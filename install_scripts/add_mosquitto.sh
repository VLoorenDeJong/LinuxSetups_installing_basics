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
# Mosquitto, the MQTT broker, as a Docker container: the message bus that
# devices (a P1 meter gateway, Zigbee2MQTT) publish to and any home automation
# platform reads from. Keeping the bus separate from the platform is what lets
# the platform be swapped without touching a device.
#
# LAN ONLY, AND NEVER ANONYMOUS. The listener is published on this machine's
# LAN address, so devices on Wi-Fi can reach it and nothing outside can: the
# router forwards nothing to it. Every client needs an account.
#
# ACCOUNTS. Each --user is an account a device logs in with; its password is
# asked for here and typed again into that device's own settings page. Service
# accounts (zigbee2mqtt) are made by their own installers, not here. Accounts
# are never removed by this script.
#
# Passwords reach mosquitto_passwd over stdin, into a tmpfs, so they are never
# in `ps`, in the shell history, or written to any disk in plaintext.
#
# Usage:
#   add_mosquitto.sh --user p1meter
#   add_mosquitto.sh --user p1meter --user phone --bind 192.168.1.10
#
# Exit codes:
#   0  the broker is up and refusing anonymous clients
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

# Prompts. print_action cannot be one: it ends with a newline.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}" > /dev/tty; }
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }
prompt_retry()  { printf "   \033[33m%s\033[0m\n" "$1" > /dev/tty; }

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

# One asterisk per character, so a paste that landed can be told from one that
# did not.
read_secret() {
    local out="" ch
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

# A --debug trace must never print a password.
secret_quiet()  { { set +x; } 2>/dev/null; }
secret_loud()   { [ "$DEBUG_MODE" = "1" ] && set -x; return 0; }

restore_tty() { stty echo < /dev/tty 2>/dev/null || true; }
trap restore_tty EXIT
trap 'restore_tty; exit 130' INT TERM

need_value() { [ -n "$2" ] || { print_error "$1 needs a value."; exit 2; }; }

# --- Arguments ---------------------------------------------------------------
USERS=()
BIND=""
PORT="1883"
DATA_DIR="/opt/mosquitto"
IMAGE="eclipse-mosquitto:2"
BROKER_UID="1883"

while [ $# -gt 0 ]; do
    case "$1" in
        --user)     need_value "$1" "${2:-}"; USERS+=("$2"); shift 2 ;;
        --bind)     need_value "$1" "${2:-}"; BIND="$2"; shift 2 ;;
        --port)     need_value "$1" "${2:-}"; PORT="$2"; shift 2 ;;
        --data-dir) need_value "$1" "${2:-}"; DATA_DIR="$2"; shift 2 ;;
        --image)    need_value "$1" "${2:-}"; IMAGE="$2"; shift 2 ;;
        -h|--help)  sed -n '18,44p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo $0 $*"
    exit 2
fi

print_header "Mosquitto (MQTT broker)"

CONF_DIR="$DATA_DIR/config"
PASSWD_FILE="$CONF_DIR/passwd"
HAVE_TTY=0
{ : < /dev/tty; } 2>/dev/null && HAVE_TTY=1

has_account() { [ -f "$PASSWD_FILE" ] && grep -q "^$1:" "$PASSWD_FILE"; }
is_ours()     { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx mosquitto; }

# --- Pre-flight --------------------------------------------------------------
ERRORS=()

if ! command -v docker >/dev/null 2>&1; then
    ERRORS+=("Docker is not installed. Install it first: sudo bash $SCRIPT_DIR/add_docker.sh")
elif ! docker info >/dev/null 2>&1; then
    ERRORS+=("Docker is installed but not answering. Check it: sudo systemctl status docker")
elif ! docker compose version >/dev/null 2>&1; then
    ERRORS+=("The docker compose plugin is missing. Install it: sudo apt-get install -y docker-compose-plugin")
fi

if [ -z "$BIND" ]; then
    BIND="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
    [ -n "$BIND" ] || ERRORS+=("Could not work out this machine's LAN address. Give it: --bind 192.168.1.10")
elif [ -z "$(ip -4 addr show to "$BIND" 2>/dev/null)" ]; then
    ERRORS+=("This machine does not hold $BIND. List its addresses: ip -4 addr")
fi

if ! [[ "$PORT" =~ ^[0-9]+$ ]] || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    ERRORS+=("--port must be a number between 1024 and 65535, not '$PORT'")
elif [ -n "$BIND" ] && ss -lnt 2>/dev/null | grep -qE "(${BIND//./\\.}|0\.0\.0\.0|\*):${PORT} " && ! is_ours; then
    ERRORS+=("Something that is not Mosquitto already listens on port $PORT. Find it: sudo ss -lntp | grep :$PORT")
fi

for u in ${USERS+"${USERS[@]}"}; do
    if ! [[ "$u" =~ ^[A-Za-z0-9_-]+$ ]]; then
        ERRORS+=("Account name '$u' may only use letters, digits, - and _")
    elif [ "$HAVE_TTY" -eq 0 ] && ! has_account "$u"; then
        ERRORS+=("No terminal to ask a password for new account '$u'. Run this once from a terminal.")
    fi
done

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

# Before the first write, so a failed download leaves nothing behind.
if ! run_watched "Pulling $IMAGE" docker pull "$IMAGE"; then
    print_error "Pre-flight failed, nothing was changed: could not pull $IMAGE."
    exit 1
fi
print_status "Image:     $IMAGE"
print_status "Listener:  ${BIND}:${PORT}, LAN only, accounts required"
print_status "Accounts:  ${USERS[*]:-none asked for here}"
print_status "Data:      $DATA_DIR"
print_success "Pre-flight passed."

# --- Files -------------------------------------------------------------------
mkdir -p "$CONF_DIR" "$DATA_DIR/data"
chown "$BROKER_UID:$BROKER_UID" "$DATA_DIR/data"

CONF_FILE="$CONF_DIR/mosquitto.conf"
NEW_CONF="# Generated by add_mosquitto.sh. The next run overwrites it.
persistence true
persistence_location /mosquitto/data/
log_dest stdout
listener 1883
allow_anonymous false
password_file /mosquitto/config/passwd"

CONF_CHANGED=0
if [ -f "$CONF_FILE" ] && [ "$(cat "$CONF_FILE")" = "$NEW_CONF" ]; then
    print_success "Broker settings unchanged."
else
    printf '%s\n' "$NEW_CONF" > "$CONF_FILE"
    chmod 0644 "$CONF_FILE"
    CONF_CHANGED=1
    print_success "Wrote $CONF_FILE"
fi

# The other containers on this bus (zigbee2mqtt) join this network by name and
# reach the broker as mosquitto:1883, never through the LAN address.
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
NEW_COMPOSE="# Generated by add_mosquitto.sh. The next run overwrites it.
services:
  mosquitto:
    container_name: mosquitto
    image: ${IMAGE}
    restart: unless-stopped
    ports:
      # Bound to the LAN address on purpose: Docker's IPv4 publishes bypass UFW.
      - \"${BIND}:${PORT}:1883\"
    volumes:
      - ./config:/mosquitto/config
      - ./data:/mosquitto/data
networks:
  default:
    name: mqtt"

if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$NEW_COMPOSE" ]; then
    print_success "Compose file unchanged."
else
    printf '%s\n' "$NEW_COMPOSE" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
    CONF_CHANGED=1
    print_success "Wrote $COMPOSE_FILE"
fi

# --- Accounts ----------------------------------------------------------------
hash_line() {
    printf '%s:%s\n' "$1" "$2" | docker run --rm -i --tmpfs /tmp --entrypoint sh "$IMAGE" \
        -c 'cat > /tmp/p && mosquitto_passwd -U /tmp/p >/dev/null && cat /tmp/p'
}

set_account() {
    local user="$1" pass="$2" line tmp
    line="$(hash_line "$user" "$pass")" || return 1
    case "$line" in "$user:"*) ;; *) return 1 ;; esac
    tmp="$(mktemp "$CONF_DIR/.passwd.XXXXXX")"
    if [ -f "$PASSWD_FILE" ]; then grep -v "^$user:" "$PASSWD_FILE" > "$tmp" || true; fi
    printf '%s\n' "$line" >> "$tmp"
    chmod 0600 "$tmp"
    chown "$BROKER_UID:$BROKER_UID" "$tmp"
    mv "$tmp" "$PASSWD_FILE"
}

[ -f "$PASSWD_FILE" ] || install -m 0600 -o "$BROKER_UID" -g "$BROKER_UID" /dev/null "$PASSWD_FILE"

ACCOUNTS_CHANGED=0
for u in ${USERS+"${USERS[@]}"}; do
    if [ "$HAVE_TTY" -eq 0 ]; then
        print_success "Account $u kept: no terminal to ask at."
        continue
    fi
    print_action "NEEDED: a password for the MQTT account '$u'"
    print_hint "The device using this account gets the same password in its own settings page."
    has_account "$u" && print_hint "It already has one: press Enter to keep it."
    secret_quiet
    while true; do
        prompt_ask "Password for $u:" ""
        read_secret; p1="$SECRET"; unset SECRET
        if [ -z "$p1" ] && has_account "$u"; then
            prompt_got "Kept the existing password for $u."
            break
        fi
        if [ ${#p1} -lt 8 ]; then
            prompt_retry "At least 8 characters."
            continue
        fi
        prompt_ask "Again:" ""
        read_secret; p2="$SECRET"; unset SECRET
        if [ "$p1" != "$p2" ]; then
            prompt_retry "They do not match. Try again."
            continue
        fi
        if set_account "$u" "$p1"; then
            ACCOUNTS_CHANGED=1
            prompt_got "Password set for $u."
        else
            print_error "Could not hash the password for $u."
            exit 1
        fi
        break
    done
    unset p1 p2
    secret_loud
done

# --- Start it ----------------------------------------------------------------
if ! run_watched "Starting Mosquitto" docker compose --project-directory "$DATA_DIR" up -d; then
    print_error "Mosquitto did not start. Logs: sudo docker logs mosquitto"
    exit 1
fi
if [ "$CONF_CHANGED" -eq 1 ]; then
    docker restart mosquitto >/dev/null || { print_error "Could not restart Mosquitto for its new settings."; exit 1; }
    print_status "Restarted Mosquitto for the new settings."
elif [ "$ACCOUNTS_CHANGED" -eq 1 ]; then
    docker kill -s HUP mosquitto >/dev/null || { print_error "Could not tell Mosquitto to re-read its accounts."; exit 1; }
    print_status "Mosquitto re-read its accounts."
fi

# --- Prove it ----------------------------------------------------------------
# An anonymous publish must be REFUSED by the broker itself. Any other failure
# (not up yet, crashing) is not proof of anything, so it is retried.
REFUSED=0
ANSWER=""
for _ in $(seq 1 50); do
    if ANSWER="$(docker exec mosquitto mosquitto_pub -h 127.0.0.1 -t install/check -m x 2>&1)"; then
        print_error "The broker ACCEPTED a client without an account. Check $CONF_FILE."
        exit 1
    fi
    if printf '%s' "$ANSWER" | grep -qi "not authori"; then REFUSED=1; break; fi
    spin_tick "Waiting for Mosquitto to answer"
done
printf '\r\033[K'
if [ "$REFUSED" -ne 1 ]; then
    print_error "Mosquitto did not answer within 10 seconds. Last reply: ${ANSWER:-none}"
    print_error "Logs: sudo docker logs mosquitto"
    exit 1
fi
print_success "Mosquitto answers and refuses anonymous clients."

# --- Firewall ----------------------------------------------------------------
# IPv4 publishes bypass UFW, so this rule only makes `ufw status` tell the truth.
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    BIND_DEV="$(ip -4 -o addr show to "$BIND" 2>/dev/null | awk '{print $2; exit}')"
    LAN_CIDR="$(ip -4 route show dev "$BIND_DEV" proto kernel 2>/dev/null | awk '{print $1; exit}')"
    if [ -z "$LAN_CIDR" ]; then
        print_info "No subnet found for $BIND, so no UFW rule was added."
    elif ufw status | grep -qE "^${PORT}/tcp[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR}"; then
        print_success "UFW already allows MQTT from $LAN_CIDR."
    elif ufw allow from "$LAN_CIDR" to any port "$PORT" proto tcp >/dev/null 2>&1; then
        print_success "UFW now allows MQTT from $LAN_CIDR."
    else
        print_info "UFW refused the MQTT rule; the broker still works, 'ufw status' just will not show it."
    fi
fi

echo ""
print_success "Mosquitto is up."
print_info "Devices connect to:  ${BIND}:${PORT}, with their account and password"
print_info "Accounts:            $(cut -d: -f1 "$PASSWD_FILE" | tr '\n' ' ')"
print_info "Logs:                sudo docker logs mosquitto"
