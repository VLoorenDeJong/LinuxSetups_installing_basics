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
# Enable the Apache modules the server needs.
#
# the server serves almost nothing from disk: Apache is a reverse proxy in
# front of about ten ASP.NET Kestrel processes on localhost ports. Without
# proxy and proxy_http every one of those sites returns a 500 and the machine
# looks broken with no clue why, because add_apache_webserver.sh installs
# Apache and enables none of them.
#
# the server specific on purpose. add_apache_webserver.sh is shared by machines
# that only serve static files and have no business loading a proxy stack.
#
# Safe to re-run: a2enmod on an already-enabled module is a no-op.
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

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_action "Please run with: sudo $0"
    exit 1
fi

print_header "Apache modules"

if ! command -v a2enmod >/dev/null 2>&1; then
    print_error "a2enmod not found, so Apache is not installed."
    print_action "Run add_apache_webserver.sh first, then this script."
    exit 1
fi

# ssl        terminate HTTPS, which certbot's config assumes is already loaded
# headers    set forwarding and security headers on proxied responses
# rewrite    the http to https redirect certbot writes uses RewriteRule
# proxy      the proxy core, required by proxy_http
# proxy_http reverse proxy over HTTP, this is what reaches Kestrel
# proxy_html rewrite links in proxied HTML so app generated URLs stay correct
MODULES=(ssl headers rewrite proxy proxy_http proxy_html)

ENABLED=()
ALREADY=()
FAILED=()

for module in "${MODULES[@]}"; do
    if a2query -m "$module" >/dev/null 2>&1; then
        ALREADY+=("$module")
        continue
    fi

    if a2enmod "$module" >/dev/null 2>&1; then
        ENABLED+=("$module")
    else
        FAILED+=("$module")
    fi
done

if [ ${#ALREADY[@]} -gt 0 ]; then
    print_success "Already enabled: ${ALREADY[*]}"
fi

if [ ${#ENABLED[@]} -gt 0 ]; then
    print_success "Enabled: ${ENABLED[*]}"
fi

if [ ${#FAILED[@]} -gt 0 ]; then
    print_error "Could not enable: ${FAILED[*]}"
    print_action "Check that the module is packaged on this release: apt-cache search libapache2-mod"
    exit 1
fi

if [ ${#ENABLED[@]} -eq 0 ]; then
    print_success "Nothing to do, all modules were already enabled."
    exit 0
fi

# Never reload on a broken config. A reload with a bad config takes the whole
# web host down, and every other site on the box with it.
print_status "Testing Apache configuration..."

CONFIGTEST_LOG="$(mktemp)"
trap 'rm -f "$CONFIGTEST_LOG"' EXIT

if ! apache2ctl configtest >"$CONFIGTEST_LOG" 2>&1; then
    print_error "Apache configuration test failed, so Apache was NOT reloaded."
    print_info "The modules are enabled on disk but not live. Output:"
    cat "$CONFIGTEST_LOG"
    print_action "Fix the config, then run: sudo systemctl reload apache2"
    exit 1
fi

print_success "Apache configuration is valid."

if systemctl is-active --quiet apache2; then
    if systemctl reload apache2; then
        print_success "Apache reloaded, the new modules are live."
    else
        print_error "Apache reload failed. Check: systemctl status apache2"
        exit 1
    fi
else
    print_info "Apache is not running, so nothing was reloaded."
    print_action "The modules load on next start: sudo systemctl start apache2"
fi

print_success "Apache modules configured."
