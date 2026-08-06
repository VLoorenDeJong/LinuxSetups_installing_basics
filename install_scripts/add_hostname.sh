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

# Sets the machine's hostname and makes it survive a reboot.
#
# On a cloud-init image (which is what the Raspberry Pi Ubuntu images are),
# hostnamectl alone is not enough: cloud-init rewrites the hostname on every
# boot, so the new name silently reverts. Setting preserve_hostname first is
# what makes the change stick.
#
# Usage, from an install array:  "add_hostname.sh:night-hawk"
# Run by hand:                   sudo ./add_hostname.sh night-hawk
# With no argument it asks.

export DEBIAN_FRONTEND=noninteractive

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

if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31mThis script requires sudo privileges to run properly.\e[0m"
    echo -e "\e[33mPlease run with: sudo $0 <hostname>\e[0m"
    exit 1
fi

CLOUD_CFG="/etc/cloud/cloud.cfg"
CURRENT_HOSTNAME="$(hostname)"

NEW_HOSTNAME="$1"

# Read the prompt from the terminal, not stdin: this script may be launched by
# an installer that has already redirected its own stdin, and buffered input
# from an earlier step would otherwise answer this silently.
if [ -z "$NEW_HOSTNAME" ]; then
    print_status "Current hostname: $CURRENT_HOSTNAME"
    if [ -e /dev/tty ]; then
        printf "\e[34m🔧 New hostname (Enter to keep the current one): \e[0m"
        read -r NEW_HOSTNAME < /dev/tty
    fi
fi

if [ -z "$NEW_HOSTNAME" ] || [ "$NEW_HOSTNAME" = "$CURRENT_HOSTNAME" ]; then
    print_success "Hostname unchanged: $CURRENT_HOSTNAME"
    NEW_HOSTNAME="$CURRENT_HOSTNAME"
else
    # A hostname is letters, digits and hyphens only. Underscores are the
    # common mistake: they are illegal in a hostname and break name lookups
    # in ways that are hard to trace back to this.
    if ! printf '%s' "$NEW_HOSTNAME" | grep -qE '^[a-zA-Z0-9]([a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$'; then
        print_error "Not a valid hostname: $NEW_HOSTNAME"
        print_error "Use letters, digits and hyphens only. No underscores, no leading or trailing hyphen, 63 characters maximum."
        exit 1
    fi

    print_status "Setting hostname to $NEW_HOSTNAME..."
    if ! hostnamectl set-hostname "$NEW_HOSTNAME"; then
        print_error "hostnamectl failed to set the hostname"
        exit 1
    fi
    print_success "Hostname set to $NEW_HOSTNAME"
fi

# --- Keep cloud-init from putting the old name back on the next boot ---------
if [ -f "$CLOUD_CFG" ]; then
    if grep -qE '^\s*preserve_hostname:\s*true' "$CLOUD_CFG"; then
        print_success "cloud-init already preserves the hostname"
    elif grep -qE '^\s*preserve_hostname:' "$CLOUD_CFG"; then
        sed -i -E 's/^\s*preserve_hostname:.*/preserve_hostname: true/' "$CLOUD_CFG"
        print_success "cloud-init preserve_hostname switched to true"
    else
        echo "preserve_hostname: true" >> "$CLOUD_CFG"
        print_success "cloud-init preserve_hostname added"
    fi
else
    print_status "No cloud-init config here, nothing to preserve"
fi

# --- Keep /etc/hosts in step ------------------------------------------------
# Without a matching 127.0.1.1 entry, sudo and other tools stall on a failed
# lookup of the machine's own name.
if grep -qE '^127\.0\.1\.1' /etc/hosts; then
    sed -i -E "s/^127\.0\.1\.1.*/127.0.1.1\t$NEW_HOSTNAME/" /etc/hosts
    print_success "/etc/hosts updated for $NEW_HOSTNAME"
elif ! grep -qE "[[:space:]]$NEW_HOSTNAME(\$|[[:space:]])" /etc/hosts; then
    printf '127.0.1.1\t%s\n' "$NEW_HOSTNAME" >> /etc/hosts
    print_success "/etc/hosts entry added for $NEW_HOSTNAME"
fi

echo -e "\e[34m📛 Hostname: \e[0m$(hostname)"
print_warning "The shell prompt shows the new name after the next login or reboot"
