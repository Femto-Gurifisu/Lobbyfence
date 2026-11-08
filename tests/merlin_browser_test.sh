#!/bin/sh
# The Asuswrt-Merlin pages in headless Chromium against a real (namespaced)
# router: Merlin's BusyBox, ipset 7.6, legacy iptables, LobbyFence installed
# by its installer (page via Merlin's helper.sh, menu entry in Merlin's
# menuTree.js), requests through the add-on settings + service-event.
#   usage: merlin_browser_test.sh <workdir> <merlin-busybox> <full-busybox> <ipset> <merlin-www-files-dir> <maplibre-dist> [screenshot dir]
W="$1"; FBB="$3"; DIST="$6"; SHOTS="${7:-}"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/merlin_env.sh" "$1" "$2" "$3" "$4" "$5" >/dev/null || exit 1
. "$W/env.sh"
IP="$FBB ip"

unshare -n sleep 900 & LAN=$!
unshare -n -m --propagation private sleep 900 & RTR=$!
unshare -n sleep 900 & WAN=$!
sleep 0.3
inl() { nsenter -t $LAN -n "$@"; }
inr() { nsenter -t $RTR -n -m "$@"; }
inw() { nsenter -t $WAN -n "$@"; }
inr mount --bind "$MERLIN_SH" "$(readlink -f /bin/sh)"
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
inw python3 "$HERE/udp.py" serve 3074 &
inr python3 "$HERE/fake_geo.py" 8080 "$W/geo_calls.log" &
trap 'inr env PATH="$TPATH" "$LF_HOME/lobbyfence" stop >/dev/null 2>&1; kill $LAN $RTR $WAN 2>/dev/null; pkill -f "^python3 $HERE/(udp|fake_geo).py" 2>/dev/null; pkill -f "$W/jffs/addons/lobbyfence/bin/lf-lagd" 2>/dev/null' EXIT INT TERM
sleep 0.5

cfg() { inr env PATH="$TPATH" LF_SHARE="$LF_HOME/share" LF_CONF_FILE="$LF_HOME/lobbyfence.conf" \
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
# (the phone test also moves a polygon)
[ "${LF_BROWSER_SCRIPT:-}" = browser_merlin_mobile.py ] && cfg add_list "lobbyfence.game.polygon=30,-100;30,-80;45,-80;45,-100"
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" start
inl python3 "$HERE/udp.py" probe 3074 45.10.0.1 80.20.0.1 99.30.0.1 >/dev/null
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" cycle

python3 "$HERE/${LF_BROWSER_SCRIPT:-browser_merlin.py}" "$W" "$RTR" "$DIST" $SHOTS
