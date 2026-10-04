# Upstream packages

Applications written by somebody else, run here as containers and updated from
their own stable releases. Each folder is one puzzle piece; the scripts that
use them know no package names.

```
upstream/<name>/recipe.conf  (+ Dockerfile when upstream ships none)
      │
upstream_build.sh <name>             → image upstream-<name>:<version>, health-checked
upstream_promote.sh <name> <env> <v> → image upstream-<name>:<env>, rows restarted
upstream_check.sh                    → weekly: new stable release? build it, put it on test
      │
app row, Runtime upstream:<name>     → one container per row per environment
```

## recipe.conf

`KEY = value`, one per line. `MOUNT`, `ENV` and `SECRET` may repeat.

| Key | Meaning |
| --- | ------- |
| `UPSTREAM` | Their git repository |
| `RELEASE_RULE` | Where versions come from: `github-stable` (tags of `UPSTREAM`), `nuget` or `npm` (versions of `PACKAGE`). Only plain `1.2.3` or `v1.2.3` counts; anything with a suffix (`-canary.3`, `-rc1`) is a pre-release |
| `PACKAGE` | The NuGet or npm package name, for `nuget` and `npm` |
| `SOURCE` | `upstream`: build their `DOCKERFILE` at the release tag. `recipe`: build the `Dockerfile` in this folder, which receives `--build-arg VERSION=<tag>` |
| `DOCKERFILE` | Path to their Dockerfile, for `SOURCE = upstream` |
| `CONTAINER_PORT` | What the app listens on inside the container |
| `HEALTH_PATH` | Asked after a build and after a restart. Any answer below 500 is healthy |
| `HEALTH_WAIT` | Seconds to wait for that answer. Default 120 |
| `MOUNT` | `name:/path/inside`. Kept on the machine under the row's data folder, in `name` |
| `ENV` | `KEY=value` handed to the container. `{PUBLIC_URL}` becomes the row's `https://` address in that environment, `{PUBLIC_HOST}` its hostname, `{HOSTS}` the hostname plus its LAN preview address (comma-separated) |
| `SECRET` | A variable generated once per row and environment, kept in `/etc/upstream/app-<row><suffix>.env`, root only. 32 random hex characters ending `Aa1!`, so it passes the usual password rules |
| `CAPS` | Linux capabilities to give back. Every container starts with none |
| `READ_ONLY` | `yes` (default): the filesystem is read-only apart from `/tmp`, the mounts and `WRITABLE`. `no` only for an app that writes into its own install folder |
| `WRITABLE` | Space-separated paths kept in memory, emptied on restart |
| `USER` | `uid:gid` the app runs as inside, and the owner of its data folders. Empty means root inside |
| `MKDIR` | Space-separated folders to create inside the mounts, relative to the row's data folder, for an app that expects them |
| `MEMORY` | Memory cap. Default `768m` |
| `EGRESS` | `yes` lets the container open connections. Default `no`: it can only answer (`upstream_net.sh`) |

## Supply-chain guards

| Guard | Where |
| ----- | ----- |
| Only plain `x.y.z` releases, never pre-releases | every `RELEASE_RULE` |
| A release must be `UPSTREAM_COOLDOWN_DAYS` (7) old before the weekly check takes it | `upstream_check.sh` |
| Each version is pinned to its git commit, or to the sha256 of what our Dockerfile downloaded, the first time it is built; a later build that differs is refused | `upstream_build.sh`, `/var/lib/upstream/<name>/pins` |
| No capabilities, read-only filesystem, memory and process caps, no outbound connections | `add_app_services.sh`, `upstream_net.sh` |
| Health check on test before any row gets it; one-command rollback | `upstream_build.sh`, `upstream_promote.sh` |

A recipe `Dockerfile` must write the sha256 of what it downloads to
`/upstream-artifact.sha256` in the image, one line.

## Adding one

1. Make `upstream/<name>/recipe.conf`, and a `Dockerfile` beside it if they ship none.
2. `sudo bash hostings/scripts/upstream_build.sh <name>`
3. `sudo bash hostings/scripts/upstream_promote.sh <name> test <version>`
4. Add an app row with Runtime `upstream:<name>` and apply.

## Moving a site between builders

```
sudo bash hostings/scripts/upstream_transfer.sh <from-row> <from-env> <to-row> <to-env> [--name "Site name"]
```

Each piece has a `transfer.py` with two verbs, `export` (its storage → a site
bundle) and `import` (a bundle → its storage). The bundle is the common
ground: `site.json` (name, pages in order), `pages/<slug>.html` and `.css`,
`assets/`. Menus, themes and anything dynamic are not carried. Bundles are
kept in `/var/lib/upstream/transfers/`. `TRANSFER_RESTART = yes` in a recipe
restarts the target afterwards (Oqtane caches its pages).

**Switching a row's builder** in the console (Runtime `upstream:a` →
`upstream:b`) does this by itself: the console asks first, then on apply
`add_app_services.sh` exports from `a` while it still runs and the site moves
into `b` once it answers (or once `b` is promoted, if it was not built yet).
A failed export keeps the row on `a`. Each builder keeps its data in its own
subfolder of the row's (`<row data>/<package>/`), so switching back to `a`
returns to the site that was kept there, with nothing moved.
