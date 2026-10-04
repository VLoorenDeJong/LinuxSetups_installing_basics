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
# Zigbee2MQTT as a Docker container, talking to a NETWORK Zigbee coordinator
# (an SMLIGHT SLZB-06 family box on Ethernet) and publishing every Zigbee
# device to the Mosquitto broker from add_mosquitto.sh.
#
# No home automation platform is assumed: anything that reads MQTT can use the
# devices, so the platform can be chosen or changed later. Discovery messages
# are published in Home Assistant's format, which other platforms can read too.
#
# The coordinator's address is found by scanning the LAN for port 6638, asked
# for only when that finds none or several, and kept in $DATA_DIR/.env. A kept
# address that stops answering is looked for again on the next run. The MQTT
# account `zigbee2mqtt` gets a generated password nobody types: it lives in that
# same file, mode 600, and in the broker's password file as a hash.
#
# configuration.yaml belongs to Zigbee2MQTT once it exists (it writes the
# network key into it), so this script creates it once and never edits it.
# Everything this script owns is set through ZIGBEE2MQTT_CONFIG_* variables in
# the compose file instead.
#
# THE WEB PAGE IS LOOPBACK ONLY. It pairs devices and has no login, so it is
# reached with:  ssh -L 8080:127.0.0.1:8080 <user>@<this machine>
#
# Usage:
#   add_zigbee2mqtt.sh
#   add_zigbee2mqtt.sh --coordinator 192.168.1.50
#   add_zigbee2mqtt.sh --coordinator 192.168.1.50:6638 --adapter zstack
#   add_zigbee2mqtt.sh --update                     # pull a newer image
#
# --adapter: ember for Silicon Labs chips (SLZB-06M, -06Mg24, -06Mg26, the
# default), zstack for Texas Instruments ones (SLZB-06, -06p7, -06p10).
#
# Exit codes:
#   0  Zigbee2MQTT is up and connected
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

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

# Prompts. print_action cannot be one: it ends with a newline.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}" > /dev/tty; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

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

# --- Arguments ---------------------------------------------------------------
COORDINATOR=""
ADAPTER="ember"
WEB_PORT="8080"
DATA_DIR="/opt/zigbee2mqtt"
MOSQUITTO_DIR="/opt/mosquitto"
IMAGE="koenkk/zigbee2mqtt:latest"
BROKER_IMAGE="eclipse-mosquitto:2"
BROKER_UID="1883"
MQTT_USER="zigbee2mqtt"
UPDATE=0

need_value() { [ -n "$2" ] || { print_error "$1 needs a value."; exit 2; }; }

# A --debug trace must never print the broker password.
secret_quiet()  { { set +x; } 2>/dev/null; }
secret_loud()   { [ "$DEBUG_MODE" = "1" ] && set -x; return 0; }

while [ $# -gt 0 ]; do
    case "$1" in
        --coordinator)   need_value "$1" "${2:-}"; COORDINATOR="$2"; shift 2 ;;
        --adapter)       need_value "$1" "${2:-}"; ADAPTER="$2"; shift 2 ;;
        --web-port)      need_value "$1" "${2:-}"; WEB_PORT="$2"; shift 2 ;;
        --data-dir)      need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --mosquitto-dir) need_value "$1" "${2:-}"; MOSQUITTO_DIR="$2"; shift 2 ;;
        --image)         need_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        --update)        UPDATE=1; shift ;;
        -h|--help)       sed -n '18,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo $0 $*"
    exit 2
fi

print_header "Zigbee2MQTT"

ENV_FILE="$DATA_DIR/.env"
PASSWD_FILE="$MOSQUITTO_DIR/config/passwd"
HAVE_TTY=0
{ : < /dev/tty; } 2>/dev/null && HAVE_TTY=1

env_get() { [ -f "$ENV_FILE" ] && sed -n "s/^$1=//p" "$ENV_FILE" | head -1 || true; }

# Pulled only when missing or with --update, so a re-run never jumps a version.
ensure_image() {
    if [ "$UPDATE" -eq 0 ] && docker image inspect "$1" >/dev/null 2>&1; then return 0; fi
    run_watched "Pulling $1" docker pull "$1"
}

# --- Pre-flight, part 1: what does not need the coordinator ------------------
ERRORS=()

if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed. Install it first: sudo bash $SCRIPT_DIR/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but not answering. Check it: sudo systemctl status docker")
else
    docker ps --format '{{.Names}}' | grep -qx mosquitto \
        || ERRORS+=("The Mosquitto broker is not running. Install it first: sudo bash $SCRIPT_DIR/add_mosquitto.sh")
    docker network inspect mqtt >/dev/null 2>&1 \
        || ERRORS+=("The 'mqtt' Docker network is missing. Re-run: sudo bash $SCRIPT_DIR/add_mosquitto.sh")
fi
[ -f "$PASSWD_FILE" ] || ERRORS+=("No broker password file at $PASSWD_FILE. Run add_mosquitto.sh first, or give --mosquitto-dir")

case "$ADAPTER" in
    ember|zstack) ;;
    *) ERRORS+=("--adapter must be ember (Silicon Labs) or zstack (Texas Instruments), not '$ADAPTER'") ;;
esac

if ! [[ "$WEB_PORT" =~ ^[0-9]+$ ]] || [ "$WEB_PORT" -lt 1024 ] || [ "$WEB_PORT" -gt 65535 ]; then
    ERRORS+=("--web-port must be a number between 1024 and 65535, not '$WEB_PORT'")
elif ss -lnt 2>/dev/null | grep -qF "127.0.0.1:${WEB_PORT} " \
     && ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx zigbee2mqtt; then
    ERRORS+=("Something that is not Zigbee2MQTT already listens on 127.0.0.1:${WEB_PORT}. Pick another: --web-port")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

# --- The coordinator's address -----------------------------------------------
CURRENT="$(env_get COORDINATOR)"

# Assumes a /24 LAN. All probes run at once, so the sweep takes under a second.
scan_for_coordinators() {
    local src net i
    src="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
    [ -n "$src" ] || return 0
    net="${src%.*}"
    {
        for i in $(seq 1 254); do
            timeout 0.5 bash -c '</dev/tcp/$1/6638' _ "$net.$i" 2>/dev/null && echo "$net.$i" &
        done
        wait
    } | sort -t. -k4 -n
}

answers() { timeout 3 bash -c '</dev/tcp/$1/$2' _ "${1%%:*}" "$( [[ "$1" == *:* ]] && echo "${1##*:}" || echo 6638 )" 2>/dev/null; }

# A stored address that stopped answering means the coordinator moved, for
# example from its cable to Wi-Fi, which gives it a new IP. So look again.
if [ -z "$COORDINATOR" ] && [ -n "$CURRENT" ]; then
    if answers "$CURRENT"; then
        COORDINATOR="$CURRENT"
    else
        print_info "The stored coordinator ${CURRENT} no longer answers."
        CURRENT=""
    fi
fi

if [ -z "$COORDINATOR" ] && [ -z "$CURRENT" ]; then
    print_status "Looking for a coordinator on this network (port 6638)..."
    mapfile -t FOUND < <(scan_for_coordinators)
    if [ ${#FOUND[@]} -eq 1 ]; then
        COORDINATOR="${FOUND[0]}"
        print_success "Found one coordinator: ${COORDINATOR}"
    elif [ ${#FOUND[@]} -gt 1 ]; then
        print_info "Found several, pick one below: ${FOUND[*]}"
    else
        print_info "Found none, so it is asked for below."
    fi
fi

if [ -z "$COORDINATOR" ] && [ "$HAVE_TTY" -eq 1 ]; then
    print_action "NEEDED: the Zigbee coordinator's network address (its IP address)"
    print_hint "if you do not have it already:"
    print_hint "  open your router's list of connected devices and look for ${HL}SLZB${NC}"
    print_hint "  give it a fixed address there, so this never changes"
    prompt_ask "Coordinator address" "[e.g. 192.168.1.50]: "
    read -r COORDINATOR < /dev/tty || COORDINATOR=""
fi
COORDINATOR="${COORDINATOR:-$CURRENT}"
COORD_HOST="${COORDINATOR%%:*}"
COORD_PORT="6638"
[[ "$COORDINATOR" == *:* ]] && COORD_PORT="${COORDINATOR##*:}"

# --- Pre-flight, part 2: the coordinator answers -----------------------------
if ! [[ "$COORD_HOST" =~ ^[A-Za-z0-9.-]+$ ]] || ! [[ "$COORD_PORT" =~ ^[0-9]+$ ]]; then
    print_error "Pre-flight failed, nothing was changed:"
    print_error "  '${COORDINATOR}' is not an address. Give it as: --coordinator 192.168.1.50 (or host:port)"
    exit 1
fi
if ! timeout 3 bash -c '</dev/tcp/$1/$2' _ "$COORD_HOST" "$COORD_PORT" 2>/dev/null; then
    print_error "Pre-flight failed, nothing was changed:"
    print_error "  Nothing answers on ${COORD_HOST}:${COORD_PORT}."
    print_error "  Check the coordinator is powered, cabled and in Zigbee coordinator mode on its own web page: http://${COORD_HOST}"
    exit 1
fi
prompt_got "Coordinator answers on ${COORD_HOST}:${COORD_PORT}."

# Before the first write, so a failed download leaves nothing behind.
if ! ensure_image "$BROKER_IMAGE" || ! ensure_image "$IMAGE"; then
    print_error "Pre-flight failed, nothing was changed: an image could not be pulled."
    exit 1
fi

print_status "Coordinator: tcp://${COORD_HOST}:${COORD_PORT}, adapter ${ADAPTER}"
print_status "Broker:      mqtt://mosquitto:1883 as ${MQTT_USER}"
print_status "Web page:    127.0.0.1:${WEB_PORT}, loopback only"
print_status "Image:       $IMAGE$([ "$UPDATE" -eq 1 ] && echo ', freshly pulled')"
print_status "Data:        $DATA_DIR"
print_success "Pre-flight passed."

# --- The broker account ------------------------------------------------------
# A password is generated only when none is kept. A generated one is always
# (re)hashed into the broker, so a lost .env cannot leave the two disagreeing.
mkdir -p "$DATA_DIR/data"
secret_quiet
MQTT_PASSWORD="$(env_get MQTT_PASSWORD)"
GENERATED=0
if [ -z "$MQTT_PASSWORD" ]; then
    MQTT_PASSWORD="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    GENERATED=1
fi

( umask 077; printf 'COORDINATOR=%s\nMQTT_PASSWORD=%s\n' "${COORD_HOST}:${COORD_PORT}" "$MQTT_PASSWORD" > "$ENV_FILE" )
chmod 0600 "$ENV_FILE"

if [ "$GENERATED" -eq 0 ] && grep -q "^${MQTT_USER}:" "$PASSWD_FILE"; then
    secret_loud
    print_success "Broker account ${MQTT_USER} exists."
else
    LINE="$(printf '%s:%s\n' "$MQTT_USER" "$MQTT_PASSWORD" | docker run --rm -i --tmpfs /tmp --entrypoint sh "$BROKER_IMAGE" \
        -c 'umask 077 && cat > /tmp/p && mosquitto_passwd -U /tmp/p >/dev/null && cat /tmp/p')" || LINE=""
    secret_loud
    case "$LINE" in
        "$MQTT_USER:"*) ;;
        *) print_error "Could not hash the broker password for ${MQTT_USER}."; exit 1 ;;
    esac
    TMP="$(mktemp "$MOSQUITTO_DIR/config/.passwd.XXXXXX")"
    grep -v "^${MQTT_USER}:" "$PASSWD_FILE" > "$TMP" || true
    printf '%s\n' "$LINE" >> "$TMP"
    chmod 0600 "$TMP"
    chown "$BROKER_UID:$BROKER_UID" "$TMP"
    mv "$TMP" "$PASSWD_FILE"
    docker exec mosquitto kill -HUP 1 >/dev/null || { print_error "Could not tell Mosquitto to re-read its accounts."; exit 1; }
    print_success "Broker account ${MQTT_USER} set; Mosquitto re-read its accounts."
fi
unset LINE

# --- Files -------------------------------------------------------------------
CONFIG_YAML="$DATA_DIR/data/configuration.yaml"
if [ -f "$CONFIG_YAML" ]; then
    print_success "configuration.yaml exists and is Zigbee2MQTT's; left alone."
else
    cat > "$CONFIG_YAML" <<'EOF'
# Created once by add_zigbee2mqtt.sh, then owned by Zigbee2MQTT.
# The broker, the coordinator and the web page come from the compose file.
version: 5
homeassistant:
  enabled: true
advanced:
  network_key: GENERATE
  pan_id: GENERATE
  ext_pan_id: GENERATE
EOF
    chmod 0644 "$CONFIG_YAML"
    print_success "Wrote $CONFIG_YAML"
fi

COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Etc/UTC')"
NEW_COMPOSE="# Generated by add_zigbee2mqtt.sh. The next run overwrites it.
services:
  zigbee2mqtt:
    container_name: zigbee2mqtt
    image: ${IMAGE}
    restart: unless-stopped
    ports:
      - \"127.0.0.1:${WEB_PORT}:8080\"
    volumes:
      - ./data:/app/data
    environment:
      TZ: \"${TZ_VALUE}\"
      Z2M_ONBOARD_NO_SERVER: \"1\"
      ZIGBEE2MQTT_CONFIG_MQTT_SERVER: \"mqtt://mosquitto:1883\"
      ZIGBEE2MQTT_CONFIG_MQTT_USER: \"${MQTT_USER}\"
      ZIGBEE2MQTT_CONFIG_MQTT_PASSWORD: \"\${MQTT_PASSWORD}\"
      ZIGBEE2MQTT_CONFIG_SERIAL_PORT: \"tcp://${COORD_HOST}:${COORD_PORT}\"
      ZIGBEE2MQTT_CONFIG_SERIAL_ADAPTER: \"${ADAPTER}\"
      ZIGBEE2MQTT_CONFIG_FRONTEND_ENABLED: \"true\"
      ZIGBEE2MQTT_CONFIG_FRONTEND_PORT: \"8080\"
      ZIGBEE2MQTT_CONFIG_HOMEASSISTANT_ENABLED: \"true\"
networks:
  default:
    name: mqtt
    external: true"

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Start it ----------------------------------------------------------------
started_at() { docker inspect -f '{{.State.StartedAt}}' zigbee2mqtt 2>/dev/null || true; }
BEFORE="$(started_at)"
SINCE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if ! run_watched "Starting Zigbee2MQTT" docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Zigbee2MQTT did not start. Logs: sudo docker logs zigbee2mqtt"
    exit 1
fi

# --- Prove it ----------------------------------------------------------------
# Running is not the same as connected to both the coordinator and the broker.
if [ -n "$BEFORE" ] && [ "$(started_at)" = "$BEFORE" ]; then
    print_success "Zigbee2MQTT unchanged and already running; not restarted."
else
    print_status "Container started at $(started_at); waiting for it to connect."
    STARTED=0
    for _ in $(seq 1 300); do
        if docker logs --since "$SINCE" zigbee2mqtt 2>&1 | grep -q "Zigbee2MQTT started"; then STARTED=1; break; fi
        docker ps --format '{{.Names}}' | grep -qx zigbee2mqtt || break
        spin_tick "Waiting for Zigbee2MQTT to reach the coordinator and the broker"
    done
    printf '\r\033[K'
    if [ "$STARTED" -ne 1 ]; then
        print_error "Zigbee2MQTT did not report a start within a minute. Last lines:"
        docker logs --tail 20 zigbee2mqtt 2>&1 | sed 's/^/   /'
        exit 1
    fi
    print_success "Zigbee2MQTT is connected to the coordinator and the broker."
fi

echo ""
print_success "Zigbee2MQTT is up."
print_info "Pair devices on the web page, over a tunnel from your PC:"
print_info "  ssh -L ${WEB_PORT}:127.0.0.1:${WEB_PORT} <user>@$(hostname)"
print_info "  then open http://localhost:${WEB_PORT} and press Permit join"
print_info "Coordinator backup: $DATA_DIR/data/coordinator_backup.json, keep a copy of it"
print_info "Newer Zigbee2MQTT: re-run with --update"
print_info "Logs: sudo docker logs zigbee2mqtt"
