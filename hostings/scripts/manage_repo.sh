#!/usr/bin/env bash
set -e

# =============================================================================
# Archive or delete a repository this machine created.
#
#   manage_repo.sh --archive <org>/site_a
#   manage_repo.sh --delete  <org>/site_a
#
# Called by the console when a row that owns a repository is deleted and the
# operator chose more than "leave it alone". Nothing else calls it.
#
# BOUNDED FIVE WAYS, because this is the most destructive thing the page can
# ask for:
#   1. Two verbs, and no way to pass anything else.
#   2. The slug must be owner/name, both plain, no path and no query.
#   3. The owner must be one the App is installed on. A repository belonging to
#      anybody else cannot be named, whatever the config says.
#   4. The token is the App's, minted for that owner, so GitHub refuses
#      anything the installation was not granted.
#   5. REPO_DELETE_OWNERS, when set, narrows 3 further: a test machine names its
#      own org there and cannot touch a customer's.
#
# ARCHIVE IS THE REVERSIBLE ONE and is why it exists: read only on GitHub, out
# of the way, and undone with one click. Delete is not recoverable at all.
#
# JSON on stdout, one object, so the page can report rather than guess.
# =============================================================================

print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

fail() { printf '{"ok":false,"error":"%s"}\n' "$1"; exit 1; }

VERB=""
case "${1:-}" in
    --archive) VERB="archive" ;;
    --delete)  VERB="delete" ;;
    *) print_error "Usage: $0 --archive|--delete <owner>/<name>"; fail "unknown verb" ;;
esac
SLUG="${2:-}"

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to read the App key."
    fail "not root"
fi

# owner/name, both plain. Anything with a slash too many, a dot-dot or a query
# is refused here rather than sent to GitHub to be interpreted.
if ! printf '%s' "$SLUG" | grep -qE '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$'; then
    fail "not an owner/name"
fi
case "$SLUG" in *..*) fail "not an owner/name" ;; esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
MANAGER_CLONE="/var/lib/hosting-manager/config-repo"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "${MANAGER_CLONE}/backup_config")"

TOKEN_SH="$SCRIPT_DIR/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="${MANAGER_CLONE}/hostings/scripts/github_app_token.sh"
[ -f "$TOKEN_SH" ] || fail "no App token script"

OWNER="${SLUG%%/*}"

# The owner has to be one the App is installed on. Without this the page could
# name any repository on the forge and the only thing stopping it would be what
# the credential happened to be able to reach.
#
# THIS STAYS OFF THE INTERFACE DELIBERATELY. It is an allow-list, not a repo
# operation: the question is "may this page act on this owner at all", asked
# before any verb is called. repo_host.sh has no verb for that and should not,
# because the answer is about THIS machine's installation, not about the forge.
if ! SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" --owners 2>/dev/null | grep -qxF "$OWNER"; then
    fail "the App is not installed on ${OWNER}"
fi

# A test machine may archive or delete only in its own org, so a test bug can
# never reach a customer repository. Unset means any installed owner (live).
DELETE_OWNERS="$(sed -n 's/^[[:space:]]*REPO_DELETE_OWNERS[[:space:]]*=//p' "$SITES_CONF" 2>/dev/null \
    | head -n 1 | tr -d '\r' | sed 's/#.*//')"
if [ -n "${DELETE_OWNERS// /}" ] && ! printf '%s\n' $DELETE_OWNERS | grep -qxF "$OWNER"; then
    fail "this machine may only ${VERB} repositories owned by: ${DELETE_OWNERS# }"
fi

# No token is minted here any more. It was handed to this script's own curl,
# and the service file mints its own at the point of use: a caller that never
# holds a credential cannot leak one, which is the whole point of the split.

# THE VERBS, not the transport. This knew the forge three times over: a PATCH
# body, two REST paths, and its own curl carrying the token minted above. All
# three are gone; repo_archive and repo_delete say what is meant and the
# service file knows how it is done.
#
# The inline curl fallback went with them. Principle 2b keeps a fallback for a
# lone script on a bare machine, and this is not one: it is reached from the
# console, which needs the pipeline tree anyway, and a destructive call is the
# worst place to keep a second code path that is never exercised.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}
# shellcheck source=/dev/null
. "$(_iface repo_host.sh)" || fail "no repository host available"

NAME="${SLUG#*/}"

if [ "$VERB" = "archive" ]; then
    code="$(repo_archive "$OWNER" "$NAME")" \
        || fail "the repository host refused to archive ${SLUG} (${code:-no answer})"
    printf '{"ok":true,"verb":"archive","slug":"%s"}\n' "$SLUG"
    exit 0
fi

code="$(repo_delete "$OWNER" "$NAME")" \
    || fail "the repository host refused to delete ${SLUG} (${code:-no answer})"
# The Repositories tab and the name-clash check read a cached list. A repository
# that has just gone must not sit in it until the TTL runs out.
rm -f /var/lib/hosting-manager/repo-names.json 2>/dev/null || true
printf '{"ok":true,"verb":"delete","slug":"%s"}\n' "$SLUG"
