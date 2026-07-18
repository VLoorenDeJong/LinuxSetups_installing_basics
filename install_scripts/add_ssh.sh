#!/bin/bash
set -e

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

# Watch-only progress for irreversible package transactions: reports elapsed
# time but never kills the command — a SIGKILL mid-dpkg can corrupt package state
show_progress_watch_only() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)
    while kill -0 "$cmd_pid" 2>/dev/null; do
        echo -n "."
        sleep 3
    done
    echo
    wait "$cmd_pid"
    return $?
}

if ! dpkg -s openssh-server &> /dev/null; then
    print_status "Installing OpenSSH server..."
    # Package-list update is kill-safe/retryable — timeout is fine here
    timeout 180 apt-get update -qq --fix-missing
    # The install is an irreversible dpkg transaction — never run it under a kill timeout
    if ! show_progress_watch_only "📦 Installing openssh-server" \
        env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends openssh-server; then
        print_error "Failed to install openssh-server"
        exit 1
    fi
fi

if ! systemctl is-active --quiet ssh; then
    sudo systemctl enable ssh >/dev/null 2>&1
    sudo systemctl start ssh >/dev/null 2>&1
fi

if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    # Anchor on "22/tcp" so ports like 220 or 2222 don't false-match
    if ! sudo ufw status numbered | grep -E "ALLOW" | grep -qE "\b22/tcp\b|\b22\b(/| |$)"; then
        echo "y" | sudo ufw allow 22/tcp > /dev/null
    fi
fi

echo -e "\e[32m✅ SSH installation and configuration complete\e[0m"
