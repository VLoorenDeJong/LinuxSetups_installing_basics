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
# Home Assistant Container, from the compose file Home Assistant documents:
# host networking and privileged, because discovery (mDNS, Matter, Bluetooth)
# does not work through Docker's port mapping.
#
# LAN ONLY. Host networking means the page is on port 8123 of every address
# this machine has; UFW is what limits it, and it is opened to the LAN subnet
# only. The router forwards nothing to it.
#
# FINISH SETUP STRAIGHT AWAY. The first person to open the page creates the
# owner account. This script cannot do that step for you.
#
# Devices arrive through MQTT: add the MQTT integration on the page, pointing
# at the Mosquitto broker from add_mosquitto.sh with its own account.
#
# Usage:
#   add_home_assistant.sh
#   add_home_assistant.sh --update                  # pull a newer image
#
# Exit codes:
#   0  Home Assistant is up and answering
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
DATA_DIR="/opt/homeassistant"
IMAGE="ghcr.io/home-assistant/home-assistant:stable"
PORT="8123"
UPDATE=0

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir) need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --image)    need_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        --update)   UPDATE=1; shift ;;
        -h|--help)  sed -n '18,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo $0 $*"
    exit 2
fi

print_header "Home Assistant"

is_ours() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx homeassistant; }

# --- Pre-flight --------------------------------------------------------------
ERRORS=()
if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed. Install it first: sudo bash $SCRIPT_DIR/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but not answering. Check it: sudo systemctl status docker")
elif ! docker compose version >/dev/null 2>&1; then
    ERRORS+=("The docker compose plugin is missing. Install it: sudo apt-get install -y docker-compose-plugin")
elif ss -lnt 2>/dev/null | grep -qE "[:.]${PORT} " && ! is_ours; then
    ERRORS+=("Something that is not Home Assistant already listens on port $PORT. Find it: sudo ss -lntp | grep :$PORT")
fi
[ -S /run/dbus/system_bus_socket ] || ERRORS+=("No D-Bus socket at /run/dbus. Install it: sudo apt-get install -y dbus")

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

# Pulled only when missing or with --update, so a re-run never jumps a version.
if [ "$UPDATE" -eq 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if ! run_watched "Pulling $IMAGE (large, several minutes on a Pi)" docker pull "$IMAGE"; then
        print_error "Pre-flight failed, nothing was changed: could not pull $IMAGE."
        exit 1
    fi
    print_success "Pulled $IMAGE"
fi

print_status "Image:     $IMAGE"
print_status "Web page:  port ${PORT}, LAN only through UFW"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- Files -------------------------------------------------------------------
mkdir -p "$DATA_DIR/config"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Etc/UTC')"
NEW_COMPOSE="# Generated by add_home_assistant.sh. The next run overwrites it.
services:
  homeassistant:
    container_name: homeassistant
    image: \"${IMAGE}\"
    volumes:
      - ./config:/config
      - /etc/localtime:/etc/localtime:ro
      - /run/dbus:/run/dbus:ro
    restart: unless-stopped
    stop_grace_period: 60s
    privileged: true
    network_mode: host
    environment:
      TZ: \"${TZ_VALUE}\""

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Start it ----------------------------------------------------------------
if ! run_watched "Starting Home Assistant" docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Home Assistant did not start. Logs: sudo docker logs homeassistant"
    exit 1
fi
print_success "Container started."

# --- Firewall ----------------------------------------------------------------
# Host networking goes through UFW, so this rule is what makes the page reachable.
LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    LAN_DEV="$(ip -4 -o addr show to "$LAN_IP" 2>/dev/null | awk '{print $2; exit}')"
    LAN_CIDR="$(ip -4 route show dev "$LAN_DEV" proto kernel 2>/dev/null | awk '{print $1; exit}')"
    if [ -z "$LAN_CIDR" ]; then
        print_action "No LAN subnet found. Open the page by hand: sudo ufw allow from <your-lan>/24 to any port ${PORT} proto tcp"
    elif ufw status | grep -qE "^${PORT}/tcp[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR//./\.}([[:space:]]|$)"; then
        print_success "UFW already allows port ${PORT} from $LAN_CIDR."
    elif ufw allow from "$LAN_CIDR" to any port "$PORT" proto tcp >/dev/null 2>&1; then
        print_success "UFW now allows port ${PORT} from $LAN_CIDR."
    else
        print_error "UFW refused the rule, so the LAN cannot reach the page."
        print_action "Add it by hand: sudo ufw allow from $LAN_CIDR to any port ${PORT} proto tcp"
    fi
fi

# --- Prove it ----------------------------------------------------------------
# The first start builds its database and can take minutes on a Pi.
ANSWERED=0
WAIT_LIMIT=300
WAIT_START="$(date +%s)"
while [ $(( $(date +%s) - WAIT_START )) -lt "$WAIT_LIMIT" ]; do
    CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
    case "$CODE" in 200|302) ANSWERED=1; break ;; esac
    is_ours || break
    spin_tick "Waiting for Home Assistant, $(( $(date +%s) - WAIT_START ))s of ${WAIT_LIMIT}s"
done
printf '\r\033[K'
if [ "$ANSWERED" -ne 1 ]; then
    print_error "Home Assistant did not answer on port ${PORT} within ${WAIT_LIMIT}s. Last lines:"
    docker logs --tail 20 homeassistant 2>&1 | sed 's/^/   /'
    exit 1
fi
print_success "Home Assistant answers on port ${PORT}."

echo ""
print_success "Home Assistant is up."
print_action "Open http://${LAN_IP:-<this machine>}:${PORT} now and create the owner account."
print_info "Then Settings > Devices & services > Add integration > MQTT:"
print_info "  broker ${LAN_IP:-<this machine>}, port 1883, the account made for it by add_mosquitto.sh"
print_info "Newer Home Assistant: re-run with --update"
print_info "Logs: sudo docker logs homeassistant"
