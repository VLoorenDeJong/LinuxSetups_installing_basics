#!/bin/bash

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
# Single reboot authority for the basics bootstrap — only start_install.sh
# may invoke this script; nothing else triggers a reboot.

print_status() {
    printf "\e[34m🔧 %s\e[0m\n" "$1"
}

print_success() {
    printf "\e[32m✅ %s\e[0m\n" "$1"
}

print_warning() {
    printf "\e[33m⚠️ %s\e[0m\n" "$1"
}

print_error() {
    printf "\e[31m❌ %s\e[0m\n" "$1"
}

# Rebooting needs root — fail fast instead of counting down to nothing
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges to reboot."
    print_warning "Please run with: sudo $0"
    exit 1
fi

print_status "Rebooting in 10 seconds... (Ctrl+C to cancel)"
sleep 8
print_warning "Rebooting in 2 seconds — this connection will be closed"
sleep 2

print_status "Rebooting the system..."
reboot
