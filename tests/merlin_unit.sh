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
zl() { Z_ID=game; Z_PROTO=udp; Z_LPORT=""; Z_RPORT=3074; Z_PORT=""; Z_BURST=0; Z_STRICT=1; Z_MODE=enforce; Z_LAG=1; Z_LAG_DIR=\$DIR; Z_LAG_DELAY=80; Z_LAG_JITTER=10; Z_LAG_LOSS=0; Z_DEV=192.168.1.100; Z_ALLOW=""; Z_BLOCK=""; Z_GROUPS=""; }
zone_load() { zl; }
# (the main script's: one group, the device on the zone's own ports)
zone_group() { G_TAG=""; G_LPORT="\$Z_LPORT"; G_RPORT="\$Z_RPORT"; G_PORT="\$Z_PORT"; G_DEV4="\$(addr_list 4)"; G_DEV6=""; G_MACS=""; }
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

# SKIPLOG on the 4.19 kernels: a module the firmware doesn't load by itself.
# A stand-in iptables-restore that knows the target only once the module is
# in (the fake) /proc/modules
skip_case() { # name modprobe-works(1|0)
	d="$W/sk.$1"; rm -rf "$d"; mkdir -p "$d/run" "$d/mods"
	: > "$d/proc_modules"
	cat > "$d/mu2.sh" <<EOT
LF_RUN="$d/run"; LF_SHARE="$HERE/../files/usr/share/lobbyfence"; LF_LAGD=/bin/true
LF_PROC_MODULES="$d/proc_modules"; LF_MODULES_DIR="$d/mods"; LF_FC=fc
have() { type "\$1" >/dev/null 2>&1; }
log() { echo "\$*" >> "$d/log"; }
addr_list() { [ "\$1" = 4 ] && echo 192.168.1.100; }
mac_list() { :; }
. "\$LF_SHARE/fw-merlin.sh"
modprobe() { [ "$2" = 1 ] && [ "\$1" = xt_SKIPLOG ] && echo "xt_SKIPLOG 16384 0 - Live 0x0" >> "\$LF_PROC_MODULES"; [ "$2" = 1 ]; }
insmod() { echo "insmod \$*" >> "$d/insmod"; return 1; }
lf_iptr4() { local in; in="\$(cat)"; case "\$in" in *SKIPLOG*) grep -q '^xt_SKIPLOG ' "\$LF_PROC_MODULES" || return 1;; esac; return 0; }
fc() { :; }
nvram() { [ "\$2" = fc_disable ] && echo 0; }
fw_families() { echo 4; }
zl() { Z_ID=game; Z_PROTO=udp; Z_LPORT=""; Z_RPORT=3074; Z_PORT=""; Z_BURST=0; Z_STRICT=1; Z_MODE=enforce; Z_LAG=0; Z_LAG_DIR=both; Z_DEV=192.168.1.100; Z_ALLOW=""; Z_BLOCK=""; Z_GROUPS=""; }
zone_load() { zl; }
zone_group() { G_TAG=""; G_LPORT="\$Z_LPORT"; G_RPORT="\$Z_RPORT"; G_PORT="\$Z_PORT"; G_DEV4="\$(addr_list 4)"; G_DEV6=""; G_MACS=""; }
ZONES_ON=game; LAG_SUPPORTED=0
echo 0 > "\$LF_RUN/target.4.SKIPLOG"   # asked before the module was loaded (1.4.6)
fw_prepare
echo "filter=\$FW_SKIP4" > "$d/prep"
zl; ipt_zone game 4 > "$d/zone.out"
accel_skip_ok && echo yes > "$d/skip" || echo no > "$d/skip"
fc_on && ! accel_skip_ok && echo true > "$d/offload" || echo false > "$d/offload"
fw_prepare; echo "\$(cat "\$LF_RUN/skiplog.load")" > "$d/load2"
EOT
	$SH "$d/mu2.sh" 2>"$d/err" || echo "script error: $(cat "$d/err")" > "$d/prep"
}
skip_case loads 1
s="$W/sk.loads"
[ "$(cat "$s/prep")" = "filter=SKIPLOG" ] && grep -q -- "-A LF_game_o4 -j SKIPLOG" "$s/zone.out" && [ "$(cat "$s/skip")" = yes ] \
	&& [ "$(cat "$s/run/skiplog.load")" = "module loaded" ] && [ "$(cat "$s/offload")" = false ] \
	&& ok "SKIPLOG a module (4.19 kernels): loaded from the firmware, then asked again despite the old 'missing' answer" \
	|| no "module load: prep=$(cat "$s/prep") load=$(cat "$s/run/skiplog.load" 2>/dev/null) skip=$(cat "$s/skip") $(cat "$s/err")"
[ "$(cat "$s/load2")" = "module loaded" ] && [ "$(grep -c . "$s/log")" = 1 ] && ok "the module is loaded once per boot" || no "load twice: $(cat "$s/log")"
skip_case none 0
s="$W/sk.none"
[ "$(cat "$s/prep")" = "filter=" ] && ! grep -q SKIPLOG "$s/zone.out" \
	&& [ "$(cat "$s/run/skiplog.load")" = "no xt_SKIPLOG module in this firmware" ] && [ "$(cat "$s/offload")" = true ] \
	&& ok "no module in the firmware: no SKIPLOG rules, diag says why, the page is told the flow cache wins (offload)" \
	|| no "no module: prep=$(cat "$s/prep") load=$(cat "$s/run/skiplog.load" 2>/dev/null) offload=$(cat "$s/offload") $(cat "$s/err")"
[ "$F" = 0 ] && echo "ALL MERLIN UNIT TESTS PASSED" || exit 1
