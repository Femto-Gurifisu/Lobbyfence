#!/bin/sh
# Builds a throw-away DD-WRT-like environment for the tests: BusyBox built with
# DD-WRT's own configuration (so missing applets show up), legacy iptables,
# ipset 7, lighttpd, fake nvram / logger, and LobbyFence installed by its own
# installer into a fake /jffs.
#   usage: ddwrt_env.sh <workdir> <ddwrt-busybox> <its applet list> <full-busybox> <ipset> <lighttpd prefix>
set -e
W="$1"; DBB="$2"; APPLETS="$3"; FBB="$4"; IPSETBIN="$5"; LT="$6"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$W"; mkdir -p "$W/bin" "$W/bb" "$W/jffs" "$W/run" "$W/nvram" "$W/cron.d"

cp "$DBB" "$W/busybox-sh"           # (BusyBox picks the applet by its name: busybox*)
for a in $(cat "$APPLETS"); do ln -s "$W/busybox-sh" "$W/bb/$a"; done
rm -f "$W/bb/logger"

for n in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
	ln -s /usr/sbin/xtables-legacy-multi "$W/bin/$n"
done
ln -s "$IPSETBIN" "$W/bin/ipset"
ln -s /usr/bin/curl "$W/bin/curl"
ln -s "$FBB" "$W/bin/ip"            # DD-WRT ships iproute2's ip and tc
ln -s "$LT/sbin/lighttpd" "$W/bin/lighttpd"

cat > "$W/bin/nvram" <<EOF
#!/bin/sh
# nvram get/set backed by files
case "\$1" in
	get) cat "$W/nvram/\$2" 2>/dev/null; exit 0;;
	set) echo "\${2#*=}" > "$W/nvram/\${2%%=*}";;
	unset) rm -f "$W/nvram/\$2";;
	commit) ;;
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
chmod +x "$W/bin/nvram" "$W/bin/logger" "$W/bin/modprobe"
echo "Netgear R7000" > "$W/nvram/DD_BOARD"
echo 0 > "$W/nvram/ctf_disable"
echo 2 > "$W/nvram/sfe"
echo 192.168.1.1 > "$W/nvram/lan_ipaddr"
echo br0 > "$W/nvram/lan_ifname"

# the router as it was before LobbyFence (the brick-safety test compares with it)
cp -a "$W/nvram" "$W/nvram.initial"
PATH="$W/bin:$W/bb" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 LF_NVRAM="$W/bin/nvram" LF_LIGHTTPD=1 LF_TC=1 \
	"$W/busybox-sh" sh "$REPO/ddwrt/install.sh" > "$W/install.log" 2>&1 || {
	cat "$W/install.log"; exit 1; }

cat > "$W/env.sh" <<EOF
export TPATH="$W/bin:$W/bb"
export LF_HOME="$W/jffs/lobbyfence"
export LF_RUN="$W/run"
export LF_LEASES="$W/dnsmasq.leases"
export LF_NVRAM="$W/bin/nvram"
export LF_CROND="$W/cron.d"
export LF_IPV6=0
export LF_LAG_SUPPORTED=0
export TOMATO_SH="$W/busybox-sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
EOF
echo "environment ready in $W"
