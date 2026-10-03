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
# Install the 1Password CLI (`op`) and this machine's service account tokens,
# and prove the token opens the vault. login-store-decisions.md.
#
#   sudo bash add_1password.sh              install, ask both tokens, test them
#   sudo bash add_1password.sh --test-only  test what is already installed
#   sudo bash add_1password.sh --replace    ask even when the stored tokens work
#
# The service account is made on the 1Password website, with access to the
# OP_VAULT vault only. Its token is shown once; keep it in your own vault.
#
# `op` comes from 1Password's own signed apt repository, the install their
# documentation gives. The signing key is checked against its published
# fingerprint before apt is told to trust it.
#
# The token is the one secret here: root 0600 at OP_TOKEN_FILE, systemd-creds
# encrypted to this host, handed to `op` through its environment, never as an
# argument (arguments show in `ps`).
# =============================================================================

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
OR=$'\033[38;5;208m'   # orange: the names to find in 1Password
YL=$'\033[33m'         # back to print_action's yellow

# Prompts. print_action cannot be one: it ends with a newline.
prompt_got()    { printf "   \033[32m✅ %s\033[0m\n" "$1"; }

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

# Duplicated from add_jenkins.sh, per the convention that each script stays
# runnable alone. One asterisk per character, as they arrive.
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

# First characters, stars, last characters: enough to recognise.
masked() { printf '%s…%s' "${1:0:8}" "${1: -4}"; }

TEST_ONLY=0
REPLACE=0
case "${1:-}" in
    --test-only) TEST_ONLY=1 ;;
    --replace)   REPLACE=1 ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This installs a package and a root-only token, so it needs root."
    print_action "Run: sudo bash $0 $*"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# Two configs, two service accounts: live and TEST. test-machine-decisions.md.
LIVE_CONF="${SITES_CONF:-/etc/hostings/hostings.conf}"
TEST_CONF="${SITES_TEST_CONF:-/etc/hostings/hostings.test.conf}"

conf_from() {
    local file="$1" key="$2" def="$3" v
    v="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null \
         | head -1 | cut -d= -f2-)"
    v="${v%%#*}"
    v="$(printf '%s' "$v" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    printf '%s' "${v:-$def}"
}

CONFS=()
for c in "$LIVE_CONF" "$TEST_CONF"; do
    [ -f "$c" ] && CONFS+=("$c")
done

# 1Password's published signing key, from their CLI install documentation.
OP_KEY_URL="https://downloads.1password.com/linux/keys/1password.asc"
OP_KEY_FPR="3FEF9748469ADBE15DA7CA80AC2D62742012EA22"
OP_KEYRING="/usr/share/keyrings/1password-archive-keyring.gpg"
OP_LIST="/etc/apt/sources.list.d/1password.list"
DEBSIG_ID="AC2D62742012EA22"

LOG="$(mktemp)"
trap 'spinner_stop; { stty echo < /dev/tty; } 2>/dev/null || true; rm -f "$LOG"' EXIT

# =============================================================================
# Pre-flight
# =============================================================================
ERRORS=()
[ ${#CONFS[@]} -gt 0 ] || ERRORS+=("No config at $LIVE_CONF or $TEST_CONF. Run this from a clone of the repository.")
for c in ${CONFS[@]+"${CONFS[@]}"}; do
    [ -n "$(conf_from "$c" OP_VAULT '')" ] || ERRORS+=("No OP_VAULT in $c. Add: OP_VAULT = <vault name>")
    case "$(conf_from "$c" OP_TOKEN_FILE /root/.op_service_account_token)" in
        /*) ;;
        *)  ERRORS+=("OP_TOKEN_FILE in $c must be an absolute path.") ;;
    esac
done
if [ ${#CONFS[@]} -eq 2 ] && \
   [ "$(conf_from "$LIVE_CONF" OP_TOKEN_FILE /root/.op_service_account_token)" = \
     "$(conf_from "$TEST_CONF" OP_TOKEN_FILE /root/.op_service_account_token)" ]; then
    ERRORS+=("Live and TEST name the same OP_TOKEN_FILE, so one token would overwrite the other.")
fi
ARCH="$(dpkg --print-architecture 2>/dev/null || true)"
case "$ARCH" in
    amd64|arm64) ;;
    *) ERRORS+=("1Password publishes op for amd64 and arm64 only, and this machine is '${ARCH:-unknown}'.") ;;
esac
for tool in curl gpg systemd-creds; do
    command -v "$tool" >/dev/null 2>&1 || ERRORS+=("$tool is missing. Install it: sudo apt install $tool")
done
if [ ${#ERRORS[@]} -gt 0 ]; then
    for e in "${ERRORS[@]}"; do print_error "$e"; done
    exit 1
fi

# =============================================================================
# The CLI
# =============================================================================
print_header "1Password CLI"

if command -v op >/dev/null 2>&1; then
    print_success "op $(op --version 2>/dev/null) is already installed."
elif [ "$TEST_ONLY" = "1" ]; then
    print_error "op is not installed, so there is nothing to test."
    print_action "Run: sudo bash $0"
    exit 1
else
    spinner_start "Fetching 1Password's signing key..."
    if ! curl -fsS --max-time 30 "$OP_KEY_URL" -o "$LOG.asc" > "$LOG" 2>&1; then
        spinner_stop
        print_error "Could not fetch $OP_KEY_URL:"
        tail -5 "$LOG"
        exit 1
    fi
    spinner_stop
    # Checked before apt trusts it: a key that is not theirs must never sign
    # packages that run as root.
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

    spinner_start "Installing 1password-cli..."
    if ! { apt-get update -q && apt-get install -y -q 1password-cli; } > "$LOG" 2>&1; then
        spinner_stop
        print_error "Installing 1password-cli failed:"
        tail -20 "$LOG"
        exit 1
    fi
    spinner_stop
    print_success "Installed op $(op --version 2>/dev/null)"
fi

# =============================================================================
# The tokens: one per config, live first
# =============================================================================
FAILED=0

# Returns 0 when the token opens the vault. The token goes in through the
# environment of this one command only.
vault_opens() {
    OP_SERVICE_ACCOUNT_TOKEN="$1" op vault get "$2" --format json > "$LOG" 2>&1
}

# Encrypted to this host. A plain file is still read: the first clone may have
# written one before this script ran.
token_file_read() {  # <file> <credential name>
    local t
    t="$(systemd-creds decrypt --name="$2" "$1" - 2>/dev/null)" \
        || t="$(grep -m1 -E '^(ops_|eyJ)' "$1" 2>/dev/null)" || return 1
    printf '%s' "$t" | tr -d '[:space:]'
}

# The token goes in on stdin, so the plain value never lands on disk.
token_file_write() {  # <file> <credential name> <token>
    local tmp
    [ -d "$(dirname "$1")" ] || install -d -m 0700 "$(dirname "$1")"
    tmp="$(dirname "$1")/.op-token.$$.new"
    rm -f "$tmp"
    if ! printf '%s' "$3" | (umask 077; systemd-creds encrypt --name="$2" - "$tmp") 2>/dev/null; then
        rm -f "$tmp"; return 1
    fi
    chmod 0600 "$tmp"
    mv -T -f "$tmp" "$1"
}

setup_token() {
    local label="$1" conf="$2"
    local vault conn_vault token_file item item_vault current new v
    vault="$(conf_from "$conf" OP_VAULT '')"
    conn_vault="$(conf_from "$conf" OP_CONNECT_VAULT '')"
    token_file="$(conf_from "$conf" OP_TOKEN_FILE /root/.op_service_account_token)"
    item="$(conf_from "$conf" OP_TOKEN_ITEM '')"
    item_vault="$(conf_from "$conf" OP_TOKEN_ITEM_VAULT '')"

    print_header "$label service account token"
    current=""
    [ -f "$token_file" ] && current="$(token_file_read "$token_file" op-token)"

    # A token already in place that opens every vault is kept without asking,
    # so an install with the tokens pushed beforehand runs unattended. A token
    # that fails, or --replace, still reaches the question.
    local kept=0
    if [ "$TEST_ONLY" = "0" ] && [ "$REPLACE" = "0" ] && [ -n "$current" ]; then
        kept=1
        for v in "$vault" ${conn_vault:+"$conn_vault"}; do
            spinner_start "Trying the stored $label token on vault $v..."
            vault_opens "$current" "$v" || kept=0
            spinner_stop
        done
        if [ "$kept" = "1" ]; then
            print_success "The stored $label token opens its vaults, so it was kept without asking."
        else
            print_info "The stored $label token does not open its vaults, so it is asked for."
        fi
    fi

    if [ "$kept" = "1" ]; then
        new="$current"
    elif [ "$TEST_ONLY" = "0" ]; then
        print_action "NEEDED: $label token → Vault: ${OR}${item_vault:-?}${YL} → Item: ${OR}${item:-? (set OP_TOKEN_ITEM in $(basename "$conf"))}${YL}"
        if [ -n "$current" ]; then
            read_secret "   Credential [now $(masked "$current"), Enter keeps it]: "
        else
            read_secret "   Credential: "
        fi
        # Quotes and backticks ride along when a token is copied out of a
        # command or a note; no token contains one.
        new="$(printf '%s' "$SECRET" | tr -d "[:space:]\`\"'")"
        unset SECRET
        [ -z "$new" ] && new="$current"
        if [ -z "$new" ]; then
            print_error "No $label token given and none stored, so nothing was saved."
            FAILED=1; return 0
        fi
        case "$new" in
            ops_*) ;;
            *) print_error "That is not a service account token: they start with ops_. Nothing was saved."
               FAILED=1; return 0 ;;
        esac
        prompt_got "$label token $(masked "$new")"
    else
        new="$current"
        if [ -z "$new" ]; then
            print_error "No $label token at $token_file, so there is nothing to test."
            FAILED=1; return 0
        fi
    fi

    [ "$kept" = "1" ] || for v in "$vault" ${conn_vault:+"$conn_vault"}; do
        spinner_start "Opening vault $v..."
        if ! vault_opens "$new" "$v"; then
            spinner_stop
            print_error "The $label token does not open vault '$v':"
            tail -3 "$LOG"
            if grep -q "DecodeSACredentials" "$LOG"; then
                print_info "The token itself is damaged: copy it again, only the credential field."
            else
                print_info "Give the service account access to '$v' on the 1Password website."
            fi
            [ "$TEST_ONLY" = "0" ] && print_info "Nothing was saved; the stored $label token, if any, is unchanged."
            FAILED=1; return 0
        fi
        spinner_stop
        print_success "$label token opens '$v'."
    done

    if [ "$TEST_ONLY" = "0" ]; then
        # An unchanged token still gets written when the file is plain.
        if [ "$new" = "$current" ] \
           && systemd-creds decrypt --name=op-token "$token_file" - >/dev/null 2>&1; then
            print_info "$token_file is unchanged."
        elif token_file_write "$token_file" op-token "$new"; then
            print_success "Saved the $label token to $token_file (root, 0600, encrypted to this host)."
        else
            print_error "systemd-creds could not encrypt the $label token. $token_file is unchanged."
            FAILED=1
        fi
    fi
}

for c in "${CONFS[@]}"; do
    if [ "$c" = "$LIVE_CONF" ]; then setup_token "Live" "$c"; else setup_token "TEST" "$c"; fi
done
exit "$FAILED"
