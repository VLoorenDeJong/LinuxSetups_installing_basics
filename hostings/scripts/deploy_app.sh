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
# Deploy one published ASP.NET app and prove it came back up.
#
# Called by a Jenkinsfile, but it is a normal script and running it by hand is
# the expected way to learn it and to recover when a pipeline breaks:
#
#   ./deploy_app.sh mvp_portfolio ./out
#
# The deploy logic lives here, in git, rather than inside a Jenkins job. A job
# config is not reviewed, not versioned with the app, and is lost with the
# Jenkins instance. This file survives all three.
#
# What it does, in order:
#   1. Look the app up in hostings.conf, so the target directory and the port are
#      never passed in and never wrong.
#   2. Snapshot the current deploy.
#   3. rsync the new build into place.
#   4. Restart the unit.
#   5. Health check the port.
#   6. On any failure after step 2, restore the snapshot and restart again.
#
# Step 6 is the reason this exists. A hand deploy that half works leaves the
# site down until someone notices. This puts it back within seconds.
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

usage() {
    echo "Usage: $0 <app-name> <source-dir> [env]" >&2
    echo "" >&2
    echo "  app-name    an app row name from hostings.conf, e.g. mvp_portfolio" >&2
    echo "  source-dir  the output of dotnet publish" >&2
    echo "  env         an environment from ENVS. Defaults to the first, the live one." >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SITES_CONF     override the config location" >&2
    echo "  HEALTH_PATH    path to health check, default /" >&2
    echo "  HEALTH_TIMEOUT seconds to wait for the app, default 60" >&2
    echo "  SKIP_HEALTH=1  deploy without verifying, and without rollback" >&2
    exit 1
}

APP_NAME="${1:-}"
SOURCE_DIR="${2:-}"
ENV_NAME="${3:-}"

[ -z "$APP_NAME" ] && usage
[ -z "$SOURCE_DIR" ] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
HEALTH_PATH="${HEALTH_PATH:-/}"
HEALTH_TIMEOUT="${HEALTH_TIMEOUT:-60}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Site config not found: $SITES_CONF"
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim rather than sourced, so this script stays
# runnable on its own on a machine that has only this file copied to it.
# -----------------------------------------------------------------------------
# Memoised: this is called once per key per row per environment, and each
# uncached call forks four processes. Without the cache a pre-flight on a
# ten row config spends most of its time in fork rather than doing anything.
declare -A _CONF_CACHE=()
conf_get() {
    local key="$1" default="$2" value
    if [ -n "${_CONF_CACHE[$key]+set}" ]; then
        value="${_CONF_CACHE[$key]}"
    else
        value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" | head -n 1)"
        # tr -d '\r': xargs does not strip a carriage return, and a value is
        # the last thing on its line, so a CRLF config leaves one in it.
        value="$(echo "$value" | tr -d '\r' | sed 's/#.*//' | xargs)"
        _CONF_CACHE[$key]="$value"
    fi
    echo "${value:-$default}"
}

conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# A field holding a single dash means empty. `| | |` cannot be counted by eye.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

# -----------------------------------------------------------------------------
# Which environment. Defaults to the first in ENVS, which is the live one, so an
# existing Jenkinsfile that passes two arguments keeps deploying to production
# exactly as before.
# -----------------------------------------------------------------------------
IFS=',' read -r -a ALL_ENVS <<< "$(conf_get ENVS live)"
if [ -z "$ENV_NAME" ]; then
    ENV_NAME="$(trim "${ALL_ENVS[0]}")"
fi

ENV_KNOWN=0
for e in "${ALL_ENVS[@]}"; do
    [ "$(trim "$e")" = "$ENV_NAME" ] && ENV_KNOWN=1
done
if [ "$ENV_KNOWN" -ne 1 ]; then
    print_error "'$ENV_NAME' is not in ENVS."
    print_info "Known environments: $(conf_get ENVS live)"
    exit 1
fi

ENV_UPPER="$(echo "$ENV_NAME" | tr '[:lower:]' '[:upper:]')"
APP_ROOT="$(conf_get "APP_ROOT_${ENV_UPPER}" "")"
UNIT_SUFFIX="$(conf_get "${ENV_UPPER}_UNIT_SUFFIX" "")"
PORT_OFFSET="$(conf_get "${ENV_UPPER}_PORT_OFFSET" 0)"

if [ -z "$APP_ROOT" ]; then
    print_error "No APP_ROOT_${ENV_UPPER} in $SITES_CONF"
    exit 1
fi

if [ ! -d "$SOURCE_DIR" ]; then
    print_error "Source directory does not exist: $SOURCE_DIR"
    exit 1
fi

# An empty publish directory would rsync --delete the live app into nothing.
# This check is the difference between a failed build and an outage.
if [ -z "$(ls -A "$SOURCE_DIR" 2>/dev/null)" ]; then
    print_error "Source directory is empty: $SOURCE_DIR"
    print_action "Refusing to deploy. Did the build actually produce anything?"
    exit 1
fi

# -----------------------------------------------------------------------------
# Resolve the app from the config. The caller names the app, never the paths:
# a mistyped target directory is how you deploy one app over another.
# -----------------------------------------------------------------------------
REL_DLL=""
PORT=""
ROW_ENVS=""
ROW_BRANCH=""
ROW_RUNTIME=""
ROW_ENABLED="yes"
while IFS='|' read -r type name port path subdomain datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
    [ "$(trim "$type")" != "app" ] && continue
    [ "$(trim "$name")" != "$APP_NAME" ] && continue
    PORT="$(trim "$port")"
    REL_DLL="$(trim "$path")"
    ROW_ENVS="$(trim "$rowenvs")"
    ROW_BRANCH="$(trim "$branch")"
    ROW_RUNTIME="$(echo "$runtime" | xargs | tr '[:upper:]' '[:lower:]')"
    # trim, not xargs: this is the last field on the line, so it is the one a
    # carriage return reaches, and xargs leaves the CR in place.
    ROW_ENABLED="$(trim "$enabled")"
    ROW_ENABLED="${ROW_ENABLED,,}"
    [ -z "$ROW_ENABLED" ] && ROW_ENABLED="yes"
    break
done < <(conf_rows)

if [ -z "$REL_DLL" ]; then
    print_error "No app row named '$APP_NAME' in $SITES_CONF"
    print_info "Known apps:"
    while IFS='|' read -r type name port path subdomain datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
        [ "$(trim "$type")" != "app" ] && continue
        name="$(trim "$name")"
        [ -n "$name" ] && print_info "  - $name"
    done < <(conf_rows)
    exit 1
fi

# A row can be limited to certain environments: the four progress tenants are
# live only, and one mvp_progress row covers test. Deploying to an environment a
# row does not exist in would create a directory with no unit and no vhost, so
# it is refused rather than silently producing one.
if [ -n "$ROW_ENVS" ]; then
    IN_ENV=0
    IFS=',' read -r -a ROW_ENV_LIST <<< "$ROW_ENVS"
    for e in "${ROW_ENV_LIST[@]}"; do
        [ "$(echo "$e" | xargs)" = "$ENV_NAME" ] && IN_ENV=1
    done
    if [ "$IN_ENV" -ne 1 ]; then
        print_error "'$APP_NAME' does not exist in the '$ENV_NAME' environment."
        print_info "Its Envs field lists: $ROW_ENVS"
        exit 1
    fi
fi

# The branch this environment deploys from, unless the row overrides it. The
# demo instance is why the override exists: a demo should not change every time
# a customer fix ships.
DEPLOY_BRANCH="${ROW_BRANCH:-$(conf_get "${ENV_UPPER}_BRANCH" "$ENV_NAME")}"

# The row carries a path relative to the environment's app root and the port of
# the FIRST environment. Everything else derives, which is what lets one row
# serve every environment without a second column of ports and paths.
TARGET_DLL="${APP_ROOT%/}/${REL_DLL#/}"
PORT=$((PORT + PORT_OFFSET))
TARGET_DIR="$(dirname "$TARGET_DLL")"
DLL_NAME="$(basename "$TARGET_DLL")"
UNIT="app-${APP_NAME}${UNIT_SUFFIX}.service"

# The build has to contain the dll the unit will try to run. Without this the
# deploy succeeds, the restart succeeds, and the app dies on startup with a
# message nobody reads.
if [ ! -f "$SOURCE_DIR/$DLL_NAME" ]; then
    print_error "$DLL_NAME is not in $SOURCE_DIR"
    print_action "The unit runs $TARGET_DLL, so the build must contain $DLL_NAME."
    print_info "Found instead:"
    ls -1 "$SOURCE_DIR"/*.dll 2>/dev/null | head -n 10 | while read -r f; do
        print_info "  - $(basename "$f")"
    done
    exit 1
fi

# -----------------------------------------------------------------------------
# Does this machine have the runtime the build asks for?
#
# Nothing named a .NET version anywhere in this repo's config, and nothing needs
# to: `dotnet <app>.dll` reads the version out of the build's own
# runtimeconfig.json and picks a matching installed runtime. So the version is
# never typed, only checked.
#
# Without this check a .NET 10 build onto a box carrying only 8 deploys clean,
# restarts clean, and dies at startup. The unit then crash loops, which is
# exactly the failure that went unnoticed for weeks before the status publisher
# existed.
#
# Parsed with grep and sed rather than jq: jq is not a dependency of this repo
# and a deploy must not fail for want of a JSON parser.
# -----------------------------------------------------------------------------
RUNTIME_CONFIG="$SOURCE_DIR/${DLL_NAME%.dll}.runtimeconfig.json"

check_dotnet_runtime() {
    local want_name want_ver want_mm want_patch have best_patch=-1

    if [ ! -f "$RUNTIME_CONFIG" ]; then
        print_info "No $(basename "$RUNTIME_CONFIG") in the build, so the required .NET version could not be checked."
        return 0
    fi

    # A self-contained build ships its own runtime under `includedFrameworks`
    # and needs nothing installed. Checked FIRST and by its own key: that block
    # also holds a name and a version, so reading the first of each in the file
    # would check a self-contained build against runtimes it does not use.
    if grep -q '"includedFrameworks"' "$RUNTIME_CONFIG"; then
        print_status "The build is self-contained, so it carries its own runtime. Nothing to check."
        return 0
    fi

    # Everything after the framework key, so the name and version read here
    # cannot come from some other object. Works on minified JSON too, which is
    # what a publish actually produces.
    local frag
    frag="$(tr -d '\n' < "$RUNTIME_CONFIG" | sed 's/.*"frameworks\?"[[:space:]]*:[[:space:]]*//')"
    want_name="$(printf '%s' "$frag" | grep -o '"name"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    want_ver="$(printf '%s' "$frag" | grep -o '"version"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"\([^"]*\)"$/\1/')"
    if [ -z "$want_name" ] || [ -z "$want_ver" ]; then
        print_info "Could not read a framework out of $(basename "$RUNTIME_CONFIG"), so the .NET version was not checked."
        return 0
    fi

    # The WHOLE version, not just the last part. A preview reads 9.0.0-preview.1,
    # whose suffix lands in the minor rather than the patch, so checking only the
    # last field let it through and then reported a framework called
    # "9.0.0-preview" as missing.
    case "$want_ver" in
        [0-9]*.[0-9]*.[0-9]*) ;;
        *)
            print_info "This build asks for $want_name $want_ver, which is not a plain x.y.z version, so it was not checked."
            return 0
            ;;
    esac
    case "$want_ver" in
        *[!0-9.]*)
            print_info "This build asks for $want_name $want_ver, a preview or release candidate, so it was not checked."
            return 0
            ;;
    esac

    want_mm="${want_ver%.*}"
    want_patch="${want_ver##*.}"

    # Every installed patch of the same major.minor. A framework rolls forward
    # to a HIGHER patch, never back, and never to another major on its own.
    while read -r have; do
        [ -z "$have" ] && continue
        [ "$have" -gt "$best_patch" ] 2>/dev/null && best_patch="$have"
    done < <(dotnet --list-runtimes 2>/dev/null \
             | awk -v n="$want_name" -v mm="$want_mm" '$1 == n && index($2, mm ".") == 1 { sub(/^.*\./, "", $2); print $2 }')

    if [ "$best_patch" -lt 0 ]; then
        print_error "This build needs $want_name $want_mm, which is not installed."
        print_info "Installed runtimes:"
        dotnet --list-runtimes 2>/dev/null | sed 's/^/     /' || print_info "     (dotnet --list-runtimes said nothing)"
        print_action "Install it: sudo env DOTNET_VERSIONS=${want_mm%%.*} bash LinuxBasics/install_scripts/add_dotnet.sh"
        return 1
    fi

    if [ "$best_patch" -lt "$want_patch" ]; then
        print_error "This build needs $want_name $want_ver, and the newest installed is $want_mm.$best_patch."
        print_info "A framework rolls forward to a higher patch, never back to a lower one."
        return 1
    fi

    print_status "Runtime: needs $want_name $want_ver, this machine has $want_mm.$best_patch"
    return 0
}

if [ "${ROW_RUNTIME:-dotnet}" != "node" ] && [ "${ROW_RUNTIME}" != "-" ]; then
    check_dotnet_runtime || exit 1
fi

print_header "Deploying $APP_NAME ($ENV_NAME)"
print_status "From:  $SOURCE_DIR"
print_status "To:    $TARGET_DIR"
print_status "Unit:  $UNIT"
print_status "Port:  $PORT"
print_status "Branch: $DEPLOY_BRANCH"

# -----------------------------------------------------------------------------
# Customer data living inside the deploy target.
#
# This is not hypothetical. The live appsettings.json points both
# BackendDatabaseFolderLocation and FrontendDatabaseFolderLocation at
# wwwroot/databases under running_csharp_projects, which is exactly where this
# script rsyncs. Without the excludes below, deploying the backoffice deletes
# the master CSVs, and deploying the portfolio deletes what the backoffice
# pushed into it.
#
# The excludes are anchored with a leading slash, so they match only at the
# root of the deploy and cannot accidentally spare a build directory of the
# same name nested deeper.
#
# The real fix is to move this data outside the deploy path entirely and point
# appsettings at it. Until that has been done on the machine, these excludes
# are the only thing standing between a deploy and a customer's data.
#
# Override for an app that stores data elsewhere:
#   DATA_DIRS="wwwroot/uploads" ./deploy_app.sh <app> <dir>
# -----------------------------------------------------------------------------
if [ -n "${DATA_DIRS:-}" ]; then
    read -r -a DATA_DIR_LIST <<< "$DATA_DIRS"
else
    IFS=',' read -r -a DATA_DIR_LIST <<< "$(conf_get DATA_DIRS "wwwroot/databases, wwwroot/project_photos")"
    for i in "${!DATA_DIR_LIST[@]}"; do
        DATA_DIR_LIST[$i]="$(trim "${DATA_DIR_LIST[$i]}")"
    done
fi

RSYNC_EXCLUDES=()
for data_dir in "${DATA_DIR_LIST[@]}"; do
    RSYNC_EXCLUDES+=(--exclude "/${data_dir}/")
done

print_status "Protected from deploy: ${DATA_DIR_LIST[*]}"

# -----------------------------------------------------------------------------
# Snapshot. Kept next to the target rather than in /tmp, so it survives a
# reboot and so it is on the same filesystem.
#
# Code only: the data directories are excluded. A snapshot containing data
# would make rollback roll the data backwards too, silently discarding
# everything written since the last deploy. Rollback restores code and leaves
# data exactly where it is.
# -----------------------------------------------------------------------------
BACKUP_DIR="${TARGET_DIR}.previous"
ROLLBACK_POSSIBLE=0

if [ -d "$TARGET_DIR" ] && [ -n "$(ls -A "$TARGET_DIR" 2>/dev/null)" ]; then
    print_status "Snapshotting the current deploy..."
    rm -rf "$BACKUP_DIR"
    mkdir -p "$BACKUP_DIR"
    if ! rsync -a "${RSYNC_EXCLUDES[@]}" "$TARGET_DIR"/ "$BACKUP_DIR"/; then
        print_error "Could not snapshot $TARGET_DIR, refusing to deploy without a rollback."
        exit 1
    fi
    ROLLBACK_POSSIBLE=1
    print_success "Snapshot at $BACKUP_DIR"
else
    print_info "Nothing deployed here yet, so there is nothing to roll back to."
    mkdir -p "$TARGET_DIR"
fi

rollback() {
    if [ "$ROLLBACK_POSSIBLE" -ne 1 ]; then
        print_error "No snapshot exists, so no rollback is possible."
        print_action "The app is down. Deploy a known good build by hand."
        return 1
    fi
    print_info "Rolling back to the previous deploy..."
    # rsync rather than rm -rf plus mv: the target holds live customer data in
    # the excluded directories, and a rename would take it with it. This
    # restores the old code and leaves the data untouched.
    if ! rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$BACKUP_DIR"/ "$TARGET_DIR"/; then
        print_error "Rollback failed to restore $TARGET_DIR from $BACKUP_DIR."
        print_info "The previous build is still intact at $BACKUP_DIR, restore it by hand."
        return 1
    fi
    # A switched-off row stays switched off, even here. Starting it to prove a
    # rollback worked would undo the disable on the worst possible path.
    if [ "$ROW_ENABLED" = "no" ]; then
        print_success "Rolled back the files. $UNIT is switched off and was left stopped."
        return 0
    fi
    sudo systemctl restart "$UNIT" || true
    sleep 5
    if systemctl is-active --quiet "$UNIT"; then
        print_success "Rolled back, $UNIT is running the previous build."
    else
        print_error "Rollback restored the files but $UNIT is still not running."
        print_action "Logs: sudo journalctl -u $UNIT -n 40 --no-pager"
    fi
    return 0
}

# -----------------------------------------------------------------------------
# Copy. --delete on purpose: a stale dll left behind from a previous build is
# how you get an app running code that is not in any commit. The data
# directories are excluded from it, so --delete removes stale build output and
# never customer data.
# -----------------------------------------------------------------------------
print_status "Syncing files..."
if ! rsync -a --delete "${RSYNC_EXCLUDES[@]}" "$SOURCE_DIR"/ "$TARGET_DIR"/; then
    print_error "rsync failed."
    rollback
    exit 1
fi
print_success "Files in place."

# -----------------------------------------------------------------------------
# The build arrives with the developer's own appsettings.json, which points at
# Windows paths. Rewrite it before the unit starts, or the app either crashes or
# writes data somewhere nobody looks.
#
# After the rsync, because the rsync would overwrite it. Before the restart,
# because the running app reads it at startup.
# -----------------------------------------------------------------------------
SETTINGS_SCRIPT="$SCRIPT_DIR/apply_app_settings.sh"
if [ -f "$SETTINGS_SCRIPT" ]; then
    print_status "Applying machine settings to appsettings.json..."
    if ! SITES_CONF="$SITES_CONF" bash "$SETTINGS_SCRIPT" "$APP_NAME" "$ENV_NAME"; then
        print_error "Could not apply settings, so the app would start with the wrong paths."
        rollback
        exit 1
    fi
else
    print_action "apply_app_settings.sh not found next to this script."
    print_info "The deployed appsettings.json still holds whatever the build shipped."
fi

# A switched-off row is built and published, and stopped there. The files, the
# snapshot and the settings are all current, so enabling it in the console is
# one apply rather than a redeploy. Restarting would silently undo the disable:
# add_app_services.sh stops AND disables the unit, and this ran next.
if [ "$ROW_ENABLED" = "no" ]; then
    print_success "Deployed $APP_NAME to $TARGET_DIR."
    print_info "The row is switched off, so $UNIT was left stopped and not health checked."
    print_action "Enable '$APP_NAME' in the console to start it."
    exit 0
fi

print_status "Restarting $UNIT..."
if ! sudo systemctl restart "$UNIT"; then
    print_error "Could not restart $UNIT"
    print_action "If this is a permission error, run add_jenkins_deploy_permissions.sh."
    rollback
    exit 1
fi

if [ "${SKIP_HEALTH:-0}" = "1" ]; then
    print_info "SKIP_HEALTH=1, not verifying. A broken build will stay deployed."
    print_success "Deployed $APP_NAME."
    exit 0
fi

# -----------------------------------------------------------------------------
# Health check. systemd reporting "active" only means the process started, and
# an ASP.NET app can be alive while failing every request. Ask it for a page.
#
# WHAT COUNTS AS HEALTHY: any HTTP answer that is not a server error.
#
# It used to be `curl -f`, which fails on 404, and that is wrong for an API.
# ispaddress_api answers 404 on every path including /, /health and /swagger,
# because it exposes no root route at all. It was rolled back on 2026-08-24
# while running perfectly: the check was asking "does / exist" when the
# question is "did this build start and bind its port".
#
# A 404 answers that. It came from the application, over its own port, which a
# process that failed to start cannot do. A 5xx does not: that is the app alive
# and failing, which is the case the check exists for.
# -----------------------------------------------------------------------------
print_status "Waiting up to ${HEALTH_TIMEOUT}s for http://127.0.0.1:${PORT}${HEALTH_PATH} ..."

HEALTHY=0
elapsed=0
last_code=""
while [ "$elapsed" -lt "$HEALTH_TIMEOUT" ]; do
    if ! systemctl is-active --quiet "$UNIT"; then
        print_error "$UNIT stopped. It is crashing on startup, not warming up."
        break
    fi
    # No `|| echo` fallback here. curl PRINTS 000 on a connection failure and
    # also exits non-zero, so a fallback appends a second code and the result
    # is "000000", which matches no case below and passed the check. A health
    # check that goes green when nothing answered is worse than none.
    last_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        "http://127.0.0.1:${PORT}${HEALTH_PATH}" 2>/dev/null)" || true
    [ -z "$last_code" ] && last_code="000"

    # Named rather than excluded: only these three classes are the app
    # answering. Anything else, 000 and 5xx included, is not.
    case "$last_code" in
        2??|3??|4??) HEALTHY=1; break ;;
    esac
    sleep 3
    elapsed=$((elapsed + 3))
done

if [ "$HEALTHY" -ne 1 ]; then
    print_error "Health check failed after ${elapsed}s."
    case "$last_code" in
        000) print_info "Nothing answered on port ${PORT}." ;;
        5??) print_info "The app answered ${last_code}, so it is running and failing." ;;
    esac
    print_info "Last 20 log lines:"
    journalctl -u "$UNIT" -n 20 --no-pager 2>/dev/null || true
    rollback
    exit 1
fi

print_success "$APP_NAME is serving on port $PORT (HTTP $last_code)."

# Only now is the snapshot expendable. Kept, not deleted: one manual rollback
# after the fact costs nothing to keep and is worth a lot at 2am.
print_status "Previous build kept at $BACKUP_DIR"
print_success "Deployed $APP_NAME."
