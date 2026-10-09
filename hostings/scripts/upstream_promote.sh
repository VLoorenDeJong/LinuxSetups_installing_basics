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
# Point one environment of an upstream package at a built version.
#
#   upstream_promote.sh <name>                          what runs where
#   upstream_promote.sh <name> <env> <version|previous>
#
# Every row with Runtime upstream:<name> in <env> runs upstream-<name>:<env>,
# so moving that tag and restarting those rows IS the promotion. Rolling back
# is the same act with an older version, and `previous` finds it in the
# history, so nothing is ever rebuilt or rewritten to go back.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "${s//$'\r'/}"; }
conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=//p" "$SITES_CONF" | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${v:-$2}"
}
recipe_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*$1[[:space:]]*=[[:space:]]*//p" "$RECIPE" | head -n1 | tr -d '\r' | sed 's/[[:space:]]*$//')"
    printf '%s' "${v:-$2}"
}
# Same reading as add_app_services.sh: an empty or `-` Envs is every environment.
row_in_env() {
    local list; list="$(trim "$1")"
    { [ -z "$list" ] || [ "$list" = "-" ]; } && return 0
    local e
    IFS=',' read -ra _envs <<< "$list"
    for e in "${_envs[@]}"; do [ "$(trim "${e%%:*}")" = "$2" ] && return 0; done
    return 1
}

NAME="${1:-}" ENV_NAME="${2:-}" WANT="${3:-}"
[ -n "$NAME" ] || { print_error "Usage: $0 <name> [<env> <version|previous>]"; exit 2; }
[[ "$NAME" =~ ^[a-z0-9_-]+$ ]] || { print_error "'$NAME' is not a package name."; exit 2; }

[ "$EUID" -eq 0 ] || { print_error "This needs root: it retags images and restarts units."; print_action "sudo bash $0 $*"; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
RECIPE="$REPO_ROOT/hostings/upstream/$NAME/recipe.conf"
STATE="/var/lib/upstream/$NAME"

[ -f "$RECIPE" ] || { print_error "No recipe at $RECIPE"; exit 1; }
[ -f "$SITES_CONF" ] || { print_error "No config at $SITES_CONF"; exit 1; }
mkdir -p "$STATE"; touch "$STATE/versions" "$STATE/history"

IFS=',' read -ra ENV_LIST <<< "$(conf_get ENVS live)"
for i in "${!ENV_LIST[@]}"; do ENV_LIST[$i]="$(trim "${ENV_LIST[$i]}")"; done

# --- No environment given: report --------------------------------------------

if [ -z "$ENV_NAME" ]; then
    print_header "$NAME"
    for e in "${ENV_LIST[@]}"; do
        printf '   %-8s %s\n' "$e" "$(cat "$STATE/$e" 2>/dev/null || echo '-')"
    done
    print_info "Built and healthy: $(tr '\n' ' ' < "$STATE/versions")"
    [ -s "$STATE/history" ] && { print_info "Last changes:"; tail -n 5 "$STATE/history" | sed 's/^/   /'; }
    exit 0
fi

known=0
for e in "${ENV_LIST[@]}"; do [ "$e" = "$ENV_NAME" ] && known=1; done
[ "$known" = "1" ] || { print_error "'$ENV_NAME' is not in ENVS ($(conf_get ENVS)) in $SITES_CONF."; exit 1; }
[ -n "$WANT" ] || { print_error "Which version? Give one, or 'previous'."; exit 2; }

CURRENT="$(cat "$STATE/$ENV_NAME" 2>/dev/null || true)"
if [ "$WANT" = "previous" ]; then
    # The newest version this environment ran before the current one.
    WANT="$(awk -v env="$ENV_NAME" -v cur="$CURRENT" '$2 == env && $3 != cur { v = $3 } END { print v }' "$STATE/history")"
    [ -n "$WANT" ] || { print_error "$ENV_NAME has never run anything but ${CURRENT:-nothing}, so there is no previous version."; exit 1; }
fi

grep -qx "$WANT" "$STATE/versions" || {
    print_error "$WANT has not been built and health-checked here."
    print_action "sudo bash $SCRIPT_DIR/upstream_build.sh $NAME $WANT"
    exit 1
}
docker image inspect "upstream-${NAME}:${WANT}" >/dev/null 2>&1 || {
    print_error "The image upstream-${NAME}:${WANT} is gone, although it passed once."
    print_action "sudo bash $SCRIPT_DIR/upstream_build.sh $NAME $WANT --rebuild"
    exit 1
}

# --- Rows that run this package in this environment ---------------------------

ENV_UPPER="${ENV_NAME^^}"
SUFFIX="$(conf_get "${ENV_UPPER}_UNIT_SUFFIX" "")"
OFFSET="$(conf_get "${ENV_UPPER}_PORT_OFFSET" 0)"
UNITS=() PORTS=()
while IFS='|' read -r type name port _p _s _d _o _a _r _b rowenvs _u _m runtime _rest; do
    [ "$(trim "$type")" = "app" ] || continue
    [ "$(trim "$runtime" | tr '[:upper:]' '[:lower:]')" = "upstream:${NAME}" ] || continue
    row_in_env "$rowenvs" "$ENV_NAME" || continue
    UNITS+=("app-$(trim "$name")${SUFFIX}.service")
    PORTS+=("$(( $(trim "$port") + OFFSET ))")
done < <(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|')

print_header "$NAME in $ENV_NAME: ${CURRENT:-nothing} → $WANT"

docker tag "upstream-${NAME}:${WANT}" "upstream-${NAME}:${ENV_NAME}"
echo "$WANT" > "$STATE/$ENV_NAME"
printf '%s %s %s %s\n' "$(date -u +%FT%TZ)" "$ENV_NAME" "$WANT" "${SUDO_USER:-root}" >> "$STATE/history"
print_status "upstream-${NAME}:${ENV_NAME} now points at $WANT"

if [ "${#UNITS[@]}" -eq 0 ]; then
    print_info "No row runs upstream:${NAME} in $ENV_NAME yet, so nothing was restarted."
    exit 0
fi

HPATH="$(recipe_get HEALTH_PATH /)"
HWAIT="$(recipe_get HEALTH_WAIT 120)"
FAILED=()
for i in "${!UNITS[@]}"; do
    u="${UNITS[$i]}" p="${PORTS[$i]}"
    if [ ! -f "/etc/systemd/system/$u" ]; then
        print_info "$u is not written yet; the next apply starts it on $WANT."
        continue
    fi
    systemctl enable "$u" >/dev/null 2>&1 || true
    systemctl restart "$u"
    code="000"
    for _ in $(seq 1 "$HWAIT"); do
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${p}${HPATH}" || true)"
        [ "$code" != "000" ] && break
        sleep 1
    done
    if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
        print_error "$u did not answer on 127.0.0.1:$p (HTTP $code)."
        FAILED+=("$u")
    else
        print_status "$u answers on 127.0.0.1:$p with HTTP $code"
    fi
done

# A row switched to this package in the console waits for it to run.
if [ -n "$(ls /var/lib/upstream/pending 2>/dev/null | grep -v "\.done$")" ]; then
    bash "$SCRIPT_DIR/upstream_transfer.sh" --import-pending || true
fi

if [ "${#FAILED[@]}" -gt 0 ]; then
    print_error "${#FAILED[@]} of ${#UNITS[@]} rows did not come back on $WANT."
    print_action "Go back: sudo bash $0 $NAME $ENV_NAME previous"
    exit 1
fi
print_success "${#UNITS[@]} row(s) in $ENV_NAME run $NAME $WANT."
