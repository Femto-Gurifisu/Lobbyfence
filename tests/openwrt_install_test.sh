#!/bin/sh
# The OpenWrt installer, run from the release package on BusyBox, in a private
# mount + network namespace: empty /etc, /usr/sbin, /usr/share, /www and
# /lib/upgrade (tmpfs) stand in for the router's. Checks that it installs
# where LuCI and procd expect, that an update keeps the settings, and that
# --uninstall --purge leaves those folders exactly as they were (nothing of
# the router's touched, nothing of LobbyFence's left).
#   usage: openwrt_install_test.sh <workdir> <busybox>
# SPDX-License-Identifier: GPL-3.0-or-later
W="$1"; BB="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
case "$W" in /*) ;; *) W="$PWD/$W";; esac
rm -rf "$W"; mkdir -p "$W/bb" "$W/fake" "$W/pkg"
for a in $("$BB" --list); do ln -s "$BB" "$W/bb/$a"; done
sh "$HERE/../tools/build-packages.sh" "$W/dist" >/dev/null || { echo "FAIL: packages not built"; exit 1; }
( cd "$W/pkg" && "$W/bb/tar" -xzf "$W/dist/lobbyfence-openwrt.tar.gz" ) || { echo "FAIL: package does not unpack"; exit 1; }

# stand-ins for the router's tools: nft (the installer only checks for it), uci,
# procd's rc.common (records what the init script was asked to do)
cat > "$W/fake/nft" <<'EOF'
#!/bin/sh
echo "nft $*" >> /tmp/lf-test.log
exit 0
EOF
cat > "$W/fake/uci" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod 755 "$W/fake/nft" "$W/fake/uci"
# mount points for the stand-in folders (made here when this system has none; removed again)
made=""
for d in /www /lib/upgrade; do [ -d "$d" ] || { mkdir -p "$d" && made="$made $d"; }; done

cat > "$W/inside.sh" <<'EOF'
W="$1"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
for d in /etc /usr/sbin /usr/share /www /lib/upgrade; do mount -t tmpfs tmpfs "$d" || { echo "FAIL: cannot mount $d"; exit 1; }; done
# (this namespace's own network devices in /sys/class/net)
mount -t sysfs sysfs /sys 2>/dev/null
export PATH="$W/fake:$W/bb"
# the router before LobbyFence: its own files in those folders
printf "DISTRIB_ID='OpenWrt'\nDISTRIB_RELEASE='24.10.4'\n" > /etc/openwrt_release
mkdir -p /etc/config /etc/init.d /etc/rc.d /usr/share/luci/menu.d /usr/share/rpcd/acl.d /www/luci-static/resources/view/status
echo "config system" > /etc/config/system
echo "router's own page" > /www/luci-static/resources/view/status/index.js
echo '{}' > /usr/share/luci/menu.d/luci-base.json
mkdir -p /lib/upgrade/keep.d; echo "/etc/config/" > /lib/upgrade/keep.d/base-files-essential
cat > /etc/rc.common <<'RC'
#!/bin/sh
# rc.common stand-in: "<init script> <action>"
. "$1"
n="${1##*/}"
echo "init $n $2" >> /tmp/lf-test.log
case "$2" in
	enable) ln -sf "../init.d/$n" "/etc/rc.d/S${START}$n"; ln -sf "../init.d/$n" "/etc/rc.d/K${STOP}$n";;
	disable) rm -f /etc/rc.d/S??"$n" /etc/rc.d/K??"$n";;
esac
exit 0
RC
printf '#!/bin/sh\necho "rpcd $*" >> /tmp/lf-test.log\n' > /etc/init.d/rpcd
chmod 755 /etc/rc.common /etc/init.d/rpcd
snap() { find /etc /usr/sbin /usr/share /www /lib/upgrade \( -type f -o -type l \) -exec md5sum {} \; 2>/dev/null | sort -k2; find /etc /usr/sbin /usr/share /www /lib/upgrade -type d | sort; }
snap > /tmp/before.txt

out="$(sh "$W/pkg/lobbyfence-install/install.sh" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] && pass "installs from the release package" || fail "install: rc=$rc $out"
for f in /usr/sbin/lobbyfence:755 /etc/init.d/lobbyfence:755 /usr/share/lobbyfence/lobbyfence.awk:644 /usr/share/lobbyfence/fw-nft.sh:644 \
	/www/luci-static/resources/view/lobbyfence/map.js:644 /www/luci-static/resources/view/lobbyfence/zones.js:644 \
	/usr/share/luci/menu.d/luci-app-lobbyfence.json:644 /usr/share/rpcd/acl.d/luci-app-lobbyfence.json:644 \
	/www/luci-static/lobbyfence/manifest.json:644 /www/luci-static/lobbyfence/lf-app.js:644 /lib/upgrade/keep.d/lobbyfence:644 \
	/usr/share/lobbyfence/install.sh:755 /etc/config/lobbyfence:600; do
	p="${f%:*}"; m="${f##*:}"
	[ -f "$p" ] && [ "$(stat -c %a "$p")" = "$m" ] || { fail "installed: $p (mode $(stat -c %a "$p" 2>/dev/null), want $m)"; bad=1; }
done
[ -z "$bad" ] && pass "files where LuCI and procd expect them, with the right modes"
grep -q "init lobbyfence enable" /tmp/lf-test.log && [ -L /etc/rc.d/S99lobbyfence ] && pass "enabled at boot (S99)" || fail "not enabled: $(cat /tmp/lf-test.log)"
grep -q "init lobbyfence restart" /tmp/lf-test.log && pass "service (re)started" || fail "not started"
grep -q "option enabled '0'" /etc/config/lobbyfence && pass "new install: filtering off until a zone is made" || fail "default config"

# an update keeps the settings
echo "	option interval '30'" >> /etc/config/lobbyfence
sh "$W/pkg/lobbyfence-install/install.sh" >/dev/null 2>&1
grep -q "option interval '30'" /etc/config/lobbyfence && pass "an update keeps the settings" || fail "update replaced the settings"

# install straight from the repository: only over https
out="$(LF_SOURCE=http://example.com/lobbyfence sh "$W/pkg/lobbyfence-install/install.sh" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "https" && pass "LF_SOURCE over plain http is refused" || fail "http source: $out"

# uninstall with the copy kept on the router: settings and data stay
mkdir -p /etc/lobbyfence/zones; echo "1.2.3.4 1700000000" > /etc/lobbyfence/zones/game.ips
# a lag queue the service did not take out (its state in RAM lost), next to another device
lagq=0; ip link add lflag2 type ifb 2>/dev/null && ip link add other0 type ifb 2>/dev/null && lagq=1
sh /usr/share/lobbyfence/install.sh --uninstall >/dev/null 2>&1
if [ "$lagq" = 1 ]; then
	[ ! -e /sys/class/net/lflag2 ] && [ -e /sys/class/net/other0 ] && pass "--uninstall removes a lag queue left behind (and nothing else)" \
		|| fail "lag queues after uninstall: $(ls /sys/class/net)"
	ip link del other0 2>/dev/null
else
	echo "SKIP: lag queue leftovers (no ifb devices in this kernel)"
fi
[ ! -e /usr/sbin/lobbyfence ] && [ ! -e /etc/init.d/lobbyfence ] && [ ! -e /www/luci-static/resources/view/lobbyfence ] && [ ! -e /usr/share/lobbyfence ] \
	&& [ ! -e /etc/rc.d/S99lobbyfence ] && [ -f /etc/config/lobbyfence ] && [ -f /etc/lobbyfence/zones/game.ips ] \
	&& pass "--uninstall removes the program, keeps settings and learned servers" || fail "uninstall: $(find /etc /usr/sbin /usr/share /www /lib/upgrade -path '*lobbyfence*' 2>/dev/null | head)"
grep -q "nft delete table inet lobbyfence" /tmp/lf-test.log && pass "...and takes its firewall table out" || fail "nft table not removed"

# install again, then purge: the router's folders exactly as before LobbyFence
sh "$W/pkg/lobbyfence-install/install.sh" >/dev/null 2>&1
sh /usr/share/lobbyfence/install.sh --uninstall --purge >/dev/null 2>&1
snap > /tmp/after.txt
if cmp -s /tmp/before.txt /tmp/after.txt; then
	pass "--uninstall --purge: /etc, /usr/sbin, /usr/share, /www, /lib/upgrade exactly as before"
else
	fail "purge left differences: $(diff /tmp/before.txt /tmp/after.txt | head -20)"
fi
[ -f /etc/config/system ] && [ -f /www/luci-static/resources/view/status/index.js ] && pass "the router's own files untouched" || fail "router files touched"
[ "$FAIL" = 0 ] && echo "ALL OPENWRT INSTALL TESTS PASSED"
exit $FAIL
EOF
rm -f /tmp/lf-test.log
unshare -m -n --propagation private "$W/bb/sh" "$W/inside.sh" "$W"
rc=$?
rm -f /tmp/lf-test.log
for d in $made; do rmdir "$d" 2>/dev/null; done
exit $rc
