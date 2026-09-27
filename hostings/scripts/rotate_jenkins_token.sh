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
[ "$DEBUG_MODE" = "1" ] && set -x

# =============================================================================
# Replace the Jenkins API token the hosting manager uses with a fresh one.
#
# Run monthly by jenkins-token-rotate.timer, and by hand whenever a token has
# escaped. It authenticates with the CURRENT token to mint the next one, so
# nothing has to be typed and no password is involved.
#
# THE ORDER IS THE WHOLE POINT:
#
#   mint  ->  verify the new token answers  ->  write the file  ->  revoke the old
#
# A rotation that wrote first would break Apply and Update silently, and the
# first anyone would learn of it is a button that does nothing a month later.
# Every failure below leaves the working token exactly where it was.
#
# The file is two lines. Line 1 is what callers read with `head -n1`; line 2 is
# the token's own UUID, which is the only handle Jenkins accepts for revoking
# it. A file without line 2 rotates fine, it just cannot clean up its
# predecessor.
#
#   user:token
#   00000000-0000-0000-0000-000000000000
#
# Usage:
#   sudo ./rotate_jenkins_token.sh
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
TOKEN_NAME="hosting-manager"

print_header "Rotate the Jenkins token"

# -----------------------------------------------------------------------------
# Pre-flight. Everything this needs, before anything is minted.
# -----------------------------------------------------------------------------
if [ ! -s "$TOKEN_FILE" ]; then
    print_error "No token at $TOKEN_FILE, so there is nothing to rotate with."
    print_info "A token can only mint its successor. The first one comes from"
    print_info "add_jenkins.sh, which has Jenkins create it at startup:"
    print_action "  sudo ./hostings/scripts/add_jenkins.sh"
    exit 1
fi

if ! systemctl is-active --quiet jenkins; then
    print_error "Jenkins is not running, so no token can be minted."
    print_action "Start it and run this again: sudo systemctl start jenkins"
    exit 1
fi

CURRENT="$(head -n1 "$TOKEN_FILE")"
OLD_UUID="$(sed -n '2p' "$TOKEN_FILE")"
JENKINS_USER="${CURRENT%%:*}"

if [ -z "$JENKINS_USER" ] || [ "$JENKINS_USER" = "$CURRENT" ]; then
    print_error "$TOKEN_FILE does not hold 'user:token' on its first line."
    print_action "Fix it, or delete it and re-run add_jenkins.sh to mint a new one."
    exit 1
fi

# The current token has to work before anything is minted with it, and this is
# also the check that says "the token is already dead" rather than minting a
# second one beside a broken first.
if ! curl -fsS -u "$CURRENT" "${JENKINS_URL}/api/json?tree=mode" >/dev/null 2>&1; then
    print_error "Jenkins rejected the token that is in $TOKEN_FILE."
    print_info "Nothing was minted and nothing was changed."
    print_action "Revoke it in Jenkins, then re-run add_jenkins.sh to mint a new one."
    exit 1
fi

print_status "Rotating the token for '$JENKINS_USER'."

# -----------------------------------------------------------------------------
# Mint
#
# A crumb is sent even though a request authenticated by an API token is exempt
# from CSRF in current Jenkins: it costs one call, and the exemption is a
# version-dependent behaviour rather than a promise.
# -----------------------------------------------------------------------------
CRUMB="$(curl -fsS -u "$CURRENT" \
    "${JENKINS_URL}/crumbIssuer/api/xml?xpath=concat(//crumbRequestField,\":\",//crumb)" \
    2>/dev/null || true)"

CRUMB_ARGS=()
[ -n "$CRUMB" ] && CRUMB_ARGS=(-H "$CRUMB")

# Dated, so the list in Jenkins says when each one was made and a stale entry is
# recognisable without cross-referencing anything.
NEW_NAME="${TOKEN_NAME}-$(date +%Y-%m-%d)"
MINT_URL="${JENKINS_URL}/user/${JENKINS_USER}/descriptorByName/jenkins.security.ApiTokenProperty/generateNewToken"

RESPONSE="$(curl -fsS -X POST -u "$CURRENT" ${CRUMB_ARGS+"${CRUMB_ARGS[@]}"} \
    --data-urlencode "newTokenName=${NEW_NAME}" "$MINT_URL" 2>/dev/null || true)"

# Deliberately not jq: it is not installed on a fresh machine, and adding a
# dependency to read two fields out of one known response is not worth it.
NEW_TOKEN="$(printf '%s' "$RESPONSE" | sed -n 's/.*"tokenValue" *: *"\([^"]*\)".*/\1/p')"
NEW_UUID="$(printf '%s' "$RESPONSE" | sed -n 's/.*"tokenUuid" *: *"\([^"]*\)".*/\1/p')"

if [ -z "$NEW_TOKEN" ]; then
    print_error "Jenkins did not return a new token, so nothing was changed."
    print_info "The old token is still in place and still works."
    print_info "Response was: ${RESPONSE:-<empty>}"
    exit 1
fi

# -----------------------------------------------------------------------------
# Verify BEFORE the file is touched. This is the step that makes the whole
# thing safe to run unattended.
# -----------------------------------------------------------------------------
if ! curl -fsS -u "${JENKINS_USER}:${NEW_TOKEN}" \
        "${JENKINS_URL}/api/json?tree=mode" >/dev/null 2>&1; then
    print_error "The new token does not authenticate, so it was not written."
    print_info "The old token is still in place and still works."
    if [ -n "$NEW_UUID" ]; then
        curl -fsS -X POST -u "$CURRENT" ${CRUMB_ARGS+"${CRUMB_ARGS[@]}"} \
            --data-urlencode "tokenUuid=${NEW_UUID}" \
            "${JENKINS_URL}/user/${JENKINS_USER}/descriptorByName/jenkins.security.ApiTokenProperty/revoke" \
            >/dev/null 2>&1 || true
        print_info "The token that was just minted has been revoked again."
    fi
    exit 1
fi

# -----------------------------------------------------------------------------
# Write, atomically. A half-written token file is a machine with no working
# button and no obvious reason why.
# -----------------------------------------------------------------------------
TMP="$(mktemp "${MANAGER_HOME}/.jenkins-token.XXXXXX")"
chmod 600 "$TMP"
chown root:root "$TMP"
printf '%s:%s\n%s\n' "$JENKINS_USER" "$NEW_TOKEN" "$NEW_UUID" > "$TMP"
mv -f "$TMP" "$TOKEN_FILE"
print_success "New token written to $TOKEN_FILE."

# -----------------------------------------------------------------------------
# Revoke the predecessor, last, and never fatally: the new token is already in
# place and working, so a failure here leaves a stale entry in a list rather
# than a broken machine.
# -----------------------------------------------------------------------------
if [ -z "$OLD_UUID" ]; then
    print_info "The previous token had no UUID recorded, so it was left alone."
    print_action "Revoke it by hand: Jenkins -> ${JENKINS_USER} -> Security -> API token"
    exit 0
fi

if curl -fsS -X POST -u "${JENKINS_USER}:${NEW_TOKEN}" ${CRUMB_ARGS+"${CRUMB_ARGS[@]}"} \
        --data-urlencode "tokenUuid=${OLD_UUID}" \
        "${JENKINS_URL}/user/${JENKINS_USER}/descriptorByName/jenkins.security.ApiTokenProperty/revoke" \
        >/dev/null 2>&1; then
    print_success "The previous token has been revoked."
else
    print_info "The previous token could not be revoked, so it still works."
    print_action "Revoke it by hand: Jenkins -> ${JENKINS_USER} -> Security -> API token"
fi

exit 0
