#!/usr/bin/env bash
set -e

# =============================================================================
# The one file that authenticates GIT to GitHub. A git credential helper.
#
# WHY THIS EXISTS. Ten scripts each carried their own copy of
#
#     git -c credential.helper='!f() { echo username=x-access-token;
#                                      echo "password=$GH_TOKEN"; }; f'
#
# with ONE token minted up front and no owner named. That is fine while every
# repository has the same owner, and wrong the moment two owners are in play.
#
# Measured 2026-09-12: repositories live under `<org>` (the organisation)
# and `<owner>` (the personal account), one App installed twice, two
# installation ids. add_pipeline_scripts.sh minted the ORG token and handed it
# to `submodule update`, which has to fetch <owner>/<private-submodule>, and got
#
#     remote: Repository not found.
#
# A 404 for a GitHub App means the WRONG INSTALLATION'S TOKEN, not a missing
# repository and not a bad key. Every Jenkins job died at its checkout and the
# pipeline tree could not be refreshed.
#
# THE RULE THIS FOLLOWS is project-context.md principle 2b: an outside service
# gets one file, and every script goes through it. github_app_token.sh already
# does that for MINTING. This does it for handing the result to git, which is
# the half that was still copied ten times.
#
#   git -c credential.helper=/path/git_credential_github_app.sh \
#       -c credential.useHttpPath=true  fetch ...
#
# useHttpPath is not optional. Without it git tells the helper the HOST only,
# every github.com URL looks identical, and there is no owner to choose a
# token for. That single config line is the whole fix.
#
#   --token <owner>   print a token for one owner, for a caller that must mint
#                     before dropping privileges (see WHO RUNS IT below)
#   --check [<owner>] say whether a token can be minted right now
#
# WHO RUNS IT. Minting reads the App private key, which is root-only. Four
# callers clone as an unprivileged account (sudo -u, runuser), so the helper
# runs as that account and cannot mint. Those callers mint as root first, one
# token per owner, and export
#
#     GH_APP_TOKEN_<OWNER>     e.g. GH_APP_TOKEN_EXAMPLE
#
# which this reads before trying to mint. The owner is upper-cased and every
# character outside A-Z0-9 becomes an underscore, because that is what a shell
# variable name allows.
#
# A PUBLIC REPOSITORY MUST STILL WORK WHEN NOTHING CAN BE MINTED. LinuxBasics
# is public and is the submodule that has never failed; answering with no
# credential lets git fetch it anonymously, which is why every path below ends
# in "print nothing" rather than in an error.
#
# THE TOKEN NEVER REACHES ARGV OR A FILE. It is written to stdout, which git
# reads over a pipe. /proc/<pid>/cmdline is world readable while a clone runs,
# and a token in a URL is copied into .git/config, so neither is used here.
# Tokens last an hour; nothing is cached to disk.
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

# The installed tree first: a script in /usr/local/sbin has no siblings, which
# is the 2026-09-02 fault where every $SCRIPT_DIR/github_app_token.sh lookup
# failed and fell back silently.
TOKEN_SH=""
for _c in "$SCRIPT_DIR/github_app_token.sh" \
          /usr/local/lib/linuxbasics/hostings/scripts/github_app_token.sh; do
    [ -f "$_c" ] && { TOKEN_SH="$_c"; break; }
done

# A shell variable name: upper case, and anything else becomes an underscore.
env_name_for() {
    local o="$1"
    o="$(printf '%s' "$o" | tr '[:lower:]' '[:upper:]' | tr -c 'A-Z0-9' '_')"
    printf 'GH_APP_TOKEN_%s' "$o"
}

# Pre-minted beats minting, so an unprivileged clone still authenticates.
token_from_env() {
    local var val
    var="$(env_name_for "$1")"
    val="${!var:-}"
    printf '%s' "$val"
}

mint_token() {
    [ -n "$TOKEN_SH" ] || return 0
    bash "$TOKEN_SH" "$1" 2>/dev/null || true
}

token_for_owner() {
    local owner="$1" tok
    tok="$(token_from_env "${owner%%/*}")"
    [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
    tok="$(mint_token "$owner")"
    [ -n "$tok" ] && { printf '%s' "$tok"; return 0; }
    # Legacy: a caller that exported one owner-blind token before this file
    # existed. Better than nothing, and still wrong for a second owner.
    printf '%s' "${GH_TOKEN:-}"
}

case "${1:-}" in
    --token)
        [ -n "${2:-}" ] || { print_error "--token needs an owner."; exit 1; }
        tok="$(token_for_owner "$2")"
        [ -n "$tok" ] || { print_error "No token could be minted for '$2'."; exit 1; }
        printf '%s\n' "$tok"
        exit 0
        ;;
    --check)
        owner="${2:-}"
        if [ -z "$TOKEN_SH" ]; then
            print_error "github_app_token.sh was not found beside this script or in the pipeline tree."
            exit 1
        fi
        print_info "Minter: $TOKEN_SH"
        print_info "Config: $SITES_CONF"
        tok="$(token_for_owner "$owner")"
        if [ -n "$tok" ]; then
            print_info "A token was minted for '${owner:-the configured owner}' (${#tok} characters). It is not printed."
            exit 0
        fi
        print_error "No token could be minted for '${owner:-the configured owner}'."
        print_action "Check the App: sudo bash hostings/scripts/add_github_app.sh --test-only"
        exit 1
        ;;
    store|erase)
        # git offers these after a successful or failed authentication. Nothing
        # is stored, so both are a deliberate no-op rather than an error.
        exit 0
        ;;
esac

# =============================================================================
# The credential-helper protocol
#
# git writes key=value lines and a blank line, and reads the same shape back.
# Only host and path are wanted here; anything else is ignored rather than
# rejected, because git adds keys over time and a helper that fails on an
# unknown one breaks on upgrade.
# =============================================================================
HOST=""
PATH_IN=""
while IFS= read -r line; do
    [ -z "$line" ] && break
    case "$line" in
        host=*) HOST="${line#host=}" ;;
        path=*) PATH_IN="${line#path=}" ;;
    esac
done

# Only GitHub. Any other host is somebody else's credential and answering for
# it would hand a GitHub token to whoever asked.
case "$HOST" in
    github.com|www.github.com) ;;
    *) exit 0 ;;
esac

# path is <owner>/<repo>.git, and empty when useHttpPath was not set. An empty
# owner is passed on as empty: github_app_token.sh then falls back to the
# configured owner, which is exactly what every caller did before this file.
OWNER="${PATH_IN%%/*}"
case "$OWNER" in
    ''|'.'|'..') OWNER="" ;;
esac
# owner/repo lets a TEST machine's write App answer for its one repository there.
REPO="${PATH_IN#*/}"
REPO="${REPO%.git}"
case "$REPO" in
    ''|*/*|'.'|'..') REPO="" ;;
esac
[ "$PATH_IN" = "$OWNER" ] && REPO=""

TOKEN="$(token_for_owner "${OWNER}${OWNER:+${REPO:+/$REPO}}")"

# No token is not an error. A public repository clones anonymously, and saying
# so with silence is what keeps LinuxBasics working on a machine with no key.
[ -n "$TOKEN" ] || exit 0

printf 'username=x-access-token\n'
printf 'password=%s\n' "$TOKEN"
