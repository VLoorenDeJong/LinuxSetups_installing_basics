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
# Homey Self-Hosted Server (Athom), from the compose file Athom documents:
# host networking and privileged, for device discovery on the LAN.
#
# A PAID PRODUCT. The first activation on its web page starts a free month;
# after that it needs a subscription or a lifetime licence, and stops working
# without one. Installing it costs nothing until it is activated.
#
# It can run beside Home Assistant: the two use different ports (Homey 4859 to
# 4862, Home Assistant 8123) and can both read the same MQTT broker.
#
# LAN ONLY. Host networking means its ports are on every address this machine
# has; UFW opens them to the LAN subnet only. The router forwards nothing.
#
# Usage:
#   add_homey_shs.sh
#   add_homey_shs.sh --update                       # pull a newer image
#
# Exit codes:
#   0  Homey Self-Hosted Server is up and answering
#   1  something needed for the run is missing or failed
#   2  bad usage
# =============================================================================

export DEBIAN_FRONTEND=noninteractive
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
SPIN_TICK=0
spin_tick() {
    printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[SPIN_TICK % 10]}" "$1"
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only: an image pull killed halfway leaves a partial layer cache.
run_watched() {
    local message="$1"; shift
    if [ "$DEBUG_MODE" = "1" ]; then "$@"; return; fi
    local log; log="$(mktemp)"
    "$@" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do spin_tick "$message"; done
    local rc=0
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        print_error "$message failed (exit $rc)"
        tail -n 20 "$log" >&2
        print_info "Full log: $log"
    else
        rm -f "$log"
    fi
    return $rc
}

need_value() { [ -n "$2" ] || { print_error "$1 needs a value."; exit 2; }; }

# --- Arguments ---------------------------------------------------------------
DATA_DIR="/opt/homey-shs"
IMAGE="ghcr.io/athombv/homey-shs:latest"
PORTS=(4859 4860 4861 4862)
UPDATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir) need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --image)    need_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        --update)   UPDATE=1; shift ;;
        -h|--help)  sed -n '18,40p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo $0 $*"
    exit 2
fi

print_header "Homey Self-Hosted Server"

is_ours() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx homey-shs; }

# --- Pre-flight --------------------------------------------------------------
ERRORS=()
if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed. Install it first: sudo bash $SCRIPT_DIR/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but not answering. Check it: sudo systemctl status docker")
elif ! docker compose version >/dev/null 2>&1; then
    ERRORS+=("The docker compose plugin is missing. Install it: sudo apt-get install -y docker-compose-plugin")
elif ! is_ours; then
    for p in "${PORTS[@]}"; do
        if ss -lnt 2>/dev/null | grep -qE "[:.]${p} "; then
            ERRORS+=("Port $p is already in use, and Homey needs it. Find it: sudo ss -lntp | grep :$p")
        fi
    done
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

# Pulled only when missing or with --update, so a re-run never jumps a version.
if [ "$UPDATE" -eq 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if ! run_watched "Pulling $IMAGE" docker pull "$IMAGE"; then
        print_error "Pre-flight failed, nothing was changed: could not pull $IMAGE."
        exit 1
    fi
    print_success "Pulled $IMAGE"
fi

print_status "Image:     $IMAGE"
print_status "Ports:     ${PORTS[*]}, LAN only through UFW"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- Files -------------------------------------------------------------------
mkdir -p "$DATA_DIR/user"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
NEW_COMPOSE="# Generated by add_homey_shs.sh. The next run overwrites it.
services:
  homey-shs:
    container_name: homey-shs
    image: ${IMAGE}
    restart: unless-stopped
    network_mode: host
    privileged: true
    volumes:
      - ./user:/homey/user"

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Start it ----------------------------------------------------------------
if ! run_watched "Starting Homey" docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Homey did not start. Logs: sudo docker logs homey-shs"
    exit 1
fi
print_success "Container started."

# --- Firewall ----------------------------------------------------------------
# Host networking goes through UFW, so these rules are what make Homey reachable.
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    LAN_DEV="$(ip -4 -o addr show to "$LAN_IP" 2>/dev/null | awk '{print $2; exit}')"
    LAN_CIDR="$(ip -4 route show dev "$LAN_DEV" proto kernel 2>/dev/null | awk '{print $1; exit}')"
    RANGE="${PORTS[0]}:${PORTS[${#PORTS[@]}-1]}"
    if [ -z "$LAN_CIDR" ]; then
        print_action "No LAN subnet found. Open Homey by hand: sudo ufw allow from <your-lan>/24 to any port $RANGE proto tcp"
    elif ufw status | grep -qE "^${RANGE}/tcp[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR//./\.}([[:space:]]|$)"; then
        print_success "UFW already allows ports $RANGE from $LAN_CIDR."
    elif ufw allow from "$LAN_CIDR" to any port "$RANGE" proto tcp >/dev/null 2>&1; then
        print_success "UFW now allows ports $RANGE from $LAN_CIDR."
    else
        print_error "UFW refused the rule, so the LAN cannot reach Homey."
        print_action "Add it by hand: sudo ufw allow from $LAN_CIDR to any port $RANGE proto tcp"
    fi
fi

# --- Prove it ----------------------------------------------------------------
ANSWERED=0
WAIT_LIMIT=180
WAIT_START="$(date +%s)"
while [ $(( $(date +%s) - WAIT_START )) -lt "$WAIT_LIMIT" ]; do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORTS[0]}/" 2>/dev/null || true)"
    case "$CODE" in 2??|3??) ANSWERED=1; break ;; esac
    is_ours || break
    spin_tick "Waiting for Homey, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
done
printf '\r\033[K'
if [ "$ANSWERED" -ne 1 ]; then
    print_error "Homey did not answer on port ${PORTS[0]} within ${WAIT_LIMIT}s. Last lines:"
    docker logs --tail 20 homey-shs 2>&1 | sed 's/^/   /'
    exit 1
fi
print_success "Homey answers on port ${PORTS[0]}."

echo ""
print_success "Homey Self-Hosted Server is up, not yet activated."
print_info "Activating it on http://${LAN_IP:-<this machine>}:${PORTS[0]} starts the free month."
print_info "MQTT: install Homey's MQTT app and point it at ${LAN_IP:-<this machine>}:1883 with its own account."
print_info "Newer Homey: re-run with --update"
print_info "Logs: sudo docker logs homey-shs"
