#!/bin/sh
# The geolocation service's free-tier limits, against fake_geo.py behaving like
# ip-api.com's batch endpoint (15 requests a minute per address, X-Rl / X-Ttl,
# 429, 100 addresses per request). The router script runs on the given shell
# with a stand-in firewall backend that reports many new servers at once.
#   usage: geo_limit_test.sh <workdir> <busybox>
W="$1"; BB="$2"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
rm -rf "$W"; mkdir -p "$W/share" "$W/run" "$W/data" "$W/bin" "$W/bb"
for a in $("$BB" --list); do ln -s "$BB" "$W/bb/$a"; done
rm -f "$W/bb/logger"
ln -s /usr/bin/curl "$W/bin/curl"
printf '#!/bin/sh\nwhile [ $# -gt 0 ]; do case "$1" in -t|-p) shift 2;; --) shift; break;; *) break;; esac; done\necho "LOG: $*" >> %s/run.log\n' "$W" > "$W/bin/logger"
chmod +x "$W/bin/logger"
cp "$REPO/files/usr/share/lobbyfence/lobbyfence.awk" "$REPO/freshtomato/functions.sh" "$REPO/freshtomato/conf.awk" "$W/share/"
# a stand-in backend: the servers "seen" come from a file
cat > "$W/share/fw-stub.sh" <<EOF
LF_ZONE_MAXLEN=16
fw_exists() { return 0; }
fw_build() { :; }; fw_commit() { :; }; fw_post_apply() { :; }; fw_remove() { :; }; fw_check() { :; }
fw_zone_servers() { :; }; fw_zone_mip() { :; }; fw_load_sets() { :; }; fw_override() { :; }
fw_seen() { cat "$W/seen" 2>/dev/null; }
fw_now() { :; }; fw_open_left() { echo 0; }; counters_load() { COUNTERS=""; }
fw_status_json() { printf '"platform":"stub",'; }
EOF
cat > "$W/lobbyfence.conf" <<EOF
config globals 'globals'
	option enabled '1'
	option interval '20'
	option geo_url 'http://127.0.0.1:8099/batch'
	option max_batches '20'
	option data_dir '$W/data'

config zone 'game'
	option enabled '1'
	option mode 'monitor'
	list device '192.168.1.100'
	list remote_port '3074'
	list circle '50.1,8.6,800'
EOF
FAIL=0
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; FAIL=1; }
lf() { env -i PATH="$W/bin:$W/bb" LF_SHARE="$W/share" LF_FW=stub LF_FUNCTIONS="$W/share/functions.sh" LF_CONF_FILE="$W/lobbyfence.conf" \
	LF_RUN="$W/run" LF_DATA_DEFAULT="$W/data" "$BB" sh "$REPO/files/usr/sbin/lobbyfence" "$@"; }
calls() { wc -l < "$W/geo.log" 2>/dev/null | tr -d ' '; }
n429() { if [ -f "$W/geo.log.429" ]; then wc -l < "$W/geo.log.429" | tr -d ' '; else echo 0; fi; }

python3 "$HERE/fake_geo.py" 8099 "$W/geo.log" & GEO=$!
trap 'kill $GEO 2>/dev/null' EXIT INT TERM
sleep 0.5

# 2500 brand-new servers at once (25 batches of 100)
awk 'BEGIN { for (i = 0; i < 2500; i++) printf "%d.%d.%d.%d\n", 20 + int(i / 65536) % 200, int(i / 256) % 256, i % 256, 7 }' > "$W/seen"
: > "$W/geo.log"
lf cycle 2>>"$W/stderr.log"
c="$(calls)"
[ "$c" -le 14 ] && [ "$c" -ge 1 ] && pass "a burst of 2500 new servers: $c requests in the first pass (at most 14 a minute)" || fail "first pass sent $c"
awk '{ n = gsub(/","/, ""); if (n + 1 > 100) bad = 1 } END { exit bad }' "$W/geo.log" && pass "at most 100 addresses per request" || fail "a request had over 100 addresses"
lf cycle 2>>"$W/stderr.log"; lf cycle 2>>"$W/stderr.log"
[ "$(calls)" -le 14 ] && pass "more passes within the minute send nothing more ($(calls) in total)" || fail "$(calls) requests within a minute"
out="$(lf whereis 1.2.3.4 2>&1)"
echo "$out" | grep -q "rate limit" && [ "$(calls)" -le 14 ] && pass "whereis on the command line counts too (refused: '$out')" || fail "whereis: $out / $(calls)"
out="$(lf apitest 2>&1)"
echo "$out" | grep -q "rate limit" && [ "$(calls)" -le 14 ] && pass "Test API button counts too" || fail "apitest: $out / $(calls)"
[ "$(n429)" = 0 ] && pass "the service never had to say 429" || fail "$(n429) times 429"

# another device on the same internet address used up the service's count
rm -f "$W/run/geo.calls"; touch "$W/geo.log.reset"
echo 14 > "$W/geo.log.used"
c0="$(calls)"
lf cycle 2>>"$W/stderr.log"
c1="$(calls)"
[ $((c1 - c0)) = 1 ] && [ -s "$W/run/geo.backoff" ] && pass "the service's X-Rl reached 0 (other devices): LobbyFence stops at once and waits ($((c1 - c0)) request)" \
	|| fail "X-Rl: sent $((c1 - c0)), backoff '$(cat "$W/run/geo.backoff" 2>/dev/null)'"
lf cycle 2>>"$W/stderr.log"; lf apitest >/dev/null 2>&1
[ "$(calls)" = "$c1" ] && [ "$(n429)" = 0 ] && pass "while the service asked to wait, nothing is sent (not even Test API)" || fail "sent while waiting: $(calls) vs $c1, 429s $(n429)"

# the service answers 429 (e.g. counts we can't see): wait as long as it says
rm -f "$W/run/geo.backoff" "$W/run/geo.calls"; touch "$W/geo.log.reset"
echo 30 > "$W/geo.log.used"
c0="$(calls)"
lf cycle 2>>"$W/stderr.log"
lf cycle 2>>"$W/stderr.log"
[ "$(n429)" = 1 ] && [ -s "$W/run/geo.backoff" ] && pass "after one 429 LobbyFence waits (no second try; going on would get the address banned for an hour)" \
	|| fail "429: $(n429) times, backoff '$(cat "$W/run/geo.backoff" 2>/dev/null)'"
grep -q "too many requests" "$W/run.log" && pass "logged in plain words" || fail "no log line"

# a clock change (NTP at boot) doesn't reset the count
rm -f "$W/run/geo.backoff"; touch "$W/geo.log.reset"
up="$(awk '{ printf "%d", $1 }' /proc/uptime)"
awk -v t="$up" 'BEGIN { for (i = 0; i < 14; i++) print t }' > "$W/run/geo.calls"
c0="$(calls)"
lf cycle 2>>"$W/stderr.log"
[ "$(calls)" = "$c0" ] && pass "the count uses time since boot: a clock jump can't reset it" || fail "sent $(( $(calls) - c0 )) after a full count"

# an older version's clock-based files don't block lookups for years
date +%s > "$W/run/geo.calls"; echo $(( $(date +%s) + 120 )) > "$W/run/geo.backoff"
sleep 61
c0="$(calls)"
lf apitest >/dev/null 2>&1
[ "$(calls)" -gt "$c0" ] && pass "files left by an older version are ignored" || fail "stuck on old files"

# a hostile answer (plain HTTP: anyone on the way can answer): endless and fast,
# or a byte now and then forever - cut at 1 MB and 30 s, with curl and with
# BusyBox wget (whose -T only limits silence)
cat > "$W/hostile.py" <<'PYEOF'
import sys, time
from http.server import BaseHTTPRequestHandler, HTTPServer
class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0); self.rfile.read(n)
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        try:
            if sys.argv[2] == "flood":
                while True: self.wfile.write(b"[" + b" " * 65536)
            else:
                while True: self.wfile.write(b" "); self.wfile.flush(); time.sleep(5)
        except Exception:
            pass
HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PYEOF
python3 "$W/hostile.py" 8097 flood & HF=$!
python3 "$W/hostile.py" 8096 trickle & HT=$!
sleep 0.5
for mode in flood:8097 trickle:8096; do
	for tool in curl wget; do
		sed -i "s#option geo_url .*#option geo_url 'http://127.0.0.1:${mode#*:}/batch'#" "$W/lobbyfence.conf"
		if [ "$tool" = curl ]; then path="$W/bin:$W/bb"; else path="$W/bb2"; fi
		[ -d "$W/bb2" ] || { mkdir -p "$W/bb2"; for a in $("$BB" --list); do [ "$a" = logger ] || ln -s "$BB" "$W/bb2/$a"; done; ln -s "$W/bin/logger" "$W/bb2/logger"; }
		rm -f "$W/run/geo.backoff"; : > "$W/run/geo.calls"
		t0=$(date +%s)
		env -i PATH="$path" LF_SHARE="$W/share" LF_FW=stub LF_FUNCTIONS="$W/share/functions.sh" LF_CONF_FILE="$W/lobbyfence.conf" \
			LF_RUN="$W/run" LF_DATA_DEFAULT="$W/data" "$BB" sh "$REPO/files/usr/sbin/lobbyfence" apitest >/dev/null 2>&1
		t1=$(date +%s)
		left="$(ls "$W/run"/http.* 2>/dev/null)"
		[ $((t1 - t0)) -le 40 ] && [ -z "$left" ] \
			&& pass "a hostile ${mode%%:*} answer, fetched with $tool: given up after $((t1 - t0)) s, nothing left in memory" \
			|| fail "${mode%%:*} with $tool: $((t1 - t0)) s, left: $left"
	done
done
kill $HF $HT 2>/dev/null
sed -i "s#option geo_url .*#option geo_url 'http://127.0.0.1:8099/batch'#" "$W/lobbyfence.conf"

grep -E "not found|syntax error|bad number|unexpected" "$W/stderr.log" | head -3 | sed 's/^/STDERR: /'
grep -qE "not found|syntax error|bad number|unexpected" "$W/stderr.log" && fail "errors from the script"
[ "$FAIL" = 0 ] && echo "ALL GEO LIMIT TESTS PASSED" || { echo "SOME GEO LIMIT TESTS FAILED"; exit 1; }
