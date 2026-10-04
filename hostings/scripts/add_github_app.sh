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
# Install the GitHub App's private key on this machine, and prove it works.
#
#   sudo bash add_github_app.sh              paste the key, install it, test it
#   sudo bash add_github_app.sh --key-file /path/to/key.pem
#   sudo bash add_github_app.sh --test-only  test what is already installed
#
# WHAT THIS REPLACES, and why it is worth a script of its own.
#
# A personal access token cannot renew itself. The first one on this machine
# died silently on 2026-08-18: every clone started failing and it took two days
# to find, because a dead token and a missing repository look identical from
# the outside. An App's private key does not expire, and the tokens minted from
# it live one hour and are made fresh each time. There is nothing to notice.
#
# THE APP IS CREATED ONCE, EVER, AND NOT HERE. It is made in a browser at
# github.com/settings/apps, which cannot be automated and does not need to be:
# it survives every rebuild of this machine. Only the key has to be put back,
# and a new one can be generated from that page at any time, so losing the file
# costs two clicks rather than the App.
#
# THE KEY IS ASKED FOR, NEVER GENERATED AND NEVER STORED IN THIS REPOSITORY.
# The repo holds its path and the two ID numbers, which are not secret.
# =============================================================================

export DEBIAN_FRONTEND=noninteractive

print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }
# Yellow means "this needs you", never "warning": a question, an instruction,
# a URL to go and open. Anything the reader cannot act on is cyan.
# Conventions: bash-installer-conventions.md.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }

# How to explain an ask without drowning it.
#
#   yellow   the ask. One line, and the only yellow on screen.
#   plain    the explanation. Most of it, in whatever colour the terminal
#            normally uses, because most of it is optional reading.
#   cyan     inside that explanation, the parts to actually find: a URL, a
#            button to click, the shape of the number being looked for.
#
# The version before this put the whole explanation in yellow. Ten yellow lines
# where nine are "here is how to find it if you do not already know" buries the
# one line that is a question.
print_hint()    { printf "   %s\n" "$1"; }
HL=$'\033[36m'     # cyan: the bit to look for
NC=$'\033[0m'      # back to the terminal's own colour

# A prompt is the ask, so it is yellow, and it keeps the cursor on its line.
# print_action cannot do that: it ends with a newline.
#
# EVERY ESCAPE IN THIS SCRIPT LIVES IN THIS BLOCK. Prompts were written inline
# as printf "\033[33m..." scattered through the file, and a search-and-replace
# over them left \033[1;35m33[33m in seven places, printing the colour code
# instead of applying it. One place to get right is one place to get wrong.
prompt_ask()    { printf "\n   \033[33m%s\033[0m %s" "$1" "${2:-}"; }
prompt_kept()   { printf "   \033[32m✅ kept: %s\033[0m\n" "$1"; }
prompt_got()    { printf "   \033[32m✅ got it: %s\033[0m\n" "$1"; }
prompt_retry()  { printf "   \033[33m%s\033[0m\n" "$1"; }
prompt_open()   { printf "\n   \033[33m%s\033[0m\n" "$1"; }
print_literal() { printf "   \033[1m%s\033[0m\n" "$1"; }
print_masked()  { printf "   \033[32m%s\033[0m\n" "$1"; }

# The busy indicator every other script in this fleet uses, copied exactly.
# A GitHub round trip is a few seconds of silence, which reads as a hang.
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

print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }


TEST_ONLY=0
KEY_SOURCE=""
ADMIN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --test-only)   TEST_ONLY=1; shift ;;
        --admin)       ADMIN=1; shift ;;
        --key-file)    KEY_SOURCE="${2:-}"; shift 2 ;;
        --key-file=*)  KEY_SOURCE="${1#--key-file=}"; shift ;;
        -h|--help)
            echo "Usage: sudo $0 [--admin] [--key-file <path>] [--test-only]" >&2
            exit 1 ;;
        *) print_error "Unknown argument '$1'"; exit 1 ;;
    esac
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script writes into /etc, so it needs sudo."
    print_action "Run with: sudo $0 $*"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

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

# --admin installs a TEST machine's second App, the one allowed to write, for
# GITHUB_ADMIN_TARGETS only (github_app_token.sh). Same steps, other names.
PFX="GITHUB_APP"
SECRET_NAME="github-app-key"
DEFAULT_KEY_FILE="/etc/github-app/app.pem"
TEST_TARGET=""
if [ "$ADMIN" -eq 1 ]; then
    PFX="GITHUB_ADMIN_APP"
    SECRET_NAME="github-admin-app-key"
    DEFAULT_KEY_FILE="/etc/github-app/admin-app.pem"
    TEST_TARGET="$(conf_get GITHUB_ADMIN_TARGETS "")"
    TEST_TARGET="${TEST_TARGET%% *}"
    # Zero, not a failure: the install runs --admin on every machine, and a live
    # one has no second App.
    if [ -z "$TEST_TARGET" ]; then
        print_info "No GITHUB_ADMIN_TARGETS in $SITES_CONF, so this machine has no second App."
        exit 0
    fi
fi

KEY_FILE="$(conf_get "${PFX}_KEY_FILE" "$DEFAULT_KEY_FILE")"
APP_ID="$(conf_get "${PFX}_ID" "")"
INSTALL_ID="$(conf_get "${PFX}_INSTALLATION_ID" "")"

print_header "GitHub App"

for tool in openssl curl; do
    command -v "$tool" >/dev/null 2>&1 || { print_error "$tool is not installed."; exit 1; }
done

# -----------------------------------------------------------------------------
# The two numbers. Neither is secret, and both belong in the config so that a
# rebuilt machine asks only for the key.
# -----------------------------------------------------------------------------
# ALWAYS ASKED, EVEN WHEN A VALUE IS ALREADY KNOWN.
#
# A script that skips a question because the answer is already on disk is a
# script you cannot use to correct a wrong answer, and a wrong answer is the
# reason anybody runs it a second time. So every value is asked for every time;
# an empty Enter keeps the current one, which is shown because these two
# numbers are not secret.
ask_id() {
    local -n __out="$1"
    local label="$2" example="$3" current="$4" answer=""
    while true; do
        if [ -n "$current" ]; then
            prompt_ask "$label" "[now $current, Enter keeps it]: "
        else
            prompt_ask "$label" "(digits, like $example, then Enter): "
        fi
        # /dev/tty, not stdin: an installer that has already consumed its own
        # stdin would otherwise answer this from whatever was buffered.
        read -r answer < /dev/tty || true
        answer="${answer//[^0-9]/}"
        if [ -z "$answer" ] && [ -n "$current" ]; then
            answer="$current"
            prompt_kept "$answer"
            break
        fi
        if [ -n "$answer" ]; then
            prompt_got "$answer"
            break
        fi
        prompt_retry "Digits only. Try again."
    done
    __out="$answer"
}

# Vault first: the two numbers are fields "App ID" and "Installation ID" on the
# App's info item (SECRET_ITEM_<name>_info). The keyboard is the fallback.
VAULT_APP_ID=""
VAULT_INSTALL_ID=""
if [ -f "$SCRIPT_DIR/secret_ask.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/secret_ask.sh" || true
fi
if [ "${SECRET_READY:-0}" = "1" ] && command -v secret_entry_get >/dev/null 2>&1; then
    _fields="$(secret_entry_get "$(_file_title "${SECRET_NAME%-key}-info")" 2>/dev/null)" || _fields=""
    _field() { printf '%s\n' "$_fields" | awk -F'\t' -v l="$1" 'NF >= 2 && tolower($(NF-1)) == tolower(l) { print $NF; exit }' | tr -cd '0-9'; }
    VAULT_APP_ID="$(_field "App ID")"
    VAULT_INSTALL_ID="$(_field "Installation ID")"
fi

# Each number on its own: whatever the vault has is used, only a missing one
# is asked.
for _v in APP_ID INSTALL_ID; do
    _got="VAULT_${_v}"
    [ -n "${!_got}" ] || continue
    [ "${!_got}" != "${!_v}" ] && WRITE_BACK=1
    printf -v "$_v" "%s" "${!_got}"
done
[ -n "$VAULT_APP_ID" ] && print_info "App ID ${VAULT_APP_ID} read from the vault."
[ -n "$VAULT_INSTALL_ID" ] && print_info "Installation ID ${VAULT_INSTALL_ID} read from the vault."

if [ "$TEST_ONLY" -ne 1 ] && { [ -z "$VAULT_APP_ID" ] || [ -z "$VAULT_INSTALL_ID" ]; }; then
    # Every ask NAMES THE THING FIRST. Four different values are wanted over
    # this run and the next, and a heading that says only "over to you" leaves
    # the reader working out which of the four this one is from the body text.
    if [ -z "$VAULT_APP_ID" ]; then
        OLD_APP_ID="$APP_ID"
        echo ""
        print_action "NEEDED: the GitHub App ID"
        print_hint   "if you do not have it already:"
        print_hint   "  go to ${HL}https://github.com/settings/apps${NC}"
        print_hint   "  click your App, then look for ${HL}App ID${NC} near the top"
        ask_id APP_ID "App ID" "1234567" "$OLD_APP_ID"
    fi
    if [ -z "$VAULT_INSTALL_ID" ]; then
        OLD_INSTALL_ID="$INSTALL_ID"
        echo ""
        print_action "NEEDED: the GitHub App Installation ID"
        print_hint   "a DIFFERENT number from the App ID."
        print_hint   "if you do not have it already:"
        print_hint   "  go to ${HL}https://github.com/settings/installations${NC}"
        print_hint   "  click ${HL}Configure${NC} next to your App"
        print_hint   "  the number is the tail of the address bar:"
        print_hint   "    .../settings/installations/${HL}12345678${NC}"
        print_hint   "  not listed? the App was never installed. Open the App"
        print_hint   "  page and click ${HL}Install App${NC} in the left sidebar."
        ask_id INSTALL_ID "Installation ID" "87654321" "$OLD_INSTALL_ID"
    fi
    if [ "$APP_ID" != "${OLD_APP_ID-$APP_ID}" ] || [ "$INSTALL_ID" != "${OLD_INSTALL_ID-$INSTALL_ID}" ]; then
        WRITE_BACK=1
    fi
    if [ "${SECRET_READY:-0}" = "1" ]; then
        print_action "Add what you typed to the vault item '$(_file_title "${SECRET_NAME%-key}-info")'"
        print_hint   "  as fields ${HL}App ID${NC} and ${HL}Installation ID${NC}, and the next run asks nothing."
    fi
fi

if [ -z "$APP_ID" ] || [ -z "$INSTALL_ID" ]; then
    print_error "No App ID or Installation ID, so nothing can be tested."
    exit 1
fi

# -----------------------------------------------------------------------------
# The key
# -----------------------------------------------------------------------------

# The vault, if this machine has one. Guarded and never fatal: a lone copy of
# this script on a bare machine keeps its own paste, below.
FROM_VAULT=0
if [ -f "$SCRIPT_DIR/secret_ask.sh" ]; then
    # shellcheck source=/dev/null
    . "$SCRIPT_DIR/secret_ask.sh" || true
fi

install_key() {
    local tmp
    tmp="$(mktemp)"
    chmod 600 "$tmp"

    if [ -n "$KEY_SOURCE" ]; then
        if [ ! -r "$KEY_SOURCE" ]; then
            print_error "Cannot read $KEY_SOURCE"
            rm -f "$tmp"; exit 1
        fi
        cat "$KEY_SOURCE" > "$tmp"
    elif command -v secret_ask >/dev/null 2>&1 \
         && secret_ask "$SECRET_NAME" --label "the GitHub App private key" \
                       --multiline --no-ask > "$tmp" && [ -s "$tmp" ]; then
        # The vault had it. Nothing to paste, and the repair below still runs:
        # a key stored in the app comes back with its line breaks flattened.
        FROM_VAULT=1
    else
        echo ""
        print_action "NEEDED: the GitHub App private key, the whole .pem file"
        print_hint   "from the file you downloaded, or your password vault."
        print_hint   "paste ALL of it, ${HL}-----BEGIN${NC} and ${HL}-----END${NC} lines included."
        print_hint   "it stops at the END line by itself, nothing to press after."
        print_hint   "not echoed: you will see a masked version of what arrived."
        print_hint   "lost it? generate a new one on the App page. An App can"
        print_hint   "hold several keys, so this one would keep working too."
        prompt_open "Paste now:"

        # Echo off for the same reason a password prompt has it off. Restored
        # by the trap as well as at the end, or a Ctrl+C mid-paste leaves the
        # terminal silently unable to show anything the user types afterwards.
        local saved_stty
        saved_stty="$(stty -g < /dev/tty 2>/dev/null || true)"
        # shellcheck disable=SC2064
        trap "stty '$saved_stty' < /dev/tty 2>/dev/null || stty echo < /dev/tty 2>/dev/null; exit 130" INT TERM
        stty -echo < /dev/tty 2>/dev/null || true

        # Read to the END line rather than to EOF, so a paste that does not end
        # in a newline still finishes, and so a stray extra paste is ignored.
        # Nothing is echoed here. The masked three lines are printed once,
        # below, after the key has been validated and repaired if it needed it:
        # printing anything during the paste as well would show BEGIN twice,
        # and printing before validation would show a mask of something that
        # turns out not to be a key.
        # Stops on the END marker wherever it appears, including on the very
        # first line: a key out of a password vault is one long line carrying
        # both markers, and waiting for a further line after it left the prompt
        # sitting there with the whole key already read.
        while IFS= read -r line < /dev/tty; do
            printf '%s\n' "$line" >> "$tmp"
            case "$line" in *"-----END"*"PRIVATE KEY-----"*) break ;; esac
        done

        stty "$saved_stty" < /dev/tty 2>/dev/null || stty echo < /dev/tty 2>/dev/null || true
        trap - INT TERM
    fi

    # The two markers first, because that is the failure a paste actually has:
    # a copy that grabbed the body and missed a line, or picked up the page
    # around it. openssl's own complaint about that is unreadable.
    local begin_line end_line
    # The marker only, never its whole line: on a one-line key that line is
    # the key, and both are printed back below as the "masked" display.
    begin_line="$(grep -o -m1 -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$tmp" | head -1 || true)"
    end_line="$(grep -o -m1 -- '-----END [A-Z ]*PRIVATE KEY-----' "$tmp" | head -1 || true)"

    if [ -z "$begin_line" ] || [ -z "$end_line" ]; then
        print_error "That does not look like a key file."
        echo ""
        print_info "It must start and end with these exact lines:"
        print_literal "-----BEGIN RSA PRIVATE KEY-----"
        print_literal "-----END RSA PRIVATE KEY-----"
        echo ""
        [ -z "$begin_line" ] && print_info "The BEGIN line is missing."
        [ -z "$end_line" ]   && print_info "The END line is missing."
        print_action "Copy the whole file, not just the middle."
        rm -f "$tmp"; exit 1
    fi

    key_is_valid() {
        openssl rsa -in "$1" -noout -check >/dev/null 2>&1 \
            || openssl pkey -in "$1" -noout >/dev/null 2>&1
    }

    # A PEM out of a password vault is usually flattened: one long line, or with
    # literal backslash-n where the newlines were. Every character is present
    # and openssl rejects it anyway, which reads as "the vault corrupted my
    # key" when nothing is wrong with it at all.
    #
    # So it is rebuilt rather than refused: markers on their own lines, body
    # folded back to 64 characters. Nothing is invented, only re-wrapped, and it
    # has to pass the same check afterwards as a key that arrived intact.
    if ! key_is_valid "$tmp"; then
        local rebuilt header footer body
        rebuilt="$(mktemp)"; chmod 600 "$rebuilt"

        header="$(grep -o -- '-----BEGIN [A-Z ]*PRIVATE KEY-----' "$tmp" | head -1)"
        footer="$(grep -o -- '-----END [A-Z ]*PRIVATE KEY-----' "$tmp" | head -1)"
        # Order matters. The markers contain spaces, so the whitespace has to
        # come out AFTER they are removed, not before: strip it first and
        # "BEGIN RSA PRIVATE KEY" becomes "BEGINRSAPRIVATEKEY", which matches
        # nothing and leaves the marker text sitting inside the body.
        body="$(sed 's/\\n/\n/g' "$tmp" | tr '\n\r' '  ' \
            | sed "s|.*${header}||; s|${footer}.*||" | tr -d ' \t')"

        {
            printf '%s\n' "$header"
            printf '%s' "$body" | fold -w 64
            printf '\n%s\n' "$footer"
        } > "$rebuilt"

        if key_is_valid "$rebuilt"; then
            mv "$rebuilt" "$tmp"
            chmod 600 "$tmp"
            print_info "The key arrived flattened onto one line, which is what a"
            print_info "   password vault does to a .pem. Line breaks restored."
        else
            rm -f "$rebuilt"
            print_error "Both marker lines are there, but the key between them is not valid."
            print_info "Not a line-wrap problem: rebuilding it did not help either."
            print_info "Usually a paste that lost a line, or a key for a different App."
            print_action "Download a fresh one: the App's page has 'Generate a private key'."
            rm -f "$tmp"; exit 1
        fi
    fi

    # Show it back, masked. Enough to see the right thing landed, never enough
    # to reconstruct it, and it stays that way in the scrollback and in any
    # screenshot of this install.
    local body head4 tail4
    body="$(sed -n '/-----BEGIN/,/-----END/p' "$tmp" | sed '1d;$d' | tr -d '\n\r')"
    head4="${body:0:3}"
    tail4="${body: -4}"
    echo ""
    print_masked "$begin_line"
    print_masked "${head4}*********${tail4}"
    print_masked "$end_line"
    echo ""

    mkdir -p "$(dirname "$KEY_FILE")"
    chmod 700 "$(dirname "$KEY_FILE")"
    mv "$tmp" "$KEY_FILE"
    chown root:root "$KEY_FILE"
    chmod 600 "$KEY_FILE"
    print_success "Key installed at $KEY_FILE, readable by root only."

    # A key that came from a paste or a file goes into the vault, so the next
    # drive is not asked for it. One that came FROM the vault is left alone.
    if [ "$FROM_VAULT" -ne 1 ] && command -v secret_save >/dev/null 2>&1; then
        secret_save "$SECRET_NAME" < "$KEY_FILE"
    fi
}

KEY_WORKS=0
if [ "$TEST_ONLY" -ne 1 ] && [ -z "$KEY_SOURCE" ] && [ -s "$KEY_FILE" ] && [ "${WRITE_BACK:-0}" != "1" ]; then
    # stdout is the token itself, so it is discarded rather than logged.
    spinner_start "Asking GitHub whether the installed key still works..."
    SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/github_app_token.sh" ${TEST_TARGET:+"$TEST_TARGET"} >/dev/null 2>&1 \
        && KEY_WORKS=1
    spinner_stop
    [ "$KEY_WORKS" -eq 1 ] || print_info "GitHub issued no token for the installed key, so it is asked about below."
fi

if [ "$TEST_ONLY" -ne 1 ]; then
    if [ -n "$KEY_SOURCE" ]; then
        install_key
    elif [ "$KEY_WORKS" -eq 1 ]; then
        # A key GitHub accepts is kept without asking. A broken one, or new IDs,
        # still reach the question below. To swap a working key: --key-file.
        print_success "The installed key at $KEY_FILE works (GitHub issued a token), so it was kept."
    elif [ -s "$KEY_FILE" ]; then
        # Asked even though one is installed, for the same reason as the IDs: a
        # wrong key is exactly why somebody runs this again, and a script that
        # skips the question cannot be used to fix it. Empty Enter keeps it.
        # A yes/no, NOT "paste here to replace". That version read the first
        # line with echo on, so the key appeared in the clear, and a key from a
        # vault arrives flattened onto one line, so the whole thing landed in
        # that one read and the paste prompt then asked for it a second time.
        #
        # Deciding first and pasting afterwards keeps the paste in the one place
        # that hides it.
        echo ""
        print_action "NEEDED: nothing, unless you want to change the key"
        print_hint   "a key is already installed at ${HL}$KEY_FILE${NC}"
        print_hint   "generating a new key on the App page does not revoke"
        print_hint   "this one, so both would keep working."
        prompt_ask "Replace it?" "[y/N]: "
        read -r REPLACE_ANSWER < /dev/tty || true
        case "${REPLACE_ANSWER,,}" in
            y|yes)
                install_key
                ;;
            *)
                print_success "Kept the key already installed."
                ;;
        esac
    else
        install_key
    fi
fi

if [ ! -s "$KEY_FILE" ]; then
    print_error "No key at $KEY_FILE, so nothing can be tested."
    exit 1
fi

# -----------------------------------------------------------------------------
# Write the two numbers back, so a rebuild asks only for the key
# -----------------------------------------------------------------------------
if [ "${WRITE_BACK:-0}" = "1" ] && [ -w "$SITES_CONF" ]; then
    # Update in place when the setting is already there. Appending only when it
    # is absent meant a corrected ID was taken for this run and then read back
    # from the old line on the next one, which looks exactly like the fix not
    # having worked.
    if grep -qE "^[[:space:]]*${PFX}_ID[[:space:]]*=" "$SITES_CONF"; then
        sed -i "s|^[[:space:]]*${PFX}_ID[[:space:]]*=.*|${PFX}_ID = ${APP_ID}|" "$SITES_CONF"
        sed -i "s|^[[:space:]]*${PFX}_INSTALLATION_ID[[:space:]]*=.*|${PFX}_INSTALLATION_ID = ${INSTALL_ID}|" "$SITES_CONF"
        print_success "Updated the App ID and Installation ID in $SITES_CONF."
        print_action "Commit that change."
    else
        {
            echo ""
            echo "# The GitHub App this machine authenticates as. Neither number is"
            echo "# secret: the App ID names it and the Installation ID names which"
            echo "# account it was installed on. The private key behind them is NOT in"
            echo "# this repository and never will be, only its path."
            echo "#"
            echo "# Written by add_github_app.sh so a rebuilt machine asks for the key"
            echo "# and nothing else."
            echo "${PFX}_ID = ${APP_ID}"
            echo ""
            echo "${PFX}_INSTALLATION_ID = ${INSTALL_ID}"
            echo ""
            echo "${PFX}_KEY_FILE = ${KEY_FILE}"
        } >> "$SITES_CONF"
        print_success "Wrote the App ID and Installation ID into $SITES_CONF."
        print_action "Commit that change, or the next rebuild asks for them again."
    fi
fi

# -----------------------------------------------------------------------------
# Prove it. An install that is not tested is a guess.
# -----------------------------------------------------------------------------
echo ""
spinner_start "Asking GitHub for a token..."
TOKEN="$(SITES_CONF="$SITES_CONF" bash "$SCRIPT_DIR/github_app_token.sh" ${TEST_TARGET:+"$TEST_TARGET"})" || {
    spinner_stop
    print_error "Could not mint a token, so the App is not usable yet."
    print_info "Most likely one of three things:"
    print_info "  the App ID is wrong, the App is registered but never INSTALLED,"
    print_info "  or the key belongs to a different App."
    exit 1
}
spinner_stop
print_success "Token minted. It is valid for one hour and was not written anywhere."

# What it can actually see. A token that mints but reaches nothing is the
# failure worth catching here rather than at the first deploy.
spinner_start "Asking what that token can reach..."
# Through github_api.sh, the one file that calls the API. The inline curl below
# stays as the fallback, per principle 2b: this script is the one that INSTALLS
# the App, so it has to work on a machine where nothing else is in place yet.
_API_SH=""
for _c in "$SCRIPT_DIR/github_api.sh" \
          /usr/local/lib/linuxbasics/hostings/scripts/github_api.sh; do
    [ -f "$_c" ] && { _API_SH="$_c"; break; }
done
if [ -n "$_API_SH" ] && [ "$ADMIN" -eq 0 ]; then
    REPOS="$(SITES_CONF="$SITES_CONF" bash "$_API_SH" GET \
        "/installation/repositories?per_page=100" 2>/dev/null)" || true
else
    REPOS="$(curl -fsS -H "Authorization: Bearer ${TOKEN}" \
        -H "Accept: application/vnd.github+json" \
        "https://api.github.com/installation/repositories?per_page=100" 2>/dev/null)" || true
fi
spinner_stop

COUNT="$(printf '%s' "$REPOS" | tr ',' '\n' | sed -n 's/.*"total_count"[[:space:]]*:[[:space:]]*\([0-9]*\).*/\1/p' | head -1)"

if [ -z "$COUNT" ]; then
    print_error "The token works but GitHub listed no repositories for it."
    exit 1
fi

print_success "The App can reach ${COUNT} repository(ies):"
printf '%s' "$REPOS" | tr ',' '\n' \
    | sed -n 's/.*"full_name"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/  \1/p' | head -20

echo ""
print_success "GitHub App installed and proven."

# -----------------------------------------------------------------------------
# Jenkins, if this machine has one.
#
# Not a separate thing to remember: Jenkins is the main consumer of this App,
# and an install that leaves it still holding a personal access token has
# achieved nothing that anybody notices. The companion script is still runnable
# on its own, for a machine where Jenkins arrives later.
# -----------------------------------------------------------------------------
JENKINS_SETUP="$SCRIPT_DIR/add_jenkins_github_credentials.sh"
if [ "$ADMIN" -eq 0 ] && { [ -x "$JENKINS_SETUP" ] || [ -f "$JENKINS_SETUP" ]; }; then
    if systemctl is-active --quiet jenkins 2>/dev/null; then
        echo ""
        print_status "Jenkins is running here, so it gets the App too."
        SITES_CONF="$SITES_CONF" bash "$JENKINS_SETUP" || {
            print_info "Jenkins was not fully set up. The App itself is fine."
            print_action "   Try again with: sudo bash $JENKINS_SETUP"
        }
    else
        print_status "No Jenkins running here, so nothing else to wire up."
        print_status "   If it arrives later: sudo bash $JENKINS_SETUP"
    fi
fi

echo ""
print_status "What still uses a personal access token, and can now stop:"
echo "   /etc/github-api/ghapi.cred    the provisioner"
