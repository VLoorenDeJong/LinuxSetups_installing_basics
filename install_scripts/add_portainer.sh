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
# Portainer CE: a web page for managing Docker containers, images, volumes and
# networks.
#
# LOOPBACK ONLY. Portainer mounts the Docker socket, so its admin account can
# do anything root can. It is published on 127.0.0.1 and reached through a
# reverse proxy or a tunnel, never directly: Docker's IPv4 publishes bypass UFW,
# so the bind address is the only real boundary.
#
# THE ADMIN PASSWORD IS SET HERE, NOT ON THE FIRST PAGE VISIT. Otherwise the
# first person to open the page becomes admin. It is handed to Portainer once,
# and the file is deleted as soon as the account exists. A re-run on an
# initialised Portainer asks nothing.
#
# WHERE THE PASSWORD COMES FROM, first match wins:
#   1. a secret store, when a secret_ask.sh is found (SECRET_ASK_SH, or the
#      hostings/scripts/ beside this folder): the login entry "Portainer
#      admin", or a new generated one stored there before Portainer sees it.
#      PORTAINER_URL sets the entry's link; the loopback address otherwise
#   2. the keyboard, when there is no store
#
# Usage:
#   add_portainer.sh
#   add_portainer.sh --port 11006 --data-dir /opt/portainer
#
# Exit codes:
#   0  Portainer is up and answering
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

# Portainer refuses an admin password under 12 characters.
read_password_twice() {
    local p1 p2
    while true; do
        read_secret "   Portainer admin password: " || return 1
        p1="$SECRET"; unset SECRET
        if [ ${#p1} -lt 12 ]; then
            printf "   \033[33mAt least 12 characters: Portainer refuses shorter ones.\033[0m\n" > /dev/tty
            continue
        fi
        read_secret "   Again: " || return 1
        p2="$SECRET"; unset SECRET
        if [ "$p1" = "$p2" ]; then PASSWORD="$p1"; return 0; fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

# --- Arguments ---------------------------------------------------------------
PORT="11006"
DATA_DIR="/opt/portainer"
IMAGE="portainer/portainer-ce:lts"

while [ $# -gt 0 ]; do
    case "$1" in
        --port)     PORT="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --image)    IMAGE="$2"; shift 2 ;;
        -h|--help)  sed -n '18,41p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)          print_error "Unknown argument: $1"; exit 2 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script needs root."
    print_action "Run it with: sudo bash $0"
    exit 2
fi

print_header "Portainer"

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

_is_portainer() { docker ps --format '{{.Names}}' 2>/dev/null | grep -qx portainer; }
if ss -lnt 2>/dev/null | grep -qF "127.0.0.1:${PORT} " && ! _is_portainer; then
    ERRORS+=("Something that is not Portainer already listens on 127.0.0.1:${PORT}")
fi

command -v curl >/dev/null 2>&1 || ERRORS+=("curl is missing: sudo apt-get install -y curl")

# The database only exists once Portainer has made its admin account.
INITIALISED=0
[ -f "$DATA_DIR/data/portainer.db" ] && INITIALISED=1

# Optional. Without it this script asks at the keyboard, as it always did.
STORE=0
for cand in "${SECRET_ASK_SH:-}" "$SCRIPT_DIR/../hostings/scripts/secret_ask.sh"; do
    [ -n "$cand" ] && [ -f "$cand" ] || continue
    # shellcheck source=/dev/null
    . "$cand" 2>/dev/null || true
    [ "${SECRET_READY:-0}" = "1" ] && STORE=1
    break
done

if [ "$INITIALISED" -eq 0 ] && [ "$STORE" -eq 0 ] && ! { true > /dev/tty; } 2>/dev/null; then
    ERRORS+=("No terminal to ask for the admin password, and Portainer has none yet")
    ERRORS+=("  Run this once from a terminal; re-runs after that need none")
fi

if [ ${#ERRORS[@]} -gt 0 ]; then
    print_error "Pre-flight failed, nothing was changed:"
    for e in "${ERRORS[@]}"; do print_error "  $e"; done
    exit 1
fi

print_info "Web page:  http://127.0.0.1:${PORT}, loopback only"
print_info "Data:      $DATA_DIR/data"
if [ "$INITIALISED" -eq 1 ]; then
    print_info "Admin:     already set, so nothing is asked"
elif [ "$STORE" -eq 1 ]; then
    print_info "Admin:     not set yet, its password comes from the secret store"
else
    print_info "Admin:     not set yet, so a password is asked for below"
fi
print_success "Pre-flight passed."

# --- Compose file ------------------------------------------------------------
mkdir -p "$DATA_DIR/data"
chmod 0755 "$DATA_DIR"
COMPOSE_FILE="$DATA_DIR/docker-compose.yml"
SECRET_FILE="$DATA_DIR/admin_password"

write_compose() {
    local with_secret="$1" secret_cmd="" secret_vol=""
    if [ "$with_secret" = "yes" ]; then
        secret_cmd=" --admin-password-file /run/portainer_admin_password"
        secret_vol="      - ./admin_password:/run/portainer_admin_password:ro"
    fi
    local new
    new="$(cat <<EOF
# Generated by add_portainer.sh. Do not edit by hand: the next run overwrites it.
services:
  portainer:
    container_name: portainer
    image: ${IMAGE}
    restart: unless-stopped
    # Plain HTTP on loopback; HTTPS is the reverse proxy's job.
    command: --http-enabled${secret_cmd}
    ports:
      - "127.0.0.1:${PORT}:9000"
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - ./data:/data
${secret_vol}
EOF
)"
    if [ -f "$COMPOSE_FILE" ] && [ "$(cat "$COMPOSE_FILE")" = "$new" ]; then
        return 1
    fi
    printf '%s\n' "$new" > "$COMPOSE_FILE"
    chmod 0644 "$COMPOSE_FILE"
}

wait_for() {
    local what="$1" url="$2" expect="$3" limit=90 start
    start="$(date +%s)"
    while [ $(( $(date +%s) - start )) -lt "$limit" ]; do
        [ "$(curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null)" = "$expect" ] && { printf '\r\033[K'; return 0; }
        spin_tick "Waiting for $what, $(( $(date +%s) - start ))s of ${limit}s"
    done
    printf '\r\033[K'
    return 1
}

if ! run_pull "$IMAGE"; then
    exit 1
fi

# A login entry, not a note: it is what a person opens to sign in by hand.
ENTRY="Portainer admin"
entry_password() {
    secret_entry_get "$ENTRY" "" 2>/dev/null | awk -F'\t' '$1 == "" && $2 == "password" { print $3; exit }'
}
if [ "$INITIALISED" -eq 0 ] && [ "$STORE" -eq 1 ]; then
    PASSWORD="$(entry_password)" || PASSWORD=""
    if [ ${#PASSWORD} -ge 12 ]; then
        print_status "Admin password read from the secret store ('$ENTRY')."
    else
        # Stored before Portainer sees it: a password nobody holds is a lockout.
        PASSWORD="$(openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20)"
        if printf 'username\ttext\tadmin\npassword\tpassword\t%s\n' "$PASSWORD" \
                | secret_entry_set "$ENTRY" "" \
           && printf 'Portainer\t%s\n' "${PORTAINER_URL:-http://127.0.0.1:${PORT}}" \
                | secret_entry_urls "$ENTRY" \
           && [ "$(entry_password)" = "$PASSWORD" ]; then
            print_status "New admin password generated and stored in '$ENTRY'."
        else
            PASSWORD=""
            print_error "The secret store did not keep a new password, so it was not used."
        fi
    fi
fi

if [ "$INITIALISED" -eq 0 ]; then
    if [ -z "${PASSWORD:-}" ]; then
        if ! { true > /dev/tty; } 2>/dev/null; then
            print_error "No terminal to ask for the admin password instead. Nothing was started."
            exit 1
        fi
        echo ""
        print_action "NEEDED: a password for Portainer's 'admin' account"
        if ! read_password_twice; then
            print_error "No password given, so nothing was started."
            exit 1
        fi
    fi
    ( umask 077; printf '%s' "$PASSWORD" > "$SECRET_FILE" )
    unset PASSWORD
    write_compose yes || true
else
    rm -f "$SECRET_FILE"
    if write_compose no; then
        print_status "Wrote $COMPOSE_FILE"
    else
        print_info "Compose file unchanged."
    fi
fi

if ! run_watched "Starting Portainer" docker compose --project-directory "$DATA_DIR" up -d; then
    rm -f "$SECRET_FILE"
    print_action "Logs: sudo docker logs portainer"
    exit 1
fi

if ! wait_for "Portainer to answer" "http://127.0.0.1:${PORT}/api/system/status" 200; then
    rm -f "$SECRET_FILE"
    print_error "Portainer is running but did not answer within 90s."
    print_action "Logs: sudo docker logs portainer"
    exit 1
fi

# --- Drop the password file once the account exists --------------------------
if [ "$INITIALISED" -eq 0 ]; then
    if ! wait_for "the admin account" "http://127.0.0.1:${PORT}/api/users/admin/check" 204; then
        rm -f "$SECRET_FILE"
        print_error "Portainer started but made no admin account."
        print_action "Logs: sudo docker logs portainer"
        exit 1
    fi
    rm -f "$SECRET_FILE"
    write_compose no || true
    run_watched "Restarting without the password file" \
        docker compose --project-directory "$DATA_DIR" up -d || exit 1
    wait_for "Portainer to answer again" "http://127.0.0.1:${PORT}/api/system/status" 200 || {
        print_error "Portainer did not come back after removing the password file."
        print_action "Logs: sudo docker logs portainer"
        exit 1
    }
    print_success "Admin account 'admin' made; the password file is deleted."
fi

# --- This machine's Docker, named after the machine --------------------------
# Portainer calls it "local" on every machine, which says nothing once two
# machines' environments sit side by side. Made here when missing, so the
# first page visit also skips Portainer's "Get started" wizard.
name_environment() {
    local api="http://127.0.0.1:${PORT}/api" host pw jwt id
    host="$(hostname)"
    pw="$(entry_password 2>/dev/null)" || pw=""
    if [ -z "$pw" ]; then
        print_info "No admin password in the secret store, so the environment keeps its name."
        return 0
    fi
    # A typed password may hold a quote or a backslash, so a JSON encoder
    # writes the sign-in, never printf.
    jwt="$(printf '%s' "$pw" \
        | python3 -c 'import json, sys; print(json.dumps({"username": "admin", "password": sys.stdin.read()}))' \
        | curl -s -H 'Content-Type: application/json' --data @- "$api/auth" \
        | sed -n 's/.*"jwt":"\([^"]*\)".*/\1/p')"
    unset pw
    if [ -z "$jwt" ]; then
        print_error "Portainer refused the stored admin password, so the environment keeps its name."
        return 0
    fi
    if curl -s -H "Authorization: Bearer $jwt" "$api/endpoints?name=$host" | grep -q '"Id":'; then
        print_success "Docker environment already named $host."
        return 0
    fi
    id="$(curl -s -H "Authorization: Bearer $jwt" "$api/endpoints?name=local" \
        | grep -o '"Id":[0-9]*' | head -n1 | cut -d: -f2)"
    if [ -n "$id" ]; then
        curl -s -o /dev/null -w '%{http_code}' -X PUT -H "Authorization: Bearer $jwt" \
            -H 'Content-Type: application/json' --data "{\"Name\":\"$host\"}" \
            "$api/endpoints/$id" | grep -q '^200$' \
            && print_success "Docker environment renamed from local to $host." \
            || print_error "Portainer refused the rename; the environment is still called local."
    else
        curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $jwt" \
            -F "Name=$host" -F "EndpointCreationType=1" "$api/endpoints" | grep -q '^200$' \
            && print_success "Docker environment $host added." \
            || print_error "Portainer refused to add this machine's Docker; add it on the first page visit."
    fi
}
[ "$STORE" -eq 1 ] && name_environment

echo ""
print_success "Portainer is up on http://127.0.0.1:${PORT} (loopback only)."
print_info "Reach it from the LAN through a reverse proxy, or over a tunnel:"
print_info "  ssh -L ${PORT}:127.0.0.1:${PORT} <user>@$(hostname)"
