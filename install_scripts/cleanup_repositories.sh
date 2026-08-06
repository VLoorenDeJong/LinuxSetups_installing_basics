#!/bin/bash
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

# Repository Cleanup Script
# Removes problematic repositories and cleans apt cache

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Function to check and fix DPKG locks (calls dedicated script)
check_and_fix_dpkg_lock() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fix_script="$script_dir/fix_dpkg_lock.sh"
    if [ ! -f "$fix_script" ]; then
        # The shared basics layer (submodule) holds fix_dpkg_lock.sh
        fix_script="$script_dir/../../${BASICS_SUBMODULE:-LinuxBasics}/install_scripts/fix_dpkg_lock.sh"
    fi
    
    if [ -f "$fix_script" ]; then
        print_status "Checking for DPKG locks..."
        if bash "$fix_script"; then
            print_success "DPKG lock check completed"
        else
            print_warning "DPKG lock check failed, continuing anyway"
        fi
    else
        print_warning "DPKG lock fix script not found, continuing without lock check"
    fi
}

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
    print_warning "Please run with: sudo $0"
    exit 1
fi

print_status "Cleaning up problematic repositories..."

# Check and fix any DPKG locks before proceeding with package operations
check_and_fix_dpkg_lock

# Simple approach: remove known problematic repositories
print_status "Checking for problematic repositories..."

# Remove webmin repository if it has GPG issues
if [ -f "/etc/apt/sources.list.d/webmin.list" ]; then
    if apt-get update 2>&1 | grep -qi "gpg error.*webmin\|no valid openpgp data found.*webmin\|signatures were invalid.*webmin"; then
        print_status "Removing problematic webmin repository"
        sudo rm -f /etc/apt/sources.list.d/webmin.list
        sudo rm -f /usr/share/keyrings/webmin.gpg
        print_success "Webmin repository removed"
    fi
fi

# Check for other common problematic repositories
for repo_file in /etc/apt/sources.list.d/*.list; do
    if [ -f "$repo_file" ]; then
        repo_name=$(basename "$repo_file" .list)
        # Test if this specific repository causes issues
        if apt-get update 2>&1 | grep -qi "gpg error.*$repo_name\|no valid openpgp data found.*$repo_name\|signatures were invalid.*$repo_name"; then
            print_status "Removing problematic repository: $repo_name"
            sudo rm -f "$repo_file"
            
            # Remove associated GPG keys if they exist
            keyring_file="/usr/share/keyrings/${repo_name}.gpg"
            if [ -f "$keyring_file" ]; then
                sudo rm -f "$keyring_file"
                print_status "Removed associated keyring: $keyring_file"
            fi
            print_success "Repository $repo_name removed"
        fi
    fi
done

# Some Pi images ship ubuntu.sources without the <codename>-updates suite,
# while installed packages already come from it — that leaves apt unable to
# resolve dependencies (e.g. bzip2 vs libbz2-1.0 version mismatch)
UBUNTU_SOURCES="/etc/apt/sources.list.d/ubuntu.sources"
if [ -f "$UBUNTU_SOURCES" ]; then
    CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
    if [ -n "$CODENAME" ] && grep -q "^Suites: $CODENAME$" "$UBUNTU_SOURCES"; then
        print_status "Adding missing $CODENAME-updates suite to ubuntu.sources"
        sudo sed -i "s/^Suites: $CODENAME$/Suites: $CODENAME $CODENAME-updates/" "$UBUNTU_SOURCES"
        print_success "$CODENAME-updates suite enabled"
    fi
fi

# Clean apt cache and update
print_status "Cleaning package cache..."
sudo apt-get clean 2>/dev/null || true

print_status "Updating package lists..."
if timeout 180 sudo apt-get update -qq --fix-missing 2>/dev/null; then
    print_success "Package lists updated successfully"
else
    print_warning "Some repositories may still have issues"
    # Try one more time with verbose output for debugging
    print_status "Running verbose update to identify remaining issues..."
    timeout 180 sudo apt-get update 2>&1 | grep -E "(ERROR|WARNING|GPG error)" || print_success "No critical errors found"
fi

print_success "Repository cleanup completed!"
