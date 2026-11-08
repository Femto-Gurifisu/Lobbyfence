#!/bin/sh
# The Merlin lag simulator's choice between netem and lf-lagd, with the
# GT-AXE16000's tools stood in by tests/fake_merlin_netem.sh (the test kernel
# has no netem / prio / dummy): self-test on a private dummy interface, the
# queues and CLASSIFY targets it sets up, the two-minute trial, and every way
# of falling back to lf-lagd (QoS on, self-test failing, the kernel refusing
# the module, a restart during an earlier trial, another model).
#   usage: merlin_netem_unit.sh <workdir> [shell]
W="$1"; SH="${2:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
rm -rf "$W"; mkdir -p "$W/bin" "$W/home/netem/gt-axe16000-4.19.183"
for t in tc ip ping insmod iptables ip6tables iptables-restore ip6tables-restore uname; do
	ln -s "$HERE/fake_merlin_netem.sh" "$W/bin/$t"
done
for d in "$REPO"/asuswrt-merlin/netem/*-4.19.183; do
	mkdir -p "$W/home/netem/${d##*/}"; cp "$d/sch_netem.ko" "$W/home/netem/${d##*/}/"
done
# lf-lagd stand-in: says it runs (like the real one) and waits
printf '#!/bin/sh\necho "lf-lagd: queue $2, delay" >&2\nexec sleep 60\n' > "$W/home/lf-lagd"; chmod 755 "$W/home/lf-lagd"
echo 0123-boot-id > "$W/boot_id"

# one scenario: fresh state, then the commands in $2 (after the backend is loaded)
run() { # name 'setup shell' 'commands' [model]
	rm -rf "$W/fake" "$W/run"; mkdir -p "$W/fake" "$W/run"
	rm -f "$W/home/.netem-ok" "$W/home/.netem-loading"
	printf 'LF_game_q\nLF_z2_q\n' > "$W/fake/chains"
	(cd "$W/fake" && eval "$2")
	cat > "$W/s.sh" <<EOT
PATH="$W/bin:\$PATH"; FAKE_DIR="$W/fake"; export FAKE_DIR
LF_RUN="$W/run"; LF_HOME="$W/home"; LF_SHARE="$REPO/files/usr/share/lobbyfence"
LF_LAGD="$W/home/lf-lagd"; LF_PROC_MODULES="$W/fake/proc.modules"; LF_BOOT_ID="$W/boot_id"; LF_IPV6=0
have() { type "\$1" >/dev/null 2>&1; }
log() { echo "LOG \$*" >> "$W/run/log"; }
nvram() { [ "\$1" = get ] || return 0; case "\$2" in productid) echo "${4:-GT-AXE16000}";; odmpid) echo "${5:-}";; esac; }
addr_list() { [ "\$1" = 4 ] && echo 192.168.50.100; }
mac_list() { :; }
. "\$LF_SHARE/fw-merlin.sh"
zone_load() {
	Z_ID=\$1; Z_PROTO=udp; Z_LPORT=""; Z_RPORT=3074; Z_PORT=""; Z_LAG=1; Z_LAG_DELAY=80; Z_LAG_JITTER=10; Z_LAG_LOSS=0
	Z_DEV=192.168.50.100; Z_DEV4=192.168.50.100; Z_MACS=""; Z_MODE=enforce; Z_ENABLED=1
	if [ "\$1" = z2 ]; then Z_LAG_DIR=up; else Z_LAG_DIR=both; fi
}
ZONES_ON="game z2"
echo "192.168.50.100" > "\$LF_RUN/game.dev"; echo "192.168.50.100" > "\$LF_RUN/z2.dev"
$3
EOT
	$SH "$W/s.sh" > "$W/out.$1" 2>&1
	pkill -f "exec sleep 60" 2>/dev/null; pkill -f "^sleep 60" 2>/dev/null
}
F=0; ok() { echo "PASS: $*"; }; no() { echo "FAIL: $*"; F=1; }
r="$W/run"; f="$W/fake"

# --- 0. which module: one per model (productid, else odmpid), only for the running kernel
for mdl in GT-AX6000 XT12 GT-AX11000_PRO RT-AX86U_PRO RT-AX88U_PRO GT-AXE16000; do
	run M ':' 'echo "ko=$(merlin_netem_ko)"' "$mdl"
	l="$(echo "$mdl" | tr A-Z a-z)"
	grep -qx "ko=$W/home/netem/$l-4.19.183/sch_netem.ko" "$W/out.M" && ok "$mdl: its netem module is found" || no "$mdl: $(cat "$W/out.M")"
done
run M ':' 'echo "ko=$(merlin_netem_ko)"' 'ZENWIFI_PRO_XT12' 'XT12'
grep -qx "ko=$W/home/netem/xt12-4.19.183/sch_netem.ko" "$W/out.M" && ok "found by odmpid when productid is another name" || no "odmpid: $(cat "$W/out.M")"
run M ':' 'echo "ko=$(merlin_netem_ko)"' 'RT-AX86U'
grep -qx "ko=" "$W/out.M" && ok "a model without a module: none (lf-lagd)" || no "RT-AX86U: $(cat "$W/out.M")"

# --- A. the GT-AXE16000: netem works
run A ':' 'ipt_lag_apply; ipt_lag_zones; fw_mangle_extra 4 > "$LF_RUN/mangle"; fw_status_json > "$LF_RUN/st"; echo "state=$(netem_state)"
LF_NETEM_TRIAL=0; netem_trial_check; echo "nopackets=$(netem_state)"; touch "$FAKE_DIR/traffic"; netem_trial_check; echo "after=$(netem_state)"; fw_diag'
[ "$(cat "$r/lag.kind" 2>/dev/null)" = netem ] && ok "GT-AXE16000: lag runs on netem" || no "kind: $(cat "$r/lag.kind" 2>&1) $(cat "$r/log")"
grep -q "insmod $W/home/netem/gt-axe16000-4.19.183/sch_netem.ko" "$f/calls.log" && ok "the module for this model and kernel is the one loaded" || no "insmod: $(grep insmod "$f/calls.log")"
grep -q "ip link add lfnetem0 type dummy" "$f/calls.log" && grep -q "tc filter add dev lfnetem0 .*u32 match u32 0 0 flowid 7a:4" "$f/calls.log" \
	&& grep -q "ping -c 3 -w 3 -I lfnetem0 198.18.254.2" "$f/calls.log" && grep -q "ip link del lfnetem0" "$f/calls.log" \
	&& [ "$(cat "$r/netem.selftest")" = ok ] && ok "self-test on a private dummy interface first, removed again" || no "selftest: $(cat "$r/netem.selftest" 2>&1)"
# the self-test comes before any real device gets a queue
st_line="$(grep -n "lfnetem0 root" "$f/calls.log" | head -n 1 | cut -d: -f1)"; br_line="$(grep -n "dev br0 root" "$f/calls.log" | head -n 1 | cut -d: -f1)"
[ -n "$st_line" ] && [ -n "$br_line" ] && [ "$st_line" -lt "$br_line" ] && ok "self-test before real traffic is touched" || no "order $st_line $br_line"
grep -q "tc qdisc add dev br0 root handle 7a: prio bands 5" "$f/calls.log" && grep -q "tc qdisc add dev br0 parent 7a:4 handle 81: netem limit 10000 delay 40ms 5ms" "$f/calls.log" \
	&& ! grep -q "dev br0 parent 7a:5 handle 82: netem" "$f/calls.log" && ok "downloads (br0): game's netem band, the upload-only zone has none" || no "br0: $(grep br0 "$f/calls.log")"
grep -q "tc qdisc add dev eth0 parent 7a:4 handle 81: netem limit 10000 delay 40ms 5ms" "$f/calls.log" \
	&& grep -q "tc qdisc add dev eth0 parent 7a:5 handle 82: netem limit 10000 delay 80ms 10ms" "$f/calls.log" \
	&& ok "uploads (WAN): both zones' bands, 'both ways' halves the ping each way" || no "eth0: $(grep eth0 "$f/calls.log")"
grep -q "fw" "$f/calls.log" && grep -q "filter add dev br0" "$f/calls.log" && no "a fw filter / marks used" || ok "no packet marks or fw filters on real devices"
grep -q -- "-t mangle -R LF_game_q 1 -j CLASSIFY --set-class 7a:4" "$f/ipt.log" && grep -q -- "-t mangle -R LF_z2_q 1 -j CLASSIFY --set-class 7a:5" "$f/ipt.log" \
	&& grep -q -- "-A LF_game_q -j CLASSIFY --set-class 7a:4" "$r/mangle" && ok "the zones' rules put their packets in their band (CLASSIFY), also after a firewall rebuild" || no "classify: $(cat "$f/ipt.log") / $(grep _q "$r/mangle")"
grep -q '"lag_kind":"netem","netem":"trial"' "$r/st" && grep -q "state=trial" "$W/out.A" && grep -q "nopackets=trial" "$W/out.A" && grep -q "after=works" "$W/out.A" \
	&& [ -f "$W/home/.netem-ok" ] && ok "two-minute trial with game packets through netem, then recorded as working" || no "trial: $(cat "$W/out.A")"
[ -f "$W/home/.netem-loading" ] && ok "...the guard stays while netem is in use (a restart now is remembered, also after the trial)" || no "guard gone while in use"
grep -q "lag simulator: netem, queues on: br0 eth0" "$W/out.A" && grep -q "^netem: trial\|^netem: works" "$W/out.A" && ok "diag says netem and where" || no "diag: $(cat "$W/out.A")"
! pgrep -f "$W/home/lf-lagd" >/dev/null && ok "lf-lagd not started" || no "lf-lagd running"

# --- B. QoS uses the WAN: lf-lagd instead, br0 left as it was
run B 'touch busy.eth0' 'ipt_lag_apply; ls "$LF_RUN"/lagd.*.pid'
[ "$(cat "$r/lag.kind")" = nfqueue ] && [ "$(cat "$r/lag.why")" = busy ] && grep -q "lagd.game.pid" "$W/out.B" && ok "QoS on: falls back to lf-lagd" || no "busy: $(cat "$r/lag.kind" "$r/lag.why" "$W/out.B" 2>&1)"
[ ! -f "$f/dev/br0" ] && ok "the queue already put on br0 is taken away again" || no "br0 left: $(cat "$f/dev/br0")"
grep -q -- "-R LF_game_q 1 -j NFQUEUE --queue-num 7401 --queue-bypass" "$f/ipt.log" && ok "rules point at lf-lagd's queues" || no "nfq: $(cat "$f/ipt.log")"
[ ! -f "$W/home/.netem-loading" ] && [ ! -f "$r/lag.game.err" ] && ok "no trial pending, no error shown (lag works)" || no "guard/err"

# --- C. self-test fails: lf-lagd, and not retried this boot
run C 'touch netem-broken' 'ipt_lag_apply; ipt_lag_apply; echo "state=$(netem_state)"'
[ "$(cat "$r/lag.kind")" = nfqueue ] && [ "$(cat "$r/lag.why")" = selftest ] && [ "$(cat "$r/netem.selftest")" = failed ] && ok "self-test fails: lf-lagd" || no "selftest: $(cat "$r/log")"
[ "$(grep -c "ip link add lfnetem0" "$f/calls.log")" = 1 ] && ! grep -q "dev br0 root" "$f/calls.log" && ok "real devices never got a netem queue; self-test not repeated" || no "C calls: $(cat "$f/calls.log")"
grep -q "state=selftest-failed" "$W/out.C" && ok "state: selftest-failed" || no "state C: $(cat "$W/out.C")"

# --- D. the router restarted during an earlier trial: netem is never tried again
run D 'echo "other-boot 50" > "'"$W"'/home/.netem-loading"' 'ipt_lag_apply; echo "state=$(netem_state)"'
! grep -q "^insmod" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemcrash ] && [ "$(cat "$r/lag.kind")" = nfqueue ] && grep -q "state=crashed" "$W/out.D" \
	&& [ -f "$W/home/.netem-loading" ] && ok "restart during the trial: never loaded again, lf-lagd used" || no "crash: $(cat "$f/calls.log" "$W/out.D")"

# --- D2. netem worked on this firmware before, but the router restarted while it was in use
run D2 'echo "other-boot 50" > "'"$W"'/home/.netem-loading"' 'netem_id > "$LF_HOME/.netem-ok"; ipt_lag_apply; echo "state=$(netem_state)"'
! grep -q "^insmod" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemcrash ] && grep -q "state=crashed" "$W/out.D2" \
	&& ok "netem worked before, but a restart while in use: not loaded again (no reboot loop after a firmware change)" || no "crash after trial: $(cat "$f/calls.log" "$W/out.D2")"

# --- E. the kernel refuses the module
run E 'touch insmod-fail' 'ipt_lag_apply'
[ "$(cat "$r/lag.why")" = netemrefused ] && [ "$(cat "$r/lag.kind")" = nfqueue ] && [ ! -f "$W/home/.netem-loading" ] && ok "module refused: lf-lagd, no trial left behind" || no "refused: $(cat "$r/log")"

# --- F. another model: no netem, lf-lagd directly
run F ':' 'echo "have=$NETEM_HAVE"; ipt_lag_apply; echo "state=$(netem_state)"' RT-AX86U
grep -q "have=0" "$W/out.F" && ! grep -q "insmod\|lfnetem0" "$f/calls.log" && [ "$(cat "$r/lag.kind")" = nfqueue ] && [ ! -f "$r/lag.why" ] && grep -q "state=none" "$W/out.F" \
	&& ok "other models: lf-lagd, netem never touched" || no "other model: $(cat "$W/out.F" "$f/calls.log")"

# --- G. no lf-lagd either: the zone shows why
run G 'touch busy.eth0' 'LF_LAGD=/nonexistent; ipt_lag_apply'
[ "$(cat "$r/lag.game.err")" = busy ] && ok "nothing can run: the zone shows netem's reason" || no "G: $(cat "$r/lag.game.err" 2>&1)"

# --- H. network restart drops the WAN queue: set up again on the next pass
run H ':' 'ipt_lag_apply; rm -f "$FAKE_DIR/dev/eth0"; ipt_lag_check'
[ "$(grep -c "tc qdisc add dev eth0 root" "$f/calls.log")" = 2 ] && [ "$(cat "$r/lag.kind")" = netem ] && [ "$(grep -c "ip link add lfnetem0" "$f/calls.log")" = 1 ] \
	&& ok "queue gone after a network restart: put back (no second self-test)" || no "H: $(cat "$f/calls.log")"

# --- I. lag switched off during the trial: a later restart isn't counted against netem
run I ':' 'ipt_lag_apply; [ -f "$LF_NETEM_GUARD" ] && echo guard-during; ZONES_ON=""; ipt_lag_apply; [ -f "$LF_NETEM_GUARD" ] || echo guard-gone; echo "state=$(netem_state)"'
grep -q guard-during "$W/out.I" && grep -q guard-gone "$W/out.I" && grep -q "state=ready" "$W/out.I" && ok "lag off before the trial ended: trial dropped, not a crash later" || no "I: $(cat "$W/out.I")"
run J ':' 'ipt_lag_apply; fw_remove >/dev/null 2>&1; [ -f "$LF_NETEM_GUARD" ] || echo guard-gone'
grep -q guard-gone "$W/out.J" && ok "LobbyFence stopped (e.g. a normal reboot) during the trial: not counted as a crash" || no "J: $(cat "$W/out.J")"
run K 'echo "other-boot 50" > "'"$W"'/home/.netem-loading"' 'ZONES_ON=""; ipt_lag_apply; fw_remove >/dev/null 2>&1; [ -f "$LF_NETEM_GUARD" ] && echo kept'
grep -q kept "$W/out.K" && ok "a restart during an earlier trial stays recorded" || no "K: $(cat "$W/out.K")"

# --- L. dual-WAN failover: the upload queue follows the internet connection
run L ':' 'ipt_lag_apply; ipt_lag_check; echo usb0 > "$FAKE_DIR/wan"; ipt_lag_check; cat "$LF_RUN/lag.devs"'
[ ! -f "$f/dev/eth0" ] && grep -q "netem 82: netem limit 10000 delay 80ms" "$f/dev/usb0" 2>/dev/null && grep -q usb0 "$W/out.L" \
	&& [ "$(grep -c "tc qdisc add dev eth0 root" "$f/calls.log")" = 1 ] && ok "WAN moved to another device: upload queue moved with it (not rebuilt while unchanged)" || no "L: $(cat "$W/out.L") $(ls "$f/dev")"

[ "$F" = 0 ] && echo "ALL MERLIN NETEM UNIT TESTS PASSED" || exit 1
