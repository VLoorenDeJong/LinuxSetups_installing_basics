#!/usr/bin/env bash
set -e

# =============================================================================
# The one file that CALLS GitHub's API. Everything else asks it.
#
# This is the third and last layer of the same split, and the other two already
# exist:
#
#   github_app_token.sh             mints a token. One file since it was written
#   git_credential_github_app.sh    hands a token to git. One file since
#                                   2026-09-12, was ten copies
#   github_api.sh                   calls the REST API. This file
#
# WHY IT EXISTS, and it is the same reason as the other two rather than
# tidiness. Four scripts each built their own curl: provision_repo.sh,
# manage_repo.sh, list_repo_names.sh and add_github_app.sh. Three of the four
# sent a token with NO owner derived from the path, which is the fault that had
# every Jenkins job aborting on 2026-09-12: an org token gets 404 for a
# personal-account repository, and a 404 reads as "it does not exist".
#
# THE OWNER COMES OUT OF THE PATH. /repos/<owner>/... and /orgs/<owner> name
# their owner, so the token is chosen rather than configured. That derivation is
# lifted from provision_repo.sh:682, which was the only caller that had it
# right, and this file is now where it lives.
#
#   github_api.sh GET /repos/<org>/<repo>
#   github_api.sh PATCH /repos/x/y '{"archived":true}'
#   github_api.sh --status DELETE /repos/x/y     the HTTP code, nothing else
#   github_api.sh --with-code POST /orgs/x/repos BODY   the body, then the code
#   github_api.sh --paged GET /installation/repositories
#   github_api.sh --owner X GET /installation/repositories
#   github_api.sh --check                        can a token be minted
#
# STDOUT IS THE RESPONSE AND HOLDS NOTHING ELSE. Every message goes to stderr.
# A caller pipes this into a JSON parser, and one line of human text on stdout
# is a parse error blamed on GitHub.
#
# THE TOKEN NEVER REACHES ARGV. curl reads it from a header written to a file
# descriptor, not from the command line: /proc/<pid>/cmdline is world readable
# while the call runs. Tokens last an hour and nothing is cached to disk.
# =============================================================================

print_action() { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()   { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_error()  { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
export SITES_CONF
GITHUB_API="${GITHUB_API:-https://api.github.com}"

# The installed tree first: a script in /usr/local/sbin has no siblings, which
# is the 2026-09-02 fault where every sibling lookup failed silently.
TOKEN_SH=""
for _c in "$SCRIPT_DIR/github_app_token.sh" \
          /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh; do
    [ -f "$_c" ] && { TOKEN_SH="$_c"; break; }
done

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    v="${v//$'\r'/}"; v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"; v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

declare -A _TOKENS

mint_for() {
    local owner="$1"
    [ -n "$TOKEN_SH" ] || return 0
    bash "$TOKEN_SH" ${owner:+"$owner"} 2>/dev/null || true
}

# Lifted from provision_repo.sh:682. An endpoint that names no owner
# (/installation/repositories, /meta, /user) takes the configured one, which is
# correct: those answer about the installation rather than about a repository.
#
# --owner overrides it, and that is not a convenience. /installation/repositories
# names no owner in its path and is scoped by the TOKEN, so "which repositories
# can this account see" can only be asked one installation at a time. Deriving
# from the path there silently answers about the configured owner instead, which
# is a name-clash check that misses half the names.
token_for_path() {
    local path="$1" own="${FORCE_OWNER:-}"
    [ -n "$own" ] && { _tok_for_owner "$own"; return 0; }
    case "$path" in
        /repos/*) own="${path#/repos/}"; own="${own%%/*}" ;;
        /orgs/*)  own="${path#/orgs/}";  own="${own%%/*}" ;;
    esac
    _tok_for_owner "$own"
}

_tok_for_owner() {
    local own="$1" t
    if [ -n "${_TOKENS[${own:-_default}]+set}" ]; then
        printf '%s' "${_TOKENS[${own:-_default}]}"
        return 0
    fi
    t="$(mint_for "$own")"
    # An owner the App is not installed on falls back to the configured token
    # rather than sending none: a public repository still answers, and the
    # caller gets GitHub's own 404 instead of a 401 that names the wrong cause.
    [ -n "$t" ] || t="$(mint_for "")"
    _TOKENS[${own:-_default}]="$t"
    printf '%s' "$t"
}

# The header goes in through a file, never through -H on the command line.
call() {
    local method="$1" path="$2" body="${3:-}" want_status="${4:-0}"
    local tok hdr rc out
    tok="$(token_for_path "$path")"
    hdr="$(mktemp)"
    chmod 600 "$hdr"
    {
        printf 'Authorization: Bearer %s\n' "$tok"
        printf 'Accept: application/vnd.github+json\n'
        [ -n "$body" ] && printf 'Content-Type: application/json\n'
    } > "$hdr"

    if [ "$want_status" = "1" ]; then
        out="$(curl -s -o /dev/null -w '%{http_code}' -X "$method" \
               -H "@$hdr" ${body:+-d "$body"} "${GITHUB_API}${path}" 2>/dev/null)" || out="000"
    elif [ "$want_status" = "2" ]; then
        # The body AND the code, the code alone on the last line. A create needs
        # both: the code says whether it happened, the body carries the URLs the
        # caller has to write into the row, and asking twice would create twice.
        out="$(curl -s -w '\n%{http_code}' -X "$method" \
               -H "@$hdr" ${body:+-d "$body"} "${GITHUB_API}${path}" 2>/dev/null)" || out=$'\n000'
    else
        out="$(curl -s -X "$method" -H "@$hdr" ${body:+-d "$body"} \
               "${GITHUB_API}${path}" 2>/dev/null)" || out=""
    fi
    rc=$?
    rm -f "$hdr"
    printf '%s' "$out"
    return $rc
}

# --paged walks GitHub's 100-per-page limit and prints each page's body. The
# caller parses; this only stops asking. Bounded at 20 pages, which is the
# bound list_repo_names.sh already carried: an unbounded loop against a paging
# API that stops advancing is a hang nobody diagnoses.
paged() {
    local method="$1" path="$2" page=1 body sep
    while [ "$page" -le 20 ]; do
        case "$path" in *\?*) sep='&' ;; *) sep='?' ;; esac
        body="$(call "$method" "${path}${sep}per_page=100&page=${page}")" || return 0
        [ -n "$body" ] || return 0
        printf '%s\n' "$body"
        # Fewer than 100 objects means this was the last page. Counted on
        # full_name because that is one per repository; "name" also appears
        # inside a nested license object, which is how "MIT License" once
        # reached a repository list.
        local count
        count="$(printf '%s' "$body" | tr ',' '\n' | grep -c '"full_name"' || true)"
        [ "${count:-0}" -lt 100 ] && return 0
        page=$((page + 1))
    done
}

FORCE_OWNER=""
STATUS=0
PAGED=0
while [ $# -gt 0 ]; do
    case "$1" in
        --status) STATUS=1; shift ;;
        --with-code) STATUS=2; shift ;;
        --paged)  PAGED=1; shift ;;
        --owner)
            [ -n "${2:-}" ] || { print_error "--owner needs a name."; exit 1; }
            FORCE_OWNER="$2"; shift 2
            ;;
        --check)
            if [ -z "$TOKEN_SH" ]; then
                print_error "github_app_token.sh was not found beside this script or in the pipeline tree."
                exit 1
            fi
            print_info "Minter: $TOKEN_SH"
            print_info "API:    $GITHUB_API"
            code="$(call GET /installation/repositories "" 1)"
            if [ "$code" = "200" ]; then
                print_info "A token was minted and GitHub answered 200."
                exit 0
            fi
            print_error "GitHub answered HTTP ${code} for the installation."
            print_action "Check the App: sudo bash hostings/scripts/add_github_app.sh --test-only"
            exit 1
            ;;
        -h|--help)
            print_info "Usage: $0 [--status|--with-code|--paged] <METHOD> <path> [body]"
            print_info "       $0 --check"
            exit 0
            ;;
        *) break ;;
    esac
done

METHOD="${1:-}"
PATH_IN="${2:-}"
BODY="${3:-}"
if [ -z "$METHOD" ] || [ -z "$PATH_IN" ]; then
    print_error "A method and a path are required."
    print_action "For example: $0 GET /repos/<owner>/<repo>"
    exit 1
fi
case "$PATH_IN" in
    /*) ;;
    *)  print_error "The path must start with a slash: $PATH_IN"; exit 1 ;;
esac

if [ "$PAGED" = "1" ]; then
    paged "$METHOD" "$PATH_IN"
else
    call "$METHOD" "$PATH_IN" "$BODY" "$STATUS"
    printf '\n'
fi
