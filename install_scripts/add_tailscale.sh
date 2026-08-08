#!/usr/bin/env bash
set -e

# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
DEBUG_MODE=0
_dbg_args=()
for _a in "$@"; do
    case "$_a" in
        -d|--debug) DEBUG_MODE=1 ;;
        *)          _dbg_args+=("$_a") ;;
    esac
done
set -- ${_dbg_args+"${_dbg_args[@]}"}
unset _a _dbg_args
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Join this machine to a Tailscale network, and optionally offer the LAN to it.
#
# WHAT IT BUYS A MACHINE
#
# The ability to stop opening ports. A phone on mobile data reaches IMAP, SMB,
# a web console or an SSH port over the tunnel, so none of them need a port
# forward, a firewall hole or a public certificate. Inbound SMTP on 25 is the
# one thing this cannot help with: other mail servers deliver to it and they
# are not on the tunnel.
#
# THREE CHOICES, MADE HERE RATHER THAN LEFT TO DEFAULTS
#
#   The apt repository, not `curl | sh`. The vendor's installer script is
#   convenient and it is also an unreviewed program fetched over the network
#   and run as root. The repository gives signed packages, and ordinary
#   `apt upgrade` keeps it current afterwards.
#
#   DNS is left alone unless asked. MagicDNS rewrites /etc/resolv.conf, and a
#   server that resolves names through a tunnel stops resolving when the tunnel
#   does. --accept-dns turns it on for the case where a Pi-hole on the tunnel
#   is meant to be this machine's resolver.
#
#   `ufw route allow in on tailscale0` rather than `ufw default allow routed`.
#   Both make subnet routing work; the first permits forwarding from the tunnel
#   only, the second permits it from every interface on the machine.
#
# AUTHENTICATION IS ONE MANUAL STEP
#
# `tailscale up` prints a URL and waits for someone to approve it. That is
# deliberate: the alternative is storing a reusable auth key on disk. Set
# TAILSCALE_AUTHKEY in the environment to skip it on an unattended run.
#
# Usage:
#   add_tailscale.sh                                  # host only, no LAN routes
#   add_tailscale.sh --routes auto                    # advertise the local /24
#   add_tailscale.sh --routes 192.168.1.0/24,10.0.0.0/24
#   add_tailscale.sh --routes auto --hostname my-server --accept-dns
#
#   sudo env TAILSCALE_AUTHKEY=tskey-... add_tailscale.sh --routes auto
#
# Safe to re-run: an already-authenticated node keeps its identity, and only
# the advertised routes and the firewall rules are re-checked.
#
# Exit codes:
#   0  the tunnel is up, or the node was installed and left for a human to
#      authenticate
#   1  something needed for the run is missing or failed
#   2  bad usage
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0

spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only spinner: shows the command is alive but never signals it. An apt
# transaction killed halfway corrupts package state. Output is captured, never
# discarded, so a failure can be read rather than guessed at.
show_spinner_watch_only() {
    local message="$1"
    shift
    local log
    log="$(mktemp)"
    "$@" >"$log" 2>&1 &
    local cmd_pid=$!
    while kill -0 "$cmd_pid" 2>/dev/null; do
        spin_tick "$message" || break
    done
    local exit_code=0
    wait "$cmd_pid" || exit_code=$?
    printf '\r\033[K'
    if [ "$exit_code" -ne 0 ]; then
        print_error "$message failed (exit $exit_code)"
        tail -n 20 "$log" >&2
        print_warning "Full log: $log"
    else
        rm -f "$log"
    fi
    return $exit_code
}

# --- Arguments ---------------------------------------------------------------
ROUTES_SPEC=""
NODE_NAME=""
ACCEPT_DNS=0

while [ $# -gt 0 ]; do
    case "$1" in
        --routes)
            ROUTES_SPEC="$2"; shift 2 ;;
        --hostname)
            NODE_NAME="$2"; shift 2 ;;
        --accept-dns)
            ACCEPT_DNS=1; shift ;;
        -h|--help)
            sed -n '18,66p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            print_error "Unknown option: $1"
            exit 2 ;;
        *)
            print_error "Unexpected argument: $1"
            exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0 $*"
    exit 2
fi

print_header "Tailscale"

# --- Pre-flight --------------------------------------------------------------
# Everything the run depends on is settled before the first write, so a refusal
# costs a minute and a half-configured tunnel does not.
ERRORS=()
WARNINGS=()

# `auto` is only correct while the LAN is a single /24, which is why the derived
# value is printed rather than used silently.
ADVERTISE=""
case "$ROUTES_SPEC" in
    ''|-|none|no)
        print_status "Routes:  none, so only this machine is reachable on the tunnel"
        ;;
    auto)
        GATEWAY="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1)"
        if [ -z "$GATEWAY" ]; then
            ERRORS+=("--routes auto needs a default route to derive the subnet from, and there is none")
            ERRORS+=("  Give it explicitly instead: --routes 192.168.1.0/24")
        else
            ADVERTISE="$(echo "$GATEWAY" | sed -E 's/\.[0-9]+$/.0\/24/')"
            print_status "Routes:  $ADVERTISE, derived from the default route via $GATEWAY"
        fi
        ;;
    *)
        IFS=',' read -r -a _routes <<< "$ROUTES_SPEC"
        for r in ${_routes+"${_routes[@]}"}; do
            r="$(echo "$r" | xargs)"
            [ -z "$r" ] && continue
            if ! echo "$r" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$'; then
                ERRORS+=("--routes entry '$r' is not a CIDR like 192.168.1.0/24")
                continue
            fi
            ADVERTISE="${ADVERTISE:+$ADVERTISE,}$r"
        done
        [ -n "$ADVERTISE" ] && print_status "Routes:  $ADVERTISE"
        ;;
esac

if [ "$ACCEPT_DNS" -eq 1 ]; then
    DNS_FLAG="--accept-dns=true"
    print_warning "DNS:     accepting the tunnel's resolver. This machine stops resolving if the tunnel does."
else
    DNS_FLAG="--accept-dns=false"
    print_status "DNS:     unchanged, this machine keeps its own resolver"
fi

if ! command -v ip >/dev/null 2>&1; then
    ERRORS+=("iproute2 is missing, so routing cannot be set up or verified")
fi

if ! command -v curl >/dev/null 2>&1; then
    ERRORS+=("curl is missing, so the signing key cannot be fetched")
    ERRORS+=("  Install it: sudo apt-get install -y curl")
fi

if [ -z "${TAILSCALE_AUTHKEY:-}" ] && [ ! -r /dev/tty ]; then
    WARNINGS+=("No terminal and no TAILSCALE_AUTHKEY, so this node cannot be authenticated")
    WARNINGS+=("  It will be installed and left logged out. Run this script again from a terminal.")
fi

for w in ${WARNINGS+"${WARNINGS[@]}"}; do print_warning "$w"; done

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

print_success "Pre-flight passed."

# --- The package -------------------------------------------------------------
KEYRING="/usr/share/keyrings/tailscale-archive-keyring.gpg"
LIST_FILE="/etc/apt/sources.list.d/tailscale.list"

if command -v tailscale >/dev/null 2>&1; then
    print_success "Tailscale is already installed ($(tailscale version | head -1))."
else
    DISTRO="$(. /etc/os-release && echo "$ID")"
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"

    if [ ! -f "$KEYRING" ]; then
        if ! show_spinner_watch_only "Fetching the Tailscale signing key" \
            bash -c "curl -fsSL 'https://pkgs.tailscale.com/stable/${DISTRO}/${CODENAME}.noarmor.gpg' -o '$KEYRING'"; then
            rm -f "$KEYRING"
            print_error "No signing key published for ${DISTRO} ${CODENAME}."
            print_warning "Check which releases are supported: https://pkgs.tailscale.com/stable/"
            exit 1
        fi
        chmod 0644 "$KEYRING"
        print_success "Signing key installed."
    fi

    printf 'deb [signed-by=%s] https://pkgs.tailscale.com/stable/%s %s main\n' \
        "$KEYRING" "$DISTRO" "$CODENAME" > "$LIST_FILE"
    chmod 0644 "$LIST_FILE"

    show_spinner_watch_only "Updating package lists" apt-get update -qq
    show_spinner_watch_only "Installing tailscale" apt-get install -y -qq tailscale
    print_success "Installed $(tailscale version | head -1)."
fi

systemctl enable --now tailscaled >/dev/null 2>&1 || true

# --- IP forwarding -----------------------------------------------------------
# Only needed when this machine offers routes to other devices. Written as a
# sysctl drop-in rather than a runtime `sysctl -w`, or the routing works until
# the first reboot and then stops for no visible reason.
SYSCTL_FILE="/etc/sysctl.d/99-tailscale.conf"
if [ -n "$ADVERTISE" ]; then
    NEW_SYSCTL="$(cat <<'EOF'
# Generated by add_tailscale.sh. Needed for subnet routing.
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF
)"
    if [ ! -f "$SYSCTL_FILE" ] || [ "$(cat "$SYSCTL_FILE")" != "$NEW_SYSCTL" ]; then
        printf '%s\n' "$NEW_SYSCTL" > "$SYSCTL_FILE"
        chmod 0644 "$SYSCTL_FILE"
        sysctl -p "$SYSCTL_FILE" >/dev/null 2>&1 || true
        print_success "IP forwarding enabled for subnet routing."
    else
        print_success "IP forwarding already enabled."
    fi
fi

# --- Authentication ----------------------------------------------------------
# `tailscale up` blocks on a URL the operator must open, so it runs in the
# foreground with its own output visible. A spinner over it would hide the one
# thing the operator needs to read.
UP_ARGS=("$DNS_FLAG")
[ -n "$ADVERTISE" ] && UP_ARGS+=("--advertise-routes=$ADVERTISE")
[ -n "$NODE_NAME" ] && UP_ARGS+=("--hostname=$NODE_NAME")

BACKEND_STATE="$(tailscale status --json 2>/dev/null \
    | sed -n 's/.*"BackendState"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

if [ "$BACKEND_STATE" = "Running" ]; then
    # Already authenticated. `set` changes the advertised routes without
    # touching the node's identity, where a second `up` can prompt again.
    print_success "Already authenticated on the tunnel."
    if [ -n "$ADVERTISE" ]; then
        tailscale set --advertise-routes="$ADVERTISE" 2>/dev/null \
            && print_success "Advertising $ADVERTISE." \
            || print_warning "Could not update routes. Run: sudo tailscale set --advertise-routes=$ADVERTISE"
    fi
    tailscale set "$DNS_FLAG" >/dev/null 2>&1 || true
elif [ -n "${TAILSCALE_AUTHKEY:-}" ]; then
    if tailscale up --authkey="$TAILSCALE_AUTHKEY" "${UP_ARGS[@]}"; then
        print_success "Authenticated with the supplied auth key."
    else
        print_error "tailscale up failed with the supplied auth key."
        exit 1
    fi
elif [ -r /dev/tty ]; then
    echo ""
    print_header "One manual step: authorise this machine"
    echo "A URL appears below. Open it on any device signed in to your Tailscale"
    echo "account and approve this machine. This happens once."
    echo ""
    if tailscale up "${UP_ARGS[@]}" < /dev/tty; then
        print_success "Authenticated."
    else
        print_error "tailscale up did not complete."
        print_warning "Run it by hand: sudo tailscale up ${UP_ARGS[*]}"
        exit 1
    fi
else
    print_warning "Installed but not authenticated: no terminal and no TAILSCALE_AUTHKEY."
    print_warning "Finish it with: sudo tailscale up ${UP_ARGS[*]}"
    exit 0
fi

# --- The firewall ------------------------------------------------------------
# UFW's default is to drop, and it does not know the tunnel is trusted. Without
# the first rule every service on this machine is unreachable over Tailscale
# while looking perfectly healthy locally.
#
# The second rule is forwarding, and only for packets arriving on the tunnel.
# `ufw default allow routed` would do the same job for every interface.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    if ufw status | grep -q "on tailscale0"; then
        print_success "UFW already trusts the tailscale0 interface."
    else
        ufw allow in on tailscale0 >/dev/null 2>&1
        print_success "UFW now accepts traffic arriving on tailscale0."
    fi

    if [ -n "$ADVERTISE" ]; then
        if ufw show added 2>/dev/null | grep -q "route allow in on tailscale0"; then
            print_success "UFW already forwards from tailscale0."
        else
            ufw route allow in on tailscale0 >/dev/null 2>&1 \
                && print_success "UFW now forwards traffic from tailscale0 to the LAN." \
                || print_warning "Add the route rule by hand: sudo ufw route allow in on tailscale0"
        fi
    fi
else
    print_warning "UFW is not active, so no firewall rules were added."
fi

# --- What it looks like now --------------------------------------------------
TS_IP="$(tailscale ip -4 2>/dev/null | head -1)"

echo ""
print_success "Tailscale is up."
[ -n "$TS_IP" ] && print_status "This machine on the tunnel: $TS_IP"
print_status "Status: sudo tailscale status"

if [ -n "$ADVERTISE" ]; then
    echo ""
    print_header "One click left, and nothing works until you make it"
    echo "This machine is OFFERING the route $ADVERTISE. Tailscale does not"
    echo "accept a route because a machine advertises one: you approve it."
    echo ""
    echo "  1. Open https://login.tailscale.com/admin/machines"
    echo "  2. Find $(hostname), open its ... menu"
    echo "  3. Edit route settings, tick $ADVERTISE, save"
    echo ""
    echo "Until then the tunnel reaches this machine and nothing else on the LAN,"
    echo "which looks exactly like a broken install."
    echo ""
fi

print_status "On a phone: install Tailscale, sign in to the same account, done."
[ -n "$TS_IP" ] && print_status "Reach services at $TS_IP, e.g. imap at $TS_IP:993."
