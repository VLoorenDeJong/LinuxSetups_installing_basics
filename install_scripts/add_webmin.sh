#!/usr/bin/env bash

# -d / --debug: trace every command. Stripped from "$@" so it never reaches the
# script's own argument parsing.
DEBUG_MODE=0
_dbg_args=()
for _a in "$@"; do
    case "$_a" in
        -d|--debug) DEBUG_MODE=1 ;;
        *)          _dbg_args+=("$_a") ;;
    esac
done
set -- ${_dbg_args+"${_dbg_args[@]}"}
unset _a _dbg_args
[ "$DEBUG_MODE" = "1" ] && set -x

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Inline utility functions (always defined, no sourcing required) ---
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

print_header() {
    printf "\n\e[36m=== %s ===\e[0m\n" "$1"
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

# Watch-only variant for irreversible package transactions (full-upgrade, install -f,
# dpkg -i, dpkg --configure -a): never signals the child, only reports elapsed time.
show_progress_watch_only() {
    local message="$1"
    local command="$2"
    local interval="${3:-3}"  # Default 3 seconds between dots

    echo -e "\e[34m${message}\e[0m"

    eval "$command" &
    local cmd_pid=$!
    local start_time
    start_time=$(date +%s)

    while kill -0 $cmd_pid 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep $interval || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done

    wait $cmd_pid
    local exit_code=$?

    echo  # New line after dots
    return $exit_code
}

# Watch-only spinner + progress bar: never signals the child (same regime as
# show_progress_watch_only), but renders a live bar from apt's machine-readable
# status lines ("pmstatus:...:PCT:desc" / "dlstatus:...") that land in the log
# when apt-get runs with -o APT::Status-Fd=1.
show_progress_bar_watch_only() {
    local message="$1"
    local command="$2"
    local logfile="$3"

    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local width=28
    local empty_bar full_bar
    empty_bar=$(printf '░%.0s' $(seq 1 $width))
    full_bar=$(printf '█%.0s' $(seq 1 $width))

    echo -e "\e[34m${message}\e[0m"

    eval "$command" &
    local cmd_pid=$!
    local tick=0

    while kill -0 $cmd_pid 2>/dev/null; do
        local frame="${spinner[tick % 10]}"
        tick=$((tick + 1))

        local line pct="" desc="" parsed=""
        line=$(grep -E '^(pmstatus|dlstatus):' "$logfile" 2>/dev/null | tail -1)
        if [ -n "$line" ]; then
            # apt writes "type:name:percent:message", but a multi-arch name
            # carries its own colon ("pmstatus:libc6:amd64:37.5000:Unpacking"),
            # so the percent is NOT at a fixed field index — cut -f3 grabbed
            # "amd64" and the bar stayed stuck on "working" for the whole dpkg
            # phase. Take the first decimal field at or after 3 as the percent,
            # everything after it as the description (which may contain colons).
            parsed=$(printf '%s' "$line" | awk -F: '{
                for (i = 3; i <= NF; i++)
                    if ($i ~ /^[0-9]+\.[0-9]+$/) {
                        d = $(i+1)
                        for (j = i + 2; j <= NF; j++) d = d ":" $j
                        printf "%d\t%s", $i, d
                        exit
                    }
            }')
            pct=${parsed%%$'\t'*}
            desc=${parsed#*$'\t'}
        fi

        if [[ "$pct" =~ ^[0-9]+$ ]]; then
            local filled=$((pct * width / 100))
            printf '\r\033[K[%s%s] %s %3d%%  %.40s' "${full_bar:0:filled}" "${empty_bar:0:width-filled}" "$frame" "$pct" "$desc"
        else
            printf '\r\033[K[%s] %s  …   working' "$empty_bar" "$frame"
        fi

        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep 0.2 || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done

    wait $cmd_pid
    local exit_code=$?

    printf '\r\033[K'  # Clear the bar line before normal output resumes
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

# Function to diagnose apt/dpkg system health
diagnose_apt_system() {
    echo -e "\e[34m🔍 Diagnosing apt/dpkg system health...\e[0m"
    
    local issues_found=0
    
    # Check network connectivity to the Webmin repository (the host this
    # script actually needs — distro-neutral, unlike a fixed Ubuntu mirror)
    echo -e "\e[34m🌐 Checking network connectivity...\e[0m"
    if ! timeout 10 curl -s --head https://download.webmin.com/ >/dev/null 2>&1; then
        echo -e "\e[33m⚠️  Cannot reach the Webmin repository - network issue\e[0m"
        ((issues_found++))
    fi
    
    # Check for corrupted dpkg status file
    if ! sudo dpkg --audit >/dev/null 2>&1; then
        echo -e "\e[33m⚠️  dpkg audit failed - possible corruption\e[0m"
        ((issues_found++))
    fi
    
    # Check package cache integrity
    if ! sudo apt-get check >/dev/null 2>&1; then
        echo -e "\e[33m⚠️  apt-get check failed - dependency issues\e[0m"
        ((issues_found++))
    fi
    
    # Check for held packages
    local held_packages=$(sudo apt-mark showhold | wc -l)
    if [ "$held_packages" -gt 0 ]; then
        echo -e "\e[33m⚠️  $held_packages packages are held\e[0m"
        ((issues_found++))
    fi
    
    # Check disk space
    local available_space=$(df /var/lib/dpkg | awk 'NR==2 {print $4}')
    if [ "$available_space" -lt 100000 ]; then  # Less than ~100MB
        echo -e "\e[33m⚠️  Low disk space available: $(($available_space/1024))MB\e[0m"
        ((issues_found++))
    fi
    
    if [ $issues_found -gt 0 ]; then
        echo -e "\e[33m⚠️  Found $issues_found potential issues. Attempting auto-fix...\e[0m"
        
        # Try to fix common issues
        sudo apt-get clean >/dev/null 2>&1
        sudo apt-get autoclean >/dev/null 2>&1
        sudo apt-get autoremove -y >/dev/null 2>&1
        sudo dpkg --configure -a >/dev/null 2>&1
        
        echo -e "\e[32m✅ Auto-fix completed\e[0m"
    else
        echo -e "\e[32m✅ apt/dpkg system appears healthy\e[0m"
    fi
}

if [ "$EUID" -ne 0 ]; then
    print_error "This script requires sudo privileges to run properly."
    print_warning "Please run with: sudo $0"
    exit 1
fi

print_status "Installing Webmin Web Management Interface..."

# Check if Webmin is already installed and running
if timeout 10 systemctl is-active --quiet webmin 2>/dev/null; then
    print_success "Webmin is already installed and running"
    print_status "Access at: https://$(hostname -I | awk '{print $1}'):10000"
    exit 0
fi

print_status "Setting up official Webmin repository using modern GPG keys..."

# Check and fix DPKG locks before proceeding
check_and_fix_dpkg_lock

# Diagnose overall apt/dpkg system health
diagnose_apt_system

# Install dependencies
print_status "Installing required dependencies..."
if show_progress "📦 Updating package lists" "timeout 180 sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
    print_success "Package lists updated successfully"
else
    print_warning "apt-get update failed, trying apt update..."
    if show_progress "� Updating package lists (alternative method)" "timeout 180 sudo apt update -qq >/dev/null 2>&1" 2 180; then
        print_success "Package lists updated successfully (alternative method)"
    else
        print_error "Failed to update package lists"
        # Show what went wrong
        echo -e "\e[33m🔍 Debug info:\e[0m"
        timeout 30 sudo apt-get update --fix-missing 2>&1 | head -20
        exit 1
    fi
fi

if show_progress "🔧 Installing dependencies" "timeout 300 sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends curl gnupg software-properties-common apt-transport-https ca-certificates >/dev/null 2>&1" 2 300; then
    print_success "Dependencies installed successfully"
else
    print_warning "Standard installation failed, trying alternative method..."
    # Try with apt instead of apt-get
    if show_progress "🔧 Installing dependencies (alternative method)" "timeout 300 sudo env DEBIAN_FRONTEND=noninteractive apt install -y -qq --no-install-recommends curl gnupg software-properties-common apt-transport-https ca-certificates >/dev/null 2>&1" 2 300; then
        print_success "Dependencies installed successfully (alternative method)"
    else
        print_error "Failed to install dependencies"
        # Show what went wrong
        echo -e "\e[33m🔍 Debug info:\e[0m"
        timeout 30 sudo apt-get install -y --no-install-recommends curl gnupg software-properties-common apt-transport-https ca-certificates 2>&1 | head -20
        exit 1
    fi
fi

# Function to use official Webmin repository setup
setup_official_webmin_repo() {
    print_status "Using official Webmin repository setup script..."
    
    # Download and run the official Webmin repository setup script
    cd /tmp
    if show_progress "📥 Downloading official repository setup script" "curl --max-time 30 -fsSL https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh -o webmin-setup-repo.sh 2>/dev/null" 2 60; then
        print_status "Downloaded official Webmin repository setup script"

        # Webmin doesn't publish a checksum for this script, so this is a sanity
        # check, not a real integrity guarantee: refuse to root-execute anything
        # empty, truncated, or that isn't valid shell before running it.
        if [ ! -s webmin-setup-repo.sh ] || ! bash -n webmin-setup-repo.sh 2>/dev/null; then
            print_error "Downloaded setup script is empty or not valid shell — refusing to run it"
            rm -f webmin-setup-repo.sh
            return 1
        fi

        # Run the official setup script with force flag to avoid prompts
        if show_progress "⚙️ Configuring official Webmin repository" "bash webmin-setup-repo.sh --force >/dev/null 2>&1"; then
            print_success "Official Webmin repository configured successfully"
            rm -f webmin-setup-repo.sh
            return 0
        else
            print_warning "Official repository setup failed, trying manual setup..."
            rm -f webmin-setup-repo.sh
            return 1
        fi
    else
        print_warning "Could not download official setup script, trying manual setup..."
        return 1
    fi
}

# Function to manually setup Webmin repository (fallback)
setup_manual_webmin_repo() {
    print_status "Setting up Webmin repository manually with modern keys..."
    
    # Clean up any existing repositories
    sudo rm -f /etc/apt/sources.list.d/webmin*.list >/dev/null 2>&1
    sudo rm -f /usr/share/keyrings/webmin*.gpg >/dev/null 2>&1
    
    # Download the modern Webmin developers key (post-DSA-1024)
    print_status "Adding modern Webmin developers GPG key..."
    if show_progress "🔑 Downloading and installing GPG key" "curl --max-time 30 -fsSL https://download.webmin.com/developers-key.asc 2>/dev/null | gpg --dearmor 2>/dev/null | sudo tee /usr/share/keyrings/webmin-developers.gpg >/dev/null 2>&1" 2 60; then
        print_success "Modern Webmin developers key added successfully"
        
        # Add the official Webmin repository with modern newkey path
        print_status "Adding modern Webmin repository..."
        echo "deb [signed-by=/usr/share/keyrings/webmin-developers.gpg] https://download.webmin.com/download/newkey/repository stable contrib" | sudo tee /etc/apt/sources.list.d/webmin.list >/dev/null
        
        return 0
    else
        print_error "Failed to add modern Webmin developers key"
        return 1
    fi
}

# Function for Snap installation (alternative)
install_webmin_snap() {
    print_status "Attempting Snap installation as alternative..."
    if command -v snap >/dev/null 2>&1; then
        if sudo snap install webmin --classic >/dev/null 2>&1; then
            print_success "Webmin installed via Snap"
            print_status "Access Webmin at: https://$(hostname -I | awk '{print $1}'):10000"
            print_status "Login with your system username and password"
            print_warning "Note: Snap version may have slightly different features"
            return 0
        else
            print_error "Snap installation also failed"
            return 1
        fi
    else
        print_warning "Snap not available on this system"
        return 1
    fi
}

# Function for direct .deb installation (alternative)
install_webmin_deb() {
    print_status "Attempting direct .deb installation..."
    cd /tmp
    if show_progress "📥 Downloading Webmin .deb package" "wget --timeout=30 -q https://download.webmin.com/download/deb/webmin-current.deb 2>/dev/null" 2 60; then
        if show_progress_watch_only "📦 Installing Webmin from .deb package (irreversible — will not be interrupted)" "sudo dpkg -i webmin-current.deb >/dev/null 2>&1"; then
            # Fix any dependency issues (no timeout — must not be killed mid-write)
            show_progress_watch_only "🔧 Fixing dependencies" "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -f -y -qq --fix-missing >/dev/null 2>&1"
            rm -f webmin-current.deb
            print_success "Webmin installed via direct .deb package"
            return 0
        else
            rm -f webmin-current.deb
            print_error "Direct .deb installation failed"
            return 1
        fi
    else
        print_error "Could not download Webmin .deb package"
        return 1
    fi
}

# Try official repository setup first
if setup_official_webmin_repo; then
    print_status "Repository setup successful, proceeding with installation..."
elif setup_manual_webmin_repo; then
    print_status "Manual repository setup successful, proceeding with installation..."
else
    print_warning "Repository setup failed, trying alternative installation methods..."
    
    # Try Snap first, then direct .deb as fallbacks
    if install_webmin_snap; then
        exit 0
    elif install_webmin_deb; then
        # Skip the rest since we've already installed via .deb
        print_status "Configuring firewall for Webmin..."
        if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
            if ! sudo ufw status numbered | grep -q "10000"; then
                sudo ufw allow 10000 >/dev/null 2>&1
            fi
        fi
        print_success "Webmin installation complete"
        print_status "Access Webmin at: https://$(hostname -I | awk '{print $1}'):10000"
        print_status "Login with your system username and password"
        exit 0
    else
        print_error "All installation methods failed"
        print_status "Manual installation options:"
        print_status "1. Download from: https://download.webmin.com/download/deb/webmin-current.deb"
        print_status "2. Try: curl -o setup-repos.sh https://raw.githubusercontent.com/webmin/webmin/master/webmin-setup-repo.sh && sudo sh setup-repos.sh"
        exit 0
    fi
fi

print_status "Updating package lists with new repository..."
if ! show_progress "📦 Updating package lists with Webmin repository" "timeout 180 sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
    print_warning "Package list update failed, but continuing with installation attempt..."
fi

print_status "Installing Webmin package..."
print_status "Webmin is a large package - this may take several minutes..."

# The install is an irreversible dpkg transaction — watch-only, never killed
# (the old kill-on-timeout wrapper here risked corrupting package state).
# APT::Status-Fd=1 writes percent lines into the log for the progress bar;
# NEEDRESTART_MODE=a stops needrestart's kernel dialog from silently blocking.
WEBMIN_APT_LOG="/tmp/add_webmin_apt.log"
if show_progress_bar_watch_only "🌐 Installing Webmin from repository" "sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=a apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends webmin >$WEBMIN_APT_LOG 2>&1" "$WEBMIN_APT_LOG"; then
    print_success "Webmin installed successfully via repository"
    # Skip to configuration since repository installation succeeded
    print_status "Proceeding with Webmin configuration..."
else
    print_warning "Repository installation timed out or failed, trying alternative methods..."

    # Try alternative installation methods only if repository failed
    if install_webmin_snap; then
        print_success "Webmin installed via Snap"
        print_status "Proceeding with Webmin configuration..."
    elif install_webmin_deb; then
        print_success "Webmin installed via direct .deb"
        print_status "Proceeding with Webmin configuration..."
    else
        print_error "All installation methods failed"
        exit 1
    fi
fi

print_status "Configuring Webmin service..."

# Ensure Webmin service is enabled and started
if ! timeout 10 systemctl is-enabled --quiet webmin 2>/dev/null; then
    if timeout 30 sudo systemctl enable webmin >/dev/null 2>&1; then
        print_success "Webmin service enabled"
    else
        print_warning "Failed to enable Webmin service"
    fi
fi

if ! timeout 10 systemctl is-active --quiet webmin 2>/dev/null; then
    if timeout 30 sudo systemctl start webmin >/dev/null 2>&1; then
        print_success "Webmin service started"
    else
        print_warning "Failed to start Webmin service"
    fi
fi

print_status "Configuring firewall for Webmin..."

# Allow Webmin through firewall if UFW is active
if command -v ufw &> /dev/null && sudo ufw status | grep -q "Status: active"; then
    if ! sudo ufw status numbered | grep -q "10000"; then
        sudo ufw allow 10000 >/dev/null 2>&1
        print_success "Firewall rule added for Webmin (port 10000)"
    fi
fi

print_status "Verifying Webmin installation..."

# Give Webmin a moment to start
sleep 2

# Verify Webmin is running
if timeout 10 systemctl is-active --quiet webmin 2>/dev/null; then
    print_success "Webmin installation and configuration complete"
    
    print_status "Access Webmin at: https://$(hostname -I | awk '{print $1}'):10000"
    print_status "Login with your system username and password"
    print_status "Accept the self-signed SSL certificate when prompted"
    print_status "Configure additional settings through the web interface"
else
    print_warning "Webmin service may need manual start: sudo systemctl start webmin"
    print_status "Once started, access at: https://$(hostname -I | awk '{print $1}'):10000"
fi
