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
#   add_home_assistant.sh --backup-dir /srv/ha-backups   # HA's backups land here
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
print_hint()    { printf "   %s\n" "$1"; }

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

# Docker prints no percentage without a terminal, but it names every layer, so
# the bar counts layers: half for downloading, half for unpacking.
BAR_WIDTH=28

# Prints "<percent> <done>/<total>" once the log names a layer, else nothing.
pull_progress() {
    local log="$1" total have down unpacked pct
    [ -s "$log" ] || return 0
    total="$(grep -c ': Pulling fs layer' "$log" 2>/dev/null)"
    down="$(grep -c -E ': (Download complete|Already exists)' "$log" 2>/dev/null)"
    unpacked="$(grep -c -E ': (Pull complete|Already exists)' "$log" 2>/dev/null)"
    have="$(grep -c ": Already exists" "$log" 2>/dev/null)"
    total=$(( ${total:-0} + ${have:-0} ))
    [ "$total" -gt 0 ] || return 0
    pct=$(( (${down:-0} + ${unpacked:-0}) * 50 / total ))
    [ "$pct" -gt 100 ] && pct=100
    echo "$pct ${unpacked:-0}/${total}"
}

# [████░░░░] ⠸  52%  layers 3/8: filled by percent, or a sliding block before
# the first figure (the indeterminate bar).
draw_bar() {
    local pct="$1" detail="$2" filled bar i pos
    bar=""
    if [ -n "$pct" ]; then
        filled=$(( pct * BAR_WIDTH / 100 ))
        for ((i = 0; i < BAR_WIDTH; i++)); do
            [ "$i" -lt "$filled" ] && bar+="█" || bar+="░"
        done
        printf '\r\033[K[%s] %s %3d%%  %s' "$bar" "${SPIN_FRAMES[SPIN_TICK % 10]}" "$pct" "$detail"
    else
        pos=$(( SPIN_TICK % BAR_WIDTH ))
        for ((i = 0; i < BAR_WIDTH; i++)); do
            [ "$i" -ge "$pos" ] && [ "$i" -lt $((pos + 4)) ] && bar+="█" || bar+="░"
        done
        printf '\r\033[K[%s] %s  %s' "$bar" "${SPIN_FRAMES[SPIN_TICK % 10]}" "$detail"
    fi
    SPIN_TICK=$((SPIN_TICK + 1))
    sleep 0.2
}

# Watch-only like run_watched, with a bar counting layers downloaded and unpacked.
run_pull() {
    local img="$1" p
    if [ "$DEBUG_MODE" = "1" ]; then docker pull "$img"; return; fi
    local log; log="$(mktemp)"
    docker pull "$img" >"$log" 2>&1 &
    local pid=$!
    while kill -0 "$pid" 2>/dev/null; do
        p="$(pull_progress "$log")"
        if [ -n "$p" ]; then
            draw_bar "${p%% *}" "layers ${p##* }  ${img##*/}"
        else
            draw_bar "" "${img##*/}"
        fi
    done
    local rc=0
    wait "$pid" || rc=$?
    printf '\r\033[K'
    if [ "$rc" -ne 0 ]; then
        print_error "Pulling $img failed (exit $rc)"
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
BACKUP_DIR=""

while [ $# -gt 0 ]; do
    case "$1" in
        --data-dir) need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --image)    need_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        --update)   UPDATE=1; shift ;;
        --backup-dir) need_value "$1" "${2:-}"; BACKUP_DIR="$2"; shift 2 ;;
        -h|--help)  sed -n '18,42p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
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
case "$BACKUP_DIR" in
    ""|/*) ;;
    *) ERRORS+=("--backup-dir '$BACKUP_DIR' must be an absolute path.") ;;
esac
case "$BACKUP_DIR" in *" "*) ERRORS+=("--backup-dir '$BACKUP_DIR' must not contain spaces.") ;; esac
[ -S /run/dbus/system_bus_socket ] || ERRORS+=("No D-Bus socket at /run/dbus. Install it: sudo apt-get install -y dbus")

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

# Pulled only when missing or with --update, so a re-run never jumps a version.
if [ "$UPDATE" -eq 1 ] || ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    if ! run_pull "$IMAGE"; then
        print_error "Pre-flight failed, nothing was changed: could not pull $IMAGE."
        exit 1
    fi
    print_success "Pulled $IMAGE"
fi

print_status "Image:     $IMAGE"
print_status "Web page:  port ${PORT}, LAN only through UFW"
print_status "Data:      $DATA_DIR"
[ -n "$BACKUP_DIR" ] && print_status "Backups:   $BACKUP_DIR"
print_success "Pre-flight passed."

# --- Files -------------------------------------------------------------------
mkdir -p "$DATA_DIR/config"
# A share may not point into /opt, so the backups get a folder of their own.
BACKUP_MOUNT=""
if [ -n "$BACKUP_DIR" ]; then
    mkdir -p "$BACKUP_DIR"
    chmod 0755 "$BACKUP_DIR"
    BACKUP_MOUNT="
      - ${BACKUP_DIR}:/config/backups"
    if [ -d "$DATA_DIR/config/backups" ] && ! mountpoint -q "$DATA_DIR/config/backups"; then
        find "$DATA_DIR/config/backups" -maxdepth 1 -type f -name '*.tar' -exec mv -n -t "$BACKUP_DIR" {} +
    fi
fi
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
TZ_VALUE="$(timedatectl show -p Timezone --value 2>/dev/null || echo 'Etc/UTC')"
NEW_COMPOSE="# Generated by add_home_assistant.sh. The next run overwrites it.
services:
  homeassistant:
    container_name: homeassistant
    image: \"${IMAGE}\"
    volumes:
      - ./config:/config${BACKUP_MOUNT}
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
WAIT_LIMIT=300
wait_for_answer() {
    local answered=0 code wait_start
    wait_start="$(date +%s)"
    while [ $(( $(date +%s) - wait_start )) -lt "$WAIT_LIMIT" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${PORT}/" 2>/dev/null || true)"
        case "$code" in 200|302) answered=1; break ;; esac
        is_ours || break
        spin_tick "Waiting for Home Assistant, $(( $(date +%s) - wait_start ))s of ${WAIT_LIMIT}s"
    done
    printf '\r\033[K'
    if [ "$answered" -ne 1 ]; then
        print_error "Home Assistant did not answer on port ${PORT} within ${WAIT_LIMIT}s. Last lines:"
        docker logs --tail 20 homeassistant 2>&1 | sed 's/^/   /'
        exit 1
    fi
}
wait_for_answer
print_success "Home Assistant answers on port ${PORT}."

# --- Behind this machine's own proxy -----------------------------------------
# A console page proxies to it from 127.0.0.1; untrusted, every proxied
# request gets 400. Since 2026.9 Home Assistant reads http: from YAML only
# on its first start, so the setting goes into its own store, with it stopped.
HTTP_STORE="$DATA_DIR/config/.storage/http"
proxied_code() {
    curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H 'X-Forwarded-For: 192.0.2.1' "http://127.0.0.1:${PORT}/" 2>/dev/null || true
}
# The block an earlier version of this script added, now ignored and flagged.
CONFIG_YAML="$DATA_DIR/config/configuration.yaml"
if [ -f "$CONFIG_YAML" ] && grep -q '^# Added by add_home_assistant.sh: trust the proxy' "$CONFIG_YAML"; then
    sed -i '/^# Added by add_home_assistant.sh: trust the proxy/,/^    - ::1$/d' "$CONFIG_YAML"
    print_status "Removed the ignored http: block from $CONFIG_YAML."
fi

case "$(proxied_code)" in
    200|302) print_success "Home Assistant already trusts this machine's proxy." ;;
    *)
        if [ ! -f "$HTTP_STORE" ]; then
            print_error "No $HTTP_STORE, so the proxy cannot be trusted. Re-run this script once Home Assistant has started."
            exit 1
        fi
        if ! run_watched "Stopping Home Assistant" docker stop homeassistant; then
            print_error "Home Assistant did not stop. Logs: sudo docker logs homeassistant"
            exit 1
        fi
        cp -p "$HTTP_STORE" "$HTTP_STORE.before-proxy"
        if ! python3 - "$HTTP_STORE" <<'PY'
import json, sys
path = sys.argv[1]
with open(path) as f:
    store = json.load(f)
stable = store["data"]["stable"]
stable["use_x_forwarded_for"] = True
stable["trusted_proxies"] = sorted(set(stable.get("trusted_proxies", [])) | {"127.0.0.1", "::1"})
with open(path, "w") as f:
    json.dump(store, f, indent=2)
PY
        then
            cp -p "$HTTP_STORE.before-proxy" "$HTTP_STORE"
            print_error "Could not edit $HTTP_STORE; put it back as it was."
            docker start homeassistant >/dev/null 2>&1 || true
            exit 1
        fi
        print_status "Set use_x_forwarded_for and trusted_proxies 127.0.0.1, ::1 in $HTTP_STORE (old copy: $HTTP_STORE.before-proxy)."
        if ! run_watched "Starting Home Assistant" docker start homeassistant; then
            print_error "Home Assistant did not start. Logs: sudo docker logs homeassistant"
            exit 1
        fi
        wait_for_answer
        PROXIED="$(proxied_code)"
        case "$PROXIED" in
            200|302) print_success "A proxied request is answered ($PROXIED)." ;;
            *)       print_error "A proxied request still gets $PROXIED, so a console page in front of it will fail."
                     print_action "Look for 'reverse proxy' in: sudo docker logs homeassistant"
                     exit 1 ;;
        esac
        ;;
esac

echo ""
print_success "Home Assistant is up."
print_action "Open http://${LAN_IP:-<this machine>}:${PORT} now and create the owner account."
print_info "Then Settings > Devices & services > Add integration > MQTT:"
print_info "  broker ${LAN_IP:-<this machine>}, port 1883, the account made for it by add_mosquitto.sh"
print_info "Newer Home Assistant: re-run with --update"
print_info "Logs: sudo docker logs homeassistant"
