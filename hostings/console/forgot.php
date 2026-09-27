<?php
// =============================================================================
// Forgot password: a one-time link, mailed to the account's external address,
// that lets the person set their own console password.
// login-store-decisions.md, decisions 6, 6a and 6b.
//
//   GET  ?probe       204 with X-Forgot, so the shared sign-in page shows its
//                     link here and on no other door
//   GET               the name form
//   POST send         mail a link, same answer whether the name exists or not
//   GET  ?t=<token>   the new-password form
//   POST set          set it, once
//
// OUTSIDE THE LOGIN, on purpose: somebody who forgot their password cannot
// sign in to ask. The vhost exempts this one file. What guards it instead is
// the token: 256 random bits, kept only as an HMAC, valid for an hour, used
// once. The console password only: never a mailbox (decision 6b).
// =============================================================================

// The file in force, asked of config.sh so the page and the scripts share one rule.
define('CONF', (function () {
    $dir = '/etc/hostings';
    $out = trim((string) @shell_exec('bash -c '
        . escapeshellarg('. "$0/../hostings/scripts/config.sh" && conf_active "$0"')
        . ' ' . escapeshellarg($dir) . ' 2>/dev/null'));
    return $out !== '' ? $out : $dir . '/hostings.conf';
})());
const AUTHUSERS   = '/usr/local/sbin/manage_auth_users.sh';
const RESET_DIR   = '/var/lib/hosting-manager/reset';
const RESET_SECS  = 3600;
const RESEND_SECS = 15 * 60;
const SENDS_HOUR  = 10;
const MIN_LENGTH  = 12;

// Borrows the second factor's key, its HMAC and the address lookup, so there
// is one implementation of each.
define('TFA_CLI', true);
require __DIR__ . '/second_factor.php';

header('Cache-Control: no-store');
header('Referrer-Policy: no-referrer');

if (isset($_GET['probe'])) {
    header('X-Forgot: 1');
    http_response_code(204);
    exit;
}

function fp_audit(string $action, string $user, string $result): void {
    openlog('hosting-manager', LOG_PID, LOG_USER);
    syslog(LOG_NOTICE, json_encode(['user' => $user, 'action' => $action, 'target' => [], 'result' => $result]));
    closelog();
}

function fp_valid_name(string $n): bool {
    return (bool) preg_match('/^[A-Za-z0-9._-]{1,64}$/', $n);
}

function fp_file(string $user): string {
    return RESET_DIR . '/' . $user . '.json';
}

function fp_read(string $user): ?array {
    $r = json_decode((string) @file_get_contents(fp_file($user)), true);
    return is_array($r) && isset($r['mac'], $r['expires'], $r['sent']) ? $r : null;
}

function fp_holders(): array {
    exec('sudo ' . AUTHUSERS . ' --role-holders 2>/dev/null', $out, $rc);
    return $rc === 0 ? preg_split('/\s+/', trim(implode(' ', $out)), -1, PREG_SPLIT_NO_EMPTY) : [];
}

// A switched-off account gets no link: setting its password would switch it on.
function fp_enabled(string $user): bool {
    exec('sudo ' . AUTHUSERS . ' --list 2>/dev/null', $out, $rc);
    foreach ((array) (json_decode(implode('', $out), true)['users'] ?? []) as $u) {
        if (($u['name'] ?? '') === $user) return !empty($u['enabled']);
    }
    return false;
}

// Never from the Host header: a forged one would mail a link to somebody
// else's site. The address the request actually arrived on cannot be forged.
function fp_link(string $token): string {
    $addr = (string) ($_SERVER['SERVER_ADDR'] ?? '');
    if (str_contains($addr, ':')) $addr = "[$addr]";
    return 'http://' . $addr . ':' . (int) ($_SERVER['SERVER_PORT'] ?? 80) . '/forgot.php?t=' . $token;
}

// Counts sends in the last hour across every name, so the page cannot be used
// to flood a mailbox or the mail server by cycling names.
function fp_budget_left(): bool {
    $log = RESET_DIR . '/sends';
    $now = time();
    $keep = array_filter(@file($log, FILE_IGNORE_NEW_LINES) ?: [], fn($t) => (int) $t > $now - 3600);
    if (count($keep) >= SENDS_HOUR) return false;
    $keep[] = (string) $now;
    @file_put_contents($log, implode("\n", $keep) . "\n", LOCK_EX);
    return true;
}

function fp_mail(string $to, string $user, string $link): bool {
    $conf = (string) @file_get_contents(CONF);
    $from = preg_match('/^[ \t]*NOTIFY_FROM[ \t]*=[ \t]*([^\s#]+)/m', $conf, $m) ? $m[1] : '';
    $host = gethostname() ?: 'this machine';
    $text = "Set a new password for the " . tfa_machine_name() . " hosting manager.\r\n\r\n"
          . "Account: $user\r\nMachine: $host\r\n\r\n"
          . "$link\r\n\r\n"
          . "The link works once, for one hour, from the local network or the VPN.\r\n\r\n"
          . "Did not ask for this? Then ignore it: your password stays as it is.\r\n";
    $msg = "To: $to\r\n"
         . ($from !== '' ? "From: " . tfa_machine_name() . " <$from>\r\n" : '')
         . "Subject: Set your " . tfa_machine_name() . " password\r\n"
         . "MIME-Version: 1.0\r\n"
         . "Content-Type: text/plain; charset=utf-8\r\n"
         . "Content-Transfer-Encoding: base64\r\n\r\n"
         . chunk_split(base64_encode($text));
    $p = proc_open(['/usr/sbin/sendmail', '-t', '-oi'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($p)) return false;
    fwrite($pipes[0], $msg);
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    stream_get_contents($pipes[2]);
    fclose($pipes[1]);
    fclose($pipes[2]);
    return proc_close($p) === 0;
}

// Returns the user a token belongs to, or '' for any token that is not live.
function fp_check(string $token): string {
    if (!preg_match('/^([A-Za-z0-9._-]{1,64})\.([A-Za-z0-9_-]{43})$/', $token, $m)) return '';
    $r = fp_read($m[1]);
    if ($r === null || $r['expires'] < time() || tfa_key() === '') return '';
    return hash_equals($r['mac'], tfa_mac($token)) ? $m[1] : '';
}

$h = fn(string $s): string => htmlspecialchars($s, ENT_QUOTES);
$action = (string) ($_POST['action'] ?? '');
$token  = (string) ($_POST['t'] ?? $_GET['t'] ?? '');
$note = '';
$bad  = false;
$view = $token !== '' ? 'set' : 'ask';

if ($action === 'send') {
    $user = trim((string) ($_POST['name'] ?? ''));
    $view = 'sent';
    $result = 'skipped';
    $last = fp_valid_name($user) ? fp_read($user) : null;
    if (fp_valid_name($user) && ($last === null || time() - $last['sent'] >= RESEND_SECS)
        && in_array($user, fp_holders(), true) && fp_enabled($user)
        && ($to = tfa_email_of($user)) !== '' && tfa_key() !== '' && fp_budget_left()) {
        $token = $user . '.' . rtrim(strtr(base64_encode(random_bytes(32)), '+/', '-_'), '=');
        $tmp = fp_file($user) . '.' . getmypid();
        $saved = @file_put_contents($tmp, json_encode([
            'mac' => tfa_mac($token), 'expires' => time() + RESET_SECS, 'sent' => time(),
        ])) !== false && @rename($tmp, fp_file($user));
        $result = $saved && fp_mail($to, $user, fp_link($token)) ? 'ok' : 'failed';
        if (!$saved) @unlink($tmp);
    }
    // Only a valid name is logged: free text typed into a public form is not.
    fp_audit('forgot_send', fp_valid_name($user) ? $user : '', $result);
    $token = '';
}

if ($action === 'set') {
    $user = fp_check($token);
    $pw1 = (string) ($_POST['pw1'] ?? '');
    $pw2 = (string) ($_POST['pw2'] ?? '');
    if ($user === '') {
        $view = 'dead';
    } elseif ($pw1 !== $pw2) {
        $note = 'The two passwords are not the same.';
        $bad = true;
    } elseif (mb_strlen($pw1) < MIN_LENGTH || str_contains($pw1, "\n") || str_contains($pw1, "\r")) {
        $note = 'Use at least ' . MIN_LENGTH . ' characters, on one line.';
        $bad = true;
    } else {
        // Used up before the change, so a double press cannot use it twice.
        @unlink(fp_file($user));
        $p = proc_open(['sudo', AUTHUSERS, '--self-password', $user], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
        $ok = false;
        if (is_resource($p)) {
            fwrite($pipes[0], $pw1 . "\n");
            fclose($pipes[0]);
            stream_get_contents($pipes[1]);
            stream_get_contents($pipes[2]);
            fclose($pipes[1]);
            fclose($pipes[2]);
            $ok = proc_close($p) === 0;
        }
        fp_audit('forgot_set', $user, $ok ? 'ok' : 'failed');
        $view = $ok ? 'done' : 'failed';
    }
} elseif ($view === 'set' && fp_check($token) === '') {
    $view = 'dead';
}
?><!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title><?= htmlspecialchars(tfa_machine_name()) ?> | Forgot password</title>
<?php if ($view === 'sent'): ?><meta http-equiv="refresh" content="5;url=/login.html"><?php endif; ?>
<style>
:root { --bg:#0b1020; --card:#151d33; --line:#2a3550; --text:#e6ebf5; --muted:#8b98b0; --gold:#f0a500; --bad:#ff7b72; }
* { box-sizing:border-box; }
body { font-family:system-ui,sans-serif; background:var(--bg); color:var(--text); margin:0; min-height:100vh; display:grid; place-items:center; padding:1rem; }
.card { background:var(--card); border:1px solid var(--line); padding:2rem; border-radius:10px; width:min(21rem,100%); }
h1 { font-size:1.15rem; margin:0 0 .25rem; text-align:center; }
.sub { color:var(--muted); font-size:.85rem; text-align:center; margin:0 0 1.25rem; line-height:1.45; }
.note { color:var(--bad); font-size:.85rem; margin:.75rem 0 0; }
label { display:block; font-size:.8rem; color:var(--muted); margin:.9rem 0 .3rem; }
input { width:100%; padding:.55rem .7rem; background:var(--bg); border:1px solid var(--line); border-radius:5px; color:var(--text); font-size:1rem; }
input:focus { outline:none; border-color:var(--gold); }
button { width:100%; margin-top:1.5rem; padding:.65rem; border:0; border-radius:5px; background:var(--gold); color:#1a1200; font-size:1rem; font-weight:600; cursor:pointer; }
a { color:var(--gold); }
.foot { font-size:.8rem; text-align:center; margin-top:1.25rem; }
.bar { height:3px; background:var(--line); border-radius:2px; overflow:hidden; }
.bar .fill { height:100%; background:var(--gold); animation:drain 5s linear forwards; }
@keyframes drain { from { width:100%; } to { width:0; } }
</style>
</head>
<body>
<div class="card">
<?php if ($view === 'ask'): ?>
<h1>Forgot password</h1>
<p class="sub">Type your username. A link to set a new password goes to the e-mail address on your account.</p>
<form method="POST" action="/forgot.php">
<input type="hidden" name="action" value="send">
<label for="u">Username</label>
<input id="u" type="text" name="name" autocomplete="username" autofocus required>
<button type="submit">Send the link</button>
</form>
<?php elseif ($view === 'sent'): ?>
<h1>Check your e-mail</h1>
<p class="sub">If that account has an e-mail address, a link is on its way. It works once, for one hour.<br><br>Nothing after a few minutes? Ask the administrator.</p>
<p class="sub" id="back-in">Back to sign in in <span id="back-secs">5</span> s</p>
<div class="bar"><div class="fill"></div></div>
<?php elseif ($view === 'set'): ?>
<h1>Set a new password</h1>
<p class="sub">At least <?= MIN_LENGTH ?> characters. A password manager can make one for you.</p>
<form method="POST" action="/forgot.php">
<input type="hidden" name="action" value="set">
<input type="hidden" name="t" value="<?= $h($token) ?>">
<input type="text" name="username" value="<?= $h(explode('.', $token)[0]) ?>" autocomplete="username" hidden>
<label for="p1">New password</label>
<input id="p1" type="password" name="pw1" autocomplete="new-password" minlength="<?= MIN_LENGTH ?>" autofocus required>
<label for="p2">The same again</label>
<input id="p2" type="password" name="pw2" autocomplete="new-password" minlength="<?= MIN_LENGTH ?>" required>
<?php if ($bad): ?><p class="note"><?= $h($note) ?></p><?php endif; ?>
<button type="submit">Set the password</button>
</form>
<?php elseif ($view === 'done'): ?>
<h1>Password set</h1>
<p class="sub">Sign in with it now. The link is used up.</p>
<?php elseif ($view === 'failed'): ?>
<h1>Not changed</h1>
<p class="sub">The machine refused the change, and the link is used up. Ask the administrator.</p>
<?php else: ?>
<h1>This link has expired</h1>
<p class="sub">It was used already, or it is older than an hour. Ask for a new one.</p>
<?php endif; ?>
<p class="foot"><a href="/login.html">Back to sign in</a><?= $view === 'dead' ? ' · <a href="/forgot.php">New link</a>' : '' ?></p>
</div>
<?php if ($view === 'sent'): ?>
<script>
// The meta refresh does the navigating; this only counts it down.
let s = 5;
const out = document.getElementById('back-secs');
const tick = setInterval(() => { s--; out.textContent = Math.max(s, 0); if (s <= 0) clearInterval(tick); }, 1000);
</script>
<?php endif; ?>
</body>
</html>
