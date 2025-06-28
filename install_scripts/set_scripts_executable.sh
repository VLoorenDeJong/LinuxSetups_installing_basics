#!/bin/bash

# Define the directory
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Ensure the directory exists before applying permissions
if [[ -d "$REPO_DIR" ]]; then
    sudo chmod -R +x "$REPO_DIR"

    # Check if chmod was successful
    if [[ $? -eq 0 ]]; then
        echo -e "\e[32m✅ All scripts in $REPO_DIR are now executable!\e[0m"
    else
        echo -e "\e[31m❌ Failed to set executable permissions for $REPO_DIR!\e[0m"
    fi
else
    echo -e "\e[31m❌ Error: $REPO_DIR not found!\e[0m"
fi
