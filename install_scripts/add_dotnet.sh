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

print_header "Setting up .NET (ASP.NET Core runtime)"

# =============================================================================
# WHAT THIS INSTALLS, AND WHY ONLY THE RUNTIME BY DEFAULT
# =============================================================================
# The common server case is running applications that were published
# elsewhere and copied onto the machine ("dotnet MyApp.dll", usually behind a
# reverse proxy). That needs the ASP.NET Core runtime only. The SDK is a much
# larger download and is dead weight unless the box compiles its own code,
# which matters on small ARM boards.
#
# To install the SDK instead:
#     sudo env INSTALL_DOTNET_SDK=1 ./add_dotnet.sh
# "sudo env VAR=1" is the only policy-independent way to pass a one-off
# variable through sudo — a bare "VAR=1 sudo ..." is stripped by env_reset.
#
# Packages come from the distro first. That keeps the install free of any
# third-party keyring, and avoids the "pipe a remote install script straight
# into root" pattern that .NET-on-ARM guides tend to recommend.
# =============================================================================

# Minimum acceptable .NET major version. .NET 7 reached end-of-life in
# May 2024 and receives no security patches, so 8 is the floor.
REQUIRED_DOTNET_VERSION=8

INSTALL_DOTNET_SDK="${INSTALL_DOTNET_SDK:-0}"

# .NET LTS releases are the EVEN-numbered majors (6, 8, 10, ...); odd majors
# are STS with a much shorter support window. Unlike Java there is no vendor
# API to query for this, but the cadence is fixed policy, not a guess.
is_lts_version() {
    local v="$1"
    [ $(( v % 2 )) -eq 0 ]
}

# Enumerate every aspnetcore-runtime-N.0 package apt offers and pick the
# newest LTS major among them.
get_latest_dotnet_lts() {
    local list_cmd="apt-cache pkgnames aspnetcore-runtime-"
    if $TIMEOUT_AVAILABLE; then
        list_cmd="timeout 10 $list_cmd"
    fi

    local best=""
    local v
    while read -r v; do
        [ -n "$v" ] || continue
        if is_lts_version "$v"; then
            if [ -z "$best" ] || [ "$v" -gt "$best" ]; then
                best="$v"
            fi
        fi
    done < <(eval "$list_cmd" 2>/dev/null \
        | grep -E '^aspnetcore-runtime-[0-9]+\.[0-9]+$' \
        | sed -E 's/^aspnetcore-runtime-([0-9]+)\..*$/\1/')

    echo "$best"
}

# Major version of the ASP.NET Core runtime already present, if any
get_installed_aspnet_major() {
    if ! command -v dotnet &> /dev/null; then
        return
    fi
    dotnet --list-runtimes 2>/dev/null \
        | grep '^Microsoft.AspNetCore.App' \
        | awk '{print $2}' \
        | cut -d. -f1 \
        | sort -n | tail -1
}

# --- Is a new enough runtime already installed? ------------------------------
NEED_INSTALL=true
INSTALLED_MAJOR="$(get_installed_aspnet_major)"
if [ -n "$INSTALLED_MAJOR" ]; then
    if [ "$INSTALLED_MAJOR" -ge "$REQUIRED_DOTNET_VERSION" ] 2>/dev/null; then
        print_success "ASP.NET Core runtime $INSTALLED_MAJOR is already installed"
        NEED_INSTALL=false
    else
        print_warning "Installed ASP.NET Core runtime $INSTALLED_MAJOR is older than $REQUIRED_DOTNET_VERSION (end-of-life) — upgrading"
    fi
fi

if $NEED_INSTALL; then
    print_status "Preparing to install .NET..."

    check_and_fix_dpkg_lock

    if ! show_progress "📦 Updating package lists" "sudo apt-get update -qq --fix-missing >/dev/null 2>&1" 2 180; then
        print_error "Failed to update package lists"
        exit 1
    fi

    DOTNET_VERSION="$(get_latest_dotnet_lts)"

    # If the distro cannot offer a supported LTS, fall back to Microsoft's own
    # feed — same escalation shape add_java.sh uses for Adoptium.
    if [ -z "$DOTNET_VERSION" ] || [ "$DOTNET_VERSION" -lt "$REQUIRED_DOTNET_VERSION" ] 2>/dev/null; then
        print_warning "aspnetcore-runtime-${REQUIRED_DOTNET_VERSION}.0 is not available from the distro — adding the packages.microsoft.com repository"

        . /etc/os-release
        sudo mkdir -p /etc/apt/keyrings
        if ! curl -fsSL --max-time 30 https://packages.microsoft.com/keys/microsoft.asc \
            | sudo gpg --dearmor --yes -o /etc/apt/keyrings/microsoft.gpg 2>/dev/null; then
            print_error "Could not download the Microsoft signing key — check network access"
            exit 1
        fi

        echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/microsoft.gpg] https://packages.microsoft.com/ubuntu/${VERSION_ID}/prod ${VERSION_CODENAME} main" \
            | sudo tee /etc/apt/sources.list.d/microsoft-prod.list >/dev/null

        # Ubuntu ships its own dotnet packages, and having both feeds active
        # for the same package names is a documented breakage. Pin the dotnet
        # package names to Microsoft's origin so apt cannot mix the two.
        sudo tee /etc/apt/preferences.d/99-microsoft-dotnet.pref >/dev/null <<'EOF'
Package: dotnet* aspnet* netstandard*
Pin: origin "packages.microsoft.com"
Pin-Priority: 1001
EOF

        if ! show_progress "📦 Updating package lists (Microsoft)" "sudo apt-get update -qq >/dev/null 2>&1" 2 180; then
            print_error "Failed to update package lists after adding the Microsoft repository"
            exit 1
        fi

        DOTNET_VERSION="$REQUIRED_DOTNET_VERSION"
    fi

    if [ "$INSTALL_DOTNET_SDK" = "1" ]; then
        DOTNET_PACKAGE="dotnet-sdk-${DOTNET_VERSION}.0"
        print_status "INSTALL_DOTNET_SDK=1 — installing the full SDK instead of the runtime"
    else
        DOTNET_PACKAGE="aspnetcore-runtime-${DOTNET_VERSION}.0"
    fi

    # Irreversible dpkg transaction: watch-only, never killed, and the apt
    # output is logged so a failure shows WHY instead of a bare exit code
    DOTNET_APT_LOG="/tmp/add_dotnet_apt.log"
    if ! show_progress_bar_watch_only "🌐 Installing ${DOTNET_PACKAGE} (will not be interrupted)" "$DOTNET_APT_LOG" \
        bash -c "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq -o APT::Status-Fd=1 --no-install-recommends '$DOTNET_PACKAGE' >$DOTNET_APT_LOG 2>&1"; then
        print_error "Failed to install $DOTNET_PACKAGE — apt output:"
        tail -20 "$DOTNET_APT_LOG" 2>/dev/null || true
        print_error "Full log: $DOTNET_APT_LOG"
        exit 1
    fi

    print_success ".NET packages installed successfully"
fi

# --- Configure the .NET environment ------------------------------------------
print_status "Configuring the .NET environment..."

# Opt out of the CLI telemetry ping on an unattended server. Set once in
# /etc/environment so service units inherit it too.
if ! grep -q "DOTNET_CLI_TELEMETRY_OPTOUT" /etc/environment 2>/dev/null; then
    echo 'DOTNET_CLI_TELEMETRY_OPTOUT="1"' | sudo tee -a /etc/environment > /dev/null
    print_success "DOTNET_CLI_TELEMETRY_OPTOUT set"
fi

# --- Verify ------------------------------------------------------------------
print_status "Verifying the .NET installation..."

if ! command -v dotnet &> /dev/null; then
    print_error ".NET verification failed — the dotnet binary is not on PATH"
    exit 1
fi

# Web applications need the ASP.NET Core shared framework specifically, not
# just the base runtime — check for that rather than for "dotnet exists"
if ! dotnet --list-runtimes 2>/dev/null | grep -q '^Microsoft.AspNetCore.App'; then
    print_error "The ASP.NET Core shared framework is missing — web application services will not start"
    print_error "Installed runtimes:"
    dotnet --list-runtimes 2>/dev/null || true
    exit 1
fi

FINAL_MAJOR="$(get_installed_aspnet_major)"
if [ -n "$FINAL_MAJOR" ] && [ "$FINAL_MAJOR" -lt "$REQUIRED_DOTNET_VERSION" ] 2>/dev/null; then
    print_error "ASP.NET Core runtime is $FINAL_MAJOR, which is below the required $REQUIRED_DOTNET_VERSION"
    exit 1
fi

print_success ".NET installation and configuration complete"
echo -e "\e[34m📊 SDK/Runtime: \e[0m$(dotnet --version 2>/dev/null || echo 'runtime-only install (no SDK)')"
echo -e "\e[34m🌐 ASP.NET Core: \e[0m$(dotnet --list-runtimes 2>/dev/null | grep '^Microsoft.AspNetCore.App' | tail -1)"
