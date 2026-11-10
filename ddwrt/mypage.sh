#!/bin/sh
# LobbyFence for DD-WRT - its entry in the router's Status > My Page.
# DD-WRT's web server runs this (only for a signed-in user) and shows what it
# prints. It hands the browser the sign-in token for LobbyFence's own page
# (after the "#", so it never goes over the network) and opens that page.
# SPDX-License-Identifier: GPL-3.0-or-later

LF_HOME="${LF_HOME:-@LFHOME@}"
PORT="$(cat "$LF_HOME/.webport" 2>/dev/null)"
# (a port number, 1-65535 - anything else is not used, as by LobbyFence's web server)
case "$PORT" in [1-9]|[1-9][0-9]|[1-9][0-9][0-9]|[1-9][0-9][0-9][0-9]|[1-9][0-9][0-9][0-9][0-9]) ;; *) PORT=8055;; esac
[ "$PORT" -le 65535 ] || PORT=8055
TOKEN="$(cat "$LF_HOME/.webtoken" 2>/dev/null | tr -cd '0-9a-f')"
RUNNING=0
RUN="${LF_RUN:-/tmp/lobbyfence}"
# LobbyFence's web server: exactly "lighttpd -f <its configuration>" (the pid
# file can name another program by now, if the server died)
ours() {
	case "$(tr '\000' ' ' 2>/dev/null < "/proc/$1/cmdline")" in
		"lighttpd -f $RUN/lighttpd.conf "|*"/lighttpd -f $RUN/lighttpd.conf ") return 0;;
	esac
	return 1
}
p="$(cat "$RUN/lighttpd.pid" 2>/dev/null | tr -cd '0-9')"
[ -n "$p" ] && ours "$p" && RUNNING=1
if [ "$RUNNING" != 1 ]; then
	# (no pid file: look for it in the process list)
	for d in /proc/[0-9]*; do
		ours "${d#/proc/}" && { RUNNING=1; break; }
	done
fi

cat <<EOF
<div id="lf-mypage" style="font:15px/1.5 -apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:640px;margin:24px auto;padding:18px 20px;border:1px solid #c9d1dc;border-radius:10px;background:#fff;color:#1f2933">
<h2 style="margin:0 0 8px;font-size:20px">LobbyFence</h2>
EOF
if [ -z "$TOKEN" ] || [ "$RUNNING" != 1 ]; then
	cat <<EOF
<p>LobbyFence's page is not running. Over SSH: <code>$LF_HOME/lobbyfence restart</code>
(the reason is in Status &gt; Syslog, lines with "lobbyfence").</p>
</div>
EOF
	exit 0
fi
cat <<EOF
<p id="lf-msg">Opening LobbyFence&hellip;</p>
<p><a id="lf-go" href="#" style="display:inline-block;padding:10px 18px;border-radius:8px;background:#1f6fd1;color:#fff;font-weight:600;text-decoration:none">Open LobbyFence &#x2197;</a></p>
<p style="color:#6b7785;font-size:13px">LobbyFence runs on port $PORT of this router. On a phone you can add it to the home screen from there.</p>
</div>
<script>
(function() {
	var url = 'http://' + location.hostname.replace(/^\[?(.*?)\]?$/, function(m, h) { return h.indexOf(':') >= 0 ? '[' + h + ']' : h; }) +
		':$PORT/#t=$TOKEN';
	/* and where the router's own pages are (http or https, their port): LobbyFence's "Router" link leads back here */
	url += '&r=' + encodeURIComponent(location.protocol + '//' + location.host);
	var a = document.getElementById('lf-go');
	a.href = url;
	/* straight on, unless this page is shown inside another one */
	if (window.top === window.self) location.replace(url);
	else { a.target = '_blank'; document.getElementById('lf-msg').textContent = 'LobbyFence opens in a new tab:'; }
})();
</script>
EOF
