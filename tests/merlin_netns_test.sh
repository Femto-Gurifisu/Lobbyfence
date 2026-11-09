#!/bin/sh
# End-to-end test of the Asuswrt-Merlin port: LAN client -> router -> WAN game
# servers in network namespaces. The router namespace runs everything with
# BusyBox built from Merlin's tree and configuration as /bin/sh and as the only
# tools (plus legacy iptables, ipset 7.6, curl), LobbyFence installed by its
# own installer into a fake /jffs next to another add-on. The web page's
# requests go the way Merlin's web server sends them (add-on settings +
# service-event); the lag simulator (lf-lagd, NFQUEUE) runs for real.
#   usage: merlin_netns_test.sh <workdir> <merlin-busybox> <full-busybox> <ipset> <merlin-www-files-dir>
W="$1"; FBB="$3"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/merlin_env.sh" "$@" >/dev/null || exit 1
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
# Merlin's BusyBox is /bin/sh in the router
inr mount --bind "$MERLIN_SH" "$(readlink -f /bin/sh)"

inr $IP link add rl type veth; inr $IP link add rw type veth
inr $IP link set dev veth0 netns $LAN; inr $IP link set dev veth1 netns $WAN
for p in $LAN $RTR $WAN; do nsenter -t $p -n $IP link set lo up; done
inr $IP addr add 192.168.1.1/24 dev rl; inr $IP link set rl up
inr $IP addr add 10.99.0.1/24 dev rw; inr $IP link set rw up
inr sh -c 'echo 1 > /proc/sys/net/ipv4/ip_forward'
inl $IP addr add 192.168.1.100/24 dev veth0; inl $IP link set veth0 up; inl $IP route add default via 192.168.1.1
inw $IP addr add 10.99.0.2/24 dev veth1; inw $IP link set veth1 up
for s in 45.10.0.1 80.20.0.1 99.30.0.1 77.40.0.1; do
	inw $IP addr add $s/32 dev veth1; inr $IP route add $s/32 via 10.99.0.2
done
inw $IP route add 192.168.1.0/24 via 10.99.0.1

inw python3 "$HERE/udp.py" serve 3074 &
inw python3 "$HERE/udp.py" serve 5555 &
inr python3 "$HERE/fake_geo.py" 8080 "$W/geo_calls.log" &
cleanup() {
	inr env PATH="$TPATH" "$LF_HOME/lobbyfence" stop >/dev/null 2>&1
	kill $LAN $RTR $WAN 2>/dev/null
	pkill -f "^python3 $HERE/(udp|fake_geo).py" 2>/dev/null
	pkill -f "$W/jffs/addons/lobbyfence/bin/lf-lagd" 2>/dev/null
}
trap cleanup EXIT INT TERM
sleep 0.5

probe() { inl python3 "$HERE/udp.py" probe 3074 "$@" | tr '\n' ' ' | sed 's/ $//'; }
rtt() { inl python3 "$HERE/udp.py" rtt "$1" "$2" "${3:-7}"; }
lf() { inr env PATH="$TPATH" "$LF_HOME/lobbyfence" "$@" 2>>"$W/stderr.log"; }
cfg() { inr env PATH="$TPATH" LF_SHARE="$LF_HOME/share" LF_CONF_FILE="$LF_HOME/lobbyfence.conf" \
	/bin/sh -c '. "$LF_SHARE/functions.sh"; uci "$@"' sh "$@"; }
hook() { s="$1"; shift; inr env PATH="$TPATH" /bin/sh "$W/jffs/scripts/$s" "$@" 2>>"$W/stderr.log"; }
# the web page, through Merlin's web server (add-on settings + service-event)
page() { inr env PATH="$TPATH" MERLIN_SCRIPTS="$W/jffs/scripts" /usr/bin/python3 "$HERE/merlin_page.py" "$@"; }
js() { python3 -c "import json,sys; d=json.loads(sys.argv[1]); $1" "$2"; }
ipt() { inr "$W/bin/iptables" "$@"; }
ips() { inr "$W/bin/ipset" "$@"; }
st() { python3 -c "import json,sys; d=json.load(open(sys.argv[1])); $1" "$LF_RUN/status.json"; }
waitfor() { n=0; while [ "$n" -lt "${2:-60}" ]; do eval "$1" && return 0; sleep 0.5; n=$((n + 1)); done; return 1; }

# --- 0. installed like on the router
for f in lobbyfence bin/lobbyfence-main bin/lf-lagd share/fw-ipt.sh share/fw-merlin.sh share/functions.sh share/conf.awk \
	share/lobbyfence.awk share/servers.txt www/lobbyfence.asp www/lobbyfence/app.asp www/lobbyfence/map.js www/lobbyfence/lf-merlin.js www/lobbyfence/lf-shim.js; do
	[ -f "$LF_HOME/$f" ] || fail "installer did not copy $f"
done
grep -q "other.sh start # OtherAddon" "$W/jffs/scripts/services-start" && grep -q "lobbyfence start .*# LobbyFence$" "$W/jffs/scripts/services-start" \
	&& grep -q "lobbyfence fwhook # LobbyFence$" "$W/jffs/scripts/firewall-start" && grep -q 'service-event "$1" "$2" # LobbyFence$' "$W/jffs/scripts/service-event" \
	&& [ -x "$W/jffs/scripts/services-stop" ] && head -n 1 "$W/jffs/scripts/firewall-start" | grep -q '^#!/bin/sh' \
	&& pass "hooks added to /jffs/scripts, the other add-on's lines kept" || fail "hooks: $(cat "$W/jffs/scripts/services-start")"
expect "installer switched on Merlin's custom scripts" 1 "$(cat "$W/nvram/jffs2_scripts")"
inr /bin/sh -c 'type echo' 2>/dev/null | grep -q builtin && fail "test shell is not Merlin's BusyBox (echo is a builtin)" \
	|| pass "running on Merlin's BusyBox (echo, printf and [ are not builtins; no stat/timeout/mktemp)"
expect "baseline connectivity" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

# --- 1. boot: services-start
hook services-start
waitfor '[ -s "$LF_RUN/status.json" ] && [ -L "$W/www/user/lobbyfence/d" ] && [ -s "$LF_RUN/webui_page" ] && grep -q "LobbyFence" "$W/tmp/menuTree.js" 2>/dev/null' 60 \
	&& pass "services-start starts LobbyFence in the background" || fail "start: $(cat "$W/stderr.log" | tail -3)"
grep -q "start" "$W/other.log" 2>/dev/null && pass "the other add-on still starts too" || fail "other add-on not started"
page_name="$(cat "$LF_RUN/webui_page")"
cmp -s "$W/www/user/$page_name" "$LF_HOME/www/lobbyfence.asp" && pass "page mounted as /$page_name (Merlin's helper.sh)" || fail "page: $page_name"
grep -A1 'url: "Tools_OtherSettings.asp", tabName:' "$W/tmp/menuTree.js" | grep -q "{url: \"$page_name\", tabName: \"LobbyFence\"}," \
	&& inr awk -v f="$W/www/require/modules/menuTree.js" '$2 == f { m = 1 } END { exit !m }' /proc/mounts \
	&& pass "LobbyFence tab under Administration (after Tweaks), laid over the menu file" || fail "menu: $(grep -n LobbyFence "$W/tmp/menuTree.js")"
for f in app.asp map.js lf-shim.js lf-merlin.js settings.js; do [ -e "$W/www/user/lobbyfence/$f" ] || fail "web file $f missing"; done
[ -s "$W/www/user/lobbyfence/d/config.json" ] && [ -s "$W/www/user/lobbyfence/d/status.json" ] && [ -s "$W/www/user/lobbyfence/d/cs.json" ] \
	&& pass "the page's data files are there (settings, status)" || fail "data files: $(ls "$W/www/user/lobbyfence/d/")"

# --- 2. settings from the page (Save & Apply through the add-on API)
out="$(page ops '[["set","globals","enabled","1"],["set","globals","geo_url","http://127.0.0.1:8080/batch"],["set","globals","log_blocked","1"],
	["add","game","zone"],["set","game","enabled","1"],["set","game","label","Test <%game%> \"1\""],["set","game","mode","monitor"],["set","game","strict","0"],
	["set","game","device",["192.168.1.100"]],["set","game","remote_port",["3074"]],["set","game","circle",["50.1109,8.6821,800"]]]')"
js "assert d.get('done') and d['code']==0, d" "$out" && pass "page: Save & Apply through Merlin's add-on settings + service-event" || fail "apply: $out"
grep -q "option label 'Test <%game%> \"1\"'" "$LF_HOME/lobbyfence.conf" && grep -q "list circle '50.1109,8.6821,800'" "$LF_HOME/lobbyfence.conf" \
	&& pass "changes written to the settings" || fail "conf: $(cat "$LF_HOME/lobbyfence.conf")"
grep -q "^other_title Other Addon 1.2$" "$LF_CUSTOM_SETTINGS" && grep -q "^other_mode fast$" "$LF_CUSTOM_SETTINGS" && ! grep -q lobbyfence_cmd "$LF_CUSTOM_SETTINGS" \
	&& pass "the other add-on's settings kept, LobbyFence's request taken out again" || fail "custom settings: $(cat "$LF_CUSTOM_SETTINGS")"
ipt -C FORWARD -j LF_FWD 2>/dev/null && ipt -n -L LF_game_o4 >/dev/null 2>&1 && pass "rules loaded" || fail "rules: $(ipt -S | head)"
grep -q '"text":"config globals' "$W/www/user/lobbyfence/d/config.json" && ! grep -q '<' "$W/www/user/lobbyfence/d/config.json" \
	&& pass "the page's copy of the settings is updated, no '<' in it (Merlin's web server runs <% %>)" || fail "config.json: $(head -c 300 "$W/www/user/lobbyfence/d/config.json")"
! grep -q '<' "$LF_RUN/status.json" && pass "status has no '<' either" || fail "status: $(grep -o '.\{20\}<.\{20\}' "$LF_RUN/status.json")"

# --- 3. learning, server lists for the page
expect "monitor mode lets everything through" "45.10.0.1 ok 80.20.0.1 ok 99.30.0.1 ok" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"
lf cycle
expect "three servers learned" 3 "$(wc -l < "$LF_RUN/state/game.ips" | tr -d ' ')"
grep -q "^45.10.0.1 in" "$W/www/user/lobbyfence/d/game.servers.json" && pass "server list where the page finds it" || fail "servers: $(ls -l "$W/www/user/lobbyfence/d/")"

# --- 4. a long request goes in pieces (8 KB for all add-ons' settings)
poly="$(python3 -c "print(';'.join('%.4f,%.4f' % (40 + i * 0.01, 5 + i * 0.013) for i in range(220)))")"
out="$(page ops "[[\"set\",\"game\",\"polygon\",[\"$poly\"]],[\"set\",\"game\",\"mode\",\"enforce\"],[\"set\",\"game\",\"strict\",\"1\"]]" 600)"
js "assert d.get('done') and d['code']==0 and d['parts']>4, d" "$out" && grep -q "list polygon '40.0000,5.0000;" "$LF_HOME/lobbyfence.conf" \
	&& pass "long change sent in $(js 'print(d["parts"])' "$out") pieces, put together on the router" || fail "pieces: $out"
expect "enforce + strict: outside and unlocatable servers blocked" "45.10.0.1 ok 80.20.0.1 blocked 99.30.0.1 blocked" "$(probe 45.10.0.1 80.20.0.1 99.30.0.1)"

# --- 5. click to allow on the map, then Save & Apply of older page changes: the click stays
out="$(page send "allow game 80.20.0.1")"
js "assert d.get('done') and d['code']==0 and '80.20.0.1' in d['stdout'], d" "$out" && pass "page: Always allow" || fail "allow: $out"
expect "allowed at once" "80.20.0.1 ok" "$(probe 80.20.0.1)"
out="$(page ops '[["set","game","label","Renamed"]]')"
grep -q "list allow_ip '80.20.0.1'" "$LF_HOME/lobbyfence.conf" && grep -q "option label 'Renamed'" "$LF_HOME/lobbyfence.conf" \
	&& pass "a later Save & Apply keeps the click (changes replayed onto the router's settings)" || fail "click lost: $(cat "$LF_HOME/lobbyfence.conf")"
out="$(page send "teardown")"
js "assert d.get('error')=='not allowed', d" "$out" && pass "page: commands it doesn't offer are refused" || fail "teardown: $out"
out="$(page send "allow game 1.2.3.4;reboot")"
js "assert d.get('error')=='bad address', d" "$out" && pass "page: odd addresses refused" || fail "injection: $out"
out="$(page send "allow ../x 1.2.3.4")"
js "assert d.get('error')=='bad zone', d" "$out" && pass "page: odd zone names refused" || fail "zone: $out"
printf 'other_title Other Addon 1.2\nlobbyfence_cmd ../../x 1/1 cycle\n' > "$LF_CUSTOM_SETTINGS"
page event lobbyfence; sleep 1
! ls "$LF_RUN" | grep -q '^web.in' && ! grep -q lobbyfence_cmd "$LF_CUSTOM_SETTINGS" && pass "a request with a bad id is dropped" || fail "bad id: $(ls "$LF_RUN")"
printf 'other_title Other Addon 1.2\nother_mode fast\n' > "$LF_CUSTOM_SETTINGS"

# --- 6. Merlin rebuilt its firewall: firewall-start puts the rules back
ipt -D FORWARD -j LF_FWD; ipt -F; for c in $(ipt -S | awk '$1=="-N"{print $2}'); do ipt -X "$c"; done
hook firewall-start eth0
waitfor 'ipt -C FORWARD -j LF_FWD 2>/dev/null' 40 && pass "firewall-start: rules back" || fail "fwhook"
expect "filtering works again" "45.10.0.1 ok 99.30.0.1 blocked" "$(probe 45.10.0.1 99.30.0.1)"
grep -q "fc flush" "$W/fc.log" && pass "flow cache flushed after rule changes" || fail "fc: $(cat "$W/fc.log" 2>&1)"
st "assert d['platform']=='merlin' and d['accel_skip'] is False and d['lag_supported'], d" \
	&& pass "status: platform, flow-cache bypass (SKIPLOG not in this test kernel), lag simulator available" || fail "status: $(head -c 400 "$LF_RUN/status.json")"

# --- 7. lag simulator (lf-lagd behind NFQUEUE, real kernel queue)
base="$(rtt 3074 45.10.0.1)"
out="$(page ops '[["set","game","lag","1"],["set","game","lag_delay","120"],["set","game","lag_jitter","0"],["set","game","lag_direction","both"]]')"
js "assert d['code']==0, d" "$out" || fail "lag apply: $out"
inr pidof lf-lagd >/dev/null && pass "lf-lagd running" || fail "lf-lagd not running: $(cat "$LF_RUN"/lagd.*.log 2>&1)"
inr "$W/bin/iptables" -t mangle -S | grep -q -- "-A LF_game_q -j NFQUEUE --queue-num 7401 --queue-bypass" \
	&& inr "$W/bin/iptables" -t mangle -C FORWARD -j LF_LAG && pass "game packets queued in mangle FORWARD (bypass when lf-lagd isn't there)" \
	|| fail "mangle: $(inr "$W/bin/iptables" -t mangle -S)"
lag="$(rtt 3074 45.10.0.1)"
[ "$lag" != lost ] && [ "$lag" -ge 110 ] && [ "$lag" -le 400 ] && pass "game ping +120 ms (both ways: $base -> $lag ms)" || fail "lag rtt: base $base lag $lag"
other="$(rtt 5555 45.10.0.1)"
[ "$other" != lost ] && [ "$other" -lt 50 ] && pass "other traffic of the device not delayed ($other ms)" || fail "non-game delayed: $other"
st "z=d['zones'][0]; assert z['lag']['active'] and not z['lag']['error'], z['lag']" && pass "status: lag active" || fail "lag status: $(grep -o '"lag":{[^}]*}' "$LF_RUN/status.json")"
expect "filtering still applies to lagged traffic" "45.10.0.1 ok 99.30.0.1 blocked" "$(probe 45.10.0.1 99.30.0.1)"
out="$(page ops '[["set","game","lag_direction","down"]]')"
lag="$(rtt 3074 45.10.0.1)"
inr "$W/bin/iptables" -t mangle -S LF_LAG | grep -q "LF_game_lo4" && fail "download only: uploads queued" || \
	{ [ "$lag" != lost ] && [ "$lag" -ge 110 ] && pass "download only: the full +120 ms on the way in ($lag ms)" || fail "down rtt $lag"; }
# lf-lagd gone: game traffic passes without lag, the next pass starts it again
inr sh -c 'kill $(pidof lf-lagd)'; sleep 0.5
fast="$(rtt 3074 45.10.0.1)"
[ "$fast" != lost ] && [ "$fast" -lt 50 ] && pass "without lf-lagd packets pass (queue bypass), not dropped ($fast ms)" || fail "bypass: $fast"
lf cycle
inr pidof lf-lagd >/dev/null && pass "the next pass starts lf-lagd again" || fail "not restarted"

# --- 7b. a model LobbyFence carries netem for, but the kernel refuses the module
# (this test kernel can't load an ARM module; insmod is a stand-in that fails
# the way the kernel does, so the real kernel is never asked)
echo GT-AXE16000 > "$W/nvram/productid"
KD="$LF_HOME/netem/gt-axe16000-$(uname -r)"; mkdir -p "$KD"
cp "$HERE/../asuswrt-merlin/netem/gt-axe16000-4.19.183/sch_netem.ko" "$KD/"
printf '#!/bin/sh\necho "insmod $*" >> %s/insmod.log\necho "insmod: cannot insert %s: Exec format error" >&2\nexit 1\n' "$W" "$1" > "$W/bin/insmod"
printf '#!/bin/sh\necho "tc $*" >> %s/tc.log\n' "$W" > "$W/bin/tc"      # (the test system has no tc; Merlin has)
chmod 755 "$W/bin/insmod" "$W/bin/tc"
out="$(page ops '[["set","game","lag_direction","both"]]')"
js "assert d['code']==0, d" "$out" || fail "netem apply: $out"
grep -q "sch_netem.ko" "$W/insmod.log" 2>/dev/null && pass "netem tried for the matching model" || fail "netem not tried: $(cat "$W/insmod.log" 2>&1)"
[ "$(cat "$LF_RUN/lag.kind")" = nfqueue ] && [ "$(cat "$LF_RUN/lag.why")" = netemrefused ] && inr pidof lf-lagd >/dev/null \
	&& pass "module refused: lf-lagd carries the lag instead" || fail "fallback: $(cat "$LF_RUN/lag.kind" "$LF_RUN/lag.why" 2>&1)"
lag="$(rtt 3074 45.10.0.1)"
[ "$lag" != lost ] && [ "$lag" -ge 110 ] && [ "$lag" -le 400 ] && pass "lag still +120 ms after the fallback ($lag ms)" || fail "fallback rtt: $lag"
st "z=d['zones'][0]; assert z['lag']['active'] and not z['lag']['error'] and d['lag_kind']=='nfqueue' and d['netem']=='ready', (z['lag'], d['lag_kind'], d['netem'])" \
	&& pass "status: lag active, no error, netem not in use" || fail "status after fallback: $(grep -o '"lag_kind":"[^"]*","netem":"[^"]*"' "$LF_RUN/status.json")"
[ ! -f "$LF_HOME/.netem-loading" ] && pass "no netem trial left pending" || fail "guard left"
[ "$(cat "$LF_RUN"/target.4.mangle.CLASSIFY* 2>/dev/null)" = 1 ] && pass "the kernel's firewall accepts the CLASSIFY rule (mangle)" || fail "classify probe: $(ls "$LF_RUN"/target.*)"
# netem's rules for real: the zone's queue chain switched to CLASSIFY and back
inr env PATH="$TPATH" LF_SHARE="$LF_HOME/share" LF_RUN="$LF_RUN" LF_HOME="$LF_HOME" LF_IPV6=0 /bin/sh -c '
	have() { type "$1" >/dev/null 2>&1; }; log() { :; }
	. "$LF_SHARE/fw-merlin.sh"; LAG_ZONES=" game:1"
	lag_chains_set netem && iptables -t mangle -S LF_game_q > "$LF_RUN/q.netem"
	lag_chains_set nfqueue && iptables -t mangle -S LF_game_q > "$LF_RUN/q.nfq"' 2>>"$W/stderr.log"
grep -q -- "-A LF_game_q -j CLASSIFY --set-class 007a:0004" "$LF_RUN/q.netem" && grep -q -- "-A LF_game_q -j NFQUEUE --queue-num 7401 --queue-bypass" "$LF_RUN/q.nfq" \
	&& pass "the game's rule switches to netem's band (CLASSIFY 7a:4) and back, in the real firewall" || fail "chain switch: $(cat "$LF_RUN/q.netem" "$LF_RUN/q.nfq" 2>&1)"
! grep -q "dev br0\|dev rw\|dev rl" "$W/tc.log" 2>/dev/null && pass "no device got a queue before netem passed its checks" || fail "tc: $(cat "$W/tc.log")"
rm -rf "$LF_HOME/netem/gt-axe16000-$(uname -r)" "$W/bin/insmod" "$W/bin/tc"; rm -f "$W/nvram/productid"

out="$(page ops '[["set","game","lag","0"]]')"
! inr pidof lf-lagd >/dev/null && ! inr "$W/bin/iptables" -t mangle -S | grep -q LF_LAG && pass "lag off: lf-lagd stopped, queue rules gone" \
	|| fail "lag off: $(inr "$W/bin/iptables" -t mangle -S | grep LF_)"

# --- 8. live data while the map is open: written again each time the page read it (no request)
L="$W/www/user/lobbyfence/d/live.json"
waitfor '[ -s "$L" ]' 40 && js "assert 'zones' in d and 'game' in d['zones']" "$(cat "$L")" \
	&& pass "live data for the map written by the learning loop" || fail "live: $(ls "$W/www/user/lobbyfence/d/")"
t1="$(js "print(d['time'])" "$(cat "$L")")"; sleep 1.2; cat "$L" > /dev/null
waitfor '[ "$(js "print(d[\"time\"])" "$(cat "$L")")" != "$t1" ]' 12 \
	&& pass "the page read it: a fresh copy within seconds (no service event, so ASUS's WAN watchdog isn't paused)" || fail "live not refreshed after a read"
out="$(lf diag)"
echo "$out" | grep -q "flow cache" && echo "$out" | grep -q "lag simulator" && pass "diag explains flow cache and lag simulator" || fail "diag: $out"

out="$(page send debug)"
js "o=d['stdout']; assert d.get('done') and d['code']==0 and o.startswith('LobbyFence debug report') and '==== Asuswrt-Merlin' in o and 'add-on settings file' in o and '==== End of report' in o, d" "$out" \
	&& pass "debug report through the add-on API (Merlin part included)" || fail "debug: $(echo "$out" | head -c 300)"
out="$(page send 'debug /jffs/x')"
js "assert d.get('error') == 'not allowed', d" "$out" && pass "debug takes no other arguments" || fail "debug arg: $out"
out="$(page send export)"
js "assert d.get('done') and d['code']==0 and '\\nlobbyfence-servers 1\\n' in d['stdout'], d" "$out" && pass "servers file download through the add-on API" || fail "export: $(echo "$out" | head -c 300)"
out="$(page send "$(printf 'import-servers\nlobbyfence-servers 1\ngame apex Apex Legends\n45.77.0.9 51.5 -0.1 GB 1700000000\n')")"
js "assert d.get('done') and d['code']==0 and 'imported 1 new' in d['stdout'], d" "$out" && pass "servers file import through the add-on API" || fail "import-servers: $out"
out="$(page send "$(printf 'import-servers\nnope\n')")"
js "assert d.get('done') and d['code']!=0 and 'not a LobbyFence servers file' in d['stderr'], d" "$out" && pass "other files refused through the add-on API" || fail "import bad: $out"
out="$(page send "remove-servers apex 45.77.0.9")"
js "assert d.get('done') and d['code']==0 and 'removed 1 chosen server(s) of apex' in d['stdout'], d" "$out" && pass "remove one chosen server through the add-on API" || fail "remove one: $out"
out="$(page send "remove-servers apex")"
js "assert d.get('done') and d['code']==0 and 'removed 0 server(s) of apex' in d['stdout'], d" "$out" && pass "remove a game's servers list through the add-on API" || fail "remove-servers: $out"
out="$(page send "remove-servers a;b")"
js "assert d.get('error') == 'bad game', d" "$out" && pass "remove-servers takes game names only" || fail "remove bad: $out"
out="$(page send "ports game clear")"
js "assert d.get('done') and d['code']==0 and 'cleared' in d['stdout'], d" "$out" && pass "ports seen through the add-on API" || fail "ports: $out"
out="$(page send "ports ../x")"
js "assert d.get('error') == 'bad zone', d" "$out" && pass "ports: zone names only" || fail "ports bad: $out"
# answers are deleted after ten minutes (they are in RAM; a report is up to 240 KB)
D="$W/www/user/lobbyfence/d"
echo '{}' > "$D/res-old1.json"; echo "$(( $(date +%s) - 700 )) old1" >> "$LF_RUN/res.list"
page send live > /dev/null
[ ! -f "$D/res-old1.json" ] && [ "$(ls "$D" | grep -c '^res-')" -ge 1 ] && pass "old answers removed, new ones kept" || fail "answers: $(ls "$D")"

# --- 9. shutdown and boot
hook services-stop
ipt -C FORWARD -j LF_FWD 2>/dev/null && fail "rules left after services-stop" || pass "services-stop: rules removed"
[ -s "$LF_HOME/data/zones/game.ips" ] && pass "learned servers saved to JFFS" || fail "not saved: $(ls -R "$LF_HOME/data")"
rm -rf "$LF_RUN"; mkdir -p "$LF_RUN"; inr umount "$W/www/require/modules/menuTree.js" 2>/dev/null; rm -f "$W/tmp/menuTree.js" "$W/www/user/$page_name"; rm -rf "$W/www/user/lobbyfence"
hook services-start
waitfor 'ipt -C FORWARD -j LF_FWD 2>/dev/null && [ -s "$LF_RUN/webui_page" ] && grep -q "LobbyFence" "$W/tmp/menuTree.js" 2>/dev/null' 60 && expect "filtering right after the reboot" "45.10.0.1 ok 99.30.0.1 blocked" "$(probe 45.10.0.1 99.30.0.1)" || fail "boot"
grep -q "LobbyFence" "$W/tmp/menuTree.js" && pass "page and menu entry back after the reboot" || fail "menu after boot"

# --- 9b. update while running: the page keeps one add-on slot and one tab (the
# update changes the page's text, so Merlin's helper would not know it again)
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 /bin/sh "$HERE/../asuswrt-merlin/install.sh" > "$W/update.log" 2>&1 \
	&& pass "update over a running install" || fail "update: $(tail -3 "$W/update.log")"
waitfor 'ipt -C FORWARD -j LF_FWD 2>/dev/null && [ -s "$LF_RUN/webui_page" ] && [ -L "$W/www/user/lobbyfence/d" ]' 60 || fail "not running again after the update"
pages="$(grep -l 'LobbyFence for Asuswrt-Merlin' "$W"/www/user/user*.asp 2>/dev/null | wc -l | tr -d ' ')"
page_name="$(cat "$LF_RUN/webui_page")"
[ "$pages" = 1 ] && cmp -s "$W/www/user/$page_name" "$LF_HOME/www/lobbyfence.asp" \
	&& pass "after the update: one page slot, holding the new page" || fail "page slots after the update: $pages ($(ls "$W/www/user"))"
expect "...and one LobbyFence tab in the menu" 1 "$(grep -c 'tabName: "LobbyFence"' "$W/tmp/menuTree.js")"
expect "filtering after the update" "45.10.0.1 ok 99.30.0.1 blocked" "$(probe 45.10.0.1 99.30.0.1)"

# --- 10. uninstall
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 /bin/sh "$HERE/../asuswrt-merlin/install.sh" remove > "$W/remove.log" 2>&1
! grep -q "# LobbyFence" "$W/jffs/scripts/"* && grep -q "OtherAddon" "$W/jffs/scripts/services-start" \
	&& pass "uninstall: our hook lines gone, the other add-on's kept" || fail "hooks after remove: $(cat "$W/jffs/scripts/services-start")"
! grep -q "LobbyFence" "$W/tmp/menuTree.js" && [ ! -e "$W/www/user/$page_name" ] && [ ! -e "$W/www/user/lobbyfence" ] \
	&& pass "uninstall: page and menu entry removed" || fail "web after remove: $(ls "$W/www/user")"
ipt -C FORWARD -j LF_FWD 2>/dev/null && fail "rules left after uninstall" || pass "uninstall: rules removed"
[ -f "$LF_HOME/lobbyfence.conf" ] && pass "uninstall keeps the settings" || fail "settings deleted"
[ -z "$(ipt -S | grep LF_)" ] && [ -z "$(ips list -n | grep '^lf_')" ] && pass "uninstall leaves no firewall rules or sets" || fail "rules left: $(ipt -S | grep -c LF_)"

# --- 11. brick safety: purge with the copy the installer kept, then a fresh install
# from the release package (unpacked by Merlin's own BusyBox), then purge again -
# the router is left as it was before LobbyFence: JFFS (scripts, add-on settings,
# the other add-on untouched), nvram, web pages and menu, firewall, ipsets.
# (jffs2_scripts stays on: other add-ons need it, LobbyFence doesn't turn it off)
snapshot() {
	( cd "$W/nvram" && for f in *; do [ "$f" = jffs2_scripts ] || printf '%s=%s\n' "$f" "$(cat "$f")"; done )
	echo "-- jffs:"; diff -r "$W/jffs.initial" "$W/jffs" 2>&1 | sed "s#$W##g"
	echo "-- web pages:"; find "$W/www/user" -type f -o -type l 2>/dev/null | sed "s#$W##"
	echo "-- menu:"; grep -c LobbyFence "$W/www/require/modules/menuTree.js" 2>/dev/null | grep -v '^0$'
	echo "-- cron:"; grep -i lobbyfence "$W/cron" 2>/dev/null
	echo "-- iptables:"; ipt -S | grep -i lf_; ipt -t mangle -S | grep -i lf_
	echo "-- ipsets:"; ips list -n | grep '^lf_'
}
initial="$( cd "$W/nvram.initial" && for f in *; do [ "$f" = jffs2_scripts ] || printf '%s=%s\n' "$f" "$(cat "$f")"; done; printf -- '-- jffs:\n-- web pages:\n-- menu:\n-- cron:\n-- iptables:\n-- ipsets:\n' )"
[ -f "$LF_HOME/install.sh" ] && pass "uninstall keeps a copy of the installer on JFFS (to purge later)" || fail "no installer copy in $LF_HOME"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 /bin/sh "$LF_HOME/install.sh" purge > "$W/purge.log" 2>&1
expect "purge: the router is as it was before LobbyFence (JFFS, scripts, add-on settings, nvram, web, firewall)" "$initial" "$(snapshot)"
rm -rf "$W/dist" "$W/pkg"; mkdir -p "$W/pkg"
sh "$HERE/../tools/build-packages.sh" "$W/dist" >/dev/null 2>&1 || fail "release packages not built"
( cd "$W/pkg" && "$MERLIN_SH" tar -xzf "$W/dist/lobbyfence-asuswrt-merlin.tar.gz" ) && [ -f "$W/pkg/lobbyfence-install/asuswrt-merlin/install.sh" ] \
	&& pass "the release package unpacks with Merlin's BusyBox into lobbyfence-install" || fail "package does not unpack"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 LF_NOSTART=1 /bin/sh "$W/pkg/lobbyfence-install/asuswrt-merlin/install.sh" > "$W/install2.log" 2>&1 \
	&& pass "installs from the release package" || fail "package install: $(tail -3 "$W/install2.log")"
inr env PATH="$TPATH" LF_JFFS="$W/jffs" LF_FORCE=1 /bin/sh "$LF_HOME/install.sh" purge > "$W/purge2.log" 2>&1
expect "purge after the package install: the router is as it was before" "$initial" "$(snapshot)"

grep -E "not found|syntax error|bad number|unexpected|can't" "$W/stderr.log" | grep -v "^$" | head -5 | while read -r l; do echo "STDERR: $l"; done
if grep -qE "not found|syntax error|bad number|unexpected" "$W/stderr.log"; then fail "errors from the scripts (see STDERR lines)"; fi
[ "$FAIL" = 0 ] && echo "ALL MERLIN TESTS PASSED" || { echo "SOME MERLIN TESTS FAILED"; exit 1; }
