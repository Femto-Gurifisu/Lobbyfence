#!/bin/sh
# End-to-end test: LAN client -> router (LobbyFence) -> WAN game servers,
# all in network namespaces. Needs root, nft, python3 and a BusyBox binary.
#   usage: netns_test.sh <workdir> <busybox> <uci-prefix> <openwrt-checkout>
W="$1"; BB="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/setup_env.sh" "$@" >/dev/null || exit 1
. "$W/env.sh"
IP="$BB ip"
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
expect() { # description, expected, actual
	if [ "$2" = "$3" ]; then pass "$1"; else fail "$1 (expected '$2', got '$3')"; fi
}

unshare -n sleep 900 & LAN=$!
unshare -n sleep 900 & RTR=$!
unshare -n sleep 900 & WAN=$!
sleep 0.3
inl() { nsenter -t $LAN -n "$@"; }
inr() { nsenter -t $RTR -n "$@"; }
inw() { nsenter -t $WAN -n "$@"; }

# router <-> lan (rl / veth0), router <-> wan (rw / veth1)
inr $IP link add rl type veth
inr $IP link add rw type veth
inr $IP link set dev veth0 netns $LAN
inr $IP link set dev veth1 netns $WAN
for p in $LAN $RTR $WAN; do nsenter -t $p -n $IP link set lo up; done

inr $IP addr add 192.168.1.1/24 dev rl;  inr $IP link set rl up
inr $IP addr add 10.99.0.1/24 dev rw;    inr $IP link set rw up
inr sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'

inl $IP addr add 192.168.1.100/24 dev veth0; inl $IP link set veth0 up
inl $IP route add default via 192.168.1.1

inw $IP addr add 10.99.0.2/24 dev veth1; inw $IP link set veth1 up
for s in 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1 61.0.0.1 61.0.0.2 61.0.0.3 61.0.0.4 62.0.0.1 63.0.0.1; do
	inw $IP addr add $s/32 dev veth1
	inr $IP route add $s/32 via 10.99.0.2
done
inw $IP route add 192.168.1.0/24 via 10.99.0.1

inw python3 "$HERE/udp.py" serve 3074 & SRV=$!
inw python3 "$HERE/udp.py" serve 5555 & SRV2=$!
inr python3 "$HERE/fake_geo.py" 8080 "$W/geo_calls.log" & GEO=$!
trap 'kill $LAN $RTR $WAN $SRV $SRV2 $GEO 2>/dev/null; pkill -f "^python3 .*(udp|fake_geo|fake_form).py" 2>/dev/null' EXIT INT TERM
sleep 0.5

probe() { inl python3 "$HERE/udp.py" probe 3074 "$@" | tr '\n' ' ' | sed 's/ $//'; }
probe_port() { p="$1"; shift; inl python3 "$HERE/udp.py" probe "$p" "$@" | tr '\n' ' ' | sed 's/ $//'; }
lf() { inr $LF "$@" 2>>"$W/stderr.log"; }   # errors collected, checked at the end
cfg() { "$W/bin/uci" "$@"; }

cfg set lobbyfence.globals.enabled=1
cfg set lobbyfence.globals.geo_url='http://127.0.0.1:8080/batch'
cfg set lobbyfence.globals.data_dir="$W/data"
cfg set lobbyfence.globals.log_blocked=1
# fresh install has no zones: create one the way the map page does
grep -q "config zone" "$W/etc/config/lobbyfence" && fail "default config should have no zones"
cfg set lobbyfence.game=zone
cfg set lobbyfence.game.enabled=1
cfg set lobbyfence.game.label='Test "game"'
cfg set lobbyfence.game.mode=monitor
cfg set lobbyfence.game.strict=0
cfg set lobbyfence.game.burst_servers=0
cfg add_list lobbyfence.game.device=192.168.1.100
cfg set lobbyfence.game.proto=udp
cfg set lobbyfence.game.game=fortnite
cfg add_list lobbyfence.game.remote_port=3074
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800
cfg commit lobbyfence
# a zone whose name starts with a digit must still produce a valid ruleset
cfg set lobbyfence.1st=zone
cfg set lobbyfence.1st.enabled=1
cfg add_list lobbyfence.1st.device=192.168.1.200
cfg add_list lobbyfence.1st.remote_port=9999
cfg commit lobbyfence

# --- 0. sanity: no filter yet
expect "baseline connectivity" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

# --- 1. apply in monitor mode
lf apply || fail "apply returned error"
inr nft list table inet lobbyfence > "$W/table.txt" 2>&1 && pass "table loaded" || { fail "table not loaded"; cat "$W/run/nft.err"; }
expect "monitor mode lets everything through" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

# --- 2. learn + locate
lf cycle
expect "three servers learned" 3 "$(wc -l < "$W/run/state/game.ips" | tr -d ' ')"
expect "state of 45.10.0.1" in "$(awk '$1=="45.10.0.1"{print $2}' "$W/run/game.servers")"
expect "state of 80.20.0.1" out "$(awk '$1=="80.20.0.1"{print $2}' "$W/run/game.servers")"
expect "state of 99.30.0.1" unloc "$(awk '$1=="99.30.0.1"{print $2}' "$W/run/game.servers")"
expect "one batch lookup sent" 1 "$(wc -l < "$W/geo_calls.log" | tr -d ' ')"
expect "in4 set holds the inside server" 1 "$(inr nft list set inet lobbyfence z_game_in4 | grep -c 45.10.0.1)"
expect "out4 set holds the outside server" 1 "$(inr nft list set inet lobbyfence z_game_out4 | grep -c 80.20.0.1)"

probe 80.20.0.1 >/dev/null
hits="$(inr nft list chain inet lobbyfence z_game_x | awk '/counter packets/{for(i=1;i<NF;i++) if($i=="packets") print $(i+1)}')"
[ "${hits:-0}" -gt 0 ] && pass "monitor mode counts would-be blocks ($hits)" || fail "monitor hit counter stayed 0"

# second cycle must not look the same addresses up again
lf cycle
expect "no repeated lookups" 1 "$(wc -l < "$W/geo_calls.log" | tr -d ' ')"

# --- 3. enforce
cfg set lobbyfence.game.mode=enforce; cfg commit lobbyfence
lf apply
expect "enforce: outside blocked, unlocated allowed" \
	"45.10.0.1 ok 80.20.0.1 blocked 99.30.0.1 ok 77.40.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1)"

# --- 4. strict
cfg set lobbyfence.game.strict=1; cfg commit lobbyfence
lf apply
expect "strict: only located inside servers pass" \
	"45.10.0.1 ok 80.20.0.1 blocked 99.30.0.1 blocked 77.40.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1)"

# --- 5. allow / block overrides
cfg add_list lobbyfence.game.allow_ip=80.20.0.0/24
cfg add_list lobbyfence.game.block_ip=45.10.0.1
cfg commit lobbyfence
lf apply
expect "allow_ip / block_ip override geography" \
	"45.10.0.1 blocked 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
cfg delete lobbyfence.game.allow_ip; cfg delete lobbyfence.game.block_ip; cfg commit lobbyfence

# --- 6. country rule (US allowed in addition to the circle)
cfg add_list lobbyfence.game.country=us; cfg commit lobbyfence
lf apply
expect "country rule allows the US server" "80.20.0.1 ok" "$(probe 80.20.0.1)"
cfg delete lobbyfence.game.country; cfg commit lobbyfence

# --- 6b. polygon region (a box around New York instead of the Frankfurt circle)
cfg delete lobbyfence.game.circle
cfg add_list lobbyfence.game.polygon='38,-80;45,-80;45,-70;38,-70'
cfg commit lobbyfence
lf apply
expect "polygon decides inside/outside" "45.10.0.1 blocked 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
cfg delete lobbyfence.game.polygon; cfg add_list lobbyfence.game.circle=50.1109,8.6821,800; cfg commit lobbyfence
lf apply

# --- 6c. no region drawn: nothing is inside, so strict / enforce block every server
cfg delete lobbyfence.game.circle; cfg commit lobbyfence
lf apply
expect "no region: every server blocked" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf allow game 45.10.0.1 >/dev/null
expect "no region: whitelisted servers still allowed" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf unlist game 45.10.0.1 >/dev/null
cfg add_list lobbyfence.game.circle=50.1109,8.6821,800; cfg commit lobbyfence
lf apply

# --- 7. ports outside the zone are untouched
cfg set lobbyfence.game.remote_port=4000; cfg commit lobbyfence
lf apply
expect "traffic on other ports is not filtered" "80.20.0.1 ok" "$(probe 80.20.0.1)"
cfg delete lobbyfence.game.remote_port; cfg add_list lobbyfence.game.remote_port=3074; cfg commit lobbyfence
lf apply

# --- 7b. phone-style zone: device given only by MAC, game port on either side
LANMAC="$(inl $IP link show veth0 | awk '/link\/ether/ { print $2 }')"
cfg delete lobbyfence.game.device; cfg add_list lobbyfence.game.device="$(echo "$LANMAC" | tr 'a-f' 'A-F')"
cfg delete lobbyfence.game.remote_port; cfg add_list lobbyfence.game.port=3074
cfg commit lobbyfence
lf apply || fail "apply with MAC device"
expect "MAC-only device: geography still enforced" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "either-side port: device port 3074 to server port 5555 is filtered" "80.20.0.1 blocked" "$(probe_port 5555 80.20.0.1)"
lf cycle
grep -qx "192.168.1.100" "$W/run/game.mip" && pass "MAC resolved to the device's current IP" || fail "MAC resolution ($(cat "$W/run/game.mip" 2>/dev/null))"
inr nft list set inet lobbyfence z_game_mip4 | grep -q "192.168.1.100" && pass "resolved IP loaded for inbound matching" || fail "z_game_mip4 empty"
python3 -c "import json,sys; z=json.load(open(sys.argv[1]))['zones'][0]; assert z['macs']==1 and '192.168.1.100' in z['devices'], z" "$W/run/status.json" \
	&& pass "status.json lists the device's addresses" || fail "status.json devices"
devs="$(lf devices)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); m=sys.argv[2].lower(); e=[x for x in d if x['mac']==m]; assert e and '192.168.1.100' in e[0]['ipv4'], d" "$devs" "$LANMAC" \
	&& pass "devices lists the console with its IP and MAC" || fail "devices: $devs"
# the internet side's neighbours (the ISP's gateway) are not LAN devices
inr $IP route add default via 10.99.0.2
inr $BB ping -c1 -W1 10.99.0.2 >/dev/null 2>&1
inr grep -q "^10.99.0.2 .* rw" /proc/net/arp || fail "test setup: no ARP entry for the WAN gateway"
devs="$(lf devices)"
inr $IP route del default via 10.99.0.2
python3 -c "import sys; d=sys.argv[1]; assert '10.99.0.2' not in d and '192.168.1.100' in d, d" "$devs" \
	&& pass "devices leaves out the WAN side's neighbours (the ISP's gateway)" || fail "devices lists the WAN gateway: $devs"
inr nft list chain inet lobbyfence z_game_o4 | grep -q "update @z_game_seen4" && ! inr nft list chain inet lobbyfence z_game_o4 | grep -q "ct state new update @z_game_seen4" \
	&& pass "outbound traffic keeps servers seen" || fail "seen rule"
# back to the plain IP device for the remaining steps
cfg delete lobbyfence.game.device; cfg add_list lobbyfence.game.device=192.168.1.100
cfg delete lobbyfence.game.port; cfg add_list lobbyfence.game.remote_port=3074
cfg commit lobbyfence
lf apply
expect "remote_port only: other server ports untouched" "80.20.0.1 ok" "$(probe_port 5555 80.20.0.1)"

# --- 7c. click-to-allow / block: live, without Save & Apply
out="$(lf allow game 80.20.0.1)"
expect "allow takes effect at once" "80.20.0.1 ok" "$(probe 80.20.0.1)"
lf block game 45.10.0.1 >/dev/null
expect "block takes effect at once (even inside the region)" "45.10.0.1 blocked" "$(probe 45.10.0.1)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1]))['zones'][0]; assert d['allow']==['80.20.0.1'] and d['block']==['45.10.0.1'], d" "$W/run/status.json" \
	&& pass "rules listed in status.json" || fail "status.json allow/block"
[ "$(cfg -q get lobbyfence.game.allow_ip)" = "80.20.0.1" ] && pass "rule saved in the configuration" || fail "uci allow_ip"
lf block game 80.20.0.1 >/dev/null
expect "switching a server from allow to block" "80.20.0.1 blocked" "$(probe 80.20.0.1)"
[ -z "$(cfg -q get lobbyfence.game.allow_ip)" ] && pass "allow rule removed when blocking" || fail "allow_ip not cleared"
lf unlist game 80.20.0.1 45.10.0.1 >/dev/null
expect "unlist returns to the geographic decision" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
lf allow nosuchzone 1.2.3.4 >/dev/null 2>&1 && fail "allow accepted an unknown zone" || pass "allow rejects unknown zones"
lf allow game garbage >/dev/null 2>&1 && fail "allow accepted garbage" || pass "allow rejects invalid addresses"

# --- 7d. open for server tests: more than 3 servers at once opens the zone briefly
cfg set lobbyfence.game.mode=enforce; cfg set lobbyfence.game.strict=1
cfg set lobbyfence.game.burst_servers=3; cfg set lobbyfence.game.burst_open=4
cfg commit lobbyfence
lf apply || fail "apply with burst"
inr nft list chain inet lobbyfence z_game_b4 >/dev/null 2>&1 && pass "burst chain loaded" || { fail "burst chain missing"; cat "$W/run/nft.err"; }
expect "3 servers: still filtered" "80.20.0.1 blocked 61.0.0.1 blocked 61.0.0.2 blocked" "$(probe 80.20.0.1 61.0.0.1 61.0.0.2)"
expect "4th server at once: zone opens" "61.0.0.3 ok" "$(probe 61.0.0.3)"
expect "while open, outside servers get through" "80.20.0.1 ok" "$(probe 80.20.0.1)"
live="$(lf live)"
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 1 <= z['open_left'] <= 4 and z['opened'] > 0, z" "$live" \
	&& pass "live state shows the zone open ($live)" || fail "live: $live"
sleep 12   # open time (4 s) and the counting window (10 s) both over
expect "after the open time the regions apply again" "80.20.0.1 blocked" "$(probe 80.20.0.1)"
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert z['open_left'] == 0, z" "$(lf live)" \
	&& pass "live state shows it closed" || fail "still open"
lf status >/dev/null
python3 -c "import json,sys; z=json.load(open(sys.argv[1]))['zones'][0]; assert z['burst']==3 and z['burst_open']==4 and z['opened']>0, z" "$W/run/status.json" \
	&& pass "status.json reports the setting" || fail "status.json burst fields"
cfg set lobbyfence.game.burst_servers=0; cfg commit lobbyfence; lf apply
inr nft list table inet lobbyfence | grep -q z_game_b4 && fail "burst chain left with 0" || pass "0 turns it off"
inr nft list table inet lobbyfence | grep -q z_1st_b4 && fail "zones without a setting should not open for server tests" || pass "open for server tests is off by default"

# --- 7e. "active now" = traffic within the last 30 seconds
probe 45.10.0.1 >/dev/null
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 0 <= z['active']['45.10.0.1'] <= 3 and z['active_window'] == 15, z" "$(lf live)" \
	&& pass "a server in use is listed as active, with its last-packet age" || fail "active list: $(lf live)"
inr nft list chain inet lobbyfence z_game_i4 | grep -q "@z_game_now4" && fail "server-sent packets count as activity" \
	|| pass "only packets from the device count as activity"
sleep 5
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert 4 <= z['active']['45.10.0.1'] <= 7, z" "$(lf live)" \
	&& pass "age grows while the device is quiet" || fail "age: $(lf live)"
sleep 12
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; assert not z['active'], z" "$(lf live)" \
	&& pass "15 s without packets from the device: no longer active" || fail "still active: $(lf live)"

# --- 7f. a brand-new outside server is blocked within seconds (background service running)
cfg set lobbyfence.game.mode=enforce; cfg set lobbyfence.game.strict=0; cfg set lobbyfence.globals.interval=60; cfg commit lobbyfence
lf apply
inr $LF daemon >/dev/null 2>&1 & DAEMON=$!
sleep 3
expect "enforce: an unknown server first gets through" "62.0.0.1 ok" "$(probe 62.0.0.1)"
t0=$(date +%s); res=ok
while [ $(( $(date +%s) - t0 )) -lt 15 ]; do
	res="$(probe 62.0.0.1 | awk '{print $2}')"; [ "$res" = blocked ] && break
done
took=$(( $(date +%s) - t0 ))
[ "$res" = blocked ] && [ "$took" -le 8 ] && pass "new outside server blocked after ${took}s (learning cycle is 60s)" || fail "not blocked fast ($res after ${took}s)"

# --- 7g. "active now" needs real traffic: a busy server vs a single ping
probe 63.0.0.1 >/dev/null      # (one at a time: both use local port 3074)
inl python3 "$HERE/udp.py" stream 3074 45.10.0.1 20 6 & STREAM=$!
sleep 2; lf live >/dev/null; sleep 1.5
live="$(lf live)"
wait $STREAM
python3 -c "import json,sys; z=json.loads(sys.argv[1])['zones']['game']; r=z['rate']; assert r['45.10.0.1'] >= 5 and r.get('63.0.0.1', 0) < 1, r" "$live" \
	&& pass "packet rate tells game traffic from a single ping" || fail "rates: $live"
kill "$(cat "$W/run/daemon.pid")" $DAEMON 2>/dev/null; wait $DAEMON 2>/dev/null
cfg set lobbyfence.globals.interval=20; cfg set lobbyfence.game.strict=1; cfg commit lobbyfence
lf apply

# --- 7h. lag simulator (netem): only this device's game traffic gets the lag,
# in the direction(s) chosen
# (needs an iproute2 "tc"; point LF_REAL_TC at one if it is not on PATH)
if command -v "${LF_REAL_TC:-tc}" >/dev/null 2>&1; then
export LF_TC="$HERE/fake_tc.sh" LF_REAL_TC="${LF_REAL_TC:-tc}" LF_TC_LOG="$W/tc.log" LF_TC_DEVIP=192.168.1.100 LF_IP="$IP"
# answer from the server's own address for these checks (like a real game server)
kill $SRV 2>/dev/null; pkill -f "^python3 .*udp.py serve 3074" 2>/dev/null; sleep 0.2
inw python3 "$HERE/udp.py" serve_from 3074 & SRV=$!
sleep 0.4
# a second table after LobbyFence counts the tagged packets of each direction
inr nft -f - <<'NFT'
table inet lagcheck {
	counter down { }
	counter up { }
	chain f {
		type filter hook forward priority 10; policy accept;
		ip daddr 192.168.1.100 meta mark & 0x7f000000 == 0x01000000 counter name "down"
		ip saddr 192.168.1.100 ct mark & 0x7f000000 == 0x01000000 counter name "up"
	}
}
NFT
cnt() { inr nft list counter inet lagcheck "$1" | awk '/packets/ { for (i = 1; i < NF; i++) if ($i == "packets") print $(i + 1) }'; }
qd() { inr "$LF_REAL_TC" -s qdisc show dev lflag1 | awk '/Sent/ { print $4; exit }'; }
lagrun() { # direction -> probes once; sets R and D U Q (tagged down, tagged up, queue packets)
	: > "$W/tc.log"
	cfg set lobbyfence.game.lag=1; cfg set lobbyfence.game.lag_delay=80; cfg set lobbyfence.game.lag_jitter=10
	cfg set lobbyfence.game.lag_loss=1.5; cfg set lobbyfence.game.lag_direction="$1"; cfg commit lobbyfence
	lf apply
	d0="$(cnt down)"; u0="$(cnt up)"; q0="$(qd)"
	R="$(probe 45.10.0.1)"
	probe_port 5555 45.10.0.1 >/dev/null
	D=$(( $(cnt down) - d0 )); U=$(( $(cnt up) - u0 )); Q=$(( $(qd) - ${q0:-0} ))
}

lagrun down
expect "lag down: the game still works" "45.10.0.1 ok" "$R"
grep -q "root netem limit 10000 delay 80ms 10ms loss 1.5%" "$W/tc.log" && pass "lag down: netem gets ping, jitter and loss" || fail "lag down: netem args: $(cat "$W/tc.log")"
grep -q "filter add dev rl egress pref 4915 protocol all handle 0x1000000/0x7f000000 fw action mirred egress redirect dev lflag1" "$W/tc.log" \
	&& pass "lag down: LAN egress filter redirects the tagged packets" || fail "lag down: filter: $(cat "$W/tc.log")"
grep -q "filter add dev rl ingress" "$W/tc.log" && fail "lag down: upload filters added" || pass "lag down: no upload filters"
[ "$D" = 1 ] && [ "$U" = 0 ] && pass "lag down: only the game's reply is tagged" || fail "lag down: tagged down=$D up=$U"
[ "$Q" -ge 1 ] && pass "lag down: it passes through the lag queue" || fail "lag down: queue saw $Q"

lagrun up
expect "lag up: the game still works" "45.10.0.1 ok" "$R"
grep -q "root netem limit 10000 delay 80ms 10ms loss 1.5%" "$W/tc.log" && pass "lag up: full delay on the way out" || fail "lag up: netem args: $(cat "$W/tc.log")"
grep -q "filter add dev rl ingress pref 4914 protocol ip u32 match ip src 192.168.1.100/32 action ctinfo cpmark 0x7f000000 continue" "$W/tc.log" \
	&& pass "lag up: connection mark copied onto the zone device's uploads" || fail "lag up: ctinfo filter: $(cat "$W/tc.log")"
grep "action ctinfo" "$W/tc.log" | grep -v "match ip src 192.168.1.100/32" | grep -q . \
	&& fail "lag up: the mark is copied for other devices' packets too: $(grep "action ctinfo" "$W/tc.log")" || pass "lag up: other devices' packets are left alone"
grep -q "filter add dev rl ingress pref 4915 protocol all handle 0x1000000/0x7f000000 fw action mirred egress redirect dev lflag1" "$W/tc.log" \
	&& pass "lag up: LAN ingress filter redirects the game's uploads" || fail "lag up: filter: $(cat "$W/tc.log")"
grep -q "filter add dev rl egress pref 4915" "$W/tc.log" && fail "lag up: download filter added" || pass "lag up: no download filter"
[ "$U" -ge 1 ] && [ "$D" = 0 ] && pass "lag up: the game's connection is tagged, its replies are not" || fail "lag up: tagged down=$D up=$U"
[ "$Q" -ge 1 ] && pass "lag up: uploads pass through the lag queue" || fail "lag up: queue saw $Q"

lagrun both
expect "lag both: the game still works" "45.10.0.1 ok" "$R"
grep -q "root netem limit 10000 delay 40ms 5ms loss 1.5%" "$W/tc.log" && pass "lag both: delay split in half each way (adds up to 80 ms)" || fail "lag both: netem args: $(cat "$W/tc.log")"
grep -q " egress pref 4915" "$W/tc.log" && grep -q " ingress pref 4915" "$W/tc.log" && pass "lag both: filters for both directions" || fail "lag both: filters: $(cat "$W/tc.log")"
[ "$D" = 1 ] && [ "$U" -ge 1 ] && pass "lag both: both directions tagged" || fail "lag both: tagged down=$D up=$U"
[ "$Q" -ge 2 ] && pass "lag both: both directions pass through the lag queue ($Q)" || fail "lag both: queue saw $Q"
grep -q "TC-ERROR" "$W/tc.log" && fail "lag: tc rejected a command: $(grep TC-ERROR "$W/tc.log")" || pass "lag: every tc command is valid"
lf status >/dev/null
python3 -c "import json,sys; z=json.load(open(sys.argv[1]))['zones'][0]['lag']; assert z['on'] and z['dir']=='both' and z['delay']==80 and z['jitter']==10 and z['loss']==1.5 and z['active'] and z['error']=='', z" "$W/run/status.json" \
	&& pass "lag: status.json reports it" || fail "lag: status $(cat "$W/run/status.json")"

# hand-edited odd numbers must not break status.json
cfg set lobbyfence.game.lag_delay=007; cfg set lobbyfence.game.lag_loss=5.; cfg set lobbyfence.game.burst_servers=05; cfg commit lobbyfence
lf status >/dev/null
python3 -c "import json,sys; z=json.load(open(sys.argv[1]))['zones'][0]; assert z['lag']['delay']==7 and z['lag']['loss']==0 and z['burst']==5, z" "$W/run/status.json" \
	&& pass "odd hand-edited numbers keep status.json valid" || fail "status.json broken by odd numbers: $(head -c 300 "$W/run/status.json")"
cfg set lobbyfence.game.lag_delay=80; cfg set lobbyfence.game.lag_loss=1.5; cfg set lobbyfence.game.burst_servers=0; cfg commit lobbyfence

# the LAN device restarting wipes its hooks: the next pass puts them back
inr "$LF_REAL_TC" qdisc del dev rl clsact
lf cycle
inr "$LF_REAL_TC" filter show dev rl egress pref 4915 | grep -q . && inr "$LF_REAL_TC" filter show dev rl ingress pref 4915 | grep -q . \
	&& pass "lag: filters come back after the LAN device lost them" || fail "lag: not restored after a network restart"
lf cycle
[ "$(grep -c "went missing" "$W/run.log" 2>/dev/null)" = 1 ] && pass "lag: no repeated repairs once restored" || fail "lag: repairs every pass"
# a device of the zone gets another address (DHCP, a phone given by MAC): its
# upload hook follows on the next pass
: > "$W/tc.log"
cfg add_list lobbyfence.game.device=192.168.1.150; cfg commit lobbyfence
lf cycle; lf cycle
grep -q "ingress pref 4914 protocol ip u32 match ip src 192.168.1.150/32 action ctinfo" "$W/tc.log" \
	&& pass "lag: a device's new address gets its upload hook on the next pass" || fail "lag: no hook for the new address: $(cat "$W/tc.log")"
: > "$W/tc.log"; lf cycle
grep -q "filter add" "$W/tc.log" && fail "lag: hooks set up again with nothing changed" || pass "lag: and only then"
cfg del_list lobbyfence.game.device=192.168.1.150; cfg commit lobbyfence

cfg set lobbyfence.game.lag=0; cfg commit lobbyfence
lf apply
inr $IP link show lflag1 >/dev/null 2>&1 && fail "lag: queue left behind" || pass "lag: switching it off removes the queue"
inr "$LF_REAL_TC" filter show dev rl egress | grep -q . && fail "lag: egress filter left behind" || pass "lag: and the download filter"
inr "$LF_REAL_TC" filter show dev rl ingress | grep -q . && fail "lag: ingress filters left behind" || pass "lag: and the upload filters"
inr "$LF_REAL_TC" qdisc show dev rl | grep -q clsact && fail "lag: clsact left behind" || pass "lag: and the hook LobbyFence added"
inr nft delete table inet lagcheck
kill $SRV 2>/dev/null; pkill -f "^python3 .*udp.py serve_from 3074" 2>/dev/null; sleep 0.2
inw python3 "$HERE/udp.py" serve 3074 & SRV=$!
sleep 0.4
unset LF_TC LF_IP
else
	echo "SKIP: lag simulator checks (no tc program)"
fi

# --- 8. status json, list, whereis
lf status >/dev/null
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); z=d['zones'][0]; assert z['id']=='game' and z['inside']==1 and z['outside']==2 and z['rev'] >= 1, z; print('PASS: status.json valid:', z)" "$W/run/status.json" || fail "status.json"
lf list game out | grep -q 80.20.0.1 && pass "list filter" || fail "list filter"
r1=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['zones'][0]['rev'])" "$W/run/status.json")
lf cycle; lf cycle
r2=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['zones'][0]['rev'])" "$W/run/status.json")
[ "$r1" = "$r2" ] && pass "server list revision stays put when nothing changed" || fail "revision moved without changes ($r1 -> $r2)"
# Save & Apply with the same region reuses the classification (fast) and still loads every server
lf apply
r2b=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['zones'][0]['rev'])" "$W/run/status.json")
[ "$r2b" = "$r2" ] && inr nft list set inet lobbyfence z_game_out4 | grep -q 80.20.0.1 \
	&& expect "apply with an unchanged region: same verdicts, nothing reclassified" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)" \
	|| fail "apply with unchanged region: rev $r2 -> $r2b or sets not loaded"
lf forget game 99.30.0.1 >/dev/null; lf status >/dev/null
r3=$(python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['zones'][0]['rev'])" "$W/run/status.json")
[ "$r3" -gt "$r2" ] && pass "...and moves when the list changes ($r2 -> $r3)" || fail "revision did not move after forget ($r2 -> $r3)"
lf whereis 80.20.0.1 | grep -q "zone game: out" && pass "whereis" || fail "whereis"

# --- 8b. debug report; an unexpected stop of the learning loop is recorded
out="$(lf debug)"
echo "$out" | grep -q "^LobbyFence debug report" && echo "$out" | grep -q "^nftables table inet lobbyfence" && echo "$out" | grep -q "^==== End of report" \
	&& pass "debug report with the nftables table" || fail "debug: $(echo "$out" | head -5)"
echo "$out" | grep -q "elements = " && fail "debug report lists the server sets (too long)" || pass "debug report leaves the server lists out"
inr $LF daemon >/dev/null 2>&1 & DAEMON=$!
n=0; while [ ! -f "$W/run/daemon.alive" ] && [ $n -lt 20 ]; do sleep 0.2; n=$((n + 1)); done
kill -9 "$(cat "$W/run/daemon.pid")"; wait $DAEMON 2>/dev/null
inr $LF daemon >/dev/null 2>&1 & DAEMON=$!     # (procd starts it again)
n=0; while ! grep -q "^=== crash" "$W/data/crash.log" 2>/dev/null && [ $n -lt 25 ]; do sleep 0.2; n=$((n + 1)); done
grep -q "^=== crash" "$W/data/crash.log" 2>/dev/null && pass "a killed learning loop is recorded as a crash when it is started again" || fail "no crash record"
kill "$(cat "$W/run/daemon.pid")" 2>/dev/null; wait $DAEMON 2>/dev/null
[ ! -f "$W/run/daemon.alive" ] && pass "a normal stop leaves no crash mark" || fail "daemon.alive left after TERM"
lf status >/dev/null
python3 -c "import json,sys; p=json.load(open(sys.argv[1]))['problems']; assert p['crashes']==1 and p['error_time']>0, p" "$W/run/status.json" && pass "status.json: crash count and last error" || fail "problems: $(cat "$W/run/status.json" | head -c 300)"
# a loop that keeps stopping (procd starts it again every 5 s): one record on
# flash per 10 minutes at most, the others in RAM - the newest 8 of them
m1="$(md5sum < "$W/data/crash.log")"
for i in 1 2 3 4 5 6 7 8 9 10; do
	echo "999999 $(date +%s)" > "$W/run/daemon.alive"
	inr $LF daemon >/dev/null 2>&1 & DAEMON=$!
	n=0; while [ "$(cut -d' ' -f1 "$W/run/daemon.alive" 2>/dev/null)" = 999999 ] && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
	kill "$(cat "$W/run/daemon.pid")" 2>/dev/null; wait $DAEMON 2>/dev/null
done
[ "$(md5sum < "$W/data/crash.log")" = "$m1" ] && pass "a crash loop does not write the flash again within 10 minutes" || fail "crash.log on flash rewritten"
expect "...the records go to RAM, the newest 8 kept" 8 "$(grep -c '^=== crash' "$W/run/crash.log" 2>/dev/null)"
lf status >/dev/null
python3 -c "import json,sys; p=json.load(open(sys.argv[1]))['problems']; assert p['crashes']==9, p" "$W/run/status.json" && pass "...and are counted with the one on flash" || fail "problems: $(head -c 300 "$W/run/status.json")"
lf debug clear >/dev/null
python3 -c "import json,sys; p=json.load(open(sys.argv[1]))['problems']; assert p['crashes']==0 and p['error']=='', p" "$W/run/status.json" && pass "debug clear" || fail "debug clear"

# --- 9. import + forget
printf '51.50.0.1, 8.8.8.8\n10.0.0.5 garbage\n' | lf import game - | grep -q "imported 2" && pass "import keeps only public addresses" || fail "import"
lf forget game 8.8.8.8 >/dev/null
grep -q '^8.8.8.8 ' "$W/run/state/game.ips" && fail "forget" || pass "forget"

# --- 9b. IPv6: the same filtering for a device's IPv6 game traffic
if python3 -c "import socket; socket.socket(socket.AF_INET6, socket.SOCK_DGRAM)" 2>/dev/null; then
inl $IP -6 addr add fd00:1::100/64 dev veth0 nodad; inr $IP -6 addr add fd00:1::1/64 dev rl nodad
inr $IP -6 addr add fd99::1/64 dev rw nodad;       inw $IP -6 addr add fd99::2/64 dev veth1 nodad
inr sh -c 'echo 1 > /proc/sys/net/ipv6/conf/all/forwarding'
inl $IP -6 route add default via fd00:1::1
for s in 2a00:1450::1 2600:1::1; do inw $IP -6 addr add $s/128 dev veth1 nodad; inr $IP -6 route add $s/128 via fd99::2; done
inw $IP -6 route add fd00:1::/64 via fd99::1
inw python3 "$HERE/udp.py" serve6 3074 & SRV6=$!
sleep 0.5
cfg add_list lobbyfence.game.device=fd00:1::100; cfg commit lobbyfence
lf apply
probe 2a00:1450::1 2600:1::1 >/dev/null     # strict: unknown servers wait until located
lf cycle
expect "IPv6: server inside the region allowed, outside blocked" "2a00:1450::1 ok 2600:1::1 blocked" "$(probe 2a00:1450::1 2600:1::1)"
inr nft list set inet lobbyfence z_game_out6 | grep -q "2600:1::1" && pass "IPv6: outside server in the IPv6 block set" || fail "IPv6: z_game_out6 lacks 2600:1::1"
lf list game | grep -q "2a00:1450::1 in" && pass "IPv6: listed as inside" || fail "IPv6: list: $(lf list game | grep 2a00)"
kill $SRV6 2>/dev/null; pkill -f "^python3 .*udp.py serve6" 2>/dev/null
cfg del_list lobbyfence.game.device=fd00:1::100; cfg commit lobbyfence
lf apply
else
	echo "SKIP: IPv6 checks (this kernel has no IPv6)"
fi

# --- 10. firewall table self-heals
inr nft delete table inet lobbyfence
lf cycle
inr nft list table inet lobbyfence >/dev/null 2>&1 && pass "table rebuilt by cycle" || fail "table not rebuilt"

# --- 10b. the kernel refuses the new rule set: no rules are left - not the old
# settings' either (the router works as without LobbyFence) - and the next
# learning pass tries again
cat > "$W/nft-refuse" <<'EOF'
#!/bin/sh
# refuses LobbyFence's rule set (like a kernel without a feature it uses), runs the rest
if [ "$1" = -f ] && grep -q "^chain forward" "$2" 2>/dev/null; then echo "Error: Could not process rule: No such file or directory" >&2; exit 1; fi
exec nft "$@"
EOF
chmod +x "$W/nft-refuse"
before="$(probe 45.10.0.1 80.20.0.1)"
inr env NFT="$W/nft-refuse" $LF apply >/dev/null 2>&1 && fail "apply said it worked" || pass "a refused rule set: apply reports the failure"
inr env NFT="$W/nft-refuse" $LF cycle >/dev/null 2>&1   # (a learning pass trying again, still refused)
inr nft list table inet lobbyfence >/dev/null 2>&1 && fail "the old rules were left in place" || pass "...and leaves no rules behind (not the old ones either)"
expect "...so the router works as without LobbyFence" "45.10.0.1 ok 80.20.0.1 ok" "$(probe 45.10.0.1 80.20.0.1)"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert d['active'] is False and 'nft rejected' in d['problems']['error'], d['problems']" "$W/run/status.json" \
	&& pass "...the status says so, with the reason" || fail "status after a refused apply: $(head -c 400 "$W/run/status.json")"
lf cycle
inr nft list table inet lobbyfence >/dev/null 2>&1 && expect "the next learning pass puts the rules in place again" "$before" "$(probe 45.10.0.1 80.20.0.1)" \
	|| fail "rules not back after a pass"
[ "$(grep -c "could not be put in place" "$W/run.log")" = 1 ] && pass "said once in the log, not on every pass" || fail "log: $(grep -c "could not be put in place" "$W/run.log")"

# --- 11. persist + teardown + restore after "reboot"
lf teardown
inr nft list table inet lobbyfence >/dev/null 2>&1 && fail "table still present after teardown" || pass "teardown removes table"
[ -s "$W/data/zones/game.ips" ] && [ -s "$W/data/geo.cache" ] && pass "learned data persisted" || fail "persist"
mt() { python3 -c "import os,sys; print(os.stat(sys.argv[1]).st_mtime_ns, os.stat(sys.argv[2]).st_mtime_ns)" "$W/data/geo.cache" "$W/data/zones/game.ips"; }
m1="$(mt)"; sleep 1.1; lf persist; m2="$(mt)"
[ "$m1" = "$m2" ] && pass "saving again with nothing new writes nothing to flash" || fail "unchanged files rewritten ($m1 -> $m2)"
rm -rf "$W/run"                                            # simulate reboot (tmpfs gone)
lf apply
expect "after reboot: restored data enforced immediately" \
	"45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
grep -q "add element inet lobbyfence z_game_out4 {.*80.20.0.1" "$W/run/ruleset.nft" && grep -q "^delete table inet lobbyfence" "$W/run/ruleset.nft" \
	&& pass "rules and learned servers are applied in one transaction (no gap)" || fail "ruleset.nft does not carry the learned server sets"

# --- 11b. deleting a zone removes its rules and learned data
[ -f "$W/run/state/1st.ips" ] || fail "precondition: zone 1st has a state file"
cfg delete lobbyfence.1st; cfg commit lobbyfence
lf apply
[ ! -e "$W/run/state/1st.ips" ] && [ ! -e "$W/data/zones/1st.ips" ] && pass "deleted zone's learned data removed" || fail "1st data left behind"
inr nft list table inet lobbyfence | grep -q "z_1st_" && fail "deleted zone still in the firewall" || pass "deleted zone gone from the firewall"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert [z['id'] for z in d['zones']]==['game'], d['zones']" "$W/run/status.json" \
	&& pass "deleted zone gone from status.json" || fail "status.json still lists 1st"
expect "remaining zone unaffected" "45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"

# --- 12. disabling removes the table
cfg set lobbyfence.globals.enabled=0; cfg commit lobbyfence
lf apply
inr nft list table inet lobbyfence >/dev/null 2>&1 && fail "table present while disabled" || pass "disabled -> no table"
expect "disabled: all traffic passes" "80.20.0.1 ok" "$(probe 80.20.0.1)"

# --- 13. API check: working service, then a dead one
out="$(lf apitest)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['ok'] and d['country']=='US' and d['ip']=='8.8.8.8', d" "$out" \
	&& pass "apitest reports a working service ($out)" || fail "apitest ok case: $out"
pkill -f "^python3 .*fake_geo.py" ; sleep 0.3
out="$(lf apitest)"; rc=$?
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert not d['ok'] and 'no answer' in d['error'], d" "$out" && [ $rc -ne 0 ] \
	&& pass "apitest reports a dead service" || fail "apitest failure case: $out"
python3 -c "import json,sys; d=json.load(open(sys.argv[1])); assert 'no answer' in d['geo']['error'], d['geo']" "$W/run/status.json" \
	&& pass "API failure shows up in status.json" || fail "status.json geo error"
lf apitest 10.0.0.1 >/dev/null 2>&1 && fail "apitest accepted a private address" || pass "apitest rejects private addresses"

# --- 13b. servers file: download on this router, import on a "new" one - located with no lookup
cfg set lobbyfence.globals.enabled=1; cfg set lobbyfence.game.game=fortnite; cfg commit lobbyfence
lf apply
lf export > "$W/servers.txt"
grep -qx 'lobbyfence-servers 1' "$W/servers.txt" && grep -q '^game fortnite Test game$' "$W/servers.txt" \
	&& grep -q '^80\.20\.0\.1 -\?[0-9.]* -\?[0-9.]* [A-Z][A-Z] [0-9]*$' "$W/servers.txt" && grep -q '^45\.10\.0\.1 ' "$W/servers.txt" \
	&& pass "export: the located servers under the zone's game" || fail "export: $(head -12 "$W/servers.txt")"

# --- 13c. Send to LobbyFence (share-servers): only this router's own finds for the listed
# client-server games, in data-centre networks, not built in or sent before - to the form
# (here a stand-in on 127.0.0.1:8090; the test addresses count as data centres in a copy
# of the network list, the real list leaves them out)
inr python3 "$HERE/fake_form.py" 8090 "$W/form.log" & FORM=$!
mkdir -p "$W/share"; cp "$LF_SHARE"/* "$W/share/"
echo "45.10.0.0/16 80.20.0.0/16" > "$W/share/server-networks.txt"
shf() { inr env LF_SHARE="$W/share" LF_SHARE_URL="http://127.0.0.1:8090/forms/d/e/x/formResponse" $LF share-servers "$@" 2>>"$W/share.err"; }
sleep 0.4
st="$(shf status)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['auto']==0 and d['pending']==2 and d['last']==0 and d['sent']==0, d" "$st" \
	&& pass "share-servers status: off, 2 found servers waiting to be sent" || fail "share status: $st"
pv="$(shf preview)"
echo "$pv" | head -1 | grep -qx 'lobbyfence-servers 1' && echo "$pv" | grep -qx 'game fortnite Fortnite' \
	&& echo "$pv" | grep -q '^45\.10\.0\.1 ' && echo "$pv" | grep -q '^80\.20\.0\.1 ' && ! echo "$pv" | grep -q 'Test' \
	&& pass "preview: a servers file under the game's own name, not the zone's label" || fail "share preview: $pv"
st="$(inr env LF_SHARE_URL=http://127.0.0.1:8090/x $LF share-servers status)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['pending']==0, d" "$st" \
	&& pass "with the real network list these addresses (not data centres) would not be sent" || fail "real network list: $st"
out="$(shf now)"; rc=$?
python3 - "$W/form.log" <<'PY' && pass "sent: one answer to the form, in its field, with just the two servers ($out)" || fail "share now: rc=$rc $out $(cat "$W/form.log" "$W/share.err" 2>/dev/null | head -5)"
import json, sys
a = [json.loads(l) for l in open(sys.argv[1])]
assert len(a) == 1 and a[0]["fields"] == ["entry.902986460"] and a[0]["path"].endswith("/formResponse"), a
assert "x-www-form-urlencoded" in a[0]["type"], a
t = a[0]["text"].splitlines()
assert t[0] == "lobbyfence-servers 1" and "game fortnite Fortnite" in t, t
assert sorted(l.split()[0] for l in t if l[:1].isdigit()) == ["45.10.0.1", "80.20.0.1"], t
assert all(len(l.split()) == 5 for l in t if l[:1].isdigit()), t
PY
st="$(shf status)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['last_ok']==1 and d['last_n']==2 and d['pending']==0 and d['sent']==2 and d['last']>0, d" "$st" \
	&& pass "after sending: remembered as sent, nothing waiting" || fail "share status after send: $st"
grep -q "sent 2 new game server(s) to LobbyFence" "$W/run.log" 2>/dev/null || grep -rq "sent 2 new game server" "$W/run" 2>/dev/null \
	&& pass "the log says what was sent" || fail "no log line for the send"
out="$(shf now)"
[ "$out" = "nothing new to send" ] && [ "$(wc -l < "$W/form.log")" = 1 ] \
	&& pass "sending again: nothing new, nothing sent" || fail "second send: $out / $(wc -l < "$W/form.log")"
# the form down: nothing marked as sent, the failure is told
rm -f "$W/data/share.sent"; touch "$W/form.log.down"
out="$(shf now 2>&1)"; rc=$?
st="$(shf status)"
[ $rc -ne 0 ] && python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['last_ok']==0 and d['sent']==0 and d['pending']==2, d" "$st" \
	&& pass "form not answering: an error, nothing counted as sent" || fail "form down: rc=$rc $out $st"
rm -f "$W/form.log.down"
# an answer the form refuses (400, with its confirmation text in the page) is not taken as sent
inr env LF_SHARE="$W/share" LF_SHARE_URL="http://127.0.0.1:8090/forms/d/e/x/notaform" $LF share-servers now >/dev/null 2>&1; rc=$?
[ $rc -ne 0 ] && [ ! -s "$W/data/share.sent" ] && pass "an answer the form refuses (400) is not counted as sent" || fail "400 counted as sent"
# once a day: on -> the first time within the hour; the learning loop sends when it is time
st="$(shf auto on)"; js="$(shf status)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['auto']==1 and d['now']+300 <= d['next'] <= d['now']+3600, d" "$js" \
	&& [ "$st" = on ] && pass "auto on: the first send is within the hour" || fail "auto on: $st $js"
echo 1 > "$W/data/share.next"; : > "$W/form.log"
inr env LF_SHARE="$W/share" LF_SHARE_URL="http://127.0.0.1:8090/forms/d/e/x/formResponse" $LF daemon >/dev/null 2>&1 & DAEMON=$!
n=0; while [ ! -s "$W/form.log" ] && [ $n -lt 60 ]; do sleep 0.5; n=$((n + 1)); done
sleep 1
kill "$(cat "$W/run/daemon.pid" 2>/dev/null)" $DAEMON 2>/dev/null; wait $DAEMON 2>/dev/null
js="$(shf status)"
[ "$(wc -l < "$W/form.log")" = 1 ] && python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['last_ok']==1 and d['sent']==2 and abs(d['next'] - d['now'] - 86400) <= 960, d" "$js" \
	&& pass "the learning loop sends by itself when it is time, then again in about a day" || fail "daemon send: $(wc -l < "$W/form.log") $js"
# Google's answer is told apart by its status: after a redirect, without the confirmation text,
# or cut off after the 200 - the form has the answer each time, so it counts as sent (and the
# log says how it went)
for mode in redirect nomarker cut; do
	rm -f "$W/data/share.sent" "$W/data/share.last"; : > "$W/form.log"; echo "$mode" > "$W/form.log.mode"
	out="$(shf now 2>&1)"; rc=$?
	js="$(shf status)"
	[ $rc -eq 0 ] && [ "$(wc -l < "$W/form.log")" = 1 ] \
		&& python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['last_ok']==1 and d['sent']==2 and d['pending']==0, d" "$js" \
		&& pass "form answer '$mode': counted as sent, not sent again" || fail "form answer '$mode': rc=$rc $out $js"
done
rm -f "$W/form.log.mode"
lg="$(cat "$W/run.log" "$W/run/log" 2>/dev/null)"
echo "$lg" | grep -q "sent 2 new game server(s) to LobbyFence (curl: HTTP 200, exit 0, no confirmation shown" \
	&& echo "$lg" | grep -q "sent 2 new game server(s) to LobbyFence (curl: HTTP 200, exit 18" \
	&& pass "the log says how each answer came back" || fail "share log lines: $(echo "$lg" | grep 'to LobbyFence' | tail -4)"
# failing again and again: it waits longer each time (2 hours, then 4) instead of every 2 hours
rm -f "$W/data/share.sent" "$W/data/share.last"; touch "$W/form.log.down"
for want in 7200 14400; do
	echo 1 > "$W/data/share.next"
	inr env LF_SHARE="$W/share" LF_SHARE_URL="http://127.0.0.1:8090/forms/d/e/x/formResponse" $LF daemon >/dev/null 2>&1 & DAEMON=$!
	n=0; while [ "$(cat "$W/data/share.next" 2>/dev/null)" = 1 ] && [ $n -lt 60 ]; do sleep 0.5; n=$((n + 1)); done
	sleep 0.5
	kill "$(cat "$W/run/daemon.pid" 2>/dev/null)" $DAEMON 2>/dev/null; wait $DAEMON 2>/dev/null
	js="$(shf status)"
	python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['last_ok']==0 and d['sent']==0 and abs(d['next'] - d['now'] - $want) <= 60, d" "$js" \
		&& pass "failure $([ $want = 7200 ] && echo 1 || echo 2) in a row: next try in $((want / 3600)) hours" || fail "backoff $want: $js"
done
rm -f "$W/form.log.down"
st="$(shf auto off)"; js="$(shf status)"
python3 -c "import json,sys; d=json.loads(sys.argv[1]); assert d['auto']==0 and d['next']==0, d" "$js" && [ "$st" = off ] && [ ! -f "$W/data/share.next" ] \
	&& pass "auto off: nothing scheduled any more" || fail "auto off: $st $js"
lf share-servers auto maybe >/dev/null 2>&1 && fail "share-servers accepted a bad argument" || pass "share-servers refuses bad arguments"
kill $FORM 2>/dev/null; wait $FORM 2>/dev/null
rm -f "$W/data/share.sent" "$W/data/share.last"
# the "new router": nothing learned or located yet - and the geolocation service is down (13)
lf teardown
rm -rf "$W/data/geo.cache" "$W/data/zones" "$W/run/state"
out="$(lf import-servers - < "$W/servers.txt")"
echo "$out" | grep -q "^imported [1-9][0-9]* new server location" && [ -s "$W/data/shared.cache" ] \
	&& pass "import-servers keeps the locations ($(echo "$out" | head -1))" || fail "import-servers: $out"
lf apply
printf "45.10.0.1\n80.20.0.1\n" | lf import game - >/dev/null
lf cycle
expect "imported locations: the servers are sorted in or out straight away, with the service down" \
	"45.10.0.1 ok 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
grep -q "from known locations (no lookup)" "$W/run/log" 2>/dev/null || grep -rq "from known locations" "$W"/*.log 2>/dev/null \
	&& pass "the log says they came from known locations" || fail "no log line about known locations"
# the game servers LobbyFence comes with (servers.txt): placed straight away too, the service still down
inw $IP addr add 45.32.7.134/32 dev veth1; inr $IP route add 45.32.7.134/32 via 10.99.0.2
printf "45.32.7.134\n" | lf import game - >/dev/null
lf cycle
grep -q '^45\.32\.7\.134 40\.4993 -74\.399 US ' "$W/run/state/geo.cache" \
	&& pass "a Call of Duty server from the list LobbyFence comes with: located with no lookup" \
	|| fail "built-in list: $(grep -c . "$W/run/state/geo.cache") located, log: $(tail -2 "$W/run/log")"
expect "...and sorted out straight away (New Jersey: outside the region)" "45.32.7.134 blocked" "$(probe 45.32.7.134)"
out="$(lf builtin-servers)"
[ "$(echo "$out" | head -1)" = "lobbyfence-servers 1" ] && echo "$out" | grep -qx 'game apex Apex Legends' && echo "$out" | grep -qx 'game cod Call of Duty series' \
	&& [ "$(echo "$out" | grep -c '^[0-9]')" = "$(grep -c '^[0-9]' "$LF_SHARE/servers.txt")" ] && ! echo "$out" | grep -q '^#' \
	&& pass "builtin-servers: the list LobbyFence comes with, as a servers file (for the Servers file window)" || fail "builtin-servers: $(echo "$out" | head -3)"
cp "$W/data/shared.cache" "$W/shared.before"
printf '<html>a web page</html>\n' > "$W/notservers.txt"
lf import-servers "$W/notservers.txt" >/dev/null; rc=$?
[ $rc -ne 0 ] && grep -q "not a LobbyFence servers file" "$W/stderr.log" && cmp -s "$W/data/shared.cache" "$W/shared.before" \
	&& pass "a file that is not a servers file is refused (and says why), nothing changed" || fail "bad file: rc=$rc $(tail -2 "$W/stderr.log")"
sed -i '/lobbyfence: not a LobbyFence servers file/d' "$W/stderr.log" 2>/dev/null
out="$(lf import-servers - < "$W/servers.txt")"
echo "$out" | grep -q "^imported 0 new" && [ "$(wc -l < "$W/data/shared.cache")" = "$(wc -l < "$W/shared.before")" ] \
	&& pass "the same file again adds nothing (no duplicates)" || fail "re-import: $out"
# a nearly full flash: LobbyFence leaves the last LF_FLASH_RESERVE KB to the router
cp "$W/data/shared.cache" "$W/shared.before" 2>/dev/null
out="$(inr env LF_FLASH_RESERVE=999999999 $LF import-servers - < "$W/servers.txt" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] && echo "$out" | grep -q "not enough room left on the flash" && cmp -s "$W/data/shared.cache" "$W/shared.before" \
	&& pass "flash nearly full: import refused, saved file untouched" || fail "flash room import: rc=$rc $out"
touch "$W/run/dirty_new"; rm -f "$W/run/persisted_at" "$W/run/persist.err"
inr env LF_FLASH_RESERVE=999999999 $LF persist 2>>"$W/stderr.log"
grep -q "not enough room left on the flash" "$W/run/log" && pass "flash nearly full: saving waits, the learned servers stay in memory" || fail "flash room persist: $(tail -2 "$W/run/log")"
lf persist

# --- 13c. diag: the server ports the device really uses, and which the zone's ports miss
cat > "$W/ct.txt" <<'CTEOF'
ipv4     2 udp      17 175 src=192.168.1.100 dst=45.10.0.1 sport=50000 dport=3074 packets=120 bytes=9000 src=45.10.0.1 dst=10.99.0.1 sport=3074 dport=50000 packets=118 bytes=9100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=192.168.1.100 dst=80.20.0.1 sport=50001 dport=41215 packets=900 bytes=9000 src=80.20.0.1 dst=10.99.0.1 sport=41215 dport=50001 packets=880 bytes=9100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=192.168.1.100 dst=80.20.0.2 sport=50002 dport=41215 packets=700 bytes=9000 src=80.20.0.2 dst=10.99.0.1 sport=41215 dport=50002 packets=680 bytes=9100 [ASSURED] mark=0 use=2
ipv4     2 udp      17 175 src=192.168.1.77 dst=80.20.0.3 sport=50003 dport=5000 packets=7 bytes=900 src=80.20.0.3 dst=10.99.0.1 sport=5000 dport=50003 packets=7 bytes=900 [ASSURED] mark=0 use=2
CTEOF
out="$(inr env LF_CONNTRACK="$W/ct.txt" $LF diag 2>&1)"
echo "$out" | grep -q "^    \* udp/41215: 2 server(s), 1600 packets$" && echo "$out" | grep -q "^      udp/3074: 1 server(s), 120 packets$" \
	&& ! echo "$out" | grep -q "udp/5000" \
	&& pass "diag: ports in use, the one the zone misses marked (other devices left out)" || fail "diag ports: $(echo "$out" | grep -A4 'server ports')"

# --- 13c2. "Ports seen": the server ports the device used, tallied on passes with game traffic
# (their packet counts come from the connections: OpenWrt counts none unless asked to)
[ "$(inr cat /proc/sys/net/netfilter/nf_conntrack_acct 2>/dev/null)" = 1 ] && pass "connection packet counts switched on" \
	|| fail "nf_conntrack_acct: $(inr cat /proc/sys/net/netfilter/nf_conntrack_acct 2>&1)"
lf ports game clear > /dev/null
rm -f "$W/run/game.ports.at"   # (a pass in 13b may have tallied moments ago: once a pass at most)
probe 45.10.0.1 > /dev/null
inr env LF_CONNTRACK="$W/ct.txt" $LF cycle 2>>"$W/stderr.log"
out="$(lf ports game)"
echo "$out" | head -1 | grep -q '^udp/41215 2 1600 [0-9]* [0-9]* 1 [01] 1600$' && echo "$out" | grep -q '^udp/3074 1 120 ' && ! echo "$out" | grep -q 'udp/5000' \
	&& pass "ports: the device's server ports tallied, busiest first, other devices left out" || fail "ports: $out"
sleep 1; probe 45.10.0.1 > /dev/null
inr env LF_CONNTRACK="$W/ct.txt" $LF cycle 2>>"$W/stderr.log"
lf ports game | grep -q '^udp/41215 2 1600 [0-9]* [0-9]* 1 ' && pass "ports: tallied once a pass at most (passes come every 2 s in a busy moment)" || fail "ports tallied twice: $(lf ports game)"
rm -f "$W/run/game.ports.at"
probe 45.10.0.1 > /dev/null
inr env LF_CONNTRACK="$W/ct.txt" $LF cycle 2>>"$W/stderr.log"
lf ports game | grep -q '^udp/41215 2 1600 [0-9]* [0-9]* 2 [01] 1600$' && pass "ports: seen again -> 2 passes (nothing sent since: the total stays)" || fail "ports again: $(lf ports game)"
# the game keeps sending: the total counts it, the peak follows the busiest pass
sed -i 's/packets=900 /packets=1500 /' "$W/ct.txt"
sleep 1; rm -f "$W/run/game.ports.at"; probe 45.10.0.1 > /dev/null
inr env LF_CONNTRACK="$W/ct.txt" $LF cycle 2>>"$W/stderr.log"
lf ports game | grep -q '^udp/41215 2 2200 [0-9]* [0-9]* 3 [01] 2200$' && pass "ports: the packets the game sent since the pass before are added" || fail "ports total: $(lf ports game | head -2)"
lf persist
lf teardown; rm -rf "$W/run/state"; lf apply
lf ports game | grep -q '^udp/41215 ' && pass "ports: kept on flash, back after a restart" || fail "ports restore: $(ls "$W/data/zones")"
lf ports game clear | grep -q cleared && [ -z "$(lf ports game)" ] && [ ! -f "$W/data/zones/game.ports" ] && pass "ports: clear" || fail "ports clear"
lf ports nosuchzone; [ $? -ne 0 ] && pass "ports: unknown zone refused" || fail "ports bad zone"
sed -i '/nosuchzone/d' "$W/stderr.log" 2>/dev/null

# --- 13d. a zone switched to another game: its servers stay filed under the old game
lf cycle
[ -s "$W/run/state/game.ips" ] && pass "zone has learned servers before the switch" || fail "no servers before the switch"
cfg set lobbyfence.game.game=apex; cfg commit lobbyfence
lf apply
[ ! -s "$W/run/state/game.ips" ] && pass "switched game: the zone learns the new game's servers anew" || fail "switch: $(cat "$W/run/state/game.ips")"
lf export > "$W/servers2.txt"
awk '$1 == "game" { g = $2; next } /^45\.10\.0\.1 / { print g, NF }' "$W/servers2.txt" | grep -qx "fortnite 5" \
	&& ! grep -q '^game apex' "$W/servers2.txt" \
	&& pass "switched game: the old servers stay under the old game, as found by this router" || fail "switch export: $(cat "$W/servers2.txt")"
grep -q "game changed from fortnite to apex" "$W/run/log" && pass "switched game: logged" || fail "switch log: $(tail -3 "$W/run/log")"
lf apply
grep -c "game changed" "$W/run/log" | grep -qx 1 && pass "apply again: no second switch" || fail "switch repeated"
cfg set lobbyfence.gone=zone; cfg set lobbyfence.gone.game=valorant; cfg add_list lobbyfence.gone.device=192.168.1.150; cfg add_list lobbyfence.gone.remote_port=7000
cfg add_list lobbyfence.gone.country=US; cfg commit lobbyfence
lf apply
printf '99.30.0.7 %s\n' "$(date +%s)" > "$W/run/state/gone.ips"
printf '99.30.0.7 48.8 2.3 FR %s\n' "$(date +%s)" >> "$W/run/state/geo.cache"
[ "$(cat "$W/data/zones/gone.game" 2>/dev/null)" = valorant ] && pass "a zone's game is recorded" || fail "gone.game: $(ls "$W/data/zones")"
cfg delete lobbyfence.gone; cfg commit lobbyfence
lf apply
[ ! -f "$W/data/zones/gone.game" ] && lf export | awk '$1 == "game" { g = $2; next } /^99\.30\.0\.7 / { print g, NF }' | grep -qx "valorant 5" \
	&& pass "deleted zone: its located servers kept under its game, record removed" || fail "deleted zone: $(lf export | tail -4) | $(ls "$W/data/zones") | $(tail -3 "$W/run/log")"

# --- 13e. remove a game's servers list
lf export | grep -q '^game valorant' || fail "remove: valorant list missing before"
out="$(lf remove-servers valorant)"
! lf export | grep -q '^game valorant' && lf export | grep -q '^game fortnite' && echo "$out" | grep -q "removed 1 server(s) of valorant" \
	&& pass "remove-servers: that game's list gone, the others kept" || fail "remove-servers: $out / $(lf export | grep '^game')"
cfg set lobbyfence.game.game=fortnite; cfg commit lobbyfence; lf apply
printf '45.10.0.1\n80.20.0.1\n' | lf import game -
lf cycle
out="$(lf remove-servers fortnite 80.20.0.1)"
! grep -q '^80\.20\.0\.1 ' "$W/run/state/game.ips" && grep -q '^45\.10\.0\.1 ' "$W/run/state/game.ips" \
	&& ! lf export | grep -q '^80\.20\.0\.1 ' && lf export | grep -q '^45\.10\.0\.1 ' && echo "$out" | grep -q "removed 1 chosen server" \
	&& pass "remove-servers <game> <address>: just that server goes (zone and kept list), the rest stays" || fail "remove one: $out / $(cat "$W/run/state/game.ips")"
lf remove-servers fortnite '1.2.3.4;x'; rc=$?
[ "$rc" -ne 0 ] && grep -q "not an address" "$W/stderr.log" && pass "remove-servers: bad addresses refused" || fail "remove bad addr: $rc"
sed -i '/not an address/d' "$W/stderr.log" 2>/dev/null
[ -s "$W/run/state/game.ips" ] || fail "remove: zone has no servers before"
out="$(lf remove-servers fortnite)"
[ ! -s "$W/run/state/game.ips" ] && [ ! -s "$W/data/zones/game.ips" ] && ! lf export | grep -q '^game fortnite' \
	&& echo "$out" | grep -q "learned by zones set to it" \
	&& pass "remove-servers: the zones set to that game forget their learned servers too (memory and flash)" || fail "remove zone: $out"
lf remove-servers 'x;y'; rc=$?
[ "$rc" -ne 0 ] && grep -q "usage: lobbyfence remove-servers" "$W/stderr.log" && pass "remove-servers: a bad game name is refused" || fail "remove bad: $rc $(tail -1 "$W/stderr.log")"
sed -i '/usage: lobbyfence remove-servers/d' "$W/stderr.log" 2>/dev/null
lf remove-servers all > /dev/null
[ "$(lf export | grep -vc '^#')" = 1 ] && pass "remove-servers all: empty file left (header only)" || fail "remove all: $(lf export)"

# --- 14. the RAM folder taken over beforehand (a link, or someone else's folder): not used
rm -rf "$W/run"; mkdir -p "$W/elsewhere"; ln -s "$W/elsewhere" "$W/run"
lf apply >/dev/null 2>&1
[ -d "$W/run" ] && [ ! -L "$W/run" ] && [ -z "$(ls -A "$W/elsewhere")" ] && [ -f "$W/run/status.json" ] \
	&& pass "a link put in place of the RAM folder is replaced, nothing written through it" || fail "RAM folder link: $(ls -la "$W/run" "$W/elsewhere" 2>&1 | head -5)"
rm -rf "$W/run"; mkdir "$W/run"; echo planted > "$W/run/status.json"; chown -R 65534 "$W/run"
lf apply >/dev/null 2>&1
[ "$(ls -ldn "$W/run" | awk '{ print $3 }')" = 0 ] && [ "$(cat "$W/run/status.json")" != planted ] \
	&& pass "a folder someone else made in its place is replaced" || fail "RAM folder of another user: $(ls -ldn "$W/run")"

# --- 15. brick safety: a zone filtering every port and protocol, nothing allowed,
# never cuts the device off the router itself (LuCI, SSH, DNS stand-ins)
inr python3 "$HERE/udp.py" tcpserve 8022 >/dev/null 2>&1 &
inr python3 "$HERE/udp.py" serve 1053 >/dev/null 2>&1 &
sleep 0.5
for o in remote_port port local_port circle polygon country; do cfg delete lobbyfence.game.$o 2>/dev/null; done
cfg add_list lobbyfence.game.remote_port=1-65535
cfg set lobbyfence.game.proto=both
cfg set lobbyfence.game.mode=enforce
cfg set lobbyfence.game.strict=1
cfg set lobbyfence.game.enabled=1
cfg set lobbyfence.globals.enabled=1
cfg commit lobbyfence
lf apply
expect "a zone filtering every port, no region: the device's game servers are blocked" "45.10.0.1 blocked 80.20.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1)"
expect "...the router's own TCP services still answer the device (LuCI / SSH stand-in)" "192.168.1.1 ok" "$(inl python3 "$HERE/udp.py" tcpprobe 8022 192.168.1.1 | tr '\n' ' ' | sed 's/ $//')"
expect "...and its UDP services (DNS stand-in)" "192.168.1.1 ok" "$(probe_port 1053 192.168.1.1)"
inr nft list table inet lobbyfence | grep -q "hook input\|hook output\|hook prerouting\|hook postrouting" \
	&& fail "LobbyFence hooks more than the forward path: $(inr nft list table inet lobbyfence | grep hook)" \
	|| pass "LobbyFence's nft table hooks only the forward path (traffic to the router itself is never filtered)"
pkill -f "udp.py (tcpserve 8022|serve 1053)" 2>/dev/null

# (the background passes must not trip over their own temporary files)
grep -q "state.tmp" "$W/stderr.log" 2>/dev/null && fail "refresh_sets touched a missing state.tmp" || pass "no missing temporary files in learning passes"
echo "---- log ----"; cat "$W/run.log" 2>/dev/null | tail -n 12
[ "$FAIL" = 0 ] && echo "ALL TESTS PASSED" || echo "SOME TESTS FAILED"
exit $FAIL
