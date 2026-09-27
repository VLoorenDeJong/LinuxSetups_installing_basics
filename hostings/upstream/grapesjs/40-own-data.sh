#!/bin/sh
# The data folder is mounted from the machine, owned by root on first start;
# nginx's workers run as nginx and must write the editor's saves into it.
# Only the folder itself: without capabilities root cannot read into it once
# nginx owns it, and what nginx writes is nginx's already.
d=/usr/share/nginx/html/data
[ "$(stat -c %U "$d")" = nginx ] || chown nginx:nginx "$d"
