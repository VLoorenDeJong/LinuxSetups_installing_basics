# Jenkins jobs

Six pipelines. They contain no configuration of their own: everything comes
out of `/etc/hostings/hostings.conf`, and they call the scripts in
`hostings/scripts/`. Jenkins is the button, not the source of truth.

The job name is the filename after `Jenkinsfile.`, and it is subject first:
the list sorts into subjects rather than into verbs, and the name lands in a
URL, so it is lowercase with hyphens and no spaces.

| File | Job | Started by | Writes to the machine |
| --- | --- | --- | --- |
| `Jenkinsfile.hosting-check` | `hosting-check` | Nightly at 02:00 | No |
| `Jenkinsfile.hosting-apply` | `hosting-apply` | By hand, after reading the report | Yes |
| `Jenkinsfile.hosting-certificates` | `hosting-certificates` | By hand, staging by default | Yes, in `real` mode |
| `Jenkinsfile.app-deploy` | `app-deploy` | By hand, per application | Yes |
| `Jenkinsfile.machine-update` | `machine-update` | By hand, or the hosting manager | Yes. Never reboots |
| `Jenkinsfile.dns-apex` | `dns-apex` | ISPAddressChecker, over localhost | Yes, at TransIP |

## Creating them

`add_jenkins.sh` creates one job per `Jenkinsfile.*` in this folder, so adding a
pipeline here adds a job to the machine on the next run. An existing job is
never overwritten.

By hand, for each one: **New Item → Pipeline**, then under Pipeline choose
*Pipeline script from SCM*, point it at this repository, and set *Script Path*
to the file above.

**Pin the branch.** Not `*/main`, not a wildcard: the machine branch this
repository is checked out on. These jobs run scripts with root rights, so a job
that took its steps from whatever branch happened to be pushed would turn a pull
request into a way to run commands as root on this machine.

## What they need to exist first

1. **Sudo rights for the Jenkins user.** `add_jenkins_deploy_permissions.sh`
   grants them. Without it every job fails at the first `sudo`.
2. **The .NET SDK on the agent**, for the deploy job. The runtime is not enough:
   `dotnet publish` needs the SDK.
3. **Read access to each application's repository**, for the deploy job. Public
   ones need nothing. A private one needs a credential, and it should be
   read-only.

## Why applying waits for a person

`Jenkinsfile.hosting-apply` prints the drift report, then stops and asks. That pause is
the job's purpose. Applying is not the dangerous part; applying something nobody
read is. Without it, a typo saved in a form reaches production a minute later.

`--prune` is a parameter and defaults to off. It removes generated config whose
row has gone from `hostings.conf`. It never touches application data, but it
should still only be switched on by somebody who has read the orphan list.

## Why the check job going red is not a false alarm

It reports that the machine no longer matches its configuration. That divergence
IS the failure, whether or not anything looks broken yet. The alternative is
finding out during an apply, which is the worst moment.

## Why the certificate job defaults to staging

A failed validation is rate limited at five per hostname per hour, and this
config has sixteen hostnames. One run against a machine that cannot answer the
challenge locks all of them out together.

The usual cause is not in this repository: the router still forwards port 80
somewhere else. Nothing here can detect that, because every hostname resolves to
the household's public address whichever machine you are on. So the default is
the harmless mode and `real` asks first.

## Setting up the SSH key Jenkins uses

Jenkins runs as its own user and cannot read the key in the install user's home,
so it needs one of its own. A deploy key, read-only, on the one repository:

```bash
sudo -u jenkins ssh-keygen -t ed25519 -f /var/lib/jenkins/.ssh/id_ed25519 -N "" -C "jenkins@$(hostname)"
sudo ssh-keyscan -t rsa,ecdsa,ed25519 github.com | sudo tee -a /var/lib/jenkins/.ssh/known_hosts >/dev/null
sudo chown -R jenkins:jenkins /var/lib/jenkins/.ssh
sudo chmod 700 /var/lib/jenkins/.ssh
sudo cat /var/lib/jenkins/.ssh/id_ed25519.pub
```

Put that public key on the repository under Settings → Deploy keys, **without**
write access. Not under the account's own SSH keys: an account key gives Jenkins
write access to everything you own, and Jenkins runs shell out of those
repositories.

Check it before touching Jenkins:

```bash
sudo -u jenkins ssh -T git@github.com
```

`Hi <user>/<repo>!` means a deploy key. `Hi <user>!` means an account key, which
works but grants far more than intended.

In the job's credential, set Private Key to **From the Jenkins master ~/.ssh**.
Pasting the key with "Enter directly" is where `error in libcrypto` comes from:
one missing newline and the key is silently unreadable.

## This whole page is a symptom

Everything above is a list of clicks. Clicks are not reviewable, not versioned,
and not rememberable: the second machine will be configured slightly differently
from the first, and nobody will know which one is right.

The fix is Configuration as Code (the `configuration-as-code` plugin) plus a job
DSL, so the jobs, the credentials and the SSH setup are files in this folder that
the install applies. Then creating a machine's Jenkins is the same as creating
its vhosts: change a file, run a script.

Not built yet. It is the difference between a Jenkins that survives a reflash
and one that gets rebuilt from memory each time.

## A static-site job, and the submodule it replaces

Decided 2026-08-04, not urgent: the site in question is not being maintained.

Website content is currently described twice. Once as a git submodule under
`/etc/hostings/apache/www/html/`, and once as a repository URL in the ninth
column of that row in `hostings.conf`. Adding a customer site means doing both,
and nothing reports it when the two drift.

The config row is the better of the two: it also knows the branch, which
environments the site exists in, and whether it needs a login. The submodule
only knows that some files live somewhere.

The submodule predates Jenkins. Checking out a repository and putting it in the
right place is exactly what a deploy job is for, and `deploy_static_site.sh`
already exists for the second half of that.

So, in this order:

1. A `Jenkinsfile.static` that reads the row, clones the repository at the right
   branch, and calls `deploy_static_site.sh`.
2. Only then, drop the submodule. Doing it the other way round leaves a machine
   with no site content and no way to get it.

What it buys: the install stops needing access to private customer content,
which is currently a failure waiting to happen on a fresh machine, and a second
site becomes one line of config instead of a line plus a submodule.

## Not here yet

- A job for `add_dns_records.sh`. DNS management is switched off until the
  registrar's API has been driven by hand.
- Webhooks. These are all timer or manual for now; a push trigger comes once the
  jobs have proved themselves.
