#!/bin/sh
# LobbyFence installer for DD-WRT (Broadcom ARM routers such as the Netgear R7000, JFFS)
#
#   sh install.sh            install or update (settings and learned servers are kept)
#   sh install.sh remove     uninstall, keep settings and learned servers on JFFS
#   sh install.sh purge      uninstall and delete everything, settings included
#
# Run it on the router from the unpacked folder, e.g.
#   sh /tmp/lobbyfence-install/ddwrt/install.sh
# A copy stays in the install folder for uninstalling later:
#   sh /jffs/lobbyfence/install.sh remove
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
JFFS="${LF_JFFS:-/jffs}"
DEST="$JFFS/lobbyfence"
HOOKS="$JFFS/etc/config"
RUN=/tmp/lobbyfence
NVRAM="${LF_NVRAM:-nvram}"
MYPAGE="$DEST/mypage.sh"

have() { type "$1" >/dev/null 2>&1; }
say() { echo "lobbyfence: $*"; }
die() { echo "lobbyfence: ERROR: $*" >&2; exit 1; }

# file in the package : place under $DEST : mode
FILES="
files/usr/sbin/lobbyfence:bin/lobbyfence-main:755
files/usr/share/lobbyfence/lobbyfence.awk:share/lobbyfence.awk:644
files/usr/share/lobbyfence/fw-ipt.sh:share/fw-ipt.sh:644
files/usr/share/lobbyfence/fw-ddwrt.sh:share/fw-ddwrt.sh:644
freshtomato/functions.sh:share/functions.sh:644
freshtomato/conf.awk:share/conf.awk:644
freshtomato/www/lobbyfence.cgi:share/lobbyfence-cgi.sh:755
ddwrt/lobbyfence:lobbyfence:755
ddwrt/mypage.sh:mypage.sh:755
ddwrt/www/index.html:www/index.html:644
ddwrt/www/cgi-bin/lobbyfence.cgi:www/cgi-bin/lobbyfence.cgi:755
ddwrt/www/lobbyfence/manifest.json:www/lobbyfence/manifest.json:644
freshtomato/www/lobbyfence/lf-shim.js:www/lobbyfence/lf-shim.js:644
freshtomato/www/lobbyfence/settings.js:www/lobbyfence/settings.js:644
freshtomato/www/lobbyfence/lf-app.js:www/lobbyfence/lf-app.js:644
app-icon/icon-192.png:www/lobbyfence/icon-192.png:644
app-icon/icon-512.png:www/lobbyfence/icon-512.png:644
app-icon/icon-maskable-512.png:www/lobbyfence/icon-maskable-512.png:644
app-icon/apple-touch-icon.png:www/lobbyfence/apple-touch-icon.png:644
app-icon/favicon-32.png:www/lobbyfence/favicon-32.png:644
luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js:www/lobbyfence/map.js:644
ddwrt/install.sh:install.sh:755
"

# Status > My Page: DD-WRT runs the scripts listed in nvram mypage_scripts
mypage_add() {
	local l
	l="$($NVRAM get mypage_scripts 2>/dev/null)"
	case " $l " in *" $MYPAGE "*) return 0;; esac
	$NVRAM set mypage_scripts="$(echo "$l $MYPAGE" | sed 's/^ *//')" && $NVRAM commit >/dev/null 2>&1
}
mypage_remove() {
	local l n
	l="$($NVRAM get mypage_scripts 2>/dev/null)"
	case " $l " in *" $MYPAGE "*) ;; *) return 0;; esac
	n="$(echo " $l " | sed "s# $MYPAGE # #g; s/^ *//; s/ *\$//")"
	if [ -n "$n" ]; then $NVRAM set mypage_scripts="$n"; else $NVRAM unset mypage_scripts; fi
	$NVRAM commit >/dev/null 2>&1
}
# which My Page entry is ours (DD-WRT's menu opens the first one)
mypage_url() {
	local i=0 s
	for s in $($NVRAM get mypage_scripts 2>/dev/null); do
		i=$((i + 1))
		[ "$s" = "$MYPAGE" ] && { [ "$i" = 1 ] && echo "MyPage.asp" || echo "MyPage.asp?$i"; return; }
	done
	echo "MyPage.asp"
}

hooks_remove() {
	rm -f "$HOOKS/lobbyfence.startup" "$HOOKS/lobbyfence.firewall" "$HOOKS/K90lobbyfence"
}

# ---------------------------------------------- RegionGate, LobbyFence's old name
# An install under the old name is switched off and removed. Its settings,
# learned servers, web page token and port move over - unless LobbyFence
# already has settings of its own: then the old ones stay where they are.
OLD="$JFFS/regiongate"

# option data_dir '<old>[/...]' -> '<new>[/...]' (a folder chosen elsewhere stays)
move_data_dir() { # config-file old new
	cp -p "$1" "$1.new" && awk -v o="$2" -v n="$3" '
		$1 == "option" && $2 == "data_dir" {
			v = $0; sub(/^[ \t]*option[ \t]+data_dir[ \t]+/, "", v); sub(/[ \t]+$/, "", v)
			q = substr(v, 1, 1)
			if ((q == "\047" || q == "\"") && length(v) > 1 && substr(v, length(v)) == q) v = substr(v, 2, length(v) - 2)
			if (v == o || index(v, o "/") == 1) {
				match($0, /^[ \t]*/)
				print substr($0, 1, RLENGTH) "option data_dir \047" n substr(v, length(o) + 1) "\047"
				next
			}
		}
		{ print }' "$1" > "$1.new" && mv "$1.new" "$1" || { rm -f "$1.new"; return 1; }
}

# the old folder's settings and data into $DEST; its programs are removed
# (the new ones are copied in next)
migrate_files() {
	local f
	rm -rf "$OLD/bin" "$OLD/share" "$OLD/www" "$OLD/regiongate" "$OLD/mypage.sh"
	if [ -f "$DEST/lobbyfence.conf" ]; then
		rm -rf "$OLD/modules" "$OLD/netem"
		say "LobbyFence already has settings of its own - RegionGate's were left in $OLD (delete them when you no longer need them: rm -rf $OLD)"
		return 0
	fi
	if [ -f /tmp/regiongate/staged.conf ] && [ ! -f "$RUN/staged.conf" ]; then
		# (changes saved on the web page, not applied yet)
		mkdir -p "$RUN" && mv /tmp/regiongate/staged.conf "$RUN/staged.conf"
	fi
	if [ ! -e "$DEST" ]; then
		mv "$OLD" "$DEST" || die "could not move $OLD to $DEST"
	else
		# a LobbyFence folder without settings (an install that did not finish)
		rmdir "$DEST/data" 2>/dev/null
		for f in "$OLD"/* "$OLD"/.[!.]*; do
			[ -e "$f" ] && [ ! -e "$DEST/${f##*/}" ] && mv "$f" "$DEST/"
		done
		rmdir "$OLD" 2>/dev/null || say "some of RegionGate's files were left in $OLD"
	fi
	if [ -f "$DEST/regiongate.conf" ]; then
		mv "$DEST/regiongate.conf" "$DEST/lobbyfence.conf" || die "could not rename $DEST/regiongate.conf"
		move_data_dir "$DEST/lobbyfence.conf" "$OLD" "$DEST" || say "warning: could not update data_dir in $DEST/lobbyfence.conf"
	fi
	say "settings, learned servers and the web page's sign-in moved to $DEST"
}

migrate_regiongate() {
	local l n d
	[ -d "$OLD" ] || return 0
	[ -f "$DEST/lobbyfence.conf" ] && [ ! -e "$OLD/regiongate" ] && return 0   # (told on an earlier run)
	say "found RegionGate (LobbyFence's old name) in $OLD - moving it over to LobbyFence"
	rm -f /tmp/cron.d/regiongate
	# (it saves its learned servers, takes its rules out and stops its web page)
	[ -x "$OLD/regiongate" ] && RG_HOME="$OLD" "$OLD/regiongate" stop >/dev/null 2>&1
	# (a web server an older version left running would hold the page's port)
	for d in /proc/[0-9]*; do
		case "$(tr '\000' ' ' 2>/dev/null < "$d/cmdline")" in
			"lighttpd -f /tmp/regiongate/lighttpd.conf "|*"/lighttpd -f /tmp/regiongate/lighttpd.conf ") kill "${d#/proc/}" 2>/dev/null;;
		esac
	done
	rm -f "$HOOKS/regiongate.startup" "$HOOKS/regiongate.firewall" "$HOOKS/K90regiongate"
	# Status > My Page: the old entry becomes LobbyFence's, in the same place
	l="$($NVRAM get mypage_scripts 2>/dev/null)"
	case " $l " in
		*" $OLD/mypage.sh "*)
			n="$(echo " $l " | sed "s# $OLD/mypage.sh # $MYPAGE #g" | \
				awk '{ o = ""; for (i = 1; i <= NF; i++) if (!s[$i]++) o = o (o == "" ? "" : " ") $i; print o }')"
			$NVRAM set mypage_scripts="$n" && $NVRAM commit >/dev/null 2>&1;;
	esac
	migrate_files
	rm -rf /tmp/regiongate
}

# Anything of LobbyFence's still running is stopped before its files go - a
# start or firewall hook waiting for its turn would otherwise put the filter
# back after the uninstall (until the next reboot).
lf_kill() {
	local d c n=0 left
	while :; do
		left=""
		for d in /proc/[0-9]*; do
			[ "${d#/proc/}" = "$$" ] && continue
			c="$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)"
			case "$c" in
				*"$DEST/bin/"*|*"$DEST/share/"*|*"$DEST/lobbyfence "*|*"$DEST/lobbyfence") left="$left ${d#/proc/}";;
			esac
		done
		[ -n "$left" ] || return 0
		# shellcheck disable=SC2086
		if [ "$n" -lt 10 ]; then kill $left 2>/dev/null; else kill -9 $left 2>/dev/null; fi
		[ "$n" -ge 12 ] && return 0
		n=$((n + 1))
		sleep 1
	done
}

# LobbyFence's firewall rules, sets and lag queues - also when the program
# that would take them out is gone already (an earlier "remove")
fw_leftovers() {
	local cmd t c b n d
	for cmd in iptables ip6tables; do
		have "$cmd" || continue
		for t in filter mangle; do
			for c in $($cmd -t "$t" -S 2>/dev/null | awk '$1 == "-N" && $2 ~ /^LF_/ { print $2 }'); do
				for b in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
					while $cmd -t "$t" -D "$b" -j "$c" 2>/dev/null; do :; done
				done
				$cmd -t "$t" -F "$c" 2>/dev/null
			done
			for c in $($cmd -t "$t" -S 2>/dev/null | awk '$1 == "-N" && $2 ~ /^LF_/ { print $2 }'); do
				$cmd -t "$t" -X "$c" 2>/dev/null
			done
		done
	done
	if have ipset; then
		for n in $(ipset list -n 2>/dev/null | grep '^lf_'); do ipset destroy "$n" 2>/dev/null; done
	fi
	if have tc; then
		for d in /sys/class/net/*; do
			d="${d##*/}"
			tc qdisc show dev "$d" 2>/dev/null | grep -q '^qdisc prio 7a: root' && tc qdisc del dev "$d" root 2>/dev/null
		done
	fi
	return 0
}

uninstall() {
	[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" stop >/dev/null 2>&1
	lf_kill
	fw_leftovers
	hooks_remove
	mypage_remove
	rm -f /tmp/cron.d/lobbyfence
	rm -rf "$RUN"
	if [ "$1" = purge ]; then
		rm -rf "$DEST"
		say "removed, including settings and learned servers"
	else
		rm -rf "$DEST/bin" "$DEST/share" "$DEST/www" "$DEST/lobbyfence" "$DEST/mypage.sh"
		say "removed - settings and learned servers are still in $DEST (sh $DEST/install.sh purge deletes them)"
	fi
}

case "${1:-install}" in
	remove|uninstall) uninstall keep; exit 0;;
	purge) uninstall purge; exit 0;;
	install) ;;
	*) die "usage: sh install.sh [remove|purge]";;
esac

# ---------------------------------------------------------------- checks

[ -f "$SRC/files/usr/sbin/lobbyfence" ] || die "run this from the unpacked LobbyFence folder"
[ -n "$($NVRAM get DD_BOARD 2>/dev/null)" ] || [ -n "${LF_FORCE:-}" ] || \
	die "this is not DD-WRT (FreshTomato: freshtomato/install.sh, Asuswrt-Merlin: asuswrt-merlin/install.sh, OpenWrt: install.sh)"
if ! grep -q " $JFFS " /proc/mounts 2>/dev/null && [ -z "${LF_FORCE:-}" ]; then
	die "JFFS is not mounted. Turn it on under Administration > Management > JFFS2 Support (Enable, Clean JFFS2 once, Apply Settings), reboot, then run this again."
fi
for t in iptables iptables-restore ipset awk; do
	have "$t" || die "'$t' is missing - this DD-WRT build is not supported (use a recent build for your router)"
done
have curl || have wget || die "neither curl nor wget found"
if ! ipset list -n >/dev/null 2>&1; then
	die "the kernel's ipset support is missing - use a newer DD-WRT build"
fi
have lighttpd || [ -n "${LF_LIGHTTPD:-}" ] || say "note: this build has no lighttpd - the filter works, but there is no web page (set it up over SSH)"
have tc || [ -x /usr/sbin/tc ] || [ -n "${LF_TC:-}" ] || say "note: no tc - the lag simulator is not available"

# ---------------------------------------------------------------- install

migrate_regiongate

# a running copy saves its learned servers and steps aside first
if [ -x "$DEST/lobbyfence" ]; then
	say "updating - stopping the running copy"
	"$DEST/lobbyfence" stop >/dev/null 2>&1
fi

mkdir -p "$DEST/bin" "$DEST/share" "$DEST/www/lobbyfence" "$DEST/www/cgi-bin" "$DEST/data" "$HOOKS" || die "cannot write to $DEST"
echo "$FILES" | while IFS=: read -r src dst mode; do
	[ -n "$src" ] || continue
	[ -f "$SRC/$src" ] || { echo "missing $src" >&2; exit 1; }
	cp "$SRC/$src" "$DEST/$dst.new" && chmod "$mode" "$DEST/$dst.new" && mv "$DEST/$dst.new" "$DEST/$dst" || exit 1
done || die "copying the files failed (JFFS full?)"

# a new version number in the page addresses, so browsers fetch the new files;
# where LobbyFence lives, for the scripts the web servers run (they get no environment)
v="$(date +%s)"
sed -i "s/@LFVER@/$v/g" "$DEST/www/index.html"
sed -i "s#@LFHOME@#$DEST#g" "$DEST/mypage.sh" "$DEST/www/cgi-bin/lobbyfence.cgi"

if [ ! -f "$DEST/lobbyfence.conf" ]; then
	cp "$SRC/freshtomato/lobbyfence.conf" "$DEST/lobbyfence.conf"
	sed -i "s#option data_dir .*#option data_dir '$DEST/data'#" "$DEST/lobbyfence.conf"
fi

# DD-WRT runs /jffs/etc/config/*.startup at boot, *.firewall after every
# firewall rebuild and K<nn>* before shutting down (and waits for each)
cat > "$HOOKS/lobbyfence.startup" <<EOF
#!/bin/sh
# LobbyFence: start at boot
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" start </dev/null >/dev/null 2>&1 &
EOF
cat > "$HOOKS/lobbyfence.firewall" <<EOF
#!/bin/sh
# LobbyFence: put the filter rules back after DD-WRT rebuilt its firewall
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" fwhook
EOF
cat > "$HOOKS/K90lobbyfence" <<EOF
#!/bin/sh
# LobbyFence: save the learned servers before shutting down
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" stop </dev/null >/dev/null 2>&1
EOF
chmod 755 "$HOOKS/lobbyfence.startup" "$HOOKS/lobbyfence.firewall" "$HOOKS/K90lobbyfence"

mypage_add || say "warning: could not add LobbyFence to Status > My Page"

[ -n "${LF_NOSTART:-}" ] || "$DEST/lobbyfence" start >/dev/null 2>&1 || say "warning: start reported a problem - see Status > Syslog"

say "installed in $DEST"
say "open the router's page, then Status > My Page ($(mypage_url)) - it takes you to LobbyFence"
