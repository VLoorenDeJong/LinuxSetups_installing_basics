#!/bin/bash

# Get the directory where this script resides
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Array of scripts to run
SCRIPTS=(
    "set_scripts_executable.sh"
    "updates_install_and_clean.sh"
    "add_bash_show_branch_name.sh"
    "add_backup_config.sh"
    "add_ufw.sh"
    "add_ssh.sh"
    "add_apache_webserver.sh"
    "add_smb.sh"
)

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
for script in "${SCRIPTS[@]}"; do
    bash "$INSTALL_DIR/$script"
    echo -e "\