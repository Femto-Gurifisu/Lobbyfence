#!/bin/sh
# Builds a throw-away FreshTomato-like environment for the tests: BusyBox built
# with FreshTomato's own configuration (so missing applets show up), legacy
# iptables, ipset 6.38 (FreshTomato's version), fake nvram / cru / logger, and
# LobbyFence installed by its own installer into a fake /jffs.
#   usage: tomato_env.sh <workdir> <tomato-busybox> <full-busybox> <ipset>
set -e
W="$1"; TBB="$2"; FBB="$3"; IPSETBIN="$4"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$W"; mkdir -p "$W/bin" "$W/bb" "$W/jffs" "$W/run" "$W/wwwext" "$W/nvram"

for a in $("$TBB" --list); do ln -s "$TBB" "$W/bb/$a"; done
rm -f "$W/bb/logger"
cp "$TBB" "$W/busybox-sh"

# legacy iptables (FreshTomato has iptables 1.8 legacy), ipset 6.38
for n in iptables iptables-restore iptables-save ip6tables ip6tables-restore ip6tables-save; do
	ln -s /usr/sbin/xtables-legacy-multi "$W/bin/$n"
done
ln -s "$IPSETBIN" "$W/bin/ipset"
ln -s /usr/bin/curl "$W/bin/curl"
ln -s "$FBB" "$W/bin/ip"          # FreshTomato ships iproute2's ip

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
cat > "$W/bin/cru" <<EOF
#!/bin/sh
# cron entries (cru a <id> <line> / cru d <id>) in a file
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
chmod +x "$W/bin/nvram" "$W/bin/cru" "$W/bin/logger" "$W/bin/modprobe"
echo "TID1234567890abc" > "$W/nvram/http_id"
echo 0 > "$W/nvram/ctf_disable"
echo 0 > "$W/nvram/qos_enable"
echo 192.168.1.1 > "$W/nvram/lan_ipaddr"

# the router as it was before LobbyFence (the brick-safety test compares with it)
cp -a "$W/nvram" "$W/nvram.initial"
PATH="$W/bin:$W/bb" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 "$W/busybox-sh" sh "$REPO/freshtomato/install.sh" > "$W/install.log" 2>&1 || {
	cat "$W/install.log"; exit 1; }

cat > "$W/env.sh" <<EOF
export TPATH="$W/bin:$W/bb"
export LF_HOME="$W/jffs/lobbyfence"
export LF_RUN="$W/run"
export LF_WWWEXT="$W/wwwext"
export LF_LEASES="$W/dnsmasq.leases"
export LF_NVRAM="$W/bin/nvram"
export LF_IPV6=0
export TOMATO_SH="$W/busybox-sh"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
EOF
echo "environment ready in $W"
