#!/usr/bin/env bash
set -e

. "$(dirname "${BASH_SOURCE[0]}")/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }

# No -d flag here, unlike its siblings: a trace would print the Jenkins token.

# =============================================================================
# Reboot this machine, when an update has asked for it.
#
# Called by the hosting manager through sudo with no arguments, like
# trigger_update.sh. It refuses unless /var/run/reboot-required exists, so the
# page cannot be used to take every site down for no reason, and it refuses
# while Jenkins is building or has a build queued, so an apply or an update is
# never cut off halfway.
#
# The reboot is scheduled a few seconds out, so this returns and the page gets
# its answer before Apache goes down.
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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

REBOOT_FLAG="/var/run/reboot-required"
DELAY_SECONDS=5
TOKEN_FILE="/var/lib/hosting-manager/jenkins-token"
JENKINS_PORT="$(grep -v '^[[:space:]]*#' "${SITES_CONF:-$(conf_active /var/lib/hosting-manager/config-repo/backup_config)}" 2>/dev/null | grep '|' \
    | awk -F'|' '{gsub(/ /,"",$2); gsub(/ /,"",$3); if ($2=="jenkins") print $3}' | head -1)"
JENKINS_URL="http://127.0.0.1:${JENKINS_PORT:-11002}"

print_header "Reboot this machine"

if [ ! -f "$REBOOT_FLAG" ]; then
    print_info "No update is asking for a reboot, so nothing was done."
    exit 1
fi

# Unreadable Jenkins is not proof that nothing runs, so it refuses rather than
# guessing. A reboot without Jenkins is still one SSH command away.
if [ ! -f "$TOKEN_FILE" ]; then
    print_error "No Jenkins token at $TOKEN_FILE, so it cannot check for running builds."
    print_action "Reboot over SSH instead: sudo systemctl reboot"
    exit 1
fi
AUTH="$(head -n1 "$TOKEN_FILE")"
BUSY="$(curl -fsS -u "$AUTH" "${JENKINS_URL}/computer/api/json?tree=busyExecutors" 2>/dev/null \
    | grep -o '"busyExecutors":[0-9]*' | cut -d: -f2 || true)"
QUEUE_JSON="$(curl -fsS -u "$AUTH" "${JENKINS_URL}/queue/api/json?tree=items%5Bid%5D" 2>/dev/null || true)"
QUEUED="$(printf '%s' "$QUEUE_JSON" | grep -o '"id":' | wc -l || true)"
if [ -z "$BUSY" ] || [ -z "$QUEUE_JSON" ]; then
    print_error "Jenkins did not answer, so it cannot tell whether a build is running."
    print_action "Reboot over SSH instead: sudo systemctl reboot"
    exit 1
fi
if [ "$BUSY" -gt 0 ] || [ "${QUEUED:-0}" -gt 0 ]; then
    print_info "Jenkins has $BUSY build(s) running and ${QUEUED:-0} queued, so nothing was done."
    print_info "Press it again once they have finished."
    exit 1
fi

PACKAGES="$(tr '\n' ' ' < "${REBOOT_FLAG}.pkgs" 2>/dev/null || true)"
if systemd-run --quiet --on-active="$DELAY_SECONDS" --unit="console-reboot-$(date +%s)" \
        /bin/systemctl reboot; then
    logger -t reboot_machine "Reboot requested from the hosting manager. Packages: ${PACKAGES:-unknown}"
    print_success "Rebooting in $DELAY_SECONDS seconds. Every site is down for about a minute."
    exit 0
fi

print_error "The reboot could not be scheduled."
print_action "Reboot over SSH instead: sudo systemctl reboot"
exit 1
