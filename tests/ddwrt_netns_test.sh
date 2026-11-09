#!/bin/sh
# End-to-end test of the DD-WRT port: LAN client -> router -> WAN game servers
# in network namespaces. The router namespace runs everything with BusyBox
# built from DD-WRT's configuration as /bin/sh and as the only tools (plus
# legacy iptables, ipset 7, curl, lighttpd), LobbyFence installed by its own
# installer into a fake /jffs. (Made from the FreshTomato test: the filter is
# the same; hooks, CTF, lag simulator, web page and CGI are DD-WRT's.)
#   usage: ddwrt_netns_test.sh <workdir> <ddwrt-busybox> <its applet list> <full-busybox> <ipset> <lighttpd prefix>
W="$1"; FBB="$4"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/ddwrt_env.sh" "$@" >/dev/null || exit 1
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
# DD-WRT's BusyBox is /bin/sh in the router
inr mount --bind "$TOMATO_SH" "$(readlink -f /bin/sh)"

inr $IP link add rl type veth; inr $IP link add rw type veth
inr $IP link set dev veth0 netns $LAN; inr $IP link set dev veth1 netns $WAN
for p in $LAN $RTR $WAN; do nsenter -t $p -n $IP link set lo up; done
inr $IP addr add 192.168.1.1/24 dev rl; inr $IP link set rl up
inr $IP addr add 127.0.0.1/8 dev lo 2>/dev/null
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
# the web page's CGI, through LobbyFence's lighttpd (body as the POST body; the header cut off)
cgi() { printf '%s\n' "$@" | post; }
post() { inr curl -s --noproxy '*' -m 20 -X POST -H 'Content-Type: text/plain' --data-binary @- "http://192.168.1.1:8055/cgi-bin/lobbyfence.cgi"; }
TOKEN=""


# --- 0. installed like on the router
for f in lobbyfence mypage.sh bin/lobbyfence-main share/fw-ipt.sh share/fw-ddwrt.sh share/functions.sh share/conf.awk share/lobbyfence.awk share/servers.txt share/lobbyfence-cgi.sh www/index.html www/cgi-bin/lobbyfence.cgi www/lobbyfence/map.js www/lobbyfence/manifest.json; do
	[ -f "$LF_HOME/$f" ] || fail "installer did not copy $f"
done
[ -x "$W/jffs/etc/config/lobbyfence.firewall" ] && [ -x "$W/jffs/etc/config/lobbyfence.startup" ] && [ -x "$W/jffs/etc/config/K90lobbyfence" ] \
	&& pass "installer set up the boot, firewall and shutdown hooks" || fail "hooks missing"
expect "Status > My Page runs LobbyFence's script" "$LF_HOME/mypage.sh" "$(cat "$W/nvram/mypage_scripts")"
grep -q "@LF" "$LF_HOME/mypage.sh" "$LF_HOME/www/cgi-bin/lobbyfence.cgi" "$LF_HOME/www/index.html" && fail "placeholders left" || pass "install paths and version filled in"
inr env PATH="$TPATH" /bin/sh -c 'type mktemp || type flock || type pgrep || type timeout' >/dev/null 2>&1 && fail "test shell is not DD-WRT's BusyBox" || pass "running on DD-WRT's BusyBox (no mktemp, flock, pgrep, timeout)"
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
grep -qx "\* \* \* \* \* root $LF_HOME/lobbyfence watchdog" "$W/cron.d/lobbyfence" && pass "watchdog in /tmp/cron.d (with the user name)" || fail "cron: $(cat "$W/cron.d/lobbyfence" 2>/dev/null)"
[ -n "$(cat "$LF_RUN/lighttpd.pid" 2>/dev/null)" ] && inr kill -0 "$(cat "$LF_RUN/lighttpd.pid")" && pass "start runs the web page's server" || fail "no lighttpd: $(cat "$LF_RUN/lighttpd.out" "$LF_RUN/lighttpd.log" 2>/dev/null)"
grep -qi "warning\|error" "$LF_RUN/lighttpd.log" 2>/dev/null && fail "lighttpd complains about its settings: $(cat "$LF_RUN/lighttpd.log")" || pass "lighttpd takes the settings without a warning"
TOKEN="$(cat "$LF_HOME/.webtoken" 2>/dev/null)"
case "$TOKEN" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]*) [ ${#TOKEN} = 32 ] && pass "random sign-in token made (32 hex digits)" || fail "token: $TOKEN";; *) fail "token: $TOKEN";; esac
# a web server whose pid file got lost (it held the port, every new start failed with "Address in use")
ours() { for d in /proc/[0-9]*; do case "$(tr '\000' ' ' 2>/dev/null < "$d/cmdline")" in *"lighttpd -f $LF_RUN/lighttpd.conf ") echo "${d#/proc/}";; esac; done; }
rm -f "$LF_RUN/lighttpd.pid"
out="$(inr env PATH="$TPATH" LF_RUN="$LF_RUN" "$LF_HOME/mypage.sh")"
echo "$out" | grep -q "location.replace" && pass "My Page finds the web server without its pid file" || fail "mypage without pid: $out"
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" web >/dev/null 2>"$W/web.err"
n="$(ours | wc -l)"
[ "$n" = 1 ] && [ -n "$(cat "$LF_RUN/lighttpd.pid" 2>/dev/null)" ] && ! grep -q "in use" "$LF_RUN/lighttpd.out" && pass "lobbyfence web: the lost server is stopped, one new one runs" || fail "orphan: $n servers, $(cat "$LF_RUN/lighttpd.out" "$W/web.err")"
# two starts at the same moment (watchdog + a command): still one server
inr kill $(ours); sleep 1
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" watchdog & w1=$!
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" watchdog & w2=$!
wait $w1 $w2
sleep 1
expect "two starts at once: one web server" 1 "$(ours | wc -l | tr -d ' ')"
grep -q "Address in use" "$LF_RUN/lighttpd.out" 2>/dev/null && fail "a start collided" || pass "...and no collision"
[ "$(stat -c %a "$LF_HOME/.webtoken")" = 600 ] && pass "token file readable by root only" || fail "token mode $(stat -c %a "$LF_HOME/.webtoken")"
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

# --- 8. DD-WRT rebuilds its firewall (iptables-restore of its own rules)
printf '*filter\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n-A FORWARD -m state --state RELATED,ESTABLISHED -j ACCEPT\nCOMMIT\n*mangle\n:PREROUTING ACCEPT [0:0]\n:INPUT ACCEPT [0:0]\n:FORWARD ACCEPT [0:0]\n:OUTPUT ACCEPT [0:0]\n:POSTROUTING ACCEPT [0:0]\nCOMMIT\n' > "$W/ddwrt-fw.rules"
inr "$W/bin/iptables-restore" < "$W/ddwrt-fw.rules"
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "test setup: firewall rebuild kept our chains" || pass "firewall rebuilt by the system: LobbyFence's chains are gone"
expect "...and nothing is filtered" "80.20.0.1 ok" "$(probe 80.20.0.1)"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.firewall"
n=0; while ! ipt -C FORWARD -j LF_FWD 2>/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
ipt -C FORWARD -j LF_FWD 2>/dev/null && [ "$(ipt -S FORWARD | sed -n 2p)" = "-A FORWARD -j LF_FWD" ] \
	&& pass "the .firewall hook puts the rules back, in front ($((n / 2))s)" || fail "rules not back: $(ipt -S FORWARD)"
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "learned sets survived the rebuild" || fail "out4 lost"
expect "filtering works again" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
grep -q "rules put back" "$W/run.log" && pass "quick path used (sets kept, no full apply)" || fail "fwhook took the slow path"
# the background service also notices (no hook installed)
inr "$W/bin/iptables-restore" < "$W/ddwrt-fw.rules"
lf cycle
ipt -C FORWARD -j LF_FWD 2>/dev/null && pass "a learning pass also restores missing rules" || fail "cycle did not restore rules"

# --- 8b. the system holds the xtables lock (DD-WRT rebuilding its firewall for UPnP):
# LobbyFence waits it out instead of failing ("Another app is currently holding the xtables lock")
lockcheck() { # what, seconds the lock is held
	inr "$W/bin/iptables-restore" < "$W/ddwrt-fw.rules"
	rm -f "$LF_RUN/last_error"
	flock -o /run/xtables.lock sleep "$2" &
	lockpid=$!
	sleep 0.3
	t0=$(date +%s)
	lf apply; rc=$?
	t1=$(date +%s)
	wait "$lockpid" 2>/dev/null
	[ "$rc" -eq 0 ] && ipt -C FORWARD -j LF_FWD 2>/dev/null && [ $((t1 - t0)) -ge $(($2 - 1)) ] && [ ! -s "$LF_RUN/last_error" ] \
		&& pass "$1: lock held for $2 s - apply waits for it, succeeds, no error ($((t1 - t0)) s)" \
		|| fail "$1 lock wait: rc=$rc $((t1 - t0)) s $(cat "$LF_RUN/last_error" 2>/dev/null)"
	expect "$1: filtering works after the wait" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
}
# iptables with its own "-w <seconds>"
rm -f "$LF_RUN"/xtw.*
lockcheck "iptables with -w" 4
grep -qx 1 "$LF_RUN/xtw.iptables_restore" && pass "-w <seconds> found and used" || fail "xtw: $(cat "$LF_RUN"/xtw.* 2>/dev/null)"
# an iptables that fails at once while the lock is held (what the R7000's build did)
for n in iptables iptables-restore; do
	mv "$W/bin/$n" "$W/bin/$n.real"
	cat > "$W/bin/$n" <<FAKE
#!/bin/sh
case " \$* " in *" -h "*) echo "fake $n: no --wait"; exit 0;; esac
if ! /usr/bin/flock -n /run/xtables.lock true; then
	echo "Can't lock /var/run/xtables.lock: Resource temporarily unavailable" >&2
	echo "Another app is currently holding the xtables lock. Perhaps you want to use the -w option?" >&2
	exit 4
fi
exec /usr/sbin/$( [ "$n" = iptables ] && echo iptables-legacy || echo iptables-legacy-restore ) "\$@"
FAKE
	chmod +x "$W/bin/$n"
done
rm -f "$LF_RUN"/xtw.*
lockcheck "iptables that fails at once" 4
grep -qx 0 "$LF_RUN/xtw.iptables_restore" && pass "no -w: tried again once a second instead" || fail "xtw fake: $(cat "$LF_RUN"/xtw.* 2>/dev/null)"
# a lock never let go: the wait has an end (LF_XT_WAIT), the error is reported, nothing hangs
for build in "fails at once" "with -w"; do
	if [ "$build" = "with -w" ]; then
		for n in iptables iptables-restore; do mv -f "$W/bin/$n.real" "$W/bin/$n"; done
		rm -f "$LF_RUN"/xtw.*
	fi
	rm -f "$LF_RUN/last_error"
	flock -o /run/xtables.lock sleep 60 &
	lockpid=$!
	sleep 0.3
	t0=$(date +%s)
	inr env PATH="$TPATH" LF_XT_WAIT=3 "$LF_HOME/lobbyfence" apply >/dev/null 2>"$W/lockwait.err"; rc=$?
	t1=$(date +%s)
	kill "$lockpid" 2>/dev/null; wait "$lockpid" 2>/dev/null
	[ "$rc" -ne 0 ] && [ $((t1 - t0)) -le 30 ] && grep -q "xtables lock" "$LF_RUN/last_error" 2>/dev/null \
		&& pass "iptables $build, lock held for good: gives up ($((t1 - t0)) s), reports the error, nothing hangs" \
		|| fail "lock forever ($build): rc=$rc $((t1 - t0)) s $(cat "$LF_RUN/last_error" 2>/dev/null)"
done
lf apply
ipt -C FORWARD -j LF_FWD 2>/dev/null && expect "lock gone: the next apply puts everything back" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)" \
	|| fail "no rules after the lock"
sed -i '/xtables lock/d; /Perhaps you want to use the -w option/d; /Stopped waiting after/d; /iptables-restore rejected/d; /Can.t lock/d' "$W/stderr.log" 2>/dev/null

# --- 9. CTF (hardware NAT) bypass for the game devices: DD-WRT's magic XOR, twice
ipt -t mangle -C PREROUTING -j LF_CTF_IN 2>/dev/null && ipt -t mangle -S LF_CTF_IN | grep -q "lf_game_dev4 src -j LF_CTF_X" \
	&& ipt -t mangle -C POSTROUTING -j LF_CTF_OUT 2>/dev/null && ipt -t mangle -S LF_CTF_OUT | grep -q "lf_game_dev4 dst -j LF_CTF_X" \
	&& pass "CTF on: game device's packets in both directions go through the CTF exclusion" || fail "CTF chains: $(ipt -t mangle -S)"
expect "the exclusion is the XOR with 0xB16B00B5, done twice (the mark stays as it was)" \
	"-A LF_CTF_X -j MARK --set-xmark 0xb16b00b5/0x0|-A LF_CTF_X -j MARK --set-xmark 0xb16b00b5/0x0" "$(ipt -t mangle -S LF_CTF_X | grep -- '^-A' | tr '\n' '|' | sed 's/|$//')"
# the mark really comes out unchanged (packets counted by a mark match after the chain)
ipt -t mangle -A POSTROUTING -m mark --mark 0 -j RETURN
ipt -t mangle -Z POSTROUTING
probe 45.10.0.1 >/dev/null
ipt -t mangle -L POSTROUTING -v -n -x | awk '/mark match 0x0/ { exit !($1 > 0) }' && pass "...game packets leave with mark 0 again" || fail "mark changed: $(ipt -t mangle -L POSTROUTING -v -n -x)"
ipt -t mangle -D POSTROUTING -m mark --mark 0 -j RETURN
echo 1 > "$W/nvram/ctf_disable"; echo 0 > "$W/nvram/sfe"
lf cycle
ipt -t mangle -S | grep -q LF_CTF && fail "CTF off: rules left" || pass "CTF switched off: exclusion rules removed on the next pass"
echo 0 > "$W/nvram/ctf_disable"; echo 2 > "$W/nvram/sfe"
lf apply
ipt -t mangle -S LF_CTF_X >/dev/null 2>&1 && pass "CTF back on: rules back" || fail "CTF rules not back"

# --- 10. status for the page
lf status >/dev/null
st "assert d['platform']=='ddwrt' and d['active'] is True and d['ctf'] is True and d['offload'] is False, d" \
	&& pass "status.json: platform ddwrt, CTF on, no SFE" || fail "status.json platform fields: $(head -c 400 "$LF_RUN/status.json")"
echo 1 > "$W/nvram/sfe"; echo 1 > "$W/nvram/ctf_disable"
lf status >/dev/null
st "assert d['offload'] is True and d['ctf'] is False, d" && pass "SFE fast path on: the page is told (it explains what that means)" || fail "sfe: $(head -c 300 "$LF_RUN/status.json")"
lf diag 2>/dev/null | grep -q "software fast path (SFE): ON" && pass "diag explains the SFE setting" || fail "diag sfe"
echo 2 > "$W/nvram/sfe"; echo 0 > "$W/nvram/ctf_disable"
lf apply
cfg set lobbyfence.game.lag=1; cfg set lobbyfence.game.lag_delay=80
lf apply || fail "apply with lag set"
st "z=d['zones'][0]; assert d['lag_supported'] is False and z['lag']['error']=='unsupported', z" \
	&& pass "no tc: lag simulator reported as unavailable" || fail "lag status: $(head -c 400 "$LF_RUN/status.json")"

# --- 10b. lag simulator: netem is built into DD-WRT's kernel (the test kernel has
# no prio / fw / netem: tc is a stand-in, the firewall marks are real)
echo rw > "$W/nvram/wan_ifname"
lfl() { inr env PATH="$TPATH" LF_LAG_SUPPORTED=1 LF_TC="$HERE/fake_tomato_tc.sh" FAKE_TC_DIR="$W/tc" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log"; }
tcs() { cat "$W/tc/dev/$1" 2>/dev/null; }
cfg set lobbyfence.game.lag_jitter=10; cfg set lobbyfence.game.lag_loss=1.5; cfg set lobbyfence.game.lag_direction=both
lfl apply || fail "apply with lag"
[ ! -e "$LF_HOME/.netem-loading" ] && [ ! -e "$LF_HOME/.netem-ok" ] && pass "nothing to load: no module, no trial" || fail "trial files on DD-WRT"
ipt -S LF_game_o4 | grep -q -- "-j MARK --set-xmark 0x1000000/0x7f000000" && ipt -S LF_game_i4 | grep -q -- "-j MARK --set-xmark 0x1000000/0x7f000000" \
	&& pass "game packets marked in both directions (real iptables)" || fail "marks: $(ipt -S LF_game_o4 | head -4)"
tcs rl | grep -q "^qdisc prio 7a: root" && tcs rw | grep -q "^qdisc prio 7a: root" \
	&& pass "queue on the LAN side (downloads) and the WAN side (uploads)" || fail "tc: rl=$(tcs rl | head -1) rw=$(tcs rw | head -1)"
tcs rl | grep -q "netem 81: netem limit 10000 delay 40ms 5ms loss 1.5%" && pass "netem: half the ping and jitter each way, loss" || fail "netem args: $(tcs rl)"
tcs rl | grep -q "filter 7a: protocol all prio 1 handle 0x1000000/0x7f000000 fw flowid 7a:4" && pass "the zone's mark goes to its netem band" || fail "filter: $(tcs rl)"
lfl status >/dev/null
st "z=d['zones'][0]; assert d['lag_supported'] and z['lag']['active'] and not z['lag']['error'], z['lag']" && pass "status: lag simulator active" || fail "lag status: $(head -c 600 "$LF_RUN/status.json")"
expect "game traffic still flows and is still filtered" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
ipt -t mangle -S LF_CTF_X >/dev/null 2>&1 && pass "CTF exclusion and lag marks together" || fail "CTF rules gone with lag"
# the LAN device lost its queue (QoS restarted, network restart): the next pass puts it back
rm -f "$W/tc/dev/rl"
lfl cycle
tcs rl | grep -q "^qdisc prio 7a: root" && pass "queue put back after a network restart" || fail "not restored"
# a kernel without netem (another build): reported, nothing left behind
rm -rf "$W/tc/dev"; touch "$W/tc/no-netem"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='nonetem', z['lag']" && [ -z "$(tcs rl)$(tcs rw)" ] \
	&& pass "kernel without netem: reported, queues taken back" || fail "no netem: $(head -c 400 "$LF_RUN/status.json") $(tcs rl)"
rm -f "$W/tc/no-netem"
# QoS owns the WAN queue: refuse, change nothing
cfg set lobbyfence.game.lag_direction=up
echo "qdisc htb 1: root refcnt 2 r2q 10 default 40" > "$W/tc/dev/rw"
lfl apply
st "z=d['zones'][0]; assert z['lag']['error']=='busy', z['lag']" && grep -q "htb 1:" "$W/tc/dev/rw" \
	&& pass "QoS on: lag refused with a reason, QoS queue untouched" || fail "busy: $(cat "$W/tc/dev/rw")"
rm -f "$W/tc/dev/rw"
cfg set lobbyfence.game.lag_direction=down
lfl apply
ipt -S LF_game_o4 | grep -q MARK && fail "download only: uploads marked" || pass "download only: uploads not marked"
[ -z "$(tcs rw)" ] && tcs rl | grep -q "delay 80ms 10ms" && pass "download only: full ping on the LAN side, WAN untouched" || fail "down: rl=$(tcs rl) rw=$(tcs rw)"
cfg delete lobbyfence.game.lag; cfg delete lobbyfence.game.lag_delay; cfg delete lobbyfence.game.lag_jitter
cfg delete lobbyfence.game.lag_loss; cfg delete lobbyfence.game.lag_direction
lfl apply
[ -z "$(tcs rl)$(tcs rw)" ] && ! ipt -S LF_game_i4 | grep -q MARK && pass "lag off: queues and marks removed" || fail "lag off left: $(tcs rl)"
sed -i '/QoS or the bandwidth limiter is on/d' "$W/run.log"

# --- 10c. Status > My Page: what DD-WRT's web server shows the signed-in user
out="$(inr env PATH="$TPATH" LF_RUN="$LF_RUN" "$LF_HOME/mypage.sh")"
echo "$out" | grep -q ":8055/#t=$TOKEN'" && echo "$out" | grep -q "location.replace(url)" \
	&& pass "My Page sends the browser on to LobbyFence with the token after the #" || fail "mypage: $out"
# the web page's files, from LobbyFence's own server
page="$(inr curl -s --noproxy '*' -m 10 http://192.168.1.1:8055/)"
echo "$page" | grep -q "window.LF_PLATFORM = 'ddwrt'" && echo "$page" | grep -q "/lobbyfence/lf-shim.js?v=[0-9]" \
	&& pass "the page is served (index.html, version filled in)" || fail "index: $(echo "$page" | head -5)"
hdr="$(inr curl -s --noproxy '*' -m 10 -D - -o /dev/null http://192.168.1.1:8055/lobbyfence/map.js)"
echo "$hdr" | grep -qi "^content-type: text/javascript" && echo "$hdr" | grep -qi "^x-frame-options: DENY" \
	&& pass "map.js served as JavaScript, page can't be framed by other sites" || fail "headers: $hdr"
echo "$hdr" | grep -qi "^content-security-policy: object-src 'none'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'" \
	&& echo "$hdr" | grep -qi "^x-content-type-options: nosniff" && echo "$hdr" | grep -qi "^referrer-policy: no-referrer" \
	&& pass "security headers: content security policy, no sniffing, no referrer" || fail "headers: $hdr"
code="$(inr curl -s --noproxy '*' -m 10 -o /dev/null -w '%{http_code}' http://192.168.1.1:8055/lobbyfence/manifest.json)"
expect "home-screen app manifest served" 200 "$code"
code="$(inr curl -s --noproxy '*' -m 10 -o /dev/null -w '%{http_code}' "http://192.168.1.1:8055/../.webtoken")"
[ "$code" != 200 ] && pass "the token file is not reachable over the web ($code)" || fail "token served!"
inr curl -s --noproxy '*' -m 3 -o /dev/null http://10.99.0.1:8055/ && fail "web page reachable on the WAN address" || pass "web server listens on the LAN address only"
# a .webport that is not a port number: not used - the page stays on 8055, My Page agrees, the log says why
echo "80 56x" > "$LF_HOME/.webport"
lf web >/dev/null 2>&1
code="$(inr curl -s --noproxy '*' -m 10 -o /dev/null -w '%{http_code}' http://192.168.1.1:8055/)"
out="$(inr env PATH="$TPATH" LF_RUN="$LF_RUN" "$LF_HOME/mypage.sh")"
[ "$code" = 200 ] && echo "$out" | grep -q ":8055/#t=$TOKEN'" && grep -q "not a port number in .*webport" "$W/run.log" \
	&& pass "a broken .webport is not used: page and My Page stay on 8055, the log says why" || fail "broken .webport: $code / $(echo "$out" | grep -o ':[^/]*/#t=' | head -1)"
rm -f "$LF_HOME/.webport"
lf web >/dev/null 2>&1
sed -i '/not a port number in/d' "$W/run.log"
out="$(inr curl -s --noproxy '*' -m 10 http://192.168.1.1:8055/cgi-bin/lobbyfence.cgi)"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['error']" "$out" && pass "CGI: GET refused" || fail "GET: $out"

# --- 11. CGI (the web page's link)
out="$(cgi "" "read status")"
python3 -c "import json,sys; assert 'My Page' in json.loads(sys.argv[1])['error']" "$out" && pass "CGI without a token says where to get one" || fail "CGI no token: $out"
out="$(cgi wrongtoken "read status")"
python3 -c "import json,sys; assert 'error' in json.loads(sys.argv[1])" "$out" && pass "CGI refuses a wrong token" || fail "CGI token: $out"
out="$(cgi "$TOKEN" "read status")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['platform']=='ddwrt'" "$out" && pass "CGI: status (through lighttpd)" || fail "CGI status: $out"
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
# Save (stage) -> config shows the waiting change -> Apply
conf="$(python3 -c "import json,sys; print(json.loads(sys.argv[1])['text'])" "$(cgi "$TOKEN" config)")"
new="$(printf '%s\n' "$conf" | sed "s/option label 'Test \"game\"'/option label 'Renamed'/")"
out="$(printf '%s\n%s\n%s\n' "$TOKEN" stage "$new" | post)"
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
	option label 'y'" | post >/dev/null
cgi "$TOKEN" revert >/dev/null
[ ! -f "$LF_RUN/staged.conf" ] && pass "CGI: Reset throws the waiting change away" || fail "revert"

old="$TOKEN"
lf newtoken >/dev/null
TOKEN="$(cat "$LF_HOME/.webtoken")"
out="$(cgi "$old" running)"
[ "$TOKEN" != "$old" ] && python3 -c "import json,sys; assert json.loads(sys.argv[1])['error']" "$out" && pass "newtoken: pages with the old token are signed out" || fail "newtoken: $out"
out="$(cgi "$TOKEN" running)"
python3 -c "import json,sys; assert 'running' in json.loads(sys.argv[1])" "$out" && pass "...and the new token works" || fail "new token: $out"

# --- 11b. ip6tables without the SET target (seen on a real R7000): IPv6 falls back, IPv4 unharmed
cat > "$W/bin/fake-ip6tables-restore" <<'EOF'
#!/bin/sh
t="$(cat)"
case "$t" in *"-j SET"*) echo "Warning: Extension SET (target) is not supported, missing kernel module?" >&2; exit 1;; esac
[ -f "${0%/*}/../v6.reject" ] && { echo "ip6tables-restore: unable to initialize table 'filter'" >&2; exit 1; }
echo "$t" > "${0%/*}/../v6.loaded"; exit 0
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
lf apply

# --- 12. saved to JFFS, back after a reboot
lf stop
[ -s "$LF_HOME/data/zones/game.ips" ] && [ -s "$LF_HOME/data/geo.cache" ] && pass "learned servers saved to JFFS on stop" || fail "nothing saved: $(ls -R "$LF_HOME/data")"
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "stop left rules" || pass "stop removes the rules"
ips list -n | grep -q '^lf_' && fail "stop left sets: $(ips list -n | tr '\n' ' ') / $(inr "$W/bin/iptables-save" | grep -e match-set -e '^\*') / $(tail -5 "$W/run.log")" || pass "and the sets"
[ -e "$W/cron.d/lobbyfence" ] && fail "cron entry left" || pass "and the cron entry"
[ -n "$(cat "$LF_RUN/lighttpd.pid" 2>/dev/null)$(ours)" ] && fail "web server left running" || pass "and the web server (no process left)"
rm -rf "$LF_RUN"; mkdir -p "$LF_RUN"             # /tmp is empty after a reboot
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.startup"
n=0; while ! ips test lf_game_out4 80.20.0.1 2>/dev/null && [ $n -lt 30 ]; do sleep 0.5; n=$((n + 1)); done
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "after a reboot the .startup hook restores filter + learned servers" || fail "not restored after reboot"
expect "filtering right after the reboot" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
n=0; while [ -z "$(cat "$LF_RUN/lighttpd.pid" 2>/dev/null)" ] && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
out="$(cgi "$TOKEN" running)"
python3 -c "import json,sys; assert 'running' in json.loads(sys.argv[1])" "$out" && pass "after the reboot the page works with the same token (home-screen app keeps working)" || fail "after reboot: $out"
# the web server died: the watchdog (cron, every minute) starts it again
inr kill "$(cat "$LF_RUN/lighttpd.pid")"; sleep 1
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" watchdog
sleep 1
out="$(cgi "$TOKEN" running)"
python3 -c "import json,sys; assert 'running' in json.loads(sys.argv[1])" "$out" && pass "watchdog restarts the web server" || fail "watchdog web: $out"
# a program that only mentions the server's configuration file (an editor, say) is not taken for the server
sh -c 'sleep 60; :' editor "$LF_RUN/lighttpd.conf" & ED=$!
sleep 0.5
inr kill "$(cat "$LF_RUN/lighttpd.pid")"; sleep 1
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" watchdog
sleep 1
out="$(cgi "$TOKEN" running)"
python3 -c "import json,sys; assert 'running' in json.loads(sys.argv[1])" "$out" && kill -0 $ED 2>/dev/null \
	&& pass "a program that only mentions the server's configuration is not taken for the server (watchdog restarts it, the program lives on)" \
	|| fail "editor taken for the web server: $out"
kill $ED 2>/dev/null

# --- 12b. debug report, crash records, damaged saved data, flash full
out="$(lf debug)"
echo "$out" | grep -q "^LobbyFence debug report" && echo "$out" | grep -q "^==== DD-WRT" && echo "$out" | grep -q "^==== End of report" \
	&& pass "lobbyfence debug: the whole report, with the DD-WRT part" || fail "debug report: $(echo "$out" | head -3)"
for s in "==== System" "==== Settings" "==== Firewall" "==== LobbyFence's own log" "==== What LobbyFence sees" "web page: port 8055, server running" "lf_game_out4" "nvram DD_BOARD: Netgear R7000"; do
	echo "$out" | grep -q -F "$s" || fail "debug report lacks '$s'"
done
mac="$(echo "$LANMAC" | tr 'A-F' 'a-f')"
echo "$out" | grep -q -F "$(cat "$LF_HOME/.webtoken")" && fail "sign-in token in the report" || pass "no sign-in token in the report"
out="$(cgi "$TOKEN" "exec debug")"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['code']==0 and d['stdout'].startswith('LobbyFence debug report') and '==== DD-WRT' in d['stdout'], d" "$out" \
	&& pass "the web page gets the report (exec debug)" || fail "cgi debug: $(echo "$out" | head -c 300)"
out="$(cgi "$TOKEN" "exec debug /etc/passwd")"
python3 -c "import json,sys; assert json.loads(sys.argv[1])['error']=='not allowed'" "$out" && pass "debug takes no other arguments" || fail "debug arg: $out"

# the learning loop is killed (out of memory): the watchdog starts it again and it records a crash
expect "no crash on record yet" "0" "$(st "print(d['problems']['crashes'])")"
cfg add_list lobbyfence.game.device="$LANMAC"
out="$(lf debug)"
cfg del_list lobbyfence.game.device="$LANMAC"
echo "$out" | tr 'A-F' 'a-f' | grep -q -F "$mac" && fail "full MAC address in the report" || pass "MAC addresses partly hidden in the report (settings)"
echo "$out" | grep -q -F "${mac%:*:*:*}:**:**:" && pass "the device's maker part stays readable" || fail "masked MAC not found"
inr kill -9 "$(cat "$LF_RUN/daemon.pid")"; sleep 0.5
echo "boom: a fatal error" >> "$LF_RUN/daemon.err"
inr env PATH="$TPATH" "$LF_HOME/lobbyfence" watchdog
n=0; while ! grep -q "^=== crash" "$LF_HOME/data/crash.log" 2>/dev/null && [ $n -lt 20 ]; do sleep 0.5; n=$((n + 1)); done
grep -q "^=== crash" "$LF_HOME/data/crash.log" 2>/dev/null && pass "an unexpected stop of the learning loop is recorded (on JFFS)" || fail "no crash record"
grep -q "boom: a fatal error" "$LF_HOME/data/crash.log" && grep -q "^last step: " "$LF_HOME/data/crash.log" \
	&& pass "the record has the error output and the step it was at" || fail "crash record: $(cat "$LF_HOME/data/crash.log" | head -20)"
lf cycle
expect "status.json: one crash on record" "1" "$(st "print(d['problems']['crashes'])")"
st "assert 'stopped unexpectedly' in d['problems']['error'] and d['problems']['error_time'] > 0" && pass "status.json: the last error for the page" || fail "problems: $(st "print(d['problems'])")"
lf debug | grep -q "boom: a fatal error" && pass "the report shows the crash" || fail "crash not in the report"
out="$(cgi "$TOKEN" "exec debug clear")"
lf cycle
expect "debug clear (from the page) forgets the crash records" "0 " "$(st "print(d['problems']['crashes'], d['problems']['error'])")"
[ -n "$(cat "$LF_RUN/daemon.pid")" ] && inr kill -0 "$(cat "$LF_RUN/daemon.pid")" && pass "learning loop running again" || fail "loop not restarted"
# a clean stop / restart is not a crash
lf restart >/dev/null 2>&1; sleep 1; lf cycle
expect "a restart is not a crash" "0" "$(st "print(d['problems']['crashes'])")"

# saved data damaged (power cut while writing, worn flash): left out, not taken as servers / locations
lf stop >/dev/null 2>&1
printf 'garbage line\n77.40.0.1\n' >> "$LF_HOME/data/geo.cache"
printf 'zzz 5\n\n80.20.0.1 notanumber\n' >> "$LF_HOME/data/zones/game.ips"
rm -rf "$LF_RUN"; mkdir -p "$LF_RUN"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.startup"
n=0; while ! ips test lf_game_out4 80.20.0.1 2>/dev/null && [ $n -lt 30 ]; do sleep 0.5; n=$((n + 1)); done
ips test lf_game_out4 80.20.0.1 2>/dev/null && pass "damaged saved data: the filter still loads its servers" || fail "set not loaded after damaged data"
grep -q "zzz" "$LF_RUN/state/game.ips" && fail "a damaged line was taken as a server" || pass "damaged server-list lines left out"
awk '$1 == "77.40.0.1" && $2 == ""' "$LF_RUN/state/geo.cache" | grep -q . && fail "a damaged location line was kept" || pass "damaged location lines left out (looked up again)"
grep -q "damaged line" "$LF_RUN/log" && pass "damaged lines are reported in the log" || fail "no log line about damaged data"

# flash full: saving fails - said once, not on every pass, and tried again later
lf persist
mv "$LF_HOME/data/zones" "$LF_HOME/data/zones.ok"; : > "$LF_HOME/data/zones"
touch "$LF_RUN/dirty_new"; lf persist; lf persist
expect "flash full: one error, not one per try" "1" "$(grep -c "saving the learned servers failed" "$LF_RUN/log")"
[ -f "$LF_RUN/dirty_new" ] && pass "the unsaved servers are still marked for saving" || fail "dirty mark lost"
rm -f "$LF_HOME/data/zones"; mv "$LF_HOME/data/zones.ok" "$LF_HOME/data/zones"
lf persist
[ ! -f "$LF_RUN/dirty_new" ] && [ ! -f "$LF_RUN/persist.err" ] && pass "saving works again once there is room" || fail "persist did not recover"
cgi "$TOKEN" "exec debug clear" >/dev/null

# --- 12c. hardening: settings that would reach other programs as options are refused;
# the web server never listens without the LAN address; a stale start lock is taken over
cfg set lobbyfence.globals.geo_url='-o/tmp/lf_pwn_curl'
cfg set lobbyfence.globals.lag_dev='-x'
cfg set lobbyfence.globals.data_dir='relative/dir'
lf cycle; inr env PATH="$TPATH" "$LF_HOME/lobbyfence" apitest >/dev/null 2>&1; lf cycle
! ls /tmp/lf_pwn_curl* >/dev/null 2>&1 && grep -q "setting geo_url ignored" "$LF_RUN/log" && grep -q "setting lag_dev ignored" "$LF_RUN/log" && grep -q "setting data_dir ignored" "$LF_RUN/log" \
	&& pass "geo_url / lag_dev / data_dir that are not what they should be are ignored (curl can't be handed an option)" || fail "hardening: $(grep ignored "$LF_RUN/log")"
expect "...and said once, not on every pass" "1" "$(grep -c "setting geo_url ignored" "$LF_RUN/log")"
cfg set lobbyfence.globals.geo_url="http://127.0.0.1:8080/batch"
cfg delete lobbyfence.globals.lag_dev; cfg delete lobbyfence.globals.data_dir
cfg set lobbyfence.globals.data_dir="$LF_HOME/data"
lf reload >/dev/null 2>&1
cfg set lobbyfence.globals.geo_url="http://127.0.0.1:8080/batch?key=SeCr3t"
out="$(lf debug)"
echo "$out" | grep -q "SeCr3t" && fail "debug report shows the geolocation key" || { echo "$out" | grep -q "key=(hidden)" && pass "debug report hides a geolocation service key" || fail "key line not found"; }
cfg set lobbyfence.globals.geo_url="http://127.0.0.1:8080/batch"
lan="$(cat "$W/nvram/lan_ipaddr")"
lf web-stop; : > "$W/nvram/lan_ipaddr"
lf web >/dev/null 2>&1
[ -z "$(ours)" ] && grep -q "LAN address (nvram lan_ipaddr) is not set" "$LF_RUN/log" \
	&& pass "no LAN address: the web server is not started (it would listen on every interface)" || fail "web without LAN IP: $(ours)"
echo "$lan" > "$W/nvram/lan_ipaddr"
ln -s "$(( $(date +%s) - 300 ))" "$LF_RUN/web.lock"
lf web >/dev/null 2>&1
[ -n "$(ours)" ] && pass "a start lock left by a start that died is taken over" || fail "stale symlink lock blocked the start"
lf web-stop; mkdir -p "$LF_RUN/web.lock"          # (an older version's lock folder, without its time)
lf web >/dev/null 2>&1
[ -n "$(ours)" ] && [ ! -d "$LF_RUN/web.lock" ] && pass "...also an older version's lock folder" || fail "old lock folder blocked the start"

# --- 13. zone removed / disabled
cfg delete lobbyfence.1st
lf apply
ipt -n -L LF_1st_o4 >/dev/null 2>&1 && fail "deleted zone's chains left" || pass "deleted zone's chains removed"
ips list -n | grep -q "^lf_1st_" && fail "deleted zone's sets left" || pass "deleted zone's sets removed"
cfg set lobbyfence.globals.enabled=0
lf apply
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "disabled: rules left" || pass "disabled: no rules"
cfg set lobbyfence.globals.enabled=1
inr env PATH="$TPATH" "$W/jffs/etc/config/K90lobbyfence"
ipt -n -L LF_FWD >/dev/null 2>&1 && fail "K90 shutdown hook left rules" || pass "the K90 shutdown hook stops LobbyFence (learned servers saved)"

# --- 13b. the RAM folder taken over before the start (a link, or someone else's folder): not used
lf stop >/dev/null 2>&1
rm -rf "$LF_RUN"; mkdir -p "$W/elsewhere"; ln -s "$W/elsewhere" "$LF_RUN"
lf start >/dev/null 2>&1
[ -d "$LF_RUN" ] && [ ! -L "$LF_RUN" ] && [ -z "$(ls -A "$W/elsewhere")" ] && [ -f "$LF_RUN/daemon.pid" ] \
	&& pass "a link put in place of the RAM folder is replaced, nothing written through it" || fail "RAM folder link: $(ls -la "$LF_RUN" "$W/elsewhere" 2>&1 | head -5)"
lf stop >/dev/null 2>&1
rm -rf "$LF_RUN"; mkdir "$LF_RUN"; echo planted > "$LF_RUN/daemon.pid"; chown -R 65534 "$LF_RUN"
lf start >/dev/null 2>&1
[ "$(ls -ldn "$LF_RUN" | awk '{ print $3 }')" = 0 ] && [ "$(cat "$LF_RUN/daemon.pid")" != planted ] \
	&& pass "a folder someone else made in its place is replaced" || fail "RAM folder of another user: $(ls -ldn "$LF_RUN")"

# --- 13c. brick safety: a zone filtering every port and protocol never cuts the
# device off the router itself (its web page, SSH, DNS stand-ins)
inr python3 "$HERE/udp.py" tcpserve 8022 >/dev/null 2>&1 &
inr python3 "$HERE/udp.py" serve 1053 >/dev/null 2>&1 &
sleep 0.5
cfg delete lobbyfence.game.remote_port
cfg add_list lobbyfence.game.remote_port=1-65535
cfg set lobbyfence.game.proto=both
cfg set lobbyfence.game.mode=enforce
cfg set lobbyfence.game.strict=1
cfg delete lobbyfence.game.circle
lf apply
expect "a zone filtering every port, no region: the device's game servers are blocked" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "...the router's own TCP services still answer the device (SSH stand-in)" "192.168.1.1 ok" "$(inl python3 "$HERE/udp.py" tcpprobe 8022 192.168.1.1 | tr '\n' ' ' | sed 's/ $//')"
expect "...and its UDP services (DNS stand-in)" "192.168.1.1 ok" "$(probe_port 1053 192.168.1.1)"
[ "$(inl curl -s --noproxy '*' -m 5 -o /dev/null -w '%{http_code}' http://192.168.1.1:8055/ 2>/dev/null)" = 200 ] \
	&& pass "...and LobbyFence's own page (port 8055, inside the filtered range)" || fail "page not reachable from the filtered device"
# hooks: DD-WRT waits for its startup / firewall / shutdown scripts - they must not
# hold the router up, even while another LobbyFence command hangs (lock held)
sleep 120 & HOLDER=$!
rm -rf "$LF_RUN/lock"; mkdir "$LF_RUN/lock"; echo "$HOLDER" > "$LF_RUN/lock/pid"
t0=$(date +%s)
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.startup"
inr env PATH="$TPATH" "$W/jffs/etc/config/lobbyfence.firewall"
t1=$(date +%s)
[ $((t1 - t0)) -le 2 ] && pass "startup and firewall hooks return at once while LobbyFence is busy ($((t1 - t0)) s)" || fail "hooks held the router up: $((t1 - t0)) s"
t0=$(date +%s)
inr env PATH="$TPATH" "$W/jffs/etc/config/K90lobbyfence"
t1=$(date +%s)
[ $((t1 - t0)) -le 35 ] && ! ipt -n -L LF_FWD >/dev/null 2>&1 \
	&& pass "shutdown hook: LobbyFence stopped within $((t1 - t0)) s although another command hung (reboots are not held up)" || fail "K90 with a hung command: $((t1 - t0)) s, rules: $(ipt -S FORWARD | grep -c LF_)"
kill "$HOLDER" 2>/dev/null; wait "$HOLDER" 2>/dev/null
n=0; while [ -d "$LF_RUN/lock" ] && [ $n -lt 40 ]; do sleep 0.5; n=$((n + 1)); done
lf stop >/dev/null 2>&1
sed -i '/lock held for too long/d' "$W/stderr.log" 2>/dev/null

# --- 14. uninstall
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NVRAM="$LF_NVRAM" "$TOMATO_SH" sh "$HERE/../ddwrt/install.sh" remove >/dev/null 2>&1
[ -z "$(cat "$W/nvram/mypage_scripts" 2>/dev/null)" ] && pass "uninstall takes LobbyFence out of My Page" || fail "mypage_scripts: $(cat "$W/nvram/mypage_scripts")"
[ ! -e "$W/jffs/etc/config/lobbyfence.firewall" ] && [ ! -e "$W/jffs/etc/config/K90lobbyfence" ] && [ ! -e "$LF_HOME/bin" ] && [ -f "$LF_HOME/lobbyfence.conf" ] && [ -d "$LF_HOME/data" ] \
	&& pass "uninstall removes the program and hooks, keeps settings and data" || fail "uninstall: $(find "$W/jffs" | head)"
[ -z "$(ipt -S | grep LF_)" ] && [ -z "$(ips list -n | grep '^lf_')" ] && pass "uninstall leaves no firewall rules or sets" || fail "rules left: $(ipt -S | grep -c LF_)"

# --- 15. brick safety: purge with the copy the installer kept, then a fresh install
# from the release package (unpacked by DD-WRT's own BusyBox), then purge again -
# the router is left exactly as it was before LobbyFence: nvram, JFFS, hooks,
# cron, firewall, ipsets
snapshot() { # -> what LobbyFence could have left behind
	# (wan_ifname: set by this test itself, section 10)
	( cd "$W/nvram" && for f in *; do [ "$f" = wan_ifname ] || printf '%s=%s\n' "$f" "$(cat "$f")"; done )
	echo "-- jffs files:"; find "$W/jffs" -type f | sed "s#$W##" | sort
	echo "-- cron:"; ls "$W/cron.d" 2>/dev/null
	echo "-- iptables:"; ipt -S | grep -i lf_; ipt -t mangle -S | grep -i lf_
	echo "-- ipsets:"; ips list -n | grep '^lf_'
}
initial="$( cd "$W/nvram.initial" && for f in *; do printf '%s=%s\n' "$f" "$(cat "$f")"; done; printf -- '-- jffs files:\n-- cron:\n-- iptables:\n-- ipsets:\n' )"
[ -f "$LF_HOME/install.sh" ] && pass "uninstall keeps a copy of the installer on JFFS (to purge later)" || fail "no installer copy in $LF_HOME"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NVRAM="$LF_NVRAM" "$TOMATO_SH" sh "$LF_HOME/install.sh" purge >/dev/null 2>&1
expect "purge: the router is as it was before LobbyFence (nvram, JFFS, hooks, cron, firewall)" "$initial" "$(snapshot)"
rm -rf "$W/dist" "$W/pkg"; mkdir -p "$W/pkg"
sh "$HERE/../tools/build-packages.sh" "$W/dist" >/dev/null 2>&1 || fail "release packages not built"
( cd "$W/pkg" && "$TOMATO_SH" tar -xzf "$W/dist/lobbyfence-ddwrt.tar.gz" ) && [ -f "$W/pkg/lobbyfence-install/ddwrt/install.sh" ] \
	&& pass "the release package unpacks with DD-WRT's BusyBox into lobbyfence-install (not /tmp/lobbyfence, LobbyFence's RAM folder)" || fail "package does not unpack"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 LF_NVRAM="$LF_NVRAM" LF_LIGHTTPD=1 LF_TC=1 \
	"$TOMATO_SH" sh "$W/pkg/lobbyfence-install/ddwrt/install.sh" > "$W/install2.log" 2>&1 && pass "installs from the release package" || fail "package install: $(tail -3 "$W/install2.log")"
for f in bin/lobbyfence-main share/fw-ipt.sh share/fw-ddwrt.sh www/lobbyfence/map.js; do
	cmp -s "$LF_HOME/$f" "$HERE/../$(grep -m1 ":$f:" "$HERE/../ddwrt/install.sh" | cut -d: -f1)" || fail "package installed a different $f"
done
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
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NVRAM="$LF_NVRAM" "$TOMATO_SH" sh "$LF_HOME/install.sh" purge >/dev/null 2>&1
expect "purge after the package install: the router is as it was before" "$initial" "$(snapshot)"

grep -q "rejected" "$W/run.log" && fail "firewall tools rejected something: $(grep rejected "$W/run.log" | head -2)" || pass "iptables / ipset never rejected a command"
real="$(grep -v -e "no valid address given" -e "is not a public address" "$W/stderr.log" 2>/dev/null)"
[ -z "$real" ] && pass "no error messages" || fail "errors: $(echo "$real" | sort | uniq -c | head -5)"
[ "$FAIL" = 0 ] && echo "ALL DD-WRT TESTS PASSED"
exit $FAIL
