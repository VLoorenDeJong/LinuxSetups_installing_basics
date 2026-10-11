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
# Uptime Kuma 2.x: watches every site and service, and tells Home Assistant
# when one goes down. Its monitors come from hostings.conf (sync_monitors.sh),
# never clicked in.
#
# THE PORT COMES FROM THE HOSTINGS CONFIG when it has a `PANEL = kuma` row:
# Kuma then listens on that row's 127.0.0.1 target for good, and the console's
# door is the only way in. Without one, Kuma's own 3001, opened to the LAN
# subnet in UFW. Host networking either way: Docker's IPv4 publishes bypass UFW.
#
# THE ADMIN IS MADE HERE, NOT ON THE FIRST PAGE VISIT, because Kuma gives admin
# to whoever opens the page first. Until the account exists Kuma listens on
# 127.0.0.1 only. Kuma has no setting for it, so the account is made through
# its own socket events, by Node inside the container: nothing is installed.
#
# WHERE THE SECRETS GO, first match wins:
#   1. a secret store, when a secret_ask.sh is found (SECRET_ASK_SH, or the
#      hostings/scripts/ beside this folder): the login "Uptime Kuma admin",
#      generated when missing, and a metrics key "Uptime Kuma API key"
#   2. the keyboard for the password; the API key is then made on the page
#
# THE MONITOR SYNC SIGNS IN WITH A TOKEN, never the password: /etc/uptime-kuma/
# token, root only. It opens Kuma and nothing else, and a new admin password
# makes it worthless. Written whenever the password is at hand; --renew-token
# asks for the password to write a new one.
#
# Usage:
#   add_uptime_kuma.sh
#   add_uptime_kuma.sh --port 3001 --data-dir /opt/uptime-kuma
#   add_uptime_kuma.sh --renew-token
#
# Exit codes:
#   0  Kuma is up, with an admin account
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

# Docker prints no percentage without a terminal, but it names every layer, so
# the bar counts layers: half for downloading, half for unpacking.
BAR_WIDTH=28

# Prints "<percent> <done>/<total>" once the log names a layer, else nothing.
pull_progress() {
    local log="$1" total have down unpacked pct
    [ -s "$log" ] || return 0
    total="$(grep -c ': Pulling fs layer' "$log" 2>/dev/null)" || true
    down="$(grep -c -E ': (Download complete|Already exists)' "$log" 2>/dev/null)" || true
    unpacked="$(grep -c -E ': (Pull complete|Already exists)' "$log" 2>/dev/null)" || true
    have="$(grep -c ": Already exists" "$log" 2>/dev/null)" || true
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

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

# Kuma calls a password without both letters and digits "too weak".
read_password_twice() {
    local p1 p2
    while true; do
        read_secret "   Password for admin: " || return 1
        p1="$SECRET"; unset SECRET
        if [ ${#p1} -lt 12 ] || ! [[ "$p1" =~ [A-Za-z] && "$p1" =~ [0-9] ]]; then
            printf "   \033[33mAt least 12 characters, with letters and digits.\033[0m\n" > /dev/tty
            continue
        fi
        read_secret "   Again: " || return 1
        p2="$SECRET"; unset SECRET
        if [ "$p1" = "$p2" ]; then PASSWORD="$p1"; return 0; fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

# --- Arguments ---------------------------------------------------------------
PORT="3001"
DATA_DIR="/opt/uptime-kuma"
IMAGE="louislam/uptime-kuma:2"
KEY_NAME="metrics, read only"
TOKEN_FILE="/etc/uptime-kuma/token"
RENEW_TOKEN=0
PORT_GIVEN=0

while [ $# -gt 0 ]; do
    case "$1" in
        --port)     PORT="$2"; PORT_GIVEN=1; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        --renew-token) RENEW_TOKEN=1; shift ;;
        -h|--help)  sed -n '18,53p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo bash $0"
    exit 2
fi

print_header "Uptime Kuma"

# --- Port: the kuma machine page's target, else Kuma's default ----------------
. "$SCRIPT_DIR/../hostings/scripts/config.sh" 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active /etc/hostings)}"
DOOR=""
if [ "$PORT_GIVEN" -eq 0 ] && [ -f "$SITES_CONF" ]; then
    ROW="$(grep -E '^[[:space:]]*PANEL[[:space:]]*=[[:space:]]*kuma[[:space:]]*\|' "$SITES_CONF" | head -n 1 | tr -d '\r' || true)"
    ROW_DOOR="$(printf '%s' "$ROW" | awk -F'|' '{gsub(/ /, "", $2); print $2}')"
    ROW_TARGET="$(printf '%s' "$ROW" | awk -F'|' '{gsub(/ /, "", $5); print $5}')"
    if [[ "$ROW_TARGET" =~ ^127\.0\.0\.1:([0-9]+)$ ]] && [[ "$ROW_DOOR" =~ ^[0-9]+$ ]]; then
        PORT="${BASH_REMATCH[1]}"
        DOOR="$ROW_DOOR"
    fi
fi
# Behind a door Kuma never leaves loopback; alone it opens to the LAN.
if [ -n "$DOOR" ]; then LAN_BIND="127.0.0.1"; else LAN_BIND="0.0.0.0"; fi

# --- Pre-flight --------------------------------------------------------------
ERRORS=()

if [ ! -f "$SCRIPT_DIR/check_docker.sh" ]; then
    ERRORS+=("check_docker.sh is missing from $SCRIPT_DIR")
elif ! bash "$SCRIPT_DIR/check_docker.sh"; then
    ERRORS+=("Docker is not usable, see above")
fi

if ! echo "$PORT" | grep -qE '^[0-9]+$' || [ "$PORT" -lt 1024 ] || [ "$PORT" -gt 65535 ]; then
    ERRORS+=("--port must be a number between 1024 and 65535, not '$PORT'")
fi

_is_kuma() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx uptime-kuma; }
if ss -lnt 2>/dev/null | grep -qE "[:.]${PORT} " && ! _is_kuma; then
    ERRORS+=("Something that is not Uptime Kuma already listens on port ${PORT}")
fi

command -v curl >/dev/null 2>&1 || ERRORS+=("curl is missing: sudo apt-get install -y curl")
command -v python3 >/dev/null 2>&1 || ERRORS+=("python3 is missing: sudo apt-get install -y python3")

LAN_IP="$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)"
LAN_DEV="$(ip -4 -o addr show to "$LAN_IP" 2>/dev/null | awk '{print $2; exit}')"
LAN_CIDR="$(ip -4 route show dev "$LAN_DEV" proto kernel 2>/dev/null | awk '{print $1; exit}')"
UFW_ON=0
if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q "Status: active"; then
    UFW_ON=1
    [ -n "$LAN_CIDR" ] || ERRORS+=("No LAN subnet found, so UFW cannot be scoped to it. Check: ip -4 route")
fi

STORE=0
for cand in "${SECRET_ASK_SH:-}" "$SCRIPT_DIR/../hostings/scripts/secret_ask.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    # shellcheck source=/dev/null
    . "$cand" 2>/dev/null || true
    [ "${SECRET_READY:-0}" = "1" ] && secret_preflight >/dev/null 2>&1 && STORE=1
    break
done
if [ "$STORE" -eq 1 ]; then
    command -v openssl >/dev/null 2>&1 || ERRORS+=("openssl is missing: sudo apt-get install -y openssl")
fi

# The database exists once Kuma has started; an admin may still be missing.
FRESH=1
[ -f "$DATA_DIR/data/kuma.db" ] && FRESH=0

if [ "$FRESH" -eq 1 ] && [ "$STORE" -eq 0 ] && ! { true > /dev/tty; } 2>/dev/null; then
    ERRORS+=("No terminal to ask for the admin password, and Kuma has none yet")
    ERRORS+=("  Run this once from a terminal; re-runs after that need none")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

PAGE_URL="http://${LAN_IP:-<this machine>}:${DOOR:-$PORT}"
if [ -n "$DOOR" ]; then
    print_info "Web page:  $PAGE_URL, the console's door to 127.0.0.1:${PORT}"
else
    print_info "Web page:  $PAGE_URL, LAN only"
fi
print_info "Data:      $DATA_DIR/data"
print_success "Pre-flight passed."

# --- Compose file ------------------------------------------------------------
mkdir -p "$DATA_DIR/data"
# kuma.db holds the admin and API key hashes; Kuma runs as root.
chmod 0700 "$DATA_DIR/data"
chmod 0755 "$DATA_DIR"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"

# $1: the address Kuma listens on. 127.0.0.1 until the admin exists.
write_compose() {
    local bind="$1" new
    new="# Generated by add_uptime_kuma.sh. Do not edit by hand: the next run overwrites it.
services:
  uptime-kuma:
    container_name: uptime-kuma
    image: ${IMAGE}
    restart: unless-stopped
    # Host networking, so UFW decides who reaches the port.
    network_mode: host
    environment:
      UPTIME_KUMA_HOST: \"${bind}\"
      UPTIME_KUMA_PORT: \"${PORT}\"
      # Skips Kuma 2's database choice page.
      UPTIME_KUMA_DB_TYPE: sqlite
    volumes:
      - ./data:/app/data"
    if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$new" ]; then
        return 1
    fi
    printf '%s\n' "$new" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
}

# The first start builds the database and can take minutes on a Pi.
wait_for_kuma() {
    local limit=300 start code
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        code="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${PORT}/" 2>/dev/null)" || true
        case "$code" in 200|302) printf '\r\033[K'; return 0 ;; esac
        spin_tick "Waiting for Uptime Kuma, $(( $(date +%s) - start ))s of ${limit}s"
    done
    printf '\r\033[K'
    return 1
}

start_kuma() {
    write_compose "$1" || true
    run_watched "Starting Uptime Kuma" docker compose --project-directory "$DATA_DIR" up -d || {
        print_action "Logs: sudo docker logs uptime-kuma"; exit 1; }
    wait_for_kuma || {
        print_error "Uptime Kuma did not answer within 300s."
        print_action "Logs: sudo docker logs uptime-kuma"; exit 1; }
}

# Kuma's own socket events, spoken by Node inside the container, where
# socket.io-client already ships. The request arrives as JSON on stdin, so a
# password is never an argument or an environment variable.
#   needSetup -> yes|no     setup -> nothing     apikey -> a new key, or EXISTS
KUMA_JS='
const { io } = require("socket.io-client");
const a = JSON.parse(require("fs").readFileSync(0, "utf8"));
const s = io("http://127.0.0.1:" + a.port, { transports: ["websocket"], reconnection: false });
const done = (code, out) => { if (out) process.stdout.write(out + "\n"); s.close(); process.exit(code); };
setTimeout(() => done(3, "no answer within 30s"), 30000);
s.on("connect_error", (e) => done(3, "connect: " + e.message));
let keys = [];
s.on("apiKeyList", (l) => { keys = l || []; });
s.on("connect", () => {
    if (a.action === "needSetup") return s.emit("needSetup", (r) => done(0, r ? "yes" : "no"));
    if (a.action === "setup") return s.emit("setup", a.user, a.pass, (r) => done(r.ok ? 0 : 1, r.ok ? "" : r.msg));
    s.emit("login", { username: a.user, password: a.pass, token: "" }, (r) => {
        if (!r.ok) return done(1, "sign-in refused: " + r.msg);
        if (a.action === "token") return done(0, r.token);
        s.emit("getAPIKeyList", () => {
            if (keys.some((k) => k.name === a.name)) return done(0, "EXISTS");
            s.emit("addAPIKey", { name: a.name, expires: null, active: 1 }, (r) => done(r.ok ? 0 : 1, r.ok ? r.key : r.msg));
        });
    });
});
'
# $1: the request as JSON. Prints Kuma's answer; non-zero when it refused.
kuma_call() {
    printf '%s' "$1" | docker exec -i -w /app uptime-kuma node -e "$KUMA_JS"
}

# A JSON encoder builds the request: a typed password may hold a quote.
kuma_request() {
    printf '%s' "${3:-}" | ACTION="$1" U="${2:-}" KPORT="$PORT" NAME="$KEY_NAME" python3 -c '
import json, os, sys
print(json.dumps({"action": os.environ["ACTION"], "port": os.environ["KPORT"],
                  "name": os.environ["NAME"], "user": os.environ["U"], "pass": sys.stdin.read()}))'
}

if ! run_pull "$IMAGE"; then
    exit 1
fi

# --- Admin account -----------------------------------------------------------
# Kuma without an admin listens on 127.0.0.1 only. A database is no proof of
# an admin, so a running Kuma is asked; anything else starts on loopback.
NEED="yes"
if _is_kuma; then NEED="$(kuma_call "$(kuma_request needSetup)")" || NEED="yes"; fi
if [ "$NEED" = "no" ]; then BIND="$LAN_BIND"; else BIND="127.0.0.1"; fi
start_kuma "$BIND"

# The page answers before the socket takes commands, on a first start by minutes.
if [ "$NEED" != "no" ]; then
    asked=0
    until NEED="$(kuma_call "$(kuma_request needSetup)")"; do
        asked=$((asked + 1))
        if [ "$asked" -ge 6 ]; then
            print_error "Could not ask Kuma whether it has an admin: $NEED"; exit 1
        fi
        print_status "Kuma is still starting; asking again ($asked of 5)."
        sleep 5
    done
    unset asked
fi

ENTRY="Uptime Kuma admin"
API_ENTRY="Uptime Kuma API key"
# $1: the entry. Its password field, or nothing.
entry_pw() {
    secret_entry_get "$1" "" 2>/dev/null | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }'
}
entry_password() { entry_pw "$ENTRY"; }

{ _xt=$-; set +x; } 2>/dev/null
PASSWORD=""
if [ "$NEED" = "yes" ]; then
    # A database without an admin is as open as a fresh one.
    if [ "$BIND" != "127.0.0.1" ]; then BIND="127.0.0.1"; start_kuma "$BIND"; fi
    if [ "$STORE" -eq 1 ]; then
        PASSWORD="$(entry_password)" || PASSWORD=""
        if [ ${#PASSWORD} -ge 12 ]; then
            print_status "Admin password read from the secret store ('$ENTRY')."
        else
            # Stored before Kuma sees it: a password nobody holds is a lockout.
            PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20)7k"
            if printf 'username\ttext\tadmin\npassword\tpassword\t%s\n' "$PASSWORD" \
                    | secret_entry_set "$ENTRY" "" \
               && printf 'Uptime Kuma\t%s\n' "$PAGE_URL" \
                    | secret_entry_urls "$ENTRY" \
               && [ "$(entry_password)" = "$PASSWORD" ]; then
                print_status "New admin password generated and stored in '$ENTRY'."
            else
                PASSWORD=""
                print_error "The secret store did not keep a new password, so it was not used."
            fi
        fi
    fi
    if [ -z "$PASSWORD" ]; then
        if ! { true > /dev/tty; } 2>/dev/null; then
            print_error "No terminal to ask for the admin password instead. Kuma stays on 127.0.0.1."
            exit 1
        fi
        echo ""
        print_action "NEEDED: a password for Uptime Kuma's 'admin' account"
        print_hint "keep it in 1Password as ${HL}${ENTRY}${NC}: the monitor sync signs in with it."
        if ! read_password_twice; then
            print_error "No password given. Kuma stays on 127.0.0.1 until this runs again."
            exit 1
        fi
    fi
    if ! out="$(kuma_call "$(kuma_request setup admin "$PASSWORD")")"; then
        print_error "Kuma refused the admin account: $out"
        exit 1
    fi
    print_success "Admin account 'admin' made."
fi

# --- Sign-in token for the monitor sync --------------------------------------
if [ -z "$PASSWORD" ] && [ "$STORE" -eq 1 ]; then PASSWORD="$(entry_password)" || PASSWORD=""; fi
if [ -z "$PASSWORD" ] && [ "$RENEW_TOKEN" -eq 1 ]; then
    if ! { true > /dev/tty; } 2>/dev/null; then
        print_error "--renew-token needs a terminal to ask the admin password."
        exit 1
    fi
    print_action "NEEDED: Uptime Kuma's admin password, for a new sign-in token"
    read_secret "   Password for admin: " || true
    PASSWORD="${SECRET:-}"; unset SECRET
fi
if [ -n "$PASSWORD" ]; then
    tok=""
    if tok="$(kuma_call "$(kuma_request token admin "$PASSWORD")")" && [ -n "$tok" ]; then
        install -d -m 0700 -o root -g root "$(dirname "$TOKEN_FILE")"
        ( umask 077; printf '%s\n' "$tok" > "$TOKEN_FILE.new" )
        mv -f "$TOKEN_FILE.new" "$TOKEN_FILE"
        print_success "Sign-in token for the monitor sync written to $TOKEN_FILE."
    else
        print_error "Kuma gave no sign-in token${tok:+: $tok}"
        [ "$RENEW_TOKEN" -eq 0 ] || exit 1
    fi
    unset tok
elif [ ! -s "$TOKEN_FILE" ]; then
    print_action "NEEDED: a sign-in token for the monitor sync. Run: sudo $0 --renew-token"
else
    print_info "Sign-in token for the monitor sync already in $TOKEN_FILE."
fi
[[ $_xt == *x* ]] && set -x

if [ "$BIND" != "$LAN_BIND" ]; then
    BIND="$LAN_BIND"
    start_kuma "$BIND"
    [ -n "$DOOR" ] || print_status "Kuma now listens on the LAN."
elif write_compose "$BIND"; then
    start_kuma "$BIND"
else
    print_info "Compose file unchanged."
fi

# --- Firewall ----------------------------------------------------------------
if [ -n "$DOOR" ]; then
    print_info "Behind the console's door on ${DOOR}: no firewall rule of its own."
elif [ "$UFW_ON" -eq 1 ]; then
    if ufw status | grep -qE "^${PORT}/tcp[[:space:]]+ALLOW[[:space:]]+${LAN_CIDR//./\.}([[:space:]]|$)"; then
        print_success "UFW already allows port ${PORT} from $LAN_CIDR."
    elif ufw allow from "$LAN_CIDR" to any port "$PORT" proto tcp >/dev/null 2>&1; then
        print_success "UFW now allows port ${PORT} from $LAN_CIDR."
    else
        print_error "UFW refused the rule, so the LAN cannot reach the page."
        print_action "Add it by hand: sudo ufw allow from $LAN_CIDR to any port ${PORT} proto tcp"
    fi
else
    print_info "UFW is not active: port ${PORT} is reachable from anywhere this machine is."
fi

# --- The metrics key, for Home Assistant and the console ----------------------
# Kuma shows a key once, so it is only made here where it can be kept unseen.
KEY_DONE=0
KEY_LOST=0
if [ "$STORE" -eq 1 ]; then
    { _xt=$-; set +x; } 2>/dev/null
    [ -n "$PASSWORD" ] || PASSWORD="$(entry_password)" || PASSWORD=""
    out=""
    if [ -n "$PASSWORD" ] && out="$(kuma_call "$(kuma_request apikey admin "$PASSWORD")")"; then
        if [ "$out" != "EXISTS" ]; then
            # Read back before trusting it: Kuma never shows this key again.
            if printf 'password\tpassword\t%s\n' "$out" | secret_entry_set "$API_ENTRY" "" \
               && [ "$(entry_pw "$API_ENTRY")" = "$out" ]; then
                print_success "Metrics key made and stored in '$API_ENTRY'."
                KEY_DONE=1
            else
                print_error "The secret store did not keep the new key, and Kuma will not show it again."
                KEY_LOST=1
            fi
        elif [ -n "$(entry_pw "$API_ENTRY")" ]; then
            print_success "Kuma has the key '$KEY_NAME', and '$API_ENTRY' is in the store."
            KEY_DONE=1
        else
            print_error "Kuma has the key '$KEY_NAME', but the store has no '$API_ENTRY'."
            KEY_LOST=1
        fi
    else
        print_error "Could not make the metrics key${out:+: $out}"
    fi
    unset out
    [[ $_xt == *x* ]] && set -x
fi
unset PASSWORD
if [ "$KEY_DONE" -eq 0 ]; then
    print_action "NEEDED: a metrics key, made once on Kuma's page"
    [ "$KEY_LOST" -eq 0 ] || print_hint "  first delete the key ${HL}${KEY_NAME}${NC} there: nobody holds it"
    print_hint "  open ${HL}${PAGE_URL}${NC} and sign in as admin"
    print_hint "  ${HL}Settings > API Keys > Add API Key${NC}, name it ${HL}${KEY_NAME}${NC}, no expiry"
    print_hint "  copy the key into 1Password as ${HL}${API_ENTRY}${NC} (Password item)"
fi

echo ""
if [ "$KEY_DONE" -eq 1 ]; then
    print_success "Uptime Kuma is up on ${PAGE_URL} (LAN only)."
else
    print_success "Uptime Kuma is up on ${PAGE_URL} (LAN only), without a metrics key yet."
fi
