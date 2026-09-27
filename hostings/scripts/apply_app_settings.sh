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
# Write the machine's settings into a deployed appsettings.json.
#
#   ./apply_app_settings.sh <app-name> <env>
#   ./apply_app_settings.sh mvp_progress_example test
#
# Called by deploy_app.sh after the rsync and before the unit is restarted. Can
# be run by hand to repair an instance without redeploying it.
#
# WHY THE FILE AND NOT A systemd Environment= VARIABLE
#
# Both work: .NET reads environment variables over appsettings.json per key. The
# file was chosen so that opening appsettings.json on the machine shows the
# truth. A file that still displays a Windows development path while an
# invisible variable overrides it is an hour lost the first time something
# breaks.
#
# The accepted cost: the deployed file no longer byte-matches the built
# artifact, so a rollback restores files and then re-applies this step.
#
# ONLY EXISTING KEYS ARE WRITTEN
#
# A key that is not already in appsettings.json is skipped and reported, never
# created. Two reasons. Applications differ: api1 and the ISP checker have no
# BackendDatabaseFolderLocation, and inventing one would add configuration they
# ignore. And a key that has to be created is almost always a typo, so the
# report is what turns a silent no-op into a visible one.
#
# Python is used for the edit rather than sed. Paths contain slashes and the
# Windows defaults contain backslashes, which are escape characters in both
# JSON and sed, so a sed edit silently produces a file the app cannot parse.
# python3 ships with Ubuntu Server, so this adds no dependency.
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
    echo "Usage: $0 <app-name> <env>" >&2
    echo "" >&2
    echo "  app-name  an app row name from the config, e.g. mvp_portfolio" >&2
    echo "  env       an environment listed in ENVS, e.g. test or dev" >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SITES_CONF  override the config location" >&2
    echo "  DRY_RUN=1   print what would change, write nothing" >&2
    exit 1
}

APP_NAME="$1"
ENV_NAME="$2"
[ -z "$APP_NAME" ] && usage
[ -z "$ENV_NAME" ] && usage

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    print_action "Override with: SITES_CONF=/path/to/hostings.conf $0 ..."
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    print_error "python3 not found, and it is what edits the JSON safely."
    print_action "Install it: sudo apt-get install -y python3"
    exit 1
fi

# -----------------------------------------------------------------------------
# Config readers. Duplicated verbatim into every script that reads this file
# rather than sourced, so each one stays runnable on its own on a machine that
# has only that script copied to it.
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

# Emit one clean, comment-stripped row per line. A settings line has no pipe and
# would otherwise parse as a row whose type is the whole line: harmless where a
# caller filters on type, wrong anywhere that iterates every row.
conf_rows() {
    # One awk pass. A bash read loop over the whole file cost 0.2s per call.
    # A SETTING line is skipped even when it holds pipes, as PANEL lines do.
    awk '{ sub(/#.*/, "") } /^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=/ { next } /\|/' "$SITES_CONF"
}

# A field holding a single dash means empty. Written that way because a row of
# `| | |` cannot be counted by eye, and a miscounted row silently puts a value
# in the wrong column.
trim() {
    # Pure bash: no echo, no xargs. This is called once per field per row per
    # environment, and each fork costs more than the work it does.
    local v="$1"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "$v"
}

ENV_UPPER="$(echo "$ENV_NAME" | tr '[:lower:]' '[:upper:]')"
APP_ROOT="$(conf_get "APP_ROOT_${ENV_UPPER}" "")"
BACKUP_ROOT="$(conf_get BACKUP_ROOT "")"

if [ -z "$APP_ROOT" ]; then
    print_error "No APP_ROOT_${ENV_UPPER} in $SITES_CONF, so '$ENV_NAME' is not a known environment."
    print_info "Environments: $(conf_get ENVS live)"
    exit 1
fi

if [ -z "$BACKUP_ROOT" ]; then
    print_error "No BACKUP_ROOT in $SITES_CONF."
    exit 1
fi

# -----------------------------------------------------------------------------
# Find the row, and the row of whichever service owns its data
# -----------------------------------------------------------------------------
find_row() {
    local want="$1" type name port path subdomain datasource options auth repo
    while IFS='|' read -r type name port path subdomain datasource options auth repo branch rowenvs authusers repomode runtime enabled owner; do
        [ "$(trim "$name")" = "$want" ] || continue
        printf '%s|%s|%s|%s|%s|%s|%s\n' \
            "$(trim "$type")" "$(trim "$name")" "$(trim "$port")" "$(trim "$path")" \
            "$(trim "$subdomain")" "$(trim "$datasource")" "$(trim "$options")"
        return 0
    done < <(conf_rows)
    return 1
}

if ! ROW="$(find_row "$APP_NAME")"; then
    print_error "No row named '$APP_NAME' in $SITES_CONF"
    exit 1
fi

# Every field is named. `read` puts the remainder in its LAST variable, so
# stopping at OPTIONS made it swallow AuthProtected onwards and wrote
# "Production | yes | - | - | live | carol" into appsettings.json.
IFS='|' read -r TYPE _ PORT DLL_PATH _ DATA_SOURCE OPTIONS _AUTH _REPO _BRANCH _ENVS _USERS _MODE _RT _ENABLED <<< "$ROW"

if [ "$TYPE" != "app" ]; then
    print_error "'$APP_NAME' is a '$TYPE' row. Only app rows have an appsettings.json."
    exit 1
fi

APP_DIR="${APP_ROOT%/}/$(dirname "${DLL_PATH#/}")"
APPSETTINGS="$APP_DIR/appsettings.json"

# -----------------------------------------------------------------------------
# Resolve the live data folder. DataSource names a SERVICE, not a path, so the
# environment still derives: a dev service reads dev data. The portfolio is
# view-only and points at the backoffice, which is why this indirection exists.
# -----------------------------------------------------------------------------
resolve_data_dir() {
    local svc="$1" row src_path src_type

    case "$svc" in
        =*) echo "${svc#=}"; return 0 ;;
    esac

    if ! row="$(find_row "$svc")"; then
        print_error "DataSource '$svc' on row '$APP_NAME' names no service in $SITES_CONF"
        exit 1
    fi
    IFS='|' read -r src_type _ _ src_path _ _ _ <<< "$row"
    echo "${APP_ROOT%/}/$(dirname "${src_path#/}")/wwwroot"
}

if [ -n "$DATA_SOURCE" ]; then
    if [ "$DATA_SOURCE" = "$APP_NAME" ]; then
        print_error "Row '$APP_NAME' lists itself as its own DataSource. Leave the field empty instead."
        exit 1
    fi
    DATA_DIR="$(resolve_data_dir "$DATA_SOURCE")"
    print_status "Data comes from '$DATA_SOURCE', not from this app's own folder."
else
    DATA_DIR="$APP_DIR/wwwroot"
fi

BACKUP_DIR="${BACKUP_ROOT%/}/${APP_NAME}/${ENV_NAME}"

print_header "Settings for $APP_NAME ($ENV_NAME)"
print_status "App dir:  $APP_DIR"
print_status "Data:     $DATA_DIR"
print_status "Backup:   $BACKUP_DIR"

if [ ! -f "$APPSETTINGS" ]; then
    print_error "No appsettings.json at $APPSETTINGS"
    print_action "Deploy the app first. This script edits a deployed file, it does not create one."
    exit 1
fi

# -----------------------------------------------------------------------------
# The settings to apply.
#
# The six path keys below are the defaults, tried against every app. An app that
# does not have them is left alone, so listing them here costs nothing for api1
# or the ISP checker.
#
# Anything else comes from the row's ApplicationOptionsOverwrite field, where
# {DATA}, {BACKUP} and {APP_DIR} expand to the paths resolved above.
# -----------------------------------------------------------------------------
SETTINGS=(
    "ApplicationOptions__BackendDatabaseFolderLocation=${DATA_DIR}/databases/"
    "ApplicationOptions__BackendProjectPicturesFolderPath=${DATA_DIR}/project_photos/"
    "ApplicationOptions__FrontendDatabaseFolderLocation=${DATA_DIR}/databases/"
    "ApplicationOptions__FrontendProjectPicturesFolderPath=${DATA_DIR}/project_photos/"
    "ApplicationOptions__BackupDatabaseFolderLocation=${BACKUP_DIR}/databases/"
    "ApplicationOptions__BackupProjectPicturesFolderPath=${BACKUP_DIR}/project_photos/"
    "Platform__CurrentPlatform=Ubuntu"
)

if [ -n "$OPTIONS" ]; then
    IFS=';' read -r -a OPTION_PAIRS <<< "$OPTIONS"
    for pair in "${OPTION_PAIRS[@]}"; do
        pair="$(trim "$pair")"
        [ -z "$pair" ] && continue
        pair="${pair//\{DATA\}/$DATA_DIR}"
        pair="${pair//\{BACKUP\}/$BACKUP_DIR}"
        pair="${pair//\{APP_DIR\}/$APP_DIR}"
        SETTINGS+=("$pair")
    done
fi

# -----------------------------------------------------------------------------
# Settings that must not be in git.
#
# A mail password is a real credential and hostings.conf is a tracked file, so
# the row cannot carry one. This reads an optional per-row file instead, owned
# by root and unreadable by anyone else, holding the same KEY=VALUE lines the
# Options field takes:
#
#   /etc/app-secrets/<row>.env
#   EmailSettings__Password=...
#
# Read last, so it wins over the row. Values are never printed: only the key
# names, and only to say that they were applied.
#
# Same shape as add_transip_key.sh, deliberately. A second mechanism for
# secrets is a second mechanism to get wrong.
# -----------------------------------------------------------------------------
SECRETS_FILE="${SECRETS_FILE:-/etc/app-secrets/${APP_NAME}.env}"
if [ -f "$SECRETS_FILE" ]; then
    perms="$(stat -c '%a' "$SECRETS_FILE" 2>/dev/null || echo '')"
    case "$perms" in
        600|400) ;;
        *)
            print_error "$SECRETS_FILE is mode ${perms:-unknown}, so other accounts can read a password."
            print_action "Fix it: sudo chmod 600 $SECRETS_FILE"
            exit 1
            ;;
    esac
    secret_keys=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(trim "${line%%$'\r'}")"
        [ -z "$line" ] && continue
        case "$line" in \#*) continue ;; esac
        [ "${line#*=}" = "$line" ] && continue
        SETTINGS+=("$line")
        secret_keys+=("${line%%=*}")
    done < "$SECRETS_FILE"
    if [ ${#secret_keys[@]} -gt 0 ]; then
        print_status "From $SECRETS_FILE: ${secret_keys[*]}"
    fi
fi

# -----------------------------------------------------------------------------
# Apply. Written to a temp file in the same directory and renamed, so an
# interrupted run cannot leave the app with a JSON file it will not start on.
# -----------------------------------------------------------------------------
DRY_RUN="${DRY_RUN:-0}" SECRET_KEYS="${secret_keys[*]-}" \
    python3 - "$APPSETTINGS" "${SETTINGS[@]}" <<'PYEOF'
import json, os, re, sys, tempfile

path = sys.argv[1]
pairs = sys.argv[2:]
dry = os.environ.get("DRY_RUN") == "1"

BLUE, GREEN, YELLOW, RED, RESET = "\033[34m", "\033[32m", "\033[33m", "\033[31m", "\033[0m"

def strip_jsonc(text):
    """Remove // and /* */ comments and trailing commas.

    appsettings.json is JSONC, not JSON. .NET reads it with
    JsonCommentHandling.Skip and AllowTrailingCommas, so a commented-out
    setting is entirely normal and every real project has one. Strict
    json.load rejected the ISPAddressChecker settings on the line above its
    APIEndpointURL and took the deploy down with it.

    Scanned rather than matched with a regex, because the first thing a
    settings file contains is URLs, and `https://` is a // that must survive.
    """
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"':
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            while i < n and text[i] != "\n":
                i += 1
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            i += 2
            while i + 1 < n and not (text[i] == "*" and text[i + 1] == "/"):
                i += 1
            i += 2
            continue
        out.append(c)
        i += 1
    stripped = "".join(out)
    # Trailing commas, once the comments that hid them are gone.
    return re.sub(r",(\s*[}\]])", r"\1", stripped)


try:
    with open(path, encoding="utf-8-sig") as f:
        raw = f.read()
except OSError as e:
    print(f"{RED}❌ Cannot read {path}: {e}{RESET}")
    sys.exit(1)

try:
    data = json.loads(raw)
    HAD_COMMENTS = False
except json.JSONDecodeError:
    try:
        data = json.loads(strip_jsonc(raw))
        HAD_COMMENTS = True
    except json.JSONDecodeError as e:
        print(f"{RED}❌ {path} is not valid JSON: {e}{RESET}")
        sys.exit(1)

changed, unchanged, skipped = [], [], []

for pair in pairs:
    if "=" not in pair:
        print(f"{RED}❌ Option is not KEY=VALUE: {pair}{RESET}")
        sys.exit(1)
    key, value = pair.split("=", 1)
    parts = key.split("__")

    # Walk to the parent, refusing to create anything that is not already there
    node = data
    for p in parts[:-1]:
        if not isinstance(node, dict) or p not in node:
            node = None
            break
        node = node[p]
    leaf = parts[-1]

    if node is None or not isinstance(node, dict) or leaf not in node:
        skipped.append(key)
        continue

    if node[leaf] == value:
        unchanged.append(key)
    else:
        node[leaf] = value
        changed.append((key, value))

# Keys that came out of the secrets file. Their values are never printed: this
# output goes to a Jenkins console log that anyone with an account can read.
SECRET_KEYS = set(filter(None, os.environ.get("SECRET_KEYS", "").split()))

for key, value in changed:
    print(f"{GREEN}✅ {key}{RESET}")
    print("     ********" if key in SECRET_KEYS else f"     {value}")
for key in unchanged:
    print(f"{BLUE}🔧 {key} already correct{RESET}")

if skipped:
    print(f"{YELLOW}⚠️ Not present in appsettings.json, left alone:{RESET}")
    for key in skipped:
        print(f"{YELLOW}   - {key}{RESET}")
    print(f"{YELLOW}   Expected for an app that does not use these settings.{RESET}")
    print(f"{YELLOW}   Unexpected for one that does: check the key name for a typo.{RESET}")

if dry:
    print(f"{YELLOW}⚠️ DRY_RUN=1, nothing written.{RESET}")
    sys.exit(0)

if not changed:
    sys.exit(0)

if HAD_COMMENTS:
    # Said out loud rather than done quietly: json.dump writes JSON, so the
    # comments go. Only the deployed copy is rewritten, never the repository,
    # so a commented-out setting is still where the developer left it.
    print(f"{YELLOW}ℹ️ {path} had comments. The deployed copy is rewritten without them;{RESET}")
    print(f"{YELLOW}ℹ️ the repository is untouched.{RESET}")

st = os.stat(path)
fd, tmp = tempfile.mkstemp(dir=os.path.dirname(path) or ".")
try:
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.chmod(tmp, st.st_mode & 0o7777)
    try:
        os.chown(tmp, st.st_uid, st.st_gid)
    except PermissionError:
        pass          # not root, and the file is already ours
    os.replace(tmp, path)
except Exception:
    if os.path.exists(tmp):
        os.unlink(tmp)
    raise
PYEOF

print_success "Settings applied to $APPSETTINGS"
