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
# THE INLINE FALLBACK STAYS, and it is deliberate. project-context.md principle
# 2b: one file talks to an outside service, and a caller MAY keep its own copy
# so a lone script on a bare machine still runs. This is that copy, and it is
# only ever the read path.
#
# "!bash <path>" rather than the path alone: the pipeline tree chmods every file
# in it to 644, so a helper named by path is not executable there.
# =============================================================================
CRED_HELPER=""
for _c in /usr/local/lib/linuxbasics/hostings/scripts/git_credential_github_app.sh \
          "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/git_credential_github_app.sh"; do
    [ -f "$_c" ] && { CRED_HELPER="$_c"; break; }
done
if [ -n "$CRED_HELPER" ]; then
    GIT_CRED="!bash '$CRED_HELPER'"
else
    GIT_CRED='!f() { echo username=x-access-token; echo "password=$GH_TOKEN"; }; f'
fi

# =============================================================================
# Print every RUNNABLE project in a row's repository, as JSON.
#
#   list_startup_projects.sh <row>
#
#   {"row":"demo","branch":"main",
#    "projects":[{"name":"Api","path":"src/Api/Api.csproj","runnable":true},
#                {"name":"Shared","path":"src/Shared/Shared.csproj","runnable":false}]}
#
# WHY THE CONSOLE NEEDS THIS. An application row's fourth field is the path to
# a published .dll, and the build derives the PROJECT name from it: the dll
# name is what `find src -name "<name>.csproj"` looks for. So the field is
# really "which project in this repository is the one to run", typed by hand,
# and a typo produces a build that stops with "No <name>.csproj in the
# repository" or a unit that starts, finds no dll, and crash-loops.
#
# A dropdown of what is actually in the repository removes the typo. This is
# the half that answers what is in there.
#
# RUNNABLE IS NOT THE SAME AS PRESENT, and this is the part worth getting
# right. A class library is a .csproj too, and picking one gives a unit that
# starts and immediately exits. A project is reported runnable when it either
# uses a web SDK or declares <OutputType>Exe</OutputType>. Both are read from
# the file; nothing is built to find out.
#
# NOT-RUNNABLE PROJECTS ARE STILL LISTED, with runnable:false, so the page can
# grey them rather than pretend they do not exist. A reader looking for a
# project that is missing from the list would otherwise have no idea why.
#
# THE REPOSITORY IS READ, NOT THE PUBLISH OUTPUT. Nothing has to have been
# built, which is the whole point: this answers before the first deploy.
#
# GIT RUNS AS THE DEPLOY ACCOUNT, NOT AS ROOT. root has no SSH key here.
#
# JSON goes to stdout and nothing else does: the page parses it.
# =============================================================================

print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

json_out() { printf '%s\n' "$1"; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run git as the deploy account."
    print_action "Please run with: sudo $0 $*"
    exit 1
fi

# --fresh skips the cache, for a caller that has just pushed a project.
FRESH=0
ROW=""
for _a in "$@"; do
    case "$_a" in
        --fresh) FRESH=1 ;;
        *)       [ -z "$ROW" ] && ROW="$_a" ;;
    esac
done
if [ -z "$ROW" ]; then
    json_out '{"error":"a row name is needed"}'
    exit 0
fi

# The row name reaches this from a browser, so it is checked against the same
# shape a row name may have rather than trusted. Everything after this uses it
# only to match a config line, never as a path.
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

if [ ! -f "$SITES_CONF" ]; then
    json_out '{"error":"no config to read the row from"}'
    exit 0
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

REPO=""
BRANCH=""
ROWTYPE=""
while IFS='|' read -r type name port path sub ds opts auth repo branch _rest; do
    [ "$(trim "$name")" = "$ROW" ] || continue
    ROWTYPE="$(trim "$type")"
    REPO="$(trim "$repo")"
    BRANCH="$(trim "$branch")"
    break
done < <(conf_rows)

if [ -z "$ROWTYPE" ]; then
    json_out "{\"error\":\"'$ROW' is not a row in this config\"}"
    exit 0
fi
if [ "$ROWTYPE" != "app" ]; then
    json_out "{\"error\":\"'$ROW' is a '$ROWTYPE' row, and only an application has a project to run\"}"
    exit 0
fi
if [ -z "$REPO" ] || [ "$REPO" = "new" ]; then
    json_out "{\"error\":\"'$ROW' has no repository yet, so there is nothing to read\"}"
    exit 0
fi

# A row that names its branch has answered the question, the same rule
# branches_for() and both seeders use. Otherwise the first environment's
# branch, which is what a first deploy would take.
if [ -z "$BRANCH" ]; then
    FIRST_ENV="$(conf_get ENVS)"
    FIRST_ENV="$(trim "${FIRST_ENV%%,*}")"
    [ -z "$FIRST_ENV" ] && FIRST_ENV="live"
    ENV_UPPER="$(printf '%s' "$FIRST_ENV" | tr '[:lower:]' '[:upper:]')"
    BRANCH="$(conf_get "${ENV_UPPER}_BRANCH")"
    [ -z "$BRANCH" ] && BRANCH="$FIRST_ENV"
fi

# HTTPS AND AN APP TOKEN FIRST, SSH ONLY IF THERE IS NO TOKEN.
#
# This rewrote every https:// repository to git@github.com: and cloned as the
# deploy account. That account's key was deleted on 2026-09-04, so the dropdown
# has answered "could not read the repository" for every private repository
# since, which is what item 89 moved the other four scripts off SSH for. This
# one was missed. Measured 2026-09-09: "Permission denied (publickey)".
#
# The token reaches git through a credential helper and the ENVIRONMENT, never
# the argument list: anything on this machine can read /proc/<pid>/cmdline.
TOKEN_SH="$SCRIPT_DIR/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"

GH_TOKEN=""
if [ -f "$TOKEN_SH" ]; then
    GH_TOKEN="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" 2>/dev/null || true)"
fi
export GH_TOKEN

# HTTPS only: the SSH key is for the first clone of a machine, the owner 2026-09-13.
clone_url="$REPO"
case "$REPO" in
    git@github.com:*) clone_url="https://github.com/${REPO#git@github.com:}" ;;
esac

# CACHED, keyed by the repository and the branch it reads.
#
# Measured 2026-09-04: 6.3s for progress-repo, 3.5s for
# ISPAddressChecker. That is a clone per drawer open, and the drawer is
# opened far more often than a repository gains a project.
#
# The KEY is the repository and branch, not the row name. A row repointed at
# another repository, or at another branch, has a different key and cannot be
# served the previous answer, so nothing has to remember to drop this file.
#
# --fresh skips it, for a caller that has just pushed a project.
CACHE_DIR="/var/lib/hosting-manager/startup-projects"
CACHE_FILE="$CACHE_DIR/$ROW.json"
CACHE_KEY="$REPO|$BRANCH"

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

WORK="$(sudo -n -u "$APP_RUN_USER" mktemp -d)"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

# --depth 1 and --filter=blob:none: the file LIST is what is wanted, and the
# blobs are only fetched for the .csproj files read below. A repository with
# large assets in it should not cost a full clone to answer a dropdown.
if ! sudo -n -u "$APP_RUN_USER" --preserve-env=GH_TOKEN git \
        -c credential.helper= \
        -c credential.helper="$GIT_CRED" -c credential.useHttpPath=true \
        clone -q --depth 1 --filter=blob:none \
        --branch "$BRANCH" "$clone_url" "$WORK/repo" 2>"$WORK/err"; then
    msg="$(tr '\n' ' ' < "$WORK/err" | tail -c 160 | sed 's/"/\\"/g')"
    json_out "{\"error\":\"cannot read branch '$BRANCH': $msg\"}"
    exit 0
fi

# =============================================================================
# Every .csproj, and whether it can be started.
#
# Two things make a project runnable, and either is enough:
#
#   Sdk="Microsoft.NET.Sdk.Web"      an ASP.NET app, which is what a row runs
#   <OutputType>Exe</OutputType>     a console app or a worker
#
# Anything else is a library. Blazor WebAssembly uses Sdk.BlazorWebAssembly and
# is deliberately NOT runnable here: it is served as static files by a website
# row, not started as a unit.
# =============================================================================
first=1
# Built in a variable rather than printed as it goes, so the cache holds a
# whole document and a half-written one is never served.
OUT=""
add() { OUT="$OUT$1"; }

add "$(printf '{"row":"%s","branch":"%s","projects":[' "$ROW" "$BRANCH")"

while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$WORK/repo/"}"
    base="$(basename "$f" .csproj)"

    runnable=false
    if grep -qi 'Sdk="Microsoft\.NET\.Sdk\.Web"' "$f" 2>/dev/null; then
        runnable=true
    elif grep -qiE '<OutputType>[[:space:]]*Exe[[:space:]]*</OutputType>' "$f" 2>/dev/null; then
        runnable=true
    fi

    [ "$first" -eq 1 ] || add ","
    first=0
    add "$(printf '{"name":"%s","path":"%s","runnable":%s}' \
        "$(printf '%s' "$base" | sed 's/"/\\"/g')" \
        "$(printf '%s' "$rel"  | sed 's/"/\\"/g')" \
        "$runnable")"
done < <(find "$WORK/repo" -name '*.csproj' -not -path '*/.git/*' -type f | sort)

add "]}"

# The key on the first line, the document from the second. A reader that
# finds a different key clones again rather than trusting a stale answer.
if [ -n "$OUT" ]; then
    mkdir -p "$CACHE_DIR"
    _tmp="$(mktemp)"
    printf '%s\n%s\n' "$CACHE_KEY" "$OUT" > "$_tmp"
    install -m 0644 -o root -g root "$_tmp" "$CACHE_FILE" 2>/dev/null || true
    rm -f "$_tmp"
fi

json_out "$OUT"
