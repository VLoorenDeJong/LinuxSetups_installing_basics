## 🚀 Automagic Setup for Linux Basics

These scripts automatically configure the basics for supported Linux versions.

### 🛠️ What They Do

1. Update the OS  
2. Install UFW (Uncomplicated Firewall)  
3. Install SSH  

---

## ⚙️ Usage

**Important:**  
The script requires `sudo` privileges to avoid password prompts during installation.

---

## 🐧 Supported Linux Versions

- Ubuntu 24.04.2 LTS  

---

## <span id="setting_up_the_basics">📦 Setting Up the Basics</span>

1. Log into your Linux server  
2. Check if Git is installed:  
   `git version`  
   - If installed: `git version 2.43.0`  
   - If not installed: `Command 'git' not found`  
   ➤ [Install Git](#install_git)  
3. Check internet connectivity:  
   `ping 8.8.8.8`  
   (Note: Numpad may not work in some terminals)  
   - A working connection returns: `ttl=*** time=*** ms`  
   - Stop pinging: `CTRL + C`  
   - If there's no internet, troubleshoot accordingly  

4. Clone the setup repository:  
   `git clone https://github.com/VLoorenDeJong/LinuxSetups_installing_basics`  
5. List downloaded contents:  
   `ls -al`  
6. Navigate into the folder:  
   `cd LinuxSetups_installing_basics`  
   (Tip: Use tab autocomplete: `cd Li` + `TAB`)  
7. Check OS and version:  
   `lsb_release -a`  
8. View Git branches:  
   `git branch -r`  
9. Switch to your Linux version branch:  
   `git checkout YOUR_BRANCH_NAME`  
   (No quotes or "origin/". Use autocomplete with `TAB`)  
   - Success message: `Switched to a new branch 'YOUR_BRANCH_NAME'`  

10. Make all scripts executable:  
    `sudo chmod -R +x .`  
11. Run the install script:  
    `sudo ./start_install.sh`  
    - Script runs with color indications  
    - If dpkg lock error appears ➤ [Fix dpkg Lock](#unlock_dpkg)  

---

## 🔐 Connecting via SSH (Secure Shell)

1. Download SSH client:  
   👉 [Recommended: MobaXterm](https://mobaxterm.mobatek.net/download.html)  
2. Find your local IP:  
   `ip addr show`  
   - Look for `inet` under `eth0` (e.g. `2: eth0`)  
3. Use this IP in your SSH client to connect  

---

## <span id="install_git">🐙 Install Git</span>

1. Update system packages:  
   `sudo apt update`  
2. Install Git:  
   `sudo apt install git`  
3. Enter your password if prompted  
4. Confirm installation:  
   `git --version`  
   ➤ Example: `git version 2.43.0`  
5. Go back to → [Setting Up the Basics](#setting_up_the_basics)  

---

## 🧩 <span id="common_issues">Common Issues</span>

### <span id="unlock_dpkg">🔓 Fix dpkg Lock/Frontend Issues</span>

1. Interrupt: `CTRL + C`  
2. Identify locking process ID  
3. Kill the process:  
   `sudo kill -9 <ProcessIdNumber>`  
4. Remove lock file:  
   `sudo rm /var/lib/dpkg/lock-frontend`  
5. Reconfigure dpkg:  
   `sudo dpkg --configure -a`  
6. Reboot system:  
   `sudo reboot`  
7. After reboot, update system:  
   `sudo apt update && sudo apt upgrade -y`  
8. Enter password if prompted  
9. If no lock error — Eureka! 💡  
   ➤ Continue with → [Setting Up the Basics](#setting_up_the_basics)  
