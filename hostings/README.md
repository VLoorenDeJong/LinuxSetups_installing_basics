# hostings

A hosting stack for one Ubuntu machine, driven by one config file: Apache
vhosts and certificates per row, applications and websites deployed by
Jenkins, mail, Samba shares, and a web console to edit the config.

**Built, not yet run on a machine.** Start with `sudo ./install_hostings.sh`:
on a machine with no config it writes a blank `/etc/hostings/hostings.conf`
to fill in, then installs the modules chosen from `modules.conf`.

## Layout

| Folder | What |
| - | - |
| `scripts/` | Installers and the scripts the console and pipelines run |
| `console/` | The web console (PHP + JS) |
| `jenkins/` | The pipelines, one Jenkinsfile per job |
| `status/` | The status page |
| `upstream/` | Recipes for third-party apps built from their releases |

## Paths on the machine

| Path | What |
| - | - |
| `/etc/hostings/` | The config directory: `hostings.conf`, and the machine's own login pages and share settings |
| `/usr/local/lib/linuxbasics/` | Root-owned clone of this repository that root runs scripts from |
