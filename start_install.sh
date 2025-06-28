#!/bin/bash

# Get the directory where this script resides
INSTALL_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Array of scripts to run
SCRIPTS=(
    "set_scripts_executable.sh"
    "updates_install_and_clean.sh"
    "add_bash_show_branch_name.sh"
    "add_ufw.sh"
    "add_ssh.sh"
)

# Loop through each script and execute if it exists
for script in "${SCRIPTS[@]}"; do
    if [[ -f "$INSTALL_DIR/$script" ]]; then
        bash "$INSTALL_DIR/$script"
        echo -e "\e[32m✅ Successfully executed: $script\e[0m"
    else
        echo -e "\e[31m❌ Error: $script not found!\e[0m"
    fi
done
