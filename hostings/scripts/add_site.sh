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
# Add one site, by answering questions instead of editing a table.
#
# This is layer 2 of the three-layer design. Layer 1 is the generators, which
# each do one thing and stay runnable alone. Layer 3 is hostings.conf and
# maintain_services.sh, which reconcile the whole machine against the whole
# file. Both already exist. The gap was between them: adding ONE site meant
# hand-editing a twelve column row and hoping the columns lined up.
#
# EVERYTHING IS ASKED UP FRONT
#
# A run that stops for a question twenty minutes in, over SSH on a slow line, is
# a run that gets abandoned. Every answer is collected, the row is shown, and
# only then is anything written.
#
# IT WRITES A ROW AND NOTHING ELSE
#
# No vhost, no unit, no certificate. It appends to hostings.conf, validates it,
# and hands over to maintain_services.sh, which is the one thing that turns
# rows into a machine. A second writer would be a second answer to "what does
# this machine serve".
#
# Usage:
#   sudo bash add_site.sh              ask, add the row, apply it
#   sudo bash add_site.sh --dry-run    ask, show the row, write nothing
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

DRY_RUN=0
case "${1:-}" in
    --dry-run) DRY_RUN=1 ;;
    "")        ;;
    *)
        print_error "Unknown argument: $1"
        print_action "Use --dry-run, or no argument at all."
        exit 1
        ;;
esac

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0 ${1:-}"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
. "$SCRIPT_DIR/config.sh" 2>/dev/null \
    || . /usr/local/lib/linuxbasics/hostings/scripts/config.sh 2>/dev/null \
    || conf_active() { printf '%s/hostings.conf' "$1"; }
SITES_CONF="${SITES_CONF:-$(conf_active "/etc/hostings")}"

if [ ! -f "$SITES_CONF" ]; then
    print_error "Config not found: $SITES_CONF"
    exit 1
fi

conf_get() {
    local key="$1" default="${2:-}" value
    value="$(sed -n "s/^[[:space:]]*${key}[[:space:]]*=//p" "$SITES_CONF" \
             | head -n1 | tr -d '\r' | sed 's/#.*//' | xargs)"
    printf '%s' "${value:-$default}"
}

BASE_DOMAIN="$(conf_get BASE_DOMAIN "")"
ENVS="$(conf_get ENVS "live")"

# Read from the terminal, not stdin: this may be called by something that has
# already consumed its own input, and a buffered answer to an earlier question
# silently answering a later one is very hard to see.
ask() {
    local prompt="$1" default="$2" answer
    if [ -n "$default" ]; then
        printf "\033[34m🔧 %s [%s]: \033[0m" "$prompt" "$default"
    else
        printf "\033[34m🔧 %s: \033[0m" "$prompt"
    fi
    read -r answer < /dev/tty
    printf '%s' "${answer:-$default}"
}

ask_yes_no() {
    local prompt="$1" default="$2" answer
    answer="$(ask "$prompt (yes/no)" "$default")"
    case "$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')" in
        y|yes|true|1) printf 'yes' ;;
        *)            printf 'no' ;;
    esac
}

print_header "Add a site"
print_status "Config: $SITES_CONF"
print_status "Domain: $BASE_DOMAIN"
echo ""
print_info "Every question is asked now. Nothing is written until you confirm."
echo ""

# =============================================================================
# 1. What kind of thing is it
# =============================================================================
print_status "What kind of site is this?"
print_status "  1  a .NET application, which this machine runs and serves"
print_status "  2  a website: plain files served from disk"
print_status "  3  something already running on a port, which Apache just fronts"
print_status "  4  a mailbox, with no website at all"
echo ""

KIND="$(ask "Choose 1, 2, 3 or 4" "1")"
case "$KIND" in
    1) TYPE="app" ;;
    2) TYPE="website" ;;
    3) TYPE="proxy" ;;
    4) TYPE="mailbox" ;;
    *) print_error "Not one of the four."; exit 1 ;;
esac

# =============================================================================
# 2. The name, which becomes the unit and the vhost filename
# =============================================================================
while true; do
    NAME="$(ask "A short name, lowercase, no spaces" "")"
    if [ -z "$NAME" ]; then
        print_error "A name is needed: it becomes the unit and the vhost filename."
        continue
    fi
    if ! printf '%s' "$NAME" | grep -qE '^[a-z0-9][a-z0-9_-]*$'; then
        print_error "Lowercase letters, digits, underscore and hyphen only."
        continue
    fi
    # Checked before anything is written rather than caught by the pre-flight
    # afterwards, because being told at the end that the first answer was wrong
    # means answering everything again.
    if grep -qE "^[[:space:]]*[a-z]+[[:space:]]*\|[[:space:]]*${NAME}[[:space:]]*\|" "$SITES_CONF"; then
        print_error "There is already a row called '$NAME'."
        continue
    fi
    break
done

PORT="-"; PATH_FIELD="-"; SUB="-"; REPO="-"; BRANCH="-"; AUTH="no"; AUTHUSERS="-"

# =============================================================================
# 3. The rest, which depends on the kind
# =============================================================================
case "$TYPE" in
    app)
        print_status "Ports are grouped: 8000s portfolio, 8100s progress, 8200s APIs, 8900s customer sites."
        PORT="$(ask "Which port, in the live band" "")"
        PATH_FIELD="$(ask "Path to the dll, relative to APP_ROOT" "")"
        REPO="$(ask "Git repository to deploy from, or - for none" "-")"
        ;;
    website)
        PATH_FIELD="$(ask "Folder name, relative to WEB_ROOT" "$NAME")"
        REPO="$(ask "Git repository to deploy from, or - for none" "-")"
        ;;
    proxy)
        PORT="$(ask "Which port is it already listening on" "")"
        ;;
esac

if [ "$TYPE" = "mailbox" ]; then
    print_status "A mailbox has no hostname. The address is ${NAME}@${BASE_DOMAIN}."
    ENVS_ROW="live"
else
    print_status "The hostname. Plain text means <that>.${BASE_DOMAIN}."
    print_status "Use @ for ${BASE_DOMAIN} itself, or =example.com for a different domain."
    SUB="$(ask "Hostname" "$NAME")"

    AUTH="$(ask_yes_no "Put a login in front of it" "no")"
    if [ "$AUTH" = "yes" ]; then
        print_status "Accounts come from the htpasswd file. Empty means only 'admin' can enter."
        AUTHUSERS="$(ask "Which accounts, comma separated" "-")"
    fi

    print_status "Environments available: $ENVS"
    ENVS_ROW="$(ask "Which ones, comma separated, or - for all" "-")"
fi

[ "$TYPE" != "mailbox" ] && [ "$TYPE" != "proxy" ] && \
    BRANCH="$(ask "Deploy from a specific branch, or - for the environment default" "-")"

# =============================================================================
# 4. Show it, then ask once
# =============================================================================
ROW="$(printf '%s | %s | %s | %s | %s | - | - | %s | %s | %s | %s | %s' \
    "$TYPE" "$NAME" "$PORT" "$PATH_FIELD" "$SUB" \
    "$AUTH" "$REPO" "$BRANCH" "$ENVS_ROW" "$AUTHUSERS")"

print_header "The row that will be added"
echo ""
printf "  %s\n" "$ROW"
echo ""

if [ "$TYPE" != "mailbox" ]; then
    case "$SUB" in
        @)  print_status "It will answer on: ${BASE_DOMAIN}" ;;
        =*) print_status "It will answer on: ${SUB#=}" ;;
        *)  print_status "It will answer on: ${SUB}.${BASE_DOMAIN}" ;;
    esac
else
    print_status "The address will be: ${NAME}@${BASE_DOMAIN}"
fi
echo ""

CONFIRM="$(ask_yes_no "Add it" "yes")"
if [ "$CONFIRM" != "yes" ]; then
    print_status "Nothing was written."
    exit 0
fi

if [ "$DRY_RUN" = "1" ]; then
    print_status "--dry-run, so nothing was written."
    exit 0
fi

# =============================================================================
# 5. Write it, check it, and put it back if it is wrong
#
# The old file is kept beside the new one. A config that passes validation can
# still be wrong in a way only a person notices, and the previous version being
# one copy away matters more than tidiness.
# =============================================================================
BACKUP="${SITES_CONF}.before-${NAME}"
cp "$SITES_CONF" "$BACKUP"
printf '%s\n' "$ROW" >> "$SITES_CONF"
print_success "Added the row. Previous file kept at $BACKUP"

print_header "Checking the new config"
if ! bash "$SCRIPT_DIR/maintain_services.sh" --check; then
    print_error "The new row does not validate, so it has been taken out again."
    cp "$BACKUP" "$SITES_CONF"
    print_info "The config is back to what it was. Nothing on the machine changed."
    exit 1
fi

echo ""
APPLY="$(ask_yes_no "Apply it to this machine now" "yes")"
if [ "$APPLY" != "yes" ]; then
    print_success "Row added and validated. Nothing applied."
    print_status "When ready: sudo bash $SCRIPT_DIR/maintain_services.sh --apply"
    exit 0
fi

bash "$SCRIPT_DIR/maintain_services.sh" --apply

echo ""
print_success "$NAME is configured on this machine."
print_action "It is not on GitHub yet. Commit hostings.conf, or the next Jenkins"
print_action "build reverts this machine to the version on the branch."
