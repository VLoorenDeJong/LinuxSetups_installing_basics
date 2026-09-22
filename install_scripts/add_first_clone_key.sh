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

# ===== USAGE =====
# Put the SSH key for the FIRST CLONE on a blank machine, out of 1Password.
#
#   sudo bash add_first_clone_key.sh --vault "<vault name>"
#   sudo bash add_first_clone_key.sh --vault "<vault>" --item "file git-push-key"
#
#     --vault <name>     the 1Password vault the service account opens. Required
#     --item  <title>    the item holding the key. Default: file git-push-key.
#                        That default is what the store titles an item with no
#                        alias. If the private config sets a SECRET_ITEM_ alias
#                        for this key, pass that title here: this script runs
#                        before the clone, so it cannot read that config.
#     --user  <name>     the account that will clone. Default: the sudo caller
#     --path  <file>     where the key goes. Default: ~<user>/.ssh/id_ed25519
#     --token-file <f>   where the token is kept. Default /root/.op_service_account_token
#     --no-save-token    do not keep the token
#     --test-only        report what is installed and what the vault holds, write nothing
#
# WHY THIS EXISTS. A private repository cannot be cloned without a credential,
# and the credential minter lives inside it. The way out used to be eleven
# manual steps: generate a key, copy the public half out of a terminal, paste
# it into GitHub's website, confirm it in the phone app. This replaces them
# with a token typed once, because the key is already in the vault.
#
# The token is the only secret typed here. It is handed to `op` through its
# environment, never as an argument, because arguments show in `ps`. Unless
# --no-save-token is given it is left at the token file (root, 0600) so the
# rest of the install does not ask for it a second time.
#
# NOTHING IN HERE NAMES A MACHINE, A DOMAIN OR A VAULT. This repository is
# public; every local fact arrives as an argument.
# ===== END USAGE =====

export DEBIAN_FRONTEND=noninteractive

print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }

# Explaining an ask: plain body, cyan for what to find.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'
NC=$'\033[0m'

# Prompts. print_action cannot be one: it ends with a newline.
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

# The busy indicator. Kill-safe work only.
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

# Duplicated from add_1password.sh, per the convention that each script stays
# runnable alone. One asterisk per character, as they arrive: read -s shows
# nothing, so a paste that landed and one that did not look identical.
read_secret() {
    local prompt="$1" out="" ch
    printf '%s' "$prompt" > /dev/tty
    stty -echo < /dev/tty
    while IFS= read -r -n1 ch < /dev/tty; do
        case "$ch" in
            '') break ;;
            $'\177'|$'\b')
                [ -n "$out" ] && { out="${out%?}"; printf '\b \b' > /dev/tty; } ;;
            *) out="$out$ch"; printf '*' > /dev/tty ;;
        esac
    done
    stty echo < /dev/tty
    printf '\n' > /dev/tty
    SECRET="$out"
}

masked() {
    local v="$1"
    [ ${#v} -le 8 ] && { printf '%s' '********'; return; }
    printf '%s...%s (%d chars)' "${v:0:4}" "${v: -4}" "${#v}"
}

# =============================================================================
# Arguments
# =============================================================================
VAULT=""
ITEM="file git-push-key"
CLONE_USER=""
KEY_PATH=""
TEST_ONLY=0
SAVE_TOKEN=1
OP_TOKEN_FILE="/root/.op_service_account_token"

# Kept before the loop shifts them away: the root check below has to be able to
# hand back the whole command, or a run without sudo is refused twice, the
# second time for a missing --vault the operator did type.
ORIG_ARGS=("$@")

while [ $# -gt 0 ]; do
    case "$1" in
        --vault)         VAULT="${2:-}"; shift 2 ;;
        --item)          ITEM="${2:-}"; shift 2 ;;
        --user)          CLONE_USER="${2:-}"; shift 2 ;;
        --path)          KEY_PATH="${2:-}"; shift 2 ;;
        --token-file)    OP_TOKEN_FILE="${2:-}"; shift 2 ;;
        --test-only)     TEST_ONLY=1; shift ;;
        --no-save-token) SAVE_TOKEN=0; shift ;;
        -h|--help)       sed -n '/^# ===== USAGE =====/,/^# ===== END USAGE =====/p' "$0" | sed '1d;$d'; exit 0 ;;
        *) print_error "Unknown argument '$1'."; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "Installing the 1Password CLI and writing a key needs root."
    print_action "Run: sudo bash $0 ${ORIG_ARGS[*]}"
    exit 1
fi

# The real invoking user, never root's own home: the clone belongs to a person.
[ -n "$CLONE_USER" ] || CLONE_USER="${SUDO_USER:-$(whoami)}"
CLONE_HOME="$(getent passwd "$CLONE_USER" | cut -d: -f6)"
[ -n "$KEY_PATH" ] || KEY_PATH="$CLONE_HOME/.ssh/id_ed25519"

OP_KEY_URL="https://downloads.1password.com/linux/keys/1password.asc"
OP_KEY_FPR="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
OP_KEYRING="/usr/share/keyrings/1password-archive-keyring.gpg"
OP_LIST="/etc/apt/sources.list.d/1password.list"
DEBSIG_ID="AC2D62742012EA22"

LOG="$(mktemp)"
KEY_TMP=""
trap 'spinner_stop; stty echo < /dev/tty 2>/dev/null || true; rm -f "$LOG" "$LOG.asc" ${KEY_TMP:+"$KEY_TMP"}' EXIT

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()
[ -n "$VAULT" ] || ERRORS+=("No vault given. Run: sudo bash $0 --vault \"<your vault name>\"")
[ -n "$ITEM" ]  || ERRORS+=("--item cannot be empty.")
[ -n "$CLONE_HOME" ] || ERRORS+=("User '$CLONE_USER' has no home directory, so there is nowhere to put the key.")
case "$KEY_PATH" in
    /*) ;;
    *)  ERRORS+=("--path must be absolute, not '$KEY_PATH'.") ;;
esac
case "$OP_TOKEN_FILE" in
    /*) ;;
    *)  ERRORS+=("--token-file must be absolute, not '$OP_TOKEN_FILE'.") ;;
esac
ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$ARCH" in
    amd64|arm64) ;;
    *) ERRORS+=("1Password publishes op for amd64 and arm64 only, and this machine is '${ARCH:-unknown}'.") ;;
esac
command -v curl >/dev/null 2>&1       || ERRORS+=("curl is missing. Install it: sudo apt-get install -y curl")
command -v gpg >/dev/null 2>&1        || ERRORS+=("gpg is missing. Install it: sudo apt-get install -y gnupg")
command -v ssh-keygen >/dev/null 2>&1 || ERRORS+=("ssh-keygen is missing. Install it: sudo apt-get install -y openssh-client")
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

print_header "The key for the first clone"
print_info "Vault: $VAULT"
print_info "Item:  $ITEM"
print_info "Key:   $KEY_PATH, owned by $CLONE_USER"

# =============================================================================
# The CLI
# =============================================================================
print_header "1Password CLI"

NEED_APT=()
command -v op >/dev/null 2>&1 || NEED_APT+=("1password-cli")
# jq reads the item's fields. It is not on a fresh Ubuntu and every later
# script in the fleet wants it, so it is installed here rather than refused.
command -v jq >/dev/null 2>&1 || NEED_APT+=("jq")

if [ ${#NEED_APT[@]} -eq 0 ]; then
    print_success "op $(op --version 2>/dev/null) and jq are already installed."
elif [ "$TEST_ONLY" = "1" ]; then
    print_error "Missing: ${NEED_APT[*]}. There is nothing to test."
    print_action "Run: sudo bash $0 --vault \"$VAULT\""
    exit 1
else
    if ! command -v op >/dev/null 2>&1; then
        spinner_start "Fetching 1Password's signing key..."
        if ! curl -fsS --max-time 30 "$OP_KEY_URL" -o "$LOG.asc" > "$LOG" 2>&1; then
            spinner_stop
            print_error "Could not fetch $OP_KEY_URL:"
            tail -5 "$LOG"
            exit 1
        fi
        spinner_stop
        # Checked before apt trusts it: a key that is not theirs must never
        # sign packages that run as root.
        GOT_FPR="$(gpg --show-keys --with-colons "$LOG.asc" 2>/dev/null | awk -F: '/^fpr:/ {print $10; exit}')"
        if [ "$GOT_FPR" != "$OP_KEY_FPR" ]; then
            rm -f "$LOG.asc"
            print_error "The fetched key's fingerprint is '${GOT_FPR:-none}', not 1Password's $OP_KEY_FPR."
            print_info "Nothing was installed. Check https://developer.1password.com/docs/cli/get-started/"
            exit 1
        fi
        gpg --dearmor --yes --output "$OP_KEYRING" < "$LOG.asc"
        install -d -m 0755 "/etc/debsig/policies/$DEBSIG_ID" "/usr/share/debsig/keyrings/$DEBSIG_ID"
        gpg --dearmor --yes --output "/usr/share/debsig/keyrings/$DEBSIG_ID/debsig.gpg" < "$LOG.asc"
        rm -f "$LOG.asc"
        if ! curl -fsS --max-time 30 "https://downloads.1password.com/linux/debian/debsig/1password.pol" \
                -o "/etc/debsig/policies/$DEBSIG_ID/1password.pol" > "$LOG" 2>&1; then
            print_error "Could not fetch 1Password's package policy:"
            tail -5 "$LOG"
            exit 1
        fi
        printf 'deb [arch=%s signed-by=%s] https://downloads.1password.com/linux/debian/%s stable main\n' \
            "$ARCH" "$OP_KEYRING" "$ARCH" > "$OP_LIST"
        print_status "Added $OP_LIST, signed by key $OP_KEY_FPR"
    fi

    spinner_start "Installing ${NEED_APT[*]}..."
    if ! { apt-get update -q && apt-get install -y -q "${NEED_APT[@]}"; } > "$LOG" 2>&1; then
        spinner_stop
        print_error "Installing ${NEED_APT[*]} failed:"
        tail -20 "$LOG"
        exit 1
    fi
    spinner_stop
    print_success "Installed ${NEED_APT[*]} (op $(op --version 2>/dev/null))"
fi

# =============================================================================
# The token
# =============================================================================
print_header "Service account token"

CURRENT=""
[ -f "$OP_TOKEN_FILE" ] && CURRENT="$(tr -d '[:space:]' < "$OP_TOKEN_FILE")"

# Returns 0 when the token opens the vault. The token goes in through the
# environment of this one command only.
vault_opens() {
    OP_SERVICE_ACCOUNT_TOKEN="$1" op vault get "$VAULT" --format json > "$LOG" 2>&1
}

if [ "$TEST_ONLY" = "0" ]; then
    print_action "NEEDED: the 1Password service account token for vault $VAULT"
    print_hint   "it starts with ops_ and was shown once, when the service account was made."
    print_hint   "if you kept it: ${HL}1Password -> your own vault -> the service account item${NC}"
    print_hint   "if it is lost: ${HL}my.1password.eu -> Developer -> the service account -> Regenerate token${NC}"
    if [ -n "$CURRENT" ]; then
        read_secret "   Token [now $(masked "$CURRENT"), Enter keeps it]: "
    else
        read_secret "   Token: "
    fi
    TOKEN="$(printf '%s' "$SECRET" | tr -d '[:space:]')"
    unset SECRET
    [ -z "$TOKEN" ] && TOKEN="$CURRENT"
    if [ -z "$TOKEN" ]; then
        print_error "No token given and none stored, so nothing was done."
        exit 1
    fi
    case "$TOKEN" in
        ops_*) ;;
        *) print_error "That is not a service account token: they start with ops_. Nothing was done."
           exit 1 ;;
    esac
    prompt_got "Token $(masked "$TOKEN")"
else
    TOKEN="$CURRENT"
    if [ -z "$TOKEN" ]; then
        print_error "No token at $OP_TOKEN_FILE, so there is nothing to test."
        print_action "Run: sudo bash $0 --vault \"$VAULT\""
        exit 1
    fi
fi

spinner_start "Opening vault $VAULT..."
if ! vault_opens "$TOKEN"; then
    spinner_stop
    print_error "The token does not open vault '$VAULT':"
    tail -3 "$LOG"
    print_info "Check the service account was given '$VAULT' with read access."
    exit 1
fi
spinner_stop
print_success "The token opens vault '$VAULT'."

# =============================================================================
# The key
# =============================================================================
print_header "The key"

# The field labels a stored key can arrive under, in the order they are
# believed. `file` is plain text and `content` is base64; the rest are what a
# hand-made item uses. The same order as secret_store_1password.sh, which is
# what writes them.
read_key() {
    local item
    item="$(OP_SERVICE_ACCOUNT_TOKEN="$TOKEN" op item get "$ITEM" --vault "$VAULT" --format json 2>"$LOG")" || return 1
    if printf '%s' "$item" | jq -e 'any(.fields[]?; .label == "file" and .value != null)' >/dev/null; then
        printf '%s' "$item" | jq -j '.fields[] | select(.label == "file") | .value'
    elif printf '%s' "$item" | jq -e 'any(.fields[]?; .label == "content" and .value != null)' >/dev/null; then
        printf '%s' "$item" | jq -j '.fields[] | select(.label == "content") | .value' | base64 -d
    else
        printf '%s' "$item" | jq -j '
            first(.fields[]? | select(.value != null)
                            | select(.label as $l | ["credential","password","notesPlain"] | index($l))
                            | .value) // ""'
    fi
}

# Written to a file, never into a variable: a command substitution drops every
# NUL and strips the trailing newline an OpenSSH key needs.
KEY_TMP="$(mktemp)"
chmod 0600 "$KEY_TMP"
spinner_start "Reading '$ITEM' from the vault..."
if ! read_key > "$KEY_TMP"; then
    spinner_stop
    print_error "Could not read '$ITEM' from vault '$VAULT':"
    tail -3 "$LOG"
    print_action "Check the item's title. List what the account can see:"
    print_hint   "  ${HL}sudo OP_SERVICE_ACCOUNT_TOKEN=\$(cat $OP_TOKEN_FILE) op item list --vault \"$VAULT\"${NC}"
    exit 1
fi
spinner_stop

if [ ! -s "$KEY_TMP" ]; then
    print_error "'$ITEM' holds no value in any field this reads."
    print_info "Expected one of: file, content, credential, password, notesPlain."
    exit 1
fi

# A key that ends without a newline is rejected by OpenSSH, and a round trip
# through a vault is exactly where that newline gets lost.
[ -n "$(tail -c1 "$KEY_TMP")" ] && printf '\n' >> "$KEY_TMP"

if ! PUBKEY="$(ssh-keygen -y -f "$KEY_TMP" 2>"$LOG")"; then
    print_error "What came out of '$ITEM' is not an SSH private key:"
    tail -3 "$LOG"
    print_info "Nothing was written to $KEY_PATH."
    exit 1
fi
FPR="$(printf '%s\n' "$PUBKEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')"
print_success "The vault holds an SSH key: $FPR"

if [ "$TEST_ONLY" = "1" ]; then
    print_info "--test-only: nothing was written."
    exit 0
fi

if [ -s "$KEY_PATH" ] && cmp -s "$KEY_TMP" "$KEY_PATH"; then
    print_success "$KEY_PATH is already the vault's key."
else
    if [ -s "$KEY_PATH" ]; then
        BACKUP="$KEY_PATH.before-vault.$(date +%Y%m%d-%H%M%S)"
        cp -p "$KEY_PATH" "$BACKUP"
        chmod 0600 "$BACKUP"
        print_status "Kept the key that was there as $BACKUP"
    fi
    install -d -m 0700 -o "$CLONE_USER" -g "$CLONE_USER" "$(dirname "$KEY_PATH")"
    install -m 0600 -o "$CLONE_USER" -g "$CLONE_USER" "$KEY_TMP" "$KEY_PATH"
    printf '%s\n' "$PUBKEY" > "$KEY_PATH.pub"
    chown "$CLONE_USER:$CLONE_USER" "$KEY_PATH.pub"
    chmod 0644 "$KEY_PATH.pub"
    print_success "Wrote $KEY_PATH ($CLONE_USER, 0600) and $KEY_PATH.pub"
fi

# =============================================================================
# github.com, so the clone does not stop on a host key prompt
# =============================================================================
print_header "GitHub"

KNOWN="$CLONE_HOME/.ssh/known_hosts"
if ssh-keygen -F github.com -f "$KNOWN" >/dev/null 2>&1; then
    print_info "github.com is already in $KNOWN."
else
    spinner_start "Fetching github.com's host keys..."
    ssh-keyscan -H github.com >> "$KNOWN" 2>"$LOG" || true
    spinner_stop
    chown "$CLONE_USER:$CLONE_USER" "$KNOWN"
    chmod 0644 "$KNOWN"
    print_status "Added github.com to $KNOWN"
fi

# `ssh -T git@github.com` always exits non-zero: GitHub refuses the shell and
# says who you are on stderr. The name is the answer, not the exit code.
spinner_start "Asking GitHub who this key is..."
WHO="$(sudo -u "$CLONE_USER" ssh -o BatchMode=yes -o StrictHostKeyChecking=yes \
        -i "$KEY_PATH" -T git@github.com 2>&1 || true)"
spinner_stop
case "$WHO" in
    *"successfully authenticated"*)
        print_success "GitHub: $WHO" ;;
    *"Host key verification failed"*|*"REMOTE HOST IDENTIFICATION"*)
        # Not a key problem at all: the keyscan above is allowed to fail, and
        # sending the operator to their GitHub key list would waste the trip.
        print_error "github.com is not trusted yet, so the key was never offered:"
        printf '   %s\n' "$WHO"
        print_action "Fix $KNOWN and run this again:"
        print_hint   "  ${HL}sudo -u $CLONE_USER ssh-keyscan -H github.com >> $KNOWN${NC}"
        exit 1 ;;
    *)
        print_error "GitHub did not accept the key:"
        printf '   %s\n' "$WHO"
        print_action "The key is in place, but the clone will fail. Check that $FPR"
        print_hint   "is listed at ${HL}https://github.com/settings/keys${NC}"
        exit 1 ;;
esac

# =============================================================================
# The token, kept so the rest of the install does not ask again
# =============================================================================
if [ "$SAVE_TOKEN" = "1" ] && [ "$TOKEN" != "$CURRENT" ]; then
    [ -d "$(dirname "$OP_TOKEN_FILE")" ] || install -d -m 0700 "$(dirname "$OP_TOKEN_FILE")"
    TMP="$(mktemp "$(dirname "$OP_TOKEN_FILE")/.op-token.XXXXXX")"
    printf '%s\n' "$TOKEN" > "$TMP"
    chmod 0600 "$TMP"
    mv -T -f "$TMP" "$OP_TOKEN_FILE"
    print_success "Saved the token to $OP_TOKEN_FILE (root, 0600), so the install does not ask again."
fi
unset TOKEN CURRENT

print_header "Next"
print_action "Clone the repository as $CLONE_USER:"
print_hint   "  ${HL}git clone git@github.com:<owner>/<repo>.git${NC}"
