#!/usr/bin/env bash
set -e

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
# Put the console accounts that predate the vault into their 1Password entry,
# by giving each one a NEW password.
#
#   backfill_console_logins.sh                say what it would do, change nothing
#   backfill_console_logins.sh --apply        do it
#   backfill_console_logins.sh --apply jane   just that account
#
# THE SAME SHAPE AS backfill_mailbox_logins.sh, and for the same reason: the
# machine keeps a bcrypt hash, so the plaintext of an existing account does not
# exist anywhere and cannot be written to the vault. A new password is the only
# way in. The owner chose that for mailboxes on 2026-09-20 and for these on the
# same day, after measuring eight of nine entries holding an EMPTY password
# field.
#
# WHY THE FIELD LOOKED FILLED. A 1Password Login item always shows a username
# and a password, so `--show` listing them proves nothing. person_entry.sh
# --has-login tests the LENGTH, which is the only question worth asking.
#
# SO THIS SIGNS EVERYBODY OUT of the accounts it touches, and whoever is
# holding the old password no longer has it. That is why the default is a dry
# run and --apply is a separate decision.
#
# IT DOES ONE THING PER ACCOUNT: generate, then hand to manage_auth_users.sh
# --password, which writes the htpasswd hash and calls person_entry.sh --login,
# which writes the entry and its links. Nothing here talks to htpasswd or to
# 1Password directly, so there is no second implementation of either.
#
# WHAT IT SKIPS, and says so rather than guessing:
#   already in  the entry already holds a page password
#   no entry    the store has nothing under that name. Not an error: the entry
#               is created by the first --login, which is what --apply does
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning".
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"
[ -f "$SITES_CONF" ] || SITES_CONF="$(conf_active "/etc/hostings")"
export SITES_CONF

APPLY=0
ONLY=()
for a in "$@"; do
    case "$a" in
        --apply) APPLY=1 ;;
        --help|-h) sed -n '18,48p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
        -*) print_error "Unknown option: $a"; exit 1 ;;
        *)  ONLY+=("$a") ;;
    esac
done

# The console's own copies, in /usr/local/sbin, before the pipeline tree's.
_tool() {
    [ -x "/usr/local/sbin/$1" ] && { printf '/usr/local/sbin/%s' "$1"; return; }
    [ -f "$SCRIPT_DIR/$1" ] && { printf '%s/%s' "$SCRIPT_DIR" "$1"; return; }
    printf '/usr/local/lib/linuxbasics/hostings/scripts/%s' "$1"
}
PERSON_ENTRY="$(_tool person_entry.sh)"
AUTH_USERS="$(_tool manage_auth_users.sh)"

# -----------------------------------------------------------------------------
# Pre-flight: everything that would stop this halfway, checked before the first
# password is changed. A run that dies on account three leaves two people
# locked out with nobody told.
# -----------------------------------------------------------------------------
print_header "Pre-flight"
ERRORS=()
[ "$EUID" -eq 0 ]      || ERRORS+=("This changes sign-in passwords and reads the vault token, so it must run as root. Run: sudo bash $0 $*")
[ -f "$SITES_CONF" ]   || ERRORS+=("No config at $SITES_CONF")
[ -f "$PERSON_ENTRY" ] || ERRORS+=("person_entry.sh is not installed: $PERSON_ENTRY")
[ -f "$AUTH_USERS" ]   || ERRORS+=("manage_auth_users.sh is not installed: $AUTH_USERS")
command -v jq >/dev/null 2>&1      || ERRORS+=("jq is not installed, so the user list cannot be read. Run: sudo apt-get install -y jq")
# --has-login exits 1 for "no password", and an older person_entry.sh exits 1
# from its usage line for "no such mode". The two are indistinguishable, and
# reading the second as the first would give every account a new password for
# nothing. So the mode is checked for, not tried. The console keeps its own
# copy in /usr/local/sbin and it is the one that goes stale.
grep -q -- '--has-login)' "$PERSON_ENTRY" 2>/dev/null \
    || ERRORS+=("$PERSON_ENTRY has no --has-login mode, so it is older than this script. Refresh it: sudo bash $SCRIPT_DIR/add_hosting_manager.sh")
command -v openssl >/dev/null 2>&1 || ERRORS+=("openssl is not installed, so no password can be generated. Run: sudo apt-get install -y openssl")
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi
print_success "Config, scripts, jq and openssl are all present."

USERS="$(bash "$AUTH_USERS" --list 2>/dev/null | jq -r '.users[]?.name' || true)"
if [ -z "$USERS" ]; then
    print_info "No console accounts, so there is nothing to back-fill."
    exit 0
fi

wanted() {
    [ ${#ONLY[@]} -eq 0 ] && return 0
    local u
    for u in "${ONLY[@]}"; do [ "$u" = "$1" ] && return 0; done
    return 1
}

# 20 characters of base64 with the awkward ones removed: a password that gets
# typed once and then lives in the vault.
new_password() { openssl rand -base64 24 | tr -d '/+=\n' | cut -c1-20; }

print_header "What this would change"
TODO=()
SKIPPED=0
while IFS= read -r user; do
    [ -n "$user" ] || continue
    wanted "$user" || continue
    set +e
    SITES_CONF="$SITES_CONF" bash "$PERSON_ENTRY" --has-login "$user" >/dev/null 2>&1
    STATE=$?
    set -e
    case "$STATE" in
        0) print_info "$user already has a password in the vault, unchanged." ;;
        1) TODO+=("$user"); print_status "$user  ->  new password, into their 1Password entry" ;;
        *) SKIPPED=$((SKIPPED + 1))
           print_error "$user is skipped: the vault could not be read, so it is not known what it holds." ;;
    esac
done <<< "$USERS"

if [ ${#TODO[@]} -eq 0 ]; then
    echo ""
    print_info "Nothing to back-fill. $SKIPPED account(s) skipped for the reasons above."
    exit 0
fi

echo ""
if [ "$APPLY" -ne 1 ]; then
    print_info "${#TODO[@]} account(s) would get a NEW console password. Nothing has been changed."
    print_action "Everyone holding the old password is signed out, including you if your own name is listed."
    print_action "Run it for real: sudo bash $0 --apply"
    exit 0
fi

print_header "Setting new passwords"
DONE=0
FAILED=0
for user in "${TODO[@]}"; do
    # Generated here and handed straight down a pipe: never a variable this
    # script could print, and never an argument, which ps would publish.
    set +e
    new_password | SITES_CONF="$SITES_CONF" bash "$AUTH_USERS" --password "$user" >/dev/null 2>&1
    RC=$?
    set -e
    if [ "$RC" -eq 0 ]; then
        print_success "$user has a new password, and it is in their entry."
        DONE=$((DONE + 1))
    else
        print_error "$user was NOT changed. Run it alone to see why: sudo bash $0 --apply $user"
        FAILED=$((FAILED + 1))
    fi
done

echo ""
print_status "$DONE changed, $FAILED failed, $SKIPPED skipped."
[ "$DONE" -gt 0 ] && print_action "Each of them opens their 1Password entry for the new password, or is sent it with the Share button."
[ "$FAILED" -gt 0 ] && exit 1
exit 0
