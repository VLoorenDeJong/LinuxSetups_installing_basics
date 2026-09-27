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
# The whole mail stack, in the one order that works.
#
# Five scripts, each of which still runs on its own. This does nothing they
# cannot do; it removes the need to remember which comes first, and stops
# halfway rather than continuing past a failure.
#
# WHY THIS ORDER, AND IT IS NOT NEGOTIABLE
#
#   1. the store     everything else writes into it, and it makes the vmail user
#   2. Dovecot       owns the mailboxes. Starts without Postfix, deliberately
#   3. Postfix       delivers through Dovecot, and re-runs it to add the socket
#   4. Rspamd        filters Postfix's mail, so Postfix must exist first
#   5. Roundcube     reads through Dovecot and sends through Postfix
#
# The one that surprises people is 2 before 3: Dovecot's delivery socket is
# owned by the postfix user, so it cannot be defined before that package
# exists. Dovecot therefore starts without it, and step 3 runs step 2 again.
#
# IT ASKS THINGS, SO IT IS NOT UNATTENDED
#
# The store prints a backup password once, and Dovecot asks for one password per
# mailbox. Neither can be automated: a generated password has to be shown, and
# anything shown is in the scrollback.
#
# Usage:
#   sudo bash add_mail_stack.sh            run all five
#   sudo bash add_mail_stack.sh --check    ask each what it would do, change nothing
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

MODE="apply"
PASS=()

usage() {
    echo "Usage: $0 [--check] [--domain <domain>] [--mail-root <path>]" >&2
    echo "          [--mailbox <name>]... [--relay <host:port>] [--cert-dir <path>]" >&2
    echo "" >&2
    echo "Every option except --check is handed to the scripts that understand" >&2
    echo "it. Anything not given is taken from hostings.conf if there is one," >&2
    echo "and asked for if there is not." >&2
    exit 1
}

# Collected and handed down rather than interpreted here. This script decides
# the ORDER and nothing else: the moment it starts understanding options, it
# becomes a second place where the meaning of --mail-root is defined.
while [ $# -gt 0 ]; do
    case "$1" in
        --check)   MODE="check"; shift ;;
        -h|--help) usage ;;
        --*)
            if [ $# -ge 2 ] && [ "${2#--}" = "$2" ]; then
                PASS+=("$1" "$2"); shift 2
            else
                PASS+=("$1"); shift
            fi
            ;;
        *) print_error "Unknown argument: $1"; usage ;;
    esac
done

# Which script understands which option. A script given one it does not know
# exits on an unknown argument, so this is not optional bookkeeping.
opts_for() {
    local script="$1" out=() i=0
    local -a want
    case "$script" in
        add_mail_store.sh) want=(--domain --mail-root --backup-repo --backup-interval --mailbox) ;;
        add_dovecot.sh)    want=(--domain --mail-root --cert-dir --mailbox) ;;
        add_postfix.sh)    want=(--domain --hostname --cert-dir --relay --mail-domain) ;;
        add_rspamd.sh)     want=(--mail-root --selector --domain) ;;
        add_roundcube.sh)  want=(--domain --hostname) ;;
    esac
    while [ $i -lt ${#PASS[@]} ]; do
        for w in "${want[@]}"; do
            if [ "${PASS[$i]}" = "$w" ]; then
                out+=("${PASS[$i]}" "${PASS[$((i+1))]}")
                break
            fi
        done
        i=$((i + 2))
    done
    # Guarded, because `printf '%s\n'` with no arguments still prints one empty
    # line, which mapfile turns into a single empty argument and the receiving
    # script rejects as an unknown option.
    [ ${#out[@]} -eq 0 ] && return 0
    printf '%s\n' "${out[@]}"
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 ${1:-}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The order above, as an array, the same shape start_install.sh uses. A script
# here does one thing and stays runnable alone; this only decides the sequence.
STACK=(
    "add_mail_store.sh:the maildirs, the vmail user and the encrypted backup"
    "add_dovecot.sh:the mailboxes, IMAPS on 993, and the accounts"
    "add_postfix.sh:accepting mail on 25, sending on 587 and 465"
    "add_rspamd.sh:DKIM signatures, spam filing, and learning from you"
    "add_roundcube.sh:reading mail in a browser"
)

print_header "Mail stack"
print_status "Mode: $MODE"
echo ""
print_status "Five scripts, in the only order that works:"
n=0
for entry in "${STACK[@]}"; do
    n=$((n + 1))
    print_status "  $n. ${entry%%:*}  ${entry#*:}"
done

if [ "$MODE" = "apply" ]; then
    echo ""
    print_info "Two of them stop and ask you something:"
    print_info "  the store prints a backup password ONCE, for your password vault"
    print_info "  Dovecot asks for a password per mailbox"
    print_action "So do not walk away from this one."
fi

# Missing scripts are found now, not four steps in. A stack that stops at step
# four leaves mail half configured, which is worse than not starting.
MISSING=()
for entry in "${STACK[@]}"; do
    [ -f "$SCRIPT_DIR/${entry%%:*}" ] || MISSING+=("${entry%%:*}")
done
if [ ${#MISSING[@]} -gt 0 ]; then
    echo ""
    print_error "Missing from $SCRIPT_DIR, so nothing was run:"
    for m in "${MISSING[@]}"; do print_error "  - $m"; done
    exit 1
fi

DONE=()
STEP=0
TOTAL=${#STACK[@]}

for entry in "${STACK[@]}"; do
    script="${entry%%:*}"
    STEP=$((STEP + 1))

    printf "\n\033[36m=== Step %d of %d: %s ===\033[0m\n" "$STEP" "$TOTAL" "$script"
    # The description again here, not only in the list at the top. Between this
    # banner and the child script's first line there is nothing on screen, and
    # by step four the list has scrolled away.
    print_status "${entry#*:}"

    # --check is passed through where the script has it. add_mail_store.sh does
    # not, and is skipped rather than run: a check run that installs something
    # is not a check run.
    mapfile -t _opts < <(opts_for "$script")

    if [ "$MODE" = "check" ]; then
        if grep -q -- "--check" "$SCRIPT_DIR/$script"; then
            bash "$SCRIPT_DIR/$script" --check ${_opts+"${_opts[@]}"} || {
                print_error "$script reported a problem. Fix that before running the stack."
                exit 1
            }
        else
            print_info "$script has no --check, so it was skipped."
        fi
        continue
    fi

    if ! bash "$SCRIPT_DIR/$script" ${_opts+"${_opts[@]}"}; then
        echo ""
        print_error "$script failed, so the stack stopped here."
        print_info "Steps that already finished are done and are safe to re-run:"
        for d in ${DONE+"${DONE[@]}"}; do print_info "  - $d"; done
        print_action "Fix the cause, then run this again. Every step is re-runnable."
        exit 1
    fi
    DONE+=("$script")
done

if [ "$MODE" = "check" ]; then
    echo ""
    print_success "Every step that can report did so, and nothing was changed."
    exit 0
fi

print_header "Mail stack done"
print_success "All $TOTAL steps completed."
echo ""
print_status "What exists now:"
print_status "  mailboxes, backed up every 15 minutes to an encrypted repository"
print_status "  IMAPS on 993, submission on 587 and 465"
print_status "  DKIM signing, spam filed into Junk, and training as you tidy"
print_status "  Roundcube installed, waiting for a hostname"
echo ""
print_action "Two things are NOT done, and both are deliberate:"
print_info "  1. The MX record still points elsewhere, so no mail arrives yet."
print_action "     Add it after the drive swap. add_rspamd.sh --dns prints it again."
print_info "  2. Roundcube has no hostname. Add a website row for it in the config."
