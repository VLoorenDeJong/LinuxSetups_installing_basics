#!/usr/bin/env bash
set -e

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Inline utility functions (always defined, no sourcing required) ---
print_status() {
    printf "\033[34m🔧 %s\033[0m\n" "$1"
}

print_success() {
    printf "\033[32m✅ %s\033[0m\n" "$1"
}

print_warning() {
    printf "\033[33m⚠️ %s\033[0m\n" "$1"
}

print_error() {
    printf "\033[31m❌ %s\033[0m\n" "$1"
}

print_header() {
    printf "\n\033[36m=== %s ===\033[0m\n" "$1"
}

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

# Function to check and fix DPKG locks (calls dedicated script)
check_and_fix_dpkg_lock() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local fix_script="$script_dir/fix_dpkg_lock.sh"
    if [ ! -f "$fix_script" ]; then
        # The shared basics layer (submodule) holds fix_dpkg_lock.sh
        fix_script="$script_dir/../../${BASICS_SUBMODULE:-LinuxBasics}/install_scripts/fix_dpkg_lock.sh"
    fi
    
    if [ -f "$fix_script" ]; then
        echo -e "\e[34m🔧 Checking and fixing DPKG locks...\e[0m"
        if bash "$fix_script"; then
            echo -e "\e[32m✅ DPKG lock check/fix completed\e[0m"
            return 0
        else
            echo -e "\e[31m❌ DPKG lock fix failed, continuing anyway...\e[0m"
            return 1
        fi
    else
        echo -e "\e[33m⚠️  fix_dpkg_lock.sh not found, proceeding without DPKG lock check\e[0m"
        return 1
    fi
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

echo ""
echo -e "\e[34m🔍 Checking Apache installation...\e[0m"
echo ""

# Check if Apache is already installed
if dpkg -s apache2 &> /dev/null; then
    echo -e "\e[32m✅ Apache is already installed.\e[0m"
else
    echo -e "\e[34m🛠️ Installing Apache...\e[0m"
    
    # Check and fix DPKG locks before proceeding
    check_and_fix_dpkg_lock
    
    if show_progress "📦 Updating package lists" "sudo apt-get update -qq >/dev/null 2>&1"; then
        if show_progress "🔄 Installing Apache2 package" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq apache2 >/dev/null 2>&1"; then
            echo -e "\e[32m✅ Apache installed successfully.\e[0m"
        else
            echo -e "\e[31m❌ Apache installation failed.\e[0m"
            exit 1
        fi
    else
        echo -e "\e[31m❌ Package update failed.\e[0m"
        exit 1
    fi
fi

echo -e "\e[34m🔧 Checking Apache service status...\e[0m"

# Enable and start Apache service if not running
if ! systemctl is-active --quiet apache2; then
    if show_progress "🚀 Starting and enabling Apache service" "sudo systemctl enable apache2 >/dev/null 2>&1 && sudo systemctl start apache2 >/dev/null 2>&1"; then
        echo -e "\e[32m✅ Apache service started successfully.\e[0m"
    else
        echo -e "\e[31m❌ Failed to start Apache service.\e[0m"
        exit 1
    fi
else
    echo -e "\e[32m✅ Apache service is already running.\e[0m"
fi

echo -e "\e[34m🛡️ Configuring firewall...\e[0m"

# Allow Apache through firewall if UFW is active
#
# 'Apache Full' (80 and 443), never 'Apache' (80 only). With only port 80 open,
# certbot's HTTP-01 challenge still succeeds and certificates are issued, and
# then every site is unreachable over HTTPS. The symptom appears only once the
# certificates work, which is the worst moment to start suspecting the firewall.
#
# The old check matched the word "Apache", so once the port-80-only rule existed
# it reported success on every later run and 443 was never opened. The check
# below looks for 443 specifically, which is the thing that matters.
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    if sudo ufw status | grep -qE "Apache Full|443"; then
        echo -e "\e[32m✅ Apache is already allowed through UFW on 80 and 443.\e[0m"
    else
        echo -e "\e[34m🔥 Allowing Apache Full (80 and 443) through UFW...\e[0m"
        if sudo ufw allow 'Apache Full' >/dev/null 2>&1; then
            echo -e "\e[32m✅ Apache allowed through firewall on 80 and 443.\e[0m"
        else
            # The app profile only exists once apache2 is installed. Fall back
            # to the ports themselves rather than leaving HTTPS closed.
            sudo ufw allow 80/tcp >/dev/null 2>&1
            sudo ufw allow 443/tcp >/dev/null 2>&1
            echo -e "\e[33m⚠️ 'Apache Full' profile not found, allowed 80/tcp and 443/tcp directly.\e[0m"
        fi
    fi
else
    echo -e "\e[33m⚠️ UFW not active or not installed. Skipping firewall configuration.\e[0m"
fi

echo -e "\e[34m🧪 Testing Apache configuration...\e[0m"

# Test Apache configuration
if sudo apachectl configtest &> /dev/null; then
    echo -e "\e[32m✅ Apache configuration is valid.\e[0m"
else
    echo -e "\e[33m⚠️ Apache configuration test failed. Please check manually.\e[0m"
fi

echo -e "\e[34m📁 Setting up web directory...\e[0m"

# Create /var/www folder and set permissions if needed
if [ ! -d "/var/www" ]; then
    sudo mkdir -p /var/www >/dev/null 2>&1
    sudo chmod 755 /var/www >/dev/null 2>&1
    echo -e "\e[32m✅ Apache www folder created with proper permissions.\e[0m"
elif [ "$(stat -c %a /var/www)" != "755" ]; then
    sudo chmod 755 /var/www >/dev/null 2>&1
    echo -e "\e[32m✅ Apache www folder permissions updated.\e[0m"
else
    echo -e "\e[32m✅ Apache www folder already exists with correct permissions.\e[0m"
fi

echo ""
echo -e "\e[32m✅ Apache installation and configuration complete\e[0m"
echo ""