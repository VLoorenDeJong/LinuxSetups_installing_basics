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

# Watch-only progress for irreversible package transactions: shows dots but
# never kills the command — a SIGKILL mid-dpkg can corrupt package state
show_progress_watch_only() {
    local message="$1"
    shift
    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local watch_pid=$!
    while kill -0 "$watch_pid" 2>/dev/null; do
        echo -n "."
        # If sleep itself fails (e.g. filesystem died), bail instead of
        # spinning and flooding the terminal with error lines
        sleep 3 || { printf "\n\e[31m❌ Progress loop aborted — sleep failed (filesystem trouble?)\e[0m\n"; break; }
    done
    echo
    wait "$watch_pid"
    return $?
}

# Watch-only spinner + progress bar: never kills the wrapped command (same
# regime as show_progress_watch_only), but renders a live bar from apt's
# machine-readable status lines ("pmstatus:...:PCT:desc" / "dlstatus:...")
# that land in the log when apt-get runs with -o APT::Status-Fd=1.
show_progress_bar_watch_only() {
    local message="$1"
    local logfile="$2"
    shift 2

    local spinner=('⠋' '⠙' '⠹' '⠸' '⠼' '⠴' '⠦' '⠧' '⠇' '⠏')
    local width=28
    local empty_bar full_bar
    empty_bar=$(printf '░%.0s' $(seq 1 $width))
    full_bar=$(printf '█%.0s' $(seq 1 $width))

    echo -e "\e[34m${message}\e[0m"
    "$@" &
    local cmd_pid=$!
    local tick=0

    while kill -0 "$cmd_pid" 2>/dev/null; do
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

    wait "$cmd_pid"
    local exit_code=$?
    printf '\r\033[K'  # Clear the bar line before normal output resumes
    return $exit_code
}

# Check if timeout command is available
if ! command -v timeout &> /dev/null; then
    echo -e "\e[33m⚠️  timeout command not available, using direct commands\e[0m"
    TIMEOUT_AVAILABLE=false
else
    TIMEOUT_AVAILABLE=true
fi

# Function to check for DPKG lock issues (calls the dedicated script)
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

echo -e "\e[34m🔍 Setting up Java (OpenJDK)...\e[0m"

# Function to check if Java is already installed
check_java_installation() {
    if command -v java &> /dev/null; then
        local java_version=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}')
        echo -e "\e[32m✅ Java is already installed: $java_version\e[0m"
        return 0
    else
        return 1
    fi
}

# Function to get the latest available OpenJDK LTS version
# Enumerates every openjdk-N-jdk package apt offers and picks the newest LTS.
# LTS detection: authoritative list from the Adoptium API when reachable,
# falling back to the release-cadence formula (8, 11, then every 4th release
# from 17: 17, 21, 25, 29, ...) when offline, so the script keeps working
# without network access and picks up future LTS versions automatically.
get_latest_openjdk() {
    local list_cmd="apt-cache pkgnames openjdk-"
    if $TIMEOUT_AVAILABLE; then
        list_cmd="timeout 10 $list_cmd"
    fi

    # Try to fetch the authoritative LTS list from the Adoptium API
    # (e.g. "available_lts_releases": [8, 11, 17, 21, 25])
    local adoptium_lts=""
    if command -v curl >/dev/null 2>&1; then
        # tr flattens the pretty-printed JSON onto one line so grep can match the array
        adoptium_lts=$(curl -fsSL --max-time 10 "https://api.adoptium.net/v3/info/available_releases" 2>/dev/null \
            | tr -d '[:space:]' \
            | grep -oE '"available_lts_releases":\[[^]]*\]' \
            | grep -oE '[0-9]+')
    fi

    is_lts_version() {
        local v="$1"
        if [ -n "$adoptium_lts" ]; then
            printf '%s\n' "$adoptium_lts" | grep -qx "$v"
        else
            # Offline fallback: LTS releases are 8, 11, and every 4th from 17
            [ "$v" = "8" ] || [ "$v" = "11" ] || { [ "$v" -ge 17 ] && [ $(( (v - 17) % 4 )) -eq 0 ]; }
        fi
    }

    local best=""
    local v
    while read -r v; do
        [ -n "$v" ] || continue
        if is_lts_version "$v"; then
            if [ -z "$best" ] || [ "$v" -gt "$best" ]; then
                best="$v"
            fi
        fi
    done < <(eval "$list_cmd" 2>/dev/null | grep -E '^openjdk-[0-9]+-jdk$' | grep -oE '[0-9]+')

    if [ -n "$best" ]; then
        echo "$best"
    else
        # Fallback if apt enumeration fails entirely
        echo "${REQUIRED_JAVA_VERSION:-21}"
    fi
}

# Minecraft 26.1+ requires Java 25 — treat that as the minimum acceptable version
REQUIRED_JAVA_VERSION=25

# Function to get the major version of the currently installed Java
get_installed_java_major() {
    local major
    major=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}' | cut -d. -f1)
    if [ "$major" = "1" ]; then
        # Handle Java 8 version format (1.8.x)
        major=$(java -version 2>&1 | head -n 1 | awk -F '"' '{print $2}' | cut -d. -f2)
    fi
    echo "$major"
}

# Check if Java is already installed and new enough
NEED_INSTALL=true
INSTALLED_MAJOR=""
if check_java_installation; then
    INSTALLED_MAJOR=$(get_installed_java_major)
    if [ -n "$INSTALLED_MAJOR" ] && [ "$INSTALLED_MAJOR" -ge "$REQUIRED_JAVA_VERSION" ] 2>/dev/null; then
        NEED_INSTALL=false
    else
        print_warning "Installed Java $INSTALLED_MAJOR is older than Java $REQUIRED_JAVA_VERSION (required by Minecraft 26.1+) — upgrading"
    fi
fi

if $NEED_INSTALL; then
    echo -e "\e[34m🔧 Preparing to install Java...\e[0m"
    
    # Check and fix DPKG locks before proceeding
    check_and_fix_dpkg_lock
    
    # Update package list
    if ! show_progress "📦 Updating package lists" "sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
        echo -e "\e[31m❌ Failed to update package lists\e[0m"
        exit 1
    fi
    
    # Get the latest available OpenJDK LTS version
    JAVA_VERSION=$(get_latest_openjdk)

    # If the distro can't offer the required Java version, add the Adoptium
    # (Temurin) repository — it serves every Debian-family distro identically,
    # which keeps this script distro-neutral (Ubuntu, Raspberry Pi OS, Debian)
    if [ "$JAVA_VERSION" -lt "$REQUIRED_JAVA_VERSION" ] 2>/dev/null; then
        print_warning "openjdk-${REQUIRED_JAVA_VERSION} is not available from the distro — adding the Adoptium (Temurin) repository"
        CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
        sudo mkdir -p /etc/apt/keyrings
        if ! curl -fsSL --max-time 30 https://packages.adoptium.net/artifactory/api/gpg/key/public \
            | sudo gpg --dearmor --yes -o /etc/apt/keyrings/adoptium.gpg 2>/dev/null; then
            print_error "Could not download the Adoptium signing key — check network access"
            exit 1
        fi
        echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb $CODENAME main" \
            | sudo tee /etc/apt/sources.list.d/adoptium.list >/dev/null
        if ! show_progress "📦 Updating package lists (Adoptium)" "sudo apt-get update -qq >/dev/null 2>&1" 2 180; then
            print_error "Failed to update package lists after adding the Adoptium repository"
            exit 1
        fi
        JAVA_PACKAGE="temurin-${REQUIRED_JAVA_VERSION}-jdk"
        JAVA_VERSION="$REQUIRED_JAVA_VERSION"
    else
        JAVA_PACKAGE="openjdk-${JAVA_VERSION}-jdk"
    fi

    echo -e "\e[34m🔧 Installing Java ${JAVA_VERSION} LTS ($JAVA_PACKAGE)...\e[0m"

    # Install the JDK — irreversible dpkg transaction: watch-only, never killed,
    # and log the apt output so a failure shows WHY instead of a bare error
    JAVA_APT_LOG="/tmp/add_java_apt.log"
    if ! show_progress_bar_watch_only "☕ Installing Java ${JAVA_VERSION} JDK (will not be interrupted)" "$JAVA_APT_LOG" \
        bash -c "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends '$JAVA_PACKAGE' >$JAVA_APT_LOG 2>&1"; then
        echo -e "\e[31m❌ Failed to install $JAVA_PACKAGE — apt output:\e[0m"
        tail -10 "$JAVA_APT_LOG" 2>/dev/null || true
        exit 1
    fi

    # Also install the separate JRE package (OpenJDK only — Temurin's JDK
    # package already contains the runtime)
    if [[ "$JAVA_PACKAGE" == openjdk-* ]] && ! dpkg -s "openjdk-${JAVA_VERSION}-jre" &> /dev/null; then
        show_progress_bar_watch_only "☕ Installing Java Runtime Environment (will not be interrupted)" "$JAVA_APT_LOG" \
            bash -c "sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends 'openjdk-${JAVA_VERSION}-jre' >>$JAVA_APT_LOG 2>&1" || true
    fi

    echo -e "\e[32m✅ Java packages installed successfully\e[0m"
fi

echo -e "\e[34m🔧 Configuring Java environment...\e[0m"

# Resolve the real JVM home from the java binary itself — works for both
# OpenJDK and Temurin layouts instead of hardcoding the OpenJDK path
JAVA_HOME_PATH=""
if command -v java &> /dev/null; then
    JAVA_HOME_PATH="$(readlink -f "$(command -v java)" | sed 's|/bin/java$||')"
fi

# Configure default Java version if multiple versions exist
if command -v update-alternatives &> /dev/null && [ -d "$JAVA_HOME_PATH" ]; then
    echo -e "\e[34m🔄 Setting up Java alternatives...\e[0m"
    sudo update-alternatives --install /usr/bin/java java "$JAVA_HOME_PATH/bin/java" 100 &>/dev/null || true
    sudo update-alternatives --install /usr/bin/javac javac "$JAVA_HOME_PATH/bin/javac" 100 &>/dev/null || true
    echo -e "\e[32m✅ Java alternatives configured\e[0m"
fi

# Set JAVA_HOME environment variable
echo -e "\e[34m🔄 Configuring JAVA_HOME...\e[0m"

if [ -d "$JAVA_HOME_PATH" ]; then
    # Add JAVA_HOME to /etc/environment if not already present
    if ! grep -q "JAVA_HOME" /etc/environment 2>/dev/null; then
        echo "JAVA_HOME=\"$JAVA_HOME_PATH\"" | sudo tee -a /etc/environment > /dev/null
    else
        # Update existing JAVA_HOME
        sudo sed -i "s|^JAVA_HOME=.*|JAVA_HOME=\"$JAVA_HOME_PATH\"|" /etc/environment
    fi
    
    # Set for current session
    export JAVA_HOME="$JAVA_HOME_PATH"
    export PATH="$JAVA_HOME/bin:$PATH"
    echo -e "\e[32m✅ JAVA_HOME configured\e[0m"
fi

echo -e "\e[34m🔄 Verifying Java installation...\e[0m"

# Verify installation
if ! command -v java &> /dev/null || ! command -v javac &> /dev/null; then
    echo -e "\e[31m❌ Java verification failed - check installation manually\e[0m"
    exit 1
fi

echo -e "\e[32m✅ Java installation and configuration complete\e[0m"
echo -e "\e[34m📊 Version: \e[0m$(java -version 2>&1 | head -n 1)"
echo -e "\e[34m🌍 JAVA_HOME: \e[0m${JAVA_HOME:-'Available in new sessions'}"