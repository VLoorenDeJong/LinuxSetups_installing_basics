#!/usr/bin/env bash
set -e

# =============================================================================
# Print every repository name the App can see, per owner, as JSON.
#
#   list_repo_names.sh
#
#   {"create_owner":"<org>",
#    "owners":{"<org>":["site_a"],"<owner>":["the config repository"]}}
#
# WHY THE CONSOLE NEEDS THIS. A new row's name becomes a repository name, and a
# clash is only discovered when provision_repo.sh refuses halfway through an
# apply. The drawer checks it while it is being typed instead.
#
# BOTH OWNERS, and a clash on either one blocks. GitHub allows the same name
# under two owners; this does not, because a transfer leaves a redirect behind
# and creating the name it moved away from silently breaks the old links.
# See .claude/docs/github-org-decisions.md, decision 6.
#
# WHAT IT IS NOT. An App installation lists only what the App was granted, so
# this answers "no clash I can see", never "no clash". It is a warning that
# saves a failed apply, not an authority.
#
# JSON goes to stdout and nothing else does: the page parses it.
# =============================================================================

print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to read the App key."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"

# CACHED, because this costs one GitHub round trip per owner and the page waits
# on it. Measured 2026-09-03: 2.6 seconds, which is the Repositories tab filling
# in visibly rather than appearing.
#
# The list of repositories somebody owns changes when a repository is created,
# renamed or deleted, and provision_repo.sh drops this file when it does any of
# those. There is no TTL: a change made on github.com is picked up by --fresh.
#
# --fresh skips it, for a caller that has just changed something.
CACHE="/var/lib/hosting-manager/repo-names.json"
CACHE_TTL="${REPO_NAMES_TTL:-0}"
FRESH=0
[ "${1:-}" = "--fresh" ] && FRESH=1

if [ "$FRESH" -eq 0 ] && [ -s "$CACHE" ]; then
    _age=$(( $(date +%s) - $(stat -c %Y "$CACHE" 2>/dev/null || echo 0) ))
    # 0 means no expiry, and that is the default since 2026-09-04. The TTL
    # was 300s, so a page opened five minutes after the last look paid the
    # GitHub round trip again: measured 3.98s on a cache file that existed.
    # Creation and deletion both drop this file, so the only change it can
    # miss is one made on github.com, and --fresh answers that.
    if [ "$CACHE_TTL" -eq 0 ] || [ "$_age" -lt "$CACHE_TTL" ]; then
        cat "$CACHE"
        exit 0
    fi
fi

# Written whole and moved into place, never appended to: a reader that opens
# this mid-write must not get half a JSON document.
_TMP_CACHE="$(mktemp)"
trap 'rm -f "$_TMP_CACHE"' EXIT
exec 8>&1
exec 1> >(tee "$_TMP_CACHE" >&8)

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"
    v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

CREATE_ORG="$(conf_get GITHUB_ORG "")"

# The installed copy of this script lives alone in /usr/local/sbin, so the
# token minter is not beside it. The pipeline tree is where every other
# privileged script reads its siblings from.
TOKEN_SH="$SCRIPT_DIR/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
[ -f "$TOKEN_SH" ] || TOKEN_SH="/usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh"
if [ ! -f "$TOKEN_SH" ]; then
    print_error "github_app_token.sh not found, so no repository names can be read."
    print_action "Refresh the pipeline tree: sudo /usr/local/lib/linuxbasics/hostings/scripts/add_pipeline_scripts.sh"
fi

# The personal account, read from the checkout this script came out of, which is
# the same derivation provision_repo.sh uses.
url="$(git -C "$(readlink -f /etc/hostings)" remote get-url origin 2>/dev/null || true)"
case "$url" in
    git@*:*)   PERSONAL="$(echo "$url" | sed -E 's#^[^:]+:([^/]+)/.*$#\1#')" ;;
    https://*) PERSONAL="$(echo "$url" | sed -E 's#^https://[^/]+/([^/]+)/.*$#\1#')" ;;
    *)         PERSONAL="" ;;
esac

# THE VERBS come from repo_host.sh, which names no forge, no path and no HTTP
# code. This file used to ask github_api.sh, the transport, and carried its own
# curl underneath that: two places knowing GitHub's URL shape and its paging,
# for a question that is just "what does this owner have".
#
# The pipeline tree first: a script installed to /usr/local/sbin has no
# siblings, which is the 2026-09-02 fault where every sibling lookup failed
# silently and fell back with no message.
_iface() {
    local d
    d="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    [ -f "$d/$1" ] || d=/usr/local/lib/linuxbasics/hostings/scripts
    printf "%s/%s" "$d" "$1"
}

# Optional, because this script's whole job is a warning: a machine that cannot
# reach the forge should still render the drawer, saying it checked nothing.
# shellcheck source=/dev/null
REPO_HOST_OPTIONAL=1 . "$(_iface repo_host.sh)"

names_for() {
    local owner="$1" token
    # ONE THING STAYS OFF THE INTERFACE, and it is not an oversight.
    # `repo_list` prints nothing both when an owner has no repositories and
    # when the credential could not be minted, and an exit code cannot tell
    # them apart. The page would then call a taken name free, which is the one
    # answer this script must never give. Asking the minter first is the only
    # way to say which happened. It goes when repo_list can say so itself,
    # the way repo_exists already distinguishes absent from unreadable.
    [ -f "$TOKEN_SH" ] || return 0
    token="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" "$owner" 2>/dev/null)" || {
        # An empty list and a failed mint look identical to the page, and the
        # page would then say a taken name is free.
        print_error "Could not mint a token for ${owner}: its names are not checked."
        return 0
    }
    [ -n "$token" ] || return 0

    # repo_list answers for THIS owner and pages for itself. The owner matters:
    # the underlying listing is scoped by the token, so asking without one
    # answers about the configured owner and the clash check misses half the
    # names.
    [ "${REPO_HOST_READY:-0}" = "1" ] || {
        print_error "No repository host is available, so ${owner}'s names are not checked."
        return 0
    }
    # owner/name in, name out: the page asks per owner and already knows which.
    repo_list "$owner" | sed -n 's|^[^/]*/\(.*\)$|\1|p'
}

json_list() {
    local first=1 n
    printf '['
    while IFS= read -r n; do
        [ -n "$n" ] || continue
        [ "$first" = "1" ] || printf ','
        first=0
        # GitHub repository names are letters, digits, dot, dash, underscore,
        # so there is nothing here that needs escaping.
        printf '"%s"' "${n//\"/}"
    done
    printf ']'
}

printf '{"create_owner":"%s","owners":{' "${CREATE_ORG//\"/}"

# EVERY ACCOUNT THE APP IS INSTALLED ON, asked of GitHub rather than listed
# here. Two names somebody thought of stop being the whole truth the moment a
# third owner appears, and nothing would say so.
#
# The two derived names stay as the fallback, for a machine that cannot reach
# GitHub to enumerate but still has them.
OWNERS=""
if [ -f "$TOKEN_SH" ]; then
    OWNERS="$(SITES_CONF="$SITES_CONF" bash "$TOKEN_SH" --owners 2>/dev/null || true)"
fi
[ -n "$OWNERS" ] || OWNERS="$(printf '%s\n%s\n' "$CREATE_ORG" "$PERSONAL")"

sep=""
seen=""
while IFS= read -r own; do
    [ -n "$own" ] || continue
    case " $seen " in *" $own "*) continue ;; esac
    seen="$seen $own"
    printf '%s"%s":' "$sep" "${own//\"/}"
    names_for "$own" | sort -u | json_list
    sep=","
    # A here-string, not a pipe: a piped while runs in a subshell and both sep
    # and seen would reset on every iteration.
done <<< "$OWNERS"

printf '}}\n'

# Close the tee and let it finish before the cache is judged. Only a document
# that ends in the closing brace is kept: a run that died halfway through the
# GitHub calls must not be served for the next five minutes.
exec 1>&8 8>&-
wait 2>/dev/null || true
if [ -s "$_TMP_CACHE" ] && tail -c 4 "$_TMP_CACHE" | grep -q '}}'; then
    install -m 0644 -o root -g root "$_TMP_CACHE" "$CACHE" 2>/dev/null || true
fi
