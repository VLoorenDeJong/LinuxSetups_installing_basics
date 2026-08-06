#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

# No backup_config/smb/smb.conf is created here on purpose. When it is absent
# the script leaves the samba package's own /etc/samba/smb.conf in place (see
# the else branch of the config block below). Creating an empty one instead
# would symlink /etc/samba/smb.conf to a config with zero shares.

# Function to show progress with dots
show_progress() {
    local message="$1"
    local command="$2"
    local interval="${3:-3}"  # Default 3 seconds between dots
    local timeout="${4:-300}"  # Default 5 minute timeout

    echo -e "\e[34m${message}\e[0m"

    # Start the command in background
    eval "$command" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)

    # Show progress dots while command runs
    while kill -0 $cmd_pid 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep $interval || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
        local current_time
        current_time=$(date +%s)
        if (( current_time - start_time > timeout )); then
            printf "\n\e[31m❌ Command timed out after %d seconds\e[0m\n" "$timeout"
            kill -TERM $cmd_pid 2>/dev/null || true
            sleep 2
            kill -KILL $cmd_pid 2>/dev/null || true
            return 1
        fi
    done

    # Wait for command to complete and get exit code
    wait $cmd_pid
    local exit_code=$?

    echo  # New line after dots
    return $exit_code
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

print_status "Setting up Samba..."

# Function to wait for or fix dpkg lock issues
wait_for_dpkg_unlock() {
    local max_wait=600
    local check_interval=5
    local waited=0
    local lock_files=(
        "/var/lib/dpkg/lock-frontend"
        "/var/lib/dpkg/lock"
        "/var/lib/apt/lists/lock"
        "/var/cache/apt/archives/lock"
    )

    test_dpkg_available() {
        ! sudo lsof "${lock_files[@]}" >/dev/null 2>&1
    }

    get_lock_process() {
        for lock in "${lock_files[@]}"; do
            if [ -f "$lock" ]; then
                local pid=$(sudo fuser "$lock" 2>/dev/null)
                if [ -n "$pid" ]; then
                    echo "$pid"
                    return 0
                fi
            fi
        done
        return 1
    }

    if ! test_dpkg_available; then
        local lock_pid
        lock_pid=$(get_lock_process)
        if [ -n "$lock_pid" ]; then
            local process_name
            process_name=$(ps -p "$lock_pid" -o comm= 2>/dev/null)
            echo -e "\e[34m🔄 Package system is locked by $process_name (PID: $lock_pid)\e[0m"
        fi
    else
        return 0
    fi

    while [ $waited -lt $max_wait ]; do
        if ! test_dpkg_available; then
            sleep $check_interval
            waited=$((waited + check_interval))
            if [ $((waited % 30)) -eq 0 ]; then
                echo -e "\e[34m⏳ Still waiting for package system... (${waited}s/${max_wait}s)\e[0m"
            fi
            continue
        fi

        sleep 2
        return 0
    done

    echo -e "\e[33m⚠️ Timeout waiting for package system, attempting to fix...\e[0m"
    echo "🛠️ Attempting to resolve dpkg lock using fix_dpkg_lock.sh..."

    local script_dir
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fix_script="$script_dir/fix_dpkg_lock.sh"
    if [ ! -f "$fix_script" ]; then
        # The shared basics layer (submodule) holds fix_dpkg_lock.sh
        fix_script="$script_dir/../../${BASICS_SUBMODULE:-LinuxBasics}/install_scripts/fix_dpkg_lock.sh"
    fi

    # fix_dpkg_lock.sh waits for any lock holder to exit on its own and never
    # force-kills a live dpkg/apt process — do the same here, no pkill -9 fallback.
    if [ -f "$fix_script" ]; then
        if bash "$fix_script"; then
            print_success "dpkg lock resolved successfully"
            return 0
        else
            print_error "Failed to resolve dpkg lock"
            return 1
        fi
    else
        print_warning "fix_dpkg_lock.sh not found at $fix_script."
        print_error "Cannot safely resolve dpkg lock without force-killing a live process — aborting"
        return 1
    fi
}

# Ensure dpkg is available
if ! wait_for_dpkg_unlock; then
    print_error "Cannot proceed: dpkg lock could not be resolved"
    exit 1
fi

# Install required packages
if ! dpkg -s samba &> /dev/null; then
    print_status "Installing Samba packages..."
    if show_progress "📦 Updating package lists" "sudo apt-get update -qq >/dev/null 2>&1"; then
        if show_progress "📁 Installing Samba server packages" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq samba samba-common-bin >/dev/null 2>&1"; then
            print_success "Samba packages installed successfully"
            sleep 2 # Short delay to ensure services are ready
        else
            print_error "Failed to install Samba packages"
            exit 1
        fi
    else
        print_error "Failed to update package lists"
        exit 1
    fi
fi

if ! dpkg -s smbclient &> /dev/null; then
    print_status "Installing Samba client..."
    if ! wait_for_dpkg_unlock; then
        print_error "Cannot install smbclient: dpkg lock could not be resolved"
        exit 1
    fi
    if show_progress "📱 Installing Samba client tools" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq smbclient >/dev/null 2>&1"; then
        print_success "Samba client installed successfully"
    else
        print_error "Failed to install Samba client"
        exit 1
    fi
fi

# Configure services
print_status "Configuring Samba services..."
if ! systemctl is-active --quiet smbd; then
    if show_progress "🚀 Starting and enabling Samba services" "sudo systemctl enable smbd nmbd >/dev/null 2>&1 && sudo systemctl start smbd nmbd >/dev/null 2>&1"; then
        if systemctl is-active --quiet smbd && systemctl is-active --quiet nmbd; then
            print_success "Samba services started and enabled"
        else
            print_error "Failed to start Samba services"
            exit 1
        fi
    else
        print_error "Failed to enable/start Samba services"
        exit 1
    fi
fi

# Configure firewall
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    print_status "Configuring firewall rules..."
    if ! sudo ufw status numbered | grep -qE "^.*ALLOW.*(Samba|445|139)"; then
        if sudo ufw allow 'Samba' > /dev/null 2>&1; then
            print_success "Firewall rules added for Samba"
        else
            print_error "Failed to configure firewall rules"
        fi
    fi
fi

# Comprehensive Samba share configuration parser and validator
parse_samba_config() {
    local config_file="$1"
    local current_share=""
    local in_share_section=false
    local share_config=()
    local all_shares=()

    while IFS= read -r line || [ -n "$line" ]; do
        # Remove leading/trailing whitespace
        line=$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')

        # Skip empty lines and comments
        [[ -z "$line" || "$line" =~ ^[[:space:]]*[\;#] ]] && continue

        # Check for share section start
        if [[ "$line" =~ ^\[(.+)\]$ ]]; then
            # Save previous share if exists
            if [ -n "$current_share" ] && [ ${#share_config[@]} -gt 0 ]; then
                all_shares+=("$current_share:$(printf '%s|' "${share_config[@]}")")
            fi

            current_share="${BASH_REMATCH[1]}"
            share_config=()
            in_share_section=true

            # Skip global section
            [[ "$current_share" == "global" ]] && {
                current_share=""
                in_share_section=false
                continue
            }

        elif [ "$in_share_section" = true ]; then
            # Parse configuration lines within share section
            if [[ "$line" =~ ^([^=]+)[[:space:]]*=[[:space:]]*(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                # Clean up the key and value
                key=$(echo "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')
                value=$(echo "$value" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;s/^"//;s/"$//')

                share_config+=("$key=$value")
            fi
        fi
    done < "$config_file"

    # Save the last share
    if [ -n "$current_share" ] && [ ${#share_config[@]} -gt 0 ]; then
        all_shares+=("$current_share:$(printf '%s|' "${share_config[@]}")")
    fi

    # Return all shares
    printf '%s\n' "${all_shares[@]}"
}

# Function to extract share paths from Samba config
extract_share_paths() {
    local config_file="$1"
    local shares_data

    # Parse the configuration
    mapfile -t shares_data < <(parse_samba_config "$config_file")

    for share_data in "${shares_data[@]}"; do
        # Parse share name and configuration
        local share_name="${share_data%%:*}"
        local config_string="${share_data#*:}"
        local share_path=""

        # Parse configuration parameters
        IFS='|' read -ra config_items <<< "$config_string"
        for item in "${config_items[@]}"; do
            if [[ "$item" =~ ^([^=]+)=(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                if [[ "$key" == "path" ]]; then
                    share_path="$value"
                    break
                fi
            fi
        done

        # Output the path if found
        if [ -n "$share_path" ]; then
            printf '%s\n' "$share_path"
        fi
    done
}

# Function to extract share info (name:path) from Samba config
extract_share_info() {
    local config_file="$1"
    local shares_data

    # Parse the configuration
    mapfile -t shares_data < <(parse_samba_config "$config_file")

    for share_data in "${shares_data[@]}"; do
        # Parse share name and configuration
        local share_name="${share_data%%:*}"
        local config_string="${share_data#*:}"
        local share_path=""

        # Parse configuration parameters
        IFS='|' read -ra config_items <<< "$config_string"
        for item in "${config_items[@]}"; do
            if [[ "$item" =~ ^([^=]+)=(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                if [[ "$key" == "path" ]]; then
                    share_path="$value"
                    break
                fi
            fi
        done

        # Output name:path if path found
        if [ -n "$share_path" ]; then
            printf '%s:%s\n' "$share_name" "$share_path"
        fi
    done
}

validate_and_create_share_directories() {
    local config_file="$1"
    local shares_data

    # Parse the configuration
    mapfile -t shares_data < <(parse_samba_config "$config_file")

    # First, list all shares found in configuration
    print_status "📁 Found ${#shares_data[@]} shares in configuration:"
    for share_data in "${shares_data[@]}"; do
        local share_name="${share_data%%:*}"
        local config_string="${share_data#*:}"
        local share_path=""

        # Parse path from configuration
        IFS='|' read -ra config_items <<< "$config_string"
        for item in "${config_items[@]}"; do
            if [[ "$item" =~ ^path=(.+)$ ]]; then
                share_path="${BASH_REMATCH[1]}"
                break
            fi
        done

        if [ -n "$share_path" ]; then
            echo "   • $share_name: $share_path"
        fi
    done

    print_status "🔧 📁 Validating and creating Samba share directories..."

    local processed_count=0
    local created_count=0
    local updated_count=0

    for share_data in "${shares_data[@]}"; do
        # Parse share name and configuration
        local share_name="${share_data%%:*}"
        local config_string="${share_data#*:}"
        local share_path=""
        local directory_mask="755"
        local force_user=""
        local force_group=""
        local create_mask="644"

        # Parse configuration parameters
        IFS='|' read -ra config_items <<< "$config_string"
        for item in "${config_items[@]}"; do
            if [[ "$item" =~ ^([^=]+)=(.+)$ ]]; then
                local key="${BASH_REMATCH[1]}"
                local value="${BASH_REMATCH[2]}"

                case "$key" in
                    "path")
                        share_path="$value"
                        ;;
                    "directory mask"|"force directory mode")
                        directory_mask="$value"
                        ;;
                    "create mask"|"force create mode")
                        create_mask="$value"
                        ;;
                    "force user")
                        force_user="$value"
                        ;;
                    "force group")
                        force_group="$value"
                        ;;
                esac
            fi
        done

        # Skip if no path defined
        if [ -z "$share_path" ]; then
            print_warning "⚠️ Share '$share_name' has no path defined, skipping..."
            continue
        fi

        processed_count=$((processed_count + 1))

        if [ ! -d "$share_path" ]; then
            if sudo mkdir -p "$share_path" 2>/dev/null; then
                created_count=$((created_count + 1))

                # Apply ownership
                if [ -n "$force_user" ]; then
                    if [ -n "$force_group" ]; then
                        sudo chown "$force_user:$force_group" "$share_path"
                    else
                        sudo chown "$force_user" "$share_path"
                    fi
                fi

                # Apply directory permissions
                if [ -n "$directory_mask" ]; then
                    sudo chmod "$directory_mask" "$share_path"
                fi
            else
                print_error "❌ Failed to create directory: $share_path"
            fi
        else
            # Validate and fix permissions if needed
            local current_perms
            current_perms=$(stat -c "%a" "$share_path")
            local current_owner
            current_owner=$(stat -c "%U:%G" "$share_path")

            local needs_update=false

            # Check ownership
            if [ -n "$force_user" ]; then
                local expected_owner="$force_user"
                if [ -n "$force_group" ]; then
                    expected_owner="$force_user:$force_group"
                fi

                if [ "$current_owner" != "$expected_owner" ]; then
                    sudo chown "$expected_owner" "$share_path" 2>/dev/null || print_warning "Failed to set ownership for $share_path"
                    needs_update=true
                fi
            fi

            # Check permissions
            if [ -n "$directory_mask" ] && [ "$current_perms" != "$directory_mask" ]; then
                sudo chmod "$directory_mask" "$share_path" 2>/dev/null || print_warning "Failed to set permissions for $share_path"
                needs_update=true
            fi

            if [ "$needs_update" = true ]; then
                updated_count=$((updated_count + 1))
            fi
        fi
    done

    print_success "📊 Samba directory validation complete:"
    print_success "   • Processed: $processed_count shares"
    print_success "   • Created: $created_count directories"
    print_success "   • Updated: $updated_count directories"
}

setup_folder_permissions() {
    local folder_path="$1"
    local requested_dir_perms="$2"  # Optional: Use SMB config force_directory_mode
    local requested_file_perms="$3"  # Optional: Use SMB config force_create_mode

    # Determine permissions based on folder type and SMB config
    local min_dir_perms="${requested_dir_perms:-755}"
    local min_file_perms="${requested_file_perms:-644}"

    # Override defaults for known writable shares
    if [[ "$folder_path" == "/var/www/"* ]]; then
        min_dir_perms="${requested_dir_perms:-775}"
        min_file_perms="${requested_file_perms:-664}"
    elif [[ "$folder_path" == *"/minecraft"* ]] || [[ "$folder_path" == *"/backup_"* ]]; then
        # Minecraft and backup folders should be writable (use requested perms from SMB config)
        min_dir_perms="${requested_dir_perms:-775}"
        min_file_perms="${requested_file_perms:-664}"
    fi

    if [ -d "$folder_path" ]; then
        # Set ownership - use batch operation for efficiency
        sudo chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$folder_path" 2>/dev/null || true
        
        # IMPORTANT: Special handling for maintenance scripts - preserve execute bits on .sh files
        if [[ "$folder_path" == *"/maintenance_scripts/scripts"* ]]; then
            # Only add group write to existing .sh files, preserve execute bits
            find "$folder_path" -name "*.sh" -type f -exec sudo chmod g+w {} \; 2>/dev/null || true
            # Non-script files get standard permissions
            find "$folder_path" -type f ! -name "*.sh" -exec sudo chmod "$min_file_perms" {} \; 2>/dev/null || true
            # Directories get standard permissions
            find "$folder_path" -type d -exec sudo chmod "$min_dir_perms" {} \; 2>/dev/null || true
        # For existing Minecraft directories: only add group write bit, don't remove execute
        elif [[ "$folder_path" == *"/minecraft"* ]]; then
            # Use batch chmod with -R flag - more efficient than per-file operations
            sudo chmod -R g+w "$folder_path" 2>/dev/null || true
        # For backup directories: use batch operations with --preserve-mode when possible
        elif [[ "$folder_path" == *"/backup_"* ]]; then
            # Apply batch permissions without the verbose loop
            sudo find "$folder_path" -type d -exec chmod "$min_dir_perms" {} \; 2>/dev/null || true
            sudo find "$folder_path" -type f -exec chmod "$min_file_perms" {} \; 2>/dev/null || true
        else
            # For other directories: apply full permissions using batch operations
            sudo find "$folder_path" -type d -exec chmod "$min_dir_perms" {} \; 2>/dev/null || true
            sudo find "$folder_path" -type f -exec chmod "$min_file_perms" {} \; 2>/dev/null || true
        fi
    else
        print_status "Creating directory: $folder_path"
        sudo mkdir -p "$folder_path"
        sudo chown -R "$ACTUAL_USER:$ACTUAL_GROUP" "$folder_path"
        sudo chmod "$min_dir_perms" "$folder_path"
        
        # Ensure parent directories also have proper permissions for access
        local parent_dir="$(dirname "$folder_path")"
        if [ "$parent_dir" != "/" ] && [ "$parent_dir" != "$ACTUAL_HOME" ]; then
            sudo chown "$ACTUAL_USER:$ACTUAL_GROUP" "$parent_dir" 2>/dev/null || true
            sudo chmod 755 "$parent_dir" 2>/dev/null || true
        fi
    fi
}

# Function to process template scripts (replace __INSTALLER_USER__ placeholders)
process_template_scripts() {
    local backup_config_dir="$1"
    local real_user="$2"
    local scripts_dir="$backup_config_dir/maintenance_scripts/scripts"
    
    # Optional: only machines with maintenance scripts have this folder.
    if [ ! -d "$scripts_dir" ]; then
        return 0
    fi

    print_status "Processing template scripts in maintenance_scripts/scripts..."
    
    local processed_count=0
    
    # Process all .sh files in the scripts directory
    for script_file in "$scripts_dir"/*.sh; do
        if [ -f "$script_file" ] && grep -q "__INSTALLER_USER__" "$script_file"; then
            print_status "Processing template: $(basename "$script_file")"
            # Replace placeholder with actual username
            sed -i "s/__INSTALLER_USER__/$real_user/g" "$script_file"
            # IMPORTANT: sed -i can remove execute bits when creating temp files
            # Restore the execute bit after modification
            sudo chmod +x "$script_file" 2>/dev/null || true
            ((processed_count++))
        fi
    done
    
    if [ $processed_count -gt 0 ]; then
        print_success "Processed $processed_count template script(s)"
    else
        print_status "No template scripts to process"
    fi
    
    return 0
}

print_status "Configuring Samba shares..."

if [ -n "$SUDO_USER" ]; then
    ACTUAL_USER="$SUDO_USER"
    ACTUAL_HOME=$(getent passwd "$SUDO_USER" | cut -d: -f6)
else
    ACTUAL_USER=$(whoami)
    ACTUAL_HOME="$HOME"
fi

ACTUAL_GROUP=$(id -gn "$ACTUAL_USER")

# Repo root is two levels up from install_scripts/scripts/, so this resolves
# without naming the repo. BACKUP_CONFIG can be exported by the caller to point
# somewhere else (e.g. when this script is fetched from a shared repo rather
# than run from inside the machine's own checkout).
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BACKUP_CONFIG="${BACKUP_CONFIG:-$REPO_ROOT/backup_config}"
SMB_CONFIG="$BACKUP_CONFIG/smb/smb.conf"
SYSTEM_SMB_CONFIG="/etc/samba/smb.conf"

if [ -d "$BACKUP_CONFIG" ] && [ -f "$SMB_CONFIG" ]; then
    print_status "Configuring Samba configuration file..."

    # Ensure config file has correct permissions
    if sudo chown "$ACTUAL_USER:$ACTUAL_GROUP" "$SMB_CONFIG" && \
       sudo chmod 644 "$SMB_CONFIG"; then
        print_success "Samba configuration permissions set successfully"
    else
        print_error "Failed to set Samba configuration permissions"
        exit 1
    fi

    mapfile -t SHARE_PATHS < <(extract_share_paths "$SMB_CONFIG")
    mapfile -t SHARE_INFO < <(extract_share_info "$SMB_CONFIG")

    # Validate and create all share directories with proper permissions
    validate_and_create_share_directories "$SMB_CONFIG"

    # Ensure all share directories exist with proper permissions from SMB config
    # Re-parse to get directory masks for each share
    mapfile -t shares_data < <(parse_samba_config "$SMB_CONFIG")
    for share_data in "${shares_data[@]}"; do
        share_name="${share_data%%:*}"
        config_string="${share_data#*:}"
        share_path=""
        directory_mask="755"
        create_mask="644"

        # Parse configuration parameters
        IFS='|' read -ra config_items <<< "$config_string"
        for item in "${config_items[@]}"; do
            if [[ "$item" =~ ^([^=]+)=(.+)$ ]]; then
                key="${BASH_REMATCH[1]}"
                value="${BASH_REMATCH[2]}"

                case "$key" in
                    "path")
                        share_path="$value"
                        ;;
                    "directory mask"|"force directory mode")
                        directory_mask="$value"
                        ;;
                    "create mask"|"force create mode")
                        create_mask="$value"
                        ;;
                esac
            fi
        done

        # Apply SMB config permissions to share directory
        if [ -n "$share_path" ]; then
            setup_folder_permissions "$share_path" "$directory_mask" "$create_mask"
        fi
    done

    # Ensure critical directories exist (especially backup directories that scripts depend on)
    print_status "Creating essential directories for server operations..."

    # Dynamically generate ESSENTIAL_DIRS based on smb.conf shares
    ESSENTIAL_DIRS=()

    # Add all share paths from smb.conf
    for path in "${SHARE_PATHS[@]}"; do
        if [ -n "$path" ] && [ "$path" != "" ]; then
            ESSENTIAL_DIRS+=("$path")
        fi
    done

    # Remove duplicates and empty entries, then sort
    if [ ${#ESSENTIAL_DIRS[@]} -gt 0 ]; then
        mapfile -t ESSENTIAL_DIRS < <(printf '%s\n' "${ESSENTIAL_DIRS[@]}" | grep -v '^$' | sort -u)
    fi

    print_status "Found ${#ESSENTIAL_DIRS[@]} essential directories to configure"

    for essential_dir in "${ESSENTIAL_DIRS[@]}"; do
        # Skip empty entries
        if [ -z "$essential_dir" ] || [ "$essential_dir" = "" ]; then
            continue
        fi

        if [ ! -d "$essential_dir" ]; then
            print_status "Creating essential directory: $essential_dir"
            setup_folder_permissions "$essential_dir"
        else
            # Ensure existing directories have correct permissions
            setup_folder_permissions "$essential_dir"
        fi
    done

    # Process template scripts that contain __INSTALLER_USER__ placeholders
    if [ -d "$BACKUP_CONFIG" ]; then
        process_template_scripts "$BACKUP_CONFIG" "$ACTUAL_USER"
    fi

    if [ -L "$SYSTEM_SMB_CONFIG" ]; then
        current_target=$(readlink "$SYSTEM_SMB_CONFIG")
        [ "$current_target" != "$SMB_CONFIG" ] && sudo ln -sf "$SMB_CONFIG" "$SYSTEM_SMB_CONFIG"
    elif [ -f "$SYSTEM_SMB_CONFIG" ]; then
        backup_file="${SYSTEM_SMB_CONFIG}.bak.$(date +%Y%m%d_%H%M%S)"
        sudo mv "$SYSTEM_SMB_CONFIG" "$backup_file"
        sudo ln -sf "$SMB_CONFIG" "$SYSTEM_SMB_CONFIG"
    else
        sudo ln -sf "$SMB_CONFIG" "$SYSTEM_SMB_CONFIG"
    fi

    print_status "Verifying symlink configuration..."
    if [ -L "$SYSTEM_SMB_CONFIG" ]; then
        symlink_target=$(readlink "$SYSTEM_SMB_CONFIG")
        if [ "$symlink_target" = "$SMB_CONFIG" ]; then
            print_success "Symlink correctly points to: $SMB_CONFIG"
        else
            print_error "Symlink points to wrong location: $symlink_target"
            sudo ln -sf "$SMB_CONFIG" "$SYSTEM_SMB_CONFIG"
        fi
    else
        print_error "System config is not a symlink!"
        exit 1
    fi

    if [ ! -f "$SMB_CONFIG" ]; then
        print_error "Target config file missing: $SMB_CONFIG"
        exit 1
    fi

    [ -r "$SYSTEM_SMB_CONFIG" ] || sudo chmod 644 "$SMB_CONFIG"

    if ! sudo testparm -s "$SYSTEM_SMB_CONFIG" >/dev/null 2>&1; then
        print_warning "Configuration validation failed - using backup"
        latest_backup=$(ls -t ${SYSTEM_SMB_CONFIG}.bak.* 2>/dev/null | head -1)
        [ -n "$latest_backup" ] && sudo cp "$latest_backup" "$SYSTEM_SMB_CONFIG"
    fi

    sudo systemctl restart smbd nmbd
else
    print_status "No $SMB_CONFIG found - keeping the installed /etc/samba/smb.conf"
    SHARE_INFO=()
fi

print_status "Performing final system verification..."

# Verify Samba configuration
if sudo testparm -s "$SYSTEM_SMB_CONFIG" >/dev/null 2>&1; then
    print_success "Samba configuration validated successfully"
else
    print_error "Configuration validation failed"
    print_warning "Run 'sudo testparm $SYSTEM_SMB_CONFIG' for detailed error information"
    print_warning "Configuration symlink status: $(ls -la $SYSTEM_SMB_CONFIG)"
    exit 1
fi

# Check service status
if ! systemctl is-active --quiet smbd || ! systemctl is-active --quiet nmbd; then
    print_error "Some Samba services are not running"
    print_warning "Check service status with: 'sudo systemctl status smbd nmbd'"
    exit 1
fi

# Verify shares
if command -v smbclient &> /dev/null && [ ${#SHARE_INFO[@]} -gt 0 ]; then
    print_status "Verifying configured shares..."
    for share_data in "${SHARE_INFO[@]}"; do
        share_name="${share_data%%:*}"
        share_path="${share_data##*:}"

        smbclient "//localhost/$share_name" -N -c "ls" > /dev/null 2>/tmp/smbclient_error.log || true
        # Only show error info if share is not accessible
        if [ ${PIPESTATUS[0]} -ne 0 ]; then
            print_warning "Share '$share_name' may not be accessible"
            if [ ! -d "$share_path" ]; then
                print_error "   Directory missing: $share_path"
            elif [ ! -r "$share_path" ]; then
                print_error "   Directory not readable: $share_path ($(stat -c '%a' "$share_path"))"
            fi
            echo "   🔍 smbclient error:"
            cat /tmp/smbclient_error.log | grep -vE 'blocks of size|blocks available|^\s*\.|^\s*\.\.'
        fi
    done
fi

server_ip=$(hostname -I | awk '{print $1}')

if [ ${#SHARE_INFO[@]} -gt 0 ]; then
    print_success "Available Samba shares:"
    for share_data in "${SHARE_INFO[@]}"; do
        share_name="${share_data%%:*}"
        echo "   \\\\$server_ip\\$share_name"
    done
    echo ""
else
    print_warning "No shares configured or share information not available"
fi

print_success "Samba installation and configuration completed successfully!"

# Clean up temporary files
rm -f /tmp/smbclient_error.log