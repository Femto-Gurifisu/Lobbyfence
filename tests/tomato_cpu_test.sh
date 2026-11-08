#!/bin/sh
# CPU use of LobbyFence on FreshTomato, measured: the learning loop running
# on its own, with the map page open (its requests every 5 s), and with
# LobbyFence switched off. Runs on FreshTomato's BusyBox, ipset and legacy
# iptables in a network namespace; prints CPU seconds per minute and an
# estimate for a 1 GHz ARM router (factor LF_ARM_FACTOR, default 15).
#   usage: tomato_cpu_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset> [servers per zone] [seconds]
W="$1"; N="${5:-1500}"; SECS="${6:-60}"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/tomato_env.sh" "$1" "$2" "$3" "$4" >/dev/null || exit 1
. "$W/env.sh"
cat > "$LF_HOME/lobbyfence.conf" <<EOF
config globals 'globals'
	option enabled '1'
	option geo_url 'http://127.0.0.1:9/none'
	option data_dir '$LF_HOME/data'
	option interval '60'

config zone 'game'
	option enabled '1'
	option label 'Game'
	option proto 'udp'
	list device '192.168.1.100'
	list remote_port '3074'
	list remote_port '27000-27200'
	list circle '50.11,8.68,1500'

config zone 'phone'
	option enabled '1'
	option label 'Phone'
	option proto 'tcp'
	list device '192.168.1.101'
	list remote_port '443'
	list circle '40.7,-74.0,1500'
EOF
mkdir -p "$LF_HOME/data/zones"
for z in game phone; do
	awk -v n="$N" -v now="$(date +%s)" -v z="$z" 'BEGIN { srand(z == "game" ? 7 : 9)
		for (i = 0; i < n; i++) {
			ip = (z == "game" ? 20 : 60) + int(i / 65536) % 30 "." int(i / 256) % 256 "." i % 256 "." (1 + i % 250)
			printf "%s %.4f %.4f %s %d\n", ip, rand() * 140 - 60, rand() * 360 - 180, "US", now > "/dev/stderr"
			printf "%s %d\n", ip, now - int(rand() * 86400)
		} }' > "$LF_HOME/data/zones/$z.ips" 2>> "$LF_HOME/data/geo.cache"
done
# a busy home network: 3000 connections in the connection table, 40 of them the zones' devices
awk 'BEGIN { for (i = 0; i < 3000; i++) {
	d = i < 20 ? "192.168.1.100" : i < 40 ? "192.168.1.101" : "192.168.1." (110 + i % 100)
	p = i < 20 ? "udp" : "tcp"; pn = p == "udp" ? 17 : 6
	printf "ipv4     2 %s      %d 120 src=%s dst=%d.%d.%d.%d sport=%d dport=%d packets=%d bytes=%d src=%d.%d.%d.%d dst=100.64.0.2 sport=%d dport=%d packets=%d bytes=%d [ASSURED] mark=0 use=1\n",
		p, pn, d, 20 + i % 30, int(i / 256) % 256, i % 256, 1 + i % 250, 40000 + i, i < 20 ? 3074 : 443, 100 + i, 9000 + i,
		20 + i % 30, int(i / 256) % 256, i % 256, 1 + i % 250, i < 20 ? 3074 : 443, 40000 + i, 90 + i, 8000 + i } }' > "$W/conntrack"

cat > "$W/cpu_inner.sh" <<'INNER'
export PATH="$TPATH" LF_CONNTRACK="$W/conntrack"
LF="$LF_HOME/lobbyfence"
clk=$(getconf CLK_TCK 2>/dev/null || echo 100)
# CPU ticks of a process and the children it waited for
ticks() { awk '{ print $14 + $15 + $16 + $17 }' "/proc/$1/stat" 2>/dev/null || echo 0; }
self_ticks() { /usr/bin/python3 -c 'import os; t = os.times(); print(int((t.children_user + t.children_system) * '"$clk"'))'; }
report() { # name ticks
	awk -v n="$1" -v t="$2" -v s="$SECS" -v c="$clk" -v f="${LF_ARM_FACTOR:-15}" 'BEGIN {
		cpu = t / c; pm = cpu * 60 / s
		printf "RESULT: %-44s %6.2f CPU-s/min here = %5.2f%% of a core; on a 1 GHz ARM router (x%d) ~%5.1f%% of one core\n", n, pm, pm / 60 * 100, f, pm / 60 * 100 * f }'
}

"$LF" web >/dev/null 2>&1          # (the page and its CGI, as at start)
"$LF" apply >/dev/null 2>&1
"$LF" cycle >/dev/null 2>&1
# --- 1. the learning loop alone (no page open)
"$LF" daemon </dev/null >/dev/null 2>&1 &
D=$!
sleep 8
a=$(ticks $D); sleep "$SECS"; b=$(ticks $D)
report "learning loop, page closed" $((b - a))

# the map page's requests for SECS seconds (CPU ticks of everything they ran -> $W/cgi.ticks)
page_load() {
/usr/bin/python3 - "$LF_WWWEXT/cgi-bin/lobbyfence.cgi" "$SECS" > "$W/cgi.ticks" <<'PY'
import os, subprocess, sys, time
cgi, secs = sys.argv[1], int(sys.argv[2])
t0 = os.times(); end = time.time() + secs
while time.time() < end:
    for body in (b"TID1234567890abc\nread status\n", b"TID1234567890abc\nrunning\n", b"TID1234567890abc\nexec live\n"):
        subprocess.run([cgi], input=body, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                       env=dict(os.environ, REQUEST_METHOD="POST", CONTENT_LENGTH=str(len(body))))
    time.sleep(max(0, 5 - 0))
t1 = os.times()
print(int(((t1.children_user + t1.children_system) - (t0.children_user + t0.children_system)) * os.sysconf("SC_CLK_TCK")))
PY

}

# --- 2. the map page open: every 5 s status + live (+ running check), through the CGI
a=$(ticks $D)
page_load
b=$(ticks $D)
report "map page open: its requests (every 5 s)" "$(cat "$W/cgi.ticks")"
report "map page open: learning loop meanwhile" $((b - a))

# --- 3. LobbyFence switched off (Enable unticked + Save & Apply): no learning loop
# runs then (the start script doesn't start it) - only the open map page asks
kill $D 2>/dev/null; wait $D 2>/dev/null
sed -i "s/option enabled '1'/option enabled '0'/" "$LF_HOME/lobbyfence.conf"
"$LF" restart >/dev/null 2>&1
/usr/bin/pgrep -f "lobbyfence-main daemon" >/dev/null && echo "NOTE: a learning loop is running while switched off"
page_load
report "switched off, map page open: its requests" "$(cat "$W/cgi.ticks")"
INNER
unshare -n -m --propagation private sh -c 'mount --bind "$TOMATO_SH" "$(readlink -f /bin/sh)" && W="'"$W"'" SECS="'"$SECS"'" sh "'"$W"'/cpu_inner.sh"'
