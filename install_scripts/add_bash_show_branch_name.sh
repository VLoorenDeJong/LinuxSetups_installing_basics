#!/usr/bin/env bash
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ "$EUID" -ne 0 ]; then
    echo -e "\e[31m❌ This script requires sudo privileges to run properly.\e[0m"
    echo -e "\e[33m⚠️  Please run with: sudo $0\e[0m"
    exit 1
fi

# Get the actual user who called sudo (not root)
if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

echo -e "\e[34m🔧 Setting up Git branch display for user: $ACTUAL_USER\e[0m"
echo -e "\e[34mℹ️  User home directory: $ACTUAL_HOME\e[0m"

# Resolved from this script's own location rather than a hardcoded checkout path
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

# Function: Get Git branch
get_git_branch() {
    local branch
    if branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
        echo "$branch"
    else
        echo ""
    fi
}

# Function: Get OS ID and Version separately
get_os_info() {
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "$ID $VERSION_ID"
    else
        echo "unknown unknown"
    fi
}


# --- Prompt logic to be appended to ~/.bashrc ---
PROMPT_BRANCH_FUNC='get_git_branch() {
    local branch
    if branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null); then
        echo "$branch"
    else
        echo ""
    fi
}
update_prompt() {
    local branch=$(get_git_branch)
    if [[ -n "$branch" ]]; then
        branch_display="\[\e[35m\]${branch}\[\e[0m\] → "
    else
        branch_display=""
    fi
    PS1="\[\e[1;32m\]\u\[\e[0m\]:${branch_display}\[\e[1;34m\]\W\[\e[0m\] \$ "
}
export PROMPT_COMMAND=update_prompt
if [[ -n "$PS1" ]]; then update_prompt; fi'

# Idempotently add to user's ~/.bashrc
USER_BASHRC="$ACTUAL_HOME/.bashrc"

# Enhanced detection - check for multiple indicators
HAS_GIT_PROMPT=false

if [ -f "$USER_BASHRC" ]; then
    # Check for any of our git prompt indicators
    if grep -q "PROMPT_COMMAND=update_prompt" "$USER_BASHRC" 2>/dev/null || \
       grep -q "Git branch in prompt" "$USER_BASHRC" 2>/dev/null || \
       grep -q "get_git_branch()" "$USER_BASHRC" 2>/dev/null; then
        HAS_GIT_PROMPT=true
    fi
fi 

if [ "$HAS_GIT_PROMPT" = false ]; then
    echo -e "\e[34m📁 Adding Git branch prompt to $USER_BASHRC\e[0m"
    echo "# --- Git branch in prompt ---" >> "$USER_BASHRC"
    echo "$PROMPT_BRANCH_FUNC" >> "$USER_BASHRC"
    
    # Set proper ownership for the bashrc file
    chown "$ACTUAL_USER:$(id -gn "$ACTUAL_USER")" "$USER_BASHRC" 2>/dev/null || true
    
    echo -e "\e[32m✅ Git branch prompt added to user's bashrc.\e[0m"
else
    echo -e "\e[33m⚠️ Git branch prompt already exists in user's bashrc.\e[0m"
    
    # Check if the existing prompt has the display issue and fix it
    if grep -q "PS1=.*\[\\\e\[1;32m\].*\[\\\e\[0m\].*\[\\\e\[1;34m\].*\[\\\e\[0m\].*branch_display.*\[\\\e\[0m\]" "$USER_BASHRC" 2>/dev/null; then
        echo -e "\e[33m🔧 Detected broken prompt formatting, fixing...\e[0m"
        
        # Create a backup
        cp "$USER_BASHRC" "$USER_BASHRC.backup.$(date +%Y%m%d_%H%M%S)"
        
        # Remove the old broken prompt section
        sed -i '/# --- Git branch in prompt ---/,/^if \[\[ -n "\$PS1" \]\]; then update_prompt; fi$/d' "$USER_BASHRC"
        
        # Add the fixed version
        echo "# --- Git branch in prompt ---" >> "$USER_BASHRC"
        echo "$PROMPT_BRANCH_FUNC" >> "$USER_BASHRC"
        
        # Set proper ownership
        chown "$ACTUAL_USER:$(id -gn "$ACTUAL_USER")" "$USER_BASHRC" 2>/dev/null || true
        
        echo -e "\e[32m✅ Fixed broken Git branch prompt formatting.\e[0m"
    else
        echo -e "\e[32m✅ No changes needed - Git branch prompt is already configured.\e[0m"
    fi
fi

# Test if we can source the bashrc (only if running interactively as the actual user and changes were made)
if [[ -n "$PS1" ]] && [[ "$(whoami)" == "$ACTUAL_USER" ]] && [ "$HAS_GIT_PROMPT" = false ]; then
    echo -e "\e[34m🔄 Sourcing bashrc for current session...\e[0m"
    source "$USER_BASHRC"
fi

if [ "$HAS_GIT_PROMPT" = false ]; then
    echo -e "\e[32m✅ Bash prompt will now show Git branch in new terminals for user: $ACTUAL_USER\e[0m"
    echo -e "\e[33m💡 Open a new terminal or run 'source ~/.bashrc' to see the changes\e[0m"
    echo -e "\e[33m💡 Navigate to a Git repository folder to see the branch name in the prompt\e[0m"
else
    echo -e "\e[32m✅ Git branch prompt is already configured for user: $ACTUAL_USER\e[0m"
    echo -e "\e[33m💡 If you had display issues, they should now be fixed\e[0m"
    echo -e "\e[33m💡 Run 'source ~/.bashrc' or open a new terminal to apply any fixes\e[0m"
    echo -e "\e[33m💡 Navigate to a Git repository folder to see the branch name in the prompt\e[0m"
fi