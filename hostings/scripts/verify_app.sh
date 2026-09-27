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
# Does every application row actually RUN?
#
# The sibling of verify_sites.sh, and deliberately the same shape, so the
# orchestration can swap them by row type.
#
#   verify_app.sh                  every application row, every environment
#   verify_app.sh --only-row demo
#
# WHY THIS EXISTS, and it is the thing verify_sites.sh cannot answer here.
#
# verify_sites.sh asks a HOSTNAME for a page. On this machine no name resolves
# until the drive swap, so every deploy prints "Site answered 000000" and
# counts it as fine. An application can therefore be crash-looping and the
# whole pipeline reports success.
#
# This asks the two questions that need no DNS and no certificate:
#
#   1. is the unit active
#   2. does its PORT answer on 127.0.0.1
#
# Both are true or false on this machine today, which is what makes them worth
# asking. An HTTP status is reported but never judged: an API with no root
# route answers 404 and is working perfectly, which is the mistake that rolled
# back ispaddress_api on 2026-08-24.
#
# READ ONLY. Nothing here starts, stops or writes anything.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning".
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

ONLY_ROW=""
while [ $# -gt 0 ]; do
    case "$1" in
        --only-row)    ONLY_ROW="${2:-}"; shift 2 ;;
        --only-row=*)  ONLY_ROW="${1#--only-row=}"; shift ;;
        -h|--help)
            echo "Usage: $0 [--only-row <name>]" >&2
            echo "" >&2
            echo "  Asks every application row's unit and port. Changes nothing." >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    exit 1
fi

trim() {
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
    # A CRLF config leaves a carriage return on the end of every value.
    v="${v//$'\r'/}"
    v="$(trim "${v%%#*}")"
    [ -z "$v" ] && v="${2:-}"
    printf '%s' "$v"
}

conf_rows() {
    grep -v '^[[:space:]]*#' "$SITES_CONF" \
        | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' \
        | grep '|'
}

row_in_env() {
    local list e
    list="$(trim "$1")"
    [ -z "$list" ] && return 0
    IFS=',' read -r -a _re <<< "$list"
    for e in ${_re+"${_re[@]}"}; do
        [ "$(trim "$e")" = "$2" ] && return 0
    done
    return 1
}

IFS=',' read -r -a ENV_LIST <<< "$(conf_get ENVS live)"
for i in "${!ENV_LIST[@]}"; do ENV_LIST[$i]="$(trim "${ENV_LIST[$i]}")"; done
[ -z "${ENV_LIST[0]:-}" ] && ENV_LIST=("live")

print_header "Do the applications run?"

OK=()
DOWN=()
DISABLED=()
NOPORT=()

while IFS='|' read -r type name port path sub ds opts auth repo branch rowenvs users mode runtime enabled owner; do
    type="$(trim "$type")"
    name="$(trim "$name")"
    port="$(trim "$port")"
    rowenvs="$(trim "$rowenvs")"
    # Enabled is the LAST field, so on a CRLF config it carries the carriage
    # return. Stripped here as well as in conf_get, because this one is read
    # from the row rather than from a setting.
    enabled="$(trim "${enabled//$'\r'/}")"

    [ -z "$name" ] && continue
    [ "$type" = "app" ] || continue
    [ -n "$ONLY_ROW" ] && [ "$name" != "$ONLY_ROW" ] && continue

    for env in "${ENV_LIST[@]}"; do
        row_in_env "$rowenvs" "$env" || continue
        env_upper="$(printf '%s' "$env" | tr '[:lower:]' '[:upper:]')"
        suffix="$(conf_get "${env_upper}_UNIT_SUFFIX" "")"
        offset="$(conf_get "${env_upper}_PORT_OFFSET" 0)"
        unit="app-${name}${suffix}.service"

        # A DISABLED ROW IS NOT A FAULT. A stopped unit is exactly what
        # `Enabled = no` asks for, and reporting it red is how a deliberate
        # state gets "fixed" by somebody restarting it.
        if [ "$enabled" = "no" ]; then
            DISABLED+=("$name/$env ($unit, switched off in the config)")
            continue
        fi

        if [ -z "$port" ]; then
            NOPORT+=("$name/$env (no port in the row, so nothing to ask)")
            continue
        fi
        env_port=$((port + offset))

        if ! systemctl is-active --quiet "$unit" 2>/dev/null; then
            state="$(systemctl is-active "$unit" 2>/dev/null || true)"
            DOWN+=("$name/$env: $unit is ${state:-not found}")
            continue
        fi

        # --max-time so a hung application cannot hold the whole verify open.
        # 127.0.0.1 and the port, never a hostname: this is the half that needs
        # no DNS, which is the entire point of this script.
        code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
                 "http://127.0.0.1:${env_port}/" 2>/dev/null || true)"

        # 000 means nothing answered: connection refused, or the port is not
        # listening. Any HTTP code at all means the application replied, and
        # WHICH code is not this script's business.
        if [ -z "$code" ] || [ "$code" = "000" ]; then
            DOWN+=("$name/$env: $unit is active but nothing answers on ${env_port}")
        else
            OK+=("$name/$env: $unit active, ${env_port} answered $code")
        fi
    done
done < <(conf_rows)

for r in ${OK+"${OK[@]}"};             do print_success "$r"; done
for r in ${DISABLED+"${DISABLED[@]}"}; do print_info    "$r"; done
for r in ${NOPORT+"${NOPORT[@]}"};     do print_info    "$r"; done
for r in ${DOWN+"${DOWN[@]}"};         do print_error   "$r"; done

echo ""
if [ ${#OK[@]} -eq 0 ] && [ ${#DOWN[@]} -eq 0 ]; then
    print_info "No application row asked to be checked."
    exit 0
fi

print_status "${#OK[@]} answering, ${#DOWN[@]} not."

if [ ${#DOWN[@]} -gt 0 ]; then
    print_action "Read one with: journalctl -u <unit> -n 50 --no-pager"
    exit 1
fi

print_success "Every application row runs and answers on its own port."
