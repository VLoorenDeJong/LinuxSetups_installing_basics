## 🚀 Automagic Setup for Linux Basics

These scripts automatically configure the basics for supported Linux versions.

### 🛠️ What They Do

1. Update the OS  
2. Install UFW (Uncomplicated Firewall)  
3. Install SSH  

---
## 🐧 Supported Linux Versions

- Ubuntu 24.04.2 LTS  

---
## Getting started
1. Doeload the Raspberry pi Imager software here → [Pi Imager](https://www.raspberrypi.com/software/)


## <span id="setting_up_the_basics">📦 Setting Up the Basics</span>

1. Log into your Linux server  
2. Check if Git is installed:  
   ```shell
   git version
   ```
   - If installed: `git version 2.43.0`  
   - If not installed: `Command 'git' not found`  
   ➤ [Install Git](#install_git)  
3. Check internet connectivity:  
   ```shell
   ping 8.8.8.8
   ```
   (Note: Numpad may not work in some terminals)  
   - A working connection returns: `ttl=*** time=*** ms`  
   - Stop pinging: `CTRL + C`  
   - If there's no internet, troubleshoot accordingly  

4. Clone the setup repository:  
   ```shell
   git clone https://github.com/VLoorenDeJong/LinuxSetups_installing_basics
   ```
5. List downloaded contents:  
   ```shell
   ls -al
   ```
6. Navigate into the folder:  
   ```shell
   cd LinuxSetups_installing_basics
   ```
   (Tip: Use tab autocomplete: `cd Li` + `TAB`)  
7. Check OS and version:  
   ```shell
   lsb_release -a
   ```
8. View Git branches:  
   ```shell
   git branch -r
   ```
9. Switch to your Linux version branch:  
   ```shell
   git checkout YOUR_BRANCH_NAME
   ```
   (No quotes or "origin/". Use autocomplete with `TAB`)  
   - Success message: `Switched to a new branch 'YOUR_BRANCH_NAME'`  

10. Make all scripts executable:  
    ```shell
    sudo chmod -R +x .
    ```
11. Run the main installation script with sudo privileges:
    ```shell
    sudo ./start_install.sh
    ```
**Important:**  
The script requires `sudo` privileges to avoid password prompts during installation.
    - Script runs with color indications  
    - If dpkg lock error appears ➤ [Fix dpkg Lock](#unlock_dpkg)  

---

## 🔐 Connecting via SSH (Secure Shell)

1. Download SSH client:  
   👉 [Recommended: MobaXterm](https://mobaxterm.mobatek.net/download.html)  
2. Find your local IP:  
   ```shell
   ip addr show
   ```
   - Look for `inet` under `eth0` (e.g. `2: eth0`)  
3. Use this IP in your SSH client to connect  

---

## <span id="install_git">🐙 Install Git</span>

1. Update system packages:  
   ```shell
   sudo apt update
   ```
2. Install Git:  
   ```shell
   sudo apt install git
   ```
3. Enter your password if prompted  
4. Confirm installation:  
   ```shell
   git --version
   ```
   ➤ Example: `git version 2.43.0`  
5. Go back to → [Setting Up the Basics](#setting_up_the_basics)  

---

## 🧩 <span id="common_issues">Common Issues</span>

### <span id="unlock_dpkg">🔓 Fix dpkg Lock/Frontend Issues</span>

1. Interrupt: `CTRL + C`  
2. Identify locking process ID  
3. Kill the process:  
   ```shell
   sudo kill -9 <ProcessIdNumber>
   ```
4. Remove lock file:  
   ```shell
   sudo rm /var/lib/dpkg/lock-frontend
   ```
5. Reconfigure dpkg:  
   ```shell
   sudo dpkg --configure -a
   ```
6. Reboot system:  
   ```shell
   sudo reboot
   ```
7. After reboot, update system:  
   ```shell
   sudo apt update && sudo apt upgrade -y
   ```
8. Enter password if prompted  
9. If no lock error — Eureka! 💡  
   ➤ Continue with → [Setting Up the Basics](#setting_up_the_basics)  
