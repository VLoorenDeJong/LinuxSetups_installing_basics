## Linux Setup Basics

Automatically installs the essentials on supported Linux versions:

1. Update the OS
2. Install UFW (firewall)
3. Install SSH
4. Reboot (optional)

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

1. Check your OS version:
   ```shell
   lsb_release -a
   ```

1. List available branches:
   ```shell
   git branch -r
   ```

1. Switch to your version branch:
   ```shell
   git checkout YOUR_BRANCH_NAME
   ```
   *(No quotes, no `origin/`. Use `TAB` for autocomplete)*
   Success: `Switched to a new branch 'YOUR_BRANCH_NAME'`

1. Make scripts executable:
   ```shell
   sudo chmod -R +x .
   ```

1. Run the installer:
   ```shell
   sudo ./start_install.sh
   ```
   The installer automatically handles dpkg lock issues, updates, UFW, and SSH setup.

If the run fails partway — package upgrades (kernel, `openssh-server`, etc.) can leave
`dpkg` half-configured mid-run, usually showing up as `Could not execute systemctl` or a
failed `ssh.service` step. `fix_dpkg_lock.sh` retries the repair automatically, but some
states only clear with a reboot:
   ```shell
   sudo reboot
   ```

After reboot, log back in and run it again:
   ```shell
   cd ~/LinuxSetups_installing_basics && sudo chmod -R +x . && sudo ./start_install.sh
   ```
   Every script here is safe to rerun — steps already applied are skipped or no-op.

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
