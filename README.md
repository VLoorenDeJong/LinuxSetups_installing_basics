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

Out of the box it does the sensible minimum: updates the machine, switches on
the firewall, and sets up SSH so you can log in remotely. Everything else is
switched off until you ask for it → [Choosing what to install](#choosing_what_to_install)

The install happens in two rounds. The first updates the operating system and
restarts the machine; you then run the same command again and it carries on
with the rest.

## Supported Linux versions
- Ubuntu 24.04.x LTS (tested up to 24.04.3)

> ℹ️ This repo can also be consumed as a submodule (shared "basics layer") by other setup repos. Fixes to these scripts belong here.

---

## Contents

1. [Setting up the basics](#setting_up_the_basics): get it running
2. [Choosing what to install](#choosing_what_to_install): pick your options
3. [Opening an extra port later](#opening_a_port)
4. [If something goes wrong](#troubleshooting)
5. [Connecting with SSH](#connecting_with_ssh)
6. [Install Git](#install_git)

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

1. Check your OS version:
   ```shell
   lsb_release -a
   ```
   Look at the `Description` line. If it does not start with
   `Ubuntu 24.04`, stop here: these scripts are only tested on that release,
   and a different one may fail partway through an OS upgrade. There is
   nothing to check out, everything lives on the `main` branch.

1. **Pick what you want installed** → [Choosing what to install](#choosing_what_to_install),
   then come back here. Skipping this step is fine: you get an updated,
   firewalled machine with SSH, and nothing else.

1. Run the installer (no chmod needed, it sets script permissions itself):
   ```shell
   sudo bash start_install.sh
   ```
   It updates the operating system first, then restarts the machine.

1. Log back in and run the exact same command again:
   ```shell
   cd ~/LinuxSetups_installing_basics && sudo bash start_install.sh
   ```
   This time it installs the things you picked. It knows the first round is
   already done, so you cannot accidentally repeat it.

---

## <span id="choosing_what_to_install">Choosing what to install</span>

Phase 1 is on by default and gives you a working, secured machine. Phase 2 is
entirely off. You change either in one file, `start_install.sh`, and you only
ever add or remove a `#`.

Open it:

```shell
nano start_install.sh
```

There are two lists. Find them by looking for these banner comments:

| Look for this line | Around line | What it covers |
|---|---|---|
| `# PHASE 1 - get the operating system into a clean, up-to-date state.` | 151 | Updates, firewall, SSH |
| `# PHASE 2 - applications, installed on the upgraded and rebooted system.` | 171 | Java, Docker, Apache, Webmin, file sharing, backups |

In `nano` you can jump straight to a line with `CTRL + _` (underscore), then
type the number and press `ENTER`.

Every option is one line, and looks like this:

```shell
#    "add_smb.sh"                       # Shares folders over the network so Windows and Mac can open them
```

- The `#` at the **start** means "skip this". Delete it to switch the option on.
- The text after the second `#` explains what the option does. Leave it alone.

Switched on, the same line looks like this:

```shell
    "add_smb.sh"                        # Shares folders over the network so Windows and Mac can open them
```

Save and close: `CTRL + O`, `ENTER`, then `CTRL + X`.

**Two rules:**

1. **Do not reorder the lines.** Later options rely on earlier ones having run.
2. **Do not edit below** the line that reads
   `# Nothing below this line needs editing to choose what gets installed.`

Not sure what to pick? Change nothing. The defaults give you an updated,
firewalled machine you can log into remotely, which is all most servers need.
Come back and enable Phase 2 items later if you want them.

---

## <span id="opening_a_port">Opening an extra port later</span>

Each option opens the ports its own service needs, so you normally never touch
the firewall yourself. If you later run something else on this machine, a game
server for example, open its port with:

```shell
sudo bash install_scripts/manage_ufw_ports.sh open 25565/tcp "Minecraft"
```

Replace `close` for `open` to shut it again.

---

## <span id="troubleshooting">If something goes wrong</span>

An installer step can fail while the system is still busy finishing an update.
You will usually see `Could not execute systemctl` or a failed `ssh.service`
step. The installer tries to repair this by itself; if it keeps failing,
restart the machine and run it again:

```shell
sudo reboot
```

```shell
cd ~/LinuxSetups_installing_basics && sudo bash start_install.sh
```

Running it more than once is safe. Anything already installed is skipped.

Nothing enabled? The installer stops and tells you so, rather than restarting a
machine for no reason. Go back to [Choosing what to install](#choosing_what_to_install).

---

## <span id="connecting_with_ssh">Connecting with SSH</span>

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
