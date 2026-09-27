#!/usr/bin/env bash
set -e

# =============================================================================
# Authenticating git to GitHub goes through ONE file
#
# git_credential_github_app.sh reads the repository OWNER out of the URL git
# hands it and mints that installation's token. This script used to carry its
# own helper with a single owner-blind token, which is correct only while every
# repository has the same owner. Measured 2026-09-12: an org token gets
# "remote: Repository not found." for a personal-account repository, a 404 that
# names no cause.
#
# credential.useHttpPath is what makes the choice possible: without it git tells
# the helper the host only, and every github.com URL looks identical.
#
# THE INLINE FALLBACK IS GONE, 2026-09-12. It was principle 2b's read-path
# copy, and it had drifted: four scripts carried the same ten lines and one of
# them had dropped credential.useHttpPath, which is the whole point. The helper
# now arrives through repo_host.sh, which resolves it in one place and in both
# trees, so there is nothing left to drift.
# =============================================================================
# Through repo_host.sh: repo_git is git with the forge's credential helper
# already configured. Four scripts carried this identical ten-line block, and
# md5 said so: e4469ff in seed_app_project.sh, list_repo_branches.sh and
# read_appsettings.sh, byte for byte.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# shellcheck source=/dev/null
. "$(_iface repo_host.sh)"

# =============================================================================
# The settings a row's application actually reads, out of its own repository.
#
#   read_appsettings.sh <row> [--fresh]
#
#   {"row":"progress-app","branch":"live","project":"progress-app",
#    "files":["src/App/appsettings.json"],
#    "keys":[{"key":"Logging__LogLevel__Default","value":"Information","secret":false},
#            {"key":"Mail__Password","value":"","secret":true}]}
#
# WHY THE CONSOLE NEEDS THIS. Item 99: the drawer's App settings field is one
# `KEY=VALUE;KEY=VALUE` box and nothing has ever said which keys the application
# looks for. So the operator types a name from memory, and a wrong one is not
# an error anywhere: the app simply falls back to its built-in default and
# behaves oddly in a way nothing explains.
#
# ASP.NET'S OWN NAMING, not the JSON path. A nested key is overridden by an
# environment variable with __ between the levels: Logging:LogLevel:Default is
# Logging__LogLevel__Default. That is the form the box needs, so it is the form
# this prints, and the JSON shape is not shown at all.
#
# A VALUE IS SHOWN ONLY WHERE IT IS NOT A SECRET. A key whose name looks like a
# credential comes back with an empty value and secret:true, so the page can
# offer the key without ever putting the repository's own password on screen.
# The name is the only signal available: nothing can tell a password from a
# hostname by looking at the string.
#
# appsettings.<Environment>.json IS DELIBERATELY IGNORED. Which one an app reads
# depends on ASPNETCORE_ENVIRONMENT at run time, and offering keys from a file
# this row will never load is worse than offering none.
#
# THE REPOSITORY IS READ, NOT THE DEPLOYED BUILD. Nothing has to have been built.
#
# GIT RUNS AS THE DEPLOY ACCOUNT over HTTPS with an App token, exactly as
# list_startup_projects.sh does since 2026-09-09. root has no key here.
#
# JSON goes to stdout and nothing else does: the page parses it.
# =============================================================================

print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

json_out() { printf '%s\n' "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run git as the deploy account."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

FRESH=0
ROW=""
for _a in "$@"; do
    case "$_a" in
        --fresh) FRESH=1 ;;
        *)       [ -z "$ROW" ] && ROW="$_a" ;;
    esac
done
[ -z "$ROW" ] && { json_out '{"error":"a row name is needed"}'; exit 0; }

# The row name reaches this from a browser, so it is checked against the shape a
# row name may have rather than trusted. It is only ever used to match a config
# line, never as a path.
if ! printf '%s' "$ROW" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._-]*$'; then
    json_out '{"error":"that is not a usable row name"}'
    exit 0
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/var/lib/hosting-manager/config-repo/backup_config")"
[ -f "$SITES_CONF" ] || { json_out '{"error":"no config to read the row from"}'; exit 0; }

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
    v="${v//$'\r'/}"
    printf '%s' "$(trim "${v%%#*}")"
}

conf_rows() {
    grep -v '^[[:space:]]*#' "$SITES_CONF" \
        | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' \
        | grep '|'
}

APP_RUN_USER="$(conf_get APP_RUN_USER)"
[ -z "$APP_RUN_USER" ] && APP_RUN_USER="jenkins"

REPO=""; BRANCH=""; ROWTYPE=""; DLLPATH=""
while IFS='|' read -r type name port path sub ds opts auth repo branch _rest; do
    [ "$(trim "$name")" = "$ROW" ] || continue
    ROWTYPE="$(trim "$type")"
    DLLPATH="$(trim "$path")"
    REPO="$(trim "$repo")"
    BRANCH="$(trim "$branch")"
    break
done < <(conf_rows)

[ -z "$ROWTYPE" ] && { json_out "{\"error\":\"'$ROW' is not a row in this config\"}"; exit 0; }
if [ "$ROWTYPE" != "app" ]; then
    json_out "{\"error\":\"'$ROW' is a '$ROWTYPE' row, and only an application reads appsettings\"}"
    exit 0
fi
if [ -z "$REPO" ] || [ "$REPO" = "new" ]; then
    json_out "{\"error\":\"'$ROW' has no repository yet, so there is nothing to read\"}"
    exit 0
fi

# Same branch rule as list_startup_projects.sh: the row's own if it names one,
# otherwise the first environment's.
if [ -z "$BRANCH" ]; then
    FIRST_ENV="$(conf_get ENVS)"
    FIRST_ENV="$(trim "${FIRST_ENV%%,*}")"
    [ -z "$FIRST_ENV" ] && FIRST_ENV="live"
    ENV_UPPER="$(printf '%s' "$FIRST_ENV" | tr '[:lower:]' '[:upper:]')"
    BRANCH="$(conf_get "${ENV_UPPER}_BRANCH")"
    [ -z "$BRANCH" ] && BRANCH="$FIRST_ENV"
fi

# The project name, from the row's published dll path. It is what narrows the
# search to the application's own appsettings rather than every one in the
# repository, and a repository with an Api and a Worker has two.
PROJECT="$(basename "$DLLPATH" .dll)"

CACHE_DIR="/var/lib/hosting-manager/appsettings"
CACHE_FILE="$CACHE_DIR/$ROW.json"
CACHE_KEY="$REPO|$BRANCH|$PROJECT"

if [ "$FRESH" -eq 0 ] && [ -s "$CACHE_FILE" ]; then
    if [ "$(head -n 1 "$CACHE_FILE")" = "$CACHE_KEY" ]; then
        tail -n +2 "$CACHE_FILE"
        exit 0
    fi
fi

if ! id "$APP_RUN_USER" >/dev/null 2>&1; then
    json_out "{\"error\":\"no '$APP_RUN_USER' account to run git as\"}"
    exit 0
fi

# The token reaches git through a credential helper and the ENVIRONMENT, never
# the argument list: anything on this machine can read /proc/<pid>/cmdline.
TOKEN_SH="$SCRIPT_DIR/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
GH_TOKEN=""
if [ -f "$TOKEN_SH" ]; then
    OWNER=""
    case "$REPO" in
        https://github.com/*) OWNER="${REPO#https://github.com/}"; OWNER="${OWNER%%/*}" ;;
    esac
    GH_TOKEN="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" ${OWNER:+"$OWNER"} 2>/dev/null || true)"
fi
export GH_TOKEN

# HTTPS only: the SSH key is for the first clone of a machine, the owner 2026-09-13.
clone_url="$(repo_https_url "$REPO" 2>/dev/null || printf '%s' "$REPO")"

WORK="$(sudo -n -u "$APP_RUN_USER" mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# No --filter here, unlike the project lister: the json files are the thing
# being read, so their blobs are needed anyway and a filtered clone would fetch
# them one round trip at a time.
if ! sudo -n -u "$APP_RUN_USER" --preserve-env=GH_TOKEN git \
        -c credential.helper= \
        -c credential.helper="$REPO_GIT_CRED" -c credential.useHttpPath=true \
        clone -q --depth 1 --branch "$BRANCH" "$clone_url" "$WORK/repo" 2>"$WORK/err"; then
    msg="$(tr '\n' ' ' < "$WORK/err" | tail -c 160 | sed 's/"/\\"/g')"
    json_out "{\"error\":\"cannot read branch '$BRANCH': $msg\"}"
    exit 0
fi

# =============================================================================
# Flatten every appsettings.json into ASP.NET's environment-variable form.
#
# Arrays are skipped rather than indexed. ASP.NET does bind Section__0__Key, but
# a list offered as separate numbered keys reads as several settings when it is
# one, and overriding element 0 of a list nobody can see the length of is not
# something a drawer should invite.
# =============================================================================
RC=0
python3 - "$WORK/repo" "$PROJECT" "$ROW" "$BRANCH" > "$WORK/out.json" 2>/dev/null <<'PY' || RC=$?
import json, os, re, sys

root, project, row, branch = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]

# The project's own directory when the row names one and it is there, the whole
# repository otherwise. A repository with an Api and a Worker has two of these
# files and they are not interchangeable.
search_roots = []
if project:
    for dirpath, dirnames, filenames in os.walk(root):
        if ".git" in dirpath.split(os.sep):
            continue
        if project + ".csproj" in filenames:
            search_roots.append(dirpath)
if not search_roots:
    search_roots = [root]

files, flat = [], {}

# Only the base file. Which appsettings.<Environment>.json an app reads is
# decided by ASPNETCORE_ENVIRONMENT at run time, and offering keys from a file
# this row will never load is worse than offering none.
def walk(prefix, node):
    if isinstance(node, dict):
        for k, v in node.items():
            walk(prefix + [str(k)], v)
    elif isinstance(node, (str, int, float, bool)) or node is None:
        flat["__".join(prefix)] = "" if node is None else (
            "true" if node is True else "false" if node is False else str(node))
    # lists: deliberately skipped, see the header

for base in search_roots:
    for dirpath, dirnames, filenames in os.walk(base):
        if ".git" in dirpath.split(os.sep):
            continue
        for fn in filenames:
            if fn.lower() != "appsettings.json":
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, root).replace(os.sep, "/")
            try:
                with open(full, "r", encoding="utf-8-sig", errors="replace") as fh:
                    text = fh.read()
                # appsettings.json is JSONC in practice: a // comment in one took
                # a deploy down on 2026-08-23, so they are stripped rather than
                # allowed to make the whole file unreadable here.
                text = re.sub(r"^\s*//.*$", "", text, flags=re.M)
                data = json.loads(text)
            except Exception:
                continue
            files.append(rel)
            walk([], data)

SECRETISH = re.compile(
    r"(password|passwd|secret|token|apikey|api_key|clientsecret|"
    r"connectionstring|privatekey|credential)", re.I)

keys = []
for k in sorted(flat):
    secret = bool(SECRETISH.search(k))
    keys.append({"key": k, "value": "" if secret else flat[k], "secret": secret})

print(json.dumps({"row": row, "branch": branch, "project": project,
                  "files": sorted(set(files)), "keys": keys}))
PY

if [ "$RC" -ne 0 ]; then
    json_out '{"error":"could not read the settings files"}'
    exit 0
fi

OUT="$(cat "$WORK/out.json")"
[ -z "$OUT" ] && { json_out '{"error":"no settings could be read"}'; exit 0; }

install -d -m 0755 "$CACHE_DIR" 2>/dev/null || true
{ printf '%s\n' "$CACHE_KEY"; printf '%s\n' "$OUT"; } > "$CACHE_FILE" 2>/dev/null || true

json_out "$OUT"
exit 0
