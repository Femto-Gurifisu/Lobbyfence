#!/bin/sh
# Load test of the FreshTomato port: a zone with many learned servers, timed on
# FreshTomato's BusyBox with ipset / legacy iptables, in a network namespace.
# A router CPU is roughly 10-30x slower than a desktop core.
#   usage: tomato_perf_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset> [servers]
W="$1"; N="${5:-20000}"
HERE="$(cd "$(dirname "$0")" && pwd)"
sh "$HERE/tomato_env.sh" "$1" "$2" "$3" "$4" >/dev/null || exit 1
. "$W/env.sh"
cat > "$LF_HOME/lobbyfence.conf" <<EOF
config globals 'globals'
	option enabled '1'
	option geo_url 'http://127.0.0.1:9/none'
	option data_dir '$LF_HOME/data'

config zone 'big'
	option enabled '1'
	option label 'Big'
	list device '192.168.1.100'
	list remote_port '1024-65535'
	list circle '50.11,8.68,1500'
	list polygon '30,-100;30,-80;45,-80;45,-100'
EOF
mkdir -p "$LF_HOME/data/zones"
awk -v n="$N" -v now="$(date +%s)" 'BEGIN { srand(7)
	for (i = 0; i < n; i++) {
		ip = (1 + int(i / 65536) % 200) "." int(i / 256) % 256 "." i % 256 "." (1 + i % 250)
		printf "%s %.4f %.4f %s %d\n", ip, rand() * 140 - 60, rand() * 360 - 180, "US", now > "/dev/stderr"
		printf "%s %d\n", ip, now - int(rand() * 86400)
	} }' > "$LF_HOME/data/zones/big.ips" 2> "$LF_HOME/data/geo.cache"

cat > "$W/perf_inner.sh" <<'INNER'
FAIL=0
ms() { python3 -c 'import time; print(int(time.time() * 1000))'; }
t() { # name limit_ms command...
	name="$1"; lim="$2"; shift 2
	s=$(ms); env PATH="$TPATH" "$@" >/dev/null 2>&1; rc=$?; e=$(ms)
	if [ "$rc" = 0 ] && [ $((e - s)) -le "$lim" ]; then echo "PASS: $name: $((e - s)) ms (limit $lim)"; else echo "FAIL: $name: $((e - s)) ms rc=$rc (limit $lim)"; FAIL=1; fi
}
LF="$LF_HOME/lobbyfence"
t "apply with $N servers (boot)" 4000 $LF apply
t "Save & Apply again, same region" 2000 $LF apply
t "first learning pass" 1000 $LF cycle
t "learning pass (steady state)" 500 $LF cycle
t "live status (every 5 s)" 300 $LF live
t "status" 600 $LF status
n=$(env PATH="$TPATH" ipset list lf_big_in4 | grep -c '^[0-9]'); m=$(env PATH="$TPATH" ipset list lf_big_out4 | grep -c '^[0-9]')
[ $((n + m)) -ge $((N * 9 / 10)) ] && echo "PASS: all servers in the ipsets ($n in, $m out)" || { echo "FAIL: ipsets hold $n + $m"; FAIL=1; }
exit $FAIL
INNER
unshare -n -m --propagation private sh -c 'mount --bind "$TOMATO_SH" "$(readlink -f /bin/sh)" && W="'"$W"'" N="'"$N"'" sh "'"$W"'/perf_inner.sh"'
rc=$?
[ "$rc" = 0 ] && echo "ALL TOMATO PERF TESTS PASSED"
exit $rc
