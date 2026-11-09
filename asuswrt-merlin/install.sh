#!/bin/sh
# LobbyFence installer for Asuswrt-Merlin (ASUS RT-AX / GT-AX and newer)
#
#   sh install.sh            install or update (settings and learned servers are kept)
#   sh install.sh remove     uninstall, keep settings and learned servers on JFFS
#   sh install.sh purge      uninstall and delete everything, settings included
#
# Run it on the router from the unpacked folder, e.g.
#   sh /tmp/lobbyfence-install/asuswrt-merlin/install.sh
# A copy stays in the install folder for uninstalling later:
#   sh /jffs/addons/lobbyfence/install.sh remove
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -u
SRC="$(cd "$(dirname "$0")/.." && pwd)"
JFFS="${LF_JFFS:-/jffs}"
DEST="$JFFS/addons/lobbyfence"
SCRIPTS="$JFFS/scripts"
RUN=/tmp/lobbyfence
MARK="# LobbyFence"

have() { type "$1" >/dev/null 2>&1; }
say() { echo "lobbyfence: $*"; }
die() { echo "lobbyfence: ERROR: $*" >&2; exit 1; }

# file in the package : place under $DEST : mode
FILES="
files/usr/sbin/lobbyfence:bin/lobbyfence-main:755
files/usr/share/lobbyfence/lobbyfence.awk:share/lobbyfence.awk:644
files/usr/share/lobbyfence/servers.txt:share/servers.txt:644
files/usr/share/lobbyfence/fw-ipt.sh:share/fw-ipt.sh:644
files/usr/share/lobbyfence/fw-merlin.sh:share/fw-merlin.sh:644
freshtomato/functions.sh:share/functions.sh:644
freshtomato/conf.awk:share/conf.awk:644
asuswrt-merlin/lobbyfence:lobbyfence:755
asuswrt-merlin/bin/lf-lagd:bin/lf-lagd:755
asuswrt-merlin/netem/gt-axe16000-4.19.183/sch_netem.ko:netem/gt-axe16000-4.19.183/sch_netem.ko:644
asuswrt-merlin/netem/gt-ax6000-4.19.183/sch_netem.ko:netem/gt-ax6000-4.19.183/sch_netem.ko:644
asuswrt-merlin/netem/gt-ax11000_pro-4.19.183/sch_netem.ko:netem/gt-ax11000_pro-4.19.183/sch_netem.ko:644
asuswrt-merlin/netem/rt-ax86u_pro-4.19.183/sch_netem.ko:netem/rt-ax86u_pro-4.19.183/sch_netem.ko:644
asuswrt-merlin/netem/rt-ax88u_pro-4.19.183/sch_netem.ko:netem/rt-ax88u_pro-4.19.183/sch_netem.ko:644
asuswrt-merlin/netem/xt12-4.19.183/sch_netem.ko:netem/xt12-4.19.183/sch_netem.ko:644
asuswrt-merlin/www/lobbyfence.asp:www/lobbyfence.asp:644
asuswrt-merlin/www/lobbyfence/app.asp:www/lobbyfence/app.asp:644
asuswrt-merlin/www/lobbyfence/lf-merlin.js:www/lobbyfence/lf-merlin.js:644
freshtomato/www/lobbyfence/lf-shim.js:www/lobbyfence/lf-shim.js:644
freshtomato/www/lobbyfence/settings.js:www/lobbyfence/settings.js:644
asuswrt-merlin/www/lobbyfence/manifest.json:www/lobbyfence/manifest.json:644
freshtomato/www/lobbyfence/lf-app.js:www/lobbyfence/lf-app.js:644
app-icon/icon-192.png:www/lobbyfence/icon-192.png:644
app-icon/icon-512.png:www/lobbyfence/icon-512.png:644
app-icon/icon-maskable-512.png:www/lobbyfence/icon-maskable-512.png:644
app-icon/apple-touch-icon.png:www/lobbyfence/apple-touch-icon.png:644
app-icon/favicon-32.png:www/lobbyfence/favicon-32.png:644
luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js:www/lobbyfence/map.js:644
asuswrt-merlin/install.sh:install.sh:755
"

# the lines LobbyFence adds to Merlin's user scripts (between other add-ons' lines)
hook_line() { # script
	case "$1" in
		services-start) echo "[ -x $DEST/lobbyfence ] && $DEST/lobbyfence start </dev/null >/dev/null 2>&1 & $MARK";;
		firewall-start) echo "[ -x $DEST/lobbyfence ] && $DEST/lobbyfence fwhook $MARK";;
		service-event) echo "[ -x $DEST/lobbyfence ] && $DEST/lobbyfence service-event \"\$1\" \"\$2\" $MARK";;
		services-stop) echo "[ -x $DEST/lobbyfence ] && $DEST/lobbyfence stop </dev/null >/dev/null 2>&1 $MARK";;
	esac
}
HOOKS="services-start firewall-start service-event services-stop"

hooks_remove() {
	local h
	for h in $HOOKS; do
		[ -f "$SCRIPTS/$h" ] || continue
		sed -i "/$MARK\$/d" "$SCRIPTS/$h"
		# a script LobbyFence made (nothing left but its first line) goes too
		grep -v -e '^#!' -e '^[[:space:]]*$' "$SCRIPTS/$h" | grep -q . || rm -f "$SCRIPTS/$h"
	done
}

hooks_add() {
	local h
	mkdir -p "$SCRIPTS" || return 1
	hooks_remove
	for h in $HOOKS; do
		[ -f "$SCRIPTS/$h" ] || printf '#!/bin/sh\n' > "$SCRIPTS/$h"
		# a script without its first line (#!/bin/sh) would not run
		head -n 1 "$SCRIPTS/$h" | grep -q '^#!' || sed -i '1i #!/bin/sh' "$SCRIPTS/$h"
		# a script ending in "exit" would never reach a line after it: ours goes before
		hook_line "$h" > "$SCRIPTS/.lf.line"
		awk -v f="$SCRIPTS/.lf.line" 'BEGIN { getline l < f } { a[++n] = $0 }
			END { e = n; while (e > 0 && a[e] ~ /^[ \t]*$/) e--
			      for (i = 1; i <= n; i++) { if (i == e && a[e] ~ /^[ \t]*exit([ \t;].*)?$/) print l; print a[i] }
			      if (!(e > 0 && a[e] ~ /^[ \t]*exit([ \t;].*)?$/)) print l }' "$SCRIPTS/$h" > "$SCRIPTS/.lf.new" && \
			cat "$SCRIPTS/.lf.new" > "$SCRIPTS/$h"
		rm -f "$SCRIPTS/.lf.line" "$SCRIPTS/.lf.new"
		grep -n '^[[:space:]]*exit\b' "$SCRIPTS/$h" | grep -qv "$(grep -n "$MARK\$" "$SCRIPTS/$h" | cut -d: -f1):" && \
			awk -v m="$MARK" '/^[ \t]*exit([ \t;].*)?$/ { x = NR } index($0, m) { r = NR } END { exit !(x && r && x < r) }' "$SCRIPTS/$h" && \
			say "warning: $SCRIPTS/$h has an 'exit' before LobbyFence's line - LobbyFence's line may never run there"
		chmod 755 "$SCRIPTS/$h"
	done
}

# ---------------------------------------------- RegionGate, LobbyFence's old name
# An install under the old name is switched off and removed. Its settings and
# learned servers move over - unless LobbyFence already has settings of its
# own: then the old ones stay where they are.
OLD="$JFFS/addons/regiongate"

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
	say "settings and learned servers moved to $DEST"
}

migrate_regiongate() {
	local h
	[ -d "$OLD" ] || return 0
	[ -f "$DEST/lobbyfence.conf" ] && [ ! -e "$OLD/regiongate" ] && return 0   # (told on an earlier run)
	say "found RegionGate (LobbyFence's old name) in $OLD - moving it over to LobbyFence"
	have cru && cru d regiongate
	if [ -x "$OLD/regiongate" ]; then
		# (it saves its learned servers, takes its rules out and frees its web page slot and tab)
		RG_HOME="$OLD" "$OLD/regiongate" stop >/dev/null 2>&1
		RG_HOME="$OLD" "$OLD/regiongate" web-remove >/dev/null 2>&1
	fi
	for h in $HOOKS; do
		[ -f "$SCRIPTS/$h" ] && sed -i '/# RegionGate$/d' "$SCRIPTS/$h"
	done
	[ -f "$JFFS/addons/custom_settings.txt" ] && sed -i '/^regiongate_/d' "$JFFS/addons/custom_settings.txt"
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
	[ -x "$DEST/lobbyfence" ] && "$DEST/lobbyfence" web-remove >/dev/null 2>&1
	hooks_remove
	rm -rf "$RUN"
	have cru && cru d lobbyfence
	# the page's requests to the router (add-on settings file): none left behind
	[ -f "$JFFS/addons/custom_settings.txt" ] && sed -i '/^lobbyfence_/d' "$JFFS/addons/custom_settings.txt"
	if [ "$1" = purge ]; then
		rm -rf "$DEST"
		say "removed, including settings and learned servers"
	else
		rm -rf "$DEST/bin" "$DEST/share" "$DEST/www" "$DEST/netem" "$DEST/lobbyfence"
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
if [ -z "${LF_FORCE:-}" ]; then
	have nvram || die "this is not Asuswrt-Merlin (for OpenWrt use the install.sh in the main folder)"
	nvram get rc_support 2>/dev/null | grep -qw am_addons || \
		die "this firmware has no add-on support - Asuswrt-Merlin 384.15 or newer is needed (stock ASUS firmware can't run add-ons)"
	grep -q " $JFFS " /proc/mounts 2>/dev/null || die "JFFS is not mounted. Turn it on under Administration > System > Persistent JFFS2 partition, reboot, then run this again."
	# older Wi-Fi 5 models (kernel 2.6, CTF acceleration) are not supported:
	# their acceleration would let game traffic skip the filter
	case "$(uname -r)" in
		2.*|3.*) die "this router's platform is not supported (kernel $(uname -r): an older Wi-Fi 5 model). LobbyFence on Asuswrt-Merlin needs a Wi-Fi 6 / 6E / 7 model (RT-AX..., GT-AX..., RT-BE...). Many older ASUS models can run FreshTomato instead, which LobbyFence supports.";;
	esac
fi
for t in iptables iptables-restore ipset awk; do
	have "$t" || die "'$t' is missing - this firmware build is not supported"
done
have curl || have wget || die "neither curl nor wget found"
for m in ip_set ip_set_hash_ip ip_set_hash_net xt_set; do modprobe "$m" >/dev/null 2>&1; done
ipset list -n >/dev/null 2>&1 || die "the kernel's ipset support is missing (modules ip_set / xt_set)"

# Merlin runs /jffs/scripts only with "Enable JFFS custom scripts and configs" on
if have nvram && [ "$(nvram get jffs2_scripts 2>/dev/null)" != 1 ]; then
	nvram set jffs2_scripts=1 && nvram commit
	say "switched on 'Enable JFFS custom scripts and configs' (Administration > System) - LobbyFence starts from them"
fi

# ---------------------------------------------------------------- install

migrate_regiongate

if [ -x "$DEST/lobbyfence" ]; then
	say "updating - stopping the running copy"
	"$DEST/lobbyfence" stop >/dev/null 2>&1
	# its page and tab go too: Merlin's helper finds a page's slot by its
	# text, which the update changes - the old page would keep its slot (of
	# the 20 all add-ons share) and the menu would show LobbyFence twice
	"$DEST/lobbyfence" web-remove >/dev/null 2>&1
fi

mkdir -p "$DEST/bin" "$DEST/share" "$DEST/www/lobbyfence" "$DEST/data" || die "cannot write to $DEST"
# the netem modules of this package only (a model dropped from it goes too);
# a new module starts a new trial by itself (.netem-ok names the module), and
# the record of a restart while netem was in use (.netem-loading) stays
rm -rf "$DEST/netem"
echo "$FILES" | while IFS=: read -r src dst mode; do
	[ -n "$src" ] || continue
	[ -f "$SRC/$src" ] || { echo "missing $src" >&2; exit 1; }
	mkdir -p "$(dirname "$DEST/$dst")" || exit 1
	cp "$SRC/$src" "$DEST/$dst.new" && chmod "$mode" "$DEST/$dst.new" && mv "$DEST/$dst.new" "$DEST/$dst" || exit 1
done || die "copying the files failed (JFFS full?)"

# a new version number in the page addresses, so browsers fetch the new files
v="$(date +%s)"
sed -i "s/@LFVER@/$v/g" "$DEST/www/lobbyfence.asp" "$DEST/www/lobbyfence/app.asp"

if [ ! -f "$DEST/lobbyfence.conf" ]; then
	cp "$SRC/freshtomato/lobbyfence.conf" "$DEST/lobbyfence.conf"
	sed -i "s#option data_dir .*#option data_dir '$DEST/data'#" "$DEST/lobbyfence.conf"
fi

hooks_add || die "cannot write to $SCRIPTS"

[ -n "${LF_NOSTART:-}" ] || "$DEST/lobbyfence" start >/dev/null 2>&1 || say "warning: start reported a problem - see System Log"
[ -n "${LF_NOSTART:-}" ] || "$DEST/lobbyfence" menu 2>&1 | sed 's/^/lobbyfence: menu: /'
say "installed in $DEST"
if have nvram; then
	m="$(nvram get productid 2>/dev/null | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
	o="$(nvram get odmpid 2>/dev/null | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
	if [ -f "$DEST/netem/$m-$(uname -r)/sch_netem.ko" ] || { [ -n "$o" ] && [ -f "$DEST/netem/$o-$(uname -r)/sch_netem.ko" ]; }; then
		say "lag simulator: netem module for this $(nvram get productid) (kernel $(uname -r)) included - it is self-tested before first use"
	else
		say "lag simulator: uses LobbyFence's lf-lagd on this model (netem is only included for: $(ls "$DEST/netem" 2>/dev/null | sed 's/-[0-9][0-9.]*$//' | tr '\n' ' '))"
	fi
fi
page="$(cat "$RUN/webui_page" 2>/dev/null)"
say "open http://$(nvram get lan_ipaddr 2>/dev/null || echo '<router>')/${page:-userN.asp} (also in the menu: Administration > LobbyFence tab)"
