<?php
// Installed by add_roundcube.sh as plugins/password/drivers/checked_chpasswd.php.
// The stock chpasswd driver sends only the new password. This one sends the
// current one too, so mail_chpasswd.sh checks it as root instead of trusting
// Roundcube to have. Item 146.

class rcube_checked_chpasswd_password
{
    public function save($currpass, $newpass, $username)
    {
        // One value per line, so a line break inside one would shift the rest.
        foreach ([$username, $currpass, $newpass] as $v) {
            if (strpbrk($v, "\r\n") !== false) {
                return PASSWORD_ERROR;
            }
        }

        $cmd = rcmail::get_instance()->config->get('password_chpasswd_cmd');
        $handle = popen($cmd, 'w');
        if ($handle === false) {
            return PASSWORD_CONNECT_ERROR;
        }
        fwrite($handle, "$username\n$currpass\n$newpass\n");

        if (pclose($handle) == 0) {
            return PASSWORD_SUCCESS;
        }

        rcube::raise_error([
                'code' => 600,
                'file' => __FILE__,
                'line' => __LINE__,
                'message' => "Password plugin: $cmd refused the change",
            ], true, false
        );

        return PASSWORD_ERROR;
    }
}
