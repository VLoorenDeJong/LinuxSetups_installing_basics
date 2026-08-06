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

# Function to print status messages
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

# Function to print success messages
print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

# Function to print warnings
print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

# Function to print errors
print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    echo "Please run with: sudo $0"
    exit 1
fi

print_status "Checking for rsync installation..."

if dpkg -s rsync &> /dev/null; then
    print_success "rsync is already installed."
else
    print_status "Installing rsync..."
    if sudo apt-get update -qq >/dev/null 2>&1 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null 2>&1; then
        print_success "rsync installed successfully."
    else
        print_error "Failed to install rsync."
        exit 1
    fi
fi

# pv powers the extraction progress percentage in
# minecraft_5_Worlds_restore.sh — piping the archive through it is the only way
# to get a true percentage, since a .tar.gz does not know its own uncompressed
# size. Restore still works without pv (it falls back to an indeterminate bar),
# so a failure here is a warning, not a fatal error.
print_status "Checking for pv installation..."

if dpkg -s pv &> /dev/null; then
    print_success "pv is already installed."
else
    print_status "Installing pv..."
    if sudo apt-get update -qq >/dev/null 2>&1 && sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq pv >/dev/null 2>&1; then
        print_success "pv installed successfully."
    else
        print_warning "Failed to install pv — world restores will show a progress bar without a percentage."
    fi
fi
