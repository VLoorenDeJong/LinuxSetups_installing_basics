#!/bin/bash
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

# The countdown is redrawn every second rather than slept through: the Ctrl+C
# window is the one thing the reader has to see ticking, and a silent sleep
# before a reboot is indistinguishable from a hang.
trap 'printf "\r\033[K"; print_warning "Reboot cancelled."; exit 130' INT

for remaining in $(seq 10 -1 1); do
    if [ "$remaining" -le 3 ]; then
        printf "\r\033[K\e[33m⚠️ Rebooting in %2ds, this connection will be closed\e[0m" "$remaining"
    else
        printf "\r\033[K\e[34m🔧 Rebooting in %2ds... (Ctrl+C to cancel)\e[0m" "$remaining"
    fi
    sleep 1
done
printf "\r\033[K"

trap - INT
print_status "Rebooting the system..."
reboot
