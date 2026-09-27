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
# Move a site from one web builder row to another, through a site bundle.
#
#   upstream_transfer.sh <from-row> <from-env> <to-row> <to-env> [--name <site name>]
#   upstream_transfer.sh --export-pending <row> <env> <old package> <new package>
#   upstream_transfer.sh --import-pending
#
# The last two are the console's builder switch: changing a row's Runtime from
# one upstream package to another exports before add_app_services.sh swaps the
# unit, and imports once the new builder answers.
#
# The bundle (pages as HTML, their CSS, images) is the common ground of every
# builder; each package's upstream/<name>/transfer.py turns its own storage
# into one and back. What a bundle cannot carry, menus, themes, anything
# dynamic, the user redoes in the new builder. The bundle is kept under
# /var/lib/upstream/transfers/ so a transfer can be looked at or repeated.
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

MODE="manual" ARGS=() NAME=""
while [ $# -gt 0 ]; do
    case "$1" in
        --name)           NAME="$2"; shift 2 ;;
        --export-pending) MODE="export-pending"; shift ;;
        --import-pending) MODE="import-pending"; shift ;;
        *) ARGS+=("$1"); shift ;;
    esac
done
case "$MODE:${#ARGS[@]}" in
    manual:4|export-pending:4|import-pending:0) ;;
    *) print_error "Usage: $0 <from-row> <from-env> <to-row> <to-env> [--name <site name>]"
       print_info  "       $0 --export-pending <row> <env> <old package> <new package>   (add_app_services.sh, before a switch)"
       print_info  "       $0 --import-pending                             (after a switch, once the new builder answers)"
       exit 2 ;;
esac

[ "$EUID" -eq 0 ] || { print_error "This needs root: it reads and writes the builders' data."; print_action "sudo bash $0 $*"; exit 2; }
command -v python3 >/dev/null 2>&1 || { print_error "python3 is not installed; the transfer adapters are Python."; exit 1; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
DATA_ROOT_DEFAULT="$(conf_get UPSTREAM_DATA_ROOT /srv/upstream_apps)"
PENDING="/var/lib/upstream/pending"

# Sets PKG, DATA, UNIT, PORT, SECRETS for one row in one environment, the same
# way add_app_services.sh derives them. A third argument names the package
# instead of the row's Runtime: the builder a row is being switched away from.
resolve() {
    local want="$1" env="$2" force_pkg="${3:-}" type name port path sub ds _o _a _r _b envs _u _m runtime _rest
    PKG="" DATA="" UNIT="" PORT="" SECRETS=""
    while IFS='|' read -r type name port path sub ds _o _a _r _b envs _u _m runtime _rest; do
        [ "$(trim "$type")" = "app" ] && [ "$(trim "$name")" = "$want" ] || continue
        runtime="$(trim "$runtime" | tr '[:upper:]' '[:lower:]')"
        case "$runtime" in upstream:*) PKG="${runtime#upstream:}" ;; *) print_error "Row '$want' is not a web builder (Runtime '$runtime')."; return 1 ;; esac
        [ -n "$force_pkg" ] && PKG="$force_pkg"
        ds="$(trim "$ds")"
        case "$ds" in =/*) DATA="${ds#=}" ;; *) DATA="${DATA_ROOT_DEFAULT%/}/${want}/${env}" ;; esac
        DATA="${DATA%/}/${PKG}"
        UNIT="app-${want}$(conf_get "${env^^}_UNIT_SUFFIX" "").service"
        PORT=$(( $(trim "$port") + $(conf_get "${env^^}_PORT_OFFSET" 0) ))
        SECRETS="/etc/upstream/app-${want}$(conf_get "${env^^}_UNIT_SUFFIX" "").env"
        break
    done < <(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|')
    [ -n "$PKG" ] || { print_error "No app row named '$want' in $SITES_CONF."; return 1; }
    [ -f "$REPO_ROOT/hostings/upstream/$PKG/transfer.py" ] || { print_error "$PKG has no transfer adapter (upstream/$PKG/transfer.py)."; return 1; }
    [ -d "$DATA" ] || { print_error "No data folder for $want in $env at $DATA: is the row running there?"; return 1; }
}

# An adapter that talks to its app (Umbraco) gets its local port and secrets.
run_adapter() {
    local verb="$1" pkg="$2" data="$3" port="$4" secrets="$5" unit="$6" bundle="$7" name="${8:-}"
    UPSTREAM_PORT="$port" UPSTREAM_SECRETS="$secrets" UPSTREAM_UNIT="/etc/systemd/system/$unit" \
        python3 "$REPO_ROOT/hostings/upstream/$pkg/transfer.py" "$verb" --data "$data" --bundle "$bundle" ${name:+--name "$name"}
}

recipe_value() { sed -n "s/^[[:space:]]*$2[[:space:]]*=[[:space:]]*//p" "$REPO_ROOT/hostings/upstream/$1/recipe.conf" | head -n1 | tr -d '\r' | xargs; }

import_into() {
    local pkg="$1" data="$2" port="$3" secrets="$4" unit="$5" bundle="$6" name="$7"
    run_adapter import "$pkg" "$data" "$port" "$secrets" "$unit" "$bundle" "$name" || return 1
    # Some builders read their pages once, at start; the recipe says so.
    if [ "$(recipe_value "$pkg" TRANSFER_RESTART)" = "yes" ]; then
        systemctl restart "$unit"
        print_status "Restarted $unit so it reads the new pages."
    fi
}

new_bundle() { local b; b="/var/lib/upstream/transfers/$(date +%Y%m%d-%H%M%S)-$1"; install -d -m 700 "$b"; echo "$b"; }

case "$MODE" in
manual)
    FROM_ROW="${ARGS[0]}" FROM_ENV="${ARGS[1]}" TO_ROW="${ARGS[2]}" TO_ENV="${ARGS[3]}"
    resolve "$FROM_ROW" "$FROM_ENV" || exit 1
    FROM_PKG="$PKG" FROM_DATA="$DATA" FROM_PORT="$PORT" FROM_SECRETS="$SECRETS" FROM_UNIT="$UNIT"
    resolve "$TO_ROW" "$TO_ENV" || exit 1
    NAME="${NAME:-From $FROM_ROW}"
    BUNDLE="$(new_bundle "${FROM_ROW}-to-${TO_ROW}")"
    print_header "$FROM_ROW ($FROM_PKG, $FROM_ENV) → $TO_ROW ($PKG, $TO_ENV)"
    run_adapter export "$FROM_PKG" "$FROM_DATA" "$FROM_PORT" "$FROM_SECRETS" "$FROM_UNIT" "$BUNDLE" \
        || { print_error "Export from $FROM_ROW failed. Nothing was written to $TO_ROW."; exit 1; }
    print_status "Bundle: $BUNDLE ($(find "$BUNDLE/pages" -name '*.html' | wc -l) page(s))"
    import_into "$PKG" "$DATA" "$PORT" "$SECRETS" "$UNIT" "$BUNDLE" "$NAME" \
        || { print_error "Import into $TO_ROW failed. The bundle is kept at $BUNDLE."; exit 1; }
    print_success "Moved to $TO_ROW. Menus, theme and anything dynamic are not carried: set them up there."
    ;;

export-pending)
    # A row's builder is being switched. Export now, while the old one runs;
    # --import-pending finishes it once the new one answers.
    ROW="${ARGS[0]}" ENV_NAME="${ARGS[1]}" OLD="${ARGS[2]}" NEW="${ARGS[3]}"
    resolve "$ROW" "$ENV_NAME" "$OLD" || exit 1
    # Back to a builder this row used before: its site there was kept, so the
    # switch returns to it rather than laying a copy over it.
    if [ -n "$(find "${DATA%/*}/$NEW" -type f -print -quit 2>/dev/null)" ]; then
        print_status "$ROW ($ENV_NAME) goes back to $NEW, whose site was kept. Nothing is moved."
        exit 0
    fi
    BUNDLE="$(new_bundle "${ROW}-${ENV_NAME}-from-${OLD}")"
    run_adapter export "$OLD" "$DATA" "$PORT" "$SECRETS" "$UNIT" "$BUNDLE" \
        || { print_error "Export from $OLD failed for $ROW ($ENV_NAME)."; exit 1; }
    install -d -m 700 "$PENDING"
    printf 'ROW=%s\nENV=%s\nFROM=%s\nBUNDLE=%s\n' "$ROW" "$ENV_NAME" "$OLD" "$BUNDLE" > "$PENDING/${ROW}-${ENV_NAME}"
    print_status "Exported $ROW ($ENV_NAME) from $OLD; it moves in once the new builder answers."
    ;;

import-pending)
    [ -d "$PENDING" ] || exit 0
    for f in "$PENDING"/*; do
        [ -f "$f" ] || continue
        case "$f" in *.done) continue ;; esac
        ROW="$(sed -n 's/^ROW=//p' "$f")" ENV_NAME="$(sed -n 's/^ENV=//p' "$f")"
        FROM="$(sed -n 's/^FROM=//p' "$f")" BUNDLE="$(sed -n 's/^BUNDLE=//p' "$f")"
        resolve "$ROW" "$ENV_NAME" || continue
        if [ "$PKG" = "$FROM" ]; then
            print_info "$ROW ($ENV_NAME) is back on $FROM, where its site still is. Nothing to move."
            mv "$f" "$f.done"; continue
        fi
        if ! systemctl is-active --quiet "$UNIT"; then
            print_info "$ROW ($ENV_NAME) waits for $PKG to run before its site moves in."
            continue
        fi
        wait="$(recipe_value "$PKG" HEALTH_WAIT)"; hpath="$(recipe_value "$PKG" HEALTH_PATH)"
        code="000"
        for _ in $(seq 1 "${wait:-120}"); do
            code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 "http://127.0.0.1:${PORT}${hpath:-/}" || true)"
            [ "$code" != "000" ] && [ "$code" -lt 500 ] && break
            sleep 1
        done
        if [ "$code" = "000" ] || [ "$code" -ge 500 ]; then
            print_info "$ROW ($ENV_NAME): $PKG does not answer yet; the move is retried on the next apply."
            continue
        fi
        # Oqtane and Umbraco answer before their first install has finished.
        sleep 20
        if import_into "$PKG" "$DATA" "$PORT" "$SECRETS" "$UNIT" "$BUNDLE" "From $FROM"; then
            mv "$f" "$f.done"
            print_success "$ROW ($ENV_NAME) moved from $FROM to $PKG. Menus and theme are not carried: set them up there."
        else
            print_error "$ROW ($ENV_NAME): import into $PKG failed; the bundle is kept at $BUNDLE and it is retried on the next apply."
        fi
    done
    ;;
esac
