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
# Break-glass for the console's second factor. Installed as
# /usr/local/sbin/console_otp.
#
#   sudo console_otp <user>
#
# Prints a 6-digit code that the console's code page accepts, for when the
# e-mailed code cannot arrive and the recovery codes are gone. It writes into
# the same store the page reads (second_factor.php), in the same line format.
#
# Root only, and deliberately NOT in any sudoers grant: whoever can run it can
# sign in to the console, so it belongs to people who already own the machine.
# =============================================================================

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Must match second_factor.php.
TFA_DIR="/var/lib/hosting-manager/2fa"
PAGE_USER="hosting-manager"
CODE_SECS=300
TRIES=5

USER_NAME="${1:-}"

if [ "$EUID" -ne 0 ]; then
    print_error "This prints a console login, so it needs root."
    print_action "Run: sudo console_otp ${USER_NAME:-<user>}"
    exit 1
fi

case "$USER_NAME" in
    ''|*[!A-Za-z0-9._-]*)
        print_error "Give the console username: sudo console_otp <user>"
        exit 1
        ;;
esac

if [ ! -d "$TFA_DIR" ]; then
    print_error "No code store at $TFA_DIR, so the console has no second factor installed."
    print_action "Run add_hosting_manager.sh to install it."
    exit 1
fi
command -v php >/dev/null 2>&1 || { print_error "php is missing, and the console needs it anyway: sudo apt install php-cli"; exit 1; }

# The directory belongs to the page account, so root never writes a name it can
# predict there: mktemp creates a fresh file, and mv -T replaces a planted
# symlink rather than following it.
place() {
    local tmp="$1" dest="$2"
    chown "$PAGE_USER:$PAGE_USER" "$tmp"
    chmod 0600 "$tmp"
    mv -T -f "$tmp" "$dest"
}

# The page makes the key on first use, in the same format, so whichever runs
# first wins. It is re-read from disk afterwards in case both raced.
KEY_FILE="$TFA_DIR/key"
if ! tr -d '[:space:]' 2>/dev/null < "$KEY_FILE" | grep -qxE '[0-9a-f]{64}'; then
    TMP="$(mktemp "$TFA_DIR/.key.XXXXXX")"
    od -An -N32 -tx1 /dev/urandom | tr -d ' \n' > "$TMP"
    echo >> "$TMP"
    place "$TMP" "$KEY_FILE"
fi

CODE="$(printf '%06d' $(( $(od -An -N4 -tu4 /dev/urandom | tr -d ' ') % 1000000 )))"
# The key is read from its file inside php, never passed as an argument: an
# argument is visible in ps to every account, and this key also signs passes.
MAC="$(printf '%s' "$CODE" | php -r 'echo hash_hmac("sha256", stream_get_contents(STDIN), trim(file_get_contents($argv[1])));' "$KEY_FILE")"
NOW="$(date +%s)"

TMP="$(mktemp "$TFA_DIR/.code.XXXXXX")"
printf '%s %s %s %s\n' "$MAC" "$((NOW + CODE_SECS))" "$TRIES" "$NOW" > "$TMP"
place "$TMP" "$TFA_DIR/$USER_NAME.code"

print_success "Console code for '$USER_NAME', valid 5 minutes:"
printf '\n    %s\n\n' "$CODE"
print_info "It replaces any e-mailed code still waiting. Sign in with the password first, then type it on the code page."
