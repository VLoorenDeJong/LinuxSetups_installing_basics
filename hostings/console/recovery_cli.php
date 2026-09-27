<?php
// =============================================================================
// Recovery codes from the command line, so the installer can give an account
// its ten without anybody opening a browser.
//
//   php recovery_cli.php --ensure <user>   codes only if the user has none
//   php recovery_cli.php --new <user>      always, voiding the old set
//   php recovery_cli.php --has <user>      exit 0 if a set exists, 1 if not
//
// It prints the codes on stdout, one per line, for piping into
// person_entry.sh --recovery. Nothing else goes to stdout, so a caller can
// read it without parsing prose.
//
// The generation and the hashing are NOT repeated here: second_factor.php
// owns the format, and a second implementation of it is a second one to get
// wrong. TFA_CLI tells that file to define its functions and stop.
// =============================================================================

if (PHP_SAPI !== 'cli') {
    http_response_code(404);
    exit(1);
}

define('TFA_CLI', true);
require __DIR__ . '/second_factor.php';

$verb = $argv[1] ?? '';
$user = $argv[2] ?? '';

if (!preg_match('/^[A-Za-z0-9._-]+$/', (string) $user)
    || !in_array($verb, ['--ensure', '--new', '--has'], true)) {
    fwrite(STDERR, "usage: recovery_cli.php --ensure|--new|--has <user>\n");
    exit(2);
}

$have = count(tfa_recovery_hashes($user));

if ($verb === '--has') exit($have > 0 ? 0 : 1);
if ($verb === '--ensure' && $have > 0) exit(0);

$codes = tfa_recovery_new($user);
if (!$codes) {
    fwrite(STDERR, "Could not write " . TFA_DIR . "/$user.recovery\n");
    exit(1);
}
echo implode("\n", $codes), "\n";
