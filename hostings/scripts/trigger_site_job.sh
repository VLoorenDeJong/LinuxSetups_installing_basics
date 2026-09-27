#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
DEBUG_MODE=0
_dbg_args=()
# --stop cancels the running build of the same job instead of starting one. It
# sits here, beside --debug, so the two positional arguments and every bound on
# them stay exactly as they are: cancelling is the same permission as starting,
# on the same job, and deserves no second path to reach it.
STOP_MODE=0
for _a in "$@"; do
    case "$_a" in
        -d|--debug) DEBUG_MODE=1 ;;
        --stop)     STOP_MODE=1 ;;
        *)          _dbg_args+=("$_a") ;;
    esac
done
set -- ${_dbg_args+"${_dbg_args[@]}"}
unset _a _dbg_args
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Start one site's job from the hosting manager.
#
# trigger_apply.sh and trigger_update.sh each start one hardcoded job. Now that
# every row has a folder of its own, the page needs to start a job for a row it
# is told about at the time, so the row and the action are arguments.
#
#   trigger_site_job.sh ispaddress_api set-up-this-site
#
# THE ACTION IS FROM A FIXED LIST, NOT FROM THE CALLER'S IMAGINATION. The page
# runs this through sudo, so an unchecked job name would let anything reachable
# in Jenkins be started from a web form. Four fixed actions are allowed, plus
# deploy-<env> for an environment the config declares, and nothing else is.
#
# THE ROW MUST EXIST IN hostings.conf. That is what stops a crafted row name
# from reaching a folder it should not, and it is checked against the config
# rather than against Jenkins: the config is the thing under review.
# =============================================================================

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[1m=== %s ===\033[0m\n" "$1"; }

usage() {
    echo "Usage: $0 <row> <action>" >&2
    echo "" >&2
    echo "  row      a name from the second column of hostings.conf" >&2
    echo "  action   one of:" >&2
    echo "             set-up-this-site           unit, vhost and certificate" >&2
    echo "             1-write-service-unit       the unit alone" >&2
    echo "             2-write-apache-vhost       the vhost alone" >&2
    echo "             3-request-certificate      the certificate alone" >&2
    echo "             deploy-<env>               re-run that environment's deploy" >&2
    exit 1
}

ROW="${1:-}"
ACTION="${2:-}"
[ -z "$ROW" ] && usage
[ -z "$ACTION" ] && usage

# The allowed actions, checked BEFORE the root check so a bad argument is
# refused whoever runs it and the refusal is testable without privilege.
#
case "$ACTION" in
    set-up-this-site|1-write-service-unit|2-write-apache-vhost|3-request-certificate) ;;
    deploy-*)
        # Deploy jobs were refused here on purpose until 2026-09-10: putting new
        # code on the machine is not a thing a page behind a login should start
        # with one press. The owner asked for the button anyway, having read that,
        # so the refusal becomes a bound instead: the environment must be one
        # the config declares, so `deploy-anything` cannot reach a job by name.
        _env="${ACTION#deploy-}"
        _envs="$(grep -E '^[[:space:]]*ENVS[[:space:]]*=' \
                 "${SITES_CONF:-$(conf_active /etc/hostings)}" \
                 2>/dev/null | head -1 | cut -d= -f2- | tr -d ' \r' | tr ',' ' ')"
        case " ${_envs:-live test accept skunk} " in
            *" $_env "*) ;;
            *)
                print_error "'$_env' is not an environment in the config, so nothing was started."
                exit 1
                ;;
        esac
        ;;
    *)
        print_error "'$ACTION' is not an action this script will start."
        usage
        ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 $ROW $ACTION"
    exit 1
fi

# Fixed paths. Nothing here is taken from the caller.
MANAGER_HOME="/var/lib/hosting-manager"
TOKEN_FILE="${MANAGER_HOME}/jenkins-token"
# THE PORT COMES FROM THE JENKINS ROW, not from a number repeated here. Six
# scripts held `http://127.0.0.1:11002` as a literal while add_jenkins.sh
# derived it from the config, so moving the port in hostings.conf would have
# moved Jenkins and left every one of these dialling the old one. The symptom
# would be "Jenkins is not answering" with the config saying otherwise.
#
# Same awk as add_jenkins.sh:1031, deliberately duplicated rather than sourced:
# each script here has to run alone on a machine that has only this file.
#
# 11002 stays as the fallback, so a machine whose config cannot be read behaves
# exactly as it did before.
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "${SITES_CONF:-$(conf_active /etc/hostings)}" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_URL="http://127.0.0.1:${JENKINS_PORT:-11002}"
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

print_header "Start '$ACTION' for $ROW"

if [ ! -f "$SITES_CONF" ]; then
    print_error "No config at $SITES_CONF, so the row could not be checked."
    exit 1
fi

# Checked against the config, which is the reviewed thing, rather than against
# whatever folders happen to exist in Jenkins.
if ! awk -F'|' -v n="$ROW" '
        /^[[:space:]]*#/ { next }
        NF > 1 { gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2)
                 if ($2 == n) found = 1 }
        END { exit !found }' "$SITES_CONF"; then
    print_error "'$ROW' is not a row in the published config, so nothing was started."
    exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
    print_error "No Jenkins token at $TOKEN_FILE, so no job was started."
    print_action "Press Build on '$ROW/$ACTION' in Jenkins yourself until there is one."
    exit 1
fi

JOB_PATH="job/${ROW}/job/${ACTION}"

# Already running, or already waiting to run. The POST returns the moment Jenkins
# accepts it, so the page is back and clickable while the job has barely started.
STATE="$(curl -fsS -u "$(head -n1 "$TOKEN_FILE")" \
    "${JENKINS_URL}/${JOB_PATH}/api/json?tree=inQueue,lastBuild%5Bbuilding%5D" \
    2>/dev/null || true)"

if [ -z "$STATE" ]; then
    print_error "Jenkins did not answer for '$ROW/$ACTION'."
    print_action "Usually the folder does not exist yet. Create it with:"
    print_action "  sudo bash hostings/scripts/add_jenkins_site_jobs.sh"
    exit 1
fi

# Cancel, and only what is running right now. `stop` on a build that has already
# finished answers 200 and does nothing, which would read as "cancelled" for a
# build that was never stopped, so the state is checked first and a job that is
# not running is refused rather than quietly agreed with.
if [ "$STOP_MODE" = "1" ]; then
    case "$STATE" in
        *'"building":true'*|*'"inQueue":true'*) ;;
        *)
            print_info "'$ROW/$ACTION' is not running, so there was nothing to cancel."
            exit 1
            ;;
    esac
    if curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
            "${JENKINS_URL}/${JOB_PATH}/lastBuild/stop" >/dev/null 2>&1; then
        print_success "Asked Jenkins to cancel '$ROW/$ACTION'."
        exit 0
    fi
    print_error "Jenkins refused to cancel '$ROW/$ACTION'."
    exit 1
fi

case "$STATE" in
    *'"building":true'*|*'"inQueue":true'*)
        print_info "'$ROW/$ACTION' is already running, so nothing was started."
        print_info "Watch it in Jenkins. It finishes on its own."
        exit 1
        ;;
esac

# set-up-this-site declares parameters and the three atomic jobs declare ROW, so
# every one of them needs buildWithParameters: Jenkins refuses /build outright on
# a parameterised job, which reads as "the token is wrong" and is not.
#
# ROW is sent empty on purpose. The job resolves it from its own folder, and
# sending it would let this script disagree with where the job actually lives.
if curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
        --data-urlencode "ROW=" \
        "${JENKINS_URL}/${JOB_PATH}/buildWithParameters" >/dev/null 2>&1; then
    print_success "Started '$ROW/$ACTION'. Watch it in Jenkins for the output."
    exit 0
fi

# A pipeline job learns its parameters by running once, so a job that has never
# been built answers buildWithParameters with 400 "is not parameterized". The
# unparameterised endpoint is the only one that works then, and it stops being
# accepted once the first build has taught Jenkins the block.
if curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
        "${JENKINS_URL}/${JOB_PATH}/build" >/dev/null 2>&1; then
    print_success "Started '$ROW/$ACTION', its first build. Watch it in Jenkins."
    exit 0
fi

print_error "Could not start '$ROW/$ACTION'."
print_info "Usually the token is wrong, or the job does not exist yet."
print_action "Press Build on it in Jenkins instead."
exit 1
