#!/bin/sh
# Builds a throw-away Asuswrt-Merlin-like environment for the tests: BusyBox
# 1.25.1 built from Merlin's tree with its RT-AX86U configuration (no builtin
# echo / printf / test, no stat / timeout / mktemp), legacy iptables, ipset
# 7.6 (Merlin's version), Merlin's own helper.sh and menuTree.js, fake nvram /
# cru / logger / fc, and LobbyFence installed by its own installer into a
# fake /jffs (with another add-on's lines already in /jffs/scripts).
#   usage: merlin_env.sh <workdir> <merlin-busybox> <full-busybox> <ipset> <merlin-www-files-dir>
#   (<merlin-www-files-dir>: helper.sh and menuTree.js from asuswrt-merlin.ng:
#    release/src/router/others/helper.sh,
#    release/src/router/www/require/menuTrees/menuTree.js)
set -e
W="$1"; MBB="$2"; FBB="$3"; IPSETBIN="$4"; MWWW="$5"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$W"; mkdir -p "$W/bin" "$W/bb" "$W/jffs/scripts" "$W/jffs/addons" "$W/run" "$W/nvram" \
	"$W/www/user" "$W/www/require/modules" "$W/tmp"

for a in $("$MBB" --list); do ln -s "$MBB" "$W/bb/$a"; done
rm -f "$W/bb/logger"
cp "$MBB" "$W/busybox-sh"

for n in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
	ln -s /usr/sbin/xtables-legacy-multi "$W/bin/$n"
done
ln -s "$IPSETBIN" "$W/bin/ipset"
ln -s /usr/bin/curl "$W/bin/curl"
ln -s "$FBB" "$W/bin/ip"          # Merlin ships iproute2's ip

# Merlin's helper.sh, with /www/user pointing into the test folder
sed "s#/www/user#$W/www/user#g" "$MWWW/helper.sh" > "$W/helper.sh"
cp "$MWWW/menuTree.js" "$W/www/require/modules/menuTree.js"

cat > "$W/bin/nvram" <<EOF
#!/bin/sh
case "\$1" in
	get) cat "$W/nvram/\$2" 2>/dev/null; exit 0;;
	set) echo "\${2#*=}" > "$W/nvram/\${2%%=*}";;
	unset) rm -f "$W/nvram/\$2";;
	commit) echo commit >> "$W/nvram.commits";;
esac
EOF
cat > "$W/bin/cru" <<EOF
#!/bin/sh
f="$W/cron"; touch "\$f"
case "\$1" in
	a) grep -v "#\$2#\$" "\$f" > "\$f.t"; mv "\$f.t" "\$f"; echo "\$3 #\$2#" >> "\$f";;
	d) grep -v "#\$2#\$" "\$f" > "\$f.t"; mv "\$f.t" "\$f";;
	l) cat "\$f";;
esac
EOF
cat > "$W/bin/logger" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in -t|-p) shift 2;; --) shift; break;; *) break;; esac; done
echo "LOG: \$*" >> "$W/run.log"
EOF
cat > "$W/bin/modprobe" <<EOF
#!/bin/sh
exit 0
EOF
# Broadcom's flow cache tool
cat > "$W/bin/fc" <<EOF
#!/bin/sh
echo "fc \$*" >> "$W/fc.log"
EOF
chmod +x "$W/bin/nvram" "$W/bin/cru" "$W/bin/logger" "$W/bin/modprobe" "$W/bin/fc"
echo "mssid update am_addons ipv6 dualwan" > "$W/nvram/rc_support"
echo 0 > "$W/nvram/jffs2_scripts"
echo 192.168.1.1 > "$W/nvram/lan_ipaddr"

# another add-on was here first: its lines and settings must stay
printf '#!/bin/sh\n/jffs/addons/other/other.sh start # OtherAddon\n' > "$W/jffs/scripts/services-start"
printf '#!/bin/sh\n/jffs/addons/other/other.sh event "$1" "$2" # OtherAddon\n' > "$W/jffs/scripts/service-event"
chmod 755 "$W/jffs/scripts/services-start" "$W/jffs/scripts/service-event"
printf 'other_title Other Addon 1.2\nother_mode fast\n' > "$W/jffs/addons/custom_settings.txt"
mkdir -p "$W/jffs/addons/other"; printf '#!/bin/sh\necho "$*" >> %s/other.log\n' "$W" > "$W/jffs/addons/other/other.sh"
chmod 755 "$W/jffs/addons/other/other.sh"

# the router as it was before LobbyFence (the brick-safety test compares with it)
cp -a "$W/nvram" "$W/nvram.initial"
cp -a "$W/jffs" "$W/jffs.initial"
PATH="$W/bin:$W/bb" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 "$W/busybox-sh" sh "$REPO/asuswrt-merlin/install.sh" > "$W/install.log" 2>&1 || {
	cat "$W/install.log"; exit 1; }
# the hooks point at the real /jffs: here they point into the test folder
sed -i "s#/jffs/addons/other#$W/jffs/addons/other#" "$W/jffs/scripts/services-start" "$W/jffs/scripts/service-event" \
	"$W/jffs.initial/scripts/services-start" "$W/jffs.initial/scripts/service-event"
# the router's binary is ARM: a native build of the same source for the tests
sh "$REPO/asuswrt-merlin/lagd/build.sh" gcc "$W/jffs/addons/lobbyfence/bin/lf-lagd" >/dev/null

cat > "$W/env.sh" <<EOF
export TPATH="$W/bin:$W/bb"
export LF_HOME="$W/jffs/addons/lobbyfence"
export LF_RUN="$W/run"
export LF_WWWUSER="$W/www/user"
export LF_CUSTOM_SETTINGS="$W/jffs/addons/custom_settings.txt"
export LF_MENU_JS="$W/www/require/modules/menuTree.js"
export LF_MENU_TMP="$W/tmp/menuTree.js"
export LF_HELPER="$W/helper.sh"
export LF_LEASES="$W/dnsmasq.leases"
export LF_IPV6=0
export MERLIN_SH="$W/busybox-sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
EOF
echo "environment ready in $W"
