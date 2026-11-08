#!/bin/sh
# The FreshTomato pages in headless Chromium against a real (namespaced)
# router: FreshTomato's own tomato.js / tomato.css with the menu entry
# LobbyFence adds, the real CGI and router script on FreshTomato's BusyBox,
# real ipset / iptables, real MapLibre.
#   usage: tomato_browser_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset> <maplibre-dist> <freshtomato www dir> [screenshot dir]
W="$1"; FBB="$3"; DIST="$5"; FTWWW="$6"; SHOTS="${7:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/tomato_env.sh" "$1" "$2" "$3" "$4" >/dev/null || exit 1
. "$W/env.sh"
IP="$FBB ip"

unshare -n sleep 900 & LAN=$!
unshare -n -m --propagation private sleep 900 & RTR=$!
unshare -n sleep 900 & WAN=$!
sleep 0.3
inl() { nsenter -t $LAN -n "$@"; }
inr() { nsenter -t $RTR -n -m "$@"; }
inw() { nsenter -t $WAN -n "$@"; }
inr mount --bind "$TOMATO_SH" "$(readlink -f /bin/sh)"
inr $IP link add rl type veth; inr $IP link add rw type veth
inr $IP link set dev veth0 netns $LAN; inr $IP link set dev veth1 netns $WAN
for p in $LAN $RTR $WAN; do nsenter -t $p -n $IP link set lo up; done
inr $IP addr add 192.168.1.1/24 dev rl; inr $IP link set rl up
inr $IP addr add 10.99.0.1/24 dev rw; inr $IP link set rw up
inr sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
inl $IP addr add 192.168.1.100/24 dev veth0; inl $IP link set veth0 up; inl $IP route add default via 192.168.1.1
inw $IP addr add 10.99.0.2/24 dev veth1; inw $IP link set veth1 up
for s in 45.10.0.1 80.20.0.1 99.30.0.1; do inw $IP addr add $s/32 dev veth1; inr $IP route add $s/32 via 10.99.0.2; done
inw $IP route add 192.168.1.0/24 via 10.99.0.1
inw python3 "$HERE/udp.py" serve 3074 & SRV=$!
inr python3 "$HERE/fake_geo.py" 8080 "$W/geo_calls.log" & GEO=$!
trap 'inr env PATH="$TPATH" "$LF_HOME/lobbyfence" stop >/dev/null 2>&1; kill $LAN $RTR $WAN $SRV $GEO 2>/dev/null; pkill -f "^python3 $HERE/(udp|fake_geo).py" 2>/dev/null' EXIT INT TERM
sleep 0.5

cfg() { inr env PATH="$TPATH" LF_SHARE="$LF_HOME/share" LF_CONF_FILE="$LF_HOME/lobbyfence.conf" LF_CONF_STAGED="$LF_RUN/staged.conf" \
	/bin/sh -c '. "$LF_SHARE/functions.sh"; uci "$@"' sh "$@"; }
cfg set lobbyfence.globals.enabled=1
cfg set lobbyfence.globals.geo_url=http://127.0.0.1:8080/batch
cfg set lobbyfence.game=zone
cfg set lobbyfence.game.enabled=1
cfg set lobbyfence.game.label=Game
cfg set lobbyfence.game.mode=enforce
cfg set lobbyfence.game.strict=0
cfg add_list lobbyfence.game.device=192.168.1.100
cfg add_list lobbyfence.game.remote_port=3074
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800
# a device whose DHCP host name is HTML: must show as text
LANMAC="$(inl $IP link show veth0 | awk '/link\/ether/ { print $2 }')"
echo "1900000000 $LANMAC 192.168.1.100 <img_src=x_onerror=window.__xss=1>Console *" > "$LF_LEASES"
# FreshTomato's tomato.js, as the router serves it: LobbyFence adds its menu entry
# (built the way FreshTomato's www/Makefile does it: blanks squeezed, then
# minified with the uglifyjs from FreshTomato's own tree - one long line)
mkdir -p "$W/www"; cp "$FTWWW/tomato.css" "$W/www/"
sed '/^\/\*\s*$/,/\*\//! { s/^\s\+//; s/\s\+$//; /^\/\/ --\+\s*/d; /^$/d }' < "$FTWWW/tomato.js" > "$W/www/tomato.sq.js"
node "$FTWWW/tools/lib/node_modules/uglify-js/bin/uglifyjs" "$W/www/tomato.sq.js" -c -o "$W/www/tomato.js" 2>/dev/null
grep -q '\["About","about.asp"\]' "$W/www/tomato.js" && [ "$(wc -l < "$W/www/tomato.js")" -le 2 ] \
	|| { echo "FAIL: test setup: tomato.js not minified like the firmware's"; exit 1; }
# the state an earlier LobbyFence version left on a real router: a broken copy
# laid over tomato.js (an entry put on a line of its own before the minified code)
{ head -n 1 "$W/www/tomato.js"; echo "['LobbyFence', 'ext/lobbyfence.asp'],"; tail -n +2 "$W/www/tomato.js"; } > "$W/broken.js"
inr mount --bind "$W/broken.js" "$W/www/tomato.js"
inr env PATH="$TPATH" LF_TOMATO_JS="$W/www/tomato.js" "$LF_HOME/lobbyfence" start
inl python3 "$HERE/udp.py" probe 3074 45.10.0.1 80.20.0.1 99.30.0.1 >/dev/null
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" cycle
inr cat "$W/www/tomato.js" > "$W/tomato.served.js"

python3 "$HERE/browser_tomato.py" "$W" "$RTR" "$DIST" "$W/tomato.served.js" "$W/www/tomato.css" $SHOTS
