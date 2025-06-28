#!/bin/bash

echo -e "\e[34m🔍 Checking for dpkg/lock-frontend issues...\e[0m"

# Function to find processes using dpkg
find_dpkg_processes() {
    local processes=$(lsof /var/lib/dpkg/lock-frontend 2>/dev/null | awk 'NR>1 {print $2}' | sort -u)
    echo "$processes"
}

# Test if we can run a quick apt check to detect lock
if timeout 5 sudo apt-get check >/dev/null 2>&1; then
    echo -e "\e[32m✅ No dpkg lock detected. System is ready for package operations.\e[0m"
    exit 0
else
    echo -e "\e[33m⚠️  dpkg lock detected. Attempting to fix...\e[0m"
fi

# Step 1: Find and kill processes using dpkg lock
echo -e "\e[34m🔄 Step 1: Finding processes using dpkg lock...\e[0m"
dpkg_processes=$(find_dpkg_processes)

if [ -n "$dpkg_processes" ]; then
    echo -e "\e[33m📋 Found processes using dpkg lock: $dpkg_processes\e[0m"
    echo -e "\e[34m🔫 Killing processes...\e[0m"
    for pid in $dpkg_processes; do
        echo -e "\e[33m  Killing process $pid\e[0m"
        sudo kill -9 "$pid" 2>/dev/null || true
    done
    sleep 2
else
    echo -e "\e[32m✅ No active processes found using dpkg lock.\e[0m"
fi

# Step 2: Remove lock files
echo -e "\e[34m🔄 Step 2: Removing dpkg lock files...\e[0m"

lock_files=(
    "/var/lib/dpkg/lock-frontend"
    "/var/lib/dpkg/lock"
    "/var/cache/apt/archives/lock"
)

for lock_file in "${lock_files[@]}"; do
    if [ -f "$lock_file" ]; then
        echo -e "\e[33m🗑️  Removing $lock_file\e[0m"
        sudo rm -f "$lock_file"
    else
        echo -e "\e[32m✅ $lock_file does not exist.\e[0m"
    fi
done

# Step 3: Configure dpkg
echo -e "\e[34m🔄 Step 3: Configuring dpkg...\e[0m"
if sudo dpkg --configure -a; then
    echo -e "\e[32m✅ dpkg configuration completed successfully.\e[0m"
else
    echo -e "\e[31m❌ dpkg configuration failed. Manual intervention may be required.\e[0m"
fi

# Step 4: Test if fix worked
echo -e "\e[34m🔄 Step 4: Testing if fix worked...\e[0m"
if timeout 10 sudo apt-get check >/dev/null 2>&1; then
    echo -e "\e[32m🎉 Success! dpkg lock issue has been resolved.\e[0m"
    echo -e "\e[32m✅ System is now ready for package operations.\e[0m"
else
    echo -e "\e[31m❌ dpkg lock issue persists. Manual intervention required.\e[0m"
    echo -e "\e[33m💡 You may need to:\e[0m"
    echo -e "\e[33m   - Check for other package managers running\e[0m"
    echo -e "\e[33m   - Restart the system manually\e[0m"
    echo -e "\e[33m   - Check disk space with 'df -h'\e[0m"
    exit 1
fi
