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

# Suppress confirmation prompts
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
    echo -e "\e[33mPlease run with: sudo $0\e[0m"
    exit 1
fi

# Check if UFW is installed, else exit
if ! command -v ufw &> /dev/null; then
    echo -e "\e[31mError: UFW is not installed! Exiting...\e[0m"
    exit 1
fi

# Allow SSH BEFORE enabling the firewall — this ordering is what keeps a
# remote session alive when ufw comes up. Never reorder these two steps.
# (Assumes SSH on port 22; a non-standard port would need its own allow rule.)
# From the LAN and from whoever is connected right now, never from everyone:
# an Anywhere rule made here outlived add_ssh.sh's LAN-only rule (2026-10-04).
ssh_sources() {
    if [ -n "${SSH_ALLOW_FROM:-}" ]; then
        printf '%s\n' $SSH_ALLOW_FROM
        return 0
    fi
    { ip -o -4 route show; ip -o -6 route show; } 2>/dev/null \
        | awk '$1 == "default" || / via / || $1 !~ /\// { next }
               { d = ""; for (i = 1; i < NF; i++) if ($i == "dev") d = $(i + 1) }
               d !~ /^(lo|docker|br-|veth|wg)/ { print $1 }' \
        | sort -u
}
mapfile -t SSH_FROM < <(ssh_sources)
if [ ${#SSH_FROM[@]} -eq 0 ]; then
    echo -e "\e[33m⚠️ No local subnet found, so SSH is allowed from anywhere. add_ssh.sh narrows it.\e[0m"
    sudo ufw allow ssh > /dev/null
else
    mapfile -t SSH_PEERS < <(ss -tnH state established '( sport = :22 )' 2>/dev/null \
        | awk '{ p = $NF; sub(/:[0-9]+$/, "", p); gsub(/[][]/, "", p); sub(/^::ffff:/, "", p); print p }' | sort -u)
    for src in "${SSH_FROM[@]}" "${SSH_PEERS[@]}"; do
        sudo ufw allow from "$src" to any port 22 proto tcp > /dev/null
    done
    echo -e "\e[34m🔧 SSH allowed from: ${SSH_FROM[*]} ${SSH_PEERS[*]}\e[0m"
fi

# Enable UFW without requiring user confirmation
echo "y" | sudo ufw enable > /dev/null

# Verify UFW status
if sudo ufw status | grep -q "Status: active"; then
    echo -e "\e[32m✅ UFW setup completed!\e[0m"
else
    echo -e "\e[31mError: UFW failed to start!\e[0m"
    sudo systemctl restart ufw

    # Re-check status after restart
    if sudo ufw status | grep -q "Status: active"; then
        echo -e "\e[32m✅ UFW started successfully after restart!\e[0m"
    else
        echo -e "\e[31mCritical error: UFW is still not running. Please check manually.\e[0m"
        exit 1
    fi
fi
