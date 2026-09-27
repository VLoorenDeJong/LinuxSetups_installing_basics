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
# Start the deploy every row is waiting for, so a fresh machine fills itself.
#
# WHY THIS EXISTS. add_jenkins_site_jobs.sh writes the jobs; nothing runs them.
# A newly flashed machine therefore has a complete pipeline and empty document
# roots until somebody pushes to a site or presses Build, which is
# indistinguishable from a pipeline that does not work.
#
# This does what a GitHub push would do, once per row per environment, and it
# doubles as the end to end test of the whole chain: a row that deploys proves
# its repository, its credentials, its job, its branch and its document root in
# one go.
#
#   sudo ./trigger_first_deploys.sh              start them
#   sudo ./trigger_first_deploys.sh --dry-run    list what would be started
#   sudo ./trigger_first_deploys.sh --row example_org
#
# Only rows that name a repository are touched: a row with nothing to clone has
# nothing to deploy. A job already building or queued is left alone, so running
# this twice starts nothing: a job that has already built once is left alone,
# and FORCE_FIRST_DEPLOYS=1 is the way to mean it anyway.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 [--dry-run] [--row NAME]" >&2
    echo "" >&2
    echo "  --dry-run    list the jobs that would be started, start none." >&2
    echo "  --row NAME   only this row, rather than every row with a repository." >&2
    echo "" >&2
    echo "  FORCE_FIRST_DEPLOYS=1  start a job that has already built once." >&2
    exit 1
}

DRY_RUN=0
ONLY_ROW=""
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run) DRY_RUN=1; shift ;;
        --row)     ONLY_ROW="${2:-}"
                   [ -n "$ONLY_ROW" ] || { print_error "--row needs a row name."; usage; }
                   shift 2 ;;
        --row=*)   ONLY_ROW="${1#--row=}"; shift ;;
        -h|--help) usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

# A dry run reads a config and a directory listing, so it needs no privilege:
# refusing it would make the safe way to look the harder one.
if [ "$DRY_RUN" -ne 1 ] && [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
JENKINS_HOME="${JENKINS_HOME:-/var/lib/jenkins}"
JENKINS_URL="${JENKINS_URL:-http://127.0.0.1:11002}"
TOKEN_FILE="${TOKEN_FILE:-/var/lib/hosting-manager/jenkins-token}"

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; printf '%s' "${s%"${s##*[![:space:]]}"}"; }

conf_get() {
    local key="$1" fallback="${2:-}" v
    v="$(grep -m1 -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
         | tr -d '\r' | sed 's/^[^=]*=//' | sed 's/#.*$//')" || true
    v="$(trim "$v")"
    [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$fallback"
}

# A row lists the environments it exists in. Empty means all of them, which is
# the same reading every generator here uses.
row_in_env() {
    local list="$1" want="$2" e
    list="$(trim "$list")"
    [ -z "$list" ] || [ "$list" = "-" ] && return 0
    IFS=',' read -r -a _envs_arr <<< "$list"
    for e in "${_envs_arr[@]}"; do
        [ "$(trim "$e")" = "$want" ] && return 0
    done
    return 1
}

# =============================================================================
# Pre-flight. Everything that would stop this, before a single job is started.
# =============================================================================
ERRORS=()
[ -f "$SITES_CONF" ] || ERRORS+=("No config at $SITES_CONF, so no row could be read.")
[ -d "$JENKINS_HOME/jobs" ] || ERRORS+=("No Jenkins jobs directory at $JENKINS_HOME/jobs. Run add_jenkins.sh first.")
if [ "$DRY_RUN" -ne 1 ] && [ ! -s "$TOKEN_FILE" ]; then
    ERRORS+=("No Jenkins token at $TOKEN_FILE, so nothing could be started. add_jenkins.sh mints it.")
fi
# Asked rather than assumed. Jenkins takes a minute or two to answer after a
# reboot, and a silent Jenkins looks exactly like a job that is not running:
# every row would then be reported red for a reason that is neither.
#
# WITH THE TOKEN, because Jenkins here answers 403 to an anonymous /api/json and
# -f turns that into a failure. The probe therefore reported "Jenkins does not
# answer" on a Jenkins that was up, listening and healthy, and this script could
# never start a single job. Every /build call below already authenticates; only
# the check that guards them did not.
# Only with a token: `curl -u ""` stops to ask for a password on the terminal.
if [ "$DRY_RUN" -ne 1 ] && [ -s "$TOKEN_FILE" ] && ! curl -fsS -o /dev/null --max-time 10 \
        -u "$(head -n1 "$TOKEN_FILE")" "${JENKINS_URL}/api/json" 2>/dev/null; then
    ERRORS+=("Jenkins does not answer on ${JENKINS_URL}, so no job could be started.")
    ERRORS+=("Look at it with: sudo systemctl status jenkins --no-pager")
fi
if [ ${#ERRORS[@]} -gt 0 ]; then
    print_header "First deploys"
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

IFS=',' read -r -a DEPLOY_ENVS <<< "$(conf_get ENVS "live,test,accept,skunk")"
for i in "${!DEPLOY_ENVS[@]}"; do DEPLOY_ENVS[$i]="$(trim "${DEPLOY_ENVS[$i]}")"; done

print_header "First deploys"
print_status "Config:       $SITES_CONF"
print_status "Environments: ${DEPLOY_ENVS[*]}"
[ -n "$ONLY_ROW" ] && print_status "Row:          $ONLY_ROW"
[ "$DRY_RUN" -eq 1 ] && print_info "Dry run: nothing is started."

STARTED=0
NAMED_GENERATOR=0
FORCE="${FORCE_FIRST_DEPLOYS:-0}"
SKIPPED=0
FAILED=()

# One job. Started the way trigger_site_job.sh starts one, including the fall
# back to /build: a pipeline job learns its parameters by running once, so a job
# that has never built refuses buildWithParameters with a 400 that reads like a
# bad token and is not.
start_job() {
    local row="$1" env="$2" path state err
    path="job/${row}/job/deploy-${env}"

    if [ ! -f "$JENKINS_HOME/jobs/$row/jobs/deploy-${env}/config.xml" ]; then
        print_info "  $row/deploy-$env does not exist, so it was skipped."
        [ "$NAMED_GENERATOR" -eq 0 ] && {
            print_action "  Write the missing jobs with: sudo $SCRIPT_DIR/add_jenkins_site_jobs.sh"
            NAMED_GENERATOR=1
        }
        SKIPPED=$(( SKIPPED + 1 ))
        return 0
    fi

    if [ "$DRY_RUN" -eq 1 ]; then
        print_status "  would start $row/deploy-$env"
        STARTED=$(( STARTED + 1 ))
        return 0
    fi

    state="$(curl -fsS -u "$(head -n1 "$TOKEN_FILE")" \
        "${JENKINS_URL}/${path}/api/json?tree=inQueue,lastBuild%5Bnumber,building%5D" 2>/dev/null || true)"
    case "$state" in
        *'"building":true'*|*'"inQueue":true'*)
            print_info "  $row/deploy-$env is already running, so it was left alone."
            SKIPPED=$(( SKIPPED + 1 ))
            return 0
            ;;
    esac

    # Already built once, so this machine is no longer the fresh one this script
    # exists for. Re-running the whole install would otherwise queue a build per
    # row per environment, every time, for jobs that answer "no change".
    case "$state" in
        *'"number"'*)
            if [ "$FORCE" -ne 1 ]; then
                print_info "  $row/deploy-$env has built before, so it was left alone. FORCE_FIRST_DEPLOYS=1 overrides."
                SKIPPED=$(( SKIPPED + 1 ))
                return 0
            fi
            ;;
    esac

    # These jobs take no parameters: add_jenkins_site_jobs.sh writes deploy-<env>
    # pinned to one branch, which is what makes the push trigger safe. /build is
    # therefore the right call, and buildWithParameters is the fallback for the
    # day one of them gains a parameter.
    err="$(curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
            "${JENKINS_URL}/${path}/build" 2>&1)" \
    || err="$(curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
            --data-urlencode "ROW=" \
            "${JENKINS_URL}/${path}/buildWithParameters" 2>&1)" \
    || {
        print_error "  Could not start $row/deploy-$env"
        [ -n "$err" ] && print_error "    $(printf '%s' "$err" | tail -n1)"
        FAILED+=("$row/deploy-$env")
        return 0
    }

    print_success "  Started $row/deploy-$env"
    STARTED=$(( STARTED + 1 ))
    return 0
}

# A SETTING, not a row: PANEL lines hold pipes too. Same guard as the generators.
while IFS='|' read -r type name _port _path _sub _ds _opts _auth repo _branch envs _users _mode _rt _enabled _owner; do
    type="$(trim "${type%%#*}")"
    name="$(trim "$name")"
    repo="$(trim "$repo")"
    [ -z "$type" ] && continue
    [ -z "$name" ] && continue
    [ -n "$ONLY_ROW" ] && [ "$name" != "$ONLY_ROW" ] && continue

    case "$type" in
        app|website|php|docroot) ;;
        *) continue ;;
    esac

    # No repository, nothing to clone, so nothing to deploy. This is what keeps
    # a hand-made document root from being overwritten by an empty checkout.
    if [ -z "$repo" ] || [ "$repo" = "-" ]; then
        print_info "$name names no repository, so it has nothing to deploy."
        continue
    fi

    for env in ${DEPLOY_ENVS+"${DEPLOY_ENVS[@]}"}; do
        [ -z "$env" ] && continue
        row_in_env "$envs" "$env" || continue
        start_job "$name" "$env"
    done
done < <(grep -v '^[[:space:]]*#' "$SITES_CONF" \
    | grep -vE '^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*[[:space:]]*=' \
    | grep '|')

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
    print_status "$STARTED job(s) would be started, $SKIPPED skipped."
else
    print_status "$STARTED job(s) started, $SKIPPED skipped."
fi
if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "${#FAILED[@]} job(s) could not be started:"
    for f in "${FAILED[@]}"; do print_error "  $f"; done
    print_action "Press Build on them in Jenkins, and look at why the token or the job refused."
    exit 1
fi

# Deliberately not waited for. Every one of these clones a repository and copies
# files, and the install has more to do; the builds report themselves in Jenkins
# and a failure is visible there rather than being hidden by a wait here.
[ "$STARTED" -gt 0 ] && print_info "They run in Jenkins. A red build there is a real failure, not a missing step."
print_success "First deploys handled."
exit 0
