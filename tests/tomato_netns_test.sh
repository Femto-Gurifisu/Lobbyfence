#!/bin/sh
# End-to-end test of the FreshTomato port: LAN client -> router -> WAN game
# servers in network namespaces. The router namespace runs everything with
# BusyBox built from FreshTomato's configuration as /bin/sh and as the only
# tools (plus legacy iptables, ipset 6.38, curl), LobbyFence installed by its
# own installer into a fake /jffs.
#   usage: tomato_netns_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset>
W="$1"; FBB="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/tomato_env.sh" "$@" >/dev/null || exit 1
. "$W/env.sh"
IP="$FBB ip"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
expect() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi; }

unshare -n sleep 900 & LAN=$!
unshare -n -m --propagation private sleep 900 & RTR=$!
unshare -n sleep 900 & WAN=$!
sleep 0.3
inl() { nsenter -t $LAN -n "$@"; }
inr() { nsenter -t $RTR -n -m "$@"; }
inw() { nsenter -t $WAN -n "$@"; }
# FreshTomato's BusyBox is /bin/sh in the router
inr mount --bind "$TOMATO_SH" "$(readlink -f /bin/sh)"

inr $IP link add rl type veth; inr $IP link add rw type veth
inr $IP link set dev veth0 netns $LAN; inr $IP link set dev veth1 netns $WAN
for p in $LAN $RTR $WAN; do nsenter -t $p -n $IP link set lo up; done
inr $IP addr add 192.168.1.1/24 dev rl; inr $IP link set rl up
inr $IP addr add 10.99.0.1/24 dev rw; inr $IP link set rw up
inr sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
inl $IP addr add 192.168.1.100/24 dev veth0; inl $IP link set veth0 up; inl $IP route add default via 192.168.1.1
inw $IP addr add 10.99.0.2/24 dev veth1; inw $IP link set veth1 up
for s in 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1 61.0.0.1 61.0.0.2 61.0.0.3 61.0.0.4 62.0.0.1 63.0.0.1; do
	inw $IP addr add $s/32 dev veth1; inr $IP route add $s/32 via 10.99.0.2
done
inw $IP route add 192.168.1.0/24 via 10.99.0.1

inw python3 "$HERE/udp.py" serve 3074 & SRV=$!
inw python3 "$HERE/udp.py" serve 5555 & SRV2=$!
inw python3 "$HERE/udp.py" tcpserve 443 &
inw python3 "$HERE/udp.py" tcpserve 8443 &
inr python3 "$HERE/fake_geo.py" 8080 "$W/geo_calls.log" & GEO=$!
cleanup() {
	inr env PATH="$TPATH" "$LF_HOME/lobbyfence" stop >/dev/null 2>&1
	kill $LAN $RTR $WAN $SRV $SRV2 $GEO 2>/dev/null
	pkill -f "^python3 $HERE/(udp|fake_geo).py" 2>/dev/null   # (started through a function: $! is not the server)
}
trap cleanup EXIT INT TERM
sleep 0.5

probe() { inl python3 "$HERE/udp.py" probe 3074 "$@" | tr '\n' ' ' | sed 's/ $//'; }
probe_port() { p="$1"; shift; inl python3 "$HERE/udp.py" probe "$p" "$@" | tr '\n' ' ' | sed 's/ $//'; }
lf() { inr env PATH="$TPATH" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log"; }
cfg() { inr env PATH="$TPATH" LF_SHARE="$LF_HOME/share" LF_CONF_FILE="$LF_HOME/lobbyfence.conf" LF_CONF_STAGED="$LF_RUN/staged.conf" \
	/bin/sh -c '. "$LF_SHARE/functions.sh"; uci "$@"' sh "$@"; }
ipt() { inr "$W/bin/iptables" "$@"; }
ips() { inr "$W/bin/ipset" "$@"; }
st() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); $1" "$LF_RUN/status.json"; }
# the web page's CGI, as FreshTomato's web server runs it (body on stdin)
cgi() { printf '%s\n' "$@" | inr env PATH="$TPATH" LF_HOME="$LF_HOME" LF_RUN="$LF_RUN" LF_NVRAM="$LF_NVRAM" "$LF_HOME/www/lobbyfence.cgi"; }
TOKEN="$(cat "$W/nvram/http_id")"

# --- 0. installed like on the router
for f in lobbyfence bin/lobbyfence-main share/fw-ipt.sh share/functions.sh share/conf.awk share/lobbyfence.awk share/servers.txt www/lobbyfence.cgi www/lobbyfence/map.js; do
	[ -f "$LF_HOME/$f" ] || fail "installer did not copy $f"
done
[ -x "$W/jffs/etc/config/lobbyfence.fire" ] && [ -x "$W/jffs/etc/config/lobbyfence.init" ] && [ -x "$W/jffs/etc/config/lobbyfence.shut" ] \
	&& pass "installer set up the boot, firewall and shutdown hooks" || fail "hooks missing"
inr /bin/sh -c 'type command' >/dev/null 2>&1 && fail "test shell is not FreshTomato's BusyBox (it has 'command')" || pass "running on FreshTomato's BusyBox (no 'command' builtin, no xargs/uniq/mktemp)"
expect "baseline connectivity" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

cfg set lobbyfence.globals.enabled=1
cfg set lobbyfence.globals.geo_url=http://127.0.0.1:8080/batch
cfg set lobbyfence.globals.log_blocked=1
cfg set lobbyfence.game=zone
cfg set lobbyfence.game.enabled=1
cfg set lobbyfence.game.label='Test "game"'
cfg set lobbyfence.game.mode=monitor
cfg set lobbyfence.game.strict=0
cfg add_list lobbyfence.game.device=192.168.1.100
cfg add_list lobbyfence.game.remote_port=3074
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800
cfg set lobbyfence.1st=zone
cfg set lobbyfence.1st.enabled=1
cfg add_list lobbyfence.1st.device=192.168.1.200
cfg add_list lobbyfence.1st.remote_port=9999

# --- 1. apply in monitor mode
lf apply || fail "apply returned an error"
ipt -C FORWARD -j LF_FWD 2>/dev/null && [ "$(ipt -S FORWARD | sed -n 2p)" = "-A FORWARD -j LF_FWD" ] \
	&& pass "rules hooked in first in FORWARD" || fail "FORWARD jump: $(ipt -S FORWARD)"
ipt -n -L LF_game_o4 >/dev/null 2>&1 && ipt -n -L LF_1st_o4 >/dev/null 2>&1 && pass "zone chains loaded (zone name starting with a digit too)" || { fail "zone chains"; cat "$LF_RUN/ipt.err"; }
ips list -n | grep -qx lf_game_out4 && ips list -n | grep -qx lf_priv4 && pass "ipsets created" || fail "ipsets: $(ips list -n | tr '\n' ' ')"
expect "monitor mode lets everything through" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

# --- 2. learn + locate
lf cycle
expect "three servers learned" 3 "$(wc -l < "$LF_RUN/state/game.ips" | tr -d ' ')"
expect "state of 45.10.0.1" in "$(awk '$1=="45.10.0.1"{print $2}' "$LF_RUN/game.servers")"
expect "state of 80.20.0.1" out "$(awk '$1=="80.20.0.1"{print $2}' "$LF_RUN/game.servers")"
expect "state of 99.30.0.1" unloc "$(awk '$1=="99.30.0.1"{print $2}' "$LF_RUN/game.servers")"
expect "one batch lookup sent (curl)" 1 "$(wc -l < "$W/geo_calls.log" | tr -d ' ')"
ips test lf_game_in4 45.10.0.1 2>/dev/null && pass "in4 set holds the inside server" || fail "lf_game_in4"
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "out4 set holds the outside server" || fail "lf_game_out4"
probe 80.20.0.1 >/dev/null
lf status >/dev/null
st "z=d['zones'][0]; assert z['blocked'] > 0 and z['packets'] > 0, z" && pass "monitor mode counts would-be blocks" || fail "monitor counters: $(cat "$LF_RUN/status.json")"
lf cycle
expect "no repeated lookups" 1 "$(wc -l < "$W/geo_calls.log" | tr -d ' ')"

# --- 3. enforce / 4. strict
cfg set lobbyfence.game.mode=enforce
lf apply
expect "enforce: outside blocked, unlocated allowed" \
	"45.10.0.1 ok 80.20.0.1 blocked 99.30.0.1 ok 77.40.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1)"
cfg set lobbyfence.game.strict=1
lf apply
expect "strict: only located inside servers pass" \
	"45.10.0.1 ok 80.20.0.1 blocked 99.30.0.1 blocked 77.40.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1)"

# --- 5. allow / block lists, subnet allowed
cfg add_list lobbyfence.game.allow_ip=80.20.0.0/24
cfg add_list lobbyfence.game.block_ip=45.10.0.1
lf apply
expect "allow_ip / block_ip override geography" "45.10.0.1 blocked 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
cfg delete lobbyfence.game.allow_ip; cfg delete lobbyfence.game.block_ip

# --- 6. country, polygon, no region
cfg add_list lobbyfence.game.country=us
lf apply
expect "country rule allows the US server" "80.20.0.1 ok" "$(probe 80.20.0.1)"
cfg delete lobbyfence.game.country
cfg delete lobbyfence.game.circle
cfg add_list lobbyfence.game.polygon='38,-80;45,-80;45,-70;38,-70'
lf apply
expect "polygon decides inside/outside" "45.10.0.1 blocked 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
cfg delete lobbyfence.game.polygon
lf apply
expect "no region: every server blocked" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf allow game 45.10.0.1 >/dev/null
expect "no region: whitelisted servers still allowed" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf unlist game 45.10.0.1 >/dev/null
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800
lf apply
r1="$(cat "$LF_RUN/game.rev")"; lf apply
expect "apply with an unchanged region reuses the classification" "$r1" "$(cat "$LF_RUN/game.rev")"

# --- 7. ports
cfg delete lobbyfence.game.remote_port; cfg add_list lobbyfence.game.remote_port=4000
lf apply
expect "traffic on other ports is not filtered" "80.20.0.1 ok" "$(probe 80.20.0.1)"
# 20 ports: more than iptables' multiport takes in one rule
cfg delete lobbyfence.game.remote_port
for p in 1000 1001 1002 1003 1004 1005 1006 1007 1008 1009 1010 1011 1012 1013 3000-3050 3074 4000-4001 5000; do cfg add_list lobbyfence.game.remote_port=$p; done
lf apply || fail "apply with 18 port entries"
expect "long port list: split over several rules, still filtered" "80.20.0.1 blocked" "$(probe 80.20.0.1)"
cfg delete lobbyfence.game.remote_port; cfg add_list lobbyfence.game.remote_port=3074
lf apply

# --- 7b. device by MAC, port on either side
LANMAC="$(inl $IP link show veth0 | awk '/link\/ether/ { print $2 }')"
cfg delete lobbyfence.game.device; cfg add_list lobbyfence.game.device="$(echo "$LANMAC" | tr 'a-f' 'A-F')"
cfg delete lobbyfence.game.remote_port; cfg add_list lobbyfence.game.port=3074
lf apply || fail "apply with MAC device"
expect "MAC-only device: geography still enforced" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "either-side port: device port 3074 to server port 5555 is filtered" "80.20.0.1 blocked" "$(probe_port 5555 80.20.0.1)"
lf cycle
grep -qx "192.168.1.100" "$LF_RUN/game.mip" && pass "MAC resolved to the device's current IP" || fail "MAC resolution"
ips test lf_game_mip4 192.168.1.100 2>/dev/null && pass "resolved IP loaded for inbound matching" || fail "lf_game_mip4"
devs="$(lf devices)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); m=sys.argv[2].lower(); e=[x for x in d if x['mac']==m]; assert e and '192.168.1.100' in e[0]['ipv4'], d" "$devs" "$LANMAC" \
	&& pass "devices lists the console with its IP and MAC" || fail "devices: $devs"
cfg delete lobbyfence.game.device; cfg add_list lobbyfence.game.device=192.168.1.100
cfg delete lobbyfence.game.port; cfg add_list lobbyfence.game.remote_port=3074
lf apply
expect "remote_port only: other server ports untouched" "80.20.0.1 ok" "$(probe_port 5555 80.20.0.1)"

# --- 7c. click to allow / block: live; also kept in changes waiting on the web page
printf "config globals 'globals'\n\toption enabled '1'\n" > "$LF_RUN/staged.conf.seed"
cp "$LF_HOME/lobbyfence.conf" "$LF_RUN/staged.conf"
lf allow game 80.20.0.1 >/dev/null
expect "allow takes effect at once" "80.20.0.1 ok" "$(probe 80.20.0.1)"
grep -q "allow_ip '80.20.0.1'" "$LF_HOME/lobbyfence.conf" && grep -q "allow_ip '80.20.0.1'" "$LF_RUN/staged.conf" \
	&& pass "rule saved, also into the changes waiting on the web page" || fail "allow_ip not saved everywhere"
rm -f "$LF_RUN/staged.conf" "$LF_RUN/staged.conf.seed"
lf block game 45.10.0.1 >/dev/null
expect "block takes effect at once (even inside the region)" "45.10.0.1 blocked" "$(probe 45.10.0.1)"
st "z=d['zones'][0]; assert z['allow']==['80.20.0.1'] and z['block']==['45.10.0.1'], z" && pass "rules listed in status.json" || fail "status.json allow/block"
lf unlist game 80.20.0.1 45.10.0.1 >/dev/null
expect "unlist returns to the geographic decision" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf allow game garbage >/dev/null 2>&1 && fail "allow accepted garbage" || pass "allow rejects invalid addresses"

# --- 7d. open for server tests
cfg set lobbyfence.game.burst_servers=3; cfg set lobbyfence.game.burst_open=4
lf apply || fail "apply with burst"
ipt -n -L LF_game_b4 >/dev/null 2>&1 && pass "burst chain loaded" || fail "burst chain missing"
expect "3 servers: still filtered" "80.20.0.1 blocked 61.0.0.1 blocked 61.0.0.2 blocked" "$(probe 80.20.0.1 61.0.0.1 61.0.0.2)"
expect "4th server at once: zone opens" "61.0.0.3 ok" "$(probe 61.0.0.3)"
expect "while open, outside servers get through" "80.20.0.1 ok" "$(probe 80.20.0.1)"
live="$(lf live)"
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 1 <= z['open_left'] <= 4 and z['opened'] > 0, z" "$live" \
	&& pass "live state shows the zone open" || fail "live: $live"
sleep 12
expect "after the open time the regions apply again" "80.20.0.1 blocked" "$(probe 80.20.0.1)"
cfg set lobbyfence.game.burst_open=6
lf apply
ips list -t lf_game_op4 | grep -q "timeout 6" && pass "changed open time: set re-created with it" || fail "op4 timeout: $(ips list -t lf_game_op4 | grep Header)"
cfg set lobbyfence.game.burst_servers=0
lf apply
ipt -n -L LF_game_b4 >/dev/null 2>&1 && fail "burst chain left with 0" || pass "0 turns it off (chain removed)"
ips list -n | grep -q "lf_game_bu4\|lf_game_op4" && fail "burst sets left behind" || pass "and its sets"

# --- 7e. active now / packet rate (conntrack accounting)
expect "connection accounting switched on" 1 "$(inr cat /proc/sys/net/netfilter/nf_conntrack_acct)"
probe 45.10.0.1 >/dev/null
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 0 <= z['active']['45.10.0.1'] <= 3, z" "$(lf live)" \
	&& pass "a server in use is listed as active" || fail "active: $(lf live)"
sleep 4
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 3 <= z['active']['45.10.0.1'] <= 7, z" "$(lf live)" \
	&& pass "its age grows while the device is quiet" || fail "age: $(lf live)"
inl python3 "$HERE/udp.py" stream 3074 45.10.0.1 20 6 & STREAM=$!
sleep 2; lf live >/dev/null; sleep 1.5
live="$(lf live)"
wait $STREAM
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert z['rate']['45.10.0.1'] >= 5, z" "$live" \
	&& pass "packet rate from connection counts (game traffic ~20/s)" || fail "rate: $live"

out="$(lf diag)"
echo "$out" | grep -q "zone game" && echo "$out" | grep -q "active now" && echo "$out" | grep -q "45.10.0.1" \
	&& pass "diag explains what the map shows (zone, learned, active now)" || fail "diag: $out"

# --- 7f. background service: a new outside server is blocked within seconds
cfg set lobbyfence.game.strict=0; cfg set lobbyfence.globals.interval=60
lf start
sleep 3
[ -n "$(cat "$LF_RUN/daemon.pid" 2>/dev/null)" ] && inr kill -0 "$(cat "$LF_RUN/daemon.pid")" && pass "start runs the learning loop" || fail "no daemon"
grep -q "lobbyfence watchdog" "$W/cron" && pass "watchdog in cron" || fail "cron: $(cat "$W/cron" 2>/dev/null)"
[ -L "$LF_WWWEXT/lobbyfence.asp" ] && [ -L "$LF_WWWEXT/cgi-bin/lobbyfence.cgi" ] && [ -L "$LF_WWWEXT/lobbyfence/map.js" ] \
	&& pass "web page linked into /www/ext" || fail "web links: $(ls -R "$LF_WWWEXT")"
expect "enforce: an unknown server first gets through" "62.0.0.1 ok" "$(probe 62.0.0.1)"
t0=$(date +%s); res=ok
while [ $(( $(date +%s) - t0 )) -lt 15 ]; do
	res="$(probe 62.0.0.1 | awk '{print $2}')"; [ "$res" = blocked ] && break
done
took=$(( $(date +%s) - t0 ))
[ "$res" = blocked ] && [ "$took" -le 8 ] && pass "new outside server blocked after ${took}s (learning pass is 60s)" || fail "not blocked fast ($res after ${took}s)"
# the 2-second check's cheap trigger: servers the zone doesn't know land in lf_<zone>_nw4,
# a learning pass empties it (then the check costs one small ipset list, not the whole list)
ipt -S LF_game_o4 | grep -q -- "--add-set lf_game_nw4 dst" && ipt -S LF_game_i4 | grep -q -- "--add-set lf_game_nw4 src" \
	&& pass "servers the zone doesn't know are noted for the quick check (both directions)" || fail "nw rules: $(ipt -S LF_game_o4)"
probe 62.0.0.2 >/dev/null
lf cycle
[ -z "$(ips list lf_game_nw4 | sed '1,/^Members:/d')" ] && pass "learning pass empties the quick-check set" || fail "nw after cycle: $(ips list lf_game_nw4 | tail -3)"

# --- 7f2. Save & Apply (reload) while the watchdog runs (seen on a real R7000: the
# watchdog started a second loop in the moment the reload had stopped the first -
# the reload then waited 30 s, stopped the new one by force, and that was a "crash")
loops() { pgrep -f "$LF_HOME/bin/lobbyfence-main daemon" | wc -l | tr -d ' '; }
rm -f "$LF_HOME/data/crash.log" "$LF_RUN/crash.log"; sed -i '/stopped unexpectedly/d' "$W/run.log"
( i=0; while [ $i -lt 400 ] && [ ! -f "$W/wd.stop" ]; do lf watchdog; i=$((i + 1)); done ) & wdp=$!
t0=$(date +%s); lf reload; rc=$?; took=$(( $(date +%s) - t0 ))
: > "$W/wd.stop"; wait $wdp; rm -f "$W/wd.stop"
sleep 1
[ "$rc" = 0 ] && [ "$took" -lt 20 ] && pass "reload with the watchdog running alongside: done in ${took}s" || fail "reload took ${took}s (rc $rc)"
[ "$(loops)" = 1 ] && inr kill -0 "$(cat "$LF_RUN/daemon.pid")" 2>/dev/null \
	&& pass "...one learning loop, the one the pid file names" || fail "loops: $(loops), pid file $(cat "$LF_RUN/daemon.pid" 2>&1)"
! grep -q "=== crash" "$LF_HOME/data/crash.log" "$LF_RUN/crash.log" 2>/dev/null && ! grep -q "stopped unexpectedly" "$W/run.log" \
	&& pass "...and nothing put on record as a crash" || fail "crash recorded: $(cat "$LF_HOME/data/crash.log" "$LF_RUN/crash.log" 2>/dev/null | head -5)"
# the watchdog leaves a start / stop / reload alone while one is at work
p0="$(cat "$LF_RUN/daemon.pid")"
inr kill "$p0"; n=0; while inr kill -0 "$p0" 2>/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
mkdir "$LF_RUN/svc.lock"; sleep 300 & holder=$!; echo "$holder" > "$LF_RUN/svc.lock/pid"
lf watchdog
[ "$(loops)" = 0 ] && pass "watchdog during a reload: starts nothing" || fail "watchdog started a loop during a reload"
kill "$holder" 2>/dev/null; wait "$holder" 2>/dev/null
lf watchdog; sleep 1
[ "$(loops)" = 1 ] && [ ! -d "$LF_RUN/svc.lock" ] && pass "...a lock left by a command that died doesn't stop it" || fail "stale lock: loops $(loops)"
# a second loop started by hand leaves at once and the first one stays the one to stop
p1="$(cat "$LF_RUN/daemon.pid")"
inr timeout 15 env PATH="$TPATH" "$LF_HOME/lobbyfence" daemon </dev/null >/dev/null 2>&1; sleep 1
[ "$(loops)" = 1 ] && [ "$(cat "$LF_RUN/daemon.pid")" = "$p1" ] && inr kill -0 "$p1" 2>/dev/null \
	&& pass "a second learning loop leaves at once (the first stays, and stays the one that gets stopped)" || fail "second loop: $(loops) loops, pid file $(cat "$LF_RUN/daemon.pid") (first $p1)"
sed -i '/learning loop was not running/d' "$W/run.log"

# --- 7g. "Any mobile game" preset: TCP 443 + mobile game ports (a phone's game lobby on HTTPS)
tprobe() { p="$1"; shift; inl python3 "$HERE/udp.py" tcpprobe "$p" "$@" | tr '\n' ' ' | sed 's/ $//'; }
cfg set lobbyfence.mob=zone
cfg set lobbyfence.mob.enabled=1
cfg set lobbyfence.mob.label='Mobile games'
cfg set lobbyfence.mob.game=any_mobile
cfg set lobbyfence.mob.mode=enforce
cfg set lobbyfence.mob.strict=0
cfg set lobbyfence.mob.proto=tcp
for p in 443 3013 5001 5003 9001 9330-9340 10001-10094 10514 17500 18082 30000-30999 39003 39698 39779 65010 65050; do
	cfg add_list lobbyfence.mob.remote_port=$p
done
cfg add_list lobbyfence.mob.device=192.168.1.100
cfg add_list lobbyfence.mob.circle=50.1109,8.6821,800
lf apply || fail "apply with the mobile zone"
ipt -S LF_mob_po4 | grep -q -- "-p tcp -m multiport --dports 443,3013,5001,5003,9001,9330:9340,10001:10094,10514,17500,18082,30000:30999,39003 -g LF_mob_o4" \
	&& ipt -S LF_mob_po4 | grep -q -- "--dports 39698,39779,65010,65050 -g LF_mob_o4" && ! ipt -S LF_mob_po4 | grep -q -- "-p udp" \
	&& pass "mobile zone: TCP only, 443 and the mobile game ports (split into iptables-sized lists)" || fail "mobile rules: $(ipt -S LF_mob_po4)"
expect "TCP 443: a new server first gets through (enforce, not strict)" "45.10.0.1 ok 80.20.0.1 ok" "$(tprobe 443 45.10.0.1 80.20.0.1)"
lf cycle
grep -q "^80.20.0.1 out" "$LF_RUN/mob.servers" && grep -q "^45.10.0.1 in" "$LF_RUN/mob.servers" \
	&& pass "TCP 443 servers learned and located for the mobile zone" || fail "mob servers: $(cat "$LF_RUN/mob.servers")"
expect "TCP 443: the server outside the region is blocked, the one inside works" "45.10.0.1 ok 80.20.0.1 blocked" "$(tprobe 443 45.10.0.1 80.20.0.1)"
expect "TCP on a port the zone doesn't list is left alone" "80.20.0.1 ok" "$(tprobe 8443 80.20.0.1)"
expect "the UDP game zone is unchanged by the mobile zone" "45.10.0.1 ok" "$(probe 45.10.0.1)"
out="$(lf list mob)"; echo "$out" | grep -q "80.20.0.1" && pass "list shows the mobile zone's servers" || fail "list mob: $out"
cfg delete lobbyfence.mob
lf apply
! ipt -n -L LF_mob_o4 >/dev/null 2>&1 && expect "mobile zone removed: TCP 443 open again" "80.20.0.1 ok" "$(tprobe 443 80.20.0.1)" || fail "mob chains left"

# --- 8. FreshTomato rebuilds its firewall (iptables-restore of its own rules)
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT\nCOMMIT\n*mangle\n:PREROUTING ACCEPT [0:0]\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n' > "$W/tomato-fw.rules"
inr "$W/bin/iptables-restore" < "$W/tomato-fw.rules"
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "test setup: firewall rebuild kept our chains" || pass "firewall rebuilt by the system: LobbyFence's chains are gone"
expect "...and nothing is filtered" "80.20.0.1 ok" "$(probe 80.20.0.1)"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.fire"
n=0; while ! ipt -C FORWARD -j LF_FWD 2>/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
ipt -C FORWARD -j LF_FWD 2>/dev/null && [ "$(ipt -S FORWARD | sed -n 2p)" = "-A FORWARD -j LF_FWD" ] \
	&& pass "the .fire hook puts the rules back, in front ($((n / 2))s)" || fail "rules not back: $(ipt -S FORWARD)"
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "learned sets survived the rebuild" || fail "out4 lost"
expect "filtering works again" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
grep -q "rules put back" "$W/run.log" && pass "quick path used (sets kept, no full apply)" || fail "fwhook took the slow path"
# the background service also notices (no hook installed)
inr "$W/bin/iptables-restore" < "$W/tomato-fw.rules"
lf cycle
ipt -C FORWARD -j LF_FWD 2>/dev/null && pass "a learning pass also restores missing rules" || fail "cycle did not restore rules"

# --- 8b. a jump added twice (two applies at once, a check that failed on the
# xtables lock): apply leaves exactly one, stop leaves none (it used to stop
# with the second jump left and the chains in place - filtering on, frozen)
ipt -I FORWARD 1 -j LF_FWD
lf apply
expect "a doubled FORWARD jump: apply leaves exactly one" 1 "$(ipt -S FORWARD | grep -c -x -- '-A FORWARD -j LF_FWD')"
ipt -I FORWARD 1 -j LF_FWD
lf stop >/dev/null 2>&1
[ "$(ipt -S FORWARD | grep -c LF_FWD)" = 0 ] && ! ipt -n -L LF_FWD >/dev/null 2>&1 && [ -z "$(ips list -n | grep '^lf_')" ] \
	&& pass "...and stop with a doubled jump still takes everything out" || fail "stop with two jumps: $(ipt -S FORWARD | grep LF_)"
lf start >/dev/null 2>&1

# --- 8c. the sets update failed once (ipset busy): the next pass writes every zone's sets again
lf cycle
rm -f "$LF_RUN/sets.last"
mv "$W/bin/ipset" "$W/bin/ipset.real"
printf '#!/bin/sh\ncase "$1" in restore|-exist) echo "ipset: busy" >&2; exit 1;; esac\nexec %s/bin/ipset.real "$@"\n' "$W" > "$W/bin/ipset"; chmod +x "$W/bin/ipset"
lf cycle
[ -f "$LF_RUN/sets.force" ] && [ ! -f "$LF_RUN/sets.last" ] && pass "sets not taken: marked to be written again in full next pass" || fail "no retry marked after a failed load"
rm -f "$W/bin/ipset"; mv "$W/bin/ipset.real" "$W/bin/ipset"
ips flush lf_game_in4 2>/dev/null
lf cycle
ips test lf_game_in4 45.10.0.1 2>/dev/null && [ -f "$LF_RUN/sets.last" ] && pass "...and the next pass puts every zone's servers back in the sets" || fail "sets not rewritten after the failure"
sed -i '/ipset: busy/d; /ipset rejected/d' "$W/stderr.log" "$W/run.log" 2>/dev/null

# --- 9. CTF (hardware NAT) bypass for the game devices
inr "$W/bin/iptables" -t mangle -C PREROUTING -j LF_CTF_IN 2>/dev/null && inr "$W/bin/iptables" -t mangle -S LF_CTF_IN | grep -q "lf_game_dev4 src -j MARK --set-xmark 0x1/0x7" \
	&& pass "CTF on: game device's packets marked to bypass acceleration" || fail "CTF mark: $(inr "$W/bin/iptables" -t mangle -S)"
echo 1 > "$W/nvram/ctf_disable"
lf cycle
inr "$W/bin/iptables" -t mangle -S | grep -q LF_CTF && fail "CTF off: mark rules left" || pass "CTF switched off: mark rules removed on the next pass"
echo 0 > "$W/nvram/ctf_disable"; echo 1 > "$W/nvram/qos_enable"
lf apply
inr "$W/bin/iptables" -t mangle -S | grep -q LF_CTF && fail "QoS on: marks would clash with QoS" || pass "QoS on: no marks (QoS uses them)"
echo 0 > "$W/nvram/qos_enable"
lf apply

# --- 10. status for the page
lf status >/dev/null
st "assert d['platform']=='tomato' and d['lag_supported'] is False and d['active'] is True and d['ctf'] is True, d" \
	&& pass "status.json: platform, no lag simulator, CTF state" || fail "status.json platform fields"
cfg set lobbyfence.game.lag=1; cfg set lobbyfence.game.lag_delay=80
lf apply || fail "apply with lag set"
st "z=d['zones'][0]; assert z['lag']['on'] and not z['lag']['active'] and z['lag']['error']=='unsupported', z" \
	&& pass "no netem module for this kernel: lag simulator reported as unavailable" || fail "lag status: $(cat "$LF_RUN/status.json")"
st "assert d['lag_supported'] is False" && pass "...and the page is told (lag panel hidden)" || fail "lag_supported"

# --- 10b. lag simulator with LobbyFence's netem module (the test kernel has no
# prio / fw / netem: tc and insmod are stand-ins, the firewall marks are real)
KO="$HERE/../freshtomato/modules/2.6.36.4brcmarm/sch_netem.ko"
cat > "$W/bin/insmod" <<EOF
#!/bin/sh
echo "insmod \$*" >> "$W/insmod.log"
[ -f "$W/insmod.refuse" ] && { echo "insmod: can't insert '\$1': invalid module format" >&2; exit 1; }
[ -f "$W/insmod.oops" ] && exit 139
echo "sch_netem 6144 0 - Live 0xbf000000" >> "$W/proc.modules"
EOF
chmod +x "$W/bin/insmod"; : > "$W/proc.modules"
echo rw > "$W/nvram/wan_iface"
echo boot-1 > "$W/boot_id"
lfl() { inr env PATH="$TPATH" LF_NETEM_KO="$KO" LF_PROC_MODULES="$W/proc.modules" LF_TC="$HERE/fake_tomato_tc.sh" FAKE_TC_DIR="$W/tc" \
	LF_NETEM_GUARD="$W/netem-loading" LF_NETEM_OK="$W/netem-ok" LF_BOOT_ID="$W/boot_id" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log"; }
tcs() { cat "$W/tc/dev/$1" 2>/dev/null; }
cfg set lobbyfence.game.lag_jitter=10; cfg set lobbyfence.game.lag_loss=1.5; cfg set lobbyfence.game.lag_direction=both
lfl apply || fail "apply with lag"
grep -q "sch_netem.ko" "$W/insmod.log" && pass "netem module loaded from LobbyFence's folder" || fail "insmod not called"
grep -q "^boot-1 " "$W/netem-loading" 2>/dev/null && [ ! -e "$W/netem-ok" ] && pass "first use is a trial (guard holds this boot's id)" || fail "trial guard: $(cat "$W/netem-loading" 2>&1)"
ipt -S LF_game_o4 | grep -q -- "-j MARK --set-xmark 0x1000000/0x7f000000" && ipt -S LF_game_i4 | grep -q -- "-j MARK --set-xmark 0x1000000/0x7f000000" \
	&& pass "game packets marked in both directions (real iptables)" || fail "marks: $(ipt -S LF_game_o4 | head -4)"
tcs rl | grep -q "^qdisc prio 7a: root" && tcs rw | grep -q "^qdisc prio 7a: root" \
	&& pass "queue on the LAN side (downloads) and the WAN side (uploads)" || fail "tc: rl=$(tcs rl | head -1) rw=$(tcs rw | head -1)"
tcs rl | grep -q "netem 81: netem limit 10000 delay 40ms 5ms loss 1.5%" && pass "netem: half the ping and jitter each way, loss" || fail "netem args: $(tcs rl)"
tcs rl | grep -q "filter 7a: protocol all prio 1 handle 0x1000000/0x7f000000 fw flowid 7a:4" && pass "the zone's mark goes to its netem band" || fail "filter: $(tcs rl)"
tcs rl | grep -q "child 71: pfifo limit 1000" && pass "normal traffic keeps plain queues (no drops on a bridge without a queue length)" || fail "children: $(tcs rl)"
lfl status >/dev/null
st "z=d['zones'][0]; assert d['lag_supported'] and z['lag']['active'] and not z['lag']['error'], z['lag']" && pass "status: lag simulator active" || fail "lag status: $(head -c 600 "$LF_RUN/status.json")"
expect "game traffic still flows and is still filtered" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
# same boot, applied again during the trial: still works
lfl apply
st "z=d['zones'][0]; assert z['lag']['active'] and not z['lag']['error'], z['lag']" && pass "trial: applying again in the same boot is fine" || fail "trial reapply: $(head -c 400 "$LF_RUN/status.json")"
# the router restarts during the trial (maybe netem crashed it): netem is not used again,
# and the restart loop that a bad module would cause can't happen
echo boot-2 > "$W/boot_id"; : > "$W/proc.modules"; : > "$W/insmod.log"; rm -rf "$W/tc/dev"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='netemcrash', z['lag']" && [ ! -s "$W/insmod.log" ] && [ -z "$(tcs rl)$(tcs rw)" ] \
	&& pass "restart during the trial: netem never used again (no restart loop)" || fail "trial crash: $(cat "$W/insmod.log") $(tcs rl)"
# the user deletes the guard (the restart had another cause): a new trial, which passes
rm -f "$W/netem-loading"
lfl apply
lflt() { inr env PATH="$TPATH" LF_NETEM_TRIAL=0 LF_NETEM_KO="$KO" LF_PROC_MODULES="$W/proc.modules" LF_TC="$HERE/fake_tomato_tc.sh" FAKE_TC_DIR="$W/tc" \
	LF_NETEM_GUARD="$W/netem-loading" LF_NETEM_OK="$W/netem-ok" LF_BOOT_ID="$W/boot_id" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log" >/dev/null; }
lflt cycle
[ ! -e "$W/netem-ok" ] && pass "no game packets through netem yet: not recorded as working" || fail "ok without traffic"
touch "$W/tc/traffic"
lflt cycle
[ -e "$W/netem-ok" ] && grep -q "^boot-2 " "$W/netem-loading" \
	&& pass "game packets went through netem: recorded as working; the guard stays while netem is in use" || fail "trial end: ok=$(ls "$W" | grep netem)"
echo boot-3 > "$W/boot_id"; : > "$W/proc.modules"; rm -rf "$W/tc/dev"
rm -f "$W/netem-loading"   # (boot-2 ended cleanly)
lfl apply
st "z=d['zones'][0]; assert z['lag']['active'] and not z['lag']['error'], z['lag']" && grep -q "^boot-3 " "$W/netem-loading" \
	&& pass "after a passed trial: loaded again, guarded on this boot too" || fail "after trial: $(head -c 400 "$LF_RUN/status.json")"
# a firmware update that changed the kernel (same version): the router restarts while
# netem is in use - netem worked before, but is not loaded again (no reboot loop)
echo boot-4 > "$W/boot_id"; : > "$W/proc.modules"; : > "$W/insmod.log"; rm -rf "$W/tc/dev"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='netemcrash', z['lag']" && [ ! -s "$W/insmod.log" ] \
	&& pass "netem had worked, then a restart while in use: not loaded again (no reboot loop after a firmware change)" || fail "crash after trial: $(cat "$W/insmod.log")"
rm -f "$W/netem-ok" "$W/netem-loading" "$W/tc/traffic"
lfl apply
# the LAN device lost its queue (network restart): the next pass puts it back
rm -f "$W/tc/dev/rl"
lfl cycle
tcs rl | grep -q "^qdisc prio 7a: root" && pass "queue put back after a network restart" || fail "not restored"
cfg set lobbyfence.game.lag_direction=down
lfl apply
ipt -S LF_game_o4 | grep -q MARK && fail "download only: uploads marked" || pass "download only: uploads not marked"
[ -z "$(tcs rw)" ] && tcs rl | grep -q "delay 80ms 10ms" && pass "download only: full ping on the LAN side, WAN untouched" || fail "down: rl=$(tcs rl) rw=$(tcs rw)"
# QoS owns the WAN queue: refuse, change nothing
cfg set lobbyfence.game.lag_direction=up
echo "qdisc htb 1: root refcnt 2 r2q 10 default 40" > "$W/tc/dev/rw"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='busy', z['lag']" && grep -q "htb 1:" "$W/tc/dev/rw" \
	&& pass "QoS on: lag refused with a reason, QoS queue untouched" || fail "busy: $(cat "$W/tc/dev/rw")"
cfg set lobbyfence.game.lag_direction=both
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='busy', z['lag']" && [ ! -e "$W/netem-loading" ] && [ -z "$(tcs rl)" ] \
	&& pass "QoS on the WAN side only: LAN queue taken back, no trial left over (a later restart isn't taken for a crash)" || fail "busy both: rl=$(tcs rl) guard=$(cat "$W/netem-loading" 2>&1)"
cfg set lobbyfence.game.lag_direction=up
rm -f "$W/tc/dev/rw"
# the kernel refuses the module (other firmware build): reported, nothing set up
: > "$W/proc.modules"; touch "$W/insmod.refuse"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='netemrefused', z['lag']" && [ ! -e "$W/netem-loading" ] \
	&& pass "module refused by the kernel: reported, router unchanged" || fail "refused: $(head -c 400 "$LF_RUN/status.json")"
rm -f "$W/insmod.refuse"
# insmod killed by a kernel oops while loading: never tried again, even in the same boot
: > "$W/proc.modules"; touch "$W/insmod.oops"; : > "$W/insmod.log"
lfl apply
rm -f "$W/insmod.oops"; : > "$W/insmod.log"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='netemcrash', z['lag']" && [ ! -s "$W/insmod.log" ] \
	&& pass "insmod crashed: not tried again" || fail "oops: $(cat "$W/insmod.log")"
rm -f "$W/netem-loading"
# a load that never finished (router restarted) is not tried again
touch "$W/netem-loading"; : > "$W/insmod.log"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='netemcrash', z['lag']" && [ ! -s "$W/insmod.log" ] \
	&& pass "after a crash during loading the module is never loaded again" || fail "guard: $(cat "$W/insmod.log")"
rm -f "$W/netem-loading"
cfg delete lobbyfence.game.lag; cfg delete lobbyfence.game.lag_delay; cfg delete lobbyfence.game.lag_jitter
cfg delete lobbyfence.game.lag_loss; cfg delete lobbyfence.game.lag_direction
lfl apply
[ -z "$(tcs rl)$(tcs rw)" ] && ! ipt -S LF_game_i4 | grep -q MARK && pass "lag off: queues and marks removed" || fail "lag off left: $(tcs rl)"
rm -f "$W/bin/insmod"
sed -i '/lag simulator: the kernel refused the netem module/d; /QoS or the bandwidth limiter is on/d' "$W/run.log"

# --- 11. CGI (the web page's link)
out="$(cgi wrongtoken "read status")"
python3 -c "import json,sys; assert 'error' in json.loads(sys.argv[1])" "$out" && pass "CGI refuses a wrong session token" || fail "CGI token: $out"
out="$(cgi "$TOKEN" "read status")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['platform']=='tomato'" "$out" && pass "CGI: status" || fail "CGI status: $out"
out="$(cgi "$TOKEN" "read servers game")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert '80.20.0.1 out' in d['text']" "$out" && pass "CGI: server list" || fail "CGI servers: $out"
out="$(cgi "$TOKEN" "exec live")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and 'game' in json.loads(d['stdout'])['zones']" "$out" && pass "CGI: live counters" || fail "CGI live: $out"
out="$(cgi "$TOKEN" "exec allow game 1.2.3.4;reboot")"
python3 -c "import json,sys; assert json.loads(sys.argv[1]).get('error')" "$out" && pass "CGI refuses odd addresses" || fail "CGI injection: $out"
out="$(cgi "$TOKEN" "exec teardown")"
python3 -c "import json,sys; assert json.loads(sys.argv[1]).get('error')" "$out" && pass "CGI refuses commands it does not offer" || fail "CGI exec teardown: $out"
out="$(cgi "$TOKEN" "read servers ../../etc/passwd")"
python3 -c "import json,sys; assert json.loads(sys.argv[1]).get('error')" "$out" && pass "CGI refuses paths" || fail "CGI path: $out"
# debug report through the page's link
out="$(cgi "$TOKEN" "exec debug")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); o=d['stdout']; assert d['code']==0 and o.startswith('LobbyFence debug report') and '==== FreshTomato' in o and '==== End of report' in o and 'lf_game_' in o, d" "$out" \
	&& pass "CGI: debug report (FreshTomato part, firewall, end)" || fail "CGI debug: $(echo "$out" | head -c 300)"
out="$(cgi "$TOKEN" "exec debug clear")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and 'cleared' in d['stdout'], d" "$out" && pass "CGI: debug clear" || fail "CGI debug clear: $out"
# servers file through the page's link: download, then import a file with one new location
out="$(cgi "$TOKEN" "exec export")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and '\nlobbyfence-servers 1\n' in d['stdout'], d" "$out" \
	&& pass "CGI: servers file download" || fail "CGI export: $(echo "$out" | head -c 300)"
out="$(cgi "$TOKEN" "exec builtin-servers")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); o=d['stdout']; assert d['code']==0 and o.startswith('lobbyfence-servers 1') and '\ngame apex Apex Legends\n' in o and '\ngame cod Call of Duty\n' in o and sum(1 for l in o.splitlines() if l[:1].isdigit()) > 100, d" "$out" \
	&& pass "CGI: the servers LobbyFence comes with (for the Servers file window)" || fail "CGI builtin-servers: $(echo "$out" | head -c 300)"
sf="$(printf 'lobbyfence-servers 1\ngame fortnite Fortnite\n45.77.0.9 51.5 -0.1 GB 1700000000\n10.0.0.1 1 1 GB 1700000000\n')"
out="$(cgi "$TOKEN" "import-servers" "$sf")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and 'imported 1 new' in d['stdout'], d" "$out" \
	&& pass "CGI: servers file import (private address skipped)" || fail "CGI import-servers: $out"
grep -q '^45.77.0.9 51.5 -0.1 GB [0-9]* fortnite$' "$LF_HOME/data/shared.cache" 2>/dev/null || grep -rq '^45.77.0.9 ' "$LF_HOME"/*/shared.cache 2>/dev/null \
	&& pass "imported location kept by game" || fail "shared.cache: $(find "$LF_HOME" -name shared.cache)"
out="$(cgi "$TOKEN" "import-servers" "hello")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']!=0 and 'not a LobbyFence servers file' in d['stderr'], d" "$out" \
	&& pass "CGI: other files refused" || fail "CGI import bad: $out"
out="$(cgi "$TOKEN" "exec remove-servers fortnite 45.77.0.9")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and 'removed 1 chosen server(s) of fortnite' in d['stdout'], d" "$out" \
	&& pass "CGI: remove one chosen server" || fail "CGI remove one: $out"
out="$(cgi "$TOKEN" "exec remove-servers fortnite")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and 'removed 0 server(s) of fortnite' in d['stdout'], d" "$out" \
	&& pass "CGI: remove a game's servers list" || fail "CGI remove-servers: $out"
out="$(cgi "$TOKEN" "exec remove-servers ../x")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d.get('error') == 'bad game', d" "$out" \
	&& pass "CGI: remove-servers takes game names only" || fail "CGI remove bad: $out"
out="$(cgi "$TOKEN" "exec ports game")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0, d" "$out" && pass "CGI: ports seen" || fail "CGI ports: $out"
out="$(cgi "$TOKEN" "exec ports game reboot")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d.get('error') == 'bad argument', d" "$out" && pass "CGI: ports takes clear only" || fail "CGI ports bad: $out"
# Save (stage) -> config shows the waiting change -> Apply
conf="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['text'])" "$(cgi "$TOKEN" config)")"
new="$(printf '%s\n' "$conf" | sed "s/option label 'Test \"game\"'/option label 'Renamed'/")"
out="$(printf '%s\n%s\n%s\n' "$TOKEN" stage "$new" | inr env PATH="$TPATH" LF_HOME="$LF_HOME" LF_RUN="$LF_RUN" LF_NVRAM="$LF_NVRAM" "$LF_HOME/www/lobbyfence.cgi")"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['staged'] is True" "$out" && pass "CGI: Save keeps the change aside" || fail "CGI stage: $out"
grep -q "Renamed" "$LF_HOME/lobbyfence.conf" && fail "staged change written to the live config" || pass "live configuration untouched until Apply"
out="$(cgi "$TOKEN" config)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['staged'] and 'Renamed' in d['text']" "$out" && pass "CGI: the page sees the waiting change" || fail "CGI config: $out"
out="$(cgi "$TOKEN" apply)"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['code']==0" "$out" && grep -q "Renamed" "$LF_HOME/lobbyfence.conf" && [ ! -f "$LF_RUN/staged.conf" ] \
	&& pass "CGI: Apply saves it and reloads" || fail "CGI apply: $out"
st "assert d['zones'][0]['label']=='Renamed'" && pass "the new setting is in effect" || fail "label not applied"
out="$(cgi "$TOKEN" running)"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['running'] is True" "$out" && pass "CGI: learning loop running after Apply" || fail "CGI running: $out"
# the router can't load the rules (a rule the kernel refuses): the page is told
# (it used to say "applied"), and no rules are left - not the old settings' either
mv "$W/bin/iptables-restore" "$W/bin/iptables-restore.real"
cat > "$W/bin/iptables-restore" <<'EOF2'
#!/bin/sh
# refuses LobbyFence's new rules (like a kernel without a module they need), takes the rest
t="$(cat)"
case "$t" in *"-A LF_"*) echo "iptables-restore: line 3 failed" >&2; exit 1;; esac
printf '%s\n' "$t" | /usr/sbin/xtables-legacy-multi iptables-restore "$@"
EOF2
chmod +x "$W/bin/iptables-restore"
out="$(cgi "$TOKEN" apply)"
ipt -C FORWARD -j LF_FWD 2>/dev/null && left=1 || left=0
st "assert d['active'] is False" && inactive=1 || inactive=0
rm -f "$W/bin/iptables-restore"; mv "$W/bin/iptables-restore.real" "$W/bin/iptables-restore"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']!=0 and 'could not put them into effect' in d['stderr'] and 'filtering is off' in d['stderr'], d" "$out" \
	&& pass "CGI: a failed apply is reported to the page" || fail "CGI apply failure: $out"
[ "$left" = 0 ] && [ "$inactive" = 1 ] && pass "a failed apply leaves no rules (the router works as without LobbyFence) and the status says so" \
	|| fail "after a failed apply: rules left=$left, status inactive=$inactive"
lf cycle
ipt -C FORWARD -j LF_FWD 2>/dev/null && pass "the next learning pass puts the rules in place by itself" || fail "rules not back after a pass"
sed -i '/iptables-restore rejected/d; /could not be put in place/d' "$W/run.log" 2>/dev/null
out="$(cgi "$TOKEN" apply)"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['code']==0" "$out" && ipt -C FORWARD -j LF_FWD 2>/dev/null \
	&& pass "CGI: the next apply works again" || fail "CGI apply after failure: $out"
printf '%s\n%s\n%s\n' "$TOKEN" stage "config zone 'x'
	option label 'y'" | inr env PATH="$TPATH" LF_HOME="$LF_HOME" LF_RUN="$LF_RUN" LF_NVRAM="$LF_NVRAM" "$LF_HOME/www/lobbyfence.cgi" >/dev/null
cgi "$TOKEN" revert >/dev/null
[ ! -f "$LF_RUN/staged.conf" ] && pass "CGI: Reset throws the waiting change away" || fail "revert"

# --- 11b. ip6tables without the SET target (seen on a real R7000): IPv6 falls back, IPv4 unharmed
# (switches, as files next to bin/: v6.setok - the SET target works; v6.noctk -
# the kernel refuses the connection-state match, which shows at COMMIT;
# v6.reject - refuses everything; v6.rejectline - the same, naming a line)
cat > "$W/bin/fake-ip6tables-restore" <<'EOF'
#!/bin/sh
d="${0%/*}/.."
t="$(cat)"
[ -f "$d/v6.setok" ] || case "$t" in *"-j SET"*) echo "Warning: Extension SET (target) is not supported, missing kernel module?" >&2; exit 1;; esac
[ -f "$d/v6.reject" ] && { echo "ip6tables-restore: unable to initialize table 'filter'" >&2; exit 1; }
[ -f "$d/v6.rejectline" ] && { echo "ip6tables-restore: line 3 failed" >&2; exit 1; }
if [ -f "$d/v6.noctk" ]; then
	case "$t" in *"-m conntrack"*) echo "ip6tables-restore: line $(echo "$t" | grep -n '^COMMIT' | head -n 1 | cut -d: -f1) failed" >&2; exit 1;; esac
fi
echo "$t" > "$d/v6.loaded"; exit 0
EOF
cat > "$W/bin/fake-ip6tables" <<'EOF'
#!/bin/sh
case "$*" in *"-L FORWARD"*) exit 0;; esac
exit 1
EOF
chmod +x "$W/bin/fake-ip6tables-restore" "$W/bin/fake-ip6tables"
lf6() { inr env PATH="$TPATH" LF_IPV6=1 LF_IP6T="$W/bin/fake-ip6tables" LF_IP6T_RESTORE="$W/bin/fake-ip6tables-restore" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log"; }
rm -f "$W/v6.loaded"
lf6 apply && pass "apply succeeds although ip6tables lacks the SET target" || fail "apply failed with IPv6 lacking SET"
grep -q "LF_game_o6" "$W/v6.loaded" 2>/dev/null && ! grep -q -- "-j SET" "$W/v6.loaded" && grep -q "lf_game_out6 dst -g LF_game_x" "$W/v6.loaded" \
	&& pass "IPv6 rules loaded without the SET lines (filtering kept)" || fail "IPv6 fallback rules: $(head -c 300 "$W/v6.loaded" 2>/dev/null)"
expect "IPv4 still filtered" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf6 status >/dev/null
st "assert d['ipv6']=='no-learning', d['ipv6']" && pass "status.json says IPv6 runs without learning" || fail "ipv6 status: $(cat "$LF_RUN/status.json" | head -c 200)"
grep -q "ip6tables can't add servers to ipsets" "$W/run.log" && pass "explained in the system log" || fail "no log line"
touch "$W/v6.reject"; rm -f "$LF_RUN/v6.noset"
lf6 apply && pass "ip6tables refusing everything: apply still succeeds" || fail "apply failed with IPv6 broken"
lf6 status >/dev/null
st "assert d['ipv6']=='off', d['ipv6']" && pass "status.json: IPv6 off" || fail "ipv6 status: $(head -c 200 "$LF_RUN/status.json")"
expect "IPv4 still filtered" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
rm -f "$W/v6.reject" "$LF_RUN/v6.off" "$LF_RUN/v6.noset"
sed -i '/rejected - IPv6 traffic is not filtered/d; /ip6tables can.t add servers/d' "$W/run.log"

# --- 11c. a zone that opens for server tests, on a router whose ip6tables has no SET target
# and whose kernel refuses the connection-state match for IPv6 (the R7000 again: IPv6 rules
# were refused at COMMIT as soon as the Apex Legends zone - it has a burst limit - was added)
cfg set lobbyfence.game.burst_servers=2; cfg set lobbyfence.game.burst_open=20
touch "$W/v6.noctk"; rm -f "$W/v6.loaded"
lf6 apply && pass "burst zone, no SET target, no connection-state match: apply succeeds" || fail "apply failed"
grep -q "lf_game_out6 dst -g LF_game_x" "$W/v6.loaded" 2>/dev/null && ! grep -q -- "-j SET\|-m conntrack\|_op6 " "$W/v6.loaded" \
	&& pass "IPv6 rules loaded without the burst's rules (filtering kept)" || fail "v6 rules: $(grep -n -- 'conntrack\|_op6\|SET' "$W/v6.loaded" 2>&1 | head -5)"
lf6 status >/dev/null
st "assert d['ipv6']=='no-learning', d['ipv6']" && ! grep -q "IPv6 rules rejected" "$W/run.log" && [ ! -f "$LF_RUN/v6.off" ] \
	&& pass "IPv6 stays filtered, nothing reported as an error" || fail "ipv6: $(grep -c 'IPv6 rules rejected' "$W/run.log") errors, status $(head -c 300 "$LF_RUN/status.json")"
expect "IPv4 burst rules untouched" "1" "$(ipt -S LF_game_o4 | grep -c -- '-m conntrack --ctstate NEW -j LF_game_b4')"
# the SET target works, the connection-state match doesn't: IPv6 without those rules only
touch "$W/v6.setok"; rm -f "$LF_RUN"/v6.* "$W/v6.loaded"; sed -i '/ip6tables can.t add servers/d' "$W/run.log"
lf6 apply
grep -q -- "-j SET --add-set lf_game_now6 dst" "$W/v6.loaded" 2>/dev/null && ! grep -q -- "-m conntrack" "$W/v6.loaded" && [ -f "$LF_RUN/v6.noct" ] \
	&& grep -q "refuses rules that look at the state of a connection" "$W/run.log" && ! grep -q "ip6tables can.t add servers" "$W/run.log" \
	&& pass "connection-state match refused: IPv6 filtered without those rules, servers still learned, explained in the log" || fail "noct: $(ls "$LF_RUN"/v6.* 2>&1 | tr '\n' ' ') $(tail -n 3 "$W/run.log")"
lf6 status >/dev/null; st "assert d['ipv6']=='on', d['ipv6']" && lf6 diag | grep -q "IPv6: filtered, without the rules that look at connection states" \
	&& pass "status and diag say so" || fail "noct status: $(lf6 diag | grep IPv6)"
# refused whatever is left out: the log names the line, the debug report shows the rules
touch "$W/v6.rejectline"; rm -f "$LF_RUN"/v6.*
lf6 apply
grep -q "IPv6 rules rejected - IPv6 traffic is not filtered: ip6tables-restore: line 3 failed (line 3 of the rules: :LF_game_po6 - \[0:0\])" "$W/run.log" \
	&& pass "IPv6 refused: the log says which line of the rules" || fail "refusal log: $(grep 'IPv6 rules rejected' "$W/run.log" | tail -n 1)"
lf6 debug > "$W/debug6.txt" 2>/dev/null
grep -q "IPv6 rules that ip6tables refused" "$W/debug6.txt" && grep -q "^   3  :LF_game_po6 - \[0:0\]" "$W/debug6.txt" && grep -q "kernel messages" "$W/debug6.txt" \
	&& pass "...and the debug report shows the refused rules" || fail "debug: $(grep -n -A4 'refused' "$W/debug6.txt" | head -8)"
# the next apply tries IPv6 again
rm -f "$W/v6.rejectline" "$W/v6.loaded"
lf6 apply; lf6 status >/dev/null
[ ! -f "$LF_RUN/v6.off" ] && [ -s "$W/v6.loaded" ] && [ ! -f "$LF_RUN/v6.refused" ] && st "assert d['ipv6']!='off', d['ipv6']" \
	&& pass "the next apply tries IPv6 again (and it works once ip6tables takes the rules)" || fail "retry: $(ls "$LF_RUN"/v6.* 2>&1 | tr '\n' ' ')"
rm -f "$W/v6.noctk" "$W/v6.setok" "$LF_RUN"/v6.*
cfg set lobbyfence.game.burst_servers=0
sed -i '/rejected - IPv6 traffic is not filtered/d; /ip6tables can.t add servers/d; /refuses rules that look at/d' "$W/run.log"
lf apply

# --- 12. saved to JFFS, back after a reboot
: > "$LF_RUN/v6.noset"; : > "$LF_RUN/v6.off"
lf stop
ls "$LF_RUN"/v6.* >/dev/null 2>&1 && fail "stop left what was found out about ip6tables: $(ls "$LF_RUN"/v6.*)" || pass "stop forgets what ip6tables couldn't do (found out again at the next start)"
[ -s "$LF_HOME/data/zones/game.ips" ] && [ -s "$LF_HOME/data/geo.cache" ] && pass "learned servers saved to JFFS on stop" || fail "nothing saved: $(ls -R "$LF_HOME/data")"
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "stop left rules" || pass "stop removes the rules"
ips list -n | grep -q '^lf_' && fail "stop left sets: $(ips list -n | tr '\n' ' ')" || pass "and the sets"
grep -q lobbyfence "$W/cron" && fail "cron entry left" || pass "and the cron entry"
rm -rf "$LF_RUN"; mkdir -p "$LF_RUN"             # /tmp is empty after a reboot
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.init"
n=0; while ! ips test lf_game_out4 80.20.0.1 2>/dev/null && [ $n -lt 30 ]; do sleep 0.5; n=$((n + 1)); done
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "after a reboot the .init hook restores filter + learned servers" || fail "not restored after reboot"
expect "filtering right after the reboot" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"

# --- 13. zone removed / disabled
cfg delete lobbyfence.1st
lf apply
ipt -n -L LF_1st_o4 >/dev/null 2>&1 && fail "deleted zone's chains left" || pass "deleted zone's chains removed"
ips list -n | grep -q "^lf_1st_" && fail "deleted zone's sets left" || pass "deleted zone's sets removed"
cfg set lobbyfence.globals.enabled=0
lf apply
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "disabled: rules left" || pass "disabled: no rules"
cfg set lobbyfence.globals.enabled=1
lf stop

# --- 13c. brick safety: a zone filtering every port and protocol never cuts the
# device off the router itself (its web page, SSH, DNS stand-ins)
lf start >/dev/null 2>&1
inr python3 "$HERE/udp.py" tcpserve 8022 >/dev/null 2>&1 &
inr python3 "$HERE/udp.py" serve 1053 >/dev/null 2>&1 &
sleep 0.5
cfg delete lobbyfence.game.remote_port
cfg delete lobbyfence.game.port
cfg add_list lobbyfence.game.remote_port=1-65535
cfg set lobbyfence.game.proto=both
cfg set lobbyfence.game.mode=enforce
cfg set lobbyfence.game.strict=1
cfg delete lobbyfence.game.circle
cfg delete lobbyfence.game.polygon
cfg delete lobbyfence.game.country
lf apply
expect "a zone filtering every port, no region: the device's game servers are blocked" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "...the router's own TCP services still answer the device (SSH / web page stand-in)" "192.168.1.1 ok" "$(inl python3 "$HERE/udp.py" tcpprobe 8022 192.168.1.1 | tr '\n' ' ' | sed 's/ $//')"
expect "...and its UDP services (DNS stand-in)" "192.168.1.1 ok" "$(probe_port 1053 192.168.1.1)"
# hooks: FreshTomato waits for its init / firewall / shutdown scripts - they must not
# hold the router up, even while another LobbyFence command hangs (lock held)
sleep 120 & HOLDER=$!
rm -rf "$LF_RUN/lock"; mkdir "$LF_RUN/lock"; echo "$HOLDER" > "$LF_RUN/lock/pid"
t0=$(date +%s)
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.init"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.fire"
t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] && pass "init and firewall hooks return at once while LobbyFence is busy ($((t1 - t0)) s)" || fail "hooks held the router up: $((t1 - t0)) s"
t0=$(date +%s)
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.shut"
t1=$(date +%s)
[ $((t1 - t0)) -le 35 ] && ! ipt -n -L LF_FWD >/dev/null 2>&1 \
	&& pass "shutdown hook: LobbyFence stopped within $((t1 - t0)) s although another command hung (reboots are not held up)" || fail "shut with a hung command: $((t1 - t0)) s, rules: $(ipt -S FORWARD | grep -c LF_)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
sed -i '/lock held for too long/d' "$W/stderr.log" 2>/dev/null

# --- 13d. a reset to factory defaults: FreshTomato sets its own settings back
# (the Init script among them) but leaves JFFS - LobbyFence notices it by the
# line it keeps in the Init script, starts fresh, and keeps the earlier
# settings and learned servers for "restore"
nv() { inr env PATH="$TPATH" "$LF_NVRAM" "$@"; }
started() { # (the .init hook starts LobbyFence in the background)
	n=0; while { [ ! -s "$LF_RUN/status.json" ] || [ -d "$LF_RUN/svc.lock" ]; } && [ $n -lt 60 ]; do sleep 0.5; n=$((n + 1)); done
}
tok="$(cat "$LF_HOME/.reset-mark" 2>/dev/null)"
[ -n "$tok" ] && nv get script_init | grep -q "^# LobbyFence-reset-mark $tok " \
	&& pass "reset check: a line in the router's Init script, its token on JFFS too" || fail "no reset mark: file '$tok', Init script '$(nv get script_init)'"
# (the person's own Init script stays as it is around that line)
nv set script_init="$(printf 'echo my own line\n%s' "$(nv get script_init)")"
lf start >/dev/null 2>&1
[ "$(cat "$LF_HOME/.reset-mark")" = "$tok" ] && [ -s "$LF_HOME/data/zones/game.ips" ] && [ "$(cfg get lobbyfence.game)" = zone ] \
	&& ! ls -d "$LF_HOME"/before-* >/dev/null 2>&1 && [ "$(nv get script_init | head -n 1)" = "echo my own line" ] \
	&& pass "a start with the line in place resets nothing, and the person's own Init script lines stay" || fail "start reset something: $(ls -a "$LF_HOME") / $(nv get script_init)"
expect "...the zone filters as before" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf stop
# the reset (FreshTomato's defaults again: an empty Init script; JFFS as it was), then the boot
nv unset script_init
rm -rf "$LF_RUN"; mkdir -p "$LF_RUN"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.init"
started
b="$(ls -d "$LF_HOME"/before-reset-* 2>/dev/null | head -n 1)"
[ -n "$b" ] && grep -q "config zone 'game'" "$b/lobbyfence.conf" 2>/dev/null && [ -s "$b/data/zones/game.ips" ] && grep -q "restore" "$b/README.txt" 2>/dev/null \
	&& pass "after a reset: the earlier settings and learned servers are kept in ${b##*/}" || fail "reset: nothing kept: $(ls -a "$LF_HOME")"
! grep -q "^config zone" "$LF_HOME/lobbyfence.conf" && grep -q "option enabled '0'" "$LF_HOME/lobbyfence.conf" \
	&& grep -q "option data_dir '$LF_HOME/data'" "$LF_HOME/lobbyfence.conf" && [ ! -e "$LF_HOME/data/zones/game.ips" ] \
	&& pass "...and LobbyFence starts with its default settings, like a new install" || fail "reset: settings not fresh: $(cat "$LF_HOME/lobbyfence.conf")"
expect "...nothing is filtered any more" "45.10.0.1 ok 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
expect "...the web page is told (Status)" "reset True 0" "$(st "print(d['problems']['fresh_why'], d['problems']['fresh_time'] > 0, d['problems']['crashes'])")"
tok2="$(cat "$LF_HOME/.reset-mark" 2>/dev/null)"
[ -n "$tok2" ] && [ "$tok2" != "$tok" ] && nv get script_init | grep -q "^# LobbyFence-reset-mark $tok2 " && grep -q "the router was reset to its default settings" "$LF_RUN/log" \
	&& pass "...a new line in the Init script, and the log says what happened" || fail "reset: mark / log: '$tok2' '$(nv get script_init)'"
# the earlier ones back, as the web page asks for them (its CGI)
out="$(cgi "$TOKEN" "exec restore")"
started
r="$(ls -d "$LF_HOME"/replaced-* 2>/dev/null | head -n 1)"
echo "$out" | grep -q '"code":0' && grep -q "^config zone 'game'" "$LF_HOME/lobbyfence.conf" && [ -s "$LF_HOME/data/zones/game.ips" ] && [ ! -e "$b" ] && [ -n "$r" ] \
	&& pass "restore (web page): the earlier settings and learned servers are back, the fresh ones kept in ${r##*/}" || fail "restore: $out / $(ls -a "$LF_HOME")"
expect "...it filters as before the reset" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "...and the page no longer says it started fresh" "0" "$(st "print(d['problems']['fresh_time'])")"
out="$(cgi "$TOKEN" "exec restore")"
echo "$out" | grep -q '"code":1' && echo "$out" | grep -q "no settings from before" && grep -q "^config zone 'game'" "$LF_HOME/lobbyfence.conf" \
	&& pass "restore with nothing to bring back: says so, changes nothing" || fail "second restore: $out"
# a fresh start asked for by hand, and back
lf fresh >/dev/null 2>&1
bf="$(ls -d "$LF_HOME"/before-fresh-* 2>/dev/null | head -n 1)"
[ -n "$bf" ] && grep -q "^config zone 'game'" "$bf/lobbyfence.conf" && ! grep -q "^config zone" "$LF_HOME/lobbyfence.conf" \
	&& [ "$(st "print(d['problems']['fresh_why'])")" = asked ] && pass "fresh (by hand): default settings, the earlier ones kept" || fail "fresh: $(ls -a "$LF_HOME")"
lf restore >/dev/null 2>&1
grep -q "^config zone 'game'" "$LF_HOME/lobbyfence.conf" && [ ! -e "$bf" ] && pass "...and restore brings them back" || fail "restore after fresh: $(ls -a "$LF_HOME")"
# an install from before this check (no token on JFFS, no line): set up at its next start, nothing reset
rm -f "$LF_HOME/.reset-mark"; nv set script_init="echo my own line"
lf restart >/dev/null 2>&1
[ -s "$LF_HOME/.reset-mark" ] && grep -q "^config zone 'game'" "$LF_HOME/lobbyfence.conf" && ! ls -d "$LF_HOME"/before-reset-* >/dev/null 2>&1 \
	&& [ "$(nv get script_init | head -n 1)" = "echo my own line" ] && nv get script_init | grep -q "^# LobbyFence-reset-mark " \
	&& pass "an install from before the reset check: set up at the next start, nothing reset" || fail "upgrade: $(ls -a "$LF_HOME") / $(nv get script_init)"
# nvram answering nothing: nothing can be told, so nothing is reset
printf '#!/bin/sh\nexit 0\n' > "$W/bin/nvram-mute"; chmod +x "$W/bin/nvram-mute"
inr env PATH="$TPATH" LF_NVRAM="$W/bin/nvram-mute" "$LF_HOME/lobbyfence" restart >/dev/null 2>&1
grep -q "^config zone 'game'" "$LF_HOME/lobbyfence.conf" && ! ls -d "$LF_HOME"/before-reset-* >/dev/null 2>&1 \
	&& pass "nvram not answering: nothing is reset" || fail "mute nvram reset: $(ls -a "$LF_HOME")"
lf stop

# --- 14. uninstall
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 "$TOMATO_SH" sh "$HERE/../freshtomato/install.sh" remove >/dev/null 2>&1
[ ! -e "$W/jffs/etc/config/lobbyfence.fire" ] && [ ! -e "$LF_HOME/bin" ] && [ -f "$LF_HOME/lobbyfence.conf" ] && [ -d "$LF_HOME/data" ] \
	&& pass "uninstall removes the program and hooks, keeps settings and data" || fail "uninstall: $(find "$W/jffs" | head)"
[ "$(cat "$W/nvram/script_init" 2>/dev/null)" = "echo my own line" ] && [ ! -e "$LF_HOME/.reset-mark" ] \
	&& pass "...takes its line out of the router's Init script and leaves the person's own" || fail "uninstall and the Init script: '$(cat "$W/nvram/script_init" 2>/dev/null)'"
rm -f "$W/nvram/script_init"     # (the person's own line goes too: the router as it was before the test)
[ -z "$(ipt -S | grep LF_)" ] && [ -z "$(ips list -n | grep '^lf_')" ] && pass "uninstall leaves no firewall rules or sets" || fail "rules left: $(ipt -S | grep -c LF_)"

# --- 15. brick safety: purge with the copy the installer kept, then a fresh install
# from the release package (unpacked by FreshTomato's own BusyBox), then purge again -
# the router is left exactly as it was before LobbyFence: nvram, JFFS, hooks,
# cron, the web folder, firewall, ipsets
snapshot() { # -> what LobbyFence could have left behind
	# (wan_iface: set by this test itself, section 10b)
	( cd "$W/nvram" && for f in *; do [ "$f" = wan_iface ] || printf '%s=%s\n' "$f" "$(cat "$f")"; done )
	echo "-- jffs files:"; find "$W/jffs" -type f | sed "s#$W##" | sort
	echo "-- web files:"; find "$W/wwwext" -type f -o -type l | sed "s#$W##" | sort
	echo "-- cron:"; grep -i lobbyfence "$W/cron" 2>/dev/null
	echo "-- iptables:"; ipt -S | grep -i lf_; ipt -t mangle -S | grep -i lf_
	echo "-- ipsets:"; ips list -n | grep '^lf_'
}
initial="$( cd "$W/nvram.initial" && for f in *; do printf '%s=%s\n' "$f" "$(cat "$f")"; done; printf -- '-- jffs files:\n-- web files:\n-- cron:\n-- iptables:\n-- ipsets:\n' )"
[ -f "$LF_HOME/install.sh" ] && pass "uninstall keeps a copy of the installer on JFFS (to purge later)" || fail "no installer copy in $LF_HOME"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 "$TOMATO_SH" sh "$LF_HOME/install.sh" purge >/dev/null 2>&1
expect "purge: the router is as it was before LobbyFence (nvram, JFFS, hooks, cron, web folder, firewall)" "$initial" "$(snapshot)"
rm -rf "$W/dist" "$W/pkg"; mkdir -p "$W/pkg"
sh "$HERE/../tools/build-packages.sh" "$W/dist" >/dev/null 2>&1 || fail "release packages not built"
( cd "$W/pkg" && "$TOMATO_SH" tar -xzf "$W/dist/lobbyfence-freshtomato.tar.gz" ) && [ -f "$W/pkg/lobbyfence-install/freshtomato/install.sh" ] \
	&& pass "the release package unpacks with FreshTomato's BusyBox into lobbyfence-install" || fail "package does not unpack"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 "$TOMATO_SH" sh "$W/pkg/lobbyfence-install/freshtomato/install.sh" > "$W/install2.log" 2>&1 \
	&& pass "installs from the release package" || fail "package install: $(tail -3 "$W/install2.log")"
cfg set lobbyfence.globals.enabled=1
cfg set lobbyfence.globals.geo_url=http://127.0.0.1:8080/batch
cfg set lobbyfence.game=zone
cfg set lobbyfence.game.enabled=1
cfg set lobbyfence.game.mode=enforce
cfg set lobbyfence.game.strict=0
cfg add_list lobbyfence.game.device=192.168.1.100
cfg add_list lobbyfence.game.remote_port=3074
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800
lf start >/dev/null 2>&1
probe 45.10.0.1 80.20.0.1 >/dev/null; lf cycle
expect "the package install filters like the one from the source tree" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 "$TOMATO_SH" sh "$LF_HOME/install.sh" purge >/dev/null 2>&1
expect "purge after the package install: the router is as it was before" "$initial" "$(snapshot)"

grep -q "rejected" "$W/run.log" && fail "firewall tools rejected something: $(grep rejected "$W/run.log" | head -2)" || pass "iptables / ipset never rejected a command"
real="$(grep -v -e "no valid address given" -e "is not a public address" "$W/stderr.log" 2>/dev/null)"
[ -z "$real" ] && pass "no error messages" || fail "errors: $(echo "$real" | sort | uniq -c | head -5)"
[ "$FAIL" = 0 ] && echo "ALL TOMATO TESTS PASSED"
exit $FAIL
