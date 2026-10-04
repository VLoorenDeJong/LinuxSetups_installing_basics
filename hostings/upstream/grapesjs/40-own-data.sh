#!/bin/sh
# The data folder is mounted from the machine. Run as the recipe's USER, the
# machine already gave it to that uid, so there is nothing to do here.
# Run as root (no USER), nginx's workers run as nginx and must own it.
[ "$(id -u)" = 0 ] || exit 0
d=/usr/share/nginx/html/data
[ "$(stat -c %U "$d")" = nginx ] || chown nginx:nginx "$d"
