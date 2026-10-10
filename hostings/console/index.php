<?php
// =============================================================================
// The hosting manager: edit hostings.conf in a browser, without VS Code and
// without SSH.
//
// THIS PAGE HOLDS NO CREDENTIAL.
//
// It runs as hosting-manager, in a PHP pool of its own, never as www-data. It
// cannot push to GitHub, cannot read the Jenkins token or the TransIP key, and
// cannot restart anything. It writes a candidate file to a staging path and
// calls four fixed commands through sudo, none of which take an argument:
//
//   publish_hostings.sh   validate, commit, push. Changes nothing here.
//   check_hostings.sh     read-only. Writes the drift report this page shows.
//   trigger_apply.sh      the one that changes the machine.
//   trigger_update.sh     operating system updates, through Jenkins.
//
// No arguments, because sudo matches a literal command and a wildcard would let
// the caller control the rest of the argument list. There is nothing to smuggle
// in.
//
// SAVING IS NOT APPLYING, and that is a decision rather than an oversight
// (hostings-console-decisions.md, 2026-08-02). Saving pushes a validated
// config; the operator reads the drift report and presses Apply. Applying on
// save would let a typo in a browser reach the sites a minute later, and a
// report is worth nothing once the change has already happened.
//
// The login in front of this page is Apache's, from hostings.conf. There is no
// second password here, because a second one is a second thing to get wrong.
// =============================================================================

// The file in force, asked of config.sh so the page and the scripts share one rule.
define('CONF', (function () {
    $dir = '/etc/hostings';
    $out = trim((string) @shell_exec('bash -c '
        . escapeshellarg('. /usr/local/lib/linuxbasics/hostings/scripts/config.sh && conf_active "$0"')
        . ' ' . escapeshellarg($dir) . ' 2>/dev/null'));
    return $out !== '' ? $out : $dir . '/hostings.conf';
})());
const STAGING    = '/var/lib/hosting-manager/hostings.conf.candidate';
const BASEHASH    = '/var/lib/hosting-manager/candidate.base';
const REPORT      = '/var/lib/hosting-manager/last-check.txt';
const LASTSAVE    = '/var/lib/hosting-manager/last-save.txt';
// One file per change in progress, so every other open page can say something
// is going on. The owner, 2026-09-18. Created by add_hosting_manager.sh.
const WORKDIR     = '/var/lib/hosting-manager/work';
// One entry per step of the last create, written by provision_repo.sh. The
// point of it is a create that stopped halfway: the operator gets the step
// rather than a red line and a log to scroll.
const LASTCREATE  = '/var/lib/hosting-manager/last-create.json';
// One entry per generator the last apply ran, written by maintain_services.sh.
// The apply dialog shows Jenkins' raw log, which answers "what happened" only
// if you read all of it; this answers "which part stopped" at a glance.
const LASTAPPLY   = '/var/lib/hosting-manager/last-apply.json';
const PUBLISH     = '/usr/local/sbin/publish_hostings.sh';
const CHECK       = '/usr/local/sbin/check_hostings.sh';
const APPLY       = '/usr/local/sbin/trigger_apply.sh';
// Without Jenkins, trigger_apply.sh runs the apply as the unit hosting-apply.
define('WATCH_APPLY', is_dir('/var/lib/jenkins') ? 'Watch it in Jenkins.' : 'Follow it on the machine: journalctl -u hosting-apply -f');
const FASTAPPLY   = '/usr/local/sbin/apply_config_only.sh';
const GOLIVE      = '/usr/local/sbin/go_live.sh';
const UPDATE      = '/usr/local/sbin/trigger_update.sh';
const REBOOT      = '/usr/local/sbin/reboot_machine.sh';
const PROVISION   = '/usr/local/sbin/provision_repo.sh';
const READAUDIT   = '/usr/local/sbin/read_audit.sh';
const UPGATE      = '/usr/local/sbin/upstream_gate.sh';
const DOMAINS     = '/usr/local/sbin/fetch_domains.sh';
const DOMAINFILE  = '/var/lib/hosting-manager/owned-domains';
const JOBSTATUS   = '/usr/local/sbin/jenkins_job_status.sh';
const JOBLOG      = '/usr/local/sbin/jenkins_job_log.sh';
const PROMOTE     = '/usr/local/sbin/promote_certificate.sh';
const SITEJOB     = '/usr/local/sbin/trigger_site_job.sh';
// What is deployed for a row and environment, and whether its branch has moved.
const DEPLOYEDSHA = '/usr/local/sbin/deployed_commit.sh';
// Everybody who may sign in, anywhere on this machine.
const AUTHUSERS   = '/usr/local/sbin/manage_auth_users.sh';
const LOGIN_STORE_STATUS = '/var/lib/hostings-login-store/status';
// What customers have asked for, and what was said back.
const REQUESTS    = '/usr/local/sbin/manage_requests.sh';
const CHECKDOMAIN = '/usr/local/sbin/check_domain_available.sh';
const DNSIFACE    = '/usr/local/lib/linuxbasics/hostings/scripts/dns.sh';
// The settings a row's application reads, out of its repository.
const READSETTINGS = '/usr/local/sbin/read_appsettings.sh';
const MAILSET     = '/usr/local/sbin/app_mail_settings.sh';
// What to type into Outlook or a phone. Read off Dovecot and Postfix rather
// than out of the config, because a configured port and a listening port are
// different facts and only one of them answers.
const MAILCLIENT  = '/usr/local/sbin/mail_client_settings.sh';
const SVCCTL      = '/usr/local/sbin/app_service_control.sh';
// The published machine state. A const rather than the $statusFile variable it
// used to be: that was assigned near the bottom of this file, where the page is
// built, and the ?ask=status endpoint up here read it 1800 lines earlier. So
// the live poll answered {"ok":false} on EVERY call and warned into the error
// log each time, which is why the page never followed the machine. Measured
// 2026-09-09 from hosting-manager-error.log.
const STATUSFILE  = '/run/hosting-status/status.json';
const MAILPW      = '/usr/local/sbin/set_mail_password.sh';
const PERSONENTRY = '/usr/local/sbin/person_entry.sh';
const LISTREPOS   = '/usr/local/sbin/list_repo_names.sh';
const LISTPROJECTS = '/usr/local/sbin/list_startup_projects.sh';
// The branches in one repository, for the drawer's Source branch dropdown.
const LISTBRANCHES = '/usr/local/sbin/list_repo_branches.sh';

// Samba. Read from the same clone as hostings.conf, because /etc/samba/smb.conf
// is a symlink into the deploy account's home and www-data cannot traverse it.
const SMBCONF     = '/etc/hostings/smb/smb.conf';
const SMBSTAGING  = '/var/lib/hosting-manager/smb.conf.candidate';
const SMBBASEHASH = '/var/lib/hosting-manager/smb.candidate.base';
const PUBSMB      = '/usr/local/sbin/publish_smb.sh';
// The repair half of the publisher: fast-forward the tree /etc/samba/smb.conf
// points at, validate it, reload. It writes no config and pushes nothing, so
// the worst it can do is leave Samba exactly as it was.
const RELOADSMB   = '/usr/local/sbin/reload_samba.sh';
const LISTDIRS    = '/usr/local/sbin/list_folders.sh';
const SHAREACL    = '/usr/local/sbin/set_share_access.sh';
const SHAREWIN    = '/usr/local/sbin/share_window.sh';
const SHAREWIN_MINUTES = ['5' => '5 minutes', '10' => '10 minutes', '15' => '15 minutes',
                          '60' => '1 hour', '120' => '2 hours', '240' => '4 hours'];
const MANAGEMAIL  = '/usr/local/sbin/manage_mail.sh';
const MANAGEREPO  = '/usr/local/sbin/manage_repo.sh';

// The group a share's folder is opened to. www-data, because that is the group
// every share in this file already forces, so a folder opened for one share is
// opened for the mechanism all of them use.
const SMB_SHARE_GROUP = 'www-data';

// Sections this page will not touch. [global] is the server, and the two
// printer shares are Windows driver plumbing rather than a folder anyone would
// edit. [homes] is Samba's own per-user share, if it ever appears.
const SMB_RESERVED = ['global', 'printers', 'print$', 'homes'];

// A styles or script file beside this one, stamped with its own mtime. A
// deploy therefore invalidates exactly the files it replaced, and a browser
// keeps serving the rest from its cache.
function asset(string $name): string {
    $stamp = @filemtime(__DIR__ . "/" . $name) ?: 0;
    return htmlspecialchars($name . "?v=" . $stamp, ENT_QUOTES);
}

$message = '';
$messageClass = '';
$output = '';
$outputSummary = '';
$autoConfirm = false;
$startedJob = false;
$startedApply = false;
$rebooting = false;
// -1 means the baseline could not be read. The dialog then falls back to
// watching for the job to appear rather than comparing build numbers.
$applyFrom = -1;

// Set when the publisher refused. It means the edit that was just made is gone,
// which is worth a dialog rather than a line among the others.
$publishRefused = false;
// A refusal changed nothing; any other failure may have changed some of it, and
// saying the wrong one is worse than saying neither.
$failureChangedNothing = true;
$failedAction = '';
$failedWhen   = '';
$failedSteps  = [];

// The steps of the last create, or [] when there has never been one. Read on
// every load: it is a small file and the alternative is deciding when it is
// stale, which is how last-check.txt grew a whole banner of its own.
$createSteps = [];
$createRow   = '';
$createWhen  = '';
$createFailed = false;
$lastCreate = @json_decode((string) @file_get_contents(LASTCREATE), true);
if (is_array($lastCreate) && is_array($lastCreate['steps'] ?? null)) {
    $createSteps = $lastCreate['steps'];
    $createRow   = (string) ($lastCreate['row'] ?? '');
    $createWhen  = (string) ($lastCreate['when'] ?? '');
    foreach ($createSteps as $s) {
        if (($s['state'] ?? '') === 'failed') { $createFailed = true; }
    }

}

// The same for the apply. maintain_services.sh writes it whether the run
// succeeded or stopped in the middle, and the second is the case worth having.
$applySteps  = [];
$applyWhen   = '';
$applyFailed = false;
$lastApply = @json_decode((string) @file_get_contents(LASTAPPLY), true);
if (is_array($lastApply) && is_array($lastApply['steps'] ?? null)) {
    $applySteps = $lastApply['steps'];
    $applyWhen  = (string) ($lastApply['when'] ?? '');
    foreach ($applySteps as $s) {
        if (($s['state'] ?? '') === 'failed') { $applyFailed = true; }
    }
}

// Which jobs are running, so a button whose job is still going can be greyed
// out instead of inviting a second press. Asked on load and then every few
// seconds while something is running: starting a job is a POST that returns at
// once, so nothing else on this page knows when the work actually ends.

// CSRF: a POST from another site's page is refused. Firefox sends the session
// cookie cross-site unless SameSite says otherwise, so this is the second lock.
function originHost(string $origin): string {
    $port = parse_url($origin, PHP_URL_PORT);
    return (string) parse_url($origin, PHP_URL_HOST) . ($port ? ':' . $port : '');
}
if ($_SERVER['REQUEST_METHOD'] === 'POST' && isset($_SERVER['HTTP_ORIGIN'])
    && originHost($_SERVER['HTTP_ORIGIN']) !== ($_SERVER['HTTP_HOST'] ?? '')) {
    http_response_code(403);
    exit('Refused: this request came from another site.');
}

// WHO IS SIGNED IN, AND WHAT THEY MAY DO. Item 107.
//
// REMOTE_USER is set by the form login in front of this page, verified on the
// machine 2026-09-10: a probe answered {"REMOTE_USER":"admin","AUTH_TYPE":"form"}.
//
// The role is asked of the script rather than read out of a file here, so there
// is ONE place that decides what a name means. A name with no line is 'admin',
// the limited role, and that is what an empty answer falls back to as well: an
// unreadable side file must never widen what somebody may do.
$me = (string) ($_SERVER['REMOTE_USER'] ?? $_SERVER['REDIRECT_REMOTE_USER'] ?? '');
$myRole = 'admin';
if (preg_match('/^[A-Za-z0-9._-]+$/', $me)) {
    $rLines = [];
    exec('sudo ' . AUTHUSERS . ' --role-of ' . escapeshellarg($me) . ' 2>/dev/null', $rLines, $rRc);
    $rRole = trim(implode('', $rLines));
    $myRole = ($rRc === 0 && $rRole === 'full') ? 'full' : 'admin';
}

// THE AUDIT TRAIL. Every POST is a change somebody asked for, so each leaves
// one journal line: who, what, on which row, and how it ended. Read back by
// read_audit.sh for the Audit tab. Only identifier fields are logged: never a
// password, the config text, or anything typed as free text.
const AUDIT_FIELDS = ['row', 'env', 'verb', 'host', 'id', 'name', 'role', 'rerunstep'];
function auditId($v): string {
    return substr((string) preg_replace('/[^A-Za-z0-9._:@\/+-]/', '', (string) $v), 0, 80);
}
if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    ob_start();
    $workFile = WORKDIR . '/' . getmypid() . '-' . bin2hex(random_bytes(4)) . '.json';
    if (!@file_put_contents($workFile, json_encode([
        'user'   => auditId($me),
        'action' => auditId($_POST['action'] ?? ''),
        'row'    => auditId($_POST['row'] ?? ''),
        'since'  => time(),
    ]))) {
        $workFile = '';
    }
    register_shutdown_function(function () use ($me, $workFile) {
        if ($workFile !== '') @unlink($workFile);
        $body = (string) ob_get_contents();
        $json = json_decode($body, true);
        $class = $GLOBALS['messageClass'] ?? null;
        if (http_response_code() === 403) {
            $result = 'refused';
        } elseif (is_array($json) && array_key_exists('ok', $json)) {
            $result = $json['ok'] ? 'ok' : 'failed';
        } elseif ($class !== null) {
            $result = $class === 'good' ? 'ok' : 'failed';
        } else {
            $result = 'done';
        }

        $target = [];
        foreach (AUDIT_FIELDS as $f) {
            if (isset($_POST[$f]) && is_scalar($_POST[$f]) && auditId($_POST[$f]) !== '') {
                $target[$f] = auditId($_POST[$f]);
            }
        }
        foreach (['mailops', 'repoops'] as $f) {
            $ops = json_decode((string) ($_POST[$f] ?? ''), true);
            if (!is_array($ops)) continue;
            foreach ($ops as $op) {
                if (!is_array($op)) continue;
                $what = isset($op['slug']) ? $op['slug']
                      : (($op['local'] ?? '') . '@' . ($op['domain'] ?? ''));
                $target[$f][] = auditId($op['verb'] ?? '') . ' ' . auditId($what);
            }
        }

        openlog('hosting-manager', LOG_PID, LOG_USER);
        syslog(LOG_NOTICE, json_encode([
            'user'   => auditId($me) !== '' ? auditId($me) : 'unknown',
            'action' => auditId($_POST['action'] ?? ''),
            'target' => $target,
            'result' => $result,
        ], JSON_UNESCAPED_SLASHES));
        closelog();
    });
}

// NO ROLE, NO CONSOLE. The owner, 2026-09-10: the page is for people who hold a
// role, and holding a password on this machine is not one.
//
// Every account in the password file exists for something else as well: a
// protected vhost, a LAN preview, an SMB share. Treating any of them as a
// console login was the wrong default, and this is the deny-by-default half of
// the RBAC the roles describe.
//
// Refused HERE rather than only in the vhost, because a role taken away must
// stop working at once. The vhost's Require list is the hard gate and is
// rewritten by the apply; this one needs no reload.
if ($myRole !== 'full' && $myRole !== 'admin') {
    http_response_code(403);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    echo '<!doctype html><meta charset="utf-8">'
       . '<title>Not for this account</title>'
       . '<style>body{font:16px system-ui;margin:3rem auto;max-width:34rem;padding:0 1rem}'
       . 'code{background:#eee;padding:.1rem .3rem;border-radius:3px}</style>'
       . '<h1>Not for this account</h1>'
       . '<p><code>' . htmlspecialchars($me, ENT_QUOTES) . '</code> can sign in on this '
       . 'machine, but has no role on this page, so there is nothing here for it.</p>'
       . '<p>Somebody with full access can give it one from the Users tab.</p>';
    exit;
}

// The second factor: nothing below answers until it has passed.
require __DIR__ . '/second_factor.php';

// KICKED: signed out once. The owner, 2026-09-18. The session lives in the
// browser's cookie, so it cannot be deleted here. Every request from that name
// is refused for KICK_SECS, long enough to catch the five-second poll of every
// page they have open; after that, signing in again works as normal. One
// refusal was not enough: a background request used it up, and the cookie
// survived it.
const KICK_SECS = 15;
$kickFile = WORKDIR . '/' . auditId($me) . '.kick';
if ($me !== '' && is_file($kickFile)
    && time() - (int) @file_get_contents($kickFile) > KICK_SECS) {
    @unlink($kickFile);
}
if ($me !== '' && is_file($kickFile)) {
    @unlink(WORKDIR . '/' . auditId($me) . '.seen');
    setcookie('manager_http', '', ['expires' => 1, 'path' => '/', 'httponly' => true]);
    header('Cache-Control: no-store');
    if (isset($_GET['ask']) || str_contains((string) ($_SERVER['HTTP_ACCEPT'] ?? ''), 'json')) {
        http_response_code(401);
        header('Content-Type: application/json');
        echo json_encode(['ok' => false, 'kicked' => true, 'out' => 'Signed out by a full access admin.']);
    } else {
        header('Location: /login.html');
    }
    exit;
}

// Sent here by a gated tool's vhost: the factor has passed, so hand the pass on.
if (isset($_GET['tfa-for'])) gate_handoff($me);

// Who has a page open: every page asks for ?ask=status every five seconds, so
// a name seen in the last 90 is somebody with the console in front of them.
function onlineUsers(): array {
    $out = [];
    foreach (glob(WORKDIR . '/*.seen') ?: [] as $f) {
        $age = time() - (int) @filemtime($f);
        if ($age > 90) continue;
        $out[] = ['user' => basename($f, '.seen'), 'secs' => $age];
    }
    return $out;
}

// WHAT A LIMITED ADMIN IS ALLOWED TO HAVE CHANGED. Item 106.
//
// A save posts the WHOLE config, for everybody, which is what makes the page
// simple: one flow, and the drawer decides which fields it offers. This is the
// backstop that makes that safe, because a field the page does not offer is
// still a field a POST can carry.
//
// It compares what arrived against the live file, ROW BY ROW, and allows only:
//   - a changed free field on a row they own
//   - a row of theirs disappearing, which is a delete
// Everything else, including a row appearing, a row of somebody else's moving,
// and any settings line outside the rows, is refused and named.
//
// The free list is the same one drawer.js gates on, written out here rather
// than shared: two copies that must agree is worse than one, and a copy in PHP
// that cannot be edited from a browser is the one that decides.
const FREE_FIELDS = [3, 6, 7, 9, 10, 12, 13, 14];

function rowsByName(string $text): array {
    $out = [];
    foreach (configRows($text) as $f) $out[$f[1]] = $f;
    return $out;
}

// ONE DOMAIN, ONE ADMIN. The owner, 2026-09-16.
//
// A customer owns a domain when a row of theirs serves it whole (`=shop.nl`,
// or `=www.shop.nl` under a DNS_DOMAINS entry). A label under BASE_DOMAIN makes
// nobody its owner: those customers never get a login. A MAILBOX belongs to
// whoever owns its domain, and its own Owner field is not read.
function ownership(string $text): array {
    $base = (string) (conf_val($text, 'BASE_DOMAIN') ?: 'example.com');
    $known = array_values(array_filter(array_map('trim',
        explode(',', (string) conf_val($text, 'DNS_DOMAINS')))));
    // A domain nobody owns falls back to the admin, so its mailboxes still
    // reach an entry in the vault. The owner, 2026-09-20: "for now lets set
    // missing to admin". person_entry.sh's mailbox_owners does the same.
    $own = ['base' => $base, 'known' => $known, 'owners' => [], 'conflict' => '',
            'admin' => (string) (conf_val($text, 'AUTH_ADMIN_USER') ?: 'admin')];
    foreach (explode("\n", str_replace("\r\n", "\n", $text)) as $line) {
        if (preg_match('/^\s*#/', $line) || strpos($line, '|') === false) continue;
        if (preg_match('/^\s*(PANEL|SHARE)\s*=/', $line)) continue;
        $f = array_map('trim', explode('|', $line));
        if (strtolower($f[0]) === 'mailbox') continue;
        $who = $f[15] ?? '';
        $dom = rowDomain($f, $own);
        if ($who === '' || $who === '-' || $dom === '' || $dom === $base) continue;
        $had = $own['owners'][$dom] ?? '';
        if ($had !== '' && $had !== $who && $own['conflict'] === '') {
            $own['conflict'] = "'" . $dom . "' already belongs to '" . $had
                             . "', so it cannot also belong to '" . $who . "'.";
        }
        if ($had === '') $own['owners'][$dom] = $who;
    }
    return $own;
}

// The mail domain a row lives on: '' for a row that publishes nothing.
function rowDomain(array $f, array $own): string {
    $d = trim($f[4] ?? '');
    if (strtolower(trim($f[0] ?? '')) === 'mailbox') {
        $d = ltrim($d, '=');
        return ($d === '' || $d === '-') ? $own['base'] : $d;
    }
    if ($d === '' || $d === '-') return '';
    if ($d[0] !== '=') return $own['base'];
    $whole = substr($d, 1);
    foreach ($own['known'] as $k) {
        if ($whole === $k || str_ends_with($whole, '.' . $k)) return $k;
    }
    return $whole;
}

function rowOwner(array $f, array $own): string {
    if (strtolower(trim($f[0] ?? '')) === 'mailbox') {
        return $own['owners'][rowDomain($f, $own)] ?? ($own['admin'] ?? '');
    }
    $o = trim($f[15] ?? '');
    return $o === '-' ? '' : $o;
}

// Rows keyed so a mailbox local part on two domains is two rows.
function rowsByKey(string $text): array {
    $out = [];
    foreach (configRows($text) as $f) {
        $key = strtolower($f[0]) . '|' . $f[1];
        if (strtolower($f[0]) === 'mailbox') $key .= '|' . ltrim($f[4] ?? '', '=');
        $out[$key] = $f;
    }
    return $out;
}
function configRows(string $text): array {
    $out = [];
    foreach (explode("\n", str_replace("\r\n", "\n", $text)) as $line) {
        if (preg_match('/^\s*#/', $line) || strpos($line, '|') === false) continue;
        if (preg_match('/^\s*(PANEL|SHARE)\s*=/', $line)) continue;
        $f = array_map('trim', explode('|', $line));
        if (count($f) < 2 || $f[1] === '') continue;
        $out[] = $f;
    }
    return $out;
}

const MAILBOX_FREE = ['info', 'contact', 'admin'];

// How many extra mailboxes this account may have. Item 106: the three
// defaults never count.
function mailboxAllowance(string $who): int {
    $lines = [];
    exec('sudo ' . AUTHUSERS . ' --list 2>/dev/null', $lines, $rc);
    $raw = json_decode(implode("\n", $lines), true);
    $limit = (is_array($raw) && isset($raw['mailbox_default'])) ? (int) $raw['mailbox_default'] : 5;
    foreach (($raw['users'] ?? []) as $u) {
        if (($u['name'] ?? '') !== $who) continue;
        if (isset($u['mailboxes']) && $u['mailboxes'] !== null) $limit = (int) $u['mailboxes'];
    }
    return $limit;
}

function mailboxesUsed(string $text, string $who, array $own): int {
    $n = 0;
    foreach (configRows($text) as $f) {
        if (strtolower($f[0]) !== 'mailbox' || rowOwner($f, $own) !== $who) continue;
        if (in_array($f[1], MAILBOX_FREE, true)) continue;
        $n++;
    }
    return $n;
}

// Line two of a base hash file: who pressed Save, so the commit names them.
function savedBy(string $who): string {
    $clean = (string) preg_replace('/[^A-Za-z0-9._@-]/', '', $who);
    return $clean !== '' ? substr($clean, 0, 64) : 'unknown';
}

// Returns '' when the save is allowed, or the reason it is not.
function limitedSaveProblem(string $candidate, string $who): string {
    $live = @file_get_contents(CONF);
    if ($live === false) return 'Could not read the config to compare against.';

    $was = rowsByKey($live);
    $now = rowsByKey($candidate);
    // Ownership is read off the LIVE file, so a candidate cannot make a domain
    // theirs by claiming it.
    $own = ownership($live);

    // Path is free, but only among the folders their own rows already use: the
    // drawer hides the others, and a POST could otherwise serve another
    // customer's files, PHP source included. Apps and sites have separate roots.
    $folderOf = fn(array $f): string => (strtolower($f[0]) === 'app' ? 'app' : 'web')
        . '|' . explode('/', trim(trim($f[3] ?? ''), '/'))[0];
    $myFolders = [];
    foreach ($was as $f) {
        if (rowOwner($f, $own) === $who && trim($f[3] ?? '') !== '') $myFolders[] = $folderOf($f);
    }

    foreach ($now as $key => $f) {
        $name = $f[1];
        $mine = isset($f[15]) && trim($f[15]) !== '' && trim($f[15]) !== '-'
                && trim($f[15]) === $who;
        if (!isset($was[$key])) {
            // A mailbox on their own domain is theirs to add, up to the
            // allowance checked below. Any other row is a request: this is the
            // line that stops a customer writing themselves a row on somebody
            // else's domain.
            if (strtolower($f[0]) === 'mailbox' && rowOwner($f, $own) === $who) continue;
            return "'" . $name . "' is a new row. Adding one is a request.";
        }
        $before = $was[$key];
        $wasMine = rowOwner($before, $own) === $who;
        if (strtolower($f[0]) === 'mailbox') $mine = $wasMine;
        for ($i = 0; $i < max(count($before), count($f)); $i++) {
            $a = trim($before[$i] ?? '');
            $b = trim($f[$i] ?? '');
            if ($a === $b) continue;
            if (!$wasMine) {
                return "'" . $name . "' is not yours to change.";
            }
            if (!in_array($i, FREE_FIELDS, true)) {
                $label = FIELDS[$i][1] ?? ('field ' . ($i + 1));
                return "'" . $label . "' on '" . $name . "' is a request, not a save.";
            }
            if ($i === 3 && $b !== '' && !in_array($folderOf($f), $myFolders, true)) {
                return "Path '" . $b . "' on '" . $name . "' is not one of your folders.";
            }
        }
        // Owner is inside FREE_FIELDS? No: 15 is not in the list, so a change
        // to it is caught above. Said out loud because it is the one field
        // whose absence from the list is load bearing.
        if ($mine !== $wasMine) {
            return "Who owns '" . $name . "' is not yours to change.";
        }
    }

    foreach ($was as $key => $before) {
        if (isset($now[$key])) continue;
        // A row that has gone. Deleting is theirs when the row was theirs.
        if (rowOwner($before, $own) !== $who) {
            return "'" . $before[1] . "' is not yours to delete.";
        }
    }

    $limit = mailboxAllowance($who);
    $used = mailboxesUsed($candidate, $who, $own);
    if ($used > $limit && $used > mailboxesUsed($live, $who, $own)) {
        return 'That is ' . $used . ' mailboxes against an allowance of ' . $limit
             . '. Going past it is a request.';
    }

    // Everything outside the rows: BASE_DOMAIN, the port bases, DNS_DOMAINS,
    // PANEL and SHARE lines. None of it is a customer's, and comparing the
    // non-row lines as a block is the cheapest way to say so.
    $strip = function (string $t): string {
        $keep = [];
        foreach (explode("\n", str_replace("\r\n", "\n", $t)) as $l) {
            $isRow = !preg_match('/^\s*#/', $l) && strpos($l, '|') !== false
                     && !preg_match('/^\s*(PANEL|SHARE)\s*=/', $l);
            if (!$isRow) $keep[] = rtrim($l);
        }
        return implode("\n", $keep);
    };
    if ($strip($live) !== $strip($candidate)) {
        return 'Only your own rows are yours to change.';
    }
    return '';
}

// A LIMITED ADMIN'S SAVE, PUT BACK INTO THE WHOLE FILE. Item 136.
//
// Their page only ever holds their own rows, so what they post is the live file
// with everybody else's rows blanked. This rebuilds the real candidate from the
// live file: a posted row replaces the live row of that name, a row of theirs
// missing from the post is a delete, and a name the live file lacks is appended
// so limitedSaveProblem() refuses it as a new row. Settings lines always come
// from the live file.
function mergeLimitedSave(string $posted, string $who): ?string {
    $live = @file_get_contents(CONF);
    if ($live === false) return null;
    $isRow = function (string $l): bool {
        return !preg_match('/^\s*#/', $l) && strpos($l, '|') !== false
               && !preg_match('/^\s*(PANEL|SHARE)\s*=/', $l);
    };
    // A mailbox name is a local part and repeats across domains, so it is
    // keyed with its domain; any other row is keyed by type and name.
    $nameOf = function (string $l): string {
        $f = array_map('trim', explode('|', $l));
        if (($f[1] ?? '') === '') return '';
        $key = strtolower($f[0]) . '|' . $f[1];
        return strtolower($f[0]) === 'mailbox' ? $key . '|' . ltrim($f[4] ?? '', '=') : $key;
    };

    $postedRows = [];
    foreach (explode("\n", str_replace("\r\n", "\n", $posted)) as $l) {
        if (!$isRow($l) || $nameOf($l) === '') continue;
        $postedRows[$nameOf($l)] = $l;
    }

    $own = ownership($live);
    $out = [];
    $seen = [];
    foreach (explode("\n", str_replace("\r\n", "\n", $live)) as $l) {
        if (!$isRow($l) || $nameOf($l) === '') { $out[] = $l; continue; }
        $name = $nameOf($l);
        $seen[$name] = true;
        if (isset($postedRows[$name])) { $out[] = $postedRows[$name]; continue; }
        $f = array_map('trim', explode('|', $l));
        if (rowOwner($f, $own) === $who) continue;
        $out[] = $l;
    }
    foreach ($postedRows as $name => $l) {
        if (!isset($seen[$name])) $out[] = $l;
    }
    return implode("\n", $out);
}
// WHAT A LIMITED ADMIN MAY POST. Item 105.
//
// Every account in the password file is inside this file now, so this is the
// control and the page's hiding is not. It is a DENY LIST BY DEFAULT: an action
// not named here is refused, so a handler added later is refused until somebody
// decides otherwise, rather than being open until somebody notices.
//
// What a limited admin may do, from the owner 2026-09-10: re-run and cancel a
// deploy on their own rows, and read. Everything that writes a config row, an
// account, a certificate or a share is a full access admin's.

// Does this account own that row? The sixteenth field, read straight out of the
// config file. Item 105.
//
// A dash, a blank, a missing field or an unreadable config all answer NO, which
// is the direction that fails closed: an account is handed a row only when the
// file says so in as many words.
function ownsRow(string $who, string $row): bool {
    if ($who === '' || $row === '') return false;
    $conf = @file(CONF, FILE_IGNORE_NEW_LINES);
    if ($conf === false) return false;
    foreach ($conf as $line) {
        if (preg_match('/^\s*#/', $line) || strpos($line, '|') === false) continue;
        $f = array_map('trim', explode('|', $line));
        if (count($f) < 2 || $f[1] !== $row) continue;
        $owner = isset($f[15]) ? trim($f[15]) : '';
        return $owner !== '' && $owner !== '-' && $owner === $who;
    }
    return false;
}
// 'request' files one, 'reqseen' marks an answer read, 'reqwithdraw' takes one
// back. All three are about a customer's OWN request, and the script checks
// that: it refuses to mark read or withdraw anything filed by somebody else.
// Approving and declining are not here, so they stay a full access admin's.
const ROLE_MAY_POST = ['redeploy', 'request', 'reqseen', 'reqwithdraw',
                       // Every console user votes on a new upstream version;
                       // pausing and publishing stay a full access admin's.
                       'upgradevote',
                       // The ordinary save. A limited admin reaches it like
                       // anybody else, and every DIFFERENCE they post is
                       // checked by limitedSaveProblem() below.
                       'save', 'save_apply', 'save_fast'];
// Which account owns a MAILBOX row. Item 106, 2026-09-11.
//
// NOT ownsRow(): that matches on the row name alone, and a mailbox name is a
// local part. `info` exists on three domains here, so the name on its own would
// hand one person's address to whoever owns `info` on another domain. This
// matches the local part AND the domain, and a blank domain field means
// BASE_DOMAIN, which is how the rest of the machine reads it.
//
// Since 2026-09-16 that is whoever owns the DOMAIN, see ownership(), so an
// address that does not exist yet is theirs to create as well.
function ownsMailbox(string $who, string $local, string $domain): bool {
    if ($who === '' || $local === '' || $domain === '') return false;
    $conf = @file_get_contents(CONF);
    if ($conf === false) return false;
    $own = ownership($conf);
    return rowOwner(['mailbox', $local, '', '', $domain], $own) === $who;
}
function mayPost(string $action, string $role): bool {
    if ($role === 'full') return true;
    // A customer sets the password on a mailbox THEY OWN, and on no other.
    // The owner, 2026-09-11. It is the one write here that touches nothing but
    // their own account: no row, no vhost, no certificate.
    if ($action === 'setmailpw') {
        global $me;
        return ownsMailbox((string) $me, trim($_POST['mail_local'] ?? ''),
                           trim($_POST['mail_domain'] ?? ''));
    }
    return in_array($action, ROLE_MAY_POST, true);
}
function refusePost(string $action): void {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    http_response_code(403);
    echo json_encode(['ok' => false,
        'out' => "Refused: '" . $action . "' is a full access admin's to do."]);
    exit;
}
if ($_SERVER['REQUEST_METHOD'] === 'POST' && !mayPost((string) ($_POST['action'] ?? ''), $myRole)) {
    refusePost((string) ($_POST['action'] ?? ''));
}

// Sign somebody out. Full access only, which mayPost has already decided: kick
// is not in ROLE_MAY_POST.
if ($_SERVER['REQUEST_METHOD'] === 'POST' && ($_POST['action'] ?? '') === 'kick') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $who = (string) ($_POST['name'] ?? '');
    if (!preg_match('/^[A-Za-z0-9._-]+$/', $who)) {
        echo json_encode(['ok' => false, 'out' => 'Not a username.']);
    } elseif ($who === $me) {
        echo json_encode(['ok' => false, 'out' => 'That is you. Close the page instead.']);
    } else {
        $ok = @file_put_contents(WORKDIR . '/' . $who . '.kick', (string) time()) !== false;
        // Off the online list now, not when their mark ages out 90 seconds later.
        if ($ok) @unlink(WORKDIR . '/' . $who . '.seen');
        echo json_encode(['ok' => $ok, 'out' => $ok ? "$who is signed out at their next click." : 'Could not write the kick.']);
    }
    exit;
}

// WHAT A LIMITED ADMIN MAY ASK FOR. Item 105, the read side.
//
// The POST gate above stops them CHANGING things. This stops them READING
// things, which is the half that is easy to forget because nothing breaks
// visibly when it is missing: ?ask=users handed a customer every account name,
// e-mail and role, and the page never showed it, so only a fetch found it.
//
// Three groups:
//   - free:      about the machine, not about anybody. Ports and units.
//   - row-bound: allowed only for a row they own, checked with ownsRow().
//   - nobody's:  a full access admin's alone.
// 'requests' is free because the handler FILTERS it: a limited admin is sent
// only the requests they filed. Filtering there rather than refusing here is
// what lets one tab serve both sides.
// 'domainfree' asks TransIP whether a domain can still be registered. It is
// here because a customer filling in a domain request is exactly who needs the
// answer, it reads nothing about this machine, and the token it uses is read
// only. Item 106, 2026-09-11.
const ASK_FREE = ['cpu', 'status', 'jobs', 'requests', 'domainfree'];
const ASK_ROW  = ['appsettings', 'deployed', 'joblog', 'jobhistory', 'unitlog', 'mail', 'mailpw', 'mailclient'];
function mayAsk(string $ask, string $role, string $who): bool {
    if ($role === 'full') return true;
    if (in_array($ask, ASK_FREE, true)) return true;
    // A mailbox ask names an address, not a row: a local part repeats across
    // domains, so the row name alone cannot say whose it is.
    if ($ask === 'mailpw') {
        return ownsMailbox($who, trim((string) ($_GET['local'] ?? '')), trim((string) ($_GET['domain'] ?? '')));
    }
    if ($ask === 'mailclient') {
        $at = explode('@', trim((string) ($_GET['address'] ?? '')), 2);
        return count($at) === 2 && ownsMailbox($who, $at[0], $at[1]);
    }
    if (in_array($ask, ASK_ROW, true)) {
        // Every row-bound ask names its row the same way, except joblog, which
        // names a job as <row>/<job>. Taking the part before the slash is what
        // makes one check cover both.
        $r = (string) ($_GET['row'] ?? $_GET['job'] ?? '');
        if (strpos($r, '/') !== false) $r = substr($r, 0, strpos($r, '/'));
        return ownsRow($who, trim($r));
    }
    return false;
}
if (($_GET['ask'] ?? '') !== '' && !mayAsk((string) $_GET['ask'], $myRole, $me)) {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    http_response_code(403);
    echo json_encode(['ok' => false, 'out' => 'Refused.']);
    exit;
}

if (($_GET['ask'] ?? '') === 'jobs') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    exec('sudo ' . JOBSTATUS . ' 2>/dev/null', $lines, $rc);
    $body = trim(implode('', $lines));
    // A limited admin hears about their own rows' jobs only. Item 136.
    $jobsParsed = $myRole !== 'full' ? json_decode($body, true) : null;
    if (is_array($jobsParsed) && is_array($jobsParsed['sites'] ?? null)) {
        $mine = [];
        foreach (rowsByName((string) @file_get_contents(CONF)) as $f) {
            if ($me !== '' && trim($f[15] ?? '') === $me) $mine[$f[1]] = true;
        }
        $jobsParsed['sites'] = (object) array_intersect_key($jobsParsed['sites'], $mine);
        $body = json_encode($jobsParsed, JSON_UNESCAPED_SLASHES);
    }
    // A failure means "nothing known", never "nothing running": greying a
    // button out because a status call failed would be worse than the problem.
    echo ($rc === 0 && $body !== '') ? $body : '{"jobs":{}}';
    exit;
}

// The machine's CPU counters, raw. Asked for once a second while a job runs.
//
// No sudo and no script: /proc/stat is world readable, so this is the cheapest
// thing on the page. The RAW counters go out rather than a percentage, and the
// browser divides one sample by the next: a percentage needs two readings taken
// apart, and doing that here would mean either sleeping in the request or
// keeping server state that the five-second job poll would race with.
if (($_GET['ask'] ?? '') === 'cpu') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $lines = @file('/proc/stat');
    $all   = null;
    $cores = [];
    foreach (($lines ?: []) as $l) {
        $f = preg_split('/\s+/', trim($l));
        if (count($f) < 9 || strncmp($f[0], 'cpu', 3) !== 0) {
            continue;
        }
        // user nice system idle iowait irq softirq steal
        $vals = array_map('intval', array_slice($f, 1, 8));
        $one  = ['total' => array_sum($vals), 'idle' => $vals[3] + $vals[4]];
        if ($f[0] === 'cpu') { $all = $one; } else { $cores[] = $one; }
    }
    if ($all === null) {
        echo json_encode(['ok' => false]);
        exit;
    }
    // Completed operations, not bytes: the question the graph answers is how
    // hard the disk is being asked to work. Partitions and loop devices are
    // skipped, so a read is not counted twice.
    //
    // null, never 0, when no physical device could be read: a zero is a
    // measurement, and an idle disk must not look the same as a disk nobody
    // could ask.
    $reads = null;
    $writes = null;
    foreach ((@file('/proc/diskstats') ?: []) as $l) {
        $d = preg_split('/\s+/', trim($l));
        if (count($d) < 11 || !preg_match('/^(sd[a-z]|nvme\d+n\d+|mmcblk\d+|vd[a-z])$/', $d[2])) {
            continue;
        }
        $reads  = (int) $reads  + (int) $d[3];
        $writes = (int) $writes + (int) $d[7];
    }

    // One zone on a Pi, and its type names it. Anything else takes the first.
    $temp = null;
    foreach (glob('/sys/class/thermal/thermal_zone*') ?: [] as $z) {
        $raw = @file_get_contents("$z/temp");
        if ($raw === false) { continue; }
        $c = round(((int) $raw) / 1000, 1);
        if ($temp === null || strpos((string) @file_get_contents("$z/type"), 'cpu') !== false) {
            $temp = $c;
        }
    }

    // MemAvailable, not MemFree: the page cache is free for the taking, and
    // counting it as used makes every machine look full.
    $mem = null;
    $mi  = [];
    foreach ((@file('/proc/meminfo') ?: []) as $l) {
        if (preg_match('/^(MemTotal|MemAvailable):\s+(\d+)/', $l, $m)) { $mi[$m[1]] = (int) $m[2]; }
    }
    if (!empty($mi['MemTotal']) && isset($mi['MemAvailable'])) {
        $mem = (int) round(100 * ($mi['MemTotal'] - $mi['MemAvailable']) / $mi['MemTotal']);
    }

    echo json_encode([
        'ok'    => true,
        'total' => $all['total'],
        'idle'  => $all['idle'],
        'cores' => $cores,
        'reads' => $reads,
        'writes'=> $writes,
        'temp'  => $temp,
        'mem'   => $mem,
    ]);
    exit;
}

// The console output of a job that has just finished. Only asked for when the
// job did not succeed: a green run has nothing anyone needs to read.
//
// The job is named by KEY and the key is checked here as well as in the script,
// so a crafted query string cannot reach a job the page does not own.
// What Jenkins is busy with, for a job that is still waiting in its queue.
// Full access only: it names every row's jobs.
if (($_GET['ask'] ?? '') === 'jobbusy') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    exec('sudo ' . JOBLOG . ' --busy 2>/dev/null', $lines, $rc);
    $busy = $rc === 0 ? json_decode(implode('', $lines), true) : null;
    echo json_encode(is_array($busy) ? ['ok' => true] + $busy : ['ok' => false]);
    exit;
}

if (($_GET['ask'] ?? '') === 'joblog') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $key = $_GET['job'] ?? '';
    // <row>/deploy-<env> as well, for the rerun button. Shaped here and bounded
    // in the script: jenkins_job_log.sh checks the row against the published
    // config and the environment against ENVS, exactly as trigger_site_job.sh
    // does before starting one. The page may read what it may start.
    $isDeploy = (bool) preg_match('~^[A-Za-z0-9._-]+/deploy-[a-z]+$~', (string) $key);
    if (!$isDeploy && !in_array($key, ['hosting-apply', 'machine-update'], true)) {
        echo json_encode(['ok' => false, 'log' => '', 'error' => 'Unknown job.']);
        exit;
    }
    exec('sudo ' . JOBLOG . ' ' . escapeshellarg($key) . ' 200 2>&1', $lines, $rc);
    echo json_encode([
        'ok'    => $rc === 0,
        'log'   => strip_ansi(implode("\n", $lines)),
        'error' => $rc === 0 ? '' : 'Jenkins did not return the log.',
    ]);
    exit;
}

// The last 20 builds of one deploy job, with the average. The owner, 2026-09-10:
// so the operator can tell a slow run from a normal one while it is happening.
//
// Shape checked here, meaning checked in the script: it validates the row
// against the published config and the environment against ENVS.
if (($_GET['ask'] ?? '') === 'jobhistory') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $hRow = (string) ($_GET['row'] ?? '');
    $hEnv = (string) ($_GET['env'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_.-]+$/', $hRow) || !preg_match('/^[a-z]+$/', $hEnv)) {
        echo json_encode(['builds' => [], 'average' => null]);
        exit;
    }
    // Two questions of the same job, so one endpoint with a mode rather than a
    // second one that would repeat both bounds.
    $hMode = (($_GET['what'] ?? '') === 'stages') ? '--stages' : '--history';
    $hLines = [];
    exec('sudo ' . JOBSTATUS . ' ' . $hMode . ' ' . escapeshellarg($hRow) . ' '
        . escapeshellarg($hEnv) . ' 2>/dev/null', $hLines, $hRc);
    $hRaw = json_decode(implode("\n", $hLines), true);
    echo json_encode(is_array($hRaw) ? $hRaw : ['builds' => [], 'average' => null]);
    exit;
}

// The settings a row's application reads, out of its own repository, so the
// App settings box can offer real key names instead of asking for one typed
// from memory. Item 99.
if (($_GET['ask'] ?? '') === 'appsettings') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $aRow = (string) ($_GET['row'] ?? '');
    if (!preg_match('/^[A-Za-z0-9._-]+$/', $aRow)) {
        echo json_encode(['keys' => [], 'files' => []]);
        exit;
    }
    $aLines = [];
    exec('sudo ' . READSETTINGS . ' ' . escapeshellarg($aRow) . ' 2>/dev/null', $aLines, $aRc);
    $aRaw = json_decode(implode("\n", $aLines), true);
    echo json_encode(is_array($aRaw) ? $aRaw : ['keys' => [], 'files' => []]);
    exit;
}

// Everybody who may sign in. Read-only, and it returns no hash: the page shows

// What has been asked for, and what was said back. Item 106.
//
// A full access admin sees every request. A limited admin sees only their own,
// filtered HERE and not in the page: their own answers are the only thing they
// have any business reading.
if (($_GET['ask'] ?? '') === 'requests') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $qLines = [];
    exec('sudo ' . REQUESTS . ' --list 2>/dev/null', $qLines, $qRc);
    $qRaw = json_decode(implode("\n", $qLines), true);
    if (!is_array($qRaw)) { $qRaw = ['requests' => [], 'pending' => 0]; }
    if ($myRole !== 'full') {
        $qRaw['requests'] = array_values(array_filter(
            $qRaw['requests'],
            fn($r) => ($r['by'] ?? '') === $me
        ));
        // For a customer the count that matters is answers they have not read,
        // not work waiting for somebody else.
        $qRaw['pending'] = count(array_filter(
            $qRaw['requests'],
            fn($r) => in_array($r['state'] ?? '', ['approved', 'declined'], true)
                      && empty($r['seen'])
        ));
    }
    echo json_encode($qRaw);
    exit;
}

// File one. The row arrives as JSON and is stored as asked for: it is checked
// on the way in by the page and again at approval by check_config.sh, which is
// the same gate every other save passes.
//
// NO PORT is accepted. The requester has no port field, so anything arriving in
// one came from somewhere it should not have; the script drops it as well.
if (($_POST['action'] ?? '') === 'request') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $qRow = (string) ($_POST['row'] ?? '');
    if ($qRow === '' || json_decode($qRow, true) === null) {
        echo json_encode(['ok' => false, 'out' => 'Refused: that is not a request.']);
        exit;
    }
    $qPipes = [];
    $qProc = proc_open('sudo ' . REQUESTS . ' --add ' . escapeshellarg($me) . ' 2>&1',
                       [0 => ['pipe', 'r'], 1 => ['pipe', 'w']], $qPipes);
    if (!is_resource($qProc)) {
        echo json_encode(['ok' => false, 'out' => 'Could not file it.']);
        exit;
    }
    fwrite($qPipes[0], $qRow);
    fclose($qPipes[0]);
    $qOut = stream_get_contents($qPipes[1]);
    fclose($qPipes[1]);
    $qRc = proc_close($qProc);
    echo json_encode(['ok' => $qRc === 0, 'out' => strip_ansi($qOut)]);
    exit;
}

// Approve, decline, or mark an answer read.
//
// A decline with no reason is refused by the script, deliberately: the reason
// is what the requester reads, and without it they only learn no.
if (in_array($_POST['action'] ?? '', ['reqapprove', 'reqdecline', 'reqseen', 'reqwithdraw'], true)) {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $qAct  = $_POST['action'];
    $qId   = trim($_POST['id'] ?? '');
    $qWhy  = trim($_POST['reason'] ?? '');
    if (!preg_match('/^[A-Za-z0-9._-]+$/', $qId)) {
        echo json_encode(['ok' => false, 'out' => 'Refused: that is not a request.']);
        exit;
    }
    $qVerb = ['reqapprove' => '--approve', 'reqdecline' => '--decline', 'reqseen' => '--seen', 'reqwithdraw' => '--withdraw'][$qAct];
    $qCmd  = 'sudo ' . REQUESTS . ' ' . $qVerb . ' ' . escapeshellarg($qId)
           . ' ' . escapeshellarg($me);
    if ($qAct === 'reqapprove' || $qAct === 'reqdecline') { $qCmd .= ' ' . escapeshellarg($qWhy); }
    $qLines = [];
    exec($qCmd . ' 2>&1', $qLines, $qRc);
    $qOut = implode("\n", $qLines);
    // --approve prints the row it holds on its last line, so the page can
    // publish it without asking for the request a second time.
    $qRow = null;
    if ($qAct === 'reqapprove' && $qRc === 0) {
        $qLast = trim((string) end($qLines));
        $qRow  = json_decode($qLast, true);
    }
    echo json_encode(['ok' => $qRc === 0, 'out' => strip_ansi($qOut), 'row' => $qRow]);
    exit;
}
// who exists and whether they are switched on, never what their password is.
// Can this domain still be registered? One JSON line, and never an error: the
// script answers `unknown` when TransIP cannot be reached, because a lookup
// that did not happen must not read as a refusal. Item 106.
if (($_GET['ask'] ?? '') === 'domainfree') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $dWant = trim($_GET['domain'] ?? '');
    // Checked here as well as in the script: a value that reaches sudo is worth
    // refusing twice, and this one is typed by a customer.
    if (!preg_match('/^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)+$/', $dWant)
        || strlen($dWant) > 253) {
        echo json_encode(['domain' => $dWant, 'state' => 'unknown',
                          'detail' => 'not a domain name', 'checked' => 0]);
        exit;
    }
    $dLines = [];
    exec('sudo ' . CHECKDOMAIN . ' ' . escapeshellarg($dWant) . ' 2>/dev/null', $dLines);
    $dRaw = json_decode(trim((string) end($dLines)), true);
    echo json_encode(is_array($dRaw) ? $dRaw
        : ['domain' => $dWant, 'state' => 'unknown', 'detail' => 'no answer', 'checked' => 0]);
    exit;
}

// The audit trail, newest first. Full admins only: not in ASK_FREE or ASK_ROW.
if (($_GET['ask'] ?? '') === 'audit') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $aLines = [];
    exec('sudo ' . READAUDIT . ' 2>/dev/null', $aLines, $aRc);
    $entries = [];
    foreach ($aLines as $line) {
        $j = json_decode($line, true);
        if (!is_array($j) || !isset($j['MESSAGE'], $j['__REALTIME_TIMESTAMP'])) continue;
        $m = json_decode((string) $j['MESSAGE'], true);
        if (!is_array($m)) continue;
        $m['when'] = (int) floor(((int) $j['__REALTIME_TIMESTAMP']) / 1000000);
        $entries[] = $m;
    }
    echo json_encode(['ok' => $aRc === 0, 'entries' => array_reverse($entries)]);
    exit;
}

if (($_GET['ask'] ?? '') === 'users') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $uLines = [];
    exec('sudo ' . AUTHUSERS . ' --list 2>/dev/null', $uLines, $uRc);
    $uRaw = json_decode(implode("\n", $uLines), true);
    if (!is_array($uRaw)) $uRaw = ['users' => [], 'file' => null];
    // store_logins.sh's last result: "ok <time>" or "failed <time> <reason>".
    $uStore = @file_get_contents(LOGIN_STORE_STATUS);
    $uRaw['store'] = $uStore === false ? null : trim($uStore);
    echo json_encode($uRaw);
    exit;
}

// Add, change a password, switch off, switch on, delete. The verb is checked
// here as well as in the script, because a value that reaches sudo is a value
// worth refusing twice.
//
// The password goes down stdin through proc_open, never as an argument: an
// argument is visible in ps to every account on this machine. Same reason
// setmailpw does it, and the same shape.
if (($_POST['action'] ?? '') === 'user') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $uVerb = trim($_POST['verb'] ?? '');
    $uName = trim($_POST['name'] ?? '');
    if (!in_array($uVerb, ['add', 'password', 'disable', 'enable', 'delete', 'meta'], true)
        || !preg_match('/^[A-Za-z0-9._-]+$/', $uName)) {
        echo json_encode(['ok' => false, 'out' => 'Refused: not a verb and a name.']);
        exit;
    }
    $uCmd = 'sudo ' . AUTHUSERS . ' --' . $uVerb . ' ' . escapeshellarg($uName);
    // Who somebody is and what they may do. The role is checked here as well as
    // in the script, because a value that reaches sudo is worth refusing twice,
    // and this one decides what a signed-in account may press.
    if ($uVerb === 'meta') {
        $uRole = trim($_POST['role'] ?? '');
        $uMail = trim($_POST['email'] ?? '');
        if (!in_array($uRole, ['full', 'admin', 'none'], true)) {
            echo json_encode(['ok' => false, 'out' => 'Refused: a role is full, admin or none.']);
            exit;
        }
        $uBoxes = trim($_POST['boxes'] ?? '');
        // Empty is a dash, which the script reads as "use the default". A number
        // written here would freeze that person on today's default for ever.
        if ($uBoxes !== '' && !preg_match('/^[0-9]{1,2}$/', $uBoxes)) {
            echo json_encode(['ok' => false, 'out' => 'Refused: that is not a number of mailboxes.']);
            exit;
        }
        $uCmd .= ' ' . escapeshellarg($uRole) . ' ' . escapeshellarg($uMail === '' ? '-' : $uMail)
               . ' ' . escapeshellarg($uBoxes === '' ? '-' : $uBoxes);
    }
    $uCmd .= ' 2>&1';
    if ($uVerb === 'add' || $uVerb === 'password') {
        $uPipes = [];
        $uProc = proc_open($uCmd, [0 => ['pipe', 'r'], 1 => ['pipe', 'w']], $uPipes);
        if (!is_resource($uProc)) {
            echo json_encode(['ok' => false, 'out' => 'Could not run the command.']);
            exit;
        }
        fwrite($uPipes[0], (string) ($_POST['pw'] ?? '') . "\n");
        fclose($uPipes[0]);
        $uOut = stream_get_contents($uPipes[1]);
        fclose($uPipes[1]);
        $uRc = proc_close($uProc);
    } else {
        $uOutLines = [];
        exec($uCmd, $uOutLines, $uRc);
        $uOut = implode("\n", $uOutLines);
    }
    // A new account gets its recovery codes straight away, into its own
    // 1Password entry. The owner, 2026-09-20: codes made at the moment somebody
    // is locked out are no use, so they are made at creation instead.
    //
    // Never fatal. The account exists and can sign in; the 🔑 page makes a set
    // by hand if this failed, and the message says so.
    $uExtra = '';
    if ($uVerb === 'add' && $uRc === 0) {
        $uCodes = tfa_recovery_new($uName);
        if (!$uCodes) {
            $uExtra = "\nThe account was made, but its recovery codes were not: "
                    . "open the key icon as that user to make a set.";
        } elseif (!tfa_codes_to_vault($uName, $uCodes)) {
            $uExtra = "\nRecovery codes were made, but 1Password could not be written. "
                    . "Open the key icon as that user to make a set that lands in the vault.";
        } else {
            $uExtra = "\n" . TFA_RECOVERY_N . " recovery codes are in their 1Password entry.";
        }
    }
    echo json_encode(['ok' => $uRc === 0, 'out' => strip_ansi($uOut) . $uExtra]);
    exit;
}

// Share a person's 1Password entry to their own address, which mails them the
// link. A button, never automatic: login-store-decisions.md, decision 8. Full
// access only, because usershare is not in ROLE_MAY_POST.
if (($_POST['action'] ?? '') === 'usershare') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $sName = trim($_POST['name'] ?? '');
    if (!preg_match('/^[A-Za-z0-9._-]+$/', $sName)) {
        echo json_encode(['ok' => false, 'error' => 'Refused: not a name.']);
        exit;
    }
    $sLines = [];
    exec('sudo ' . PERSONENTRY . ' --share ' . escapeshellarg($sName) . ' 2>/dev/null', $sLines, $sRc);
    $sJson = json_decode((string) end($sLines), true);
    echo json_encode(is_array($sJson) ? $sJson : ['ok' => false, 'error' => 'No answer from person_entry.sh.']);
    exit;
}

// One mailbox's 1Password item to an address typed in the page: the person who
// reads info@ need not own the domain. Full access only, like usershare.
if (($_POST['action'] ?? '') === 'mailshare') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $mAddr = trim($_POST['address'] ?? '');
    // One address or several, comma separated.
    $mList = array_values(array_filter(array_map('trim', explode(',', (string) ($_POST['to'] ?? ''))), 'strlen'));
    $mTo   = implode(',', $mList);
    if (!preg_match('/^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9.-]+$/', $mAddr) || !$mList
        || count(array_filter($mList, fn($x) => !filter_var($x, FILTER_VALIDATE_EMAIL)))) {
        echo json_encode(['ok' => false, 'error' => 'Refused: not an address.']);
        exit;
    }
    $mLines = [];
    // Who pressed it, so the owner's notice can say so.
    $mBy = preg_match('/^[A-Za-z0-9._-]+$/', $me) ? $me : '-';
    exec('sudo ' . PERSONENTRY . ' --share-mailbox ' . escapeshellarg($mAddr) . ' '
        . escapeshellarg($mTo) . ' ' . escapeshellarg($mBy) . ' 2>/dev/null', $mLines, $mRc);
    $mJson = json_decode((string) end($mLines), true);
    echo json_encode(is_array($mJson) ? $mJson : ['ok' => false, 'error' => 'No answer from person_entry.sh.']);
    exit;
}

// What is deployed for one row and environment, and whether the branch has moved
// since. Item 104 feature 5: 'Succeeded' says nothing about WHICH commit it
// succeeded on.
if (($_GET['ask'] ?? '') === 'deployed') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $kRow = (string) ($_GET['row'] ?? '');
    $kEnv = (string) ($_GET['env'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_.-]+$/', $kRow) || !preg_match('/^[a-z]+$/', $kEnv)) {
        echo json_encode(['deployed' => null, 'head' => null, 'behind' => null]);
        exit;
    }
    $kLines = [];
    exec('sudo ' . DEPLOYEDSHA . ' ' . escapeshellarg($kRow) . ' '
        . escapeshellarg($kEnv) . ' 2>/dev/null', $kLines, $kRc);
    $kRaw = json_decode(implode("\n", $kLines), true);
    echo json_encode(is_array($kRaw) ? $kRaw
                                     : ['deployed' => null, 'head' => null, 'behind' => null]);
    exit;
}

// What hosting-status.service published, for a page that is already open.
//
// The same file the page is built from at load. It is world readable and holds
// no secret: unit names and states, ports that are listening, certificate
// dates. Reading it needs no sudo, which is why this is a file_get_contents
// rather than a call into a script.
// A LIMITED ADMIN'S STATUS NAMES ONLY THEIR OWN ROWS. Item 136.
//
// Units, runtimes and vhosts are named after rows, and certificates after
// hostnames, so the whole file hands over every customer's names. Machine-wide
// entries (ports, services, errors) are not a row's and are left alone.
function statusFor(?array $status, string $role, string $who): ?array {
    if ($status === null || $role === 'full') return $status;
    $conf = (string) @file_get_contents(CONF);
    $base = (string) (conf_val($conf, 'BASE_DOMAIN') ?? '');
    $envs = array_filter(array_map('trim', explode(',', (string) conf_val($conf, 'ENVS'))));
    $names = [];
    $hosts = [];
    foreach (rowsByName($conf) as $f) {
        if (trim($f[15] ?? '') !== $who || $who === '') continue;
        $names[] = $f[1];
        $d = trim($f[4] ?? '');
        if ($d === '' || $d === '-' || strtolower($f[0]) === 'mailbox') continue;
        $hosts[] = $d === '@' ? $base : ($d[0] === '=' ? substr($d, 1) : $d . '.' . $base);
    }
    $alt = function (array $xs): string {
        return implode('|', array_map(fn($x) => preg_quote($x, '/'), $xs));
    };
    $envAlt = $alt($envs);
    $unitRe = $names ? '/^app-(' . $alt($names) . ')(-(' . $envAlt . '))?\.service$/' : '/(?!)/';
    $vhostRe = $names ? '/^(preview-)?(' . $alt($names) . ')(-(' . $envAlt . '))?$/' : '/(?!)/';
    $certRe = $hosts ? '/^((' . $envAlt . ')[.-])?(' . $alt($hosts) . ')$/' : '/(?!)/';

    if (is_array($status['units'] ?? null)) {
        $status['units'] = array_values(array_filter($status['units'],
            fn($u) => preg_match($unitRe, (string) ($u['unit'] ?? ''))));
    }
    if (is_array($status['runtimes'] ?? null)) {
        $status['runtimes'] = array_filter($status['runtimes'],
            fn($k) => preg_match($unitRe, (string) $k), ARRAY_FILTER_USE_KEY);
    }
    if (is_array($status['containerRuntimes'] ?? null)) {
        $status['containerRuntimes'] = array_filter($status['containerRuntimes'],
            fn($k) => preg_match($unitRe, (string) $k), ARRAY_FILTER_USE_KEY);
    }
    if (is_array($status['frameworks'] ?? null)) {
        $status['frameworks'] = array_filter($status['frameworks'],
            fn($k) => preg_match($vhostRe, (string) $k), ARRAY_FILTER_USE_KEY);
    }
    unset($status['hostPackages']);
    if (is_array($status['vhosts'] ?? null)) {
        $status['vhosts'] = array_values(array_filter($status['vhosts'],
            fn($v) => preg_match($vhostRe, (string) $v)));
    }
    if (is_array($status['certificates'] ?? null)) {
        $status['certificates'] = array_values(array_filter($status['certificates'],
            fn($c) => preg_match($certRe, (string) ($c['name'] ?? ''))));
    }
    return $status;
}

// The changes running right now, by anybody. A limited admin hears that
// something is happening and how long for, never who or on which row: that is
// the same line item 136 draws around rows they do not own.
// A file older than an hour belongs to a request that died without its
// shutdown function, so it is removed rather than shown for ever.
function workInProgress(string $role, string $me): array {
    $out = [];
    foreach (glob(WORKDIR . '/*.json') ?: [] as $f) {
        // Named <pid>-<random>: a worker that is gone died without its shutdown function.
        $pid = (int) strtok(basename($f), '-');
        if ($pid > 0 && !file_exists("/proc/$pid")) { @unlink($f); continue; }
        $w = json_decode((string) @file_get_contents($f), true);
        $age = is_array($w) ? time() - (int) ($w['since'] ?? 0) : PHP_INT_MAX;
        if ($age > 3600) { @unlink($f); continue; }
        if ($age < 2) continue;
        $out[] = $role === 'full' || ($w['user'] ?? '') === $me
            ? ['user' => $w['user'] ?? '', 'action' => $w['action'] ?? '', 'row' => $w['row'] ?? '', 'secs' => $age]
            : ['secs' => $age];
    }
    return $out;
}

if (($_GET['ask'] ?? '') === 'status') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $live = null;
    if (is_readable(STATUSFILE)) {
        $live = json_decode((string) file_get_contents(STATUSFILE), true);
        if (!is_array($live)) { $live = null; }
    }
    $live = statusFor($live, $myRole, $me);
    if ($me !== '') @touch(WORKDIR . '/' . auditId($me) . '.seen');
    echo json_encode(['ok' => $live !== null, 'status' => $live, 'work' => workInProgress($myRole, $me),
                      'online' => $myRole === 'full' ? onlineUsers() : []]);
    exit;
}

// One application's journal, read only.
//
// The row and the environment are passed through untouched: the unit name is
// BUILT by app_service_control.sh from the published config, and nothing here
// can name a unit. Same bound as start, stop and restart, which is why the log
// verb lives in that script rather than in one of its own.
if (($_GET['ask'] ?? '') === 'unitlog') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $row = (string) ($_GET['row'] ?? '');
    $env = (string) ($_GET['env'] ?? '');
    if ($row === '' || $env === '') {
        echo json_encode(['ok' => false, 'log' => '', 'error' => 'No row.']);
        exit;
    }
    $lines = [];
    exec('sudo ' . SVCCTL . ' ' . escapeshellarg($row) . ' ' . escapeshellarg($env)
         . ' log 2>&1', $lines, $rc);
    echo json_encode([
        'ok'    => $rc === 0,
        'log'   => strip_ansi(implode("
", $lines)),
        'error' => $rc === 0 ? '' : 'The log could not be read.',
    ]);
    exit;
}

// What an app row is currently sending mail as.
//
// Asked when the drawer opens rather than for every row on every page load:
// eight app rows would be eight sudo calls on a page nobody has opened a
// drawer on yet, and forks per page load are what made --check take seventeen
// seconds.
//
// The row name is not checked here. It is checked by the script, against the
// published config, because that is the copy that decides what this machine
// serves and it runs as root. Checking it in two places that can disagree is
// worse than checking it in the one that matters.
if (($_GET['ask'] ?? '') === 'mail') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $row = $_GET['row'] ?? '';
    exec('sudo ' . MAILSET . ' --read ' . escapeshellarg($row) . ' 2>&1', $lines, $rc);
    $raw = trim(implode("\n", $lines));
    $parsed = $rc === 0 ? json_decode($raw, true) : null;
    echo json_encode([
        'ok'    => $rc === 0 && is_array($parsed),
        'mail'  => $parsed ?: ['from' => '', 'to' => '', 'configured' => false, 'owned' => false],
        'error' => $rc === 0 ? '' : strip_ansi($raw),
    ]);
    exit;
}

// Whether one mailbox already has a password, so the drawer can say "set" or
// "never set" instead of leaving the administrator guessing. --check writes
// nothing and takes no password.
if (($_GET['ask'] ?? '') === 'mailpw') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $local  = $_GET['local']  ?? '';
    $domain = $_GET['domain'] ?? '';
    exec('sudo ' . MAILPW . ' --check ' . escapeshellarg($local)
         . ' ' . escapeshellarg($domain) . ' 2>&1', $lines, $rc);
    $raw = trim(implode("\n", $lines));
    $parsed = $rc === 0 ? json_decode($raw, true) : null;
    echo json_encode([
        'ok'    => $rc === 0 && is_array($parsed) && empty($parsed['error']),
        'box'   => $parsed ?: [],
        'error' => is_array($parsed) && !empty($parsed['error'])
                   ? $parsed['error'] : ($rc === 0 ? '' : strip_ansi($raw)),
    ]);
    exit;
}

// The settings a mail client needs, for the cog on a mailbox row. Every value
// comes off the running machine, so a card that says 993 says it because 993 is
// listening. The address is the row's own, and mayAsk() has already checked the
// caller owns that row.
if (($_GET['ask'] ?? '') === 'mailclient') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    exec('sudo ' . MAILCLIENT . ' ' . escapeshellarg((string) ($_GET['address'] ?? ''))
         . ' 2>&1', $lines, $rc);
    $raw    = trim(implode("\n", $lines));
    $parsed = $rc === 0 ? json_decode($raw, true) : null;
    echo json_encode([
        'ok'       => $rc === 0 && is_array($parsed) && empty($parsed['error']),
        'settings' => $parsed ?: [],
        'error'    => is_array($parsed) && !empty($parsed['error'])
                      ? $parsed['error'] : ($rc === 0 ? '' : strip_ansi($raw)),
    ]);
    exit;
}

// The other thing that answers without a page load. Opening the mailbox drawer
// asks for the account's domains, and waiting for a form round trip to fill a
// dropdown is not a thing anyone would sit through.
//
// It runs the fetch and then reads the file, rather than parsing the script's
// output: the file is what survives a failed fetch, so reading it is what makes
// "TransIP was unreachable, here is yesterday's list" work at all.
if (($_GET['ask'] ?? '') === 'domains') {
    header('Content-Type: application/json');
    exec('sudo ' . DOMAINS . ' 2>&1', $lines, $rc);
    $known = is_readable(DOMAINFILE)
        ? array_values(array_filter(array_map('trim', file(DOMAINFILE))))
        : [];
    echo json_encode([
        'ok'      => $rc === 0,
        'domains' => $known,
        // Only shown when there is nothing to show instead, so a stale list is
        // not buried under an error about how it got stale.
        'error'   => $rc === 0 ? '' : strip_ansi(implode("\n", $lines)),
    ]);
    exit;
}

// One reader for every SETTING in the file, and it never leaves the key's own
// line. `\s*=\s*(\S*)` does: \s matches newlines, so a key with an empty value
// swallowed the NEXT key as its value. LIVE_HOST_PREFIX is empty by design, so
// every live address on the page read LIVE_PORT_OFFSETportfolio.example.com.
//
// Returns null when the key is absent, '' when it is present and empty. The
// difference decides whether a default applies.
function conf_val(string $config, string $key): ?string {
    if (!preg_match('/^[ \t]*' . preg_quote($key, '/') . '[ \t]*=([^\r\n]*)/mi', $config, $m)) {
        return null;
    }
    return trim(preg_replace('/#.*$/', '', $m[1]));
}

// WHICH TABS THIS MACHINE SHOWS. A tab is on when its service is installed or
// rows of its kind exist; TAB_<NAME> = on|off in the config overrides that.
// So a tab is hidden while its service runs only when somebody said off.
function tabs_on(string $config): array {
    $rows    = fn(string $type): bool => (bool) preg_match('/^[ \t]*' . $type . '[ \t]*\|/m', $config);
    $jenkins = is_dir('/var/lib/jenkins');
    $on = [
        'apps'         => $jenkins || $rows('app'),
        'websites'     => $jenkins || $rows('website'),
        'mailboxes'    => is_file('/etc/postfix/main.cf') || $rows('mailbox'),
        // A proxy needs a public certificate, so it follows certbot (module 9).
        'proxies'      => is_dir('/etc/letsencrypt') || $rows('proxy'),
        'machine'      => true,
        'smb'          => is_file('/etc/samba/smb.conf'),
        // Environments only name copies of apps and websites.
        'environments' => $jenkins || $rows('app') || $rows('website'),
        'ports'        => true,
        // Not the GitHub App: a machine may hold one only to push console saves.
        'repos'        => $jenkins,
        'users'        => true,
        'raw'          => true,
        'audit'        => true,
    ];
    foreach (array_keys($on) as $tab) {
        $say = strtolower((string) conf_val($config, 'TAB_' . strtoupper($tab)));
        if ($say === 'on' || $say === 'yes') $on[$tab] = true;
        if ($say === 'off' || $say === 'no') $on[$tab] = false;
    }
    return $on;
}

// The scripts colour their output for a terminal. A browser shows the escape
// codes as literal text, which made every error message unreadable.

// ONE UNIT, AS JSON, so the service dialog can tick a list of environments
// while it works instead of the page reloading with a single sentence once it
// is all over. The form-post path further down is untouched.
//
// The bound is the same one everything else here has: app_service_control.sh
// builds the unit name itself from a row it finds in the PUBLISHED config, so
// a row or an environment that is not there is refused rather than reached.
if (($_POST['action'] ?? '') === 'svcone') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $sRow  = trim($_POST['row'] ?? '');
    $sEnv  = trim($_POST['env'] ?? '');
    $sVerb = trim($_POST['verb'] ?? '');
    if (!in_array($sVerb, ['start', 'stop', 'restart'], true)
        || !preg_match('/^[A-Za-z0-9_.-]+$/', $sRow)
        || !preg_match('/^[A-Za-z0-9_.-]+$/', $sEnv)) {
        echo json_encode(['ok' => false, 'out' => 'Refused: not a verb, a row and an environment.']);
        exit;
    }
    $sLines = [];
    exec('sudo ' . SVCCTL . ' ' . escapeshellarg($sRow) . ' ' . escapeshellarg($sEnv)
        . ' ' . escapeshellarg($sVerb) . ' 2>&1', $sLines, $sRc);
    echo json_encode([
        'ok'  => $sRc === 0,
        'row' => $sRow,
        'env' => $sEnv,
        'out' => strip_ansi(implode("
", $sLines)),
    ]);
    exit;
}

// Re-run one environment's deploy, for the rerun button the owner asked for on
// 2026-09-10: one button per environment row, and the Jenkins console tailed
// live in a dialog.
//
// Answers JSON rather than reloading the page, because the dialog opens and
// starts tailing on the same press. The refusal here is shape only: the row and
// the environment are checked against the published config by
// trigger_site_job.sh, which runs as root and is the thing under review.
if (($_POST['action'] ?? '') === 'redeploy') {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $dRow = trim($_POST['row'] ?? '');
    $dEnv = trim($_POST['env'] ?? '');
    if (!preg_match('/^[A-Za-z0-9_.-]+$/', $dRow) || !preg_match('/^[a-z]+$/', $dEnv)) {
        echo json_encode(['ok' => false, 'out' => 'Refused: not a row and an environment.']);
        exit;
    }
    // A limited admin may re-run and cancel THEIR OWN rows and no others.
    // Read from the config here rather than trusted from the page: the row name
    // arrives in a POST, and a POST is written by whoever sends it.
    //
    // The config is read directly instead of using the parsed $rows further
    // down, because this handler exits long before that runs.
    if ($myRole !== 'full' && !ownsRow($me, $dRow)) {
        http_response_code(403);
        echo json_encode(['ok' => false,
            'out' => "Refused: '" . $dRow . "' is not yours."]);
        exit;
    }
    // Cancel is the same permission on the same job, so it is a flag on the
    // same command rather than a second route to reaching a build.
    $dStop = (($_POST['stop'] ?? '') === '1') ? ' --stop' : '';
    $dLines = [];
    exec('sudo ' . SITEJOB . ' ' . escapeshellarg($dRow) . ' '
        . escapeshellarg('deploy-' . $dEnv) . $dStop . ' 2>&1', $dLines, $dRc);
    echo json_encode([
        'ok'  => $dRc === 0,
        'row' => $dRow,
        'env' => $dEnv,
        'job' => $dRow . '/deploy-' . $dEnv,
        'out' => strip_ansi(implode("\n", $dLines)),
    ]);
    exit;
}

function strip_ansi(string $s): string {
    return preg_replace('/\x1b\[[0-9;]*[A-Za-z]/', '', $s);
}

// The steps of a create, as the operator should read them: what ran, what did
// not, and the reason beside the one that stopped.
//
// A create does six or eight things and used to report a single red line, so a
// failure meant reading the whole log to find how far it got. The owner's
// decision 2026-09-03.
function render_create_steps(array $steps, string $row, string $fallback = 'the last create'): string {
    if (!$steps) { return ''; }
    $label = $row !== '' ? $row : $fallback;
    $out = '<div class="create-steps">'
         . ($label !== '' ? '<p class="note">' . htmlspecialchars($label) . '</p>' : '')
         . '<ul style="list-style:none;margin:.3rem 0;padding:0">';
    foreach ($steps as $s) {
        $state = (string) ($s['state'] ?? '');
        $name  = (string) ($s['name'] ?? '');
        $note  = (string) ($s['note'] ?? '');
        // A tick, a cross or a dash, and the colour is the token so it reads
        // the same in both themes.
        $mark  = $state === 'ok' ? '&#10003;' : ($state === 'failed' ? '&#10007;' : '&ndash;');
        $col   = $state === 'ok' ? 'var(--ok,#2e7d32)'
               : ($state === 'failed' ? 'var(--bad,#c62828)' : 'var(--muted,#777)');
        $out .= '<li style="margin:.15rem 0">'
              . '<span style="display:inline-block;width:1.2rem;color:' . $col . '">' . $mark . '</span>'
              . htmlspecialchars($name);
        if ($note !== '') {
            $out .= '<span style="opacity:.65"> &middot; ' . htmlspecialchars($note) . '</span>';
        }
        // A failed step that can be rerun on its own gets the button that does
        // it. The alternative is pressing the whole create again, which asks
        // GitHub to make a repository that is already there.
        //
        // Only where the step carries an id: creating the repository and
        // pushing its branches map to none, because by the time there is a
        // step to rerun they have already happened.
        //
        // form= is load bearing. Both call sites render outside #rows-form,
        // which owns the hidden rerunstep input, and a submit button with no
        // form owner posts nothing at all and says nothing either.
        $id = (string) ($s['id'] ?? '');
        if ($state === 'failed' && $id !== '' && $row !== '') {
            $out .= ' <button type="submit" name="action" value="rerunstep"'
                  . ' class="action-btn"'
                  . ' form="rows-form"'
                  . ' formnovalidate'
                  . ' data-step="' . htmlspecialchars($id) . '"'
                  . ' onclick="document.getElementById(\'rerun-step\').value=this.dataset.step"'
                  . ' data-i18n="rerunStep">Run this step again</button>';
        }
        $out .= '</li>';
    }
    return $out . '</ul></div>';
}


// Rows whose Repository field says `new`, read from a config file rather than
// from the parsed rows: this question is asked while a POST is being handled,
// long before the page builds its row list.
function repo_wanted(string $file): array {
    $want = [];
    foreach (preg_split('/\r?\n/', (string) @file_get_contents($file)) as $line) {
        if ($line === '' || ltrim($line)[0] === '#') { continue; }
        if (strpos($line, '|') === false) { continue; }
        $f = array_map('trim', explode('|', $line));
        if (count($f) < 9) { continue; }
        if (strtolower($f[8]) === 'new' && $f[1] !== '') { $want[] = $f[1]; }
    }
    return $want;
}
// These scripts print their progress for a human and their result as one JSON
// line at the end, so the object is the last line that parses, never the whole
// output. Imploding everything glued the headers onto the JSON, and every
// successful mailbox change was reported as a failure.
function json_result(array $lines): ?array {
    for ($i = count($lines) - 1; $i >= 0; $i--) {
        $line = trim(strip_ansi($lines[$i]));
        if ($line === '' || $line[0] !== '{') { continue; }
        $decoded = json_decode($line, true);
        if (is_array($decoded)) { return $decoded; }
    }
    return null;
}

// Keep script feedback readable: show a compact outcome first, while preserving
// the full command log for troubleshooting.
function summarize_output(string $text): string {
  $lines = preg_split('/\r?\n/', $text);
  if (!$lines) {
    return '';
  }

  $out = [];
  $hiddenUnchanged = 0;

  foreach ($lines as $line) {
    $raw = trim($line);
    if ($raw === '') {
      continue;
    }

    if (preg_match('/^✅\s+Unchanged:/u', $raw)) {
      $hiddenUnchanged++;
      continue;
    }

    if (preg_match('/^(===|✅|⚠️|❌|🔧)/u', $raw)) {
      $out[] = $raw;
      continue;
    }

    if (preg_match('/no answer|did not|failed|failure|error:|returned exit code|finished:/i', $raw)) {
      $out[] = $raw;
    }
  }

  if ($hiddenUnchanged > 0) {
    array_unshift($out, '✅ Hidden ' . $hiddenUnchanged . ' very long "Unchanged" line(s).');
  }

  return $out ? implode("\n", $out) : trim($text);
}

// -----------------------------------------------------------------------------
// Actions
// -----------------------------------------------------------------------------
// =============================================================================
// The folder picker's one endpoint.
//
// Answered before anything else on the page is built, and it exits: this is the
// only thing here that returns JSON rather than a page. GET, because it reads
// and changes nothing.
//
// The path is the caller's, which is what a picker means. list_folders.sh is
// what makes that safe: it resolves the path and refuses anything landing
// outside /srv, /var/www, /mnt, /media or a home, and it reports folder names
// only.
// =============================================================================
// The folder-permission endpoint, read and write.
//
// GET  ?access=<path>                     what the group can do there now
// POST action=setaccess, path, rwx        set it
//
// The path is the caller's, which is unavoidable: a permission is set on a
// path. set_share_access.sh is what makes it safe, and it refuses three
// things this page never has to reason about: anything outside the folders a
// share may use, anything owned by a system account, and "other" in any form.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['access'])) {
    header('Content-Type: application/json');
    $cmd = 'sudo ' . SHAREACL . ' --check ' . escapeshellarg((string) $_GET['access'])
         . ' ' . escapeshellarg(SMB_SHARE_GROUP) . ' 2>/dev/null';
    exec($cmd, $lines, $rc);
    $body = trim(implode('', $lines));
    echo ($rc === 0 && $body !== '' && json_decode($body) !== null)
        ? $body
        : '{"error":"could not read that folder"}';
    exit;
}

// Re-run the drift check after a Jenkins apply has finished.
//
// The banner is built from the last check, and the check that ran with the
// press happened BEFORE the build wrote anything, so a successful apply left
// the page still showing the drift it had just fixed. Fix drift already
// re-checks itself; this gives the slow path the same manners.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['recheck'])) {
    header('Content-Type: application/json');
    exec('sudo ' . CHECK . ' 2>&1', $rcLines, $rcRc);
    echo json_encode(['ok' => $rcRc === 0]);
    exit;
}

// Asked for by the drawer when a row wants a new repository, never on page
// load: it costs a sudo call and three GitHub round trips per owner, and most
// visits never open a row that needs it.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['repos'])) {
    header('Content-Type: application/json');
    exec('sudo ' . LISTREPOS . ' 2>/dev/null', $lines, $rc);
    $body = trim(implode('', $lines));
    // An empty answer is not an error the operator can act on. The check is a
    // convenience that saves a failed apply; provision_repo.sh refuses a clash
    // on the machine whatever this returns.
    echo ($rc === 0 && $body !== '' && json_decode($body) !== null)
        ? $body
        : '{"create_owner":"","owners":{}}';
    exit;
}

// The branches in a repository, asked for as soon as a clone URL is filled in.
//
// The URL crosses from the browser, because the drawer has one before the row
// is saved and therefore before anything could look it up in the config. It is
// checked here AND in the script, because a value that reaches sudo is a value
// worth refusing twice: only https://github.com/<owner>/<name>, nothing else.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['branches'])) {
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    $url = trim((string) $_GET['branches']);
    if (!preg_match('#^https://github.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(.git)?$#', $url)) {
        echo json_encode(['ok' => false, 'error' => 'not a github.com clone URL']);
        exit;
    }
    exec('sudo ' . LISTBRANCHES . ' ' . escapeshellarg($url) . ' 2>/dev/null', $lines, $rc);
    $body = trim(implode('', $lines));
    echo ($body !== '' && json_decode($body) !== null)
        ? $body
        : json_encode(['ok' => false, 'error' => 'the repository could not be read']);
    exit;
}

// Which project in an application row's repository is the one to run.
//
// Asked for by the drawer when an application row is opened, never on page
// load: it clones a branch, and most visits never open one.
//
// The ROW NAME is all that crosses, never a repository URL or a path. The
// script reads the row out of the published config itself and validates the
// name against the shape a row name may have, so the page cannot be talked
// into reading a repository nobody configured.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['projects'])) {
    header('Content-Type: application/json');
    $row = (string) $_GET['projects'];
    exec('sudo ' . LISTPROJECTS . ' ' . escapeshellarg($row) . ' 2>/dev/null', $lines, $rc);
    $body = trim(implode('', $lines));
    // The dropdown is a convenience and the box beside it still takes a typed
    // name, so an unreadable repository is an empty list rather than a page
    // error.
    echo ($rc === 0 && $body !== '' && json_decode($body) !== null)
        ? $body
        : '{"error":"could not read that repository"}';
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['folders'])) {
    header('Content-Type: application/json');
    $where = (string) $_GET['folders'];
    // Two root sets, chosen here and validated by the script: a share and a
    // machine page may point at different places. Anything but the one known
    // alternative falls back to the share set rather than being passed on.
    $for = (($_GET['for'] ?? '') === 'pages') ? ' --for pages' : '';
    $cmd = 'sudo ' . LISTDIRS . $for . ($where === '' ? '' : ' ' . escapeshellarg($where)) . ' 2>/dev/null';
    exec($cmd, $lines, $rc);
    $body = trim(implode('', $lines));
    // A non-zero exit or unparseable output is reported as an empty list rather
    // than as a page error: the picker is a convenience and the box beside it
    // still takes a typed path.
    echo ($rc === 0 && $body !== '' && json_decode($body) !== null)
        ? $body
        : '{"error":"could not read that folder"}';
    exit;
}

if ($_SERVER['REQUEST_METHOD'] === 'POST') {
    $action = $_POST['action'] ?? '';

    // One button, two acts. save_apply publishes and then starts the apply job,
    // and it is only ever reached from the dialog that has just shown what would
    // change. The drift is read BEFORE anything is written, which is the
    // property the separate Save and Apply buttons existed to protect.
    // MAILBOX OPS RUN BEFORE THE PUBLISH. Decided 2026-09-03.
    //
    // They used to run after it, gated on a good publish, so a refused op left
    // the config line DELETED and the mailbox untouched: half applied, reported
    // as done. Seen twice on 2026-09-03, both times a forward to a contact@
    // that had no maildir.
    //
    // Ordered this way a refused op means the row is still there, which needs
    // no rollback and is the honest outcome.
    //
    // The cost, and it is real: an op that succeeds and a publish that then
    // fails leaves the mailbox changed and the row unchanged. That is the
    // better half to be on. A mailbox that has been forwarded still delivers;
    // a row deleted with its mailbox left behind is invisible everywhere until
    // the next deletion trips over it.
    //
    // The REPOSITORY ops deliberately stay after the publish: deleting a
    // repository cannot be undone, so it must not happen for a save that is
    // then refused.
    //
    // manage_mail.sh validates each op itself; escapeshellarg stops the shell
    // seeing anything but two words, whatever a value contains.
    // ONE PRESS, FOUR JOBS, AND EACH SAYS WHAT IT DID.
    //
    // A save runs the mailbox changes, the publish, the repository changes and
    // the apply, and reported a single sentence for all four. So a failure
    // anywhere read as "the save failed", and which of the four had actually
    // run was left to be worked out from a mixed machine.
    //
    // Same shape as the create's step report, deliberately: same array, same
    // renderer, same file. The owner, 2026-09-03: things break less when they are
    // segmented, and a small part can be fixed on its own.
    $saveSteps = [];
    $save_step = function (string $name, string $state, string $note = '') use (&$saveSteps) {
        $saveSteps[] = ['name' => $name, 'state' => $state, 'note' => $note];
    };

    $mailBlocked = false;

    // A LIMITED ADMIN'S MAIL AND REPOSITORY OPS TOUCH ONLY WHAT THEY OWN. Item 136.
    // Both run beside the config check rather than through it, so a POST could
    // name anybody's mailbox or repository. Checked against the live file,
    // before any op runs.
    if ($myRole !== 'full' && in_array($action, ['save', 'save_fast', 'save_apply'], true)) {
        $opsWhy = '';
        foreach ((array) json_decode((string) ($_POST['mailops'] ?? ''), true) as $op) {
            $local = (string) ($op['local'] ?? '');
            $dom = (string) ($op['domain'] ?? '');
            if (!ownsMailbox($me, $local, $dom)) { $opsWhy = $local . '@' . $dom . ' is not yours to change.'; break; }
        }
        if ($opsWhy === '' && ($_POST['repoops'] ?? '') !== '') {
            $mySlugs = [];
            foreach (rowsByName((string) @file_get_contents(CONF)) as $f) {
                if (trim($f[15] ?? '') !== $me) continue;
                if (preg_match('#github\.com[/:]([^/\s]+/[^/\s]+?)(\.git)?/?$#', trim($f[8] ?? ''), $sm)) {
                    $mySlugs[strtolower($sm[1])] = true;
                }
            }
            foreach ((array) json_decode((string) $_POST['repoops'], true) as $op) {
                $slug = strtolower((string) ($op['slug'] ?? ''));
                if (!isset($mySlugs[$slug])) { $opsWhy = "The repository '" . $slug . "' is not yours to change."; break; }
            }
        }
        if ($opsWhy !== '') {
            $mailBlocked = true;
            $message = 'Refused: ' . $opsWhy;
            $messageClass = 'bad';
            unset($_POST['mailops'], $_POST['repoops']);
        }
    }

    if (!$mailBlocked && in_array($action, ['save', 'save_fast', 'save_apply'], true)
        && ($_POST['mailops'] ?? '') !== '') {
        $ops = json_decode((string) $_POST['mailops'], true);
        if (is_array($ops)) {
            $mailDone = 0;
            $mailFail = [];
            // Removals skipped because the address could never have existed.
            $mailSkipped = [];

            // ALL OR NOTHING, checked before the first op runs.
            //
            // A forward needs contact@<domain> to have a maildir, or it is a
            // black hole rather than a redirect, and manage_mail.sh refuses it.
            // Refused halfway through a batch, some addresses are forwarded and
            // some are not, and the operator has to work out which. Asking
            // first costs one --check per domain and makes the batch atomic in
            // the only way that matters: nothing starts unless all of it can.
            //
            // The owner's decision 2026-09-03, the half of it that was not already
            // true. contact@ itself is excluded from bulk delete in bulk.js.
            $fwdDomains = [];
            foreach ($ops as $op) {
                if (($op['verb'] ?? '') !== 'forward') { continue; }
                $d = (string) ($op['domain'] ?? '');
                if ($d !== '') { $fwdDomains[$d] = true; }
            }
            foreach (array_keys($fwdDomains) as $d) {
                $cLines = [];
                exec('sudo ' . MANAGEMAIL . ' --check contact ' . escapeshellarg($d)
                     . ' 2>&1', $cLines, $cRc);
                $cRes = json_result($cLines);
                if ($cRc !== 0 || !is_array($cRes) || empty($cRes['maildir'])) {
                    $mailFail[] = 'contact@' . $d
                                . ': no maildir, so forwarding to it would bounce. Provision contact@'
                                . $d . ' first.';
                }
            }

            foreach ($mailFail ? [] : $ops as $op) {
                $verb   = $op['verb']   ?? '';
                $local  = (string) ($op['local']  ?? '');
                $domain = (string) ($op['domain'] ?? '');
                if (!in_array($verb, ['forward', 'retire', 'unforward', 'purge'], true)) { continue; }
                // A ROW WHOSE ADDRESS CANNOT EXIST HAS NOTHING TO REMOVE, so
                // removing it must not be blocked by the mail step. Found
                // 2026-09-11: an approval wrote a mailbox row with the domain
                // `=example.com`, manage_mail.sh refused it as not a usable
                // domain name, and the refusal stopped the whole save, which
                // meant the bad row could not be deleted from the console at
                // all. A row you cannot delete is a worse failure than a mail
                // op that was skipped for an account that was never created.
                //
                // Only for the two verbs that REMOVE. Creating or forwarding to
                // an unusable address is still refused, which is the check
                // doing its job.
                $badDomain = !preg_match('/^[a-z0-9]([a-z0-9.-]*[a-z0-9])?$/', $domain);
                if ($badDomain && in_array($verb, ['retire', 'purge'], true)) {
                    $mailSkipped[] = $local . '@' . $domain;
                    continue;
                }
                $mLines = [];
                exec('sudo ' . MANAGEMAIL . ' --' . $verb
                     . ' ' . escapeshellarg($local)
                     . ' ' . escapeshellarg($domain) . ' 2>&1', $mLines, $mRc);
                $res = json_result($mLines);
                if ($mRc === 0 && is_array($res) && empty($res['error'])) {
                    $mailDone++;
                } else {
                    $mailFail[] = $local . '@' . $domain
                                . (is_array($res) && !empty($res['error']) ? ': ' . $res['error'] : '');
                }
            }
            if ($mailFail) {
                // Nothing is published. The rows those ops belong to are still
                // in the config, which is what makes this recoverable: fix the
                // reason and press again.
                $mailBlocked = true;
                $message = 'Nothing was saved. Some mailbox changes could not be made, so the rows were left alone: '
                         . implode('; ', $mailFail);
                if ($mailDone > 0) {
                    $message .= ' ' . $mailDone . ' other mailbox change'
                              . ($mailDone === 1 ? ' was' : 's were') . ' already made and did NOT get undone.';
                }
                $messageClass = 'bad';
                $save_step('mailbox changes', 'failed', implode('; ', $mailFail));
            } elseif ($mailDone > 0 || $mailSkipped) {
                $mailApplied = $mailDone;
                // The skip is REPORTED rather than silent: a row was removed
                // and nothing was done to mail for it, and the operator should
                // read that rather than deduce it.
                $note = $mailDone . ' address' . ($mailDone === 1 ? '' : 'es');
                if ($mailSkipped) {
                    $note .= '; nothing to remove for ' . implode(', ', $mailSkipped)
                           . ' (the address could never have existed)';
                }
                $save_step('mailbox changes', 'ok', $note);
            }
        }
    }

    if ($mailBlocked) {
        $save_step('publish the config', 'skipped', 'a mailbox change was refused');
    }

    if (!$mailBlocked && ($action === 'save' || $action === 'save_apply' || $action === 'save_fast')) {
        $candidate = $_POST['config'] ?? '';
        if ($myRole !== 'full' && trim((string) $candidate) !== '') {
            $candidate = mergeLimitedSave((string) $candidate, $me) ?? '';
        }

        // THE BACKSTOP. A limited admin reaches this path like anybody else,
        // which is what keeps the page to one save flow, and every difference
        // they post is compared against the live file here. The drawer's field
        // gating is what makes the page sensible; this is what makes it safe,
        // because a field the drawer does not offer is still a field a POST can
        // carry.
        $limitedWhy = ($myRole !== 'full')
            ? limitedSaveProblem((string) $candidate, $me) : '';
        // One domain, one admin, whoever is saving. The owner, 2026-09-16.
        if ($limitedWhy === '' && trim((string) $candidate) !== '') {
            $limitedWhy = ownership((string) $candidate)['conflict'];
        }

        if ($limitedWhy !== '') {
            $message = 'Refused: ' . $limitedWhy;
            $messageClass = 'bad';
        } elseif (trim($candidate) === '') {
            $message = 'The config was empty, so nothing was saved.';
            $messageClass = 'bad';
        } else {
            // Normalise line endings. A browser sends CRLF and every reader of
            // this file expects LF.
            $candidate = str_replace("\r\n", "\n", $candidate);

            // What the page was shown, so the publisher can refuse to write on
            // top of a file that has moved since. A whole-file post cannot
            // merge, so the only safe answer to a moved file is to stop.
            //
            // Checked, because it silently failed for weeks: the file did not
            // exist and the directory is not writable by www-data, so the guard
            // never ran and a stale page reverted a day of work on 2026-08-10.
            // Hex only: a newline in it would replace the "saved by" line below.
            $postedBase = preg_replace('/[^0-9a-f]/i', '', (string) ($_POST['base'] ?? ''));
            $wroteBase = @file_put_contents(BASEHASH, $postedBase . "\n" . savedBy($me) . "\n");

            if ($wroteBase === false) {
                $message = 'Could not write ' . BASEHASH . ', so nothing was saved. '
                         . 'Without it the publisher cannot tell whether the file moved '
                         . 'while this page was open. Run add_hosting_manager.sh on the machine.';
                $messageClass = 'bad';
                $save_step('publish the config', 'failed', 'cannot write ' . BASEHASH);
            } elseif (file_put_contents(STAGING, $candidate) === false) {
                $message = 'Could not write the candidate file. Check permissions on ' . STAGING;
                $messageClass = 'bad';
                $save_step('publish the config', 'failed', 'cannot write ' . STAGING);
            } else {
                exec('sudo ' . PUBLISH . ' 2>&1', $lines, $rc);
                $output = strip_ansi(implode("\n", $lines));
                // Exit 3: the branch already held exactly this config. Carried on
                // as a success, but never reported as "saved".
                $publishNoChange = ($rc === 3);
                if ($publishNoChange) { $rc = 0; }

                if ($rc !== 0) {
                    $message = 'Not saved. Nothing on the machine changed.';
                    $messageClass = 'bad';
                    $save_step('publish the config', 'failed', 'the publisher refused');
                    // A refused publish loses the edit that was just made, so it
                    // gets a dialog rather than a line among the others. Found
                    // on 2026-08-31: a stale page was refused correctly, the
                    // page said so, and nobody read it. The publisher's own
                    // wording is carried through, so this says WHICH refusal.
                    $publishRefused = true;
                } elseif ($action === 'save' || $action === 'save_fast') {
                    // save_fast applies below, here and now, without Jenkins.
                    $message = 'Saved and pushed. Nothing on the machine has changed.';
                    $messageClass = 'good';
                    $save_step('publish the config', 'ok', 'committed and pushed');
                } else {
                    $save_step('publish the config', 'ok', 'committed and pushed');
                    // The build number BEFORE the job is started. An idle answer
                    // on its own means both "not queued yet" and "already
                    // over"; a number greater than this one means only the
                    // second.
                    $applyFrom = -1;
                    exec('sudo ' . JOBSTATUS . ' 2>/dev/null', $stLines, $stRc);
                    if ($stRc === 0) {
                        $st = json_result($stLines);
                        $n = $st['jobs']['hosting-apply']['number'] ?? null;
                        if (is_int($n)) { $applyFrom = $n; }
                    }

                    // Saving succeeded, so the branch now holds what the drift
                    // report was computed from. Only now is the machine touched.
                    exec('sudo ' . APPLY . ' 2>&1', $applyLines, $applyRc);
                    $output .= "\n" . strip_ansi(implode("\n", $applyLines));
                    // Three outcomes, not two. Exit 2 is trigger_apply.sh
                    // saying an apply was ALREADY running: the config is
                    // published and correct, and the running job started
                    // before it, so it does not carry it. Reported as bad
                    // until 2026-09-04, wording and all, which read as a
                    // failure with nothing to do about it.
                    if ($applyRc === 0) {
                        $message = 'Saved, pushed, and the apply job has started. Watch it in Jenkins.';
                        $messageClass = 'good';
                        $save_step('start the apply job', 'ok', 'running in Jenkins');
                    } elseif ($applyRc === 2) {
                        $message = 'Saved and pushed. An apply was already running and it started '
                                 . 'before this change, so it does not carry it. Press Apply '
                                 . 'again once that build has finished.';
                        // good, not a new class. The PUBLISH succeeded, and
                        // every gate further down (the repository ops, the
                        // mail ops, the redirect that stops F5 replaying the
                        // POST) keys on good meaning exactly that. A new class
                        // here would silently skip all of them.
                        $messageClass = 'good';
                        $save_step('start the apply job', 'skipped', 'an apply was already running');
                    } else {
                        $message = 'Saved and pushed, but the apply job did not start. The machine is unchanged.';
                        $messageClass = 'bad';
                        $save_step('start the apply job', 'failed', 'the job did not start');
                    }
                }
            }
        }
    }

    // Checks what is in the browser, not what is on the branch. The candidate is
    // staged first so the checker validates the edit rather than the config it
    // is about to replace, which is the only version worth checking before a
    // save.
    if ($action === 'recheck') {
        $candidate = $_POST['config'] ?? '';
        if (trim($candidate) !== '') {
            file_put_contents(STAGING, str_replace("\r\n", "\n", $candidate));
            // The draft keeps the base it was edited against, which Save posts back.
            $postedBase = preg_replace('/[^0-9a-f]/i', '', (string) ($_POST['base'] ?? ''));
            @file_put_contents(BASEHASH, $postedBase . "\n" . savedBy($me) . "\n");
        }
        exec('sudo ' . CHECK . ' 2>&1', $lines, $rc);
        $message = $rc === 0
            ? 'Checked. Nothing was written and nothing was pushed.'
            : 'The check failed. The report below says why.';
        $messageClass = $rc === 0 ? 'good' : 'bad';

        // The single button checks first and comes back here. The dialog then
        // opens by itself, holding a report computed from exactly the config
        // that is about to be saved and applied.
        $autoConfirm = ($_POST['intent'] ?? '') === 'apply';
    }

    // The only action that changes the machine, which is why it is its own
    // button and not part of saving.
    // The fast path: vhosts and preview ports, here, now, no Jenkins. Measured
    // 2026-08-25 at about 15 seconds against two minutes, because the job spent
    // 100 of those on queueing, fetching and checking things a vhost edit does
    // not touch. Anything involving a repository, a certificate or a unit still
    // goes through the job below.
    // Keep this change, on a row drawer: publish, then write the vhosts here
    // rather than through Jenkins. Only when the publish worked, because
    // applying a config that was refused would write the previous one and
    // report success.
    if ($action === 'save_fast' && $messageClass === 'good') {
        exec('sudo ' . FASTAPPLY . ' 2>&1', $fastLines, $fastRc);
        $output = trim($output . "\n" . strip_ansi(implode("\n", $fastLines)));
        $message = $fastRc === 0
            ? 'Saved and live. Vhosts and preview ports were written; units, certificates and repositories were not touched.'
            : 'Saved, but the apply failed. The machine still serves the previous config.';
        $messageClass = $fastRc === 0 ? 'good' : 'bad';

        // VERIFY, THEN ESCALATE. The owner, 2026-09-07: "I am surprised with oh
        // there is a drift since we know what actions are performed and how to
        // close the drift before I need to click the button".
        //
        // He is right. Drift after the operator's OWN save is this page failing
        // to finish, and it happened three separate ways in one afternoon: a
        // deleted row classified fast-safe, environments ticked off, and the
        // mail stack skipped in the one case it had work to do. Two are fixed
        // and one was never reproduced.
        //
        // So this checks the OUTCOME rather than predicting it. Whatever routed
        // wrongly, and whatever routes wrongly next, the save now notices the
        // machine does not match and hands the rest to the full job itself.
        //
        // Once, and only upward. It never re-runs the fast path it has just
        // proved insufficient, so there is no loop to get stuck in.
        if ($fastRc === 0) {
            exec('sudo ' . CHECK . ' 2>&1', $vLines, $vRc);
            $stillFast = true;
            $stillAny  = false;
            foreach (explode("\n", (string) @file_get_contents(REPORT)) as $l) {
                if (!preg_match('/^\s*(ADD|UPDATE|ORPHAN)\s+(\S+)\s/', $l, $m)) { continue; }
                $stillAny = true;
                if ($m[1] === 'ORPHAN' || !in_array($m[2], ['vhost', 'preview'], true)) {
                    $stillFast = false;
                }
            }
            // Drift the fast path could still close is left alone: it has just
            // run, so anything of that shape is a real fault worth showing
            // rather than papering over with a second identical run.
            if ($stillAny && !$stillFast) {
                exec('sudo ' . APPLY . ' 2>&1', $escLines, $escRc);
                $output = trim($output . "\n" . strip_ansi(implode("\n", $escLines)));
                if ($escRc === 0) {
                    $message = 'Saved. That change needed a prune, a unit or a certificate, so the full apply job was started for you.';
                    $escalatedToJob = true;
                } elseif ($escRc === 2) {
                    // Exit 2 as on the plain save path: published, vhosts
                    // written, but a running apply predates this change.
                    $message = 'Saved and the vhosts were written. That change also needs the full apply, '
                             . 'but one was already running and it started before this change. Press '
                             . 'Apply again once that build has finished.';
                } else {
                    $message .= ' The machine still does not match, and the full apply job could not be started.';
                    $messageClass = 'bad';
                }
            }
        }
    }

    // Fix drift: the fast apply on its own, with nothing saved and nothing
    // pushed. The banner that offers it has already decided the drift is only
    // vhosts, which is exactly what this writes.
    //
    // The check is re-run afterwards because the banner is built from the
    // report file: without it the page would come back still claiming the drift
    // it has just written away.
    // The rehearsal. Writes nothing on the machine, and writes its verdict to
    // the file the page reads, which is what makes the real button appear.
    if ($action === 'golivetest') {
        exec('sudo ' . GOLIVE . ' --check 2>&1', $glLines, $glRc);
        $output = strip_ansi(implode("\n", $glLines));
        if ($glRc === 0) {
            $message = 'The rehearsal passed. This machine answers on its own domain, so it really has been swapped in. The Go live button is now available.';
            $messageClass = 'good';
        } else {
            $message = 'Not ready to go live, and nothing was changed. The output below says which check failed.';
            $messageClass = 'bad';
        }
    }

    // The real thing. Guarded on the machine as well as here: go_live.sh runs
    // every check again and refuses on any failure, so a stale passing report
    // on this page cannot spend a certificate or write a DNS record.
    if ($action === 'golive') {
        exec('sudo ' . GOLIVE . ' 2>&1', $glLines, $glRc);
        $output = strip_ansi(implode("\n", $glLines));
        if ($glRc === 0) {
            $message = 'This machine is live. Certificates promoted and the address record written. The output below lists what still needs a human: the PTR, SPF, and the router.';
            $messageClass = 'good';
        } else {
            $message = 'Going live did not finish. The output below says how far it got.';
            $messageClass = 'bad';
        }
    }

    // One button, two paths, and the page picks. It used to run the fast apply
    // and nothing else, so drift needing a prune, a unit or a certificate sent
    // the operator to Make it live, which is the emergency fallback and not a
    // thing routine work should ever land on.
    // THE ONLY THING THAT CAN CLEAR A STAGED CANDIDATE.
    //
    // Nothing could, before this. discardChanges() in bulk.js reloads the page,
    // and the page is BUILT from the candidate, so a reload showed the same
    // staged edit again: "Discard puts the saved version back" was not true
    // while a candidate existed on disk. Item 78's stale candidate had to be
    // deleted over SSH.
    //
    // TRUNCATED, NOT DELETED, and that is not a preference. /var/lib/hosting-
    // manager is root:root 0755, so www-data can write a file it owns in there
    // and can NEVER unlink one: removing a directory entry needs write on the
    // DIRECTORY. The first version of this used unlink() and failed on the
    // machine, correctly reporting that it could not.
    //
    // Emptying is enough: the page already treats a blank candidate as no
    // candidate, and publish_hostings.sh's clear_staging() clears both files
    // the same way, by writing /dev/null over them.
    //
    // The base hash goes too. A candidate without its base cannot be checked
    // for staleness, and a base without its candidate describes nothing.
    if ($action === 'discardstaged') {
        $clear = static function (string $f): bool {
            if (!file_exists($f)) { return true; }
            return @file_put_contents($f, '') !== false;
        };
        $goneConf = $clear(STAGING);
        $clear(BASEHASH);
        if ($goneConf) {
            $message = 'The staged change was discarded. This page now shows what is on the branch.';
            $messageClass = 'good';
        } else {
            $message = 'Could not clear ' . STAGING . '. Check that hosting-manager, the account this page runs as, owns it.';
            $messageClass = 'bad';
        }
    }
    if ($action === 'fixdrift') {
        // Read here rather than reused from further down: the drift card is
        // built long after this block runs, and a POST never reaches it.
        $fixFast = true;
        foreach (explode("\n", (string) @file_get_contents(REPORT)) as $l) {
            if (!preg_match('/^\s*(ADD|UPDATE|ORPHAN)\s+(\S+)\s/', $l, $m)) { continue; }
            if ($m[1] === 'ORPHAN' || !in_array($m[2], ['vhost', 'preview'], true)) {
                $fixFast = false;
                break;
            }
        }
        if ($fixFast) {
            exec('sudo ' . FASTAPPLY . ' 2>&1', $fixLines, $fixRc);
            $output = strip_ansi(implode("\n", $fixLines));
            if ($fixRc === 0) {
                exec('sudo ' . CHECK . ' 2>&1', $reLines, $reRc);
                $message = 'Drift fixed. Vhosts and preview ports were rewritten; nothing was saved or pushed.';
                $messageClass = 'good';
            } else {
                $message = 'The fix failed. The machine still serves the previous config, and the output below says why.';
                $messageClass = 'bad';
            }
        } else {
            // Same as the save path: the dialog needs the build number from
            // before the press to tell the new run from the last one.
            $applyFrom = -1;
            exec('sudo ' . JOBSTATUS . ' 2>/dev/null', $stLines, $stRc);
            if ($stRc === 0) {
                $n = json_result($stLines)['jobs']['hosting-apply']['number'] ?? null;
                if (is_int($n)) { $applyFrom = $n; }
            }
            exec('sudo ' . APPLY . ' 2>&1', $fixLines, $fixRc);
            $output = strip_ansi(implode("\n", $fixLines));
            $message = $fixRc === 0
                ? 'This drift needs the full apply, so it was started. ' . WATCH_APPLY
                : 'Could not start the apply job. Nothing changed.';
            $messageClass = $fixRc === 0 ? 'good' : 'bad';
            // This press started the SAME Jenkins job that Save and apply
            // starts, so it gets the same watching dialog. It did not: the
            // redirect carries done=driftfixed, and only done=applied armed the
            // watcher, so a job that runs for minutes started behind a page
            // that said nothing was happening.
            if ($fixRc === 0) { $driftStartedJob = true; }
        }
    }

    // The mailbox ops ran BEFORE the publish, above. Their success is reported
    // here, once the publish has had its say, so the sentence reads in the
    // order the work happened.
    if (($mailApplied ?? 0) > 0 && $messageClass === 'good') {
        $message .= ' ' . $mailApplied . ' mailbox change'
                  . ($mailApplied === 1 ? '' : 's') . ' applied.';
    } elseif (($mailApplied ?? 0) > 0) {
        // The ops went through and the publish did not. Say so plainly: this is
        // the half-applied case the new order accepts, and hiding it would make
        // the mailbox and the config disagree with nothing on screen about it.
        $message .= ' ' . $mailApplied . ' mailbox change'
                  . ($mailApplied === 1 ? ' was' : 's were')
                  . ' already made before this failed, and did NOT get undone.';
    }

    // Archiving or deleting the repository of a row that was just removed.
    // Only after a good publish, like the mailbox ops: the config line leaving
    // and the repository going are one act, and the irreversible half must not
    // happen for a save that was refused.
    //
    // manage_repo.sh validates the slug and refuses an owner the App is not
    // installed on, so escapeshellarg here is the second guard, not the only one.
    if (in_array($action, ['save', 'save_fast', 'save_apply'], true)
        && $messageClass === 'good'
        && ($_POST['repoops'] ?? '') !== '') {
        $rops = json_decode((string) $_POST['repoops'], true);
        if (is_array($rops)) {
            $repoDone = [];
            $repoFail = [];
            foreach ($rops as $op) {
                $verb = $op['verb'] ?? '';
                $slug = (string) ($op['slug'] ?? '');
                // Reported, never skipped in silence. An op that goes nowhere
                // without a word is how a row was deleted with Delete it
                // answered and the repository left standing on GitHub.
                if (!in_array($verb, ['archive', 'delete'], true)) {
                    $repoFail[] = ($slug !== '' ? $slug : '(no repository)')
                                . ': not archive or delete, so nothing was done';
                    continue;
                }
                if (!preg_match('#^[^/]+/[^/]+$#', $slug)) {
                    $repoFail[] = '(no owner/name): ' . $verb . ' was asked for and could not be done';
                    continue;
                }
                $rLines = [];
                exec('sudo ' . MANAGEREPO . ' --' . $verb . ' ' . escapeshellarg($slug)
                     . ' 2>&1', $rLines, $rRc);
                $res = json_result($rLines);
                if ($rRc === 0 && is_array($res) && !empty($res['ok'])) {
                    $repoDone[] = $verb . 'd ' . $slug;
                } else {
                    $repoFail[] = $slug
                        . (is_array($res) && !empty($res['error']) ? ': ' . $res['error'] : '');
                }
            }
            if ($repoDone) { $message .= ' Repositories: ' . implode(', ', $repoDone) . '.'; }
            if ($repoFail) {
                $message .= ' A repository could not be changed: ' . implode('; ', $repoFail);
                $messageClass = 'bad';
                $save_step('repository changes', 'failed', implode('; ', $repoFail));
            } elseif ($repoDone) {
                $save_step('repository changes', 'ok', implode(', ', $repoDone));
            }
        }
    }

    // The publish was refused, so the irreversible half was deliberately not
    // run. Said out loud, because the row is still on the page and the operator
    // has no other way to know the repository was left alone.
    if (in_array($action, ['save', 'save_fast', 'save_apply'], true)
        && $messageClass !== 'good'
        && ($_POST['repoops'] ?? '') !== '') {
        $message .= ' No repository was archived or deleted: the save itself was refused,'
                  . ' and a repository is not touched for a change that did not publish.';
    }

    // Repositories, on the same press. A row that says `new` asked to have one
    // created when it was written, and a second button for it meant a row could
    // be saved, applied, and still have nothing to deploy.
    //
    // Only after a good publish, for the same reason the mailbox ops are: the
    // provisioner reads the config on the branch. It writes the URL back into
    // the row itself, so the file changes underneath this page and the reload
    // afterwards is what shows it.
    if (in_array($action, ['save', 'save_fast', 'save_apply'], true)
        && $messageClass === 'good'
        && ($pendingRepos = repo_wanted(CONF))) {
        $provLines = [];
        exec('sudo ' . PROVISION . ' --create 2>&1', $provLines, $provRc);
        $output .= "\n" . strip_ansi(implode("\n", $provLines));
        if ($provRc === 0) {
            $message .= ' ' . count($pendingRepos) . ' repository(ies) provisioned: '
                      . implode(', ', $pendingRepos) . '.';
        } else {
            $message .= ' A repository could not be created: the output below says why.';
            $messageClass = 'bad';
        }
    }

    // The default password of a mailbox that was just created, carried with the
    // save because the address is not in the published config until the publish
    // lands. Only after a good publish, for the same reason as the mailbox ops:
    // set_mail_password.sh will not touch an address the config does not claim.
    //
    // proc_open, not exec: the password goes down stdin, because an argument is
    // visible in ps to every account on the machine.
    if (in_array($action, ['save', 'save_fast', 'save_apply'], true)
        && $messageClass === 'good'
        && ($_POST['mailpw'] ?? '') !== '') {
        $pws = json_decode((string) $_POST['mailpw'], true);
        if (is_array($pws)) {
            $pwDone = 0;
            $pwFail = [];
            foreach ($pws as $one) {
                $local  = trim((string) ($one['local']  ?? ''));
                $domain = trim((string) ($one['domain'] ?? ''));
                $secret = (string) ($one['pw'] ?? '');
                if ($local === '' || $domain === '' || $secret === '') { continue; }
                $pipes = [];
                $proc = proc_open(
                    'sudo ' . MAILPW . ' --set ' . escapeshellarg($local)
                    . ' ' . escapeshellarg($domain) . ' 2>&1',
                    [0 => ['pipe', 'r'], 1 => ['pipe', 'w']], $pipes);
                if (!is_resource($proc)) { $pwFail[] = $local . '@' . $domain; continue; }
                fwrite($pipes[0], $secret . "
");
                fclose($pipes[0]);
                $raw = stream_get_contents($pipes[1]);
                fclose($pipes[1]);
                $rcPw = proc_close($proc);
                // The script reports a refusal as {"error":...} on its last
                // line rather than as a failing exit code, so the code alone is
                // not the answer. Same reading as the setmailpw action.
                $res = json_result(preg_split('/?
/', strip_ansi((string) $raw)));
                if ($rcPw === 0 && is_array($res) && empty($res['error'])) {
                    $pwDone++;
                } else {
                    $pwFail[] = $local . '@' . $domain
                              . (is_array($res) && !empty($res['error']) ? ': ' . $res['error'] : '');
                }
            }
            unset($pws, $secret);
            if ($pwDone > 0) {
                $message .= ' ' . $pwDone . ' mailbox password' . ($pwDone === 1 ? '' : 's') . ' set.';
            }
            if ($pwFail) {
                $message .= ' A mailbox was created WITHOUT a password and nobody can sign in to it: '
                          . implode('; ', $pwFail) . '. Set it from its row.';
                $messageClass = 'bad';
            }
        }
    }

    // Samba. Its own file, its own publisher, its own hash: nothing here shares
    // a staging path with hostings.conf, so a save of one cannot pick up the
    // other's candidate.
    //
    // Publishing and reloading are one act, unlike hostings.conf. smb.conf IS
    // the running config, so there is nothing to render and nothing to drift.
    // The folder's group permissions, set before the share is written so a
    // share that is saved is a share that can be read. Its own action rather
    // than part of savesmb: changing a mode and changing a config are two
    // different things to undo.
    // The share write window opens every share to the whole LAN, so full role
    // only. The minutes are checked here and again by the script and sudo.
    if (in_array($action, ['sharewindow', 'sharewindowclose'], true)) {
        $mins = (string) ($_POST['minutes'] ?? '');
        if ($myRole !== 'full') {
            $rc = 2;
            $lines = ['Only a full administrator can open the shares.'];
        } elseif ($action === 'sharewindowclose') {
            exec('sudo ' . SHAREWIN . ' close 2>&1', $lines, $rc);
        } elseif (!array_key_exists($mins, SHAREWIN_MINUTES)) {
            $rc = 2;
            $lines = ['Pick a time from the list.'];
        } else {
            exec('sudo ' . SHAREWIN . ' open ' . $mins . ' 2>&1', $lines, $rc);
        }
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0 ? 'Done.' : 'The share window refused. Its answer is below.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    if ($action === 'setaccess') {
        $path = (string) ($_POST['path'] ?? '');
        $rwx  = (string) ($_POST['rwx'] ?? '');
        exec('sudo ' . SHAREACL . ' --set ' . escapeshellarg($path)
             . ' ' . escapeshellarg(SMB_SHARE_GROUP)
             . ' ' . escapeshellarg($rwx)
             // A fixed word, never anything from the request: the only choice
             // the browser gets is whether to send it at all.
             . (($_POST['deep'] ?? '') === '1' ? ' --recursive' : '')
             . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? 'Folder access set. The share can read what its permissions now allow.'
            : 'Could not set the folder access. Nothing was changed.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    if ($action === 'savesmb') {
        $candidate = $_POST['smbconf'] ?? '';

        if (trim($candidate) === '') {
            $message = 'The Samba config was empty, so nothing was saved.';
            $messageClass = 'bad';
        } else {
            $candidate = str_replace("\r\n", "\n", $candidate);
            $postedBase = preg_replace('/[^0-9a-f]/i', '', (string) ($_POST['smbbase'] ?? ''));
            $wroteBase = @file_put_contents(SMBBASEHASH, $postedBase . "\n" . savedBy($me) . "\n");

            if ($wroteBase === false) {
                $message = 'Could not write ' . SMBBASEHASH . ', so nothing was saved. '
                         . 'Without it the publisher cannot tell whether smb.conf moved '
                         . 'while this page was open. Run add_hosting_manager.sh on the machine.';
                $messageClass = 'bad';
            } elseif (file_put_contents(SMBSTAGING, $candidate) === false) {
                $message = 'Could not write the candidate file. Check permissions on ' . SMBSTAGING;
                $messageClass = 'bad';
            } else {
                exec('sudo ' . PUBSMB . ' 2>&1', $lines, $rc);
                $output = strip_ansi(implode("\n", $lines));
                $message = $rc === 0
                    ? 'Saved and live. Samba reloaded, and open connections were not dropped.'
                    : 'Not saved. The shares on this machine are unchanged.';
                $messageClass = $rc === 0 ? 'good' : 'bad';
            }
        }
    }

    // MAKE SAMBA SERVE WHAT IS PUBLISHED. A save that pushed and then could not
    // move the live tree used to leave the machine one commit behind with no way
    // to finish from here, which is what happened all of 2026-09-09.
    if ($action === 'reloadsmb') {
        exec('sudo ' . RELOADSMB . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("
", $lines));
        $message = $rc === 0
            ? 'Samba now serves the published config. Open connections were not dropped.'
            : 'Samba was not reloaded. It still serves the config it had.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    if ($action === 'apply') {
        exec('sudo ' . APPLY . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? 'Apply started. ' . WATCH_APPLY
            : 'Could not start the apply job. Nothing changed.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // Two spellings, two sudoers entries, and the reporting one is the default.
    // A repository cannot be un-created, and a public one cannot be unseen, so
    // the page never runs --create as a side effect of anything else.
    // Rerun ONE step of the last create, for the row it was for.
    //
    // Neither value comes from the browser as free text. The step is checked
    // against a fixed list of five, and the row is read from last-create.json
    // rather than posted, so the page cannot be talked into running a step for
    // a row somebody else names. escapeshellarg is then the second guard, not
    // the only one.
    if ($action === 'rerunstep') {
        $step = (string) ($_POST['rerunstep'] ?? '');
        $allowed = ['jenkins-folder', 'write-back', 'seed', 'deploy-jobs', 'first-deploy'];
        if (!in_array($step, $allowed, true)) {
            $message = 'That is not a step this page can rerun. Nothing was done.';
            $messageClass = 'bad';
        } elseif ($createRow === '') {
            $message = 'There is no record of a create to rerun a step from. Nothing was done.';
            $messageClass = 'bad';
        } else {
            exec('sudo ' . PROVISION . ' --step ' . escapeshellarg($step)
                 . ' ' . escapeshellarg($createRow) . ' 2>&1', $rsLines, $rsRc);
            $output = strip_ansi(implode("\n", $rsLines));
            $message = $rsRc === 0
                ? 'That step ran again and finished. What it did is below.'
                : 'That step ran again and failed. What it did is below.';
            $messageClass = $rsRc === 0 ? 'good' : 'bad';
        }
    }

    if ($action === 'provision' || $action === 'provision_create') {
        $cmd = PROVISION . ($action === 'provision_create' ? ' --create' : '');
        exec('sudo ' . $cmd . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        if ($action === 'provision') {
            $message = $rc === 0
                ? 'Checked. Nothing was created.'
                : 'The provisioner refused to run. Nothing was created.';
        } else {
            $message = $rc === 0
                ? 'Done. Read the output: it says what was created and what was left alone.'
                : 'The provisioner failed. Read the output before running it again.';
        }
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // The upgrade gate. The voter is the signed-in name, never a form field.
    if (in_array($action, ['upgradevote', 'upgradepause', 'upgraderesume', 'upgradepublish'], true)) {
        $pkg  = (string) ($_POST['pkg'] ?? '');
        $vote = (string) ($_POST['vote'] ?? '');
        if (!preg_match('/^[a-z0-9_-]+$/', $pkg)
            || ($action === 'upgradevote' && !in_array($vote, ['urgent', 'up', 'neutral', 'down'], true))) {
            $rc = 2;
            $lines = ['That is not a package and a vote.'];
        } elseif ($action === 'upgradevote') {
            exec('sudo ' . UPGATE . ' vote ' . escapeshellarg($pkg) . ' ' . escapeshellarg($me)
                 . ' ' . escapeshellarg($vote) . ' 2>&1', $lines, $rc);
        } else {
            exec('sudo ' . UPGATE . ' ' . substr($action, 7) . ' ' . escapeshellarg($pkg) . ' 2>&1', $lines, $rc);
        }
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0 ? 'Done.' : 'The upgrade gate refused. Its answer is below.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    if ($action === 'promote') {
        // Every refusal lives in the script, not here: it runs as root and is
        // the thing that must not be talked past.
        $host = trim($_POST['host'] ?? '');
        exec('sudo ' . PROMOTE . ' ' . escapeshellarg($host) . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? $host . ' now holds a real certificate.'
            : 'Not promoted. ' . $host . ' still holds its test certificate.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // A test certificate for a row that has none. The action name is fixed here
    // rather than taken from the form: this page has one certificate button, so
    // there is nothing for a caller to choose. The row name is checked against
    // the published config by the script, which runs as root.
    //
    // Per row, not per environment: the staging endpoint allows tens of
    // thousands a week, so narrowing it would buy nothing and cost a parameter.
    if ($action === 'testcert') {
        $row = trim($_POST['host'] ?? '');
        exec('sudo ' . SITEJOB . ' ' . escapeshellarg($row) . ' 3-request-certificate 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? 'Requesting test certificates for ' . $row . '. Watch it in Jenkins.'
            : 'No job was started, so ' . $row . ' still has no certificate.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // The two addresses an app sends its mail with. Written to a root-owned
    // file the page cannot open, through the one command that may write it.
    //
    // Nothing else about the mail setup is offered, and that is deliberate:
    // the app reaches this machine's own postfix over loopback, which relays
    // without a credential, so there is no password to ask for and none to
    // leave in a browser.
    // Start, stop or restart one app row's unit. The verb is checked here as
    // well as in the script, because a value that reaches sudo is a value
    // worth refusing twice.
    if ($action === 'service') {
        $row  = trim($_POST['row'] ?? '');
        $env  = trim($_POST['env'] ?? '');
        $verb = trim($_POST['verb'] ?? '');
        if (!in_array($verb, ['start', 'stop', 'restart'], true)) {
            $message = 'Unknown action, so nothing was done.';
            $messageClass = 'bad';
        } else {
            exec('sudo ' . SVCCTL . ' ' . escapeshellarg($row) . ' '
                . escapeshellarg($env) . ' ' . escapeshellarg($verb) . ' 2>&1', $lines, $rc);
            $output = strip_ansi(implode("\n", $lines));
            $message = $rc === 0
                ? ucfirst($verb) . 'ed ' . $row . ' in ' . $env . '.'
                : 'The ' . $verb . ' failed. ' . $row . ' in ' . $env . ' is as it was.';
            $messageClass = $rc === 0 ? 'good' : 'bad';
        }
    }

    if ($action === 'savemail') {
        $row  = trim($_POST['row'] ?? '');
        $from = trim($_POST['mail_from'] ?? '');
        $to   = trim($_POST['mail_to'] ?? '');
        exec('sudo ' . MAILSET . ' --write ' . escapeshellarg($row) . ' '
            . escapeshellarg($from) . ' ' . escapeshellarg($to) . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? 'Mail settings saved for ' . $row . '. Deploy it to apply them.'
            : 'Not saved. ' . $row . ' still has whatever it had.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // The mailbox's default password. proc_open rather than exec, because the
    // password goes down stdin: an argument would be visible in ps to every
    // account on this machine for as long as the process lives.
    //
    // What is set here is a DEFAULT. The owner changes it themselves in
    // Roundcube afterwards, which writes the same file through the same scheme.
    if ($action === 'setmailpw') {
        $local  = trim($_POST['mail_local'] ?? '');
        $domain = trim($_POST['mail_domain'] ?? '');
        $pw     = (string) ($_POST['mail_pw'] ?? '');
        $pipes  = [];
        $proc = proc_open(
            'sudo ' . MAILPW . ' --set ' . escapeshellarg($local)
            . ' ' . escapeshellarg($domain) . ' 2>&1',
            [0 => ['pipe', 'r'], 1 => ['pipe', 'w']], $pipes);
        if (!is_resource($proc)) {
            $message = 'Could not run the password command.';
            $messageClass = 'bad';
        } else {
            fwrite($pipes[0], $pw . "\n");
            fclose($pipes[0]);
            $raw = stream_get_contents($pipes[1]);
            fclose($pipes[1]);
            $pwRc = proc_close($proc);
            unset($pw);
            $out = strip_ansi(trim((string) $raw));
            // The script answers JSON on its last line whatever happened, and
            // reports a refusal as {"error":...} rather than as a failing exit
            // code, so the code alone is not the answer.
            $lastLine = trim((string) strrchr("\n" . $out, "\n"));
            $parsed = json_decode($lastLine, true);
            $failed = $pwRc !== 0 || !is_array($parsed) || !empty($parsed['error']);
            $output = $out;
            $message = $failed
                ? 'The password was not set. ' . (is_array($parsed) && !empty($parsed['error'])
                    ? $parsed['error'] : 'The output below says why.')
                : 'Password set for ' . $local . '@' . $domain . '. Tell the owner to change it in webmail.';
            $messageClass = $failed ? 'bad' : 'good';
        }
    }

    if ($action === 'update') {
        // Through sudo, not curl from here: the Jenkins token is 0600 root and
        // this process is www-data. Root reads it, so the page still holds
        // nothing.
        exec('sudo ' . UPDATE . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0
            ? 'Update job started.'
            : 'Could not start the update job.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    if ($action === 'reboot') {
        // The script refuses unless an update asked for it and Jenkins is idle.
        exec('sudo ' . REBOOT . ' 2>&1', $lines, $rc);
        $output = strip_ansi(implode("\n", $lines));
        $message = $rc === 0 ? 'Rebooting.' : 'The machine was not rebooted.';
        $messageClass = $rc === 0 ? 'good' : 'bad';
    }

    // POST/REDIRECT/GET, so a refresh cannot do it again.
    //
    // This page rendered straight from the POST, which meant F5 resubmitted it:
    // another publish, another apply, and since the apply prunes, a refresh
    // could delete generated config nobody asked it to.
    //
    // Only on success, and only for the actions that change something. A
    // failure keeps its output on screen, because that output is the whole
    // reason to look at the page at that moment, and a failed action has
    // nothing to repeat. 'recheck' never redirects: it writes nothing, and the
    // dialog it opens is built from this very response.
    //
    // The message travels as a code, never as text. A message put in the query
    // string is a message an attacker can choose.
    $changed = ['save', 'save_apply', 'save_fast', 'savesmb', 'reloadsmb', 'setaccess', 'apply', 'fixdrift', 'setmailpw', 'provision', 'provision_create', 'promote', 'testcert', 'update', 'reboot', 'rerunstep', 'upgradevote', 'upgradepause', 'upgraderesume', 'upgradepublish', 'sharewindow', 'sharewindowclose'];
    // Written before the redirect, because the redirect is what throws the
    // message away. A failed save used to skip the redirect entirely, so F5
    // re-POSTed the form and replayed ops that had already run.
    if (($publishNoChange ?? false) && ($messageClass ?? '') === 'good') {
        $rest = ucfirst((string) preg_replace('/^Saved(,| and) (pushed|live)[.,]?\s*(and\s+)?/', '', (string) $message));
        $message = 'Nothing new was saved: the config on the branch already matched what this page sent. '
                 . 'If you just changed something, reload and check it is there. ' . $rest;
        foreach ($saveSteps ?? [] as &$st) {
            if ($st['name'] === 'publish the config') { $st['note'] = 'no change, nothing committed'; }
        }
        unset($st);
    }

    if (in_array($action, $changed, true)) {
        @file_put_contents(LASTSAVE, json_encode([
            'when'    => date('c'),
            'action'  => $action,
            'class'   => $messageClass ?? '',
            'message' => $message ?? '',
            'output'  => $output ?? '',
            // Whether the config was left alone, which decides the dialog's
            // wording below: nothing published means nothing changed, anything
            // else may have changed some of it. Carried through the redirect,
            // because the redirect is what throws the POST's variables away and
            // the dialog is rendered on the GET.
            //
            // $mailBlocked counts as much as a refusal. The mail ops run first
            // now, so a failed one skips the publish entirely: on 2026-09-03 a
            // real failure printed "The config was saved" as its heading and
            // "Nothing was saved" as its body, in the same dialog.
            'refused' => ($publishRefused || !empty($mailBlocked)),
            // One entry per job the press ran. A save does the mailbox changes,
            // the publish, the repository changes and the apply, and reported
            // one sentence for all four, so a failure anywhere read as "the
            // save failed" and which had run was left to be worked out from a
            // mixed machine.
            'steps'   => $saveSteps ?? [],
        ], JSON_PRETTY_PRINT | JSON_UNESCAPED_SLASHES));
    }

    if (in_array($action, $changed, true) && ($messageClass ?? '') !== 'good') {
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . '?done=failed');
        exit;
    }

    if (in_array($action, $changed, true) && ($messageClass ?? '') === 'good') {
        $codes = [
            'save'             => 'saved',
            'save_apply'       => 'applied',
            'save_fast'        => ($escalatedToJob ?? false) ? 'escalated' : 'fastapplied',
            'savesmb'          => 'smbsaved',
            'reloadsmb'        => 'smbreloaded',
            'setaccess'        => 'accessset',
            'apply'            => 'applied',
            'fixdrift'         => ($driftStartedJob ?? false) ? 'driftapplied' : 'driftfixed',
            'setmailpw'        => 'mailpwset',
            'provision'        => 'provchecked',
            'provision_create' => 'provdone',
            'promote'          => 'promoted',
            'testcert'         => 'testcerts',
            'update'           => 'updating',
            'reboot'           => 'rebooting',
            'rerunstep'        => 'steprerun',
            'upgradevote'      => 'voted',
            'upgradepause'     => 'upgpaused',
            'upgraderesume'    => 'upgresumed',
            'upgradepublish'   => 'upgpublished',
            'sharewindow'      => 'shareopen',
            'sharewindowclose' => 'shareclosed',
        ];
        // Only ever a number, and only for the apply: the dialog uses it to
        // tell a job that has not started from one that is over.
        $q = '?done=' . $codes[$action];
        if (isset($applyFrom) && in_array($codes[$action], ['applied', 'driftapplied'], true)) {
            $q .= '&from=' . (int) $applyFrom;
        }
        // A save that created a repository ran the create inline, so its step
        // report is shown on the save's own redirect, not only on provdone.
        if (!empty($pendingRepos) && ($provRc ?? 1) === 0) {
            $q .= '&created=1';
        }
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . $q);
        exit;
    }

    // The check writes nothing, so it was never in the list above. It still has
    // to redirect: rendering its answer straight from the POST meant a refresh
    // re-submitted it, the check ran again, and the dialog came back up on a URL
    // that looked clean. The candidate is already on disk and the report is in
    // last-check.txt, so the GET rebuilds the same page without re-running it.
    if ($action === 'recheck') {
        $q = '?done=' . (($messageClass ?? '') === 'good' ? 'checked' : 'checkfailed');
        if ($autoConfirm) { $q .= '&open=1'; }
        header('Location: ' . strtok($_SERVER['REQUEST_URI'], '?') . $q);
        exit;
    }
}

// The other half of the redirect above. Fixed texts, chosen by a code that has
// to match one of these exactly, so nothing from the URL is ever displayed.
if ($_SERVER['REQUEST_METHOD'] === 'GET' && isset($_GET['done'])) {
    $doneText = [
        'saved'       => 'Saved and pushed. Nothing on the machine has changed.',
        'applied'     => 'Saved, pushed, and the apply job has started. Watch it in Jenkins.',
        'fastapplied' => 'Saved and live. Vhosts and preview ports were written; units, certificates and repositories were not touched.',
        'driftfixed'  => 'Drift fixed. Vhosts and preview ports were rewritten; nothing was saved or pushed.',
        'escalated'   => 'Saved. That change needed a prune, a unit or a certificate, so the full apply job was started for you. The dialog follows it.',
        'driftapplied' => 'This drift needed a prune, a unit or a certificate, so the full apply job has started. The dialog follows it.',
        'mailpwset'   => 'Password set. Tell the owner to change it in webmail: this one is a default.',
        'smbsaved'    => 'Saved and live. Samba reloaded, and open connections were not dropped.',
        'smbreloaded' => 'Samba now serves the published config. Open connections were not dropped.',
        'accessset'   => 'Folder access set. The share can read what its permissions now allow.',
        'provchecked' => 'Checked. Nothing was created.',
        // NOT "read it in Jenkins": provision_repo.sh is run straight from this
        // page, so nothing about it is in Jenkins to read. The steps are below.
        'provdone'    => 'Done. Every step of the create is listed below.',
        'promoted'    => 'The certificate was promoted to a real one.',
        'testcerts'   => 'The test certificate job has started. Watch it in Jenkins.',
        'updating'    => 'Update job started.',
        'rebooting'   => 'Rebooting. Every site is down for about a minute; this page comes back on its own.',
        'steprerun'   => 'That step ran again. The list below says how it went.',
        'voted'        => 'Your vote is in. You can change it until the version goes live.',
        'upgpaused'    => 'Paused: this version stays on test until you resume it.',
        'upgresumed'   => 'Resumed: the votes decide again.',
        'upgpublished' => 'Published: live now runs the version test ran.',
        'shareopen'    => 'The shares are writable without a password until the timer runs out.',
        'shareclosed'  => 'The shares are back to their own settings.',
        'checked'     => 'Checked. Nothing was written and nothing was pushed.',
        'checkfailed' => 'The check failed. The report below says why.',
    ];
    // The one entry whose words are not fixed here: the failure text is the
    // machine's own and is read back from the file the POST wrote.
    if ($_GET['done'] === 'failed') {
        $last = @json_decode((string) @file_get_contents(LASTSAVE), true);
        $message = is_array($last) && ($last['message'] ?? '') !== ''
            ? $last['message']
            : 'The last change failed, and nothing was written saying why.';
        $messageClass = 'bad';
        if (is_array($last) && ($last['output'] ?? '') !== '') { $output = $last['output']; }
        // EVERY failed change stops the page, not only a refused publish.
        //
        // The owner's decision 2026-09-03: a failure gets a dialog carrying the
        // exact issue. A line among the others is not read, which item 24
        // already proved once with the stale-edit guard.
        //
        // This also repairs that guard. $publishRefused was set during the
        // POST and the dialog rendered from it, then the failure redirect was
        // added above and exits first, so the POST's variables are gone by the
        // time anything renders: the dialog could no longer appear AT ALL. It
        // is restored from the file now, like the message beside it.
        $publishRefused = true;
        // No record means we do not KNOW whether anything changed, and the
        // louder wording claims that some of it is live. Default to the
        // truthful half instead: with no record, say nothing changed, because
        // that is what a refusal looks like and it is the common case.
        $failureChangedNothing = !is_array($last) || !empty($last['refused']);
        $failedAction = is_array($last) ? (string) ($last['action'] ?? '') : '';
        $failedWhen   = is_array($last) ? (string) ($last['when'] ?? '') : '';
        // What each of the press's four jobs did. Rendered in the dialog with
        // the same function the create uses, because it is the same question.
        $failedSteps  = (is_array($last) && is_array($last['steps'] ?? null))
                      ? $last['steps'] : [];
    }
    if (isset($doneText[$_GET['done']])) {
        $message = $doneText[$_GET['done']];
        $messageClass = $_GET['done'] === 'checkfailed' ? 'bad' : 'good';
    }
    // The check was pressed as the first half of Make it live, so the dialog
    // still opens by itself. It survives the redirect as a flag, not as a
    // re-run of the check.
    if (isset($_GET['open']) && in_array($_GET['done'], ['checked', 'checkfailed'], true)) {
        $autoConfirm = true;
    }
    // This load followed a press that handed work to Jenkins, so the page
    // watches for it to finish and reloads itself. Without it the answer on
    // screen is the one from before the job ran, and looks like a result.
    $startedJob = in_array($_GET['done'], ['applied', 'driftapplied', 'escalated', 'testcerts', 'updating'], true);
    $rebooting = $_GET['done'] === 'rebooting';
    // Apply alone reopens its dialog: the other two are started from buttons
    // that have nothing to do with it, and the banner is their answer.
    $startedApply = in_array($_GET['done'], ['applied', 'driftapplied', 'escalated'], true);
    if (isset($_GET['from']) && ctype_digit((string) $_GET['from'])) {
        $applyFrom = (int) $_GET['from'];
    }
}

$config = is_readable(CONF) ? file_get_contents(CONF) : '';
$confReadable = $config !== '';

// The hash is of the BRANCH file, never of the candidate: it is what the
// publisher compares against to see whether the file moved.
$baseHash = $confReadable
    ? sha1('blob ' . strlen($config) . "\0" . $config)
    : '';

// =============================================================================
// Samba shares
//
// Parsed into blocks, never into a model. Each share keeps its own text, so a
// share nobody edited is written back byte for byte: [www] and
// [running_csharp_projects] differ only in one mode line, and rebuilding them
// from a template would quietly turn 2775 into 0775 and break the group the
// deploys rely on.
// =============================================================================
$smbConf = is_readable(SMBCONF) ? (string) file_get_contents(SMBCONF) : '';
$smbReadable = $smbConf !== '';
$smbBaseHash = $smbReadable
    ? sha1('blob ' . strlen($smbConf) . "\0" . $smbConf)
    : '';

/**
 * Split smb.conf into its sections, keeping every byte.
 *
 * Returns a list of ['name' => string, 'raw' => string, 'path' => ?string,
 * 'reserved' => bool]. Anything before the first [section] is returned under
 * the empty name, so a preamble of comments survives a round trip.
 */
function smb_sections(string $text): array {
    $out = [];
    $name = '';
    $buf = [];

    $flush = static function (string $n, array $lines) {
        $raw = implode("\n", $lines);
        // Off when its header carries the marker. The path is read through the
        // marker too, so a switched-off share still knows which folder it is.
        $off = (bool) preg_match('/^\s*#OFF \[/', $lines[0] ?? '');
        $path = null;
        foreach ($lines as $l) {
            if (preg_match('/^\s*(?:#OFF )?path\s*=\s*(.+?)\s*$/i', $l, $m)) { $path = $m[1]; break; }
        }
        return [
            'name'     => $n,
            'raw'      => $raw,
            'path'     => $path,
            'enabled'  => $off ? 'no' : 'yes',
            'reserved' => $n === '' || in_array(strtolower($n), SMB_RESERVED, true),
        ];
    };

    // A switched-off share is the same section with `#OFF ` in front of every
    // line. Recognised here so it stays a section the page can show and switch
    // back on: without this its header would not match, the whole share would
    // be swallowed into the section above it, and it could never be recovered
    // from the console.
    foreach (explode("\n", str_replace("\r\n", "\n", $text)) as $line) {
        if (preg_match('/^\s*(?:#OFF )?\[([^\]]+)\]\s*$/', $line, $m)) {
            if ($name !== '' || trim(implode('', $buf)) !== '') { $out[] = $flush($name, $buf); }
            $name = $m[1];
            $buf = [$line];
            continue;
        }
        $buf[] = $line;
    }
    if ($name !== '' || trim(implode('', $buf)) !== '') { $out[] = $flush($name, $buf); }

    return $out;
}

$smbSections = $smbReadable ? smb_sections($smbConf) : [];


// A staged candidate is unsaved work, so the page is built from it. Checking is
// a form POST and the answer is a fresh render: rebuilding from the branch file
// silently threw the edit away, the dialog then showed drift for an edit that
// was no longer in the form, and Save posted the unchanged file.
$staged = '';
if (is_readable(STAGING)) {
    $staged = (string) file_get_contents(STAGING);
    if (trim($staged) === '') { $staged = ''; }
}
// A candidate that matches the branch file is not an edit. Apply leaves the
// file behind, so existence alone had the page offering "Make it live" for a
// change that was already live.
if ($staged !== '' && $confReadable
    && rtrim(str_replace("\r\n", "\n", $staged)) === rtrim(str_replace("\r\n", "\n", $config))) {
    $staged = '';
}
if ($staged !== '' && $confReadable) {
    $config = str_replace("\r\n", "\n", $staged);
}

// IS THE STAGED CANDIDATE STALE?
//
// The base hash is the config the candidate was edited against. When the branch
// file has moved since, the page is built from values that are already
// superseded, and nothing said so: item 78 is the record of a candidate holding
// a PRE-fix config, read for as long as it took somebody to notice.
//
// The publisher already REFUSES to publish a stale candidate, and item 24 is
// the record of that guard firing for real, so nothing can be silently
// reverted. What was missing is being told before doing the work.
//
// A missing OR EMPTY base hash is not staleness. Neither can be compared, so
// both say nothing rather than crying wolf. The empty case is real: the base is
// written from a posted field, so a form that posts without one leaves a
// zero-byte file behind.
$stagedStale = false;
$stagedWhen  = '';
// What Save posts as its base. A page built from a draft posts the draft's base,
// so the publisher refuses a stale one instead of comparing fresh to fresh.
$postBase    = $baseHash;
if ($staged !== '' && $baseHash !== '') {
    $knownBase = is_readable(BASEHASH) ? trim(explode("\n", (string) file_get_contents(BASEHASH))[0]) : '';
    $stagedStale = $knownBase !== '' && $knownBase !== $baseHash;
    $postBase = $knownBase;
}
if ($staged !== '' && ($t = @filemtime(STAGING))) {
    $stagedWhen = date('j M H:i', $t);
}

// The drift report, written by whichever privileged command ran the check. The
// page never works it out itself: --check reads /etc, systemd and certbot.
$report = is_readable(REPORT) ? strip_ansi(file_get_contents(REPORT)) : '';
$reportAge = '';
if ($report !== '') {
    $mtime = filemtime(REPORT);
    $mins = (int) round((time() - $mtime) / 60);
    if ($mins < 1)          { $reportAge = 'just now'; }
    elseif ($mins < 60)     { $reportAge = $mins . ' min ago'; }
    elseif ($mins < 60 * 24){ $reportAge = (int) round($mins / 60) . ' hours ago'; }
    else                    { $reportAge = (int) round($mins / 1440) . ' days ago'; }
}

// Split the report's own header from the body it wrote, so the header can be
// shown as a line rather than as the first three lines of a code block.
$reportHead = '';
$reportBody = $report;
if (strpos($report, "\n\n") !== false) {
    [$reportHead, $reportBody] = explode("\n\n", $report, 2);
}

// A report that says the config is not valid is the one thing on this page that
// must not be scrolled past.
$reportFailed = strpos($reportHead, 'FAILED') !== false;

// The drift lines out of the log around them, so the card can show what would
// change instead of everything the checker printed on its way there.
//
// UPDATE arrives as of 2026-08-26. report_drift.sh asks the generators, in
// RENDER_ONLY mode, whether the file they would write differs from the one on
// disk, so a login flip is predicted here instead of discovered by Apply.
$drift = ['ADD' => [], 'UPDATE' => [], 'ORPHAN' => [], 'OK' => []];
$problems = [];
$warnCount = 0;
foreach (explode("\n", $reportBody) as $l) {
    if (preg_match('/^\s*(ADD|UPDATE|ORPHAN|OK)\s+(\S+)\s+(\S.*)$/', $l, $m)) {
        $drift[$m[1]][] = ['what' => $m[2], 'name' => rtrim($m[3])];
    } elseif (strpos($l, '❌') !== false) {
        $problems[] = trim(str_replace('❌', '', $l));
    } elseif (strpos($l, '⚠️') !== false) {
        $warnCount++;
    }
}
// The report names every row and hostname on the machine, and fixing drift is
// a full access admin's. A limited admin gets neither. Item 136.
if ($myRole !== 'full') {
    $reportBody = '';
    $drift = ['ADD' => [], 'UPDATE' => [], 'ORPHAN' => [], 'OK' => []];
    $problems = [];
    $warnCount = 0;
}
$driftCount = count($drift['ADD']) + count($drift['UPDATE']) + count($drift['ORPHAN']);

// Nothing to apply: the report says nothing differs, nothing is staged, and the
// report itself is real and passed. Any one of those missing and the button
// stays live, because a button that hides when it should not is worse than one
// that offers work there is none of.
//
// Only possible since the report learned to compare content. Before that
// "nothing differs" meant "everything exists", and hiding on it would have hidden
// the button for exactly the change the owner was trying to apply.
$nothingToApply = $report !== '' && !$reportFailed && $driftCount === 0 && $staged === '';

// The drift banner. Shown from the report the last privileged check wrote, so
// this page never computes drift itself: --check is 4.5 seconds and would be
// paid on every load.
$driftBanner = $report !== '' && !$reportFailed && $driftCount > 0;

// Whether Fix drift may be offered at all. apply_config_only.sh runs the two
// vhost generators and prunes nothing, so an ADD or an UPDATE of a vhost or a
// preview is inside it and everything else is not. An ORPHAN of any kind needs
// a prune, a unit needs systemd and a certificate needs certbot: all three are
// the Jenkins job's, and offering a button that silently skips them would
// rebuild the trap that "Config only, no Jenkins" was.
//
// The two words are the two generators: add_app_vhosts.sh reports `vhost` and
// add_preview_vhosts.sh reports `preview`.
$driftFastKinds = ['vhost', 'preview'];

// Whether the FAST path is enough. An orphan needs a prune, and a unit or a
// certificate needs systemd or certbot, so any of those means the full job.
$driftFastOnly = count($drift['ORPHAN']) === 0;
if ($driftFastOnly) {
    foreach (array_merge($drift['ADD'], $drift['UPDATE']) as $d) {
        if (!in_array($d['what'], $driftFastKinds, true)) { $driftFastOnly = false; break; }
    }
}

// Whether to OFFER the button at all, which is a different question and has one
// answer: drift, and no staged edit of your own mixed into it. The button then
// picks fast or full itself, the same way the tab's Apply and the drawer's Keep
// this change do. Sending the operator to Make it live for a prune was sending
// routine work to the emergency fallback.
$driftFixable = $driftBanner && $staged === '';

// The live switch, read out of the config so the page never keeps its own copy
// of the answer.
$isLive = in_array(strtolower((string) conf_val($config, 'MACHINE_IS_LIVE')),
                   ['yes', 'y', 'true', '1'], true);

// The thirteen columns, in file order. Named here so the drawer can label them
// and the table can index them without a magic number in sight.
// key, label, hint, input type. The type is what stops a field being a box you
// have to already know the answer to type into.
const FIELDS = [
    ['ServiceType', 'Type', 'What this row is. An application is a program this machine runs, a website is files it serves from disk, forwarded points at something that runs itself, a mailbox is only an email address.', 'kind'],
    ['ApplicationName', 'Name', 'Lowercase, underscores, no spaces. Becomes the unit name and the vhost filename.', 'text'],
    ['Port', 'Port', 'The localhost port for the first environment. Empty for a website: Apache serves it off disk and nothing listens.', 'text'],
    ['Path', 'Path', 'Relative to APP_ROOT for an app, to WEB_ROOT for a website. Relative, so one row serves every environment.', 'text'],
    ['Subdomain', 'Domain', 'What you type here becomes the web address. shop gives shop.example.com, @ gives example.com itself, =other.nl gives that whole domain, and empty publishes nothing at all.', 'text'],
    ['DataSource', 'Data from', 'Another service name, to read and write that service data folder. Empty means its own.', 'datasource'],
    ['ApplicationOptionsOverwrite', 'App settings', 'Written into appsettings.json when the application is deployed. The keys already in use are offered.', 'options'],
    ['AuthProtected', 'Login', 'Whether a password stands in front of it. Can differ per environment.', 'auth'],
    ['Repository', 'Repository clone URL', 'Where the code comes from. Empty for anything deployed by hand. Type new to have one created, with its branches and its Jenkins job.', 'repo'],
    ['Branch', 'Source branch', 'The branch the environment branches are created from. Where a repository has none, every environment deploys this one.', 'branch'],
    ['Envs', 'Environments', 'Which environments this row exists in. Empty means the standard set.', 'envs'],
    ['AuthUsers', 'Who may enter', 'Accounts in the password file, plus every name already used on another row. Empty means the admin alone.', 'users'],
    ['RepoMode', 'Repository mode', 'Who reads this repository. It decides the default branch and what main means. Nothing acts on it yet.', 'repomode'],
    ['Runtime', 'Application type', 'What this application is written in. It decides what the service runs. Only applications have one.', 'runtime'],
    // Never in SHAPE, so no drawer renders it: disabling is done from the
    // table's edit mode, over as many rows as you like at once. A row written
    // before this field existed has 14 fields and reads as enabled, which is
    // what every row on every machine was until 2026-08-31.
    ['Enabled', 'Enabled', 'Whether this row does its job. A disabled row keeps everything it owns: its folder, its certificate, its repository and its files. What stops depends on what the row is.', 'enabled'],
    // Sixteenth, and never in SHAPE either: a customer does not choose who owns
    // their row. A full access admin sets it from the table's edit mode, and it
    // is what decides whose rows a limited admin sees at all. Item 105.
    ['Owner', 'Owner', 'Which account this row belongs to. A dash means nobody, and a row with no owner is visible only to a full access admin.', 'owner'],
];

// What an application can be. The value is the word hostings.conf stores, and
// the third column is what the unit executes, which is the whole difference
// between them.
//
// Angular and Vue are deliberately absent: they build to static files, so they
// are a website row pointed at the build output, with no unit and no port.
// The number is the version a NEW project is created against, and nothing else:
// the unit runs `dotnet <app>.dll` whatever it says, and the version the Runs
// on column shows is read out of the build itself. It exists because a machine
// with two SDKs seeds against the NEWEST one, so a row meant to stay on LTS 8
// came back as 10 on 2026-09-07.
const RUNTIMES = [
    ['dotnet8',  '.NET 8 (LTS)',  'A published .dll, run by dotnet. A new project is created against .NET 8, the current LTS.'],
    ['dotnet10', '.NET 10 (LTS)', 'A published .dll, run by dotnet. A new project is created against .NET 10.'],
    ['dotnet',   '.NET, newest',  'A published .dll. A new project takes whichever SDK is newest on this machine, which is 10 today.'],
    ['node',     'Node.js',       'A .js entry point, run by node. Untried here.'],
    ['uno',      'Uno with Server', 'An ASP.NET server hosting an Uno WebAssembly app and an API. Built in a container, run by dotnet. Path is <name>/<name>.Server.dll.'],
    ['docker',   'Docker (.NET sample)',   'Built from the Dockerfile in the repository and run as a container on 127.0.0.1. The app must listen on port 8080. Path is the Dockerfile, for example Dockerfile. A new repository is seeded with an ASP.NET sample.'],
    ['docker_node',   'Docker (Node sample)',   'The same container row as Docker. Only what a NEW repository is seeded with differs: a Node server on 8080 with no dependencies.'],
    ['docker_python', 'Docker (Python sample)', 'The same container row as Docker. Only what a NEW repository is seeded with differs: a Python server on 8080, standard library only.'],
];

// One entry per puzzle piece in upstream/, so a new package needs no edit here.
function upstream_runtimes(): array {
    $out = [];
    foreach (glob('/usr/local/lib/linuxbasics/hostings/upstream/*/recipe.conf') ?: [] as $recipe) {
        $pkg = basename(dirname($recipe));
        $out[] = ["upstream:$pkg", "Upstream: $pkg", "Somebody else's application, run as a container from its own stable releases. Path is unused, put a dash. See upstream/README.md."];
    }
    return $out;
}

// What a NEW website repository is seeded with. The same field 13 as the
// application runtime above, which is why the comment there says Vue and
// Angular are absent: it was written before 2026-09-05, when field 13 was
// given this second meaning on a website row.
//
// Only what seed_site_index.sh can actually WRITE is selectable. The rest are
// listed and disabled with the reason, the shape item 67 settled for startup
// projects and item 79 for platforms: a reader whose framework is simply
// missing from the list cannot tell whether it is unsupported or forgotten.
//
// build_npm_static_site.sh builds far more than this. Being buildable is not
// being seedable, and this dropdown answers the second question: what does
// pressing Keep this change put in the empty repository.
//
// [id, label, seeder?, why not]
const SITE_PLATFORMS = [
    ['-',       'HTML',               true,  'One index.html and a picture, so a working pipeline looks different from a broken one. What every row made before 2026-09-05 has.'],
    ['vue',     'Vue',                true,  ''],
    ['react',   'React',              true,  ''],
    ['svelte',  'Svelte',             true,  ''],
    ['angular', 'Angular',            true,  ''],
    ['php',     'PHP, no framework',  true,  ''],
    ['uno',     'Uno WebAssembly',    true,  ''],
    ['astro',         'Astro',                  false, 'This machine can build it, but seed_site_index.sh has no write_site_astro, so the seed step would fail.'],
    ['solid',         'SolidJS',                false, 'This machine can build it, but seed_site_index.sh has no write_site_solid, so the seed step would fail.'],
    ['vite',          'Vite, no framework',     false, 'This machine can build it, but seed_site_index.sh has no write_site_vite, so the seed step would fail.'],
    ['nextjs-static', 'Next.js, static export', false, 'This machine can build it, but nothing seeds one. Server mode is a different thing again and needs an application row.'],
    ['nuxt-static',   'Nuxt, static generate',  false, 'This machine can build it, but nothing seeds one. Server mode is a different thing again and needs an application row.'],
];

// The three modes, spelled out where they are chosen rather than in a document
// nobody has open at the time.
const REPO_MODES = [
    ['private',    'Only you. The default branch is dev.'],
    ['portfolio',  'Meant to be read. The default branch is main, and main mirrors live, so a visitor sees the code behind the running site.'],
    ['opensource', 'Meant to be contributed to. The default branch is main, and main is the trunk, ahead of live: an open project has no single production to mirror, so stability is a tag rather than a branch.'],
];

// Rows, with the line they came from, so an edit in the drawer maps back to one
// line of the file and leaves every comment around it untouched.
$lines = explode("\n", $config);
$rows = [];
foreach ($lines as $n => $line) {
    if (preg_match('/^\s*#/', $line) || strpos($line, '|') === false || trim($line) === '') {
        continue;
    }
    $fields = array_map('trim', explode('|', $line));
    // Rows written before a field existed are shorter, and each missing one has
    // its own default rather than a shared filler. Appending one value for both
    // is how an Owner of 'yes' would have landed on every row on this machine:
    // 15 fields is one short of 16 now, and it used to be the whole line.
    if (count($fields) === count(FIELDS) - 2) {
        $fields[] = 'yes';                 // Enabled, absent before 2026-08-31
    }
    if (count($fields) === count(FIELDS) - 1) {
        $fields[] = '-';                   // Owner, absent before 2026-09-10
    }
    if (count($fields) !== count(FIELDS)) {
        continue;
    }
    $rows[] = ['line' => $n, 'f' => $fields];
}


// A LIMITED ADMIN IS NOT SENT THE ROWS THEY MAY NOT SEE. Item 105.
//
// maySeeRow() in the page decides what a TABLE lists. This decides what the
// browser is given at all, and it is the one that matters: without it every
// customer's page carried every row, every repository URL and every AuthUsers
// name, hidden by a filter anyone can turn off from a console.
//
// The row LINES are blanked rather than removed, so nothing that counts lines
// shifts. Their save posts this filtered file, and mergeLimitedSave() puts it
// back into the whole one. Item 136.
$own = ownership($config);
if ($myRole !== 'full') {
    foreach ($rows as $i => $r) {
        if ($me !== '' && rowOwner($r['f'], $own) === $me) continue;
        if ($r['line'] !== null) $lines[$r['line']] = '';
        unset($rows[$i]);
    }
    $rows = array_values($rows);

    // Every other line goes too. Settings and comments name other customers'
    // rows (PREVIEW_ROWS does, by design), and mergeLimitedSave() takes them
    // from the live file anyway. Item 136.
    $keep = array_flip(array_column($rows, 'line'));
    foreach ($lines as $li => $lv) {
        if (!isset($keep[$li])) $lines[$li] = '';
    }
}
// Column widths, so a rewritten line lines up with the ones around it. A diff
// full of realignment hides the change that was actually made.

// This person's own mailbox allowance, and what they have used. Item 106.
//
// The page needs both and cannot ask for them: ?ask=users is refused for a
// limited admin, correctly, because it lists everybody. So they are computed
// here for the signed-in account alone.
//
// The three DEFAULTS never count. The owner, 2026-09-10: the allowance is for the
// extra addresses somebody types, not for info@, contact@ and admin@, and
// contact@ is mandatory anyway.
$myBoxes = null;      // null = no limit, which is what a full access admin has
$myBoxesUsed = 0;
if ($myRole !== 'full' && $me !== '') {
    $myBoxes = mailboxAllowance($me);
    $myBoxesUsed = mailboxesUsed($config, $me, $own);
}
$widths = array_fill(0, count(FIELDS), 0);
foreach ($rows as $r) {
    foreach ($r['f'] as $i => $v) {
        $widths[$i] = max($widths[$i], strlen($v));
    }
}

// The app-settings keys already in use, so the field offers them instead of
// asking anyone to type ApplicationOptions__CurrentMainProjectGoal correctly.
// Detected from the file rather than listed here: a new key appears by being
// used once.
$optionKeys = [];
foreach ($rows as $r) {
    foreach (explode(';', $r['f'][6]) as $pair) {
        $pair = trim($pair);
        if ($pair !== '' && $pair !== '-' && strpos($pair, '=') !== false) {
            $optionKeys[] = trim(strstr($pair, '=', true));
        }
    }
}
$optionKeys = array_values(array_unique($optionKeys));



$baseDomain = conf_val($config, 'BASE_DOMAIN') ?: 'example.com';

// `PANEL = id | port | name`, one per line and read in file order. The id is
// what a script looks up and never changes; the name is this page's to rename.
// Shown because nothing else on the page would, so a port collision with a row
// would go unnoticed.
//
// The ids two scripts hold by name. Renaming one of these would leave that
// script configuring nothing, silently, so the drawer will not offer it.
const PANEL_HELD = [
    'console' => 'add_hosting_manager.sh',
    'jenkins' => 'add_jenkins.sh',
];

$services = [];
foreach ($lines as $n => $line) {
    // No `$` anchor: a file with CRLF endings would leave the carriage return
    // outside the capture and match nothing at all. trim() takes it off instead.
    if (!preg_match('/^[ \t]*PANEL[ \t]*=(.*)/', $line, $m)) { continue; }
    $parts = array_map('trim', explode('|', $m[1]));
    if (count($parts) < 3 || $parts[0] === '') { continue; }
    [$id, $port, $name] = $parts;

    // The last three are optional, and absent means the page is served by its
    // own installer. That is what every page was before add_panel_vhosts.sh.
    $dash   = fn($v) => ($v === '' || $v === '-') ? '' : $v;
    $serves = strtolower($dash($parts[3] ?? '')) ?: 'itself';
    $target = $dash($parts[4] ?? '');
    $login  = strtolower($dash($parts[5] ?? '')) ?: 'yes';
    $users  = $dash($parts[6] ?? '');

    // '-' and empty both mean the page is switched off, per hostings.conf.
    $services[] = [
        'id'     => $id,
        'label'  => $name !== '' ? $name : $id,
        'held'   => PANEL_HELD[$id] ?? null,
        'line'   => $n,
        'value'  => ($port === '' || $port === '-') ? null : $port,
        'serves' => $serves,
        'target' => $target,
        'login'  => $login === 'no' ? 'no' : 'yes',
        // Who may enter besides the admin, who is always admitted and is
        // therefore never stored here.
        'users'  => $users,
    ];
}

// Machine pages that are switched off, by id.
//
// A settings line rather than an eighth field on the PANEL line, for two
// reasons. The id is the one thing about a page that never changes, which is
// what made PREVIEW_ROWS' name list go stale and cannot happen here. And the
// last positional field on a PANEL line is exactly what broke before: `login`
// picked up a carriage return and a page went onto the LAN with no password.
//
// It is separate from a page with no port, which is also off. That one forgets
// which port it had; this one does not, so it can be switched back on.
$panelsOff = [];
$offRaw = conf_val($config, 'PANELS_OFF');
if ($offRaw !== null && $offRaw !== '' && $offRaw !== '-') {
    $panelsOff = array_values(array_filter(array_map('trim', explode(',', $offRaw))));
}
foreach ($services as &$svc) {
    $svc['enabled'] = in_array($svc['id'], $panelsOff, true) ? 'no' : 'yes';
}
unset($svc);

// The environments this machine knows about, from the config rather than from a
// list here: a new environment must not need the page edited to appear.
$envList = ['live', 'test'];
$envsRaw = conf_val($config, 'ENVS');
if ($envsRaw !== null && $envsRaw !== '') {
    $envList = array_values(array_filter(array_map('trim', explode(',', $envsRaw))));
}

// The prefix each environment puts in front of a hostname, so the table can
// show the address a browser would actually be typed, per environment, rather
// than the shorthand the file stores.
$hostPrefix = [];
$portOffset = [];
$envBranch  = [];
$unitSuffix = [];
foreach ($envList as $e) {
    $hostPrefix[$e] = (string) conf_val($config, strtoupper($e) . '_HOST_PREFIX');
    $offset = conf_val($config, strtoupper($e) . '_PORT_OFFSET');
    $portOffset[$e] = (int) $offset;
    $envBranch[$e] = (string) conf_val($config, strtoupper($e) . '_BRANCH');
    $unitSuffix[$e] = (string) conf_val($config, strtoupper($e) . '_UNIT_SUFFIX');
}

// The resource limits add_app_services.sh turns into slices, as the file has
// them; an absent key means the script's default, which the page shows.
$envLimits = [];
foreach (array_merge(['NONLIVE'], array_map('strtoupper', $envList)) as $up) {
    foreach (['CPU', 'MEMORY', 'APP_MEMORY'] as $k) {
        $v = conf_val($config, $up . '_' . $k);
        if ($v !== null && $v !== '') $envLimits[$up . '_' . $k] = (string) $v;
    }
}
// One app's own memory ceiling, over its environment's Per app: "name:1G, ...".
$appMemSpec = [];
foreach (array_filter(array_map('trim', explode(',', (string) conf_val($config, 'APP_MEMORY_ROWS')))) as $entry) {
    [$an, $av] = array_pad(array_map('trim', explode(':', $entry, 2)), 2, '');
    if ($an !== '' && $av !== '') $appMemSpec[$an] = $av;
}
// What the dropdowns may offer: no more than this machine has.
$machineCores = count(preg_grep('/^cpu\d+ /', @file('/proc/stat') ?: [])) ?: 1;
$machineMemMB = 0;
foreach ((@file('/proc/meminfo') ?: []) as $l) {
    if (preg_match('/^MemTotal:\s+(\d+)/', $l, $m)) { $machineMemMB = intdiv((int) $m[1], 1024); }
}

// The previews. Not rows, so they have no table of their own: PREVIEW_ROWS names
// a row and add_preview_vhosts.sh derives the port. Shown read-only, because
// that script decides and this only reports what it would do.
$previewBase   = (int) (conf_val($config, 'PREVIEW_PORT_BASE') ?: 20000);
$previewWanted = array_values(array_filter(array_map(
    'trim', explode(',', (string) conf_val($config, 'PREVIEW_ROWS')))));

// A row says nothing about an environment, so the non-default ones are
// protected. Same rule as auth_in_env() in add_preview_vhosts.sh.
$authInEnv = function (string $spec, string $env) use ($envList): bool {
    $spec = trim($spec);
    if (strpos($spec, ':') === false) {
        return in_array(strtolower($spec), ['yes', 'y', 'true', '1'], true);
    }
    foreach (explode(',', $spec) as $part) {
        [$k, $v] = array_pad(array_map('trim', explode(':', $part, 2)), 2, '');
        if ($k === $env) { return in_array(strtolower($v), ['yes', 'y', 'true', '1'], true); }
    }
    return $env !== ($envList[0] ?? 'live');
};

// An entry is "row", "row:env" or "row:env:port". The drawer edits this shape
// and writes it back explicitly, so a bare name is expanded on the way in.
$previewSpec = [];
foreach ($previewWanted as $entry) {
    $parts = array_map('trim', explode(':', $entry));
    $prow  = $parts[0] ?? '';
    if ($prow === '') { continue; }
    $penv  = $parts[1] ?? '';
    $pport = $parts[2] ?? '';
    if ($penv === '') {
        foreach ($envList as $e) { $previewSpec[$prow][$e] = 'auto'; }
        continue;
    }
    $previewSpec[$prow][$penv] = $pport === '' ? 'auto' : $pport;
}
if ($myRole !== 'full') {
    $previewSpec = array_intersect_key($previewSpec, array_flip(array_column(array_column($rows, 'f'), 1)));
}

$previews = [];
foreach ($rows as $r) {
    $f    = $r['f'];
    $name = trim($f[1]);
    $port = (int) trim($f[2]);
    if (!isset($previewSpec[$name]) || $port <= 0) { continue; }
    foreach ($envList as $env) {
        $want = $previewSpec[$name][$env] ?? null;
        if ($want === null) { continue; }
        // Blank or '-' is every environment, the same reading the row table and
        // add_preview_vhosts.sh use. Taken literally it matched nothing, so a row
        // that inherits its environments vanished from this table while its
        // preview ports were up and answering.
        $rowEnvsRaw = trim($f[10]);
        if ($rowEnvsRaw !== '' && $rowEnvsRaw !== '-') {
            $rowEnvs = array_map('trim', explode(',', $rowEnvsRaw));
            if (!in_array($env, $rowEnvs, true)) { continue; }
        }
        $previews[] = [
            'row'     => $name,
            'type'    => trim($f[0]),
            'env'     => $env,
            'port'    => $want === 'auto'
                ? $previewBase + $port + ($portOffset[$env] ?? 0)
                : (int) $want,
            'blocked' => $authInEnv((string) $f[7], $env),
        ];
    }
}

// What hosting-status.service published. This page runs as www-data and cannot
// ask systemd anything, so it reads an answer somebody privileged wrote down.
//
// Three outcomes, and they must stay distinguishable: no file at all (nobody is
// publishing), a file whose lists are null (the collector could not look), and
// a list (it looked). Anything else here would turn a broken collector into a
// confident "nothing is running".
$status = null;
if (is_readable(STATUSFILE)) {
    $status = json_decode((string) file_get_contents(STATUSFILE), true);
    if (!is_array($status)) {
        $status = null;
    }
}
$status = statusFor($status, $myRole, $me);

// The go-live rehearsal's verdict, written by go_live.sh --check. The page never
// runs the check itself: the real button appears only because a rehearsal
// passed, and a page that could decide that for itself would be the script
// deciding the machine is live, which is the one thing this repo forbids.
$goLive = null;
$goLiveFile = '/run/hosting-status/go-live-check.json';
if (is_readable($goLiveFile)) {
    $goLive = json_decode((string) file_get_contents($goLiveFile), true);
    if (!is_array($goLive)) { $goLive = null; }
}

// A pass is worth something for a few minutes and only against the config it
// was reached on. Two ways it stops counting, and both mean "test it again":
//
//   time      the machine moves. A pass from this morning says nothing about
//             a certificate that expired since, or a credential that was
//             rotated. Five minutes is "you just pressed it".
//   the file  an edit after the check invalidates the check. The verdict was
//             true about a different config, and going live on it would act on
//             something nobody rehearsed.
//
// Deliberately not a session variable: the button is about the state of the
// MACHINE, not about who is looking at the page.
const GOLIVE_GOOD_FOR = 300;
$goLiveFresh = false;
if (is_array($goLive) && ($goLive['passed'] ?? false)) {
    $age = time() - (int) ($goLive['checked'] ?? 0);
    // The page reads the console clone; go_live.sh reads the pipeline tree.
    // They hold the same commit whenever a publish has been applied, so a
    // mismatch means the operator is looking at a different config from the one
    // that would be acted on. Hiding the button there is the point, not a flaw.
    $now = is_readable(CONF) ? substr(hash_file('sha256', CONF), 0, 16) : null;
    $goLiveFresh = $age >= 0
                && $age <= GOLIVE_GOOD_FOR
                && $now !== null
                && $now === ($goLive['fingerprint'] ?? '');
}

// Accounts that exist, so the drawer offers them instead of inviting a typo. A
// username that does not match the password file fails as "wrong password" and
// tells nobody why. Unreadable is fine: the field falls back to free text.
$accounts = [];
$authFile = conf_val($config, 'AUTH_USER_FILE') ?: '/etc/apache2/.htpasswd-progress';
if (is_readable($authFile)) {
    foreach (file($authFile) as $l) {
        if (strpos($l, ':') !== false) {
            $accounts[] = trim(strstr($l, ':', true));
        }
    }
}

// Plus every name already used on a row. The password file is the truth about
// which accounts exist, but it is not always readable from here, and a name in
// use must never disappear from the list that offers it.
// A value holding a colon is per environment, groups split by semicolons, so
// the environment name has to come off before the names are read.
foreach ($rows as $r) {
    foreach (explode(';', $r['f'][11]) as $group) {
        if (strpos($group, ':') !== false) { $group = substr(strstr($group, ':'), 1); }
        foreach (explode(',', $group) as $u) {
            $u = trim($u);
            if ($u !== '' && $u !== '-') { $accounts[] = $u; }
        }
    }
}
// A limited admin is shown no other account. The owner, 2026-09-16: only
// themselves and names already on their own rows, which $rows holds by now.
if ($myRole !== 'full') {
    $onMyRows = [];
    foreach ($rows as $r) {
        foreach (preg_split('/[;,]/', $r['f'][11]) as $u) {
            if (strpos($u, ':') !== false) { $u = substr(strstr($u, ':'), 1); }
            $u = trim($u);
            if ($u !== '' && $u !== '-') { $onMyRows[] = $u; }
        }
    }
    $accounts = array_merge($me !== '' ? [$me] : [], $onMyRows);
}
$accounts = array_values(array_unique($accounts));
sort($accounts);

// Where a mailbox's messages land. Derived, never written on the row, so the
// table can show it without anyone maintaining it.
$mailRoot = conf_val($config, 'MAIL_ROOT') ?: '/srv/mail';

// The admin is added to every protected site by the vhost script, so the field
// never names them. Shown as a ticked, fixed box rather than left out, because
// an absence explains nothing.
$adminUser = conf_val($config, 'AUTH_ADMIN_USER') ?: 'admin';

// Domains a mailbox may belong to: the base domain, every zone DNS manages, and
// anything already used on a mailbox row. Offered as a list because a typo here
// creates an address that accepts no mail and says nothing about why.
// The web roots, and what already sits in them. A document root is stored
// relative to WEB_ROOT, so the drawer can show the fixed part rather than ask
// for it, and can say whether the folder it names exists yet. Read here once:
// scandir per keystroke would be a request per keystroke.
$webRoots   = [];
$webFolders = [];
foreach ($envList as $envName) {
    $root = conf_val($config, 'WEB_ROOT_' . strtoupper($envName));
    if ($root === null || $root === '') { continue; }
    $root = rtrim($root, '/');
    $webRoots[$envName] = $root;
    if (isset($webFolders[$root])) { continue; }
    $found = [];
    if (is_dir($root)) {
        foreach ((array) scandir($root) as $entry) {
            if ($entry === '.' || $entry === '..') { continue; }
            if (is_dir($root . '/' . $entry)) { $found[] = $entry; }
        }
        sort($found);
    }
    $webFolders[$root] = $found;
}
// Another customer's folder name is theirs. A limited admin is offered only
// the folders their own rows already use. Item 136.
if ($myRole !== 'full') {
    $myPaths = [];
    foreach ($rows as $r) {
        $myPaths[] = explode('/', trim($r['f'][3] ?? ''))[0];
    }
    foreach ($webFolders as $root => $found) {
        $webFolders[$root] = array_values(array_intersect($found, $myPaths));
    }
}

$dnsDomains = [];
foreach (explode(',', (string) conf_val($config, 'DNS_DOMAINS')) as $d) {
    $d = trim($d);
    if ($d !== '') { $dnsDomains[] = $d; }
}

$mailDomains = array_merge([$baseDomain], $dnsDomains);
foreach ($rows as $r) {
    if ($r['f'][0] !== 'mailbox') { continue; }
    $d = trim($r['f'][4]);
    if ($d !== '' && $d !== '-') { $mailDomains[] = ltrim($d, '='); }
}
$mailDomains = array_values(array_unique($mailDomains));

// A limited admin is offered only the domains they own. The owner, 2026-09-16:
// one domain, one admin, and a label under BASE_DOMAIN owns nothing. Any other
// domain is a request, checked in the drawer.
if ($myRole !== 'full') {
    $mine = array_keys(array_filter($own['owners'], fn($o) => $o === $me));
    $mailDomains = array_values($mine);
    $dnsDomains = array_values(array_intersect($dnsDomains, $mine));
}
?>
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Hosting manager</title>
<!-- Inline rather than a file. The console is one PHP file with no assets
     beside it, and a real favicon.ico would be a second thing to install and
     keep in step for the sake of one request. Without this every page load
     logged a 404 in the browser console, which is noise in the one place you
     look when something is actually wrong.
     currentColor is not available to a favicon, so the stack is drawn in the
     blue that the page uses for its primary action, which reads on both
     themes. -->
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 16 16'%3E%3Cg fill='%231f6feb'%3E%3Crect x='1' y='2' width='14' height='4' rx='1'/%3E%3Crect x='1' y='7.5' width='14' height='4' rx='1' opacity='.75'/%3E%3Crect x='1' y='13' width='14' height='2' rx='1' opacity='.5'/%3E%3C/g%3E%3Ccircle cx='12.5' cy='4' r='1' fill='%234ac26b'/%3E%3Ccircle cx='12.5' cy='9.5' r='1' fill='%234ac26b'/%3E%3C/svg%3E">
<!-- Styles and scripts are files beside this one, not blocks inside it. The
     stamp is the file's own mtime, so a deploy is picked up without anyone
     clearing a cache, and an unchanged file keeps being served from one. -->
<link rel="stylesheet" href="<?= asset('style.css') ?>">
</head>
<body>
<div class="wrap">

  <div class="page-head">
    <div>
      <h1 data-i18n="title">Hosting manager</h1>
      <p class="sub">
        <span data-i18n="thisMachine">This machine is</span>
        <?php if ($isLive): ?>
          <span class="state live" data-i18n="stLive">LIVE</span>
          <span data-i18n="stLiveTail">and serving real traffic.</span>
        <?php else: ?>
          <span class="state test" data-i18n="stTest">a test machine</span>,
          <span data-i18n="stTestTail">built beside the live one.</span>
        <?php endif; ?>
      </p>

      <!-- Beside the sentence that states what this machine IS, because that is
           the line an operator reads when they want to change it. Its own form
           rather than the config one: going live is not an edit to the rows, and
           it must not carry unsaved changes along with it. -->
      <?php /* A limited admin sees none of this: going live, and testing whether
           this machine could, are about the MACHINE rather than about any row
           they own. Item 105, the owner 2026-09-10. index.php refuses golive and
           golivetest from them as well, which is the half that matters. */ ?>
      <?php if (!$isLive && $myRole === 'full'): ?>
      <div class="row-actions golive" style="margin:.5rem 0 0">
        <form method="post" style="margin:0" data-busy="golivetest">
          <input type="hidden" name="action" value="golivetest">
          <button type="submit" class="cta-warn action-btn" data-i18n="bGoLiveTest">
            Test whether this machine can go live</button>
        </form>
        <?php if ($goLiveFresh): ?>
        <form method="post" style="margin:0" data-busy="golive">
          <input type="hidden" name="action" value="golive">
          <button type="submit" class="cta action-btn action-apply" data-i18n="bGoLive">
            This machine is now live</button>
        </form>
        <?php endif; ?>
      </div>
      <p class="note" style="margin:.35rem 0 0;max-width:46rem">
        <?php if ($goLiveFresh): ?>
          <span data-i18n="goLivePassed">The rehearsal passed. Going live promotes</span>
          <?= (int) ($goLive['staging'] ?? 0) ?>
          <span data-i18n="goLivePassedTail">certificates and writes the address record. Neither can be undone.</span>
        <?php elseif (is_array($goLive) && ($goLive['passed'] ?? false)): ?>
          <!-- Passed, but no longer counts. Said as its own case rather than
               falling through to the failure text, which would claim a blocker
               that was never there. -->
          <strong data-i18n="goLiveStaleLead">Test again:</strong>
          <span data-i18n="goLiveStale">that check has expired, or the config has changed since it ran.</span>
        <?php elseif (is_array($goLive)): ?>
          <?php
          // The reason the rehearsal gave, not a sentence about the button. The
          // operator wants to know what is wrong, and go_live.sh already said
          // it in one line; repeating that beats paraphrasing it.
          $why = '';
          foreach (($goLive['reasons'] ?? []) as $r) {
              // Indented lines are the advice under a reason, not the reason,
              // so the test is on the raw string and the trim comes after it.
              if (str_starts_with((string) $r, ' ')) { continue; }
              if (trim((string) $r) !== '') { $why = trim((string) $r); break; }
          }
          ?>
          <strong data-i18n="goLiveNotYet">Not ready:</strong>
          <?= htmlspecialchars($why !== '' ? $why : 'the last rehearsal did not pass.') ?>
        <?php else: ?>
          <span data-i18n="goLiveNever">Never rehearsed. The test changes nothing.</span>
        <?php endif; ?>
      </p>
      <?php endif; ?>
    </div>
    <div class="head-controls">
      <!-- Who is signed in here, and for a full admin who else has the page
           open, with a Kick. The owner, 2026-09-18. -->
      <div class="who" id="who">
        <button type="button" id="who-btn" class="who-btn" aria-expanded="false"
                title="<?= htmlspecialchars($myRole === 'full' ? 'Full access admin' : 'Admin') ?>">
          <span aria-hidden="true">👤</span> <?= htmlspecialchars($me) ?>
          <span class="who-count" id="who-count" hidden></span>
        </button>
        <div class="who-list" id="who-list" hidden>
          <?php if ($myRole === 'full'): ?>
          <p class="note" data-i18n="whoOnline">Online now</p>
          <ul id="who-users"></ul>
          <?php endif; ?>
          <a href="/logout" class="who-signout" id="who-signout" data-i18n="whoSignOut">Sign out</a>
        </div>
      </div>
      <a href="./?second-factor=recovery" class="key-link" title="Recovery codes">🔑</a>
      <button type="button" id="theme-btn" class="theme-toggle" role="switch"
              aria-checked="false" title="Light / dark">
        <span class="theme-ico sun" aria-hidden="true">☀</span>
        <span class="theme-ico moon" aria-hidden="true">☾</span>
        <span class="theme-knob" aria-hidden="true"></span>
      </button>
      <button type="button" id="lang-btn" title="Taal / Language">🇬🇧 English</button>
    </div>
  </div>

  <!-- Shown for as long as Jenkins is busy, and the page reloads itself when it
       stops. The dialog closes the moment the job is handed over, so without
       this the only sign anything is happening is a greyed-out button. -->
  <!-- A change somebody else started, from any page. The owner, 2026-09-18. -->
  <div class="msg running" id="work-banner" hidden>
    <span class="spin" aria-hidden="true"></span><span id="work-banner-text"></span>
  </div>
  <div class="msg running" id="job-banner" hidden>
    <span class="spin" aria-hidden="true"></span><span id="job-banner-text"></span>
  </div>

  <?php /* The upgrade gate: a new upstream version on test, waiting for votes. */
    $gateLines = [];
    exec('sudo ' . UPGATE . ' list 2>/dev/null', $gateLines);
    foreach ($gateLines as $gl):
        $g = explode("\t", $gl);
        if (count($g) < 6) continue;
        [$gPkg, $gVer, $gLive, $gDays, $gPaused, $gVotes] = $g;
        $gMine = '';
        foreach (array_filter(explode(',', $gVotes)) as $uv) {
            [$u, $v] = array_pad(explode(':', $uv, 2), 2, '');
            if ($u === $me) $gMine = $v;
        } ?>
    <div class="msg running upgrade-banner">
      <strong><?= htmlspecialchars("$gPkg $gVer") ?></strong>
      is on test (live runs <?= htmlspecialchars($gLive) ?>, open <?= (int) $gDays ?> day(s)<?= $gPaused === '1' ? ', paused' : '' ?>). Please test it, then vote:
      <?php foreach (['urgent' => '⏩ Urgent', 'up' => '👍 Works', 'neutral' => '😐 Neutral', 'down' => '👎 Broken'] as $gv => $gLabel): ?>
        <form method="post" style="display:inline">
          <input type="hidden" name="action" value="upgradevote">
          <input type="hidden" name="pkg" value="<?= htmlspecialchars($gPkg) ?>">
          <input type="hidden" name="vote" value="<?= $gv ?>">
          <button type="submit"<?= $gMine === $gv ? ' aria-pressed="true" style="font-weight:bold"' : '' ?>><?= $gLabel ?></button>
        </form>
      <?php endforeach; ?>
      <?php if ($myRole === 'full'): ?>
        <?php foreach ([$gPaused === '1' ? 'upgraderesume' : 'upgradepause' => $gPaused === '1' ? 'Resume' : 'Pause', 'upgradepublish' => 'Publish now'] as $ga => $gLabel): ?>
          <form method="post" style="display:inline">
            <input type="hidden" name="action" value="<?= $ga ?>">
            <input type="hidden" name="pkg" value="<?= htmlspecialchars($gPkg) ?>">
            <button type="submit"><?= $gLabel ?></button>
          </form>
        <?php endforeach; ?>
      <?php endif; ?>
    </div>
  <?php endforeach; ?>

  <?php if ($message !== ''): ?>
    <div class="msg <?= htmlspecialchars($messageClass) ?>"><?= htmlspecialchars($message) ?></div>
  <?php endif; ?>

  <?php /* The steps of the create that just ran. Shown on the press that ran
           it, and kept showing while any step failed: a create that stopped
           halfway is exactly what nobody should have to go looking for. */ ?>
  <?php
  // A FAILED CREATE IS KEPT ON SCREEN UNTIL ITS ROW IS GONE, and no longer.
  //
  // Keeping it is deliberate and stays: a create that stopped halfway is
  // exactly what nobody should have to go looking for. What was missing is an
  // end to it. The panel rendered whenever any step had failed, with no other
  // condition, so on 2026-09-05 a seed failure from a throwaway row was still
  // on the page hours after that row and its repository had been deleted.
  //
  // Worse than untidy: it made a page that had done nothing look like it had
  // just failed, and both a person and a test read it that way.
  //
  // The row's own existence is the signal rather than an age. A failure from
  // this morning still matters while the row sits half-made; one from a minute
  // ago does not, once the row has been removed.
  //
  // Computed here because $rows does not exist where the file is read, a
  // thousand lines earlier.
  $createIsStale = false;
  if ($createFailed && $createRow !== '') {
      $createIsStale = true;
      foreach ($rows as $r) {
          $f = $r['f'] ?? [];
          if (isset($f[1]) && trim((string) $f[1]) === $createRow) { $createIsStale = false; break; }
      }
  }
  ?>
  <?php if ($createSteps && !$createIsStale && (in_array($_GET['done'] ?? '', ['provdone', 'steprerun'], true) || isset($_GET['created']) || $createFailed)): ?>
    <div class="card">
      <h2 style="font-size:1.02rem;margin:.1rem 0 .55rem" data-i18n="createStepsH">What the create did</h2>
      <?= render_create_steps($createSteps, $createRow) ?>
      <?php if ($createWhen !== ''): ?>
        <p class="note" style="margin:.4rem 0 0"><?= htmlspecialchars($createWhen) ?></p>
      <?php endif; ?>
    </div>
  <?php endif; ?>

  <?php /* And the apply's generators. Shown after an apply and kept showing
           while any of them failed, so a run that stopped in the middle does
           not need Jenkins' log read end to end to find out where. */ ?>
  <?php if ($applySteps && (in_array($_GET['done'] ?? '', ['applied', 'fastapplied', 'driftfixed', 'driftapplied', 'escalated'], true) || $applyFailed)): ?>
    <div class="card">
      <h2 style="font-size:1.02rem;margin:.1rem 0 .55rem" data-i18n="applyStepsH">What the apply did</h2>
      <?= render_create_steps($applySteps, '', '') ?>
      <?php if ($applyWhen !== ''): ?>
        <p class="note" style="margin:.4rem 0 0"><?= htmlspecialchars($applyWhen) ?></p>
      <?php endif; ?>
    </div>
  <?php endif; ?>

  <?php if ($output !== ''): ?>
    <?php $outputSummary = summarize_output($output); ?>
    <div class="card">
      <h2 style="font-size:1.02rem;margin:.1rem 0 .55rem" data-i18n="resultH">Result</h2>
      <pre class="out"><?= htmlspecialchars($outputSummary) ?></pre>
      <?php if (trim($outputSummary) !== trim($output)): ?>
      <details style="margin-top:.65rem">
        <summary class="note" style="cursor:pointer" data-i18n="fullRaw">Show full command output</summary>
        <pre class="out"><?= htmlspecialchars($output) ?></pre>
      </details>
      <?php endif; ?>
    </div>
  <?php endif; ?>

  <?php if (!$confReadable): ?>
    <div class="msg bad">
      Cannot read <?= htmlspecialchars(CONF) ?>. Run add_hosting_manager.sh on this machine.
    </div>
  <?php endif; ?>

  <!-- Hidden until the status call says there is something to install. Starts
       hidden rather than visible so it does not appear and then vanish on every
       page load. -->
  <?php /* Updating the machine is not a customer's to press either. */ ?>
  <?php if ($myRole === 'full'): ?>
  <!-- Filled by cells.js only when this machine's own software is near or past
       its end of support, or has no patch guarantee. -->
  <div class="card" id="support-card" hidden></div>
  <?php endif; ?>
  <?php if ($myRole === 'full'): ?>
  <div class="card" id="update-card" style="display:none">
    <div class="row-actions">
      <form method="post" style="margin:0" data-busy="update">
        <input type="hidden" name="action" value="update">
        <button type="submit" class="action-btn action-update" id="btn-update" data-job="machine-update"
                data-i18n="updateBtn">Update this machine</button>
      </form>
      <form method="post" style="margin:0;display:none" id="reboot-form" data-busy="reboot">
        <input type="hidden" name="action" value="reboot">
        <button type="submit" class="action-btn action-reboot" id="btn-reboot"
                data-i18n="rebootBtn">Reboot to finish updates</button>
      </form>
      <span class="note" id="update-note" data-i18n="updateNote">
        Installs operating system updates through Jenkins. Never reboots: it tells you if one is needed.
      </span>
    </div>
  </div>
  <?php endif; ?>

  <?php /* The share write window: every share writable without a password for a
           chosen time. Its buttons sit in the Shared folders tab, inside
           rows-form, so they reach these two forms through form="".
           share-write-window-decisions.md. */
    $swOpen = $swStuck = false;
    if ($myRole === 'full'):
      $swLines = [];
      exec('sudo ' . SHAREWIN . ' status 2>/dev/null', $swLines);
      $sw = json_decode(implode('', $swLines), true) ?: [];
      $swOpen  = !empty($sw['open']);
      $swStuck = !empty($sw['stuck']); ?>
    <form method="post" id="share-window-open" hidden><input type="hidden" name="action" value="sharewindow"></form>
    <form method="post" id="share-window-close" hidden><input type="hidden" name="action" value="sharewindowclose"></form>
  <?php endif; ?>
  <form method="post" class="card" id="rows-form">
    <h2 style="font-size:1.05rem;margin:.1rem 0 .75rem" data-i18n="servesH">What this machine serves</h2>

    <!-- One tab per kind of thing, because they are not the same kind of thing.
         A mailbox has no port and no environment, a website has no port at all,
         a proxy is one service however many environments exist, and the
         machine's own panels are not rows and cannot be edited as rows. One
         shared table meant every one of them carried columns it can never
         fill, and the panels sat among editable rows with no edit button,
         which reads as a bug rather than as a different kind of thing. -->

    <!-- Config drift: the machine does not match the saved config, and the
         operator did not cause it on this page. Built from the report the last
         privileged check wrote, never computed here.
         Fix drift appears for any drift and picks its own path: the fast
         rewrite when the drift is vhost-shaped, the full job when it needs a
         prune, a unit or a certificate. It used to be offered only for the
         first case and send the operator to Make it live for the second, which
         put routine work on the emergency fallback. -->
    <?php if ($driftBanner): ?>
    <div class="drift-banner" id="drift-banner" data-fixable="<?= $driftFixable ? '1' : '0' ?>">
      <p class="drift-banner-head">
        <strong>Config drift detected.</strong>
        <?= (int) $driftCount ?> thing<?= $driftCount === 1 ? '' : 's' ?> on this machine
        <?= $driftCount === 1 ? 'does' : 'do' ?> not match the saved config,
        checked <?= htmlspecialchars($reportAge) ?>.
      </p>
      <ul class="drift">
        <?php foreach (['ADD', 'UPDATE', 'ORPHAN'] as $k): ?>
          <?php foreach ($drift[$k] as $d): ?>
        <li><span class="tag <?= strtolower($k) ?>"><?= $k ?></span>
            <span class="what"><?= htmlspecialchars($d['what']) ?></span>
            <span class="name"><?= htmlspecialchars($d['name']) ?></span></li>
          <?php endforeach; ?>
        <?php endforeach; ?>
      </ul>
      <?php if ($driftFixable): ?>
      <!-- One button, the owner 2026-09-23: a second one beside Make it live read
           as a choice that did not exist. -->
      <p class="note">Make it live on this machine brings the machine back in line with the saved config.</p>
      <?php elseif ($staged !== ''): ?>
      <p class="note" id="drift-staged">
        There is an unsaved edit staged, so part of this drift may be yours.
        Save it with <strong>Make it live on this machine</strong>, or discard it,
        and the fix comes back if anything is still out of step.
      </p>
      <?php endif; ?>
    </div>
    <?php endif; ?>


    <!-- ONE button. It checks first, shows what would change, and only saves
         and applies once that has been confirmed.
         The two hidden ones are the halves it drives: the dialog presses them.
         Keeping them as real submits means the form still posts its config the
         one way it always did. -->
    <div class="row-actions" style="margin-top:.5rem">
      <button type="submit" name="action" value="recheck" id="btn-check" hidden></button>
      <button type="submit" name="action" value="save_apply" id="btn-save-apply" hidden></button>
      <button type="submit" name="action" value="save_fast" id="btn-save-fast" hidden></button>

      <button type="submit" name="action" value="recheck" id="btn-apply" class="cta action-btn action-apply"
              data-job="hosting-apply"<?= $nothingToApply ? " hidden" : "" ?>>
        Make it live on this machine
      </button>
      <input type="hidden" name="intent" id="intent" value="">
    </div>

    <?php if ($staged !== ''): ?>
    <!-- SHOWN, NOT DELETED. A staged candidate is the only record that somebody
         pressed Make it live and walked away, so removing it on load would
         destroy that with no message, on the page whose whole job is saying
         what is about to happen. The owner's call, item 87. -->
    <div class="msg<?= $stagedStale ? " bad" : "" ?>" id="staged-note" style="margin-bottom:1rem;display:block">
      <?php if ($stagedStale): ?>
      <strong>This staged change is out of date.</strong>
      It was staged<?= $stagedWhen !== '' ? ' on ' . htmlspecialchars($stagedWhen) : '' ?>
      against a config that has changed since, so the values below are not the
      current ones. Saving it will be refused for the same reason.
      <?php else: ?>
      <strong>Showing your unsaved changes</strong>, not what is on the branch.
      It was staged<?= $stagedWhen !== '' ? ' on ' . htmlspecialchars($stagedWhen) : '' ?>.
      <?php endif; ?>
      <button type="submit" name="action" value="discardstaged" class="action-btn"
              onclick="return confirm('Discard the staged change and show what is on the branch?')">
        Discard the staged change
      </button>
    </div>
    <?php endif; ?>


    <!-- A phone has no room for twelve tabs side by side: they fold behind this. -->
    <button type="button" class="tabs-menu-btn" id="tabs-menu-btn" aria-expanded="false"
            aria-controls="tabs-list"><span aria-hidden="true">☰</span> <span id="tabs-menu-label"></span></button>
    <div class="tabs" id="tabs-list" role="tablist">
      <button type="button" class="tab svc app" role="tab" data-tab="apps" data-kind="app" aria-selected="true">
        <span data-i18n="tabApps">Applications</span> <span class="count" id="count-apps"></span><span class="bell" data-tabreq="apps" hidden></span>
      </button>
      <button type="button" class="tab svc website" role="tab" data-tab="websites" data-kind="website" aria-selected="false">
        <span data-i18n="tabWebsites">Websites</span> <span class="count" id="count-websites"></span><span class="bell" data-tabreq="websites" hidden></span>
      </button>
      <button type="button" class="tab svc mailbox" role="tab" data-tab="mailboxes" data-kind="mailbox" aria-selected="false">
        <span data-i18n="tabMailboxes">Mailboxes</span> <span class="count" id="count-mailboxes"></span><span class="bell" data-tabreq="mailboxes" hidden></span>
      </button>
      <button type="button" class="tab svc proxy" role="tab" data-tab="proxies" data-kind="proxy" aria-selected="false">
        <span data-i18n="tabProxies">Proxies</span> <span class="count" id="count-proxies"></span>
      </button>
      <button type="button" class="tab svc panel" role="tab" data-tab="machine" data-kind="panel" aria-selected="false">
        <span data-i18n="tabMachine">Machine pages</span> <span class="count" id="count-machine"></span>
      </button>
      <button type="button" class="tab svc smb" role="tab" data-tab="smb" data-kind="smb" aria-selected="false">
        <span data-i18n="tabSmb">Shared folders</span> <span class="count" id="count-smb"></span>
      </button>
      <button type="button" class="tab svc environment" role="tab" data-tab="environments" data-kind="env" aria-selected="false">
        <span data-i18n="tabEnvironments">Environments</span> <span class="count" id="count-environments"></span>
      </button>
      <button type="button" class="tab svc ports" role="tab" data-tab="ports" aria-selected="false">
        <span data-i18n="tabPorts">Ports</span>
      </button>
      <button type="button" class="tab svc repos" role="tab" data-tab="repos" aria-selected="false">
        <span data-i18n="tabRepos">Repositories</span> <span class="count" id="count-repos"></span>
      </button>
      <!-- Everybody who may sign in, anywhere on this machine. Its own hue:
           indigo, deliberately away from the app blue and the proxy lavender. -->
      <button type="button" class="tab svc user" role="tab" data-tab="users" aria-selected="false">
        <span data-i18n="tabUsers">Users</span> <span class="count" id="count-users"></span>
      </button>
      <button type="button" class="tab svc raw" role="tab" data-tab="raw" aria-selected="false">
        <span data-i18n="tabRaw">Config file</span>
      </button>
      <button type="button" class="tab svc audit" role="tab" data-tab="audit" aria-selected="false">
        <span data-i18n="tabAudit">Audit</span>
      </button>
    </div>

    <!-- Above the table, not below it. The button you came to press should not
         be behind a scroll on a pane with forty rows. -->
    <div class="row-actions" style="margin:.6rem 0 .85rem" data-pane="apps">
      <!-- Every application on the machine, every environment. After a reflash
           or a power cut the answer is the same for all of them, and doing it
           one line at a time is twenty presses. -->
      <button type="button" class="svc-all go" data-svcpane="start"
              id="svc-start-all">Start all</button>
      <button type="button" class="svc-all danger" data-svcpane="stop"
              id="svc-stop-all">Stop all</button>
      <button type="button" class="add-btn app" data-kind="app">Add an application</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="websites">
      <button type="button" class="add-btn website" data-kind="website">Add a website</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="mailboxes">
      <button type="button" class="add-btn mailbox" data-kind="mailbox">Add a mailbox</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="proxies">
      <button type="button" class="add-btn proxy" data-kind="proxy">Add a proxy</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="machine">
      <button type="button" class="add-btn panel" id="add-panel" data-kind="panel">Add a page</button>
    </div>

    <!-- Same shape as every other pane's bar: bulk verbs on the left, hidden
         until something is ticked, and Add rightmost. -->
    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="users">
      <!-- uedit-btn, NOT edit-btn: bulk.js manages any pane holding both an
           .edit-btn and a .bulk-apply, and it would set this Apply disabled
           from the ROW tick count, which has nothing to do with users. -->
      <button type="button" class="uedit-btn user action-btn" id="users-edit"
              style="margin-left:auto" data-i18n="bEdit">Edit</button>
      <button type="button" class="bulk-apply user" id="users-apply" hidden
              data-i18n="bBulkApply">Apply changes</button>
      <button type="button" class="add-btn user" id="add-user"
              data-i18n="uAdd">Add a user</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="environments">
      <button type="button" class="add-btn environment" id="add-env" data-kind="env">Add an environment</button>
    </div>

    <div class="row-actions" style="margin:.6rem 0 .85rem;display:none" data-pane="smb">
      <!-- Not a save. It makes Samba serve what is already published, which is
           the state a save leaves behind when its push succeeds and the pull
           into the live tree does not. -->
      <button type="submit" name="action" value="reloadsmb" class="svc-all smb"
              id="btn-smb-reload">Reload Samba</button>
      <button type="button" class="add-btn smb" id="add-smb" data-kind="smb">Add a shared folder</button>
      <?php if ($myRole === 'full'): ?>
        <span class="share-window<?= $swOpen ? ' running' : '' ?><?= $swStuck ? ' bad' : '' ?>" id="share-window">
          <details class="sw-menu">
            <summary class="svc-all smb">🔓 <?= $swOpen ? 'Restart timer' : 'Open without password' ?> ▾</summary>
            <div class="sw-list">
              <?php foreach (SHAREWIN_MINUTES as $swMin => $swLabel): ?>
                <button type="submit" form="share-window-open" name="minutes" value="<?= $swMin ?>"><?= $swLabel ?></button>
              <?php endforeach; ?>
            </div>
          </details>
          <?php if ($swOpen): ?>
            Writable without a password: <strong id="share-window-left" data-ends="<?= (int) $sw['ends'] ?>"></strong> left.
          <?php elseif ($swStuck): ?>
            <strong>Still open after its time ran out.</strong>
          <?php endif; ?>
          <?php if ($swOpen || $swStuck): ?>
            <button type="submit" form="share-window-close">Close now</button>
          <?php endif; ?>
        </span>
      <?php endif; ?>
    </div>

    <!-- Two views of the same rows, not two sets of rows. The owner, 2026-09-10:
         thirteen columns in one table is too many to read, and the pipeline
         half is what a different question asks for. Serving answers "is it
         up", Pipeline answers "did the last deploy work". -->
    <div class="app" data-pane="apps">
      <div class="sub-tabs" data-subtabs="apps">
        <button type="button" data-subview="serving" aria-pressed="true"
                data-i18n="vServing">Serving</button>
        <button type="button" data-subview="pipeline" aria-pressed="false"
                data-i18n="vPipeline">Pipeline</button>
        <!-- Requests is a VIEW of these rows, not a tab of its own. The owner,
             2026-09-10, applying his own rule: one entity per table. A tab
             would have mixed websites, applications and mailboxes into one
             list; a third view keeps each kind with its own kind.
             The count is the bell: it is what tells an admin there is work
             waiting, and a customer that an answer has arrived. -->
        <button type="button" data-subview="requests" aria-pressed="false"
                hidden><span data-i18n="vRequests">Requests</span><span class="bell" data-reqcount hidden></span></button>
      </div>

      <div style="overflow-x:auto" data-subview-of="apps" data-subview="serving">
      <table data-table="apps">
        <thead>
          <tr>
            <th class="cert-col"><span data-i18n="cCert">Certificate</span></th>
            <th class="state-col"></th>
            <th class="sortable" data-sort="2" aria-sort="ascending" data-i18n-title="sPort" title="the door on this machine">
              <span data-i18n="cPort">Port</span></th>
            <th class="sortable" data-sort="10" aria-sort="none" data-i18n-title="sEnvs" title="which copy this is">
              <span data-i18n="cEnvs">Environment</span></th>
            <th data-i18n-title="sPreview" title="a LAN port serving this copy">
              <span data-i18n="cPreview">Preview</span></th>
            <th class="sortable" data-sort="1" aria-sort="none" data-i18n-title="sName" title="the unit and vhost name">
              <span data-i18n="cName">Name</span></th>
            <th class="repo-col" data-i18n-title="sRepo" title="where the code lives"></th>
            <th data-i18n-title="sRuntime" title="what the deployed build targets">
              <span data-i18n="cRuntime">Runs on</span></th>
            <th class="sortable" data-sort="7" aria-sort="none" data-i18n-title="sLogin" title="a password stands in front">
              <span data-i18n="cLogin">Login</span></th>
            <th class="sortable" data-sort="4" aria-sort="none" data-i18n-title="sAddr" title="what you type in a browser">
              <span data-i18n="cAddr">Address</span></th>
            <!-- Running or stopped, in words, beside the buttons that change it.
                 Applications only: it is the one row type with a unit. -->
            <th class="unit-col" data-i18n-title="sUnit" title="whether its service is running">
              <span data-i18n="cUnit">State</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="apps-body"></tbody>
      </table>
      </div>

      <!-- Deployed and Behind exist only here: they need a column each and
           there was no room for them beside the serving state. -->
      <div style="overflow-x:auto;display:none" data-subview-of="apps" data-subview="pipeline">
      <table data-table="apps-pipeline">
        <thead>
          <tr>
            <th class="state-col"></th>
            <th class="sortable" data-sort="10" aria-sort="none" data-i18n-title="sEnvs" title="which copy this is">
              <span data-i18n="cEnvs">Environment</span></th>
            <th class="sortable" data-sort="1" aria-sort="ascending" data-i18n-title="sName" title="the unit and vhost name">
              <span data-i18n="cName">Name</span></th>
            <th class="repo-col" data-i18n-title="sRepo" title="where the code lives"></th>
            <th data-i18n-title="sRuntime" title="what the deployed build targets">
              <span data-i18n="cRuntime">Runs on</span></th>
            <th class="pipe-col" data-i18n-title="sPipeline" title="the last deploy of this environment">
              <span data-i18n="cPipeline">Pipeline</span></th>
            <th class="dots-col" data-i18n-title="sRecent" title="the last five builds, newest first">
              <span data-i18n="cRecent">Last 5</span></th>
            <th class="sha-col" data-i18n-title="sDeployed" title="the commit the running build came from">
              <span data-i18n="cDeployed">Deployed</span></th>
            <th class="behind-col" data-i18n-title="sBehind" title="whether the branch has moved since">
              <span data-i18n="cBehind">Branch</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="apps-pipeline-body"></tbody>
      </table>
      </div>
      <!-- Requests for THIS kind of row. Both sides read the same table: a
           customer is sent only their own by the handler, so the difference
           between the two views is the data, never a second page. -->
      <div style="overflow-x:auto;display:none" data-subview-of="apps" data-subview="requests">
      <table data-table="req-apps">
        <thead>
          <tr>
            <th data-i18n="qWhen">Asked</th>
            <th data-i18n="qWho">By</th>
            <th data-i18n="qWhat">What</th>
            <th data-i18n="qWhy">Why</th>
            <th data-i18n="qState">State</th>
            <th data-i18n="qAnswer">Answer</th>
            <th></th>
          </tr>
        </thead>
        <tbody data-reqbody="apps"></tbody>
      </table>
      </div>
    </div>

    <!-- No Port column: Apache serves the files off disk and nothing listens.
         Document root instead, which is the field a website actually has. -->
    <div class="website" style="display:none" data-pane="websites">
      <div class="sub-tabs" data-subtabs="websites">
        <button type="button" data-subview="serving" aria-pressed="true"
                data-i18n="vServing">Serving</button>
        <button type="button" data-subview="pipeline" aria-pressed="false"
                data-i18n="vPipeline">Pipeline</button>
        <!-- Requests is a VIEW of these rows, not a tab of its own. The owner,
             2026-09-10, applying his own rule: one entity per table. A tab
             would have mixed websites, applications and mailboxes into one
             list; a third view keeps each kind with its own kind.
             The count is the bell: it is what tells an admin there is work
             waiting, and a customer that an answer has arrived. -->
        <button type="button" data-subview="requests" aria-pressed="false"
                hidden><span data-i18n="vRequests">Requests</span><span class="bell" data-reqcount hidden></span></button>
      </div>

      <div style="overflow-x:auto" data-subview-of="websites" data-subview="serving">
      <table data-table="websites">
        <thead>
          <tr>
            <th class="cert-col"><span data-i18n="cCert">Certificate</span></th>
            <th class="state-col"></th>
            <th class="sortable" data-sort="10" aria-sort="none" data-i18n-title="sEnvs" title="which copy this is">
              <span data-i18n="cEnvs">Environment</span></th>
            <th data-i18n-title="sPreview" title="a LAN port serving this copy">
              <span data-i18n="cPreview">Preview</span></th>
            <th class="sortable" data-sort="1" aria-sort="ascending" data-i18n-title="sName" title="the vhost name">
              <span data-i18n="cName">Name</span></th>
            <th class="sortable" data-sort="3" aria-sort="none" data-i18n-title="sDocRoot" title="the folder Apache serves, under WEB_ROOT">
              <span data-i18n="cDocRoot">Document root</span></th>
            <th class="repo-col" data-i18n-title="sRepo" title="where the code lives"></th>
            <th class="sortable" data-sort="7" aria-sort="none" data-i18n-title="sLogin" title="a password stands in front">
              <span data-i18n="cLogin">Login</span></th>
            <th class="sortable" data-sort="4" aria-sort="none" data-i18n-title="sAddr" title="what you type in a browser">
              <span data-i18n="cAddr">Address</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="websites-body"></tbody>
      </table>
      </div>

      <!-- No Runtime column: a website is served off disk, so there is no
           runtime to name. -->
      <div style="overflow-x:auto;display:none" data-subview-of="websites" data-subview="pipeline">
      <table data-table="websites-pipeline">
        <thead>
          <tr>
            <th class="state-col"></th>
            <th class="sortable" data-sort="10" aria-sort="none" data-i18n-title="sEnvs" title="which copy this is">
              <span data-i18n="cEnvs">Environment</span></th>
            <th class="sortable" data-sort="1" aria-sort="ascending" data-i18n-title="sName" title="the vhost name">
              <span data-i18n="cName">Name</span></th>
            <th class="repo-col" data-i18n-title="sRepo" title="where the code lives"></th>
            <th data-i18n-title="sBuiltWith" title="the framework the deployed build was made with">
              <span data-i18n="cBuiltWith">Built with</span></th>
            <th class="pipe-col" data-i18n-title="sPipeline" title="the last deploy of this environment">
              <span data-i18n="cPipeline">Pipeline</span></th>
            <th class="dots-col" data-i18n-title="sRecent" title="the last five builds, newest first">
              <span data-i18n="cRecent">Last 5</span></th>
            <th class="sha-col" data-i18n-title="sDeployed" title="the commit the running build came from">
              <span data-i18n="cDeployed">Deployed</span></th>
            <th class="behind-col" data-i18n-title="sBehind" title="whether the branch has moved since">
              <span data-i18n="cBehind">Branch</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="websites-pipeline-body"></tbody>
      </table>
      </div>
      <!-- Requests for THIS kind of row. Both sides read the same table: a
           customer is sent only their own by the handler, so the difference
           between the two views is the data, never a second page. -->
      <div style="overflow-x:auto;display:none" data-subview-of="websites" data-subview="requests">
      <table data-table="req-websites">
        <thead>
          <tr>
            <th data-i18n="qWhen">Asked</th>
            <th data-i18n="qWho">By</th>
            <th data-i18n="qWhat">What</th>
            <th data-i18n="qWhy">Why</th>
            <th data-i18n="qState">State</th>
            <th data-i18n="qAnswer">Answer</th>
            <th></th>
          </tr>
        </thead>
        <tbody data-reqbody="websites"></tbody>
      </table>
      </div>
    </div>

    <!-- No Environment column: a proxy row is one service however many
         environments exist, per maintain_services.sh. -->
    <div class="proxy" style="overflow-x:auto;display:none" data-pane="proxies">
      <table data-table="proxies">
        <thead>
          <tr>
            <th class="cert-col"><span data-i18n="cCert">Certificate</span></th>
            <th class="state-col"></th>
            <th class="sortable" data-sort="2" aria-sort="ascending" data-i18n-title="sPort" title="the door on this machine">
              <span data-i18n="cPort">Port</span></th>
            <th class="sortable" data-sort="1" aria-sort="none" data-i18n-title="sName" title="the vhost name">
              <span data-i18n="cName">Name</span></th>
            <th class="sortable" data-sort="7" aria-sort="none" data-i18n-title="sLogin" title="a password stands in front">
              <span data-i18n="cLogin">Login</span></th>
            <th class="sortable" data-sort="4" aria-sort="none" data-i18n-title="sAddr" title="what you type in a browser">
              <span data-i18n="cAddr">Address</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="proxies-body"></tbody>
      </table>

      <!-- Previews. Read-only here: they belong to their row, and the row's
           edit drawer is what adds or removes one. The explainer describes the
           table, so an empty list gets one line rather than a paragraph about
           nothing. -->
      <h4 style="margin:1.6rem 0 .3rem">LAN previews</h4>
      <?php if (!$previews): ?>
        <p class="note">No previews. Add one from a row&rsquo;s edit drawer.</p>
      <?php else: ?>
        <p class="note" style="margin:0 0 .5rem">
          One row published on a plain port, no name and no certificate. A row that asks for a login keeps it,
          reachable from this subnet only. Add or remove one in the row&rsquo;s edit drawer.
        </p>
        <table>
          <thead>
            <tr><th>Port</th><th>Row</th><th>Environment</th><th>Address</th></tr>
          </thead>
          <tbody>
            <?php foreach ($previews as $p):
              $host = strtok((string) ($_SERVER['HTTP_HOST'] ?? ''), ':');
              $url  = 'http://' . $host . ':' . $p['port'] . '/'; ?>
              <tr>
                <td><?= (int) $p['port'] ?></td>
                <td><?= htmlspecialchars($p['row']) ?></td>
                <td><?= htmlspecialchars($p['env']) ?></td>
                <td>
                  <a class="addr" href="<?= htmlspecialchars($url) ?>" target="_blank" rel="noopener"><?= htmlspecialchars($url) ?></a>
                  <?php if ($p['blocked']): ?>
                    <span class="lock" title="the same login as the site stands in front of this port">&#128274;</span>
                  <?php endif; ?>
                </td>
              </tr>
            <?php endforeach; ?>
          </tbody>
        </table>
      <?php endif; ?>
    </div>

    <div class="mailbox" style="display:none" data-pane="mailboxes">
      <!-- Mailboxes get the same Requests view as Applications and Websites.
           the owner, 2026-09-11. Item 106 files a request the moment somebody goes
           past their mailbox allowance, and until now reqKind() sent it to the
           Websites table, where nobody looking after mail would find it. -->
      <div class="sub-tabs" data-subtabs="mailboxes">
        <button type="button" data-subview="serving" aria-pressed="true"
                data-i18n="vServing">Serving</button>
        <button type="button" data-subview="requests" aria-pressed="false"
                hidden><span data-i18n="vRequests">Requests</span><span class="bell" data-reqcount hidden></span></button>
      </div>

      <div style="overflow-x:auto" data-subview-of="mailboxes" data-subview="serving">
      <label class="note" style="display:block;margin-bottom:.5rem">
        <span data-i18n="filterDomain">Domain</span>
        <select id="mail-domain-filter" style="font:inherit;margin-left:.4rem"></select>
      </label>
      <table id="mail-table" data-table="mailboxes">
        <thead>
          <tr>
            <th class="state-col"></th>
            <th class="sortable local" data-sort="1" aria-sort="none" data-i18n-title="sMailAddr" title="the part before the @">
              <span data-i18n="cMailAddr">Address</span></th>
            <th class="at-col"></th>
            <th class="sortable" data-sort="4" aria-sort="ascending" data-i18n-title="sDomain" title="the part after the @">
              <span data-i18n="cDomain">Domain</span></th>
            <th data-i18n-title="sOwner" title="who owns the domain, and so the mailbox">
              <span data-i18n="cOwner">Owner</span></th>
            <th data-i18n-title="sStore" title="where the messages sit on disk">
              <span data-i18n="cStore">Store</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="mail-body"></tbody>
      </table>
      </div>

      <div style="overflow-x:auto;display:none" data-subview-of="mailboxes" data-subview="requests">
      <table data-table="req-mailboxes">
        <thead>
          <tr>
            <th data-i18n="qWhen">Asked</th>
            <th data-i18n="qWho">By</th>
            <th data-i18n="qWhat">What</th>
            <th data-i18n="qWhy">Why</th>
            <th data-i18n="qState">State</th>
            <th data-i18n="qAnswer">Answer</th>
            <th></th>
          </tr>
        </thead>
        <tbody data-reqbody="mailboxes"></tbody>
      </table>
      </div>
    </div>

    <!-- Not rows. Each is a `PANEL = id | port | name` line, shown here because
         it holds a port and nothing else on this page would say so. The id is
         what a script looks up and is never edited; the name and the port are. -->
    <!-- One htpasswd file guards the console, every machine page with a login,
         every LAN preview and every protected row, so this is one list for all
         of them. Read from the file at load, never from the config. -->
    <div class="user" style="overflow-x:auto;display:none" data-pane="users">
      <div class="msg bad" id="users-store" hidden></div>
      <table data-table="users">
        <thead>
          <tr>
            <!-- The same three tick columns every other tab has, and one Apply.
                 the owner, 2026-09-10: three verb buttons here and tick columns
                 everywhere else meant the same job was done two ways. Written
                 out rather than built by bulk.js, because a user is not a
                 config row: nothing is staged, and Apply acts at once. -->
            <th class="ubulk-col" hidden><span class="bulk-head" data-i18n="cDelete">Delete</span>
                <input type="checkbox" class="bulk-all" data-users-all="delete"
                       data-i18n-title="selectAll" title="select all"></th>
            <th class="ubulk-col" hidden><span class="bulk-head" data-i18n="cEnable">Enable</span>
                <input type="checkbox" class="bulk-all" data-users-all="enable"
                       data-i18n-title="selectAll" title="select all"></th>
            <th class="ubulk-col" hidden><span class="bulk-head" data-i18n="cDisable">Disable</span>
                <input type="checkbox" class="bulk-all" data-users-all="disable"
                       data-i18n-title="selectAll" title="select all"></th>
            <th class="state-col"></th>
            <th data-i18n="uName">Name</th>
            <th data-i18n="uRole">Role</th>
            <th data-i18n="uEmail">E-mail</th>
            <th data-i18n="uMailboxes">Mailboxes</th>
            <th data-i18n="uUsedBy">Used by</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="users-body"></tbody>
      </table>
    </div>

    <!-- Every change made through this page, from the journal. Read only. -->
    <div class="audit" style="overflow-x:auto;display:none" data-pane="audit">
      <p class="muted" id="audit-note"></p>
      <div class="audit-tools">
        <input type="search" id="audit-search" placeholder="Search">
        <select id="audit-user"></select>
        <select id="audit-result"></select>
      </div>
      <table data-table="audit">
        <thead>
          <tr>
            <th class="audit-sort" data-col="when" aria-sort="descending"><span data-i18n="aWhen">When</span></th>
            <th class="audit-sort" data-col="user" aria-sort="none"><span data-i18n="aUser">User</span></th>
            <th class="audit-sort" data-col="action" aria-sort="none"><span data-i18n="aAction">Action</span></th>
            <th class="audit-sort" data-col="target" aria-sort="none"><span data-i18n="aTarget">Target</span></th>
            <th class="audit-sort" data-col="result" aria-sort="none"><span data-i18n="aResult">Result</span></th>
          </tr>
        </thead>
        <tbody id="audit-body"></tbody>
      </table>
      <div class="audit-pager">
        <button type="button" id="audit-prev" data-i18n="aPrev">Previous</button>
        <span id="audit-page"></span>
        <button type="button" id="audit-next" data-i18n="aNext">Next</button>
      </div>
    </div>

    <div class="panel" style="overflow-x:auto;display:none" data-pane="machine">
      <table data-table="machine">
        <thead>
          <tr>
            <th class="state-col"></th>
            <th class="sortable" data-sort="2" aria-sort="ascending" data-i18n-title="sPort" title="the door on this machine">
              <span data-i18n="cPort">Port</span></th>
            <th class="sortable" data-sort="1" aria-sort="none" data-i18n-title="sPanel" title="what answers there">
              <span data-i18n="cName">Name</span></th>
            <th data-i18n-title="sPanelServes" title="where the page comes from"
                data-i18n="cPanelServes">Serves</th>
            <th data-i18n-title="sPanelLogin" title="whether a password stands in front of it"
                data-i18n="cLogin">Login</th>
            <th></th>
          </tr>
        </thead>
        <tbody id="machine-body"></tbody>
      </table>
      <p class="note" data-i18n="machineNote">
        Reached over the local network only. Changing a port here changes the
        setting at the top of the config, and the service moves when the change
        is made live.
      </p>

    </div>

    <!-- Environments are four settings each, not one value, so they get a
         table rather than a text box. There is no rename: this project
         rebuilds rather than migrates, and renaming would rewrite every row
         plus every unit, vhost and certificate on the machine. -->
    <div class="environment" style="overflow-x:auto;display:none" data-pane="environments">
      <table data-table="envs">
        <thead>
          <tr>
            <th data-i18n-title="sEnvOn" title="whether this environment exists at all"
                data-i18n="cEnvOn">On</th>
            <th data-i18n="cEnvName">Name</th>
            <th data-i18n="cEnvBranch">Branch</th>
            <th data-i18n-title="sEnvBand" title="the thousand its ports sit in"
                data-i18n="cEnvOffset">Ports</th>
            <th data-i18n="cEnvPrefix">Host prefix</th>
            <th data-i18n-title="sEnvCpu" title="the most CPU this environment's apps get together"
                data-i18n="cEnvCpu">Cores</th>
            <th data-i18n-title="sEnvMem" title="the most memory this environment's apps get together"
                data-i18n="cEnvMem">RAM</th>
            <th data-i18n-title="sEnvAppMem" title="the most memory one app gets; it restarts at this ceiling"
                data-i18n="cEnvAppMem">Per app</th>
          </tr>
        </thead>
        <tbody id="envs-body"></tbody>
        <tfoot id="envs-foot"></tfoot>
      </table>
      <p class="note" data-i18n="envNote">
        Adding one gives every row that runs everywhere a new unit, vhost and
        certificate. Removing one leaves those behind as orphans until the
        change is made live, which is when they are cleaned up.
      </p>
    </div>

    <!-- Folders shared over the local network. Two fields, because that is the
         whole of what a share is here: everything else is identical across the
         four that already exist, and is copied from them.

         This pane has its own Save. smb.conf IS the running config, so there is
         nothing to render and nothing to drift: publishing and reloading are
         one act, and Make it live has nothing to do with it. -->
    <div class="smb" style="overflow-x:auto;display:none" data-pane="smb">
      <table data-table="smb">
        <thead>
          <tr>
            <th class="sortable" data-sort="0" aria-sort="ascending"
                data-i18n-title="sSmbName" title="what the share is called on the network">
              <span data-i18n="cName">Name</span></th>
            <th class="sortable" data-sort="1" aria-sort="none"
                data-i18n-title="sSmbPath" title="the folder on this machine">
              <span data-i18n="cSmbPath">Folder</span></th>
            <th></th>
          </tr>
        </thead>
        <tbody id="smb-body"></tbody>
      </table>
      <!-- Hidden, and pressed by the drawer and by a delete. There is no Save
           on this pane: Keep it and a confirmed delete each go to the machine
           on that press, so a button waiting for a second one had no job. -->
      <button type="submit" name="action" value="savesmb" id="btn-smb-save" hidden></button>
      <p class="note" data-i18n="smbNote">
        Reached over the local network only. Keep it and a confirmed delete each
        write smb.conf, push it and reload Samba on that press: about fifteen
        seconds, and nobody browsing a share is disconnected. Removing a share
        here never deletes the folder.
      </p>
      <input type="hidden" name="smbconf" id="smb-field">
      <input type="hidden" name="smbbase" value="<?= htmlspecialchars($smbBaseHash) ?>">
    </div>

    <!-- The port scheme and what is actually taken. Read-only, built from the
         config, and on a tab because it answers a question you ask while
         choosing a port rather than one you ask on the way past. -->
    <div class="ports" style="display:none" data-pane="ports">
    <table style="margin-top:.75rem">
      <tr><th data-i18n="bandRange">Range</th><th data-i18n="bandMeans">Means</th></tr>
      <tr><td class="port">5000&ndash;5999</td><td data-i18n="band5">skunk, the experiments, behind a login. Development itself happens on a developer's own machine and deploys nowhere.</td></tr>
      <tr><td class="port">6000&ndash;6999</td><td data-i18n="band6">test</td></tr>
      <tr><td class="port">7000&ndash;7999</td><td data-i18n="band7">accept</td></tr>
      <tr><td class="port">8000&ndash;8999</td><td data-i18n="band8">live. 8000s portfolio, 8100s progress, 8200s APIs, 8900s customer sites. A new hundred per type, never per customer.</td></tr>
      <tr><td class="port">9000&ndash;9999</td><td data-i18n="band9">free, and less empty than it looks: Prometheus and Grafana claim 9090 and 9000.</td></tr>
      <tr><td class="port">10000+</td><td><span data-i18n="band10">the machine's own panels.</span>
        <span id="band10-list"></span></td></tr>
      <tr><td class="port">11000+</td><td data-i18n="band11">the private half of a 10000 service, same last two digits. 11002 is Jenkins itself, which only 10002 may reach.</td></tr>
      <tr><td class="port">15000+</td><td data-i18n="band15">services living here temporarily, until the machine that should run them exists.</td></tr>
      <tr><td class="port">20000+</td><td data-i18n="band20">LAN previews. 8901 previews on 28901. No certificate, no login, this subnet only.</td></tr>
    </table>

    <!-- What is actually taken, as opposed to what the bands mean. Built from
         the config rather than written down, so it cannot go stale: a number
         nobody has claimed is a free number. -->
    <h3 style="font-size:.95rem;margin:1.1rem 0 .4rem" data-i18n="portsTakenH">Which ports are taken</h3>
    <p class="note" style="margin:0 0 .5rem" data-i18n="portsTakenWhy">One row per site, one column per band.</p>
    <div style="overflow-x:auto"><table id="port-map"></table></div>
    <h3 style="font-size:.95rem;margin:1.1rem 0 .4rem" data-i18n="portsPreviewH">Preview ports on the LAN</h3>
    <p class="note" style="margin:0 0 .5rem" data-i18n="portsPreviewWhy">Grey means reserved, not served.</p>
    <div style="overflow-x:auto"><table id="port-map-preview"></table></div>
    <h3 style="font-size:.95rem;margin:1.1rem 0 .4rem" data-i18n="portsFixedH">Reserved above 9999</h3>
    <div style="overflow-x:auto"><table id="port-map-fixed"></table></div>
    </div>

    <!-- Every repository the App can see, beside the row that claims it.
         Read-only, and built from the SAME ?repos answer the drawer's name
         clash check already fetches, so the tab costs nothing extra once it
         has been opened once. A repository no row claims is the case this
         exists for: it is invisible everywhere else on this page. -->
    <div class="repos" style="display:none" data-pane="repos">
      <p class="note" style="margin:.2rem 0 .7rem" data-i18n="reposWhy">
        Every repository the GitHub App can see, and which config row claims it.
      </p>
      <label class="note" style="display:inline-flex;gap:.4rem;align-items:center;margin-bottom:.7rem">
        <span data-i18n="reposOwner">Owner</span>
        <select id="repos-owner" style="width:auto"></select>
      </label>
      <!-- Space separated, every term has to appear somewhere on the row. With
           23 repositories and more arriving, picking one out of a sorted list
           is scrolling; typing two words is not. -->
      <label class="note" style="display:inline-flex;gap:.4rem;align-items:center;margin:0 0 .7rem 1rem">
        <span data-i18n="reposFind">Find</span>
        <input id="repos-search" type="search" style="width:auto" autocomplete="off"
               spellcheck="false" placeholder="progress api">
      </label>
      <div style="overflow-x:auto">
        <table data-table="repos">
          <thead>
            <tr>
              <th class="sortable" data-i18n="reposName">Repository</th>
              <th data-i18n="reposOwner">Owner</th>
              <th data-i18n="reposRow">Claimed by</th>
              <!-- The URL the row drawer asks for, with a button that copies it. -->
              <th data-i18n="reposUrl">Clone URL</th>
              <th></th>
            </tr>
          </thead>
          <tbody id="repos-body"></tbody>
        </table>
      </div>
      <p class="note" id="repos-count" style="margin-top:.6rem"></p>
    </div>

    <!-- The whole file as text, on a tab of its own rather than a fold under
         the tables. It is the escape hatch for the parts of the file no table
         covers, so it has to exist; it is not something to walk past on the
         way to a row. -->
    <div class="raw" style="display:none" data-pane="raw">
      <p class="note" id="raw-hint" data-i18n="rawHint">
        Read only. The settings the tables do not cover are edited on the
        machine; this is here so you can see what is in the file.
      </p>
      <label class="note" style="display:inline-flex;gap:.4rem;align-items:center;margin-bottom:.6rem">
        <input type="checkbox" id="raw-comments"> <span data-i18n="rawComments">Show the comments</span>
      </label>
      <!-- The file is kept in a hidden textarea because isDirty() and the
           save path compare against it. Nothing can type into it now, so
           its value never diverges from what was served. -->
      <textarea id="raw" hidden readonly spellcheck="false"><?= htmlspecialchars($myRole === 'full' ? $config : implode("\n", $lines)) ?></textarea>
      <pre id="raw-view" class="conf"></pre>
    </div>

    <p class="note" style="margin-bottom:0" id="status-line"></p>

    <input type="hidden" name="config" id="config-field">
    <input type="hidden" name="mailops" id="mailops-field">
    <!-- Which create step to rerun. Set by the button in the step list, and
         checked against a fixed list on the server: nothing from here decides
         what runs, it only picks one of five. -->
    <input type="hidden" name="rerunstep" id="rerun-step">
    <input type="hidden" name="repoops" id="repoops-field">
    <!-- The default password of a mailbox being created. It rides with the save
         because the address is not in the published config until the publish
         lands, and set_mail_password.sh will not touch an address the config
         does not claim. Written once, read once, never stored. -->
    <input type="hidden" name="mailpw" id="mailpw-field">
    <input type="hidden" name="base" value="<?= htmlspecialchars($postBase) ?>">

  </form>

  <!-- The same panel the apply dialog uses, kept running whenever the page is
       visible: what the machine is doing is worth seeing without starting a job
       first. One poll feeds both, so a second panel costs no extra request. -->
  <div class="cpu-box" data-cpu-panel style="margin-top:1rem">
    <div class="cpu-cores cpu-core-grid" role="img"></div>
    <div class="cpu-cores cpu-extra"></div>
  </div>


  <datalist id="optkey-list">
    <?php foreach ($optionKeys as $k): ?><option value="<?= htmlspecialchars($k) ?>"><?php endforeach; ?>
  </datalist>

  <div class="scrim" id="scrim"></div>
  <aside class="drawer" id="drawer" role="dialog" aria-modal="true" aria-labelledby="drawer-title">
    <button type="button" class="close" id="drawer-close" aria-label="Close">&times;</button>
    <h3 id="drawer-title">Edit row</h3>
    <div id="drawer-fields"></div>

    <!-- A preview is not a row field either: PREVIEW_ROWS holds it, because a
         fifteenth column would touch the 23 scripts that read a row. Edited
         here because it belongs to this row, written on Save with everything
         else, and published by Apply. -->
    <div id="drawer-preview" hidden>
      <h4 style="margin:1.6rem 0 .3rem">Preview port</h4>
      <div id="preview-envs"></div>
    </div>

    <!-- Not a row field either: APP_MEMORY_ROWS holds it, like PREVIEW_ROWS. -->
    <div id="drawer-appmem" hidden>
      <h4 style="margin:1.6rem 0 .3rem" data-i18n="appMemTitle">Memory</h4>
      <select id="appmem-select"></select>
      <p class="note" data-i18n="appMemNote" style="margin:.4rem 0 0">
        The most memory this app gets, in every environment it runs in. At the
        ceiling it is stopped and restarted, nothing else is touched.
      </p>
    </div>


    <!-- Mailboxes for this row's domain. These ARE rows, unlike the mail
         settings below: each ticked address is a `mailbox` line in
         hostings.conf, written on Keep this change with everything else.
         Shown here so a domain and its addresses are one screen rather than
         two tabs, which is how you forget the second one. -->
    <div id="drawer-mailboxes" hidden>
      <h4 style="margin:1.6rem 0 .3rem" data-i18n="mbxTitle">Mail for this domain</h4>
      <p class="note" id="mbx-note" style="margin:0 0 .6rem"></p>
      <div id="mbx-list" class="acl" style="flex-direction:column;gap:.35rem;align-items:stretch"></div>
      <div class="row-actions" style="margin-top:.5rem">
        <input type="text" id="mbx-new" spellcheck="false" autocomplete="off"
               style="flex:1 1 10rem" placeholder="another address">
        <button type="button" id="mbx-add" data-i18n="mbxAdd">Add</button>
      </div>
      <p class="note" id="mbx-problem" style="color:var(--bad);margin:.4rem 0 0" hidden></p>
    </div>
    <!-- The progress instance. Like the mailbox ticks above and unlike the
         fields, this is not a column on this row: ticking it WRITES AN app ROW
         on progress.<domain>, which is then an ordinary row with its own unit,
         vhost, certificate and Jenkins jobs.
         Agreed 2026-09-11, .claude/docs/progress-instance-decisions.md. A
         seventeenth field was the other design and was measured first: it
         touches 13 parser lines across 11 scripts, and every one of them ends
         in the variable that absorbs whatever follows it, which is how a
         sixteenth field re-enabled every disabled row on 2026-09-10.
         Unticking DISABLES the row and keeps it. Removing an instance for real
         is the ordinary row delete, so there is one destructive path, not two. -->
    <div id="drawer-progress" hidden>
      <h4 style="margin:1.6rem 0 .3rem" data-i18n="progTitle">Progress application</h4>
      <p class="note" id="prog-note" style="margin:0 0 .6rem"></p>
      <label class="acl" style="display:flex;gap:.5rem;align-items:center">
        <input type="checkbox" id="prog-on">
        <span data-i18n="progTick">Run a progress application on this domain</span>
      </label>
      <p class="note" id="prog-detail" style="margin:.4rem 0 0"></p>
    </div>
    <!-- Mail settings are NOT a row field. They live in a root-owned file the
         page cannot open, they never enter git, and they are written the
         moment this button is pressed rather than at Publish. Hence a section
         of its own with its own save, instead of two things behind one word. -->
    <div id="drawer-mail" hidden>
      <h4 id="mail-title" style="margin:1.6rem 0 .3rem">Mail settings</h4>
      <p class="note" id="mail-note" style="margin:0 0 .8rem"></p>
      <div data-field>
        <label for="mail-from" id="mail-from-label">Sends from</label>
        <input type="email" id="mail-from" autocomplete="off" placeholder="admin@example.com">
      </div>
      <div data-field style="margin-top:1.35rem">
        <label for="mail-to" id="mail-to-label">Alerts arrive at</label>
        <input type="email" id="mail-to" autocomplete="off" placeholder="you@example.com">
      </div>
      <p class="note" id="mail-outcome" style="margin:.6rem 0 0"></p>
      <div class="row-actions" style="margin-top:.5rem">
        <button type="button" id="mail-save">Save mail settings</button>
      </div>
    </div>
    <!-- The mailbox's DEFAULT password. Not a row field either: it becomes a
         hash in /etc/dovecot/users, never enters git, and is written the moment
         this button is pressed. The owner changes it themselves in Roundcube,
         which writes the same file, so nothing here has to know the current
         one. -->
    <div id="drawer-mailpw" hidden>
      <h4 id="mailpw-title" style="margin:1.6rem 0 .3rem">Password</h4>
      <p class="note" id="mailpw-note" style="margin:0 0 .8rem"></p>
      <div data-field>
        <label for="mailpw-value" id="mailpw-label">Default password</label>
        <input type="password" id="mailpw-value" autocomplete="new-password" spellcheck="false">
      </div>
      <p class="note" id="mailpw-outcome" style="margin:.6rem 0 0"></p>
      <!-- The "Set the password" button was here. Keep this change carries the
           password for an existing mailbox as well as a new one now, so a
           second button for one field is gone. Kept hidden rather than deleted
           because drawer.js addresses it by id. -->
      <button type="button" id="mailpw-save" hidden></button>
    </div>

    <p id="drawer-outcome"></p>
    <div class="row-actions" style="margin-top:.5rem">
      <button type="button" class="primary" id="drawer-save" data-i18n="keep">Keep this change</button>
      <button type="button" id="drawer-cancel" data-i18n="cancel">Cancel</button>
    </div>
    <p class="note" style="margin:0" data-i18n="drawerNote">
      Kept in the browser until you save.
    </p>
  </aside>

  <!-- A share is two fields here, so it gets its own small drawer rather than
       joining the row drawer, which is built from the hostings.conf field list
       and knows nothing about Samba. -->
  <aside class="drawer" id="smb-drawer" role="dialog" aria-modal="true" aria-labelledby="smb-drawer-title">
    <button type="button" class="icon-btn" id="smb-drawer-close" aria-label="Close"
            style="align-self:flex-end">&times;</button>
    <h3 id="smb-drawer-title" data-i18n="smbDrawerAdd">Add a shared folder</h3>
    <div class="drawer-fields">
      <label class="field">
        <span class="label" data-i18n="smbFName">Share name</span>
        <input type="text" id="smb-name" spellcheck="false" autocomplete="off">
      </label>
      <label class="field">
        <span class="label" data-i18n="smbFPath">Folder on this machine</span>
        <input type="text" id="smb-path" spellcheck="false" autocomplete="off"
               placeholder="/srv/something/">
      </label>
      <!-- The picker. Typing a path still works and is not second class: this
           is here because nobody remembers whether it is /srv/foo or
           /srv/foo/bar, not because typing is wrong. -->
      <div class="picker" id="smb-picker">
        <div class="picker-head">
          <button type="button" class="icon-btn" id="smb-pick-up"
                  data-i18n-title="smbPickUp" title="Up one folder">&uarr;</button>
          <span class="picker-here" id="smb-pick-here"></span>
        </div>
        <ul class="picker-list" id="smb-pick-list"></ul>
      </div>
      <!-- The folder's own permissions, which are not part of smb.conf at all.
           A share whose folder the group cannot enter serves an empty list, and
           that is the failure this exists to prevent: on 2026-08-26 a share was
           added to a folder nobody could read and looked like a broken share.

           Group only. "other" is not on offer here, and a folder owned by a
           system account is refused outright: Dovecot's mail store also holds
           the DKIM signing keys. -->
      <div class="field">
        <span class="label" data-i18n="smbAccess">What the share may do with the folder</span>
        <div class="acl" id="smb-acl">
          <label><input type="checkbox" id="acl-r"> <span data-i18n="aclRead">Read</span></label>
          <label><input type="checkbox" id="acl-w"> <span data-i18n="aclWrite">Write</span></label>
          <label><input type="checkbox" id="acl-x"> <span data-i18n="aclExec">Enter</span></label>
        </div>
        <label class="acl-deep"><input type="checkbox" id="acl-deep">
          <span data-i18n="aclDeep">and everything inside it</span></label>
        <p class="note" id="smb-acl-state" style="margin:0"></p>
        <p class="note" id="smb-acl-protected" style="color:var(--warn);margin:0" hidden></p>
      </div>
    </div>
    <p class="note" id="smb-drawer-problem" style="color:var(--bad);margin:0" hidden></p>
    <p class="note" id="smb-drawer-preview" style="margin:0"></p>
    <p class="note" id="smb-rename-note" style="margin:0" data-i18n="smbRenameNote" hidden>
      Renaming changes nothing on disk, but anyone with this share mapped as a
      drive loses it and has to map the new name.
    </p>
    <div class="row-actions" style="margin-top:.5rem">
      <button type="button" class="primary" id="smb-drawer-save" data-i18n="keepBrowser">Keep it</button>
      <button type="button" id="smb-drawer-cancel" data-i18n="cancel">Cancel</button>
    </div>
    <p class="note" style="margin:0" data-i18n="drawerNote">
      Kept in the browser until you save.
    </p>
  </aside>

  <!-- What Apply would do, shown at the moment of applying rather than in a
       card that is read at some other time. The list is the last check's, and
       its age is on the dialog, because a summary of a stale check is the one
       thing worse than no summary. -->
  <!-- Certificate actions post here, separate from the config form: they change
       the machine, not the file being edited. -->
  <form method="post" id="cert-form" hidden>
    <input type="hidden" name="action" value="">
    <input type="hidden" name="host" value="">
  </form>

  <!-- Start, stop and restart. Its own form, like cert-form: it acts on the
       machine rather than on the config being edited, so it must not carry
       the table along with it. -->
  <form method="post" id="svc-form" hidden>
    <input type="hidden" name="action" value="service">
    <input type="hidden" name="row" value="">
    <input type="hidden" name="env" value="">
    <input type="hidden" name="verb" value="">
  </form>

  <!-- Same arrangement as cert-form, and for the same reason: this writes a
       file on the machine, not the config being edited, so it must not ride
       the rows form and its publish flow. -->
  <form method="post" id="mail-form" hidden>
    <input type="hidden" name="action" value="savemail">
    <input type="hidden" name="row" value="">
    <input type="hidden" name="mail_from" value="">
    <input type="hidden" name="mail_to" value="">
  </form>

  <!-- Its own form so the password is the only interesting thing it posts, and
       so it never rides the rows form into a publish. The field is filled from
       the drawer at submit time and cleared straight afterwards. -->
  <form method="post" id="mailpw-form" hidden>
    <input type="hidden" name="action" value="setmailpw">
    <input type="hidden" name="mail_local" value="">
    <input type="hidden" name="mail_domain" value="">
    <input type="hidden" name="mail_pw" value="">
  </form>

  <!-- STARTING AND STOPPING, WATCHED. A service action used to be a form post:
       the page went away and came back with one sentence, and four
       environments were four page loads with nothing in between. This shows
       what is being done to what, one line per unit, with the machine's own
       graphs beside it, which is the same shape the apply dialog uses and the
       same [data-cpu-panel] that drawCpu already paints. -->
  <div class="scrim" id="svc-scrim"></div>
  <aside class="dialog" id="svc-dialog" role="dialog" aria-modal="true"
         aria-labelledby="svc-dialog-title">
    <h3 id="svc-dialog-title">Services</h3>
    <p class="note" id="svc-dialog-what"></p>

    <ul class="svc-list" id="svc-dialog-list"></ul>

    <div class="cpu-box" data-cpu-panel>
      <div class="cpu-cores cpu-core-grid" role="img" aria-label="Machine CPU"></div>
      <div class="cpu-cores cpu-extra"></div>
    </div>

    <p class="msg" id="svc-dialog-msg" hidden></p>

    <div class="row-actions" style="margin-top:.5rem">
      <button type="button" class="cta" id="svc-dialog-close" disabled>Close</button>
    </div>
  </aside>

  <!-- A user, added or given a new password. Deliberately two fields: a name
       and a password is the whole of what an htpasswd account is. -->
  <div class="scrim" id="user-scrim"></div>
  <aside class="dialog user" id="user-drawer" role="dialog" aria-modal="true"
         aria-labelledby="user-drawer-title">
    <h3 id="user-drawer-title" data-i18n="uAdd">Add a user</h3>
    <!-- ITS OWN FORM. The owner, 2026-09-18: Enter, or a password manager filling
         name and password and submitting, sent the page's config form instead,
         and started an apply. Submitting here adds the user. -->
    <form id="user-form" style="display:contents" novalidate>
    <label class="note" style="display:block;margin:.6rem 0 .2rem"
           for="user-name" data-i18n="uName">Name</label>
    <input id="user-name" type="text" autocomplete="off" spellcheck="false"
           placeholder="jane">
    <p class="note" style="margin:.2rem 0 .6rem" data-i18n="uNameHint">Letters, digits, dot, underscore, hyphen.</p>
    <label class="note" style="display:block;margin:.4rem 0 .2rem"
           for="user-pw" data-i18n="uPassword">Password</label>
    <input id="user-pw" type="password" autocomplete="new-password">
    <p class="note" style="margin:.2rem 0 .6rem" id="user-pw-hint"></p>
    <label class="note" style="display:block;margin:.4rem 0 .2rem"
           for="user-email" data-i18n="uEmail">E-mail</label>
    <input id="user-email" type="email" autocomplete="off" spellcheck="false" list="user-email-list"
           placeholder="billing@customer.example">
    <datalist id="user-email-list"></datalist>
    <p class="note" style="margin:.2rem 0 .6rem" data-i18n="uEmailHint">Where a request or a decline is sent. Any address that already exists; nothing is stored here.</p>
    <label class="note" style="display:block;margin:.4rem 0 .2rem"
           for="user-role" data-i18n="uRole">Role</label>
    <select id="user-role">
      <option value="none" data-i18n="uRoleNone">No access</option>
      <option value="admin" data-i18n="uRoleAdmin">Admin</option>
      <option value="full" data-i18n="uRoleFull">Full access admin</option>
    </select>
    <p class="note" style="margin:.2rem 0 .6rem" data-i18n="uRoleHint">No access means the account cannot reach this page at all, which is what a new account is. Admin sees Applications, Websites and Mailboxes and only the rows assigned to them. Full access admin is everything.</p>
    <label class="note" style="display:block;margin:.4rem 0 .2rem"
           for="user-boxes" data-i18n="uMailboxes">Mailboxes</label>
    <select id="user-boxes"></select>
    <p class="note" style="margin:.2rem 0 .6rem" data-i18n="uMailboxesHint">How many mail addresses this person may create for themselves. Empty means the default.</p>
    <p class="msg" id="user-msg" hidden></p>
    <div class="row-actions" style="margin-top:.7rem">
      <button type="submit" class="cta" id="user-save" data-i18n="uSave">Save</button>
      <button type="button" class="icon-btn text-btn" id="user-cancel" data-i18n="bCancel">Cancel</button>
    </div>
    </form>
  </aside>

  <!-- A REQUEST IS READ HERE, NOT ON ITS ROW. The owner, 2026-09-11: "from the row
       I am not getting enough info". A row can hold fifteen fields and a table
       cell can carry three of them, so answering from the row meant answering
       without having seen what was asked for.

       The reason is a TEXTAREA and not a prompt(): a decline is the one answer
       somebody has to write a sentence into, and a browser prompt gives one
       line with no wrapping and no way to correct it comfortably. -->
  <div class="scrim" id="req-scrim"></div>
  <aside class="dialog" id="req-drawer" role="dialog" aria-modal="true"
         aria-labelledby="req-drawer-title">
    <h3 id="req-drawer-title" data-i18n="qReview">Review this request</h3>
    <div id="req-meta"></div>
    <p class="note" style="margin:1.1rem 0 .3rem" data-i18n="qAsked">What was asked for</p>
    <!-- Space either side, so the values are an island rather than the middle
         of a paragraph. The owner, 2026-09-11. -->
    <div style="overflow-x:auto;margin:0 0 1.2rem"><table id="req-fields"
         style="border-spacing:0 .25rem"></table></div>
    <div id="req-answer-box">
      <label class="note" style="display:block;margin:.8rem 0 .2rem"
             for="req-reason" data-i18n="qReason">Your reason</label>
      <!-- Two rows, and it grows if somebody writes more. The owner, 2026-09-11:
           at three fixed rows the reason box was taller than the request it is
           an answer to, which reads as the wrong way round. -->
      <textarea id="req-reason" rows="2" spellcheck="false"
                style="width:100%;box-sizing:border-box;resize:vertical"></textarea>
      <p class="note" style="margin:.2rem 0 .6rem" data-i18n="qReasonHint">The requester reads this, whichever button you press. A decline needs one.</p>
    </div>
    <p class="msg" id="req-msg" hidden></p>
    <div class="row-actions" style="margin-top:.7rem" id="req-buttons"></div>
  </aside>

  <!-- One environment's deploy, re-run and tailed live. Same shape as the
       service dialog above it, with the Jenkins console in place of the list. -->
  <div class="scrim" id="redeploy-scrim"></div>
  <aside class="dialog" id="redeploy-dialog" role="dialog" aria-modal="true"
         aria-labelledby="redeploy-title">
    <h3 id="redeploy-title">Re-run the deploy</h3>
    <p class="note" id="redeploy-what"></p>
    <!-- Labelled facts rather than three sentences. The owner, 2026-09-10: the
         prose said "Deployed 0146693, the tip of live" and he could not tell
         what it was claiming. A label per line answers what each number IS. -->
    <!-- Side by side, 2026-09-10: stacked, the two blocks pushed Jenkins' own
         output down to about two and a half lines, which is the one thing in
         this dialog you actually read while a build runs. -->
    <div class="redeploy-top">
      <dl class="facts" id="redeploy-facts"></dl>
      <ol class="stage-strip" id="redeploy-stages"></ol>
    </div>

    <!-- The machine's own CPU, disk and temperature while the build runs. The
         apply dialog has carried these since 2026-08-19 and this one never did,
         so watching a deploy told you nothing about what the machine was doing.
         drawCpu() paints every [data-cpu-panel] on the page, so it needs no
         driver of its own. The owner, 2026-09-10. -->
    <div class="cpu-box" data-cpu-panel id="redeploy-cpu" hidden>
      <div class="cpu-cores cpu-core-grid" role="img"></div>
      <div class="cpu-cores cpu-extra"></div>
    </div>

    <details id="redeploy-history">
      <summary data-i18n="redeployHistoryH">The last 20 runs</summary>
      <table id="redeploy-history-table"></table>
    </details>
    <!-- Both are foldable, and which one starts open depends on why the dialog
         was opened. The owner, 2026-09-10: looking at a row, you want its history
         and not a console; re-running one, you want the console and not the
         history. -->
    <details id="redeploy-log-box">
      <summary data-i18n="jobLogH">The last of Jenkins' console output</summary>
      <pre class="out" id="redeploy-log" style="min-height:12rem;max-height:22rem;overflow:auto"></pre>
    </details>
    <p class="msg" id="redeploy-msg" hidden></p>
    <div class="row-actions" style="margin-top:.5rem">
      <button type="button" class="cta danger" id="redeploy-cancel" hidden>Cancel the build</button>
      <button type="button" class="cta" id="redeploy-close" disabled>Close</button>
    </div>
  </aside>

  <div class="scrim" id="apply-scrim"></div>
  <aside class="dialog" id="apply-dialog" role="dialog" aria-modal="true" aria-labelledby="apply-title">
    <h3 id="apply-title">Make it live</h3>
    <p class="note" id="apply-age"></p>
    <div id="apply-summary"></div>

    <!-- What the dialog becomes once the job is handed over. It replaces the
         summary rather than closing, so the thing being watched is still on
         screen when the answer arrives. -->
    <div id="apply-progress" hidden>
      <p class="msg running" style="margin:0">
        <span class="spin" aria-hidden="true"></span><span id="apply-progress-text"></span>
      </p>

      <!-- The graphs, above Jenkins' output and pinned. They are the reason the
           dialog is worth looking at during a wait, and they were below a
           scrolling log, so they were only ever found by scrolling. This is
           the machine's own CPU, not the job's progress: a bar moving on a
           timer would be a lie about how far along something is. -->
      <div class="cpu-box" data-cpu-panel>
        <!-- Both grids are filled by drawCpu. The core count comes from the
             machine, so it is not known until the first sample answers. -->
        <div class="cpu-cores cpu-core-grid" role="img" aria-label="Machine CPU"></div>
        <div class="cpu-cores cpu-extra"></div>
      </div>

      <!-- Jenkins' own output, tailed while the job runs. It is the only thing
           on this dialog that says what the machine is actually doing, as
           opposed to that it is busy. -->
      <div id="apply-log-box" hidden>
        <p class="note" style="margin:.2rem 0" data-i18n="jobLogH">The last of Jenkins' console output</p>
        <pre class="out" id="apply-log"></pre>
      </div>
    </div>

    <!-- The card is gone, so this is the only way left to the check's own
         output. Folded, because the summary above is what gets read. Below the
         progress block, so during a job it sits under Jenkins' output rather
         than above the spinner. -->
    <?php if ($reportBody !== ''): ?>
    <details>
      <summary class="note" style="cursor:pointer" data-i18n="fullLog">The whole check, as the script printed it</summary>
      <pre class="out"><?= htmlspecialchars($reportBody) ?></pre>
    </details>
    <?php endif; ?>

    <div class="row-actions" style="margin-top:.5rem" id="apply-actions">
      <button type="button" class="cta action-btn action-apply" id="apply-go">Apply now</button>
      <button type="button" class="action-btn action-check" id="apply-recheck">Check again first</button>
      <button type="button" id="apply-cancel">Cancel</button>
    </div>

    <div class="row-actions" style="margin-top:.5rem" id="apply-running-actions" hidden>
      <button type="button" class="cta" id="apply-close" data-i18n="bClose" hidden>Close</button>
      <button type="button" id="apply-hide" data-i18n="bHide">Hide</button>
    </div>
  </aside>

  <!-- Every button on this page shells out to a script that takes seconds. A
       page that looks unchanged for eight seconds gets clicked again. -->
  <div class="busy" id="busy" role="status" aria-live="polite">
    <div class="busy-box">
      <div class="spinner"></div>
      <p class="busy-text" id="busy-text"></p>
      <p class="note" id="busy-note"></p>
    </div>
  </div>

  <!-- The publisher refused, so the edit that was just made is gone. That is
       worth stopping for: on 2026-08-31 a stale page was refused correctly, the
       page said so in a line among the others, and nobody read it.
       One button, and it is the recovery rather than an acknowledgement: the
       question is never "did you see this", it is "what now". -->
<?php if ($publishRefused): ?>
  <div class="scrim open" id="refused-scrim"></div>
  <aside class="dialog open" id="refused-dialog" role="alertdialog" aria-modal="true" aria-labelledby="refused-title">
<?php if ($failureChangedNothing): ?>
    <h3 id="refused-title" data-i18n="refusedTitle">Your change was not saved</h3>
    <p data-i18n="refusedBody">Nothing on the machine changed, and the version on the branch is untouched. The reason is below. Reload to get the current config, then make the edit again.</p>
<?php else: ?>
    <!-- NOT a refusal: the publish went through and something after it did not,
         so part of this change is live and part is not. Saying "nothing
         changed" here would be the gaslighting the whole page exists to avoid. -->
    <h3 id="refused-title" data-i18n="failedTitle">Part of this change did not go through</h3>
    <p data-i18n="failedBody">The config was saved, and something after it failed. What is below is the machine's own words for it. Read it before pressing anything else: some of this change is live and some is not.</p>
<?php endif; ?>
<?php if ($failedAction !== ''): ?>
    <p class="note"><?= htmlspecialchars($failedAction) ?><?= $failedWhen !== '' ? ' &middot; ' . htmlspecialchars($failedWhen) : '' ?></p>
<?php endif; ?>
<?php /* A create that stopped halfway: which step, rather than a log to read. */ ?>
<?php if ($failedAction === 'provision_create' && $createSteps): ?>
    <?= render_create_steps($createSteps, $createRow) ?>
<?php endif; ?>
<?php /* And the same for a save, which is four jobs in one press. */ ?>
<?php if ($failedSteps): ?>
    <?= render_create_steps($failedSteps, '', '') ?>
<?php endif; ?>
    <p class="note"><?= htmlspecialchars($message) ?></p>
    <pre class="out" style="max-height:14rem;overflow:auto;white-space:pre-wrap"><?= htmlspecialchars($output) ?></pre>
    <div class="dialog-actions">
      <button type="button" class="cta" id="refused-reload" data-i18n="refusedReload">Reload and try again</button>
    </div>
  </aside>
<?php endif; ?>

  <!-- Deleting a mailbox is two different acts, so it is two buttons, not one
       confirm. The choice is recorded on the row and carried out on the next
       Keep this change, beside the config line leaving. contact@ never reaches
       here: it is the forward target and its trash button is disabled. -->
  <!-- Deleting a row that owns a repository. Keep is the default and the only
       reversible answer; the other two act on GitHub the moment Keep this
       change runs, beside the config line leaving. -->
  <div class="scrim" id="repodel-scrim"></div>
  <div class="scrim" id="svclog-scrim"></div>
  <div class="scrim" id="mailcfg-scrim"></div>

  <!-- What to type into a mail app. READ ONLY: nothing here changes anything,
       and every value is read off Dovecot and Postfix rather than out of the
       config, so a port shown is a port that is listening. -->
  <aside class="dialog" id="mailcfg-dialog" role="dialog" aria-modal="true" aria-labelledby="mailcfg-title">
    <h3 id="mailcfg-title" data-i18n="mcTitle">Set this address up in a mail app</h3>
    <p id="mailcfg-addr" style="margin:.2rem 0 .8rem;font-family:var(--mono,monospace)"></p>
    <p class="note" id="mailcfg-intro" data-i18n="mcIntro" style="margin:0 0 1rem"></p>
    <p class="note" id="mailcfg-warn" hidden style="margin:0 0 1rem;color:var(--warn,#b45309)"></p>
    <div id="mailcfg-body"></div>
    <div class="dialog-actions" style="margin-top:1rem">
      <button type="button" class="btn" id="mailcfg-copy" data-i18n="mcCopy">Copy these settings</button>
      <button type="button" class="btn" id="mailcfg-close" data-i18n="mcClose">Close</button>
    </div>
  </aside>

  <!-- One service's journal. READ ONLY: there is no control on it that changes
       anything, and the endpoint behind it only ever runs journalctl. -->
  <aside class="dialog" id="svclog-dialog" role="dialog" aria-modal="true" aria-labelledby="svclog-title">
    <h3 id="svclog-title" data-i18n="logTitle">What this service last said</h3>
    <p id="svclog-unit" style="margin:.2rem 0 .8rem;font-family:var(--mono,monospace)"></p>
    <pre class="out" id="svclog-out" style="max-height:55vh;overflow:auto"></pre>
    <div class="dialog-actions" style="margin-top:1rem">
      <button type="button" class="btn" id="svclog-refresh" data-i18n="logRefresh">Read it again</button>
      <button type="button" class="btn" id="svclog-close" data-i18n="logClose">Close</button>
    </div>
  </aside>

  <aside class="dialog" id="repodel-dialog" role="dialog" aria-modal="true" aria-labelledby="repodel-title">
    <h3 id="repodel-title" data-i18n="repoDelTitle">Delete this row. What about its repository?</h3>
    <p id="repodel-slug" style="margin:.2rem 0 1rem;font-family:var(--mono,monospace)"></p>

    <div class="mbxdel-opts" role="radiogroup" aria-labelledby="repodel-title">
      <button type="button" class="mbxdel-opt keep" role="radio" aria-checked="true" data-repoop="keep">
        <strong data-i18n="repoDelKeepH">Leave it alone</strong>
        <span data-i18n="repoDelKeepB">The repository and its Jenkins jobs stay. Remove them by hand if you meant to.</span>
      </button>
      <button type="button" class="mbxdel-opt keep" role="radio" aria-checked="false" data-repoop="archive">
        <strong data-i18n="repoDelArchiveH">Archive it</strong>
        <span data-i18n="repoDelArchiveB">Read only on GitHub, out of the way, and it can be unarchived later.</span>
      </button>
      <button type="button" class="mbxdel-opt purge" role="radio" aria-checked="false" data-repoop="delete">
        <strong data-i18n="repoDelDeleteH">Delete it</strong>
        <span data-i18n="repoDelDeleteB">The repository and every branch in it are gone. Nothing is recoverable.</span>
      </button>
    </div>

    <!-- One block per mailbox on this row's domain, because they are separate
         rows and deleting the site leaves them owning nothing. Built by
         openRowDelete(). -->
    <div id="repodel-mail" hidden style="margin-top:1.1rem">
      <h4 style="margin:0 0 .5rem" data-i18n="repoDelMailH">Mailboxes on this domain</h4>
      <div id="repodel-mail-list"></div>
    </div>

    <!-- The progress instance, asked for the same reason the mailboxes are:
         it is a SEPARATE row, so deleting the website left it running on its
         own port with nothing on screen connecting it to the customer who had
         just been removed. Found 2026-09-11 by reading the delete path after
         the tick was built, and confirmed by clicking.
         Switching it off is the default rather than deleting it, which is the
         same call the owner made for the tick itself: a mis-click must not
         destroy a customer's data. Built by openRowDelete(). -->
    <div id="repodel-prog" hidden style="margin-top:1.1rem">
      <h4 style="margin:0 0 .5rem" data-i18n="repoDelProgH">Its progress application</h4>
      <p class="note" id="repodel-prog-name" style="margin:0 0 .5rem;font-family:var(--mono,monospace)"></p>
      <div role="radiogroup" aria-labelledby="repodel-prog-name">
        <label style="display:flex;gap:.5rem;align-items:flex-start;margin-bottom:.35rem">
          <input type="radio" name="progdel" value="disable" checked>
          <span><strong data-i18n="repoDelProgOff">Switch it off, keep it</strong>
            <span class="note" data-i18n="repoDelProgOffNote">The application stops. Its row, its folder, its data and its certificate stay.</span></span>
        </label>
        <label style="display:flex;gap:.5rem;align-items:flex-start;margin-bottom:.35rem">
          <input type="radio" name="progdel" value="delete">
          <span><strong data-i18n="repoDelProgDel">Delete it too</strong>
            <span class="note" data-i18n="repoDelProgDelNote">The row goes with the website. Its unit and vhost are removed by the apply.</span></span>
        </label>
        <label style="display:flex;gap:.5rem;align-items:flex-start">
          <input type="radio" name="progdel" value="keep">
          <span><strong data-i18n="repoDelProgKeep">Leave it running</strong>
            <span class="note" data-i18n="repoDelProgKeepNote">It keeps serving on its own address, with no website beside it.</span></span>
        </label>
      </div>
    </div>

    <div class="row-actions" style="margin-top:.9rem">
      <button type="button" class="primary" id="repodel-go" data-i18n="bProceed">Proceed</button>
      <button type="button" id="repodel-cancel" data-i18n="bCancel">Cancel</button>
    </div>
  </aside>

  <div class="scrim" id="mbxdel-scrim"></div>
  <aside class="dialog" id="mbxdel-dialog" role="dialog" aria-modal="true" aria-labelledby="mbxdel-title">
    <h3 id="mbxdel-title">Delete this mailbox?</h3>
    <p id="mbxdel-addr" style="margin:.2rem 0 1rem;font-family:var(--mono,monospace)"></p>

    <div class="mbxdel-opts" role="radiogroup" aria-labelledby="mbxdel-title">
      <button type="button" class="mbxdel-opt keep" id="mbxdel-forward" role="radio" aria-checked="false" data-op="forward">
        <strong data-i18n="mbxDelKeepH">Remove, keep the files</strong>
        <span data-i18n="mbxDelKeepB">The maildir stays on disk and new mail is forwarded to contact@. Re-creating the address brings every message back.</span>
      </button>
      <!-- The same soft delete for an address that cannot forward, which in
           practice is contact@: it IS the forward target. Only one of these two
           is ever shown. -->
      <button type="button" class="mbxdel-opt keep" id="mbxdel-retire" role="radio" aria-checked="false" data-op="retire" hidden>
        <strong data-i18n="mbxDelRetireH">Remove, keep the files</strong>
        <span data-i18n="mbxDelRetireB">The maildir stays on disk untouched. Nothing is forwarded, because this is the address others forward to. Re-creating it brings every message back.</span>
      </button>
      <button type="button" class="mbxdel-opt purge" id="mbxdel-purge" role="radio" aria-checked="false" data-op="purge">
        <strong data-i18n="mbxDelPurgeH">Delete everything</strong>
        <span data-i18n="mbxDelPurgeB">The maildir, the account and the map entry are all removed. Nothing is recoverable.</span>
      </button>
    </div>

    <div class="row-actions" style="margin-top:.9rem">
      <button type="button" class="primary" id="mbxdel-go" data-i18n="bProceed" disabled>Proceed</button>
      <button type="button" id="mbxdel-cancel" data-i18n="bCancel">Cancel</button>
    </div>
  </aside>

</div>

<script>
// Everything PHP puts into JavaScript is here and nowhere else. The rest of
// the script is plain .js files beside this one, which node can parse
// directly rather than through a tag-stripping filter.
// The model. Rows carry the line they came from, so an edit rewrites one line
// and every comment in the file survives untouched.
const LINES    = <?= json_encode($lines, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const FIELDS   = <?= json_encode(FIELDS, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const WIDTHS   = <?= json_encode($widths) ?>;
const BASE     = <?= json_encode($baseDomain) ?>;
const TABS_ON  = <?= json_encode(tabs_on($config)) ?>;
const HAS_JENKINS = <?= json_encode(is_dir('/var/lib/jenkins')) ?>;
// The progress-instance preset (drawer.js). Either empty hides its tick.
const PROGRESS_REPO = <?= json_encode((string) conf_val($config, 'PROGRESS_REPO')) ?>;
const PROGRESS_DLL  = <?= json_encode((string) conf_val($config, 'PROGRESS_DLL')) ?>;
// Where a person looks a domain up themselves. drawer.js has referred to this
// since the domain request was built and nothing defined it, so it was silently
// falling back to the same string hardcoded there. Item 106, 2026-09-11.
const DOMAIN_CHECK_URL = <?= json_encode(conf_val($config, 'DOMAIN_CHECK_URL')
    ?: 'https://domainr.com/%s') ?>;
// Where it is registered, asked of the DNS service rather than configured, so
// a provider swap moves the link with it. Empty hides the link.
<?php
$registerUrl = [];
exec('DNS_OPTIONAL=1 SITES_CONF=' . escapeshellarg(CONF) . ' bash -c '
    . escapeshellarg('. "$1" >/dev/null 2>&1 && [ "$DNS_READY" = 1 ] && dns_register_url')
    . ' _ ' . escapeshellarg(DNSIFACE) . ' 2>/dev/null', $registerUrl);
?>
const DOMAIN_REGISTER_URL = <?= json_encode(trim(implode('', $registerUrl))) ?>;
// Not const: the Machine tab can add and remove environments, and everything
// that reads ENVS has to see the change without the page being reloaded.
let ENVS       = <?= json_encode($envList) ?>;
let PREFIX     = <?= json_encode($hostPrefix) ?>;
let OFFSET     = <?= json_encode($portOffset) ?>;
let ENVBRANCH  = <?= json_encode($envBranch) ?>;
let SUFFIX     = <?= json_encode($unitSuffix) ?>;
let ENVLIM     = <?= json_encode($envLimits ?: new stdClass()) ?>;
const APPMEM   = <?= json_encode($appMemSpec ?: new stdClass()) ?>;
const MACHINE  = { cores: <?= (int) $machineCores ?>, memMB: <?= (int) $machineMemMB ?> };
// A variable, not a constant: the page re-reads this file every few seconds now, so a
// now, so a unit coming up is visible without a reload. See readStatus().
let STATUS   = <?= json_encode($status, JSON_UNESCAPED_SLASHES) ?>;
// What is listening, with the process holding each port. The machine-page
// drawer offers these when a page is being pointed at a service, so a port is
// chosen from what is there rather than remembered. Empty when the status file
// is older than this field, which is a normal state right after a deploy.
const LISTENERS = (STATUS && Array.isArray(STATUS.listeners)) ? STATUS.listeners : [];
// PREVIEW_ROWS, as row -> environment -> auto or a port. Edited by the drawer
// and written back to that one line on save.
const PREVIEWS = <?= json_encode($previewSpec ?: new stdClass(), JSON_UNESCAPED_SLASHES) ?>;
const PREVBASE = <?= (int) $previewBase ?>;
const ENVGONE  = new Set();
const STAGED   = <?= $staged !== '' ? 'true' : 'false' ?>;
// The fields as the file has them, so an edit can be shown as a difference.
const ROWWAS   = <?= json_encode(array_map(fn($r) => $r['f'], $rows), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
// What the file held when the page loaded, so a save only rewrites the settings
// that actually changed and leaves the others on their aligned lines.
const ENVWAS   = JSON.parse(JSON.stringify({ b: ENVBRANCH, p: PREFIX, o: OFFSET, l: ENVLIM }));
const PANELS   = <?= json_encode($services, JSON_UNESCAPED_SLASHES) ?>;
// Who is signed in, and what they may do: 'full' or 'admin'. The page hides
// what a role may not use, and THAT IS NOT THE CHECK: every script behind a
// button decides for itself. A hidden button is a courtesy, never a control.
const ME       = <?= json_encode($me) ?>;
const MYROLE   = <?= json_encode($myRole) ?>;
// How many extra mailboxes this person may have, and how many they have used.
// null means no limit, which is what a full access admin has.
const MYBOXES  = <?= json_encode($myBoxes) ?>;
const MYBOXES_USED = <?= json_encode($myBoxesUsed) ?>;
const ACCOUNTS = <?= json_encode($accounts) ?>;
const REPOMODES = <?= json_encode(REPO_MODES, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const RUNTIMES  = <?= json_encode(array_merge(RUNTIMES, upstream_runtimes()), JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const SITE_PLATFORMS = <?= json_encode(SITE_PLATFORMS, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const MAILROOT = <?= json_encode($mailRoot, JSON_UNESCAPED_SLASHES) ?>;
// smb.conf as a list of sections, each keeping its own text. Editing a path
// rewrites one line inside `raw`; everything else is written back byte for byte.
const SMB_SECTIONS = <?= json_encode($smbSections, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;
const SMB_READABLE = <?= $smbReadable ? 'true' : 'false' ?>;
const SMB_RESERVED_JS = <?= json_encode(SMB_RESERVED) ?>;
const ADMIN    = <?= json_encode($adminUser) ?>;
const MAILDOMAINS = <?= json_encode($mailDomains, JSON_UNESCAPED_SLASHES) ?>;
// Which account owns each domain, so the drawer can SAY who a mailbox belongs
// to instead of asking. ownership() has read a mailbox that way since
// 2026-09-16; field 15 on a mailbox row was never read. Item 153.
// A limited admin gets only their own domains: the map is a list of customer
// names, and item 136 exists because one of those leaked to the page before.
const DOMAINOWNERS = <?= json_encode((object) ($myRole === 'full' ? $own['owners']
    : array_filter($own['owners'], fn($o) => $o === $me)), JSON_UNESCAPED_SLASHES) ?>;
const DNSDOMAINS  = <?= json_encode($dnsDomains, JSON_UNESCAPED_SLASHES) ?>;
let OPTKEYS  = <?= json_encode($optionKeys, JSON_UNESCAPED_SLASHES) ?>;
// Where a document root lives, per environment, and the folders already there.
const WEBROOTS   = <?= json_encode($webRoots, JSON_UNESCAPED_SLASHES) ?>;
const WEBFOLDERS = <?= json_encode($webFolders, JSON_UNESCAPED_SLASHES) ?>;
let   rows     = <?= json_encode($rows, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>;

// The last check, as data rather than as a card. It is what the Make it live
// dialog shows, so the question "what will this do" is answered at the moment
// it is asked instead of somewhere further down the page.
const CHECK = {
  ran:      <?= $report === '' ? 'false' : 'true' ?>,
  failed:   <?= $reportFailed ? 'true' : 'false' ?>,
  age:      <?= json_encode($reportAge) ?>,
  head:     <?= json_encode($reportHead) ?>,
  problems: <?= json_encode($problems, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>,
  drift:    <?= json_encode($drift, JSON_UNESCAPED_SLASHES | JSON_UNESCAPED_UNICODE) ?>,
  warnings: <?= (int) $warnCount ?>
};

// What this particular page load followed. The scripts below are static, so
// anything the request decided has to arrive as data.
const BOOT = {
  applyFrom:    <?= (int) $applyFrom ?>,
  startedJob:   <?= $startedJob ? 'true' : 'false' ?>,
  autoConfirm:  <?= $autoConfirm ? 'true' : 'false' ?>,
  startedApply: <?= $startedApply ? 'true' : 'false' ?>,
  rebooting:    <?= $rebooting ? 'true' : 'false' ?>
};
</script>
<script src="<?= asset('i18n.js') ?>"></script>
<script src="<?= asset('cells.js') ?>"></script>
<script src="<?= asset('drawer.js') ?>"></script>
<script src="<?= asset('chrome.js') ?>"></script>
<script src="<?= asset('apply.js') ?>"></script>
<script src="<?= asset('smb.js') ?>"></script>
<script src="<?= asset('sharewindow.js') ?>"></script>
<script src="<?= asset('bulk.js') ?>"></script>
<script src="<?= asset('users.js') ?>"></script>
<script src="<?= asset('requests.js') ?>"></script>
<script src="<?= asset('audit.js') ?>"></script>
<script src="<?= asset('boot.js') ?>"></script>
</body>
</html>
