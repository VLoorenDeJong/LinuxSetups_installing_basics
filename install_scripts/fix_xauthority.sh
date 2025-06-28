#!/bin/bash

echo -e "\e[34m🔍 Checking for Xauthority file issues...\e[0m"

# Function to check if Xauthority issue exists
check_xauth_issue() {
    # Check if xauth command fails due to missing .Xauthority file
    if command -v xauth >/dev/null 2>&1; then
        if xauth list >/dev/null 2>&1; then
            return 1  # No issue
        else
            # Check if the error is specifically about missing .Xauthority file
            local error_output=$(xauth list 2>&1)
            if echo "$error_output" | grep -q "does not exist"; then
                return 0  # Issue exists
            else
                return 1  # Different issue or no issue
            fi
        fi
    else
        echo -e "\e[33m⚠️  xauth command not found. Skipping Xauthority check.\e[0m"
        return 1  # No xauth, so no issue to fix
    fi
}

# Test for Xauthority issue
if ! check_xauth_issue; then
    echo -e "\e[32m✅ No Xauthority file issues detected.\e[0m"
    exit 0
else
    echo -e "\e[33m⚠️  Xauthority file issue detected. Attempting to fix...\e[0m"
fi

# Get the current user information
CURRENT_USER="$(whoami)"
USER_HOME="$HOME"

# Fallback if HOME is not set
if [ -z "$USER_HOME" ]; then
    USER_HOME="/home/$CURRENT_USER"
fi

# If running as root, try to detect the actual user
if [ "$CURRENT_USER" = "root" ] && [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    USER_HOME="/home/$ACTUAL_USER"
    echo -e "\e[33m👤 Running as root, detected actual user: $ACTUAL_USER\e[0m"
else
    ACTUAL_USER="$CURRENT_USER"
fi

XAUTH_FILE="$USER_HOME/.Xauthority"

echo -e "\e[34m🔄 Step 1: Checking Xauthority file location...\e[0m"
echo -e "\e[33m� User: $ACTUAL_USER\e[0m"
echo -e "\e[33m🏠 Home directory: $USER_HOME\e[0m"
echo -e "\e[33m📁 Xauthority file: $XAUTH_FILE\e[0m"

# Step 1: Remove corrupted or problematic Xauthority file if it exists but is corrupted
if [ -f "$XAUTH_FILE" ]; then
    echo -e "\e[33m🗃️  Xauthority file exists but may be corrupted. Backing up and removing...\e[0m"
    
    # Create backup with timestamp
    BACKUP_FILE="${XAUTH_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
    
    if cp "$XAUTH_FILE" "$BACKUP_FILE" 2>/dev/null; then
        echo -e "\e[32m✅ Backup created successfully:\e[0m"
        echo -e "\e[36m   📁 $BACKUP_FILE\e[0m"
        
        # Create a log file for the user to reference later
        LOG_FILE="$USER_HOME/.xauthority_fix.log"
        {
            echo "=============================================="
            echo "Xauthority Fix Log - $(date)"
            echo "=============================================="
            echo "User: $ACTUAL_USER"
            echo "Original file: $XAUTH_FILE"
            echo "Backup created: $BACKUP_FILE"
            echo "Fix applied: $(date)"
            echo ""
            echo "To restore backup if needed:"
            echo "cp '$BACKUP_FILE' '$XAUTH_FILE'"
            echo "=============================================="
            echo ""
        } >> "$LOG_FILE"
        
        echo -e "\e[32m📝 Log saved to: $LOG_FILE\e[0m"
    else
        echo -e "\e[31m❌ Failed to create backup, but continuing with fix...\e[0m"
    fi
    
    rm -f "$XAUTH_FILE"
else
    echo -e "\e[33m❌ Xauthority file does not exist at $XAUTH_FILE\e[0m"
fi

# Step 2: Create new Xauthority file
echo -e "\e[34m🔄 Step 2: Creating new Xauthority file...\e[0m"

# Create the file with proper permissions
touch "$XAUTH_FILE"
chmod 600 "$XAUTH_FILE"

# Ensure correct ownership
if [ "$CURRENT_USER" = "root" ] && [ -n "$ACTUAL_USER" ]; then
    # Running as root, set ownership to actual user
    chown "$ACTUAL_USER:$(id -gn "$ACTUAL_USER" 2>/dev/null || echo "$ACTUAL_USER")" "$XAUTH_FILE" 2>/dev/null || true
    echo -e "\e[32m✅ Set ownership to $ACTUAL_USER\e[0m"
else
    # Running as normal user, ensure correct ownership
    if [ "$(stat -c %U "$XAUTH_FILE" 2>/dev/null)" != "$ACTUAL_USER" ]; then
        chown "$ACTUAL_USER:$(id -gn "$ACTUAL_USER" 2>/dev/null || id -gn)" "$XAUTH_FILE" 2>/dev/null || true
    fi
fi

echo -e "\e[32m✅ Created new Xauthority file: $XAUTH_FILE\e[0m"

# Update log file with completion status
if [ -f "$USER_HOME/.xauthority_fix.log" ]; then
    {
        echo "Fix completed: $(date)"
        echo "New file created: $XAUTH_FILE"
        echo "File permissions: 600 (read/write for owner only)"
        echo "File owner: $ACTUAL_USER"
        echo ""
    } >> "$USER_HOME/.xauthority_fix.log"
fi

# Step 3: Set up basic X11 authorization if DISPLAY is set
if [ -n "$DISPLAY" ]; then
    echo -e "\e[34m🔄 Step 3: Setting up X11 authorization for DISPLAY=$DISPLAY...\e[0m"
    
    # Try to add current display
    if xauth add "$DISPLAY" . "$(mcookie)" 2>/dev/null; then
        echo -e "\e[32m✅ Added X11 authorization for current display.\e[0m"
    else
        echo -e "\e[33m⚠️  Could not add X11 authorization automatically.\e[0m"
    fi
else
    echo -e "\e[33m⚠️  DISPLAY not set. Skipping X11 authorization setup.\e[0m"
fi

# Step 4: Test if fix worked
echo -e "\e[34m🔄 Step 4: Testing if fix worked...\e[0m"
if xauth list >/dev/null 2>&1; then
    echo -e "\e[32m🎉 Success! Xauthority file issue has been resolved.\e[0m"
    echo -e "\e[32m✅ X11 applications should now work properly.\e[0m"
else
    # Check what the error is now
    local error_output=$(xauth list 2>&1)
    if echo "$error_output" | grep -q "does not exist"; then
        echo -e "\e[31m❌ Xauthority file issue persists.\e[0m"
        exit 1
    else
        echo -e "\e[32m✅ Xauthority file created successfully.\e[0m"
        echo -e "\e[33m💡 Note: X11 authorization may need to be set up when you start a graphical session.\e[0m"
    fi
fi

echo -e "\e[34m💡 Additional notes:\e[0m"
echo -e "\e[33m   - User: $ACTUAL_USER\e[0m"
echo -e "\e[33m   - If you're using SSH X11 forwarding, reconnect your SSH session\e[0m"
echo -e "\e[33m   - For graphical applications, you may need to restart your desktop session\e[0m"
echo -e "\e[33m   - File location: $XAUTH_FILE\e[0m"

# Show log file location for future reference
if [ -f "$USER_HOME/.xauthority_fix.log" ]; then
    echo -e "\e[32m📋 For future reference, backup and fix details saved to:\e[0m"
    echo -e "\e[36m   📁 $USER_HOME/.xauthority_fix.log\e[0m"
    echo -e "\e[33m   - View with: cat ~/.xauthority_fix.log\e[0m"
    echo -e "\e[33m   - This log persists after reboot\e[0m"
fi
