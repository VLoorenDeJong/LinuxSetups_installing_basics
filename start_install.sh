#!/bin/bash

# Get the directory where this script resides
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install_scripts"

# Array of scripts to run
SCRIPTS=(
    "set_scripts_executable.sh"
    "updates_install_and_clean.sh"
    "add_ufw.sh"
    "add_ssh.sh"
)

# Ask user about reboot preference before starting
echo -e "\e[34mDo you want to reboot after all scripts complete successfully? [Y/n]:\e[0m"
read -r REBOOT_CHOICE
# Default to Y if empty input or Y/y, otherwise no reboot
if [[ -z "$REBOOT_CHOICE" || "$REBOOT_CHOICE" =~ ^[Yy]$ ]]; then
    SHOULD_REBOOT=true
else
    SHOULD_REBOOT=false
fi

# Track missing scripts
MISSING=()

# Check for existence of all scripts first
for script in "${SCRIPTS[@]}"; do
    if [[ ! -f "$INSTALL_DIR/$script" ]]; then
        MISSING+=("$script")
    fi
done

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
for script in "${SCRIPTS[@]}"; do
    if bash "$INSTALL_DIR/$script"; then
        echo -e "\e[32m✅ Finished: $script\e[0m"
    else
        echo -e "\e[31m❌ Failed: $script\e[0m"
        ALL_SUCCESS=false
    fi
done

# Check if reboot is needed and requested
if $ALL_SUCCESS && $SHOULD_REBOOT; then
    echo -e "\e[32m🎉 All scripts completed successfully!\e[0m"
    echo -e "\e[34mRebooting in 5 seconds... (Press Ctrl+C to cancel)\e[0m"
    sleep 5
    bash "$INSTALL_DIR/reboot.sh"
elif $ALL_SUCCESS; then
    echo -e "\e[32m🎉 All scripts completed successfully! No reboot requested.\e[0m"
else
    echo -e "\e[31m⚠️  Some scripts failed. Skipping reboot.\e[0m"
    exit 1
fi