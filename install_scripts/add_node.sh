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

export DEBIAN_FRONTEND=noninteractive

# =============================================================================
# Node.js and npm: the BUILD toolchain for front-end sites.
#
# WHAT THIS IS FOR, AND WHAT IT IS NOT FOR
#
# A Vue, Angular, React or Svelte project is compiled to plain HTML, CSS and
# JavaScript and then served by a web server like any other static site. It
# needs Node to BUILD and nothing at all to SERVE.
#
# So this belongs on whatever machine runs the build, which in this fleet is
# the one running the CI jobs. A machine that only serves the finished files
# does not need it, and installing it there adds an attack surface for nothing.
#
# A Node SERVER, one that stays running and answers requests, is a different
# thing and wants a systemd unit and a reverse proxy. This script installs the
# toolchain either way; the difference is in how the application is deployed,
# not in what is installed.
#
# WHY NODESOURCE AND NOT THE DISTRO PACKAGE
#
# Ubuntu ships whatever Node was current when the release froze, and front-end
# toolchains move faster than that: Angular's CLI refuses to run below its
# supported major, with an error that names a version rather than a fix.
#
# The distro package is still the default here for exactly the reason
# add_dotnet.sh prefers it: it is what the rest of the system is tested
# against. NodeSource is used only when a major is asked for that the distro
# cannot supply, and the run says so.
#
# Usage:
#   sudo bash add_node.sh                 the distro's Node, or 22 via NodeSource
#   sudo bash add_node.sh --major 20      a specific major
#   sudo bash add_node.sh --distro        the distro package, whatever its major
#   sudo bash add_node.sh --check         report what would change, change nothing
# =============================================================================

# --- Inline utility functions (always defined, no sourcing required) ---
print_status()  { printf "\033[34m🔧 %s\033[0m\n" "$1"; }
print_success() { printf "\033[32m✅ %s\033[0m\n" "$1"; }
print_warning() { printf "\033[33m⚠️ %s\033[0m\n" "$1"; }

# Yellow means "this needs you", never "warning": a question, an instruction, a
# URL to go and open. Anything the reader cannot act on is cyan.
print_action()  { printf "\033[33m👉 %s\033[0m\n" "$1"; }
print_info()    { printf "\033[36mℹ️ %s\033[0m\n" "$1"; }
print_error()   { printf "\033[31m❌ %s\033[0m\n" "$1"; }
print_header()  { printf "\n\033[36m=== %s ===\033[0m\n" "$1"; }

# Braille spinner over a log file. Kill-safe regime: an apt install of a package
# set is retryable, so a timeout may terminate it. Output is never discarded.
SPIN_PID=""
spinner_start() {
    local message="$1"
    local frames=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    (
        local i=0
        while :; do
            printf "\r\033[K\033[34m%s %s\033[0m" "${frames[$((i % 10))]}" "$message"
            i=$((i + 1))
            sleep 0.1
        done
    ) &
    SPIN_PID=$!
}

spinner_stop() {
    [ -n "$SPIN_PID" ] && kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
    printf "\r\033[K"
}

# A spinner erases itself, so anything worth remembering is printed after it.
run_logged() {
    local message="$1" log="$2"
    shift 2
    spinner_start "$message"
    if "$@" >"$log" 2>&1; then
        spinner_stop
        return 0
    fi
    local rc=$?
    spinner_stop
    print_error "Failed (exit $rc): $*"
    print_error "Last 20 lines of $log:"
    tail -20 "$log" >&2 || true
    print_action "Full log: $log"
    return "$rc"
}

# =============================================================================
# Arguments
# =============================================================================
MODE="apply"
WANT_MAJOR=""
FORCE_DISTRO=0
DEFAULT_MAJOR=22

while [ $# -gt 0 ]; do
    case "$1" in
        --check)  MODE="check" ;;
        --distro) FORCE_DISTRO=1 ;;
        --major)
            shift
            WANT_MAJOR="${1:-}"
            case "$WANT_MAJOR" in
                ''|*[!0-9]*)
                    print_error "--major takes a number, for example: --major 22"
                    exit 1 ;;
            esac
            ;;
        *)
            print_error "Unknown argument: $1"
            print_action "Use --check, --distro, or --major <number>."
            exit 1 ;;
    esac
    shift
done

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo bash $0 $*"
    exit 1
fi

print_header "Node.js"

# =============================================================================
# What is here already
#
# Asked before anything is decided, because the commonest correct outcome for
# this script is "nothing to do".
# =============================================================================
HAVE_NODE=""
HAVE_NPM=""
HAVE_MAJOR=""
if command -v node >/dev/null 2>&1; then
    HAVE_NODE="$(node --version 2>/dev/null || true)"
    HAVE_MAJOR="$(printf '%s' "$HAVE_NODE" | sed -n 's/^v\([0-9]*\)\..*/\1/p')"
fi
command -v npm >/dev/null 2>&1 && HAVE_NPM="$(npm --version 2>/dev/null || true)"

if [ -n "$HAVE_NODE" ]; then
    print_info "Node $HAVE_NODE is installed, with npm ${HAVE_NPM:-MISSING}."
else
    print_info "Node is not installed."
fi

# What the distro would give, without installing it.
DISTRO_VER="$(apt-cache policy nodejs 2>/dev/null | sed -n 's/^ *Candidate: *//p' | head -1)"
DISTRO_MAJOR="$(printf '%s' "$DISTRO_VER" | sed -n 's/^\([0-9]*\)\..*/\1/p')"
[ -z "$DISTRO_VER" ] && DISTRO_VER="none"
print_info "The distro offers nodejs $DISTRO_VER."

# =============================================================================
# Decide the source
#
# The distro wins whenever it can satisfy what was asked for. NodeSource is the
# exception, and the run says which was chosen and why.
# =============================================================================
TARGET_MAJOR="$WANT_MAJOR"
[ -z "$TARGET_MAJOR" ] && TARGET_MAJOR="$DEFAULT_MAJOR"

USE_NODESOURCE=0
REASON=""

if [ "$FORCE_DISTRO" = "1" ]; then
    REASON="--distro was given, so the distro package is used whatever its major."
    TARGET_MAJOR="$DISTRO_MAJOR"
elif [ -n "$DISTRO_MAJOR" ] && [ "$DISTRO_MAJOR" -ge "$TARGET_MAJOR" ] 2>/dev/null; then
    REASON="The distro's nodejs $DISTRO_VER already meets major $TARGET_MAJOR."
else
    USE_NODESOURCE=1
    REASON="The distro offers $DISTRO_VER, which is below major $TARGET_MAJOR, so NodeSource is added."
fi
print_status "$REASON"

# Already good enough? Say so and stop, rather than reinstalling.
NOTHING_TO_DO=0
if [ -n "$HAVE_MAJOR" ] && [ -n "$HAVE_NPM" ] \
   && [ "$HAVE_MAJOR" -ge "$TARGET_MAJOR" ] 2>/dev/null; then
    NOTHING_TO_DO=1
fi

if [ "$MODE" = "check" ]; then
    if [ "$NOTHING_TO_DO" = "1" ]; then
        print_success "would change nothing: Node $HAVE_NODE already meets major $TARGET_MAJOR"
    elif [ "$USE_NODESOURCE" = "1" ]; then
        print_status "would add the NodeSource repository for major $TARGET_MAJOR"
        print_status "would install nodejs from it"
    else
        print_status "would install the distro's nodejs $DISTRO_VER"
    fi
    print_success "--check: nothing was changed."
    exit 0
fi

if [ "$NOTHING_TO_DO" = "1" ]; then
    print_success "Node $HAVE_NODE and npm $HAVE_NPM already meet major $TARGET_MAJOR. Nothing to do."
    exit 0
fi

# =============================================================================
# Install
# =============================================================================
LOG="$(mktemp /tmp/add_node.XXXXXX.log)"

if [ "$USE_NODESOURCE" = "1" ]; then
    # The keyring is written to /etc/apt/keyrings rather than the deprecated
    # apt-key, and the repository is pinned to signed-by that one key, so this
    # cannot silently start trusting anything else NodeSource publishes.
    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --max-time 30 https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
            | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg --yes 2>/dev/null; then
        print_error "Could not fetch the NodeSource signing key."
        print_action "Check outbound HTTPS, or run with --distro to use the distro package."
        exit 1
    fi
    chmod 0644 /etc/apt/keyrings/nodesource.gpg

    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_${TARGET_MAJOR}.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list
    print_status "Added the NodeSource repository for major $TARGET_MAJOR."

    run_logged "Updating package lists..." "$LOG" apt-get update -qq
fi

run_logged "Installing nodejs..." "$LOG" \
    apt-get install -y -qq --no-install-recommends nodejs
print_status "Installed the nodejs package."

# npm ships inside NodeSource's nodejs and separately on the distro, so it is
# asked for by name only when it is actually missing. Installing the distro's
# npm on top of a NodeSource node drags in a second node and breaks both.
if ! command -v npm >/dev/null 2>&1; then
    run_logged "Installing npm..." "$LOG" \
        apt-get install -y -qq --no-install-recommends npm
    print_status "Installed the npm package separately: nodejs did not carry it."
fi

# =============================================================================
# Verify, by asking the binaries rather than trusting apt
# =============================================================================
NEW_NODE="$(node --version 2>/dev/null || true)"
NEW_NPM="$(npm --version 2>/dev/null || true)"
NEW_MAJOR="$(printf '%s' "$NEW_NODE" | sed -n 's/^v\([0-9]*\)\..*/\1/p')"

if [ -z "$NEW_NODE" ] || [ -z "$NEW_NPM" ]; then
    print_error "Node or npm is still missing after the install."
    print_error "  node: ${NEW_NODE:-MISSING}"
    print_error "  npm:  ${NEW_NPM:-MISSING}"
    print_action "Full log: $LOG"
    exit 1
fi

if [ -n "$NEW_MAJOR" ] && [ "$NEW_MAJOR" -lt "$TARGET_MAJOR" ] 2>/dev/null; then
    print_error "Asked for major $TARGET_MAJOR and got $NEW_NODE."
    print_error "A front-end toolchain that requires $TARGET_MAJOR will refuse to run."
    print_action "Full log: $LOG"
    exit 1
fi

rm -f "$LOG"

print_success "Node $NEW_NODE and npm $NEW_NPM are installed."
print_info "This is a BUILD toolchain. A site built with it is served as plain"
print_info "files and needs nothing running."
