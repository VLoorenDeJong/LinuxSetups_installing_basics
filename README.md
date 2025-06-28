## Setting up the basics</span>

1. Check if GIT is installed -> **git version** 
1. Example GIT installed -> **git version 2.43.0**
1. Example GIT not installed -> **Command 'git' not found,**
1. If command is not found -> [Install GIT](#install_git) 
1. To confirm the internet is working type -> ping 8.8.8.8
1. If internet works you will get a respons with at the end ttl=*** time=*** ms 
1. To stop the ping actions press ->  CTRL + C
1. In you linux CLI type -> git clone https://github.com/VLoorenDeJong/LinuxSetups_Install_SSH.git
1. See if the folder is downloaded and type -> ls -al
1. To later run the install script type -> chmod X -R ~
1. if folder is downloaded go into the folder -> cd LinuxSetups_Install_SSH <br />(TIP: You can just type -> cd Li an then press TAB)
1. To see what OS & version you are runing type -> lsb_release -a
1. To see the available options type -> git branch -r
1. This will list the available branches
1. to later run the install script type -> chmod X -R ~
1. To go to your configuration type -> git checkout "YOUR_BRANCH_NO_QUOTES"




## <span id="install_git">Install GIT</span>  
1. Update the system to latest -> **sudo apt update**
1. Install git -> **sudo apt install git**
1. Enter password if prompted
1. Confirg git is installed: **git --version**
1. Example result -> **git version 2.43.0**
1. [**Configure GIT**](#configure_git) 
1. [Setting up the basics](#setting_up_the_basics) 
