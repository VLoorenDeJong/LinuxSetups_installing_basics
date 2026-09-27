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
# Build a Docker application row's image from its checkout and restart it.
#
#   deploy_docker_app.sh <row> <checkout-dir> <env>
#
# Item 140. The row's Path names the Dockerfile inside the repository. The
# unit add_app_services.sh wrote runs app-<row><suffix>:latest on
# 127.0.0.1:<port>, and waits for the .built marker this script writes.
#
# Root, through one sudo grant, never the docker group. The build runs the
# repository's Dockerfile, so whoever can push to that repository decides what
# the build does; the same is already true of every dotnet app deployed here.
# =============================================================================

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

ROW="${1:-}"
SRC="${2:-}"
ENV_NAME="${3:-}"
if [ -z "$ROW" ] || [ -z "$SRC" ] || [ -z "$ENV_NAME" ]; then
    print_error "Usage: $0 <row> <checkout-dir> <env>"
    exit 2
fi
if [ "$EUID" -ne 0 ]; then
    print_error "This needs root: it builds and restarts containers."
    exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active /etc/hostings)}"
WORKSPACE_ROOT="/var/lib/jenkins/workspace"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s//$'\r'/}"; }
conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$SITES_CONF" | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${v:-$2}"
}

SRC="$(realpath -e "$SRC" 2>/dev/null)" || { print_error "No such directory: $2"; exit 2; }
case "$SRC/" in
    "$WORKSPACE_ROOT"/*) ;;
    *) print_error "Refusing $SRC: only a checkout inside $WORKSPACE_ROOT is built."; exit 2 ;;
esac

PORT="" REL="" RUNTIME=""
while IFS='|' read -r type name port path _s _d _o _a _r _b _e _u _m runtime _rest; do
    [ "$(trim "$type")" = "app" ] || continue
    [ "$(trim "$name")" = "$ROW" ] || continue
    PORT="$(trim "$port")"; REL="$(trim "$path")"; RUNTIME="$(trim "$runtime")"
    break
done < <(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|')

[ -n "$PORT" ] || { print_error "No app row named '$ROW' in $SITES_CONF"; exit 1; }
case "${RUNTIME,,}" in
    docker|docker_*) ;;
    *) print_error "Row '$ROW' is not a Docker application (its type is '$RUNTIME')."; exit 1 ;;
esac
case "$REL" in
    ""|/*|*..*) print_error "Row '$ROW' Path must be a relative path to its Dockerfile, not '$REL'"; exit 1 ;;
esac
[ -f "$SRC/$REL" ] || { print_error "No $REL in the repository."; print_action "Add a Dockerfile, or fix the row's Path."; exit 1; }

ENV_UPPER="${ENV_NAME^^}"
APP_ROOT="$(conf_get "APP_ROOT_${ENV_UPPER}" "")"
SUFFIX="$(conf_get "${ENV_UPPER}_UNIT_SUFFIX" "")"
OFFSET="$(conf_get "${ENV_UPPER}_PORT_OFFSET" 0)"
[ -n "$APP_ROOT" ] || { print_error "No APP_ROOT_${ENV_UPPER} in $SITES_CONF"; exit 1; }
PORT=$((PORT + OFFSET))
IMAGE="app-${ROW,,}${SUFFIX}"
UNIT="app-${ROW}${SUFFIX}.service"
MARKER="${APP_ROOT%/}/.docker/${IMAGE}.built"

print_header "Deploying $ROW ($ENV_NAME) as a container"
print_info "Image: ${IMAGE}:latest, from $REL"
print_info "Unit:  $UNIT, on 127.0.0.1:$PORT"

print_status "docker build"
if ! docker build -t "${IMAGE}:latest" -f "$SRC/$REL" "$(dirname "$SRC/$REL")"; then
    print_error "The image did not build, so the running container was left alone."
    exit 1
fi
mkdir -p "$(dirname "$MARKER")"
date -u +%FT%TZ > "$MARKER"
print_success "Built ${IMAGE}:latest"

if [ ! -f "/etc/systemd/system/$UNIT" ]; then
    print_error "No $UNIT yet, so the container cannot be started."
    print_action "Run the apply job, or: sudo bash $SCRIPT_DIR/add_app_services.sh"
    exit 1
fi
systemctl enable "$UNIT" >/dev/null 2>&1 || true
systemctl restart "$UNIT"

code="000"
for _ in $(seq 1 60); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}/" || true)"
    [ "$code" != "000" ] && break
    sleep 1
done
if [ "$code" = "000" ]; then
    print_error "The container started but nothing answered on 127.0.0.1:$PORT within 60 s."
    print_action "Logs: sudo journalctl -u $UNIT -n 50"
    print_info "The app must listen on port 8080 inside the container."
    exit 1
fi
print_success "$ROW ($ENV_NAME) answers on 127.0.0.1:$PORT with HTTP $code."
docker image prune -f >/dev/null 2>&1 || true
