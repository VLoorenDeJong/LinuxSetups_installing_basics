## These scripts will cover the basics for the corresponding Linux versions automagicaly!
It will do the following
1. Update the OS
2. Install UFW
3. Install SSH

## Supported Linux versions
1. Ubuntu 24.04.2 LTS


## <span id="setting_up_the_basics">Setting up the basics</span>   

1. Log into your Linux server
1. Check if GIT is installed type → **git version**
1. Example GIT installed → **git version 2.43.0**
1. Example GIT not installed → **Command 'git' not found,**
1. If command is not found → [Install GIT](#install_git)
1. To confirm the internet is working type → ping 8.8.8.8 <br />
(Keep in mind numpad does not work)
1. If internet works you will get a response with at the end ttl=*** time=*** ms
1. To stop the ping actions press → CTRL + C
1. **If it does not work see how you can get your internet access working**  
---
1. In your Linux **Command Line Interface** (CLI) type → git clone https://github.com/VLoorenDeJong/LinuxSetups_installing_basics
1. See if the folder is downloaded and type → ls -al
1. If folder is downloaded go into the folder → cd LinuxSetups_installing_basics  
    (TIP: You can just type → cd Li and then press TAB)
1. To see what OS & version you are running type → lsb_release -a
1. To see the available options type → git branch -r
1. This will list the available branches
1. To go to your configuration type → git checkout "NO_QUOTES_AND_NO_ORIGIN_/_YOUR_VERSION"
1. If the branch swich is succesfull → Switched to a new branch 'YOUR_BRANCH_NAME'
1. To enable the scripts to run type → sudo chmod -R +x **.**  
1. To install the basics type → ./start_install.sh
1. This should run the scripts with color indidations
1. If message apears Simmilar to → You can wait or go to → [Unlock dpkg lock-frontend](#Unlock_dpkg/lock-frontend)


## <span id="install_git">Install GIT</span>  
1. Update the system to latest → **sudo apt update**
1. Install git → **sudo apt install git**
1. Enter password if prompted
1. Confirm git is installed: **git --version**
1. Example result → **git version 2.43.0**
1. [**Configure GIT**](#configure_git)
1. [Setting up the basics](#setting_up_the_basics)


## [Common issues](#common_issues) 
## <span id="Unlock_dpkg/lock-frontend">Fix Unlock dpkg/lock-frontend</span>  
1. CTRL + C 
1. **sudo kill -9 YourProcessIdNumber**
1. **sudo rm /var/lib/dpkg/lock-frontend**
1. **sudo dpkg --configure -a**
1. **sudo reboot**
1. Update the system -> **sudo apt update && sudo apt upgrade -y**
1. Enter the password
1. If you get a lot of text and no Lock -> **uereka go to next step ;)**
1. **Continue with** [Setting up the basics](#Setting_up_the_basics) 
