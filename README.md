## Linux Setup Basics

Sets up a fresh Linux server for you, so you don't have to look up a dozen
commands. You pick what you want from a list; it installs those and nothing
else.

Available to choose from:

- Updating the OS and cleaning up afterwards
- A firewall, and SSH so you can log in from another computer
- Java, Docker, Apache (web server), Webmin (admin page in your browser)
- Network file sharing, so Windows and Mac can open folders on this machine
- Backups with rsync, and a login screen showing disk and memory use

Everything starts switched off. You turn on what you need in one file — see
[Choosing what to install](#choosing_what_to_install).

The install happens in two rounds. The first updates the operating system and
restarts the machine; you then run the same command again and it carries on
with the rest.

## Supported Linux versions
- Ubuntu 24.04.x LTS (tested up to 24.04.3)

> ℹ️ This repo can also be consumed as a submodule (shared "basics layer") by other setup repos. Fixes to these scripts belong here.

---

## <span id="setting_up_the_basics">Setting up the basics</span>

1. Log into your Linux server.

1. Check if Git is installed:
   ```shell
   git version
   ```
   - Installed → `git version 2.43.0`
   - Not installed → `Command 'git' not found` → [Install Git](#install_git)

1. Confirm internet is working:
   ```shell
   ping 8.8.8.8
   ```
   Press `CTRL + C` to stop. If there is no response, fix your network first.

1. Clone the repository:
   ```shell
   git clone https://github.com/VLoorenDeJong/LinuxSetups_installing_basics
   ```

1. Enter the folder:
   ```shell
   cd LinuxSetups_installing_basics
   ```
   *(Tip: type `cd Li` then press `TAB` for autocomplete)*

1. Check your OS version, and compare it with the supported list above:
   ```shell
   lsb_release -a
   ```

1. <span id="choosing_what_to_install">**Choose what to install.**</span> Open the
   installer:
   ```shell
   nano start_install.sh
   ```
   Scroll to the two lists near the top. Every line looks like this, and the
   `#` at the front means "skip this one":
   ```shell
   #    "add_smb.sh"    # Shares folders over the network so Windows and Mac can open them
   ```
   Delete the `#` in front of the lines you want. The text after each line says
   what it does. Leave the order alone — later steps rely on earlier ones.

   Save and close with `CTRL + O`, `ENTER`, then `CTRL + X`.

1. Make scripts executable:
   ```shell
   sudo chmod -R +x .
   ```

1. Run the installer:
   ```shell
   sudo ./start_install.sh
   ```
   It updates the operating system first, then restarts the machine.

1. Log back in and run the exact same command again:
   ```shell
   cd ~/LinuxSetups_installing_basics && sudo ./start_install.sh
   ```
   This time it installs the things you picked. It knows the first round is
   already done, so you cannot accidentally repeat it.

### If something goes wrong

An installer step can fail while the system is still busy finishing an update.
You will usually see `Could not execute systemctl` or a failed `ssh.service`
step. The installer tries to repair this by itself; if it keeps failing,
restart the machine and run it again:

```shell
sudo reboot
```

```shell
cd ~/LinuxSetups_installing_basics && sudo ./start_install.sh
```

Running it more than once is safe. Anything already installed is skipped.

Nothing enabled? The installer stops and tells you so, rather than restarting a
machine for no reason. Go back to [Choosing what to install](#choosing_what_to_install).

---

## Connecting with SSH

Download an SSH client → [MobaXterm (recommended)](https://mobaxterm.mobatek.net/download.html)

Find your local IP:
```shell
ip addr show
```
Look for `inet` under `eth0` (e.g. `2: eth0: ... inet 192.168.x.x`). Use that IP in your SSH client.

---

## <span id="install_git">Install Git</span>

```shell
sudo apt update
sudo apt install git
git --version
```

→ [Back to Setting up the basics](#setting_up_the_basics) 
