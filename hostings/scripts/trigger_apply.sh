#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

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
# A trace prints the secrets this reads, so only a caller who could read them
# anyway gets one: root, or the sudo group. The console passes -d via a * grant.
if [ "$DEBUG_MODE" = "1" ] && [ -n "${SUDO_USER:-}" ] && [ "$SUDO_USER" != root ] \
   && ! id -nG "$SUDO_USER" 2>/dev/null | grep -qw sudo; then
    DEBUG_MODE=0
fi
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Ask Jenkins to apply the published config to this machine.
#
# THIS IS THE ONE THAT CHANGES THE MACHINE, and it is deliberately separate from
# saving. Decided 2026-08-02: saving pushes and checks, the operator reads the
# drift report, and only then presses Apply. Applying on save would let a typo
# in a browser reach the sites a minute later.
#
# Like the publisher, it takes no arguments: the job name is fixed here, so
# there is no argument list for a compromised page to smuggle anything into.
# The Jenkins token is 0600 root and this runs as root, so the page never holds
# a credential.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
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
# A path now, not a name: the jobs live in folders, and Jenkins spells a folder
# in a URL as another /job/ segment. machine/apply-config becomes
# job/machine/job/apply-config.
JENKINS_JOB="machine/apply-config"
JOB_PATH="job/${JENKINS_JOB//\//\/job\/}"

print_header "Apply the published config"

# NO JENKINS ON THIS MACHINE: the job's one real step runs directly, as its
# own transient unit, so the page is back at once as it is with Jenkins. From
# the root-owned pipeline tree only, never the console's clone, which the
# page's own account can write.
if ! id -u jenkins >/dev/null 2>&1; then
    APPLY_SCRIPT="/usr/local/lib/linuxbasics/hostings/scripts/maintain_services.sh"
    APPLY_UNIT="hosting-apply"
    if [ ! -f "$APPLY_SCRIPT" ]; then
        print_error "No $APPLY_SCRIPT, so nothing was applied."
        print_action "Make the pipeline tree first: sudo bash add_pipeline_scripts.sh"
        exit 1
    fi
    if systemctl is-active --quiet "$APPLY_UNIT"; then
        print_info "An apply is already running, so nothing was started."
        print_action "It started before this change, so it does not carry it."
        print_action "Press Make it live again once it has finished."
        exit 2
    fi
    if systemd-run --unit="$APPLY_UNIT" --collect --quiet \
         bash "$APPLY_SCRIPT" --apply --changed --prune; then
        print_info "Apply started. Follow it with: journalctl -u $APPLY_UNIT -f"
        exit 0
    fi
    print_error "systemd-run could not start the apply."
    exit 1
fi

if [ ! -f "$TOKEN_FILE" ]; then
    print_error "No Jenkins token at $TOKEN_FILE, so no job was started."
    print_action "Create one: in Jenkins, your user -> Security -> API token -> Add new token"
    print_action "Then, replacing the parts in angle brackets:"
    print_action "  echo '<jenkins-user>:<token>' | sudo tee $TOKEN_FILE"
    print_action "  sudo chmod 600 $TOKEN_FILE && sudo chown root:root $TOKEN_FILE"
    print_action "Until then, press Build on the '$JENKINS_JOB' job yourself."
    exit 1
fi

# Already running, or already waiting to run. The POST returns the moment
# Jenkins accepts it, so the page is back and clickable while the job has barely
# started, and a second press queues a second apply behind the first.
STATE="$(curl -fsS -u "$(head -n1 "$TOKEN_FILE")" \
    "${JENKINS_URL}/${JOB_PATH}/api/json?tree=inQueue,lastBuild%5Bbuilding%5D" \
    2>/dev/null || true)"

case "$STATE" in
    *'"building":true'*|*'"inQueue":true'*)
        print_info "The '$JENKINS_JOB' job is already running, so nothing was started."
        print_action "It started before this change, so it does not carry it."
        print_action "Press Make it live again once it has finished."
        print_info "Watch it in Jenkins. It finishes on its own."
        # 2, not 1: this is "did not need starting", and a caller that has
        # just published a config has to tell those apart. Exit 1 read as
        # "the apply job did not start, the machine is unchanged", which is
        # true and useless: it did not say an apply was running, nor that it
        # started before the change and will not carry it.
        exit 2
        ;;
esac

# /build, not /buildWithParameters: the job takes no parameters any more.
#
# It used to take two, PRUNE and CHANGED_ONLY, which this script sent as true and
# the Build button in Jenkins left false. The same job then did different things
# depending on who started it, with nothing on screen saying which, and a build
# from the UI that rewrote every row read as a bug for an hour. Applying is one
# behaviour now: only the rows that changed, and orphans removed.
#
# To rewrite every row, run maintain_services.sh --apply on the machine.
if curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
        "${JENKINS_URL}/${JOB_PATH}/build" >/dev/null 2>&1; then
    print_success "Started the '$JENKINS_JOB' job. Watch it in Jenkins for the output."
    exit 0
fi

# NOT ANSWERING AT ALL IS NOT THE SAME AS REFUSING, and saying "refused" for
# both sent the operator to check a token while the service was simply stopped.
# Measured 2026-09-06 by stopping Jenkins and pressing the button: the message
# named three causes and not the actual one.
#
# curl's own exit code separates them. 7 is "could not connect", 28 is a
# timeout, and both mean nothing on the other end had an opinion about the
# request. A GET of /login with the body thrown away: one request, no side
# effect, and it answers before any job or token is involved.
#
# `|| _reach=$?`, never a bare call then `$?`: this script runs under set -e, so
# the failing curl ended the script before the exit code could be read and the
# operator got a header and nothing else. Caught by running it, one minute after
# writing it.
_reach=0
curl -fsS --max-time 5 -o /dev/null "${JENKINS_URL}/login" 2>/dev/null || _reach=$?
if [ "$_reach" -eq 7 ] || [ "$_reach" -eq 28 ]; then
    print_error "Jenkins is not answering on ${JENKINS_URL}, so nothing is being applied."
    print_info "The config IS published. Only the machine is behind."
    print_action "Start it: sudo systemctl start jenkins"
    print_action "Then press Make it live again, or run the job yourself."
    exit 1
fi

print_error "Jenkins answered but refused the request, so nothing is being applied."
print_info "Usually the token is wrong, the '$JENKINS_JOB' job does not exist,"
print_info "or its parameters changed and this script no longer sends them all."
print_action "Press Build on the '$JENKINS_JOB' job instead."
exit 1
