#!/bin/sh
# LobbyFence installer for OpenWrt 23.05+ (fw4 / nftables)
#
#   sh install.sh               install or update from this folder (after copying it to the router)
#   sh install.sh --uninstall   remove LobbyFence (keeps /etc/lobbyfence unless --purge)
#
# A copy stays on the router for uninstalling later:
#   sh /usr/share/lobbyfence/install.sh --uninstall [--purge]
#
# To install straight from the repository, set LF_SOURCE to its raw base URL:
#   LF_SOURCE=https://raw.githubusercontent.com/Femto-Gurifisu/Lobbyfence/main sh install.sh
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -e

FILES="
files/etc/init.d/lobbyfence:/etc/init.d/lobbyfence:755
files/usr/sbin/lobbyfence:/usr/sbin/lobbyfence:755
files/usr/share/lobbyfence/lobbyfence.awk:/usr/share/lobbyfence/lobbyfence.awk:644
files/usr/share/lobbyfence/fw-nft.sh:/usr/share/lobbyfence/fw-nft.sh:644
files/usr/share/lobbyfence/servers.txt:/usr/share/lobbyfence/servers.txt:644
files/lib/upgrade/keep.d/lobbyfence:/lib/upgrade/keep.d/lobbyfence:644
luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/zones.js:/www/luci-static/resources/view/lobbyfence/zones.js:644
luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js:/www/luci-static/resources/view/lobbyfence/map.js:644
luci-app-lobbyfence/root/usr/share/luci/menu.d/luci-app-lobbyfence.json:/usr/share/luci/menu.d/luci-app-lobbyfence.json:644
luci-app-lobbyfence/root/usr/share/rpcd/acl.d/luci-app-lobbyfence.json:/usr/share/rpcd/acl.d/luci-app-lobbyfence.json:644
luci-app-lobbyfence/htdocs/luci-static/lobbyfence/manifest.json:/www/luci-static/lobbyfence/manifest.json:644
freshtomato/www/lobbyfence/lf-app.js:/www/luci-static/lobbyfence/lf-app.js:644
app-icon/icon-192.png:/www/luci-static/lobbyfence/icon-192.png:644
app-icon/icon-512.png:/www/luci-static/lobbyfence/icon-512.png:644
app-icon/icon-maskable-512.png:/www/luci-static/lobbyfence/icon-maskable-512.png:644
app-icon/apple-touch-icon.png:/www/luci-static/lobbyfence/apple-touch-icon.png:644
app-icon/favicon-32.png:/www/luci-static/lobbyfence/favicon-32.png:644
install.sh:/usr/share/lobbyfence/install.sh:755
"
CONFIG_SRC="files/etc/config/lobbyfence"
HERE="$(cd "$(dirname "$0")" && pwd)"

say() { echo "lobbyfence: $*"; }
fail() { echo "lobbyfence: $*" >&2; exit 1; }

fetch() { # url dest
	if command -v uclient-fetch >/dev/null 2>&1; then
		uclient-fetch -q -O "$2" "$1"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL -o "$2" "$1"
	else
		wget -q -O "$2" "$1"
	fi
}

get() { # repo-relative path, destination
	if [ -n "$LF_SOURCE" ]; then
		fetch "$LF_SOURCE/$1" "$2.tmp" || fail "download of $1 failed"
		mv "$2.tmp" "$2"
	else
		[ -f "$HERE/$1" ] || fail "missing $HERE/$1 - run this script from the LobbyFence directory or set LF_SOURCE"
		cp "$HERE/$1" "$2"
	fi
}

# ---------------------------------------------- RegionGate, LobbyFence's old name
# An install under the old name is switched off and removed. Its settings,
# learned servers and changes waiting in LuCI move over - unless LobbyFence
# already has settings of its own: then the old ones stay where they are.
OLD_CONF=/etc/config/regiongate
OLD_DATA=/etc/regiongate

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

migrate_regiongate() {
	local f d p
	# (old settings left next to LobbyFence's own on an earlier run: nothing to do)
	if [ ! -e /etc/init.d/regiongate ] && [ ! -e /usr/sbin/regiongate ]; then
		[ -f /etc/config/lobbyfence ] && return 0
		[ -f "$OLD_CONF" ] || [ -d "$OLD_DATA" ] || return 0
	fi
	say "found RegionGate (LobbyFence's old name) - moving it over to LobbyFence"
	if [ -x /etc/init.d/regiongate ]; then
		# (it saves its learned servers and takes its rules out)
		/etc/init.d/regiongate stop >/dev/null 2>&1 || true
		/etc/init.d/regiongate disable >/dev/null 2>&1 || true
	fi
	rm -f /etc/rc.d/[SK][0-9][0-9]regiongate
	nft delete table inet regiongate >/dev/null 2>&1 || true
	if [ -f /etc/config/lobbyfence ]; then
		if [ -f "$OLD_CONF" ] || [ -d "$OLD_DATA" ]; then
			say "LobbyFence already has settings of its own - RegionGate's were left in $OLD_CONF and $OLD_DATA (delete them when you no longer need them)"
		fi
	else
		if [ -f "$OLD_CONF" ]; then
			mv "$OLD_CONF" /etc/config/lobbyfence
			move_data_dir /etc/config/lobbyfence "$OLD_DATA" /etc/lobbyfence || say "warning: could not update data_dir in /etc/config/lobbyfence"
			# changes made in LuCI and not applied yet (rpcd keeps them per session)
			for f in /var/run/rpcd/uci-*/regiongate /tmp/.uci/regiongate; do
				[ -f "$f" ] || continue
				d="${f%/*}"
				if [ ! -e "$d/lobbyfence" ]; then
					sed 's/^\([-+@^|~]\{0,1\}\)regiongate\./\1lobbyfence./' "$f" > "$d/lobbyfence" || true
				fi
				rm -f "$f"
			done
		fi
		if [ -d "$OLD_DATA" ] && [ ! -e /etc/lobbyfence ]; then
			mv "$OLD_DATA" /etc/lobbyfence
		fi
		say "settings and learned servers moved to /etc/config/lobbyfence and /etc/lobbyfence"
	fi
	# installed as packages: the package manager takes them out (the settings are moved already)
	for p in luci-app-regiongate regiongate; do
		if command -v opkg >/dev/null 2>&1 && opkg status "$p" 2>/dev/null | grep -q '^Status:.* installed'; then
			opkg remove "$p" >/dev/null 2>&1 || true
		fi
		if command -v apk >/dev/null 2>&1 && apk info -e "$p" >/dev/null 2>&1; then
			apk del "$p" >/dev/null 2>&1 || true
		fi
	done
	rm -f /etc/init.d/regiongate /usr/sbin/regiongate /lib/upgrade/keep.d/regiongate \
		/usr/share/luci/menu.d/luci-app-regiongate.json /usr/share/rpcd/acl.d/luci-app-regiongate.json
	rm -rf /usr/share/regiongate /www/luci-static/resources/view/regiongate /www/luci-static/resources/regiongate /tmp/regiongate
	return 0
}

refresh_luci() {
	rm -f /tmp/luci-indexcache* 2>/dev/null || true
	rm -rf /tmp/luci-modulecache 2>/dev/null || true
	[ -x /etc/init.d/rpcd ] && /etc/init.d/rpcd reload >/dev/null 2>&1 || true
}

# anything of LobbyFence's still running (a command waiting for its turn) is
# stopped before its files go, and its firewall table is taken out even when
# the service could not do it
lf_kill() {
	local d c n=0 left
	while :; do
		left=""
		for d in /proc/[0-9]*; do
			[ "${d#/proc/}" = "$$" ] && continue
			c="$(tr '\000' ' ' < "$d/cmdline" 2>/dev/null)" || continue
			case "$c" in *"/usr/sbin/lobbyfence "*|*"/usr/sbin/lobbyfence") left="$left ${d#/proc/}";; esac
		done
		[ -n "$left" ] || return 0
		# shellcheck disable=SC2086
		if [ "$n" -lt 10 ]; then kill $left 2>/dev/null || true; else kill -9 $left 2>/dev/null || true; fi
		[ "$n" -ge 12 ] && return 0
		n=$((n + 1))
		sleep 1
	done
}

# the lag simulator's queues (lflag<n>) and the hooks that send packets to them
# (tc filters 4914 / 4915 on the LAN devices), also when the service could not
# take them out - found by their names, only hooks that lead to LobbyFence's
# queues or copy its marks
lag_leftovers() {
	local d dir p
	for d in /sys/class/net/*; do
		d="${d##*/}"
		case "$d" in
			lflag[0-9]*) ip link del "$d" >/dev/null 2>&1 || true; continue;;
		esac
		command -v tc >/dev/null 2>&1 || continue
		for dir in egress ingress; do
			tc filter show dev "$d" "$dir" pref 4915 2>/dev/null | grep -q "lflag[0-9]" && \
				{ tc filter del dev "$d" "$dir" pref 4915 >/dev/null 2>&1 || true; }
		done
		for p in 4913 4914; do
			tc filter show dev "$d" ingress pref "$p" 2>/dev/null | grep -q "ctinfo" && \
				{ tc filter del dev "$d" ingress pref "$p" >/dev/null 2>&1 || true; }
		done
	done
	return 0
}

uninstall() {
	[ -x /etc/init.d/lobbyfence ] && {
		/etc/init.d/lobbyfence stop >/dev/null 2>&1 || true
		/etc/init.d/lobbyfence disable >/dev/null 2>&1 || true
	}
	lf_kill
	nft delete table inet lobbyfence >/dev/null 2>&1 || true
	lag_leftovers
	echo "$FILES" | while IFS=: read -r _ dest _; do [ -z "$dest" ] || rm -f "$dest"; done
	rm -rf /www/luci-static/resources/view/lobbyfence /usr/share/lobbyfence \
		/www/luci-static/resources/lobbyfence /www/luci-static/lobbyfence /tmp/lobbyfence
	if [ "$1" = --purge ]; then
		rm -rf /etc/lobbyfence /etc/config/lobbyfence
		say "removed, including configuration and learned data"
	else
		say "removed (configuration and learned servers kept in /etc/config/lobbyfence and /etc/lobbyfence)"
	fi
	refresh_luci
}

case "$1" in
	--uninstall) uninstall "$2"; exit 0;;
	'') ;;
	*) sed -n '2,11p' "$0"; exit 1;;
esac

[ -f /etc/openwrt_release ] || fail "this does not look like OpenWrt"
command -v nft >/dev/null 2>&1 || fail "nftables (fw4) is required - OpenWrt 23.05 or newer"
# the files run as root: only over an encrypted, authenticated connection
case "$LF_SOURCE" in
	''|https://*) ;;
	*) fail "LF_SOURCE must start with https:// (or copy the LobbyFence folder to the router and run install.sh from it)";;
esac

# all files first into a folder of their own: a failed download changes nothing
STAGE="$(mktemp -d /tmp/lobbyfence-install.XXXXXX)" || fail "cannot create a temporary folder in /tmp"
trap 'rm -rf "$STAGE"' EXIT
echo "$FILES" | while IFS=: read -r src dest mode; do
	[ -n "$src" ] || continue
	case "$src" in */*) mkdir -p "$STAGE/${src%/*}";; esac
	get "$src" "$STAGE/$src"
done
[ -f /etc/config/lobbyfence ] || [ -f "$OLD_CONF" ] || { mkdir -p "$STAGE/${CONFIG_SRC%/*}"; get "$CONFIG_SRC" "$STAGE/$CONFIG_SRC"; }

migrate_regiongate

echo "$FILES" | while IFS=: read -r src dest mode; do
	[ -n "$src" ] || continue
	mkdir -p "${dest%/*}"
	cp "$STAGE/$src" "$dest.new"
	chmod "$mode" "$dest.new"
	mv "$dest.new" "$dest"
done

if [ -f /etc/config/lobbyfence ]; then
	say "keeping existing /etc/config/lobbyfence"
	# earlier versions shipped a disabled example zone - drop it if it was never touched
	if command -v uci >/dev/null 2>&1 &&
	   [ "$(uci -q get lobbyfence.example.label)" = "Example game" ] &&
	   [ "$(uci -q get lobbyfence.example.enabled)" = 0 ]; then
		uci delete lobbyfence.example && uci commit lobbyfence
		say "removed the unused example zone"
	fi
else
	cp "$STAGE/$CONFIG_SRC" /etc/config/lobbyfence.new
	chmod 600 /etc/config/lobbyfence.new
	mv /etc/config/lobbyfence.new /etc/config/lobbyfence
fi

# left over from earlier versions (map library copy, overview page)
rm -rf /www/luci-static/resources/lobbyfence
rm -f /www/luci-static/resources/view/lobbyfence/status.js

/etc/init.d/lobbyfence enable
# (re)start so the new code runs and LuCI's Save & Apply reaches the service
/etc/init.d/lobbyfence restart >/dev/null 2>&1 || say "warning: the service did not start - see: logread -e lobbyfence"
refresh_luci

say "installed. Open LuCI -> Services -> LobbyFence and create your first zone."
say "Command line: lobbyfence help"
