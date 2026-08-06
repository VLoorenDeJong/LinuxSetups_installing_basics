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

# UFW Port Management Script with Confirmation
# Usage: ./manage_ufw_ports.sh [open|close|status] [port/protocol] [description]

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

# Ensure running as root
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires root privileges. Run with sudo."
    exit 1
fi

# Check if UFW is installed
if ! command -v ufw &> /dev/null; then
    print_error "UFW is not installed!"
    exit 1
fi

# Function to open a port with confirmation
open_port() {
    local port="$1"
    local protocol="$2"
    local description="$3"

    if sudo ufw status | grep -q "$port/$protocol"; then
        print_warning "Port $port/$protocol is already open."
        return 0
    fi

    print_status "Opening port $port/$protocol ($description)..."
    read -p "🔓 Allow incoming connections to port $port/$protocol? (y/N): " -n 1 -r < /dev/tty || REPLY="n"
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if sudo ufw allow "$port/$protocol" >/dev/null 2>&1; then
            print_success "Port $port/$protocol opened successfully."
        else
            print_error "Failed to open port $port/$protocol."
            return 1
        fi
    else
        print_status "Port opening cancelled."
    fi
}

# Function to close a port with confirmation
close_port() {
    local port="$1"
    local protocol="$2"
    local description="$3"

    if ! sudo ufw status | grep -q "$port/$protocol"; then
        print_warning "Port $port/$protocol is not currently open."
        return 0
    fi

    print_warning "Closing port $port/$protocol ($description)..."
    read -p "🔒 Block incoming connections to port $port/$protocol? (y/N): " -n 1 -r < /dev/tty || REPLY="n"
    echo

    if [[ $REPLY =~ ^[Yy]$ ]]; then
        if sudo ufw delete allow "$port/$protocol" >/dev/null 2>&1; then
            print_success "Port $port/$protocol closed successfully."
        else
            print_error "Failed to close port $port/$protocol."
            return 1
        fi
    else
        print_status "Port closing cancelled."
    fi
}

# Main logic
case "$1" in
    "open")
        if [ $# -lt 3 ]; then
            print_error "Usage: $0 open <port/protocol> <description>"
            print_status "Example: $0 open 25565/tcp 'Minecraft Java Edition'"
            exit 1
        fi
        open_port "$2" "$3"
        ;;
    "close")
        if [ $# -lt 3 ]; then
            print_error "Usage: $0 close <port/protocol> <description>"
            print_status "Example: $0 close 25565/tcp 'Minecraft Java Edition'"
            exit 1
        fi
        close_port "$2" "$3"
        ;;
    "status")
        print_status "Current UFW status:"
        sudo ufw status
        ;;
    *)
        print_status "UFW Port Management Script"
        echo "Usage: $0 <command> [port/protocol] [description]"
        echo ""
        print_status "Commands:"
        echo "  open <port/protocol> <description>  - Open a port with confirmation"
        echo "  close <port/protocol> <description> - Close a port with confirmation"
        echo "  status                               - Show current UFW status"
        echo ""
        print_status "Examples:"
        echo "  $0 open 25565/tcp 'Minecraft Java Edition'"
        echo "  $0 close 19132/udp 'Minecraft Bedrock'"
        echo "  $0 status"
        ;;
esac
