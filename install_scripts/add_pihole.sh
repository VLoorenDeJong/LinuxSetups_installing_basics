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
# Pi-hole as a Docker container: network-wide DNS with ad and tracker blocking.
#
# WHY DOCKER AND NOT THE NATIVE INSTALLER
#
# Pi-hole ships no apt repository, so the native route is `curl | bash` and it
# reaches into the system to take port 53, which on Ubuntu means disabling
# systemd-resolved's stub listener. Get that wrong on a remote machine and the
# machine has no resolver, which is a bad afternoon on a box that also serves
# mail and web. In a container the conflict is settled by a bind address
# instead, and the worst failure is a container that will not start.
#
# THE BIND ADDRESS IS THE SECURITY BOUNDARY HERE, NOT UFW
#
# Docker publishes ports by writing its own iptables rules, and those are
# consulted BEFORE UFW's. A published port is therefore reachable even when UFW
# says otherwise, and this surprises people every time.
#
# So exposure is controlled by WHERE each port is bound:
#
#   DNS   bound to this machine's LAN address, so the LAN can resolve and
#         127.0.0.53 is left to systemd-resolved, which keeps the machine's own
#         name resolution working.
#   Web   bound to 127.0.0.1, so the admin page is reachable only through a
#         reverse proxy on this machine or over a tunnel. Never from the LAN
#         directly, because it is plain HTTP with a password on it.
#
# UFW rules are still added for DNS, so `ufw status` tells the truth about what
# is open rather than hiding a port Docker opened behind its back.
#
# THE ADMIN PASSWORD IS NEVER AN ARGUMENT
#
# It is asked for on the terminal and written to an env file at mode 600, so it
# is not in `ps`, not in the shell history, and not in the compose file.
#
# Usage:
#   add_pihole.sh                                   # prompts for the password
#   add_pihole.sh --web-port 15001 --upstream 9.9.9.9,149.112.112.112
#   add_pihole.sh --dns-bind 192.168.1.10 --data-dir /opt/pihole
#
# Safe to re-run: the data directory, the blocklists and the password are left
# alone unless a new password is given.
#
# Exit codes:
#   0  the container is up and answering DNS
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

# Watch-only spinner: shows the command is alive but never signals it. An image
# pull killed halfway leaves a partial layer cache. Output is captured, never
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

# One asterisk per character, as they arrive. Duplicated from add_auth_users.sh
# per the convention that each script stays runnable alone.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            ''|$'\n')       break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

read_password_twice() {
    local p1 p2
    while true; do
        read_secret "   Admin password: " || return 1
        p1="$SECRET"
        unset SECRET
        if [ ${#p1} -lt 8 ]; then
            printf "   \033[33mAt least 8 characters. This one blocks or unblocks your whole network.\033[0m\n" > /dev/tty
            continue
        fi
        read_secret "   Again: " || return 1
        p2="$SECRET"
        unset SECRET
        if [ "$p1" = "$p2" ]; then
            PASSWORD="$p1"
            return 0
        fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

# --- Arguments ---------------------------------------------------------------
WEB_PORT="15001"
UPSTREAM="9.9.9.9,149.112.112.112"
DNS_BIND=""
DATA_DIR="/opt/pihole"
IMAGE="pihole/pihole:latest"

while [ $# -gt 0 ]; do
    case "$1" in
        --web-port)  WEB_PORT="$2"; shift 2 ;;
        --upstream)  UPSTREAM="$2"; shift 2 ;;
        --dns-bind)  DNS_BIND="$2"; shift 2 ;;
        --data-dir)  DATA_DIR="$2"; shift 2 ;;
        --image)     IMAGE="$2"; shift 2 ;;
        -h|--help)
            sed -n '18,64p' "$0" | sed 's/^# \{0,1\}//'
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

print_header "Pi-hole"

# --- Pre-flight --------------------------------------------------------------
# Nothing is written until the run is known to be able to finish. A half-created
# container with a half-taken port 53 is worse than a refusal.
ERRORS=()
WARNINGS=()

if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed, and this runs Pi-hole as a container")
    ERRORS+=("  Install it first: sudo bash $(dirname "$0")/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but the daemon is not answering")
    ERRORS+=("  Check it: sudo systemctl status docker")
elif ! docker compose version >/dev/null 2>&1; then
    ERRORS+=("The docker compose plugin is missing")
    ERRORS+=("  Install it: sudo apt-get install -y docker-compose-plugin")
fi

# The LAN address, so DNS is published there rather than on 0.0.0.0. Publishing
# on 0.0.0.0 would collide with systemd-resolved on 127.0.0.53 and take the
# machine's own resolver with it.
if [ -z "$DNS_BIND" ]; then
    DNS_BIND="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    if [ -z "$DNS_BIND" ]; then
        ERRORS+=("Could not work out this machine's LAN address for DNS to listen on")
        ERRORS+=("  Give it explicitly: --dns-bind 192.168.1.10")
    fi
fi

if ! echo "$WEB_PORT" | grep -qE '^[0-9]+$' || [ "$WEB_PORT" -lt 1024 ] || [ "$WEB_PORT" -gt 65535 ]; then
    ERRORS+=("--web-port must be a number between 1024 and 65535, not '$WEB_PORT'")
fi

IFS=',' read -r -a _ups <<< "$UPSTREAM"
for u in ${_ups+"${_ups[@]}"}; do
    u="$(echo "$u" | xargs)"
    [ -z "$u" ] && continue
    if ! echo "$u" | grep -qE '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[0-9a-fA-F:]+$'; then
        ERRORS+=("--upstream entry '$u' is not an IP address")
    fi
done

# Port 53 on the LAN address specifically. systemd-resolved holding 127.0.0.53
# is expected and fine, so the check is deliberately narrow.
if command -v ss >/dev/null 2>&1; then
    if ss -lnup 2>/dev/null | grep -q "${DNS_BIND}:53 " || ss -lntp 2>/dev/null | grep -q "${DNS_BIND}:53 "; then
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pihole; then
            ERRORS+=("Something is already listening on ${DNS_BIND}:53 and it is not Pi-hole")
            ERRORS+=("  Find it: sudo ss -lnup | grep ':53'")
        fi
    fi
    if ss -lnt 2>/dev/null | grep -q "127.0.0.1:${WEB_PORT} "; then
        if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx pihole; then
            ERRORS+=("Something is already listening on 127.0.0.1:${WEB_PORT}")
        fi
    fi
fi

ENV_FILE="$DATA_DIR/.env"
if [ ! -f "$ENV_FILE" ] && [ ! -r /dev/tty ]; then
    ERRORS+=("No terminal to ask for an admin password, and no existing $ENV_FILE")
    ERRORS+=("  Run this from a terminal once, then it is re-runnable unattended.")
fi

for w in ${WARNINGS+"${WARNINGS[@]}"}; do print_warning "$w"; done

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

print_status "DNS:       ${DNS_BIND}:53, so the LAN can resolve through it"
print_status "Admin:     127.0.0.1:${WEB_PORT}, reachable only via a proxy or a tunnel"
print_status "Upstream:  $UPSTREAM"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- The password ------------------------------------------------------------
mkdir -p "$DATA_DIR"
chmod 0755 "$DATA_DIR"

if [ -f "$ENV_FILE" ]; then
    print_success "Keeping the existing admin password ($ENV_FILE)."
else
    echo ""
    print_status "Pi-hole's admin page has a password and no username."
    if ! read_password_twice; then
        print_error "No password given, so the admin page would be wide open."
        exit 1
    fi
    ( umask 077; printf 'PIHOLE_PASSWORD=%s\n' "$PASSWORD" > "$ENV_FILE" )
    unset PASSWORD
    chmod 0600 "$ENV_FILE"
    print_success "Password stored at $ENV_FILE (mode 600)."
fi

# --- The compose file --------------------------------------------------------
# Pi-hole v6 renamed its environment variables to FTLCONF_*. The v5 names are
# set alongside them because an unknown variable is ignored by both, and that
# costs four lines against an install that silently comes up with no password.
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Etc/UTC')"

NEW_COMPOSE="$(cat <<EOF
# Generated by add_pihole.sh. Do not edit by hand: the next run overwrites it.
# Re-run the script with different flags instead.
services:
  pihole:
    container_name: pihole
    image: ${IMAGE}
    restart: unless-stopped
    ports:
      # Bound to an address on purpose. Docker's published ports bypass UFW, so
      # the bind address is what decides who can reach these.
      - "${DNS_BIND}:53:53/tcp"
      - "${DNS_BIND}:53:53/udp"
      - "127.0.0.1:${WEB_PORT}:80/tcp"
    environment:
      TZ: "${TZ_VALUE}"
      FTLCONF_webserver_api_password: "\${PIHOLE_PASSWORD}"
      FTLCONF_dns_upstreams: "${UPSTREAM//,/;}"
      FTLCONF_dns_listeningMode: "all"
      WEBPASSWORD: "\${PIHOLE_PASSWORD}"
      PIHOLE_DNS_: "${UPSTREAM//,/;}"
    volumes:
      - ./etc-pihole:/etc/pihole
    cap_add:
      - NET_ADMIN
    healthcheck:
      test: ["CMD", "dig", "+short", "+norecurse", "+retry=0", "@127.0.0.1", "pi.hole"]
      interval: 30s
      retries: 3
EOF
)"

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Start it ----------------------------------------------------------------
if ! show_spinner_watch_only "Pulling the Pi-hole image" \
    docker compose --project-directory "$DATA_DIR" pull; then
    print_error "Could not pull $IMAGE."
    exit 1
fi

if ! show_spinner_watch_only "Starting Pi-hole" \
    docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Pi-hole did not start."
    print_warning "Logs: sudo docker logs pihole"
    exit 1
fi

# --- Prove it answers --------------------------------------------------------
# A container that is "up" is not the same as a resolver that works, and the
# difference is worth thirty seconds now rather than at the first blank browser.
WAIT_LIMIT=60
WAIT_START="$(date +%s)"
RESOLVED=0
while [ $(( $(date +%s) - WAIT_START )) -lt "$WAIT_LIMIT" ]; do
    if command -v dig >/dev/null 2>&1; then
        dig +short +time=2 +tries=1 "@${DNS_BIND}" example.com >/dev/null 2>&1 && { RESOLVED=1; break; }
    else
        docker exec pihole dig +short +time=2 +tries=1 @127.0.0.1 example.com >/dev/null 2>&1 \
            && { RESOLVED=1; break; }
    fi
    spin_tick "Waiting for Pi-hole to answer DNS, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
done
printf '\r\033[K'

if [ "$RESOLVED" -eq 1 ]; then
    print_success "Pi-hole is resolving on ${DNS_BIND}:53."
else
    print_error "Pi-hole is running but did not answer a query within ${WAIT_LIMIT}s."
    print_warning "Logs: sudo docker logs pihole"
    print_warning "Try by hand: dig @${DNS_BIND} example.com"
    exit 1
fi

# --- The firewall ------------------------------------------------------------
# Docker already opened port 53 by writing its own iptables rules, and UFW was
# not consulted. The rule below changes nothing about reachability: it makes
# `ufw status` tell the truth about what this machine answers on.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    LAN_CIDR="$(ip -4 route show default 2>/dev/null | awk '{print $3}' | head -1 \
        | sed -E 's/\.[0-9]+$/.0\/24/')"
    if [ -z "$LAN_CIDR" ]; then
        print_warning "No default route, so no DNS firewall rule was added."
        print_warning "Add it by hand: sudo ufw allow from <your-lan>/24 to any port 53"
    elif ufw status | grep -q "53.*$LAN_CIDR"; then
        print_success "UFW already allows DNS from $LAN_CIDR."
    else
        ufw allow from "$LAN_CIDR" to any port 53 proto udp >/dev/null 2>&1
        ufw allow from "$LAN_CIDR" to any port 53 proto tcp >/dev/null 2>&1
        print_success "UFW now allows DNS from $LAN_CIDR."
    fi
else
    print_warning "UFW is not active, so no firewall rules were added."
fi

# --- What to do with it ------------------------------------------------------
echo ""
print_success "Pi-hole is up."
print_status "Admin page:  http://127.0.0.1:${WEB_PORT}/admin  (loopback only)"
print_status "Container:   sudo docker logs pihole"
print_status "Restart:     sudo docker compose --project-directory $DATA_DIR restart"

echo ""
print_header "Two steps left, both by hand"
echo "1. Reach the admin page. It is bound to loopback, so pick one:"
echo "     - a reverse-proxy vhost on this machine, or"
echo "     - over Tailscale, or"
echo "     - an SSH tunnel:  ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} <user>@$(hostname)"
echo ""
echo "2. Point devices at it. Set your router's DNS server to ${DNS_BIND} and"
echo "   every device picks it up on its next lease. Nothing is being blocked"
echo "   until you do, because nothing is asking Pi-hole anything yet."
echo ""
print_warning "Test one device first. If DNS breaks, every device on the LAN breaks"
print_warning "together, and the symptom is 'the internet is down' rather than 'DNS'."
