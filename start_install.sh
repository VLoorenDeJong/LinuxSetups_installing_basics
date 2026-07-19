#!/bin/bash

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

# Check if running with sudo privileges
if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

# Get the directory where this script resides
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_scripts"

# Array of scripts to run
SCRIPTS=(
    "check_shell_syntax.sh"      # Stop early if any script has a syntax error
    "cleanup_repositories.sh"
    "fix_dpkg_lock.sh"
    "fix_xauthority.sh"
    "set_scripts_executable.sh"
    "updates_install_and_clean.sh"
    "add_ufw.sh"
    "add_ssh.sh"
)

# Ask user about reboot preference before starting.
# Read from the terminal directly so buffered/piped stdin (e.g. when run by an
# orchestrator) can't silently answer it; without a terminal default to NO
# reboot — an unattended run must never arm an access-cutting action by itself.
SHOULD_REBOOT=false
if [ -e /dev/tty ]; then
    printf "\e[34mDo you want to reboot after all scripts complete successfully? [Y/n]:\e[0m "
    if read -r REBOOT_CHOICE < /dev/tty; then
        if [[ -z "$REBOOT_CHOICE" || "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
            SHOULD_REBOOT=true
        fi
    fi
fi

# Track missing scripts
MISSING=()

# Check for existence of all scripts first
for script in "${SCRIPTS[@]}"; do
    if [[ ! -f "$INSTALL_DIR/$script" ]]; then
        MISSING+=("$script")
    fi
done

# Also validate reboot.sh since it is called directly at the end
if [[ ! -f "$INSTALL_DIR/reboot.sh" ]]; then
    MISSING+=("reboot.sh")
fi

# If any scripts are missing, display and exit
if (( ${#MISSING[@]} > 0 )); then
    echo -e "\e[31m🚫 The following script(s) are missing:\e[0m"
    for script in "${MISSING[@]}"; do
        echo -e "\e[31m - $script\e[0m"
    done
    exit 1
fi

# Run the scripts
ALL_SUCCESS=true
FAILED_SCRIPTS=()

for script in "${SCRIPTS[@]}"; do
    echo -e "\e[34m🚀 Running: $script\e[0m"
    if bash "$INSTALL_DIR/$script"; then
        echo -e "\e[32m✅ Finished: $script\e[0m"
    else
        echo -e "\e[31m❌ Failed: $script\e[0m"
        ALL_SUCCESS=false
        FAILED_SCRIPTS+=("$script")
    fi
    echo "" # Add spacing between scripts
done

# Check if reboot is needed and requested — reboot.sh owns its own countdown
if $ALL_SUCCESS && $SHOULD_REBOOT; then
    echo -e "\e[32m🎉 All scripts completed successfully!\e[0m"
    bash "$INSTALL_DIR/reboot.sh"
elif $ALL_SUCCESS; then
    echo -e "\e[32m🎉 All scripts completed successfully! No reboot requested.\e[0m"
else
    echo -e "\e[31m⚠️  Some scripts failed. Skipping reboot.\e[0m"
    echo -e "\e[31m💥 Failed scripts:\e[0m"
    for failed_script in "${FAILED_SCRIPTS[@]}"; do
        echo -e "\e[31m - $failed_script\e[0m"
    done
    exit 1
fi