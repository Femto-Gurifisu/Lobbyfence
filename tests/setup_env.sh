#!/bin/sh
# Builds a throw-away OpenWrt-like shell environment for the tests.
#   usage: setup_env.sh <workdir> <busybox> <uci-prefix> <openwrt-checkout>
set -e
W="$1"; BB="$2"; UCIP="$3"; OW="$4"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

rm -rf "$W"; mkdir -p "$W/bin" "$W/bb" "$W/root/lib/config" "$W/etc/config" "$W/run" "$W/data"

# BusyBox applets (ash, awk, sed, date, ...) shadow the host tools
"$BB" --install -s "$W/bb"
rm -f "$W/bb/logger"

cat > "$W/bin/uci" <<EOF
#!/bin/sh
LD_LIBRARY_PATH="$UCIP/lib" exec "$UCIP/bin/uci" -c "\$UCI_CONFIG_DIR" -t "\$UCI_CONFIG_DIR/.uci" "\$@"
EOF
cat > "$W/bin/logger" <<EOF
#!/bin/sh
while [ \$# -gt 0 ]; do case "\$1" in -t|-p) shift 2;; --) shift; break;; *) break;; esac; done
echo "LOG: \$*" >> "$W/run.log"
EOF
chmod +x "$W/bin/uci" "$W/bin/logger"

sed "s#/sbin/uci#$W/bin/uci#g" "$OW/package/system/uci/files/lib/config/uci.sh" > "$W/root/lib/config/uci.sh"
sed "s#/lib/config/uci.sh#$W/root/lib/config/uci.sh#g" "$OW/package/base-files/files/lib/functions.sh" > "$W/root/lib/functions.sh"

cp "$REPO/files/etc/config/lobbyfence" "$W/etc/config/lobbyfence"

cat > "$W/env.sh" <<EOF
export PATH="$W/bin:$W/bb:/usr/sbin:/usr/bin:/sbin:/bin"
export UCI_CONFIG_DIR="$W/etc/config"
export LF_FUNCTIONS="$W/root/lib/functions.sh"
export LF_SHARE="$REPO/files/usr/share/lobbyfence"
export LF_RUN="$W/run"
export LF="$BB ash $REPO/files/usr/sbin/lobbyfence"
unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY
EOF
echo "environment ready in $W"
