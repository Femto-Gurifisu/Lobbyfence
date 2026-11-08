#!/bin/sh
# LobbyFence for DD-WRT - the web page's link to the router, as LobbyFence's
# web server (lighttpd) runs it: the answer's header, then the same CGI as on
# FreshTomato (share/lobbyfence-cgi.sh) with the token from LobbyFence's file.
# SPDX-License-Identifier: GPL-3.0-or-later
LF_HOME="${LF_HOME:-@LFHOME@}"
printf 'Content-Type: application/json\r\nCache-Control: no-store\r\n\r\n'
[ "$REQUEST_METHOD" = POST ] || { echo '{"error":"POST only"}'; exit 0; }
export LF_HOME LF_TOKEN_FILE="$LF_HOME/.webtoken" LF_RUN="${LF_RUN:-/tmp/lobbyfence}"
export PATH="$PATH:/usr/sbin:/sbin:/usr/bin:/bin"
exec /bin/sh "$LF_HOME/share/lobbyfence-cgi.sh"
