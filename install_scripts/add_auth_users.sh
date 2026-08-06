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
# Make sure every account a configuration expects exists in an htpasswd file,
# by offering to create the ones that do not.
#
# WHY THIS IS NOT A LIST OF COMMANDS TO PASTE
#
# The obvious version prints `sudo htpasswd <file> <name>` per missing account
# and leaves it there. That step is the one that gets skipped, and skipping it
# costs a site nobody can log in to. Worse, the failure is silent in the most
# confusing way available: Apache treats an account that does not exist and a
# password that is wrong identically, so the first sign is somebody saying the
# password does not work.
#
# So this asks, and keeps asking until either everyone has a password or the
# operator says to carry on without.
#
# THE PASSWORD NEVER PASSES THROUGH THIS SCRIPT
#
# htpasswd prompts for it itself, on the terminal. It is never an argument, so
# it is never in `ps`, never in the shell history, and never in a variable here.
#
# UNATTENDED CALLERS DO NOT HANG
#
# CI has no controlling terminal. Prompting there would block the job for ever,
# which is worse than the list of commands this exists to replace. Without a
# terminal it reports and exits non-zero instead.
#
# Usage:
#   add_auth_users.sh --file /etc/apache2/.htpasswd-app alice hilda admin
#   add_auth_users.sh --file /etc/apache2/.htpasswd-app --users alice,hilda
#
# Exit codes:
#   0  every requested account exists
#   1  the operator chose to carry on with some still missing, or there is no
#      terminal to ask at
#   2  bad usage, or htpasswd is not installed
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

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

USER_FILE=""
REQUESTED=()

while [ $# -gt 0 ]; do
    case "$1" in
        --file)
            USER_FILE="$2"; shift 2 ;;
        --users)
            IFS=',' read -r -a _u <<< "$2"
            for x in ${_u+"${_u[@]}"}; do
                x="$(echo "$x" | xargs)"
                [ -n "$x" ] && REQUESTED+=("$x")
            done
            shift 2 ;;
        -h|--help)
            sed -n '4,40p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        -*)
            print_error "Unknown option: $1"
            exit 2 ;;
        *)
            REQUESTED+=("$1"); shift ;;
    esac
done

if [ -z "$USER_FILE" ]; then
    print_error "No --file given, and there is no sensible default for a password file."
    print_warning "Usage: $0 --file /etc/apache2/.htpasswd-app alice hilda"
    exit 2
fi

if [ ${#REQUESTED[@]} -eq 0 ]; then
    print_status "No accounts requested, so there is nothing to check."
    exit 0
fi

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to write $USER_FILE."
    print_warning "Please run with: sudo $0 --file $USER_FILE ${REQUESTED[*]}"
    exit 2
fi

if ! command -v htpasswd >/dev/null 2>&1; then
    print_error "htpasswd is not installed, so no account can be created."
    print_warning "Install it:  sudo apt-get install -y apache2-utils"
    exit 2
fi

# Sorted and de-duplicated once. The same person can be named by several rows.
mapfile -t REQUESTED < <(printf '%s\n' "${REQUESTED[@]}" | sort -u)

MISSING=()
find_missing() {
    local u
    MISSING=()
    for u in "${REQUESTED[@]}"; do
        if [ ! -f "$USER_FILE" ] || ! grep -q "^${u}:" "$USER_FILE"; then
            MISSING+=("$u")
        fi
    done
    [ ${#MISSING[@]} -eq 0 ]
}

# One asterisk per character, as they arrive. htpasswd's own prompt echoes
# nothing, which reads as a frozen terminal.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    while IFS= read -rsn1 ch < /dev/tty; do
        case "$ch" in
            "")             break ;;
            $'\177'|$'\b')  [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)              out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    printf '\n' > /dev/tty
    SECRET="$out"
}

# Read here rather than letting htpasswd prompt, so the masking is possible.
# The password is never an argument, never in the history, piped in with -i,
# and unset immediately after.
read_password() {
    local user="$1" p1 p2

    while :; do
        read_secret "   Password for $user: " || return 1
        p1="$SECRET"

        if [ -z "$p1" ]; then
            printf "   \033[33mEmpty. That locks the account rather than opening it.\033[0m\n" > /dev/tty
            continue
        fi

        read_secret "   Again: " || return 1
        p2="$SECRET"
        unset SECRET

        if [ "$p1" = "$p2" ]; then
            PASSWORD="$p1"
            unset p1 p2
            return 0
        fi
        printf "   \033[33mThey do not match. Try again.\033[0m\n" > /dev/tty
    done
}

add_one() {
    local user="$1" dir rc
    dir="$(dirname "$USER_FILE")"
    [ -d "$dir" ] || mkdir -p "$dir"

    PASSWORD=""
    read_password "$user" || { unset PASSWORD; return 1; }

    # -B is bcrypt. htpasswd still defaults to MD5 for compatibility with
    # httpd 2.2, which nothing here runs.
    #
    # -c CREATES AND TRUNCATES. It belongs on the first account and nowhere
    # else: used a second time it silently throws away everyone added before.
    if [ ! -f "$USER_FILE" ]; then
        printf '%s' "$PASSWORD" | htpasswd -i -B -c "$USER_FILE" "$user" >/dev/null 2>&1
        rc=$?
        if [ $rc -eq 0 ]; then
            chmod 640 "$USER_FILE"
            chown root:www-data "$USER_FILE" 2>/dev/null || chmod 644 "$USER_FILE"
        fi
    else
        printf '%s' "$PASSWORD" | htpasswd -i -B "$USER_FILE" "$user" >/dev/null 2>&1
        rc=$?
    fi

    unset PASSWORD
    return $rc
}

print_header "Login accounts"
print_status "File:     $USER_FILE"
print_status "Expected: ${REQUESTED[*]}"

if find_missing; then
    print_success "Every expected account already exists."
    exit 0
fi

if [ ! -r /dev/tty ]; then
    print_error "Missing accounts: ${MISSING[*]}"
    print_warning "There is no terminal here, so this cannot ask. Add them by hand:"
    for u in "${MISSING[@]}"; do
        print_warning "  sudo htpasswd $USER_FILE $u"
    done
    print_warning "Use -c only if the file does not exist yet: it truncates."
    exit 1
fi

echo ""
print_warning "Some expected accounts have no password yet."
print_status "Nobody can log in as them until they do."
echo ""

while ! find_missing; do
    print_warning "Still missing: ${MISSING[*]}"
    echo ""
    printf "   [Enter] add '%s'   [name] add somebody else   [c] carry on without: " "${MISSING[0]}"
    read -r answer < /dev/tty || answer="c"
    echo ""

    case "$answer" in
        "")
            add_one "${MISSING[0]}" && print_success "Added ${MISSING[0]}" \
                                    || print_error "htpasswd failed, nothing was written."
            ;;
        c|C)
            print_warning "Carrying on. These cannot log in: ${MISSING[*]}"
            exit 1
            ;;
        *)
            # Anything else is taken as a name, so somebody not in the config
            # yet can still be created here without leaving the script.
            add_one "$answer" && print_success "Added $answer" \
                              || print_error "htpasswd failed, nothing was written."
            ;;
    esac
    echo ""
done

print_success "Every expected account now has a password."
