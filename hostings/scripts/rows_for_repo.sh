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
# Which rows does one build deploy to?
#
# One repository serves several rows: the progress tenants are one codebase and
# four deployments, and ISPAddressChecker is one repository with an API row and
# a dashboard row. A pipeline is per repository; the config is per row. This is
# the join between them.
#
#   ./rows_for_repo.sh https://github.com/you/thing.git live
#
# Prints one row name per line, nothing else, so a caller can read it straight
# into a list. Prints nothing and exits 0 when a repository has no rows yet:
# that is the normal state of a repository that has just been filled in, not an
# error.
#
# WHICH ROWS TAKE PART, per the pipeline decisions of 2026-08-15:
#
#   - A row with a Branch override takes part only in builds of THAT branch, and
#     its environment comes from its own Envs. mvp_progress_demo is the case:
#     Branch=demo, Envs=live, so a push to live must not deploy it.
#   - A row without one takes part when the branch name matches one of its Envs.
#
# READ ONLY. It touches nothing and needs no privilege.
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1" >&2
}

usage() {
    echo "Usage: $0 <repository-url> <environment> [--branch <name>] [--with-path]" >&2
    echo "" >&2
    echo "  repository-url  as written in the ninth column of hostings.conf" >&2
    echo "  environment     live, test, accept or skunk" >&2
    echo "  --branch NAME   the branch being built. Defaults to the environment," >&2
    echo "                  which is what the multibranch layout gives you." >&2
    echo "  --with-path     print 'name|path' instead of just the name. Rows in one" >&2
    echo "                  repository can be different projects: an API and a" >&2
    echo "                  dashboard are two, four tenants of one app are one." >&2
    echo "                  A caller grouping on the path builds each project once." >&2
    echo "" >&2
    echo "Environment:" >&2
    echo "  SITES_CONF      override the config location" >&2
    exit 1
}

REPO=""
ENVIRONMENT=""
BRANCH=""
WITH_PATH=0
while [ $# -gt 0 ]; do
    case "$1" in
        --branch)   BRANCH="$2"; shift 2 ;;
        --branch=*) BRANCH="${1#--branch=}"; shift ;;
        --with-path) WITH_PATH=1; shift ;;
        -h|--help)  usage ;;
        -*)         print_error "Unknown option: $1"; usage ;;
        *)
            if   [ -z "$REPO" ];        then REPO="$1"
            elif [ -z "$ENVIRONMENT" ]; then ENVIRONMENT="$1"
            else print_error "Too many arguments: $1"; usage
            fi
            shift
            ;;
    esac
done

[ -z "$REPO" ] && { print_error "No repository given."; usage; }
[ -z "$ENVIRONMENT" ] && { print_error "No environment given."; usage; }
[ -z "$BRANCH" ] && BRANCH="$ENVIRONMENT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

# A repository may be written with or without the trailing .git, and as ssh or
# https. Comparing the owner/name tail matches all four spellings without
# pretending to be a URL parser.
repo_tail() {
    echo "$1" | sed -E 's#\.git$##; s#^git@[^:]+:##; s#^https?://[^/]+/##' | tr '[:upper:]' '[:lower:]'
}
WANT="$(repo_tail "$REPO")"

trim() { echo "$1" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//'; }

# IS THE BRANCH BEING BUILT AN ENVIRONMENT AT ALL?
#
# The branch is the environment, so a build of `live` deploys every row that
# takes part in live, including rows whose Envs is a dash meaning all of them.
# A build of `demo` is not an environment: only a row that names demo in its
# Branch column may take part. Without this, a dash row would be deployed by
# every branch that ever exists.
ALL_ENVS="$(sed -n 's/^[[:space:]]*ENVS[[:space:]]*=//p' "$SITES_CONF" \
            | head -n 1 | sed 's/#.*//')"
BRANCH_IS_ENV=0
IFS=',' read -r -a _all <<< "$ALL_ENVS"
for e in ${_all+"${_all[@]}"}; do
    [ "$(trim "$e")" = "$BRANCH" ] && BRANCH_IS_ENV=1
done

# THE PATH COLUMN IS A DEPLOY PATH, NOT A SOURCE PATH.
#
# It is <directory>/<assembly>.dll under APP_ROOT, and the directory is where the
# build LANDS, which is not required to match where it comes FROM:
#
#   ispaddress_api  ISPAddressCheckerAPI/ISPAddressCheckerAPI.dll
#   ispaddress_gui  ISPAddressCheckerDashboard/ISPAddressCheckerStatusDashboard.dll
#                   ^ deploys here            ^ but the project is called this
#
# The project directory in a .NET repository is the assembly name, so the source
# project is the dll's basename without the extension. Both of the above resolve
# to a real directory in the repository that way, and the deploy directory does
# not.
#
# Grouping on this is also what makes "one build, many deployments" correct: four
# tenants of one application produce the same assembly name and are built once.
project_of() {
    local p="$1"
    p="${p##*/}"
    p="${p%.dll}"
    echo "$p"
}

emit() {
    if [ "$WITH_PATH" -eq 1 ]; then
        echo "${1}|$(project_of "$2")"
    else
        echo "$1"
    fi
}

while IFS='|' read -r _type name _port rowpath _sub _ds _opts _auth rowrepo rowbranch rowenvs _users _mode _rt _enabled _owner; do
    rowrepo="$(trim "${rowrepo%%#*}")"
    [ -z "$rowrepo" ] || [ "$rowrepo" = "-" ] && continue
    [ "$(repo_tail "$rowrepo")" = "$WANT" ] || continue

    name="$(trim "$name")"
    rowpath="$(trim "$rowpath")"
    rowbranch="$(trim "$rowbranch")"
    rowenvs="$(trim "$rowenvs")"

    # A Branch override wins, and narrows the row to that branch alone.
    if [ -n "$rowbranch" ] && [ "$rowbranch" != "-" ]; then
        [ "$rowbranch" = "$BRANCH" ] && emit "$name" "$rowpath"
        continue
    fi

    # A row without an override can only be reached by a branch that IS an
    # environment. A feature branch deploys nothing.
    [ "$BRANCH_IS_ENV" -eq 1 ] || continue

    # Otherwise the branch is the environment, and the row takes part when its
    # Envs say so. Empty or a dash means every environment.
    if [ -z "$rowenvs" ] || [ "$rowenvs" = "-" ]; then
        emit "$name" "$rowpath"
        continue
    fi
    IFS=',' read -r -a _envs <<< "$rowenvs"
    for e in "${_envs[@]}"; do
        [ "$(trim "$e")" = "$ENVIRONMENT" ] && { emit "$name" "$rowpath"; break; }
    done
done < <(grep -v '^[[:space:]]*#' "$SITES_CONF" | grep '|')
