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
# Roundcube's password change, CHECKED HERE and not only in Roundcube.
#
#   printf 'user@domain\ncurrent\nnew\n' | mail_chpasswd.sh
#
# Three lines, written by roundcube_password_driver.php, which add_roundcube.sh
# installs as the plugin's driver. The stock chpasswd driver sends only the new
# password, so the check of the current one happened inside Roundcube alone,
# and a bug in Roundcube could set any mailbox's password. Item 146.
#
# The current password is compared with the hash in Dovecot's password file.
# Everything else about what may be changed is set_mail_password.sh's rule, as
# it is for the console. No password ever becomes an argument.
#
# Exit code is what the driver reads: 0 changed, anything else refused.
# =============================================================================

print_error() { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    exit 1
fi

SETTER="/usr/local/sbin/set_mail_password.sh"
DOVECOT_USERS="/etc/dovecot/users"

if [ ! -x "$SETTER" ]; then
    print_error "$SETTER is not installed, so no password can be changed."
    exit 1
fi
if ! command -v php >/dev/null 2>&1; then
    print_error "php is not installed, so the current password cannot be checked."
    exit 1
fi

IFS= read -r ADDR || true
IFS= read -r CURRENT || true
IFS= read -r PASSWORD || true

case "$ADDR" in
    *@*) : ;;
    *) print_error "The username is not an email address."; exit 1 ;;
esac

if [ -z "$CURRENT" ] || [ -z "$PASSWORD" ]; then
    print_error "The current and the new password are both needed."
    exit 1
fi

# The {SCHEME} prefix comes off; what is left is a crypt() hash, $6$ today.
HASH="$(awk -F: -v a="$ADDR" '$1 == a { print $2; exit }' "$DOVECOT_USERS" 2>/dev/null)"
HASH="${HASH#\{*\}}"
if [ -z "$HASH" ]; then
    print_error "There is no mailbox for $ADDR."
    exit 1
fi

# Hash and password go in on stdin, so neither is visible in ps.
if ! printf '%s\n%s\n' "$HASH" "$CURRENT" | php -r '
        $h = rtrim(fgets(STDIN), "\n");
        $p = rtrim(fgets(STDIN), "\n");
        exit(hash_equals($h, crypt($p, $h)) ? 0 : 1);'; then
    unset CURRENT PASSWORD HASH
    print_error "The current password is wrong, so nothing was changed."
    exit 1
fi
unset CURRENT HASH

LOCAL="${ADDR%@*}"
DOMAIN="${ADDR#*@}"

OUT="$(printf '%s\n' "$PASSWORD" | "$SETTER" --set "$LOCAL" "$DOMAIN" 2>&1)" || {
    unset PASSWORD
    print_error "The password was not changed."
    exit 1
}
unset PASSWORD

# set_mail_password.sh reports a refusal as JSON with an error, not as a failing
# exit code, so the code on its own is not the answer.
case "$OUT" in
    *'"error"'*) print_error "${OUT##*$'\n'}"; exit 1 ;;
esac

exit 0
