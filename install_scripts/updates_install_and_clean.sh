#!/bin/bash

# Suppress confirmation prompts for apt
export DEBIAN_FRONTEND=noninteractive

# Enable or disable confirmation prompts (true = ask, false = skip)
ASK_CONFIRMATION=false

# Function to prompt the user if confirmation is enabled
ask_user() {
    if [[ "$ASK_CONFIRMATION" == true ]]; then
        read -r -p "$1 (Y/n): " choice
        choice=${choice:-Y}  # Default to "Y" if no input is given
        [[ "$choice" =~ ^[Yy]$ ]]
    else
        return 0  # Automatically proceed without asking
    fi
}

# Ask for system update confirmation
if ask_user "Do you want to update and upgrade the system?"; then
    echo -e "\e[33mUpdating package list and upgrading system...\e[0m"
    sudo apt update && sudo apt upgrade -y && echo -e "\e[32m✅ System update & upgrade completed!\e[0m"

    # Ask for cleanup confirmation
    if ask_user "Do you want to clean up unused packages?"; then
        echo -e "\e[33mCleaning up unused packages...\e[0m"

        # Remove unused packages
        sudo apt autoremove -y

        # Purge leftover configuration files, only if any exist
        if [[ $(dpkg -l | awk '/^rc/ { print $2 }') ]]; then
            sudo apt purge -y $(dpkg -l | awk '/^rc/ { print $2 }')
        fi

        # Clean up cached packages
        sudo apt autoclean -y
        sudo apt clean -y

        echo -e "\e[32m✅ System cleanup completed!\e[0m"
    else
        echo -e "\e[31m❌ Skipping cleanup.\e[0m"
    fi
else
    echo -e "\e[31m❌ Skipping update and cleanup.\e[0m"
fi
