#!/usr/bin/env bash
# =============================================================================
# A restic repository password, never kept as a plain file.
#
#   restic_password.sh get   <name>                 the password on stdout, for
#                                                   RESTIC_PASSWORD_COMMAND
#   restic_password.sh setup <name> [--repo <path>] makes sure one exists.
#                                                   Run by the installers
#
# <name> is the vault item: docker-backup-password, mail-backup-password.
#
# Where it lives (decided 2026-10-11):
#   a vault on this machine   the vault only, read on every run. Used if it is
#                             there, made if it is not. Nothing on disk
#   no vault                  asked at install (Enter makes one), kept
#                             systemd-creds encrypted in CRED_DIR, root only
#
# A password that already exists anywhere wins over a new one: a new password
# cannot open the backups the old one made.
#
# Messages go to stderr: stdout carries the password.
# =============================================================================
set -o pipefail

print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1" >&2; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1" >&2; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1" >&2; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1" >&2; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1" >&2; }
print_hint()    { printf "   %s\n" "$1" >&2; }
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}" > /dev/tty; }

CRED_DIR="/etc/credstore.encrypted"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

VERB="${1:-}"
NAME="${2:-}"
REPO=""
[ $# -ge 2 ] && shift 2
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ -n "${2:-}" ] || { print_error "--repo needs a path."; exit 2; }
                REPO="$2"; shift 2 ;;
        *)      print_error "Unknown option: $1"; exit 2 ;;
    esac
done

case "$VERB" in
    get|setup) ;;
    *) print_error "Usage: $0 get|setup <name> [--repo <path>]"; exit 2 ;;
esac
# It becomes a file name and a credential name, so nothing but these.
if ! [[ "$NAME" =~ ^[a-z0-9-]+$ ]]; then
    print_error "'$NAME' is not a password name (lowercase, digits, -)."
    exit 2
fi
if [ "$EUID" -ne 0 ]; then
    print_error "The backup password is root-only."
    print_action "Run: sudo bash $0 $VERB $NAME"
    exit 1
fi

CRED_FILE="$CRED_DIR/$NAME"
# Where the installers kept it before 2026-10-11, in plain text.
LEGACY_FILE="/root/.${NAME//-/_}"

trim() { local v="$1"; v="${v#"${v%%[![:space:]]*}"}"; printf '%s' "${v%"${v##*[![:space:]]}"}"; }

VAULT=0
vault_ready() {
    [ "$VAULT" -eq 1 ] && return 0
    # Silenced whole: anything it printed on stdout would become the password.
    # shellcheck source=/dev/null
    { SECRET_OPTIONAL=1 . "$SCRIPT_DIR/secret_store.sh"; } >/dev/null 2>&1 || return 1
    [ "${SECRET_READY:-0}" = "1" ] || return 1
    secret_preflight >/dev/null 2>&1 || return 1
    VAULT=1
}

cred_read() { systemd-creds decrypt --name="$NAME" "$CRED_FILE" - 2>/dev/null; }

# One asterisk per character: read -s shows nothing, so a paste that landed and
# one that did not look the same.
read_masked() {
    local out="" ch
    while IFS= read -rsn1 ch; do
        case "$ch" in
            "")            break ;;
            $'\177'|$'\b') [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *)             out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done < /dev/tty
    printf '\n' > /dev/tty
    printf '%s' "$out"
}

# -----------------------------------------------------------------------------
# get: what RESTIC_PASSWORD_COMMAND runs, every backup.
# The encrypted file first, because it needs no network.
# -----------------------------------------------------------------------------
if [ "$VERB" = "get" ]; then
    if [ -f "$CRED_FILE" ]; then
        value="$(cred_read)" || { print_error "$CRED_FILE does not decrypt on this machine."; exit 1; }
    elif vault_ready; then
        value="$(secret_file_get "$NAME" 2>/dev/null)"
        case $? in
            0) ;;
            1) print_error "The vault has no '$NAME'."
               print_action "Run: sudo bash $0 setup $NAME"; exit 1 ;;
            *) print_error "The vault could not be read, so this backup has no password."; exit 1 ;;
        esac
    else
        print_error "No password for '$NAME': no vault, and no $CRED_FILE."
        print_action "Run: sudo bash $0 setup $NAME"
        exit 1
    fi
    value="$(trim "$value")"
    [ -n "$value" ] || { print_error "The stored '$NAME' is empty."; exit 1; }
    printf '%s' "$value"
    exit 0
fi

# -----------------------------------------------------------------------------
# setup: find the one that exists, or make one, and keep it in one place.
# -----------------------------------------------------------------------------
current=""
source=""
if vault_ready; then
    print_info "A vault is set up here, so '$NAME' is kept there and nowhere on disk."
    value="$(secret_file_get "$NAME" 2>/dev/null)"
    case $? in
        0) current="$(trim "$value")"; source="vault" ;;
        1) ;;
        *) print_error "The vault could not be read, so it is unknown whether '$NAME' already exists."
           print_action "Fix the vault and run this again. A new password now could lock out the existing backups."
           exit 1 ;;
    esac
fi
if [ -z "$current" ] && [ -f "$CRED_FILE" ]; then
    current="$(trim "$(cred_read)")"
    [ -n "$current" ] && source="cred"
fi
if [ -z "$current" ] && [ -s "$LEGACY_FILE" ]; then
    current="$(trim "$(cat "$LEGACY_FILE")")"
    [ -n "$current" ] && source="legacy"
fi

created=0
if [ -z "$current" ]; then
    if [ "$VAULT" -eq 1 ]; then
        current="$(openssl rand -base64 32)"
        created=1
    else
        if ! { : < /dev/tty; } 2>/dev/null; then
            print_error "No backup password for '$NAME' and no terminal to ask at."
            print_action "Run this from a terminal: sudo bash $0 setup $NAME"
            exit 1
        fi
        print_action "NEEDED: the backup password (restic), or Enter for a new one"
        print_hint "Rebuilding? Use the one the old backups were made with, from your password vault."
        for try in 1 2 3; do
            prompt_ask "Backup password:"
            current="$(read_masked)"
            [ -n "$current" ] || { current="$(openssl rand -base64 32)"; created=1; break; }
            prompt_ask "Again:"
            [ "$(read_masked)" = "$current" ] && break
            current=""
            print_error "The two did not match."
            [ "$try" -eq 3 ] && { print_action "Nothing was stored. Run this again."; exit 1; }
        done
    fi
fi

# A password that does not open the existing repository is caught here, not
# by tonight's backup.
if [ -n "$REPO" ] && [ -f "$REPO/config" ]; then
    if ! RESTIC_PASSWORD="$current" restic -r "$REPO" cat config >/dev/null 2>&1; then
        print_error "That password does not open the existing backups in $REPO."
        print_action "Put the password they were made with in place, or move $REPO aside to start new ones."
        exit 1
    fi
fi

if [ "$VAULT" -eq 1 ]; then
    if [ "$source" != "vault" ]; then
        if ! printf '%s' "$current" | secret_file_put "$NAME" 2>/dev/null; then
            print_error "The vault would not take '$NAME'. Nothing was changed."
            exit 1
        fi
        print_success "Put in the vault as '$NAME'."
    fi
    rm -f "$CRED_FILE"
else
    if [ "$source" != "cred" ]; then
        install -d -m 0700 "$CRED_DIR"
        if ! printf '%s' "$current" | (umask 077; systemd-creds encrypt --name="$NAME" - "$CRED_FILE.new") 2>/dev/null; then
            rm -f "$CRED_FILE.new"
            print_error "systemd-creds could not encrypt '$NAME'. Nothing was changed."
            exit 1
        fi
        mv -f "$CRED_FILE.new" "$CRED_FILE"
        chmod 0600 "$CRED_FILE"
        print_success "Stored encrypted: $CRED_FILE (root only)."
    fi
fi

if [ -f "$LEGACY_FILE" ]; then
    shred -u "$LEGACY_FILE" 2>/dev/null || rm -f "$LEGACY_FILE"
    print_status "Removed the plain-text copy, $LEGACY_FILE."
fi

case "$source" in
    vault)  print_success "'$NAME' came from the vault." ;;
    cred)   print_success "'$NAME' is already stored encrypted." ;;
    legacy) print_success "'$NAME' is the one the existing backups use." ;;
esac

# Only without a vault is there nowhere else it exists. Shown once.
if [ "$created" -eq 1 ] && [ "$VAULT" -eq 0 ]; then
    print_action "PUT THIS PASSWORD IN A VAULT. It is the only way to read these backups:"
    printf "   \033[36m%s\033[0m\n" "$current" > /dev/tty
    print_info "It is shown once. The encrypted copy here dies with this machine."
fi
exit 0
