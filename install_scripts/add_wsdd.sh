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
# Make this machine appear in Windows Explorer's Network pane.
#
#   sudo ./add_wsdd.sh              install and start it
#        ./add_wsdd.sh --status     is it running, and is the port open
#   sudo ./add_wsdd.sh --off        stop and remove it
#
# WHY SAMBA IS NOT ENOUGH. Windows stopped browsing with NetBIOS years ago and
# now finds machines with WS-Discovery, a SOAP protocol Samba does not speak at
# all. So a Linux machine can serve shares perfectly and still be invisible in
# Explorer, which looks like a permissions problem and is not one.
#
#   \\hostname\share typed by hand   works, always did
#   Explorer -> Network              empty, until this is installed
#
# wsdd answers those probes on Samba's behalf. It shares nothing itself and
# changes no Samba config: it only makes the machine visible.
#
# WHAT IT DOES NOT DO, and it matters on a machine that sleeps: a sleeping
# machine cannot answer a probe, so it disappears from the Network pane while
# it is off, and clicking it there cannot wake it. WS-Discovery asks "any
# servers out there?" and names nobody, so there is nothing in that packet for
# a wake-on-access watcher to match. Reach a sleeping machine by name instead,
# with a shortcut to \\<name>\<share>.
#
# PORTS. It listens on UDP 3702 for the probes and TCP 5357 for the reply
# Windows fetches afterwards. Both are opened here, scoped to the local subnet,
# because a script that needs a port opens it itself.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

MODE="on"
while [ $# -gt 0 ]; do
    case "$1" in
        --off)    MODE="off"; shift ;;
        --status) MODE="status"; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--status|--off]" >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

OWN_UNIT="/etc/systemd/system/wsdd.service"

# Ubuntu ships this as wsdd on 24.04 and as wsdd2 on some releases. Both answer
# the same probes; whichever the machine has is the one used.
#
# `systemctl list-unit-files <name>` exits 0 with NO match, so its output has to
# be looked at rather than its status. That cost a run: the script reported a
# unit that did not exist and then failed to enable it.
detect_service() {
    local candidate
    for candidate in wsdd wsdd2; do
        if systemctl list-unit-files "${candidate}.service" --no-legend 2>/dev/null | grep -q .; then
            printf '%s' "$candidate"
            return 0
        fi
    done
    return 1
}

print_header "Windows network discovery"

if [ "$MODE" = "status" ]; then
    if SERVICE="$(detect_service)"; then
        if systemctl is-active --quiet "$SERVICE"; then
            print_success "$SERVICE is running, so this machine answers Windows discovery."
        else
            print_error "$SERVICE is installed but not running."
            print_hint "start it: sudo systemctl start $SERVICE"
        fi
    else
        print_info "Not installed on this machine, so it will not appear under Network."
    fi
    if command -v ufw >/dev/null 2>&1; then
        print_info "Firewall rules mentioning the discovery ports:"
        ufw status 2>/dev/null | grep -E '3702|5357' | sed 's/^/   /' \
            || print_hint "   none, so the probes cannot reach it"
    fi
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    print_error "This installs a package, a service and firewall rules, so it needs sudo."
    print_hint "run with: sudo $0 $*"
    exit 1
fi

if [ "$MODE" = "off" ]; then
    if SERVICE="$(detect_service)"; then
        systemctl disable --now "$SERVICE" 2>/dev/null || true
        rm -f "$OWN_UNIT"
        systemctl daemon-reload
        apt-get remove -y wsdd wsdd2 >/dev/null 2>&1 || true
        print_success "$SERVICE stopped and removed."
    else
        print_info "Nothing installed to remove."
    fi
    if command -v ufw >/dev/null 2>&1; then
        # By NUMBER, highest first, because deleting one renumbers the rest.
        # `ufw delete allow ...` only matches a rule spelled exactly as it was
        # added, so it never touched these: they carry a "from <network>" that
        # the delete form omitted.
        REMOVED=0
        while true; do
            NUM="$(ufw status numbered 2>/dev/null \
                   | grep -E 'WS-Discovery' \
                   | tail -1 | sed -n 's/^\[[[:space:]]*\([0-9]\+\)\].*/\1/p')"
            [ -n "$NUM" ] || break
            ufw --force delete "$NUM" >/dev/null 2>&1 || break
            REMOVED=$((REMOVED + 1))
        done
        print_info "Discovery ports closed, $REMOVED rule(s) removed."
    fi
    print_info "Shares still work. Only browsing from Explorer stops."
    exit 0
fi

# =============================================================================
# Pre-flight. Nothing is written until every one of these passes.
# =============================================================================
ERRORS=()

command -v systemctl >/dev/null 2>&1 || ERRORS+=("No systemd on this machine, so there is nothing to install into.")

# Discovering nothing is the normal case here, so this is information, not a
# fault: wsdd is useful before Samba as well as after.
if ! command -v smbd >/dev/null 2>&1; then
    print_info "Samba is not installed, so there are no shares to find yet."
    print_hint "this still works: the machine appears, with nothing shared on it."
fi

IFACE="$(ip -4 route show default 2>/dev/null | awk '{print $5}' | head -1)"

# The NETWORK, taken from the routing table, not this machine's own address
# with a mask stuck on it. A host address like 10.0.0.7/24 is not a network, and ufw
# prints "Rule changed after normalization" while quietly rewriting it, which
# reads as a warning about something the operator did.
# 169.254.0.0/16 is skipped: an interface carries a link-local route as well as
# its real one, and it sorts first, so taking the first row opened the firewall
# to a network nothing is on.
LAN_CIDR="$(ip -4 route show scope link dev "$IFACE" 2>/dev/null | awk '$1 !~ /^169\.254\./ {print $1; exit}')"
[ -n "$LAN_CIDR" ] || ERRORS+=("Could not work out this machine's subnet, so the firewall rules cannot be scoped.")
[ -n "$IFACE" ]    || ERRORS+=("Could not work out which interface faces the LAN.")

if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

# =============================================================================
# The change. One package, one service, two scoped firewall rules.
# =============================================================================
if ! SERVICE="$(detect_service)"; then
    LOG="$(mktemp)"
    spinner_start "Refreshing package lists..."
    apt-get update >"$LOG" 2>&1 || true
    spinner_stop

    INSTALLED=""
    for candidate in wsdd wsdd2; do
        spinner_start "Installing $candidate..."
        if apt-get install -y "$candidate" >>"$LOG" 2>&1; then
            spinner_stop
            INSTALLED="$candidate"
            break
        fi
        spinner_stop
    done

    if [ -z "$INSTALLED" ]; then
        print_error "Neither wsdd nor wsdd2 could be installed. Last lines:"
        tail -20 "$LOG"
        print_hint "full log: $LOG"
        print_hint "both live in the 'universe' component; enable it if it is off."
        exit 1
    fi
    rm -f "$LOG"
    print_success "$INSTALLED installed."
fi

# The unit is written here whether or not the package shipped one, and it is
# written to /etc, which systemd prefers over /lib. Two reasons, both found by
# running this:
#
#   24.04's wsdd package is the BINARY ONLY, so systemctl had nothing to enable.
#   22.04's package ships a unit that announces on EVERY interface. On a machine
#   with a VPN that publishes an unreachable address, and Windows drops it.
#
# One interface, named, is the whole point.
if command -v wsdd >/dev/null 2>&1; then
    # The workgroup Windows groups the machine under. Asked of Samba rather
    # than guessed, so a machine that has been given a workgroup keeps it.
    spinner_start "Asking Samba which workgroup this machine is in..."
    WORKGROUP="$(testparm -s --parameter-name workgroup 2>/dev/null | tail -1 | tr -d '[:space:]')"
    spinner_stop
    [ -n "$WORKGROUP" ] || WORKGROUP=WORKGROUP

    spinner_start "Writing the service and starting it..."
    cat > "${OWN_UNIT}.new" <<'UNIT_EOF'
[Unit]
Description=Answer Windows network discovery on Samba's behalf
Documentation=man:wsdd(8)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=__WSDD__ --shortlog --interface __IFACE__ --workgroup __WORKGROUP__
# It only listens and answers, so it needs no privilege at all. DynamicUser
# rather than nobody: systemd warns that nobody is shared with every other
# service that picked it, and this needs no identity that outlives the process.
DynamicUser=yes
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
UNIT_EOF
    # The real path, asked of the shell. It is /usr/bin/wsdd on 24.04 and
    # /usr/sbin/wsdd on some releases, and a hardcoded one fails at EXEC with
    # 203, which is a long way from the word "path" in the error.
    WSDD_BIN="$(command -v wsdd)"
    sed -i -e "s|__WSDD__|$WSDD_BIN|" -e "s|__IFACE__|$IFACE|" -e "s|__WORKGROUP__|$WORKGROUP|" "${OWN_UNIT}.new"
    mv "${OWN_UNIT}.new" "$OWN_UNIT"
    systemctl daemon-reload
    # Restart, not just start: a packaged unit may already be running with the
    # old every-interface command line.
    systemctl restart wsdd 2>/dev/null || true
    spinner_stop
    print_status "Wrote $OWN_UNIT: $WSDD_BIN on $IFACE, workgroup $WORKGROUP"
    SERVICE=wsdd
elif ! SERVICE="$(detect_service)"; then
    print_error "No wsdd binary and no wsdd2 unit, so there is nothing to run."
    exit 1
fi

# Scoped to this machine's own subnet. The probes are multicast and local by
# nature, so there is no case for opening them to anything wider.
if command -v ufw >/dev/null 2>&1; then
    spinner_start "Opening the discovery ports to $LAN_CIDR only..."
    ufw allow from "$LAN_CIDR" to any port 3702 proto udp comment 'WS-Discovery probes' >/dev/null
    ufw allow from "$LAN_CIDR" to any port 5357 proto tcp comment 'WS-Discovery replies' >/dev/null
    spinner_stop
    print_status "Opened UDP 3702 and TCP 5357 to $LAN_CIDR"
else
    print_info "No ufw on this machine, so no firewall rules were added."
fi

spinner_start "Starting $SERVICE..."
if ENABLE_LOG="$(systemctl enable --now "$SERVICE" 2>&1)"; then
    sleep 1
    spinner_stop
else
    spinner_stop
    print_error "$SERVICE refused to start:"
    printf '%s\n' "$ENABLE_LOG" | tail -10
    journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null | tail -10
    exit 1
fi

if ! systemctl is-active --quiet "$SERVICE"; then
    print_error "$SERVICE is not running after starting it."
    journalctl -u "$SERVICE" -n 15 --no-pager 2>/dev/null | tail -10
    exit 1
fi

# =============================================================================
# Say what changed, and what it does not cover
# =============================================================================
# $4 is the LOCAL address. $5 is the peer, which for a listener is always
# 0.0.0.0:* and says nothing.
LISTENING="$(ss -unlp 2>/dev/null | awk '/:3702/ {print $4}' | sort -u | tr '\n' ' ')"
print_success "$(hostname) is discoverable on $IFACE: $LISTENING"
