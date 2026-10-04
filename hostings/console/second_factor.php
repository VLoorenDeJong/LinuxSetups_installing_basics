<?php
// =============================================================================
// The console's second factor. Included by index.php once the password login
// and the role check have passed, and before anything else answers.
//
//   passed in the last 12 hours  → returns, and the console runs as before
//   not passed                   → the code page, and nothing else answers
//
// The code goes to the account's own external address, never a mailbox here.
// A recovery code works instead of it, and so does one printed over SSH by
// `sudo console_otp <user>`, for when mail itself is broken.
//
// Design and the reasons: .claude/docs/console-2fa-decisions.md.
// =============================================================================

// Reached directly by URL, it is not included by anything and must do nothing.
// TFA_CLI is the one other way in: recovery_cli.php defines it to borrow the
// code generation without the page around it, so the format lives in one file.
if (!defined('TFA_CLI') && (!defined('AUTHUSERS') || !isset($me) || $me === '')) {
    http_response_code(404);
    exit;
}

const TFA_DIR        = '/var/lib/hosting-manager/2fa';
const TFA_KEY        = TFA_DIR . '/key';
const TFA_COOKIE     = 'console_2fa';
const TFA_PASS_SECS  = 12 * 3600;
const TFA_CODE_SECS  = 300;
const TFA_TRIES      = 5;
const TFA_RESEND_GAP = 60;
const TFA_RECOVERY_N = 2;

// The name shown in titles and mails: MACHINE_NAME in the config.
function tfa_machine_name(): string {
    $conf = (string) @file_get_contents(CONF);
    $name = preg_match('/^[ \t]*MACHINE_NAME[ \t]*=([^#\r\n]*)/m', $conf, $m) ? trim($m[1]) : '';
    return ($name === '' || $name === '-') ? 'Hosting' : $name;
}

// Hex text rather than raw bytes, so console_otp can use the same key with
// `openssl dgst -hmac`, which only takes a string.
function tfa_key(): string {
    $k = trim((string) @file_get_contents(TFA_KEY));
    if (preg_match('/^[0-9a-f]{64}$/', $k)) return $k;
    $k = bin2hex(random_bytes(32));
    $tmp = TFA_KEY . '.' . getmypid();
    if (@file_put_contents($tmp, $k . "\n") === false) return '';
    @chmod($tmp, 0600);
    @rename($tmp, TFA_KEY);
    return trim((string) @file_get_contents(TFA_KEY));
}

function tfa_mac(string $data): string {
    return hash_hmac('sha256', $data, tfa_key());
}

function tfa_file(string $user, string $ext): string {
    return TFA_DIR . '/' . $user . '.' . $ext;
}

// Bound to the name, so one account's cookie is worthless for another.
function tfa_cookie_ok(string $user): bool {
    $parts = explode('.', (string) ($_COOKIE[TFA_COOKIE] ?? ''));
    if (count($parts) !== 3) return false;
    [$u, $until, $mac] = $parts;
    if (tfa_key() === '' || !hash_equals($u, bin2hex($user))) return false;
    if (!ctype_digit($until) || (int) $until < time()) return false;
    return hash_equals(tfa_mac($u . '.' . $until), $mac);
}

// When the pass in the cookie runs out, so a gate pass never outlives it.
function tfa_cookie_until(string $user): int {
    if (!tfa_cookie_ok($user)) return 0;
    return (int) explode('.', (string) $_COOKIE[TFA_COOKIE])[1];
}

function tfa_cookie_set(string $user): void {
    $u = bin2hex($user);
    $until = (string) (time() + TFA_PASS_SECS);
    setcookie(TFA_COOKIE, $u . '.' . $until . '.' . tfa_mac($u . '.' . $until), [
        'expires'  => (int) $until,
        'path'     => '/',
        'httponly' => true,
        'secure'   => !empty($_SERVER['HTTPS']) && $_SERVER['HTTPS'] !== 'off',
        'samesite' => 'Strict',
    ]);
}

// One line, shared with console_otp: `<hmac> <expires> <tries left> <sent at>`.
function tfa_code_read(string $user): ?array {
    $f = explode(' ', trim((string) @file_get_contents(tfa_file($user, 'code'))));
    if (count($f) !== 4 || !ctype_digit($f[1]) || !ctype_digit($f[2]) || !ctype_digit($f[3])) {
        return null;
    }
    return ['mac' => $f[0], 'expires' => (int) $f[1], 'tries' => (int) $f[2], 'sent' => (int) $f[3]];
}

function tfa_code_write(string $user, array $c): void {
    $tmp = tfa_file($user, 'code') . '.' . getmypid();
    @file_put_contents($tmp, "{$c['mac']} {$c['expires']} {$c['tries']} {$c['sent']}\n");
    @chmod($tmp, 0600);
    @rename($tmp, tfa_file($user, 'code'));
}

function tfa_code_live(?array $c): bool {
    return $c !== null && $c['expires'] > time() && $c['tries'] > 0;
}

function tfa_email_of(string $user): string {
    $out = [];
    exec('sudo ' . AUTHUSERS . ' --email-of ' . escapeshellarg($user) . ' 2>/dev/null', $out, $rc);
    $mail = trim(implode('', $out));
    return ($rc === 0 && preg_match('/^[^@\s|]+@[^@\s|]+\.[^@\s|]+$/', $mail)) ? $mail : '';
}

// Code first in the subject: the notification shows it, and Gmail's "Copy
// code" and Apple's code autofill find it there. A copy button cannot work,
// because every mail app strips scripts.
function tfa_mail(string $to, string $from, string $user, string $code): string {
    $host  = gethostname() ?: 'this machine';
    $h     = fn(string $s): string => htmlspecialchars($s, ENT_QUOTES);
    $bound = 'tfa-' . bin2hex(random_bytes(8));
    // The code opens the body as well, so a phone's notification preview shows
    // it without the mail being opened.
    $text  = "$code\r\n"
           . "\r\n\r\n"
           . "Your sign-in code for the " . tfa_machine_name() . " hosting manager.\r\n\r\n"
           . "Account: $user\r\n"
           . "Machine: $host\r\n"
           . "Valid for 5 minutes, and only once.\r\n\r\n"
           . "Did not just sign in? Then somebody else has your password. Change it.\r\n";
    $html  = '<!doctype html><html><body style="margin:0;padding:0;background:#f3f4f7">'
           . '<div style="display:none;max-height:0;overflow:hidden">' . $h($code) . ' is your sign-in code</div>'
           . '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="background:#f3f4f7;padding:32px 12px">'
           . '<tr><td align="center">'
           . '<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:480px;background:#ffffff;border-radius:10px;border:1px solid #e3e6ec;font-family:Segoe UI,Helvetica,Arial,sans-serif;color:#1c2333">'
           . '<tr><td style="background:#0b1020;border-radius:10px 10px 0 0;padding:18px 28px;color:#f0a500;font-size:15px;font-weight:600;letter-spacing:.5px">' . $h(strtoupper(tfa_machine_name())) . '</td></tr>'
           . '<tr><td style="padding:28px 28px 0;font-size:16px;line-height:1.5">Your sign-in code for the hosting manager:</td></tr>'
           . '<tr><td align="center" style="padding:32px 28px">'
           . '<div style="display:inline-block;padding:16px 24px;background:#f3f4f7;border:1px solid #e3e6ec;border-radius:8px;'
           . 'font-family:Consolas,Menlo,monospace;font-size:34px;font-weight:700;letter-spacing:8px;color:#0b1020;'
           . '-webkit-user-select:all;user-select:all">' . $h($code) . '</div></td></tr>'
           . '<tr><td style="padding:0 28px 24px;font-size:14px;line-height:1.6;color:#4a5368">'
           . 'Account: <strong>' . $h($user) . '</strong><br>'
           . 'Machine: ' . $h($host) . '<br>'
           . 'Valid for 5 minutes, and only once.</td></tr>'
           . '<tr><td style="padding:16px 28px 24px;border-top:1px solid #e3e6ec;font-size:13px;line-height:1.5;color:#7a8398">'
           . 'Did not just sign in? Then somebody else has your password. Change it.</td></tr>'
           . '</table></td></tr></table></body></html>';
    return "To: $to\r\n"
         . ($from !== '' ? "From: " . tfa_machine_name() . " <$from>\r\n" : '')
         . "Subject: $code is your " . tfa_machine_name() . " code\r\n"
         . "MIME-Version: 1.0\r\n"
         . "Content-Type: multipart/alternative; boundary=\"$bound\"\r\n"
         . "\r\n"
         . "--$bound\r\n"
         . "Content-Type: text/plain; charset=utf-8\r\n"
         . "Content-Transfer-Encoding: base64\r\n\r\n"
         . chunk_split(base64_encode($text))
         . "--$bound\r\n"
         . "Content-Type: text/html; charset=utf-8\r\n"
         // Base64 keeps every line under SMTP's 998 bytes. Unencoded, Postfix
         // broke the one-line HTML mid-tag, measured 2026-09-19.
         . "Content-Transfer-Encoding: base64\r\n\r\n"
         . chunk_split(base64_encode($html))
         . "--$bound--\r\n";
}

// Returns '' on success, or the reason nothing was sent.
function tfa_send(string $user): string {
    $old = tfa_code_read($user);
    if ($old !== null && time() - $old['sent'] < TFA_RESEND_GAP) {
        return 'A code was sent less than a minute ago. Check your inbox, or wait a moment.';
    }
    $to = tfa_email_of($user);
    if ($to === '') {
        return 'This account has no e-mail address, so no code can be sent. '
             . 'Use a recovery code, or the command under "Locked out?".';
    }
    if (tfa_key() === '') {
        return 'The code store ' . TFA_DIR . ' is not writable, so no code can be made. '
             . 'Re-run add_hosting_manager.sh.';
    }
    $code = sprintf('%06d', random_int(0, 999999));
    $conf = (string) @file_get_contents(CONF);
    $from = preg_match('/^[ \t]*NOTIFY_FROM[ \t]*=[ \t]*([^\s#]+)/m', $conf, $m) ? $m[1] : '';
    $msg = tfa_mail($to, $from, $user, $code);
    $p = proc_open(['/usr/sbin/sendmail', '-t', '-oi'], [0 => ['pipe', 'r'], 1 => ['pipe', 'w'], 2 => ['pipe', 'w']], $pipes);
    if (!is_resource($p)) {
        return 'Could not start sendmail, so no code was sent. Use a recovery code.';
    }
    fwrite($pipes[0], $msg);
    fclose($pipes[0]);
    stream_get_contents($pipes[1]);
    $err = trim((string) stream_get_contents($pipes[2]));
    fclose($pipes[1]);
    fclose($pipes[2]);
    if (proc_close($p) !== 0) {
        return 'Sending the code failed' . ($err !== '' ? ": $err" : '') . '. Use a recovery code.';
    }
    tfa_code_write($user, [
        'mac' => tfa_mac($code), 'expires' => time() + TFA_CODE_SECS,
        'tries' => TFA_TRIES, 'sent' => time(),
    ]);
    return '';
}

function tfa_recovery_hashes(string $user): array {
    $lines = @file(tfa_file($user, 'recovery'), FILE_IGNORE_NEW_LINES | FILE_SKIP_EMPTY_LINES);
    return is_array($lines) ? $lines : [];
}

function tfa_recovery_save(string $user, array $hashes): bool {
    $tmp = tfa_file($user, 'recovery') . '.' . getmypid();
    if (@file_put_contents($tmp, $hashes ? implode("\n", $hashes) . "\n" : '') === false) return false;
    @chmod($tmp, 0600);
    return @rename($tmp, tfa_file($user, 'recovery'));
}


// The codes go into the person's 1Password entry too. The owner, 2026-09-20: they
// were shown once and then existed only as hashes, so in practice they were
// lost and `sudo console_otp` was the real recovery path.
//
// THE COST, so nobody is surprised later: the console password and the second
// factor's fallback now sit behind ONE vault, so a vault compromise is both
// factors. A code nobody can find is not a second factor either, which is the
// trade that was made. login-store-decisions.md.
//
// Down stdin, never argv: `ps` shows arguments to every account here.
// A vault that refuses changes NOTHING: the codes are already the live ones on
// this machine, and the block below is still shown once.
function tfa_codes_to_vault(string $user, array $codes): bool {
    $proc = @proc_open('sudo /usr/local/sbin/person_entry.sh --recovery '
                       . escapeshellarg($user) . ' >/dev/null 2>&1',
                       [0 => ['pipe', 'r']], $pipes);
    if (!is_resource($proc)) return false;
    fwrite($pipes[0], implode("\n", $codes) . "\n");
    fclose($pipes[0]);
    return proc_close($proc) === 0;
}

// A refilled pair nobody can read is not a recovery path. People get their
// entry by a share link, and a link made before the refill shows the spent
// pair, so the link is sent again. Only after the vault write returned 0:
// re-sharing a stale entry would hand somebody codes that no longer work.
//
// Never fatal, and never blocking the sign-in: the person is already in, and
// the key page can share again. `op item share` returns a link and sends
// nothing itself, so person_entry.sh mails it.
function tfa_reshare_entry(string $user): bool {
    $out = [];
    exec('sudo /usr/local/sbin/person_entry.sh --share ' . escapeshellarg($user) . ' 2>/dev/null',
         $out, $rc);
    if ($rc !== 0) return false;
    $j = json_decode(implode('', $out), true);
    return is_array($j) && !empty($j['ok']);
}
// UUIDv4, the owner's choice 2026-09-20: the codes live in 1Password and are
// pasted, so length costs nothing and nobody has to read one off paper.
function tfa_uuid4(): string {
    $b = random_bytes(16);
    $b[6] = chr((ord($b[6]) & 0x0f) | 0x40);
    $b[8] = chr((ord($b[8]) & 0x3f) | 0x80);
    $h = bin2hex($b);
    return substr($h, 0, 8) . '-' . substr($h, 8, 4) . '-' . substr($h, 12, 4)
         . '-' . substr($h, 16, 4) . '-' . substr($h, 20, 12);
}

// Numbered, the way a seed phrase is: the pair is worthless unless both are
// kept, and a numbered list makes a missing one obvious. The same numbering is
// what person_entry.sh writes into 1Password as "code 1" and "code 2".
function tfa_labelled(array $codes): string {
    $out = [];
    foreach ($codes as $i => $c) $out[] = 'code ' . ($i + 1) . ': ' . $c;
    return implode("\n", $out);
}

// The hash is of the NORMALISED code: upper case, dashes gone. tfa_check
// normalises what is typed the same way, so a pasted code matches whatever the
// clipboard did to its case.
function tfa_recovery_new(string $user): array {
    $codes = [];
    $hashes = [];
    for ($i = 0; $i < TFA_RECOVERY_N; $i++) {
        $uuid     = tfa_uuid4();
        $codes[]  = $uuid;
        $hashes[] = password_hash(strtoupper(str_replace('-', '', $uuid)), PASSWORD_DEFAULT);
    }
    return tfa_recovery_save($user, $hashes) ? $codes : [];
}

// Six digits is an e-mailed or console_otp code; anything else is tried as a
// recovery code, which is spent on use.
function tfa_check(string $user, string $typed, string $typed2 = ''): string {
    $typed  = strtoupper((string) preg_replace('/[\s-]+/', '', $typed));
    $typed2 = strtoupper((string) preg_replace('/[\s-]+/', '', $typed2));
    if (preg_match('/^[0-9]{6}$/', $typed)) {
        $c = tfa_code_read($user);
        if (!tfa_code_live($c)) return 'That code has expired or been used up. Send a new one.';
        if (hash_equals($c['mac'], tfa_mac($typed))) {
            @unlink(tfa_file($user, 'code'));
            return '';
        }
        $c['tries']--;
        tfa_code_write($user, $c);
        return $c['tries'] > 0
            ? "Wrong code. {$c['tries']} " . ($c['tries'] === 1 ? 'try' : 'tries') . ' left.'
            : 'Wrong code, and that was the last try. Send a new one.';
    }
    // TWO different recovery codes, the owner 2026-09-20, told that both live in
    // the same 1Password item and that this narrows only the single-leaked-code
    // case. Both are verified before either is spent, so a wrong second code
    // does not burn the first.
    if (preg_match('/^[0-9A-F]{32}$/', $typed)) {
        if ($typed2 === '') return 'Recovery codes are used two at a time. Put a second, different code in the second box.';
        if ($typed2 === $typed) return 'The two recovery codes must be different ones.';
        if (!preg_match('/^[0-9A-F]{32}$/', $typed2)) return 'The second box is not a recovery code.';

        $hashes = tfa_recovery_hashes($user);
        $hit1 = $hit2 = null;
        foreach ($hashes as $i => $h) {
            if ($hit1 === null && password_verify($typed, $h))  { $hit1 = $i; continue; }
            if ($hit2 === null && password_verify($typed2, $h)) { $hit2 = $i; }
        }
        if ($hit1 !== null && $hit2 !== null) {
            unset($hashes[$hit1], $hashes[$hit2]);
            tfa_recovery_save($user, array_values($hashes));
            // Both codes are spent, and with a pair that leaves none. The owner,
            // 2026-09-20: refill at once, so there is never a moment with no
            // recovery path and nothing saying so.
            //
            // The vault write decides it. Codes nobody can read are worse than
            // none: if 1Password cannot be written the set stays empty, the
            // key page says zero, and a new pair is made deliberately.
            $fresh = tfa_recovery_new($user);
            if (!$fresh || !tfa_codes_to_vault($user, $fresh)) {
                tfa_recovery_save($user, []);
            } else {
                // Confirmed written, so the link is worth sending. The owner,
                // 2026-09-20: reshare after confirmed change.
                tfa_reshare_entry($user);
            }
            return '';
        }
        return 'That is not a valid pair of recovery codes.';
    }
    return 'That is not a valid code.';
}

function tfa_page(string $title, string $body, int $status = 200): void {
    http_response_code($status);
    header('Content-Type: text/html; charset=utf-8');
    header('Cache-Control: no-store');
    echo '<!doctype html><html lang="en"><head><meta charset="utf-8">'
       . '<meta name="viewport" content="width=device-width, initial-scale=1">'
       . '<title>' . htmlspecialchars(tfa_machine_name() . ' | ' . $title) . '</title><style>'
       . ':root{--bg:#0b1020;--card:#151d33;--line:#2a3550;--text:#e6ebf5;--muted:#8b98b0;--gold:#f0a500;--bad:#ff6b6b}'
       . '*{box-sizing:border-box}body{font-family:system-ui,sans-serif;background:var(--bg);color:var(--text);margin:0;min-height:100vh;display:grid;place-items:center}'
       . '.card{background:var(--card);border:1px solid var(--line);padding:2rem;border-radius:10px;width:24rem;max-width:calc(100vw - 2rem)}'
       . 'h1{font-size:1.15rem;margin:0 0 .5rem}p{font-size:.9rem;line-height:1.45}.muted{color:var(--muted)}.bad{color:var(--bad)}'
       . 'label{display:block;font-size:.8rem;color:var(--muted);margin:.9rem 0 .3rem}'
       . 'input,textarea{width:100%;padding:.55rem .7rem;background:var(--bg);border:1px solid var(--line);border-radius:5px;color:var(--text);font-size:1rem}'
       . 'textarea{font-family:ui-monospace,monospace;font-size:.8rem;height:15rem}'
       . 'button{width:100%;margin-top:1rem;padding:.65rem;border:0;border-radius:5px;background:var(--gold);color:#1a1200;font-size:1rem;font-weight:600;cursor:pointer}'
       . 'button.plain{background:transparent;color:var(--muted);border:1px solid var(--line);font-weight:400}'
       . 'code{background:var(--bg);padding:.1rem .35rem;border-radius:3px}details{margin-top:1.25rem;font-size:.85rem}a{color:var(--gold)}'
       . '</style></head><body><div class="card">' . $body . '</div></body></html>';
    exit;
}

function tfa_lockout_help(string $user): string {
    return '<details><summary class="muted">Locked out?</summary>'
         . '<p>SSH into ' . htmlspecialchars(gethostname() ?: 'the machine') . ' as a sudo user and run:</p>'
         . '<p><code>sudo console_otp ' . htmlspecialchars($user) . '</code></p>'
         . '<p class="muted">It prints a code to type in above. The same line is shown at every SSH login.</p>'
         . '</details>';
}

function tfa_code_page(string $user, string $note, bool $noteBad): void {
    tfa_page('Code', '<h1>One more step</h1>'
        . '<p class="muted">A 6-digit code was sent to the e-mail address of '
        . '<strong>' . htmlspecialchars($user) . '</strong>. Two recovery codes work instead.</p>'
        . ($note !== '' ? '<p class="' . ($noteBad ? 'bad' : 'muted') . '">' . htmlspecialchars($note) . '</p>' : '')
        . '<form method="POST" action="' . htmlspecialchars(tfa_here()) . '"><input type="hidden" name="action" value="2fa-check">'
        . '<label for="c">Code</label>'
        . '<input id="c" name="code" autocomplete="one-time-code" inputmode="text" autofocus required>'
        // Recovery takes TWO different codes, the owner 2026-09-20. Left empty for
        // the e-mailed code, which is one field as before.
        . '<label for="c2">Second recovery code</label>'
        . '<input id="c2" name="code2" autocomplete="off" inputmode="text">'
        . '<p class="muted">Leave the second box empty for the e-mailed code. '
        . 'Recovery codes are used two at a time, and both are spent.</p>'
        . '<button type="submit">Continue</button></form>'
        . '<form method="POST" action="' . htmlspecialchars(tfa_here()) . '"><input type="hidden" name="action" value="2fa-send">'
        . '<button type="submit" class="plain">Send a new code</button></form>'
        . tfa_lockout_help($user));
}

function tfa_recovery_page(string $user): void {
    $host = gethostname() ?: 'the machine';
    if (($_SERVER['REQUEST_METHOD'] ?? '') === 'POST' && ($_POST['action'] ?? '') === '2fa-recovery-new') {
        $codes = tfa_recovery_new($user);
        if (!$codes) {
            tfa_page('Recovery codes', '<h1>Recovery codes</h1><p class="bad">Could not save new codes in '
                . TFA_DIR . ', so the old ones still work. Re-run add_hosting_manager.sh.</p>'
                . '<p><a href="./">Back to the console</a></p>', 500);
        }
        $inVault = tfa_codes_to_vault($user, $codes);
        $block = tfa_machine_name() . " console, $user, recovery codes (" . date('Y-m-d') . ")\n"
               . "BOTH codes are needed at once, in place of the e-mailed code.\n"
               . "Using them replaces them: a new pair is written to 1Password\n"
               . "straight away, so these two stop working the moment you sign\n"
               . "in with them.\n\n"
               . tfa_labelled($codes) . "\n\n"
               . "Locked out and out of codes:\n"
               . "  1. SSH into $host as a sudo user\n"
               . "  2. sudo console_otp $user\n"
               . "  3. Type the printed code into the console's code page\n";
        tfa_page('Recovery codes', '<h1>New recovery codes</h1>'
            . ($inVault
               ? '<p>Already saved to your 1Password entry, under <strong>Recovery codes</strong>. '
               : '<p class="bad">The vault could not be written, so this block is the only copy. '
                 . 'Put it in your 1Password item now. ')
            . 'The old codes no longer work.</p>'
            . '<textarea readonly onclick="this.select()">' . htmlspecialchars($block) . '</textarea>'
            . '<p><a href="./">Back to the console</a></p>');
    }
    $left = count(tfa_recovery_hashes($user));
    tfa_page('Recovery codes', '<h1>Recovery codes</h1>'
        . ($left >= TFA_RECOVERY_N
           ? '<p>Your pair of recovery codes is in 1Password, as <strong>code 1</strong> and <strong>code 2</strong>.</p>'
             . '<p class="muted">Both are needed at once, and using them writes a fresh pair to the vault straight away.</p>'
           : '<p class="bad">You have <strong>' . $left . '</strong> recovery code'
             . ($left === 1 ? '' : 's') . ', which is not a usable pair. Make a new pair now.</p>')
        . '<p class="muted">Making a new pair voids the old one.</p>'
        . '<form method="POST" action="./?second-factor=recovery">'
        . '<input type="hidden" name="action" value="2fa-recovery-new">'
        . '<button type="submit">Make a new pair</button></form>'
        . '<p><a href="./">Back to the console</a></p>');
}

// =============================================================================
// THE GATE: this second factor in front of the proxied tools (Jenkins,
// Portainer). Their vhosts, from add_app_vhosts.sh, send a browser without a
// pass here as ?tfa-for=<their name>. Once this page's own factor has passed,
// gate_handoff() writes a one-off token into a map Apache reads and sends the
// browser back to /.hm-gate on that name, where Apache turns it into a cookie.
//
// A token is only good together with the same account's password login on
// that name: the map key is token:user, and Apache looks it up with its own
// REMOTE_USER.
// =============================================================================
const GATE_DIR = '/var/lib/hosting-manager/gate';
const GATE_MAP = GATE_DIR . '/gate.map';

// A name is a gate target only if an enabled vhost says so. Read from what
// Apache serves, so a removed row stops being a target with its vhost.
function gate_target(): string {
    $h = strtolower((string) ($_GET['tfa-for'] ?? ''));
    if (!preg_match('/^[a-z0-9][a-z0-9.-]{0,252}$/', $h)) return '';
    foreach (glob('/etc/apache2/sites-enabled/*.conf') ?: [] as $f) {
        if (preg_match('/^# hm-gate: ' . preg_quote($h, '/') . '$/m', (string) @file_get_contents($f))) return $h;
    }
    return '';
}

// Apache compares against %{TIME}, which is local time, so the stamp is too.
function gate_stamp(int $t): string {
    $name = '';
    $link = @readlink('/etc/localtime');
    if (is_string($link) && ($p = strpos($link, 'zoneinfo/')) !== false) $name = substr($link, $p + 9);
    if ($name === '') $name = trim((string) @file_get_contents('/etc/timezone'));
    try { $tz = new DateTimeZone($name !== '' ? $name : 'UTC'); }
    catch (Exception $e) { $tz = new DateTimeZone('UTC'); }
    return (new DateTime('@' . $t))->setTimezone($tz)->format('YmdHis');
}

function gate_handoff(string $user): void {
    $host = gate_target();
    if ($host === '') {
        tfa_page('Not a gated name', '<h1>Not a gated name</h1><p class="muted">'
            . htmlspecialchars((string) ($_GET['tfa-for'] ?? '')) . ' is not served behind this sign-in.</p>', 400);
    }
    // Back here within seconds means the tool refused the last pass: most often
    // signed in there as another account. Say so rather than loop for ever.
    $seen = GATE_DIR . '/.last-' . hash('sha256', $user . '|' . $host);
    if (time() - (int) @filemtime($seen) < 10) {
        @unlink($seen);
        tfa_page('Pass not accepted', '<h1>Pass not accepted</h1><p class="muted">'
            . htmlspecialchars($host) . ' sent you straight back. It only accepts the pass for the same '
            . 'account: sign out there and sign in as <strong>' . htmlspecialchars($user) . '</strong>, '
            . 'or ask whoever runs the machine to check that ' . htmlspecialchars(GATE_MAP) . ' is readable by Apache.</p>', 403);
    }
    @touch($seen);

    $until = tfa_cookie_until($user) ?: time() + TFA_PASS_SECS;
    $tok = bin2hex(random_bytes(32));
    $now = gate_stamp(time());

    $lock = @fopen(GATE_DIR . '/.lock', 'c');
    if ($lock === false) {
        tfa_page('Gate unavailable', '<h1>Gate unavailable</h1><p class="bad">' . GATE_DIR
            . ' is not writable for this page. Re-run add_hosting_manager.sh.</p>', 500);
    }
    flock($lock, LOCK_EX);
    $keep = [];
    foreach (file(GATE_MAP, FILE_IGNORE_NEW_LINES) ?: [] as $line) {
        if (preg_match('/^[0-9a-f]{64}:[A-Za-z0-9._-]+ ([0-9]{14})$/', $line, $m) && $m[1] > $now) $keep[] = $line;
    }
    $keep[] = $tok . ':' . $user . ' ' . gate_stamp($until);
    $tmp = GATE_MAP . '.' . getmypid();
    $ok = @file_put_contents($tmp, implode("\n", $keep) . "\n") !== false && @chmod($tmp, 0640) && @rename($tmp, GATE_MAP);
    flock($lock, LOCK_UN);
    fclose($lock);
    if (!$ok) {
        @unlink($tmp);
        tfa_page('Gate unavailable', '<h1>Gate unavailable</h1><p class="bad">' . GATE_MAP
            . ' could not be written. Re-run add_hosting_manager.sh.</p>', 500);
    }
    header('Cache-Control: no-store');
    header('Location: https://' . $host . '/.hm-gate?t=' . $tok, true, 303);
    exit;
}

// Kept through the code page, so passing it still ends up back at the tool.
function tfa_here(): string {
    $h = (string) ($_GET['tfa-for'] ?? '');
    return './' . (preg_match('/^[A-Za-z0-9.-]{1,253}$/', $h) ? '?tfa-for=' . rawurlencode($h) : '');
}

// Everything below answers a request. A CLI caller wants the functions above
// and nothing else: without this it would fall through to the code page and
// send somebody a sign-in code from a cron job.
if (defined('TFA_CLI')) return;

$tfaAction = (string) ($_POST['action'] ?? '');

// The recovery page comes BEFORE the live gate, because codes are only any use
// if they exist before the lock-out. Behind the gate the 🔑 in the header was
// visible to every admin and did nothing at all.
if (($_GET['second-factor'] ?? '') === 'recovery') tfa_recovery_page($me);

if (tfa_cookie_ok($me)) {
    return;
}

// Off until the machine is live. The owner, 2026-09-19: on a test machine it is
// a code per sign-in for nothing. The drive swap sets MACHINE_IS_LIVE = yes.
if (!preg_match('/^[ \t]*MACHINE_IS_LIVE[ \t]*=[ \t]*yes\b/mi', (string) @file_get_contents(CONF))) {
    return;
}

// CONSOLE_2FA = off: a LAN-only machine with one operator, where the password
// and the failed-login throttle are the guard. The owner, 2026-10-04 (HomeRun).
if (preg_match('/^[ \t]*CONSOLE_2FA[ \t]*=[ \t]*off\b/mi', (string) @file_get_contents(CONF))) {
    return;
}

if ($tfaAction === '2fa-check') {
    $why = tfa_check($me, (string) ($_POST['code'] ?? ''), (string) ($_POST['code2'] ?? ''));
    if ($why === '') {
        tfa_cookie_set($me);
        header('Location: ' . tfa_here(), true, 303);
        exit;
    }
    tfa_code_page($me, $why, true);
}

if ($tfaAction === '2fa-send') {
    $why = tfa_send($me);
    tfa_code_page($me, $why !== '' ? $why : 'A new code is on its way.', $why !== '');
}

// A poll or a button from a page opened before the 12 hours ran out. JSON,
// because that is what every fetch() and POST here reads. A browser marks its
// own page loads `navigate`; fetch() never does.
$tfaMode = (string) ($_SERVER['HTTP_SEC_FETCH_MODE'] ?? '');
if ($_SERVER['REQUEST_METHOD'] === 'POST' || isset($_GET['ask'])
    || ($tfaMode !== '' && $tfaMode !== 'navigate')) {
    http_response_code(401);
    header('Content-Type: application/json');
    header('Cache-Control: no-store');
    echo json_encode(['ok' => false, 'out' => 'The console needs its sign-in code again. Reload the page.']);
    exit;
}

// A plain visit sends a code only when none is waiting, so reloading the page
// does not fill the inbox.
$why = tfa_code_live(tfa_code_read($me)) ? '' : tfa_send($me);
tfa_code_page($me, $why, $why !== '');
