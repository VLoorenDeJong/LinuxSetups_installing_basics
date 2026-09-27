#!/usr/bin/env bash
# =============================================================================
# WHERE THE CODE LIVES, in verbs. The interface; the forge is a config value.
#
#   . "$SCRIPT_DIR/repo_host.sh"
#   repo_exists <owner> <name>              0 there, 1 absent, 2 could not tell
#                                           on 2 it prints "<reason><TAB><code>"
#   repo_is_private <owner> <name>          yes, no, or empty if unreadable
#   repo_create <owner> <name> yes|no [description]    prints the clone URL
#   repo_delete <owner> <name>
#   repo_archive <owner> <name>             frozen, still readable: the
#                                           reversible half of repo_delete
#   repo_set_private <owner> <name> yes|no
#   repo_default_branch <owner> <name>
#   repo_set_default_branch <owner> <name> <branch>
#   repo_branches <owner> <name>            one per line
#   repo_branch_sha <owner> <name> <branch>
#   repo_create_branch <owner> <name> <new> <from-sha>
#   repo_delete_branch <owner> <name> <branch>
#   repo_clone_url <owner> <name>
#   repo_list <owner>                       owner/name per line
#   repo_git <git args...>                  git, authenticated to this forge
#   repo_https_url <ssh-or-https-url>       the forge URL a token can be used with
#
# NO CALLER NAMES A FORGE, a path, or an HTTP code. `REPO_HOST` in hostings.conf
# names the service file; this resolves and sources it.
#
# WHY, when github_api.sh already exists. Because github_api.sh is a TRANSPORT:
# it owns the auth and the curl, and it speaks GitHub's own vocabulary,
# `GET /repos/<owner>/<name>`. Every caller therefore knows GitHub's URL shape
# and status codes, so moving to Codeberg or a self-hosted Forgejo would touch
# every call site rather than one file. Measured 2026-09-12: about twelve of
# them in provision_repo.sh alone.
#
# CHANGED AND DROPPED ARE DIFFERENT QUESTIONS.
#
#   changed   a second service file exposing these verbs, plus REPO_HOST.
#             github_api.sh stays as GitHub's transport, under its service file
#   dropped   sourcing fails loudly HERE rather than mid-run. A caller that can
#             work without the forge sources with REPO_HOST_OPTIONAL=1 and
#             tests $REPO_HOST_READY
#
# THE VERBS ARE CHECKED AT SOURCE TIME, for the same reason as dns.sh: in bash
# an interface is a promise, not a contract, and a missing verb is otherwise a
# "command not found" halfway through creating repositories.
#
# WHAT NO INTERFACE HERE CAN COVER, said plainly so a swap is not costed wrong:
# Jenkins' githubPush() trigger in every generated job, the webhook door scoped
# in UFW to GitHub's published ranges, and the App credential model itself,
# which is PAT-shaped on every other forge. See the parked idea
# outside-services-behind-an-interface.md.
# =============================================================================

print_error()  { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_action() { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }

REPO_HOST_READY=0
REPO_HOST_FILE=""

_rh_conf_get() {
    local v
    [ -n "${SITES_CONF:-}" ] || { printf '%s' "$2"; return 0; }
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

# A name added here is a name every forge has to answer to, so it is not a list
# to grow casually.
REPO_HOST_REQUIRED_VERBS="repo_exists repo_is_private repo_create repo_delete repo_archive repo_set_private \
repo_default_branch repo_set_default_branch repo_branches repo_branch_sha \
repo_create_branch repo_delete_branch repo_clone_url repo_list repo_git repo_https_url"

_repo_host_load() {
    local dir name cand v missing=""
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # The environment wins over the config, as SITES_CONF does everywhere else.
    name="${REPO_HOST:-$(_rh_conf_get REPO_HOST repo_host_github.sh)}"
    # Sourced as root from a value the console can write: a bare file name only.
    if ! [[ "$name" =~ ^repo_host_[a-z0-9_]+\.sh$ ]]; then
        print_error "REPO_HOST '$name' is not a repo_host_<name>.sh file name."
        return 1
    fi

    for cand in "$dir/$name" \
                "/usr/local/lib/linuxbasics/hostings/scripts/$name"; do
        [ -f "$cand" ] && { REPO_HOST_FILE="$cand"; break; }
    done
    if [ -z "$REPO_HOST_FILE" ]; then
        print_error "No repository host file called '$name' beside repo_host.sh or in the pipeline tree."
        print_action "Set REPO_HOST in ${SITES_CONF:-hostings.conf}, or put the file there."
        return 1
    fi

    # shellcheck source=/dev/null
    . "$REPO_HOST_FILE" || { print_error "$REPO_HOST_FILE could not be sourced."; return 1; }

    for v in $REPO_HOST_REQUIRED_VERBS; do
        declare -F "$v" >/dev/null 2>&1 || missing="$missing $v"
    done
    if [ -n "$missing" ]; then
        print_error "$REPO_HOST_FILE does not provide:$missing"
        return 1
    fi

    # A service file may say it cannot work, which is not the same as being
    # absent: github_api.sh missing from the tree is this, not a bad REPO_HOST.
    if declare -F repo_host_ready >/dev/null 2>&1 && ! repo_host_ready; then
        print_error "$REPO_HOST_FILE loaded but says it cannot reach its host."
        return 1
    fi

    REPO_HOST_READY=1
}

if ! _repo_host_load; then
    if [ "${REPO_HOST_OPTIONAL:-0}" = "1" ]; then
        print_action "Carrying on without a repository host. Anything that needed it is skipped, not guessed."
    else
        return 1 2>/dev/null || exit 1
    fi
fi

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    case "${1:-}" in
        --check)
            printf 'service:  %s\n' "${REPO_HOST_FILE:-none}"
            printf 'ready:    %s\n' "$REPO_HOST_READY"
            printf 'verbs:    %s\n' "$(printf '%s' "$REPO_HOST_REQUIRED_VERBS" | tr -s ' ')"
            [ "$REPO_HOST_READY" = "1" ] || exit 1
            owner="$(_rh_conf_get GITHUB_ORG "")"
            [ -n "$owner" ] || owner="$(_rh_conf_get GITHUB_OWNER "")"
            if [ -n "$owner" ]; then
                printf 'owner:    %s\n' "$owner"
                printf 'repos:    %s\n' "$(repo_list "$owner" | wc -l | tr -d ' ')"
            fi
            ;;
        *)
            printf 'Source this file. %s --check names the service and counts what it can see.\n' "$0" >&2
            exit 1
            ;;
    esac
fi
