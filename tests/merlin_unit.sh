#!/bin/sh
# Rules the Merlin backend writes where the test kernel can't show them:
# SKIPLOG (Broadcom only) in the zone chains, and the lag queue per direction.
#   usage: merlin_unit.sh <workdir> [shell]
W="$1"; SH="${2:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W/run"
cat > "$W/mu.sh" <<EOT
LF_RUN="$W/run"; LF_SHARE="$HERE/../files/usr/share/lobbyfence"; LF_LAGD=/bin/true
have() { type "\$1" >/dev/null 2>&1; }
log() { :; }
addr_list() { [ "\$1" = 4 ] && echo 192.168.1.100; }
mac_list() { :; }
. "\$LF_SHARE/fw-merlin.sh"
ipt_target_ok() { return 0; }          # the router's kernel has SKIPLOG and NFQUEUE
fw_families() { echo 4; }
zl() { Z_ID=game; Z_PROTO=udp; Z_LPORT=""; Z_RPORT=3074; Z_PORT=""; Z_BURST=0; Z_STRICT=1; Z_MODE=enforce; Z_LAG=1; Z_LAG_DIR=\$DIR; Z_LAG_DELAY=80; Z_LAG_JITTER=10; Z_LAG_LOSS=0; Z_DEV=192.168.1.100; Z_ALLOW=""; Z_BLOCK=""; Z_DEV4=192.168.1.100; Z_MACS=""; }
zone_load() { zl; }
ZONES_ON=game
fw_prepare; zl; ipt_zone game 4 > "\$LF_RUN/zone.out"
for DIR in both up down; do LAG_SUPPORTED=1; ipt_lag_zones; fw_mangle_extra 4 > "\$LF_RUN/mangle.\$DIR"; echo "\$MANGLE_HOOKS" > "\$LF_RUN/hooks.\$DIR"; done
DIR=both; zl; echo "\$(lagd_args)" > "\$LF_RUN/args.both"
EOT
$SH "$W/mu.sh" || { echo "FAIL: script error"; exit 1; }
F=0; ok() { echo "PASS: $*"; }; no() { echo "FAIL: $*"; F=1; }
r="$W/run"
grep -n -- "-A LF_game_o4" "$r/zone.out" | sed -n 1,2p | grep -q -- "-j SKIPLOG" && grep -q -- "-A LF_game_i4 -j SKIPLOG" "$r/zone.out" \
	&& ok "game connections kept out of hardware acceleration (SKIPLOG right after the private-address check)" || no "skiplog: $(grep -n SKIPLOG "$r/zone.out")"
grep -q -- "-A LF_game_o4 -j MARK" "$r/zone.out" && no "Merlin marks packets (no marks needed)" || ok "no packet marks on Merlin (the queue is matched directly)"
grep -q -- "-A LF_LAG -m set --match-set lf_game_dev4 src -j LF_game_lo4" "$r/mangle.both" && grep -q -- "dst -j LF_game_li4" "$r/mangle.both" \
	&& grep -q -- "-A LF_game_lo4 -p udp -m multiport --dports 3074 -g LF_game_q" "$r/mangle.both" \
	&& grep -q -- "-A LF_game_q -j NFQUEUE --queue-num 7401 --queue-bypass" "$r/mangle.both" && grep -q "FORWARD:LF_LAG" "$r/hooks.both" \
	&& ok "lag both ways: uploads and downloads of the game port queued (7401, bypass)" || no "both: $(cat "$r/mangle.both")"
grep -q "src -j LF_game_lo4" "$r/mangle.up" && ! grep -q "dst -j LF_game_li4" "$r/mangle.up" && ok "lag uploads only" || no "up: $(cat "$r/mangle.up")"
grep -q "dst -j LF_game_li4" "$r/mangle.down" && ! grep -q "src -j LF_game_lo4" "$r/mangle.down" && ok "lag downloads only" || no "down: $(cat "$r/mangle.down")"
[ "$(cat "$r/args.both")" = "-d 40 -j 5 -l 0" ] && ok "both ways: each direction half the ping and jitter" || no "args: $(cat "$r/args.both")"
[ "$F" = 0 ] && echo "ALL MERLIN UNIT TESTS PASSED" || exit 1
