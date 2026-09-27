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
# Ask Jenkins to run the operating system update job.
#
# The second privileged half of the hosting manager, alongside
# publish_hostings.sh, and it exists for one reason: the Jenkins token is
# 0600 root, and the page runs as hosting-manager. A page that reads the token holds a
# credential, which is the one thing the hosting manager is built not to do.
#
# So the page calls this through sudo with no arguments, root reads the token,
# and the token never passes through a process that serves HTTP.
#
# It starts a job. It does not update anything itself, and it never reboots:
# the job reports whether a reboot is needed and leaves the decision alone.
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
# in a URL as another /job/ segment.
JENKINS_JOB="machine/update-packages"
JOB_PATH="job/${JENKINS_JOB//\//\/job\/}"

print_header "Update this machine"

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
# Jenkins accepts it, so the page is back and clickable while the job has
# barely started, and a second press queues a second run of the same thing.
#
# Checked here rather than guarded in the page: the page is one caller, and this
# is true for anything that presses the button.
STATE="$(curl -fsS -u "$(head -n1 "$TOKEN_FILE")" \
    "${JENKINS_URL}/${JOB_PATH}/api/json?tree=inQueue,lastBuild%5Bbuilding%5D" \
    2>/dev/null || true)"

case "$STATE" in
    *'"building":true'*|*'"inQueue":true'*)
        print_info "The '$JENKINS_JOB' job is already running, so nothing was started."
        print_info "Watch it in Jenkins. It finishes on its own."
        exit 1
        ;;
esac

if curl -fsS -X POST -u "$(head -n1 "$TOKEN_FILE")" \
        "${JENKINS_URL}/${JOB_PATH}/build" >/dev/null 2>&1; then
    print_success "Started the '$JENKINS_JOB' job. Watch it in Jenkins for the output."
    exit 0
fi

print_error "Jenkins refused the request, so no job was started."
print_info "Usually the token is wrong or the '$JENKINS_JOB' job does not exist."
print_action "Press Build on the '$JENKINS_JOB' job instead."
exit 1
