#!/usr/bin/env bash
set -o pipefail

# =============================================================================
# Run a 1Password Connect server on this machine, on loopback, so saves go to a
# local cache instead of spending the service account's 100 writes an hour.
# login-store-decisions.md, decision 9.
#
#   sudo bash add_1password_connect.sh              install or refresh, test
#   sudo bash add_1password_connect.sh --test-only  test what is running
#
# ASKS NOTHING. The Connect credentials file and its access token are fetched
# from OP_CONNECT_VAULT with the service account add_1password.sh installed,
# which is why this runs after it. That vault is read-only to the service
# account, and the Connect server itself is never given it.
#
# Two containers, 1Password's documented pair: connect-api answers on
# 127.0.0.1:OP_CONNECT_PORT, connect-sync keeps the cache in step with
# 1Password.com. They share one volume. Nothing outside this machine reaches
# either, so no UFW rule and no Apache door.
#
# What Connect CANNOT do, so the service account stays: write a Document, and
# share an item. See secret_store_1password_connect.sh.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
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

TEST_ONLY=0
[ "${1:-}" = "--test-only" ] && TEST_ONLY=1

if [ "$EUID" -ne 0 ]; then
    print_error "This writes root-only credentials and starts containers, so it needs root."
    print_action "Run: sudo bash $0 $*"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local key="$1" def="$2" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}

OP_VAULT="$(conf_get OP_VAULT '')"
OP_TOKEN_FILE="$(conf_get OP_TOKEN_FILE /root/.op_service_account_token)"
CRED_VAULT="$(conf_get OP_CONNECT_VAULT '')"
CRED_ITEM="$(conf_get OP_CONNECT_CREDENTIALS_ITEM '')"
TOKEN_ITEM="$(conf_get OP_CONNECT_TOKEN_ITEM '')"
PORT="$(conf_get OP_CONNECT_PORT 11004)"
CONNECT_TOKEN_FILE="$(conf_get OP_CONNECT_TOKEN_FILE /root/.op_connect_token)"
# Its own name per config, so a TEST Connect runs beside live's.
PROJECT="$(conf_get OP_CONNECT_NAME op-connect)"
DIR="/etc/$PROJECT"

LOG="$(mktemp)"
trap 'spinner_stop; rm -f "$LOG"' EXIT

# Encrypted to this host. A plain file is still read: one written before the
# tokens were encrypted, or by a first clone without systemd-creds.
token_file_read() {  # <file> <credential name>
    local t
    t="$(systemd-creds decrypt --name="$2" "$1" - 2>/dev/null)" \
        || t="$(grep -m1 -E '^(ops_|eyJ)' "$1" 2>/dev/null)" || return 2
    printf '%s' "$t" | tr -d '[:space:]'
}

# The service account's token in the environment of one command only.
op_sa() {
    local token
    token="$(token_file_read "$OP_TOKEN_FILE" op-token)" || return 2
    OP_SERVICE_ACCOUNT_TOKEN="$token" timeout 30 op "$@"
}

# The Connect token as a header file, never as an argument: argv shows in `ps`.
connect_get() {
    curl -fsS --max-time 10 -H @<(printf 'Authorization: Bearer %s' "$(token_file_read "$CONNECT_TOKEN_FILE" op-connect-token)") \
         "http://127.0.0.1:${PORT}$1"
}

test_connect() {
    local vaults
    spinner_start "Waiting for Connect to answer on 127.0.0.1:${PORT}..."
    for _ in $(seq 1 30); do
        curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/heartbeat" >/dev/null 2>&1 && break
        sleep 2
    done
    spinner_stop
    if ! curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/heartbeat" >/dev/null 2>&1; then
        print_error "Connect does not answer on 127.0.0.1:${PORT}."
        print_action "Look at: sudo docker compose -p $PROJECT logs --tail 30"
        return 1
    fi
    if ! vaults="$(connect_get /v1/vaults | jq -r '.[].name')"; then
        print_error "Connect answers, but the token in $CONNECT_TOKEN_FILE is refused."
        return 1
    fi
    local want
    for want in "$OP_VAULT" "$(conf_get OP_VAULT_USERS "$OP_VAULT")" "$(conf_get OP_VAULT_MAIL "$OP_VAULT")" \
                "$(conf_get OP_VAULT_SYSTEM "$OP_VAULT")" "$(conf_get OP_VAULT_KEYS "$OP_VAULT")"; do
        printf '%s\n' "$vaults" | grep -qxF "$want" && continue
        print_error "Connect cannot see '$want'. It sees: ${vaults:-nothing}"
        print_action "Give the Connect server that vault on 1password.com."
        return 1
    done
    if printf '%s\n' "$vaults" | grep -qxF "$CRED_VAULT"; then
        print_error "Connect can see '$CRED_VAULT', which holds its own credentials."
        print_action "Remove that vault from the Connect server on 1password.com."
        return 1
    fi
    print_success "Connect answers on 127.0.0.1:${PORT} and sees its vaults, not '$CRED_VAULT'."
}

print_header "1Password Connect"

if [ "$TEST_ONLY" = "1" ]; then
    test_connect
    exit $?
fi

MISSING=()
command -v docker >/dev/null 2>&1   || MISSING+=("Docker is not installed. Run: sudo bash add_docker.sh")
command -v op >/dev/null 2>&1       || MISSING+=("op is not installed. Run: sudo bash add_1password.sh")
command -v jq >/dev/null 2>&1       || MISSING+=("jq is not installed. Run: sudo apt-get install -y jq")
command -v systemd-creds >/dev/null 2>&1 || MISSING+=("systemd-creds is missing, so the Connect token cannot be encrypted. It ships with systemd 250+.")
[ -r "$OP_TOKEN_FILE" ]             || MISSING+=("No service account token at $OP_TOKEN_FILE. Run: sudo bash add_1password.sh")
[ -n "$OP_VAULT" ]                  || MISSING+=("No OP_VAULT in $SITES_CONF")
[ -n "$CRED_VAULT" ] && [ -n "$CRED_ITEM" ] && [ -n "$TOKEN_ITEM" ] \
    || MISSING+=("OP_CONNECT_VAULT, OP_CONNECT_CREDENTIALS_ITEM and OP_CONNECT_TOKEN_ITEM must all be set in $SITES_CONF")
if [ ${#MISSING[@]} -gt 0 ]; then
    for m in "${MISSING[@]}"; do print_error "$m"; done
    exit 1
fi

umask 077
install -d -m 0700 "$DIR"

# The credentials file goes to the containers as OP_SESSION, base64, so no
# file inside them needs an owner that matches the image's opuser.
print_status "Fetching the Connect credentials from '$CRED_VAULT'"
if ! CRED_B64="$(op_sa document get "$CRED_ITEM" --vault "$CRED_VAULT" 2>"$LOG" | base64 -w0)" \
   || [ -z "$CRED_B64" ]; then
    print_error "Could not read '$CRED_ITEM' from '$CRED_VAULT':"
    tail -5 "$LOG"
    exit 1
fi
printf 'OP_SESSION=%s\n' "$CRED_B64" > "$DIR/connect.env.new" && mv "$DIR/connect.env.new" "$DIR/connect.env"
unset CRED_B64

print_status "Fetching the Connect access token"
if ! TOKEN="$(op_sa item get "$TOKEN_ITEM" --vault "$CRED_VAULT" --fields label=credential --reveal 2>"$LOG")" \
   || [ -z "$TOKEN" ]; then
    print_error "Could not read the credential field of '$TOKEN_ITEM':"
    tail -5 "$LOG"
    exit 1
fi
# On stdin, so the plain token never lands on disk.
rm -f "$CONNECT_TOKEN_FILE.new"
if ! printf '%s' "$TOKEN" | systemd-creds encrypt --name=op-connect-token - "$CONNECT_TOKEN_FILE.new" 2>"$LOG"; then
    rm -f "$CONNECT_TOKEN_FILE.new"
    print_error "systemd-creds could not encrypt the Connect token:"
    tail -3 "$LOG"
    exit 1
fi
chmod 0600 "$CONNECT_TOKEN_FILE.new"
mv -f "$CONNECT_TOKEN_FILE.new" "$CONNECT_TOKEN_FILE"
unset TOKEN

cat > "$DIR/compose.yml" <<YAML
# Written by add_1password_connect.sh. Loopback only.
services:
  connect-api:
    image: 1password/connect-api:latest
    ports: ["127.0.0.1:${PORT}:8080"]
    env_file: connect.env
    volumes: ["data:/home/opuser/.op/data"]
    restart: unless-stopped
  connect-sync:
    image: 1password/connect-sync:latest
    env_file: connect.env
    volumes: ["data:/home/opuser/.op/data"]
    restart: unless-stopped
volumes:
  data:
YAML

spinner_start "Starting the Connect containers..."
if ! docker compose -p "$PROJECT" -f "$DIR/compose.yml" up -d --pull always --force-recreate > "$LOG" 2>&1; then
    spinner_stop
    print_error "docker compose could not start Connect:"
    tail -20 "$LOG"
    exit 1
fi
spinner_stop
print_status "Started $PROJECT from $DIR/compose.yml"

test_connect
