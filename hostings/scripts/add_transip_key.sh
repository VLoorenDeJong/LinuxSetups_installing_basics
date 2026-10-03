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
# Install the TransIP API key on this machine, and prove it works.
#
# The key answers DNS-01 challenges, which is how this machine gets certificates
# while port 80 still reaches the machine it replaces. transip_dns_challenge.sh
# is the hook certbot calls; this script is the one-off setup behind it.
#
#   sudo bash add_transip_key.sh              paste the key, install it, test it
#   sudo bash add_transip_key.sh --test-only  test what is already installed
#   sudo bash add_transip_key.sh --replace    ask even when the stored pair works
#
# The key is created in the TransIP control panel under My Account -> API, with
# NO IP whitelist. This machine shares the household's public address with the
# machine it replaces, so a restricted key passes today and fails after the
# swap, in a way that reads like a code fault.
#
# Both the key and the account name are asked for here and written 0600 root.
# Neither is in this repository, which holds their paths and nothing else. The
# account name is needed because TransIP's auth endpoint signs a body that must
# say which account to verify the signature against.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

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

# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

# The busy indicator. Kill-safe work only: see the timeout regimes above.
SPIN_FRAMES=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
_SPIN_PID=""
spinner_start() {
    [ "${DEBUG_MODE:-0}" = "1" ] && return 0
    local message="$1"
    (
        local i=0
        while true; do
            printf '\r\033[K\033[34m%s %s\033[0m' "${SPIN_FRAMES[i % 10]}" "$message"
            i=$((i + 1))
            sleep 0.2
        done
    ) &
    _SPIN_PID=$!
}
spinner_stop() {
    [ -n "$_SPIN_PID" ] || return 0
    kill "$_SPIN_PID" 2>/dev/null || true
    wait "$_SPIN_PID" 2>/dev/null || true
    _SPIN_PID=""
    printf '\r\033[K'
}

usage() {
    echo "Usage: $0 [--test-only | --replace]" >&2
    echo "" >&2
    echo "  (no option)  paste the key, install it, then test it" >&2
    echo "  --test-only  test the key already installed, change nothing" >&2
    echo "  --replace    ask to replace a key and username that already work" >&2
    exit 1
}

TEST_ONLY=0
REPLACE=0
while [ $# -gt 0 ]; do
    case "$1" in
        --test-only) TEST_ONLY=1; shift ;;
        --replace)   REPLACE=1; shift ;;
        -h|--help)   usage ;;
        *) print_error "Unknown option: $1"; usage ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to install a root-owned key."
    print_action "Please run with: sudo $0"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

conf_get() {
    local key="$1" default="${2:-}" value
    value="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$SITES_CONF" 2>/dev/null \
             | head -n1 | tr -d '\r' | cut -d= -f2- | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}

API_URL="https://api.transip.nl/v6"

# The same store add_dns_records.sh already uses. One key in the control panel,
# one copy on the machine, encrypted the stronger of the two ways that were in
# use. Two stores for one credential means rotating it in one place and finding
# out months later that the other still held the old one.
CRED_DIR="$(conf_get DNS_CRED_DIR /etc/dns-api)"
CRED_FILE="$CRED_DIR/api.key.cred"
CRED_NAME="$(conf_get DNS_CRED_NAME dnsapi)"
LOGIN_FILE="$(conf_get DNS_LOGIN_FILE "$CRED_DIR/login")"

for tool in curl openssl jq systemd-creds; do
    if ! command -v "$tool" >/dev/null 2>&1; then
        print_error "$tool is not installed."
        print_action "Run: sudo apt-get install -y $tool"
        exit 1
    fi
done

# The vault, if this machine has one, sourced AFTER the tool checks so the
# first thing that can fail is still one of them. Guarded and never fatal: a
# lone copy of this script on a bare machine keeps its own paste, below.
KEY_ASK_FLAG=""
LOGIN_ASK_FLAG=""
if [ -f "$SCRIPT_DIR/secret_ask.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/secret_ask.sh" || true
fi

mkdir -p "$CRED_DIR"
chmod 700 "$CRED_DIR"

# One plaintext key was installed at /etc/letsencrypt/transip.key before the two
# scripts were made to share a store. Moved rather than left: a second copy of a
# credential is the thing this change exists to remove.
LEGACY_KEY="/etc/letsencrypt/transip.key"
LEGACY_LOGIN="/etc/letsencrypt/transip.login"
MIGRATE=0
if [ "$TEST_ONLY" -eq 0 ] && [ -f "$LEGACY_KEY" ]; then
    if [ ! -f "$CRED_FILE" ]; then
        MIGRATE=1
    else
        # Both exist, and which is current cannot be told apart by looking. The
        # stored one predates this change and may be a key that has since been
        # replaced in the control panel, which fails as a 401 that reads like a
        # wrong account name.
        print_info "There are two keys on this machine:"
        print_info "  encrypted: $CRED_FILE"
        print_info "  plaintext: $LEGACY_KEY"
        printf "\033[33m⚠️ Replace the encrypted one with the plaintext one? Type yes: \033[0m"
        read -r answer < /dev/tty
        [ "$answer" = "yes" ] && MIGRATE=1
    fi
fi

if [ "$MIGRATE" -eq 1 ]; then
    print_info "Encrypting $LEGACY_KEY and removing the plaintext copy."
    if systemd-creds encrypt --name="$CRED_NAME" "$LEGACY_KEY" "$CRED_FILE" 2>/dev/null; then
        chmod 600 "$CRED_FILE"
        chown root:root "$CRED_FILE"
        shred -u "$LEGACY_KEY" 2>/dev/null || rm -f "$LEGACY_KEY"
        print_success "Moved into $CRED_FILE. The plaintext copy is gone."
        # The account name travels with the key it belongs to. Overwritten
        # rather than kept, because the pair has to match.
        if [ -f "$LEGACY_LOGIN" ]; then
            install -m 0600 -o root -g root "$LEGACY_LOGIN" "$LOGIN_FILE"
            rm -f "$LEGACY_LOGIN"
            print_success "Username moved to $LOGIN_FILE."
        fi
    else
        print_error "systemd-creds could not encrypt it. Nothing was removed."
        print_action "Check systemd is 250 or newer: systemctl --version"
        exit 1
    fi
fi

# =============================================================================
# Take the key at a prompt, because the download is on the workstation and this
# machine is reached over SSH.
#
# Read from /dev/tty rather than stdin: a script calling this one could
# otherwise answer the prompt with input of its own.
# =============================================================================
WANT_KEY=1
WANT_LOGIN=1
PAIR_OK=0
PAIR_TEST=""
if [ "$TEST_ONLY" -eq 0 ] && [ "$REPLACE" -eq 0 ] && [ -f "$CRED_FILE" ] && [ -f "$LOGIN_FILE" ]; then
    spinner_start "Testing the stored key and username with TransIP..."
    PAIR_TEST="$(bash "${BASH_SOURCE[0]}" --test-only < /dev/null 2>&1)" && PAIR_OK=1
    spinner_stop
fi
if [ "$TEST_ONLY" -eq 1 ]; then
    WANT_KEY=0
    WANT_LOGIN=0
elif [ "$PAIR_OK" -eq 1 ]; then
    # A pair TransIP accepts is kept without asking; --replace asks anyway.
    print_header "TransIP API key"
    print_success "The stored key and username work (TransIP issued a token), so both were kept."
    WANT_KEY=0
    WANT_LOGIN=0
    if command -v secret_file_get >/dev/null 2>&1 \
       && ! secret_file_get transip-username >/dev/null 2>&1; then
        secret_save transip-username < "$LOGIN_FILE"
    fi
else
    print_header "TransIP API key"
    if [ -n "$PAIR_TEST" ]; then
        print_error "The stored key and username did not pass the test:"
        printf '%s\n' "$PAIR_TEST" | grep -F '❌' | sed 's/^/   /'
    fi
    # Asked separately, because the key and the account name are usually wrong
    # one at a time. Replacing both to fix one means pasting a key that was
    # already right.
    if [ -f "$CRED_FILE" ]; then
        print_success "An encrypted key is already stored at $CRED_FILE"
        printf "\033[33m⚠️ Replace it? Type yes to replace, anything else to keep it: \033[0m"
        read -r answer < /dev/tty
        if [ "$answer" = "yes" ]; then
            # Replacing means a NEW key, so the vault's copy is the old one.
            KEY_ASK_FLAG="--ask"
        else
            WANT_KEY=0; print_status "Keeping the installed key."
        fi
    fi
    if [ -f "$LOGIN_FILE" ]; then
        print_success "A username is already stored at $LOGIN_FILE"
        printf "\033[33m⚠️ Replace it? Type yes to replace, anything else to keep it: \033[0m"
        read -r answer < /dev/tty
        if [ "$answer" = "yes" ]; then
            LOGIN_ASK_FLAG="--ask"
        else
            WANT_LOGIN=0; print_status "Keeping the stored username."
        fi
    fi
fi

if [ "$WANT_KEY" -eq 1 ]; then
    TMP_KEY="$(mktemp)"
    chmod 600 "$TMP_KEY"
    trap 'rm -f "$TMP_KEY"' EXIT

    GOT_KEY=0
    # The vault answers first, when this machine has one. A pasted key goes
    # into it, so the next drive is not asked for the same key again.
    if command -v secret_ask >/dev/null 2>&1; then
        if secret_ask transip-api-key \
                --label "the TransIP private key" \
                --multiline \
                --validate 'openssl pkey -noout' \
                --hint "control panel -> My Account -> API -> add key, with NO IP whitelist." \
                ${KEY_ASK_FLAG:+--ask} > "$TMP_KEY"; then
            GOT_KEY=1
        else
            print_error "No usable private key. Nothing was installed."
            exit 1
        fi
    fi

    # No vault and no helper: this script still asks for the key by itself,
    # which is what keeps it runnable on a bare machine.
    if [ "$GOT_KEY" -eq 0 ]; then
        print_status "Control panel -> My Account -> API -> add key, with NO IP whitelist."
        echo ""
        print_action "PASTE THE WHOLE KEY NOW, including the BEGIN and END lines, then press Enter."
        print_action "One long line is fine: it gets reflowed."
        echo ""

        while IFS= read -r line < /dev/tty; do
            printf '%s\n' "$line" >> "$TMP_KEY"
            case "$line" in *"END "*"PRIVATE KEY"*) break ;; esac
        done

        # A terminal paste arrives as one long line, and PEM wants the base64
        # body on its own lines. Reflowed rather than rejected: retyping it is
        # not an option and the content is already correct.
        raw="$(tr -d '\r' < "$TMP_KEY")"
        header="$(printf '%s' "$raw" | grep -oE -- '-----BEGIN [A-Z ]+-----' | head -n1)"
        footer="$(printf '%s' "$raw" | grep -oE -- '-----END [A-Z ]+-----' | head -n1)"
        if [ -n "$header" ] && [ -n "$footer" ]; then
            body="${raw#*"$header"}"
            body="${body%"$footer"*}"
            body="$(printf '%s' "$body" | tr -d ' \t\n')"
            {
                printf '%s\n' "$header"
                printf '%s' "$body" | fold -w 64
                printf '\n%s\n' "$footer"
            } > "$TMP_KEY"
        fi

        # Checked before installing, because a truncated paste fails later as
        # an authentication error, which reads like a wrong username.
        if ! openssl pkey -in "$TMP_KEY" -noout 2>/dev/null; then
            print_error "That is not a usable private key. Nothing was installed."
            print_action "Paste it whole, including the -----BEGIN and -----END lines."
            exit 1
        fi
    fi
    chmod 600 "$TMP_KEY"

    # Encrypted to this host, so a copy taken from the disk or out of a backup
    # decrypts nowhere else. The plaintext is shredded rather than left beside
    # it, which is the whole point of encrypting it.
    if ! systemd-creds encrypt --name="$CRED_NAME" "$TMP_KEY" "$CRED_FILE" 2>/dev/null; then
        print_error "systemd-creds could not encrypt the key. Nothing was stored."
        print_action "Check systemd is 250 or newer: systemctl --version"
        exit 1
    fi
    chmod 600 "$CRED_FILE"
    chown root:root "$CRED_FILE"
    shred -u "$TMP_KEY" 2>/dev/null || rm -f "$TMP_KEY"
    print_success "Key encrypted into $CRED_FILE. No plaintext copy remains."
fi

# The account name is asked for here rather than kept in hostings.conf. That
# file is committed, and half a credential in git is still a credential.
if [ "$WANT_LOGIN" -eq 1 ]; then
    login=""
    if command -v secret_ask >/dev/null 2>&1; then
        login="$(secret_ask transip-username \
                    --label "your TransIP username" \
                    --hint "the name you sign in to transip.nl with." \
                    ${LOGIN_ASK_FLAG:+--ask})" || login=""
    else
        echo ""
        print_action "TYPE YOUR TRANSIP USERNAME, then press Enter."
        printf "\033[33m⚠️ TransIP username: \033[0m"
        read -r login < /dev/tty
    fi
    if [ -z "$login" ]; then
        print_error "Nothing typed, so no username was stored."
        print_action "Re-run this script to finish."
        exit 1
    fi
    install -D -m 0600 -o root -g root /dev/null "$LOGIN_FILE"
    printf '%s\n' "$login" > "$LOGIN_FILE"
    print_success "Stored $LOGIN_FILE, mode 600, owned by root."
fi

TRANSIP_LOGIN="${TRANSIP_LOGIN:-}"
if [ -z "$TRANSIP_LOGIN" ] && [ -f "$LOGIN_FILE" ]; then
    TRANSIP_LOGIN="$(head -n1 "$LOGIN_FILE" | xargs)"
fi

# =============================================================================
# Prove it. A token is the whole handshake: the key signs, TransIP verifies, and
# nothing is created, changed or rate limited.
# =============================================================================
print_header "Testing the key"

if [ ! -f "$CRED_FILE" ]; then
    print_error "No key at $CRED_FILE."
    print_action "Run without --test-only to install one."
    exit 1
fi

# Decrypted to a temporary file because openssl signs from a file, never from a
# pipe it can seek. Mode 600 before it holds anything, and shredded on the way
# out however this script ends.
PLAIN_KEY="$(mktemp)"
chmod 600 "$PLAIN_KEY"
trap 'shred -u "$PLAIN_KEY" 2>/dev/null || rm -f "$PLAIN_KEY"' EXIT
if ! systemd-creds decrypt --name="$CRED_NAME" "$CRED_FILE" - > "$PLAIN_KEY" 2>/dev/null; then
    print_error "The stored key could not be decrypted on this machine."
    print_info "A credential encrypted elsewhere never decrypts here. Re-run to install it again."
    exit 1
fi

if [ -z "$TRANSIP_LOGIN" ]; then
    print_error "No TransIP username at $LOGIN_FILE."
    print_info "TransIP's auth endpoint signs a body that must name the account,"
    print_info "so the key alone cannot identify you."
    print_action "Run without --test-only to be prompted for it."
    exit 1
fi

# The account name is not printed. It is read from a 0600 file, and echoing it
# puts it in the terminal scrollback and in Jenkins' build log.
print_status "Account: read from $LOGIN_FILE"
print_status "Key:     $CRED_FILE (encrypted to this host)"

# The signature covers the request body BYTE FOR BYTE, so the string that is
# signed must be the string that is sent. Rebuilding the JSON, or letting a tool
# reformat it, produces a valid-looking request that is rejected.
NONCE="$(openssl rand -hex 16)"
# The label must be unique among active tokens, so running this twice inside
# half an hour with a fixed label is refused. Five minutes, because the token is
# used immediately and never again.
BODY="$(jq -nc --arg login "$TRANSIP_LOGIN" --arg nonce "$NONCE" \
    --arg label "key test $(date +%s) $NONCE" \
    '{login: $login, nonce: $nonce, read_only: true,
      expiration_time: "5 minutes", label: $label,
      global_key: true}')"
SIG="$(printf '%s' "$BODY" | openssl dgst -sha512 -sign "$PLAIN_KEY" | openssl base64 -A)"

RESPONSE="$(curl -s --max-time 20 -X POST "$API_URL/auth" \
    -H "Content-Type: application/json" \
    -H "Signature: $SIG" \
    --data-binary "$BODY")" || {
    print_error "Could not reach $API_URL/auth. Check this machine has internet."
    exit 1
}

TOKEN="$(printf '%s' "$RESPONSE" | jq -r '.token // empty')"
if [ -z "$TOKEN" ]; then
    print_error "TransIP refused the request."
    print_error "  $(printf '%s' "$RESPONSE" | jq -r '.error // .' 2>/dev/null || printf '%s' "$RESPONSE")"
    print_info "Most likely causes, in order:"
    print_info "  1. TRANSIP_LOGIN is not the account the key belongs to."
    print_info "  2. The key has an IP whitelist. Recreate it without one."
    print_info "  3. The key was pasted incompletely. Run this script again."
    exit 1
fi

print_success "Token received, ${#TOKEN} characters. The key and login work."
print_status "Nothing was created or changed."
print_status "Next: certificates can now be requested over DNS-01."
