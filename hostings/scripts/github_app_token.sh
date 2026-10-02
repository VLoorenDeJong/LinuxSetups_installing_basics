#!/usr/bin/env bash
set -e

# =============================================================================
# Print a GitHub installation token, good for one hour.
#
#   TOKEN="$(github_app_token.sh)"                     the configured installation
#   TOKEN="$(github_app_token.sh <org>)"           whatever covers that owner
#   TOKEN="$(github_app_token.sh <org>/site_a)"    whatever covers that repo
#   github_app_token.sh --owners                       every account it is on,
#                                                      one login per line, no token
#
# THIS IS WHY THE APP EXISTS. A personal access token cannot renew itself: the
# first one here died silently on 2026-08-18 and cost two days before anybody
# worked out why every clone had started failing. An installation token is
# minted fresh from a key that never expires, so there is nothing to notice.
#
# The token is written to stdout and NOWHERE else. Never into a log, never into
# a command line, never into a file. Anything on this machine can read
# /proc/<pid>/cmdline while a command runs, so a caller passes it through a
# credential helper or an environment variable, not as an argument.
#
# HOW IT WORKS, because the two-step is not obvious:
#   1. Sign a short JWT with the App's private key. That proves we are the App.
#   2. Trade the JWT for an installation token. That is what has repository
#      access, and only to what the App was installed on.
#
# WHY AN OWNER MAY BE NAMED. Repositories live under two owners now, the
# personal account and the <org> organisation, and one App installed twice
# has two installation ids. A configured id can only ever name one of them, and
# a wrong id fails with a message that names no cause. Asking GitHub which
# installation covers an owner cannot go stale.
# See .claude/docs/github-org-decisions.md, decision 1.
# =============================================================================

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
#
# All three go to stderr. Stdout is the token and nothing else: a caller that
# captures it would otherwise end up with a sentence where a credential should
# be, and then fail at the clone with an error naming no cause.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

TARGET="${1:-}"

conf_get() {
    local v
    v="$(sed -n "s/^[[:space:]]*${1}[[:space:]]*=//p" "$SITES_CONF" 2>/dev/null | head -n 1)"
    # A CRLF config leaves a carriage return on the end of every value, and
    # none of the trimming below removes it.
    v="${v//$'\r'/}"
    v="${v%%#*}"
    v="${v#"${v%%[![:space:]]*}"}"
    v="${v%"${v##*[![:space:]]}"}"
    [ "$v" = "-" ] && v=""
    printf '%s' "${v:-$2}"
}

APP_ID="$(conf_get GITHUB_APP_ID "")"
INSTALL_ID="$(conf_get GITHUB_APP_INSTALLATION_ID "")"

# AN OWNER BEATS A PINNED ID, and this file's own comment above says why: an id
# names exactly one installation and goes stale the moment the repositories move.
#
# It did exactly that on 2026-09-05. the config repository was transferred into the
# organisation, GITHUB_CREDENTIAL_OWNER followed it, and this kept minting for
# the pinned PERSONAL installation, so a freshly correct configuration produced
# a token that got 404 for the repository it was pointed at. The App was
# installed on both owners with access to all repositories the whole time, which
# is what made it look like a permissions problem.
#
# So a caller who names an owner still wins, then the configured owner, and the
# pinned id is the last resort rather than the first.
if [ -z "$TARGET" ]; then
    TARGET="$(conf_get GITHUB_CREDENTIAL_OWNER "")"
    [ -z "$TARGET" ] && TARGET="$(conf_get GITHUB_ORG "")"
fi
KEY_FILE="$(conf_get GITHUB_APP_KEY_FILE /etc/github-app/app.pem)"

# A TEST machine carries two Apps: a read-only one for everything, and one that
# may write, only for GITHUB_ADMIN_TARGETS (owners, or owner/repo). Anything
# not listed goes to the first, so a test bug cannot write a customer's repo.
# Unset (the live file) leaves the one App.
ADMIN_TARGETS="$(conf_get GITHUB_ADMIN_TARGETS "")"
ADMIN_APP_ID="$(conf_get GITHUB_ADMIN_APP_ID "")"
ADMIN_INSTALL_ID="$(conf_get GITHUB_ADMIN_APP_INSTALLATION_ID "")"
ADMIN_KEY_FILE="$(conf_get GITHUB_ADMIN_APP_KEY_FILE /etc/github-app/admin-app.pem)"

is_admin_target() {
    local a
    for a in $ADMIN_TARGETS; do
        { [ "$a" = "$1" ] || [ "$a" = "${1%%/*}" ]; } && return 0
    done
    return 1
}

# A caller that names a repository gets a token for that repository only, not
# for everything the installation covers. Audit 2026-10-02, M3.
SCOPE_REPO=""
case "$TARGET" in
    */*) SCOPE_REPO="${TARGET#*/}"; SCOPE_REPO="${SCOPE_REPO%.git}"
         [[ "$SCOPE_REPO" =~ ^[A-Za-z0-9._-]+$ ]] || SCOPE_REPO="" ;;
esac

if [ -n "$TARGET" ] && [ "$TARGET" != "--owners" ]; then
    if [ -n "$ADMIN_TARGETS" ] && is_admin_target "$TARGET"; then
        APP_ID="$ADMIN_APP_ID"
        INSTALL_ID="$ADMIN_INSTALL_ID"
        KEY_FILE="$ADMIN_KEY_FILE"
    else
        # owner/repo only ever mattered for choosing the App above.
        TARGET="${TARGET%%/*}"
    fi
fi

if [ -z "$APP_ID" ]; then
    print_error "GITHUB_APP_ID is not set in $SITES_CONF"
    exit 1
fi
if [ -z "$TARGET" ] && [ -z "$INSTALL_ID" ]; then
    print_error "No owner was named and GITHUB_APP_INSTALLATION_ID is not set in $SITES_CONF"
    print_action "Call it as: github_app_token.sh <owner>  or  github_app_token.sh <owner>/<repo>"
    exit 1
fi
if [ ! -r "$KEY_FILE" ]; then
    print_error "Cannot read the App key at $KEY_FILE"
    print_error "Install it with: sudo bash hostings/scripts/add_github_app.sh"
    exit 1
fi

# base64url: standard base64 with the two URL-unsafe characters swapped and the
# padding removed. A JWT is rejected outright with either still in it.
b64url() { openssl base64 -A | tr '+/' '-_' | tr -d '='; }

# make_jwt <app id> <key file>
make_jwt() {
    local now header payload input sig
    now="$(date +%s)"
    # Backdated a minute: GitHub rejects a JWT whose iat is in the future, and a
    # clock a few seconds fast is normal rather than a fault.
    header='{"alg":"RS256","typ":"JWT"}'
    payload="{\"iat\":$((now - 60)),\"exp\":$((now + 540)),\"iss\":\"$1\"}"
    input="$(printf '%s' "$header" | b64url).$(printf '%s' "$payload" | b64url)"
    sig="$(printf '%s' "$input" | openssl dgst -sha256 -sign "$2" -binary | b64url)"
    printf '%s.%s' "$input" "$sig"
}
JWT="$(make_jwt "$APP_ID" "$KEY_FILE")"

as_app() {
    curl -fsS -H "Authorization: Bearer ${JWT}" \
              -H "Accept: application/vnd.github+json" \
              "https://api.github.com$1" 2>&1
}

# The installation object opens with its own id, before the nested account
# object that carries a second one, so the first match is the right one.
first_id() { tr ',' '\n' | sed -n 's/.*"id"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1; }

resolve_installation() {
    local target="$1" body
    case "$target" in
        */*)
            # A repository answers directly, and it is the only form that works
            # without knowing whether the owner is a user or an organisation.
            body="$(as_app "/repos/${target}/installation")" || return 1
            ;;
        *)
            body="$(as_app "/orgs/${target}/installation")" \
                || body="$(as_app "/users/${target}/installation")" \
                || return 1
            ;;
    esac
    printf '%s' "$body" | first_id
}

# --owners: every account this App is installed on, one login per line, and no
# token at all. The console asks for it so a name is checked against everywhere
# the App can reach rather than against two names somebody thought of.
if [ "$TARGET" = "--owners" ]; then
    {
        as_app "/app/installations?per_page=100"
        if [ -n "$ADMIN_TARGETS" ] && [ -r "$ADMIN_KEY_FILE" ]; then
            JWT="$(make_jwt "$ADMIN_APP_ID" "$ADMIN_KEY_FILE")"
            as_app "/app/installations?per_page=100"
        fi
    } | tr '{' '\n' \
      | sed -n 's/.*"login"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      | sort -u
    exit 0
fi

if [ -n "$TARGET" ]; then
    if ! INSTALL_ID="$(resolve_installation "$TARGET")" || [ -z "$INSTALL_ID" ]; then
        print_error "The App is not installed on ${TARGET}, or it cannot see it."
        print_action "Install it: https://github.com/settings/apps -> your App -> Install App"
        print_info "A 404 here means no installation, not a bad key: the JWT was accepted."
        exit 1
    fi
fi

SCOPE_BODY=""
[ -n "$SCOPE_REPO" ] && SCOPE_BODY="{\"repositories\":[\"${SCOPE_REPO}\"]}"
RESPONSE="$(curl -fsS -X POST \
    -H "Authorization: Bearer ${JWT}" \
    -H "Accept: application/vnd.github+json" \
    ${SCOPE_BODY:+-d "$SCOPE_BODY"} \
    "https://api.github.com/app/installations/${INSTALL_ID}/access_tokens" 2>&1)" || {
    print_error "GitHub refused to mint a token."
    # The body, not a guess about it: GitHub says which of the three it is,
    # a bad key, a wrong App ID, or an installation that does not exist.
    printf '%s\n' "$RESPONSE" | head -5 >&2
    exit 1
}

TOKEN="$(printf '%s' "$RESPONSE" | tr ',' '\n' | sed -n 's/.*"token"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"

if [ -z "$TOKEN" ]; then
    print_error "GitHub answered, but with no token in it."
    exit 1
fi

printf '%s\n' "$TOKEN"
