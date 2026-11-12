#!/bin/sh
# LobbyFence installer for FreshTomato (ARM routers, JFFS)
#
#   sh install.sh            install or update (settings and learned servers are kept)
#   sh install.sh remove     uninstall, keep settings and learned servers on JFFS
#   sh install.sh purge      uninstall and delete everything, settings included
#
# Run it on the router from the unpacked folder, e.g.
#   sh /tmp/lobbyfence-install/freshtomato/install.sh
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
WWWEXT="${LF_WWWEXT:-/tmp/var/wwwext}"

have() { type "$1" >/dev/null 2>&1; }
say() { echo "lobbyfence: $*"; }
die() { echo "lobbyfence: ERROR: $*" >&2; exit 1; }

# file in the package : place under $DEST : mode
FILES="
files/usr/sbin/lobbyfence:bin/lobbyfence-main:755
files/usr/share/lobbyfence/lobbyfence.awk:share/lobbyfence.awk:644
files/usr/share/lobbyfence/servers.txt:share/servers.txt:644
files/usr/share/lobbyfence/server-networks.txt:share/server-networks.txt:644
files/usr/share/lobbyfence/share-games.txt:share/share-games.txt:644
files/usr/share/lobbyfence/fw-ipt.sh:share/fw-ipt.sh:644
freshtomato/functions.sh:share/functions.sh:644
freshtomato/conf.awk:share/conf.awk:644
freshtomato/lobbyfence.conf:share/lobbyfence.conf.default:644
freshtomato/lobbyfence:lobbyfence:755
freshtomato/www/lobbyfence.asp:www/lobbyfence.asp:644
freshtomato/www/lobbyfence.cgi:www/lobbyfence.cgi:755
freshtomato/www/lobbyfence/app.asp:www/lobbyfence/app.asp:644
freshtomato/www/lobbyfence/lf-shim.js:www/lobbyfence/lf-shim.js:644
freshtomato/www/lobbyfence/settings.js:www/lobbyfence/settings.js:644
freshtomato/www/lobbyfence/manifest.txt:www/lobbyfence/manifest.txt:644
freshtomato/www/lobbyfence/lf-app.js:www/lobbyfence/lf-app.js:644
app-icon/icon-192.png:www/lobbyfence/icon-192.png:644
app-icon/icon-512.png:www/lobbyfence/icon-512.png:644
app-icon/icon-maskable-512.png:www/lobbyfence/icon-maskable-512.png:644
app-icon/apple-touch-icon.png:www/lobbyfence/apple-touch-icon.png:644
app-icon/favicon-32.png:www/lobbyfence/favicon-32.png:644
luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js:www/lobbyfence/map.js:644
freshtomato/install.sh:install.sh:755
"

hooks_remove() {
	rm -f "$HOOKS/lobbyfence.init" "$HOOKS/lobbyfence.fire" "$HOOKS/lobbyfence.shut"
}

# the line LobbyFence keeps in the router's Init script to notice a reset to
# factory defaults (see "a reset to factory defaults" in $DEST/lobbyfence) -
# the rest of the script stays as it is
reset_unmark() {
	local nv="${LF_NVRAM:-nvram}" s
	have "$nv" || return 0
	s="$("$nv" get script_init 2>/dev/null)"
	case "$s" in *"# LobbyFence-reset-mark "*) ;; *) return 0;; esac
	s="$(printf '%s\n' "$s" | grep -v '^# LobbyFence-reset-mark ')"
	if [ -n "$s" ]; then "$nv" set script_init="$s"; else "$nv" unset script_init; fi
	"$nv" commit >/dev/null 2>&1
	rm -f "$DEST/.reset-mark" "$DEST/.fresh-start"
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
	[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" menu-off >/dev/null 2>&1
	hooks_remove
	reset_unmark
	rm -f "$WWWEXT/lobbyfence.asp" "$WWWEXT/cgi-bin/lobbyfence.cgi"
	rm -rf "$WWWEXT/lobbyfence" "$RUN"
	if [ "$1" = purge ]; then
		rm -rf "$DEST"
		say "removed, including settings and learned servers"
	else
		rm -rf "$DEST/bin" "$DEST/share" "$DEST/www" "$DEST/lobbyfence"
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
[ -f /www/tomato.js ] || [ -n "${LF_FORCE:-}" ] || die "this is not FreshTomato (for OpenWrt use the install.sh in the main folder)"
if ! grep -q " $JFFS " /proc/mounts 2>/dev/null && [ -z "${LF_FORCE:-}" ]; then
	die "JFFS is not mounted. Turn it on under Administration > JFFS (Enable, then Format/Erase once, Save), then run this again."
fi
for t in iptables iptables-restore ipset awk; do
	have "$t" || die "'$t' is missing - this firmware build is not supported (ARM builds have it)"
done
have curl || have wget || die "neither curl nor wget found"
for m in ip_set ip_set_hash_ip ip_set_hash_net xt_set; do modprobe "$m" >/dev/null 2>&1; done
if ! ipset list -n >/dev/null 2>&1; then
	die "the kernel's ipset support is missing (modules ip_set / xt_set)"
fi

# ---------------------------------------------------------------- install

# a running copy saves its learned servers and steps aside first
if [ -x "$DEST/lobbyfence" ]; then
	say "updating - stopping the running copy"
	"$DEST/lobbyfence" stop >/dev/null 2>&1
fi

mkdir -p "$DEST/bin" "$DEST/share" "$DEST/www/lobbyfence" "$DEST/data" "$HOOKS" || die "cannot write to $DEST"
echo "$FILES" | while IFS=: read -r src dst mode; do
	[ -n "$src" ] || continue
	[ -f "$SRC/$src" ] || { echo "missing $src" >&2; exit 1; }
	cp "$SRC/$src" "$DEST/$dst.new" && chmod "$mode" "$DEST/$dst.new" && mv "$DEST/$dst.new" "$DEST/$dst" || exit 1
done || die "copying the files failed (JFFS full?)"

# a new version number in the page addresses, so browsers fetch the new files
v="$(date +%s)"
sed -i "s/@LFVER@/$v/g" "$DEST/www/lobbyfence.asp" "$DEST/www/lobbyfence/app.asp"

# kernel modules LobbyFence brings (netem for the lag simulator), per kernel version
# (a changed module starts a new trial run - see fw-ipt.sh)
k="$(uname -r)"
cmp -s "$SRC/freshtomato/modules/$k/sch_netem.ko" "$DEST/modules/$k/sch_netem.ko" 2>/dev/null || rm -f "$DEST/.netem-ok"
rm -rf "$DEST/modules"
for d in "$SRC"/freshtomato/modules/*/; do
	[ -f "$d/sch_netem.ko" ] || continue
	k="$(basename "$d")"
	mkdir -p "$DEST/modules/$k" && cp "$d/sch_netem.ko" "$DEST/modules/$k/" || die "copying the netem module failed"
done
[ -f "$DEST/modules/$(uname -r)/sch_netem.ko" ] || say "note: no netem module for kernel $(uname -r) - the lag simulator is not available"

if [ ! -f "$DEST/lobbyfence.conf" ]; then
	cp "$SRC/freshtomato/lobbyfence.conf" "$DEST/lobbyfence.conf"
	sed -i "s#option data_dir .*#option data_dir '$DEST/data'#" "$DEST/lobbyfence.conf"
fi

# FreshTomato runs /jffs/etc/config/*.init at boot, *.fire after every
# firewall rebuild and *.shut before shutting down
cat > "$HOOKS/lobbyfence.init" <<EOF
#!/bin/sh
# LobbyFence: start at boot
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" start </dev/null >/dev/null 2>&1 &
EOF
cat > "$HOOKS/lobbyfence.fire" <<EOF
#!/bin/sh
# LobbyFence: put the filter rules back after FreshTomato rebuilt its firewall
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" fwhook
EOF
cat > "$HOOKS/lobbyfence.shut" <<EOF
#!/bin/sh
# LobbyFence: save the learned servers before shutting down
[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" stop </dev/null >/dev/null 2>&1
EOF
chmod 755 "$HOOKS/lobbyfence.init" "$HOOKS/lobbyfence.fire" "$HOOKS/lobbyfence.shut"

[ -n "${LF_NOSTART:-}" ] || "$DEST/lobbyfence" start >/dev/null 2>&1 || say "warning: start reported a problem - see Status > Logs"

[ -n "${LF_NOSTART:-}" ] || "$DEST/lobbyfence" menu 2>&1 | sed 's/^/lobbyfence: menu: /'
say "installed in $DEST"
say "open http://$(nvram get lan_ipaddr 2>/dev/null || echo '<router>')/ext/lobbyfence.asp (also in the menu as LobbyFence)"
