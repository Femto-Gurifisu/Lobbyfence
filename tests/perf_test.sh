#!/bin/sh
# Load test / benchmark: a zone that has learned many servers. Times the
# router-side work (apply, a learning pass, live status, status) with BusyBox,
# in a network namespace. A typical OpenWrt router CPU is roughly 10-30x slower
# than a desktop core; the limits are TARGETS for that headroom, not yet met
# at 20000 servers (see the notes of the 8th bug check).
#   usage: perf_test.sh <workdir> <busybox> <uci-prefix> <openwrt-checkout> [servers]
W="$1"; BB="$2"; N="${5:-20000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/setup_env.sh" "$@" >/dev/null || exit 1
. "$W/env.sh"
FAIL=0
cfg() { "$W/bin/uci" "$@"; }

cfg set lobbyfence.globals.enabled=1
cfg set lobbyfence.globals.geo_url='http://127.0.0.1:9/none'
cfg set lobbyfence.globals.data_dir="$W/data"
cfg set lobbyfence.big=zone
cfg set lobbyfence.big.enabled=1
cfg set lobbyfence.big.label=Big
cfg set lobbyfence.big.device=192.168.1.100
cfg add_list lobbyfence.big.remote_port=1024-65535
cfg add_list lobbyfence.big.circle='50.11,8.68,1500'
cfg add_list lobbyfence.big.polygon='30,-100;30,-80;45,-80;45,-100'
cfg commit lobbyfence

# N learned servers spread over the world, all located
mkdir -p "$W/data/zones"
awk -v n="$N" -v now="$(date +%s)" 'BEGIN { srand(7)
	for (i = 0; i < n; i++) {
		ip = (1 + int(i / 65536) % 200) "." int(i / 256) % 256 "." i % 256 "." (1 + i % 250)
		printf "%s %.4f %.4f %s %d\n", ip, rand() * 140 - 60, rand() * 360 - 180, "US", now > "/dev/stderr"
		printf "%s %d\n", ip, now - int(rand() * 86400)
	} }' > "$W/data/zones/big.ips" 2> "$W/data/geo.cache"

# the timed part runs in its own network namespace (it loads nft tables)
cat > "$W/perf_inner.sh" <<'INNER'
. "$W/env.sh"
FAIL=0
now_ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
t() { # name limit_ms command...
	name="$1"; lim="$2"; shift 2
	s=$(now_ms); "$@" >/dev/null 2>&1; rc=$?; e=$(now_ms)
	ms=$((e - s))
	if [ "$rc" = 0 ] && [ "$ms" -le "$lim" ]; then echo "PASS: $name: ${ms} ms (limit $lim)"; else echo "FAIL: $name: ${ms} ms rc=$rc (limit $lim)"; FAIL=1; fi
}
# limits: a ~20x slower router CPU must still finish well inside the 20 s learning pass
t "apply with $N servers (boot: everything classified)" 1000 $LF apply
t "Save & Apply again, same region" 1000 $LF apply
t "first learning pass" 1000 $LF cycle
t "learning pass (steady state)" 500 $LF cycle
t "live status (every 5 s)" 150 $LF live
t "status" 500 $LF status
n=$(nft list set inet lobbyfence z_big_in4 | tr ',' '\n' | grep -c '\.')
m=$(nft list set inet lobbyfence z_big_out4 | tr ',' '\n' | grep -c '\.')
[ $((n + m)) -ge $((N * 9 / 10)) ] && echo "PASS: all servers loaded into the firewall ($n in, $m out)" || { echo "FAIL: firewall sets hold $n + $m"; FAIL=1; }
s=$(wc -c < "$W/run/status.json"); [ "$s" -lt 20000 ] && echo "PASS: status.json stays small ($s bytes)" || { echo "FAIL: status.json $s bytes"; FAIL=1; }
echo "INFO: big.servers for the map: $(wc -c < "$W/run/big.servers") bytes"
exit $FAIL
INNER
W="$W" N="$N" unshare -n sh "$W/perf_inner.sh" || FAIL=1
[ "$FAIL" = 0 ] && echo "ALL PERF TESTS PASSED"
exit $FAIL
