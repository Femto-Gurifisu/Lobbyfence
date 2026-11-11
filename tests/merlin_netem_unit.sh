#!/bin/sh
# The Merlin lag simulator's choice between netem and lf-lagd, with the
# GT-AXE16000's tools stood in by tests/fake_merlin_netem.sh (the test kernel
# has no netem / prio / dummy): self-test on a private dummy interface, the
# queues and CLASSIFY targets it sets up, the two-minute trial, and every way
# of falling back to lf-lagd (QoS on, self-test failing, the kernel refusing
# the module, a kernel configured differently from the module's, a restart
# during an earlier trial, another model).
#   usage: merlin_netem_unit.sh <workdir> [shell]
W="$1"; SH="${2:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$HERE/.."
rm -rf "$W"; mkdir -p "$W/bin" "$W/home/netem/gt-axe16000-4.19.183"
for t in tc ip ping insmod iptables ip6tables iptables-restore ip6tables-restore uname; do
	ln -s "$HERE/fake_merlin_netem.sh" "$W/bin/$t"
done
for d in "$REPO"/asuswrt-merlin/netem/*-[0-9]*; do
	mkdir -p "$W/home/netem/${d##*/}"; cp "$d/sch_netem.ko" "$d/kernel-options.gz" "$W/home/netem/${d##*/}/"
done
# the router's own /proc/config.gz: the module's configuration without netem
# (as the firmware has it), or changed by the sed expression given
proc_config() { # folder [sed expression]
	gunzip -c "$REPO/asuswrt-merlin/netem/$1/kernel-config.gz" | sed -e 's/^CONFIG_NET_SCH_NETEM=m$/# CONFIG_NET_SCH_NETEM is not set/' ${2:+-e "$2"} | gzip -c > "$W/fake/config.gz"
}
# lf-lagd stand-in: says it runs (like the real one) and waits
printf '#!/bin/sh\necho "lf-lagd: queue $2, delay" >&2\nexec sleep 60\n' > "$W/home/lf-lagd"; chmod 755 "$W/home/lf-lagd"
echo 0123-boot-id > "$W/boot_id"

# one scenario: fresh state, then the commands in $2 (after the backend is loaded)
run() { # name 'setup shell' 'commands' [model]
	rm -rf "$W/fake" "$W/run"; mkdir -p "$W/fake" "$W/run"
	rm -f "$W/home/.netem-ok" "$W/home/.netem-loading"
	printf 'LF_game_q\nLF_z2_q\n' > "$W/fake/chains"
	proc_config gt-axe16000-4.19.183
	(cd "$W/fake" && eval "$2")
	cat > "$W/s.sh" <<EOT
PATH="$W/bin:\$PATH"; FAKE_DIR="$W/fake"; export FAKE_DIR
LF_RUN="$W/run"; LF_HOME="$W/home"; LF_SHARE="$REPO/files/usr/share/lobbyfence"
LF_LAGD="$W/home/lf-lagd"; LF_PROC_MODULES="$W/fake/proc.modules"; LF_PROC_CONFIG="$W/fake/config.gz"; LF_BOOT_ID="$W/boot_id"; LF_IPV6=0
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
n=0
for d in "$REPO"/asuswrt-merlin/netem/*-[0-9]*; do
	d="${d##*/}"; l="${d%-*}"; kv="${d##*-}"; mdl="$(echo "$l" | tr a-z A-Z)"; n=$((n + 1))
	# found for its model and kernel, its configuration is this kernel's, and
	# it is the module the checksum file names
	run M "echo $kv > kver; proc_config $d" 'echo "ko=$(merlin_netem_ko)"; netem_config_ok && echo config-ok' "$mdl"
	D="$REPO/asuswrt-merlin/netem/$d"
	grep -qx "ko=$W/home/netem/$d/sch_netem.ko" "$W/out.M" && grep -qx config-ok "$W/out.M" \
		&& (cd "$D" && sha256sum -c SHA256SUMS >/dev/null 2>&1) \
		&& gunzip -c "$D/kernel-config.gz" | grep -qx "CONFIG_NET_SCH_NETEM=m" \
		&& gunzip -c "$D/kernel-config.gz" | grep -q "^# Linux/arm.* $kv Kernel Configuration" \
		&& strings -a "$D/sch_netem.ko" | grep -q "^vermagic=$kv SMP preempt mod_unload " \
		&& ok "$mdl (kernel $kv): its netem module is found and fits its kernel configuration" || no "$mdl: $(cat "$W/out.M")"
	# the list of options is that configuration's: every option once, the
	# compared ones with its value, and the ones any module depends on among them
	gunzip -c "$D/kernel-options.gz" > "$W/opts"; gunzip -c "$D/kernel-config.gz" > "$W/cfg"
	awk 'NR == FNR { if ($1 == "R") v[$2] = $3; else if ($1 != "K") bad++; if ($2 in k) bad++; k[$2] = 1; n1++; next }
		{ n = "" }
		/^CONFIG_[A-Za-z0-9_]+=/ { i = index($0, "="); n = substr($0, 1, i - 1); val = substr($0, i + 1) }
		/^# CONFIG_[A-Za-z0-9_]+ is not set$/ { n = $2; val = "n" }
		n != "" && n != "CONFIG_NET_SCH_NETEM" { n2++; if (!(n in k)) bad++; else if ((n in v) && v[n] != val) bad++; if ((n in v) && val ~ /^"/) bad++ }
		END { exit !(n1 == n2 && bad == 0 && n1 > 2000) }' "$W/opts" "$W/cfg" \
		&& [ "$(grep -c '^R ' "$W/opts")" -ge 300 ] && grep -qx "R CONFIG_SMP y" "$W/opts" && grep -qx "R CONFIG_PREEMPT y" "$W/opts" \
		&& grep -qx "R CONFIG_MODVERSIONS n" "$W/opts" && grep -q "^R CONFIG_NR_CPUS [0-9]" "$W/opts" && grep -qx "R CONFIG_BLOG y" "$W/opts" \
		&& grep -qx "R CONFIG_NET_SCHED y" "$W/opts" && grep -qx "R CONFIG_BCM_KF_NBUFF y" "$W/opts" && grep -qx "R CONFIG_DEBUG_SPINLOCK n" "$W/opts" \
		&& ! grep -q "NET_SCH_NETEM" "$W/opts" \
		|| no "$mdl: kernel-options.gz doesn't fit kernel-config.gz"
	# the same model on another kernel version: no module
	run M 'echo 4.19.999 > kver' 'echo "ko=$(merlin_netem_ko)"' "$mdl"
	grep -qx "ko=" "$W/out.M" || no "$mdl on another kernel: $(cat "$W/out.M")"
done
[ "$n" = 18 ] && ok "18 models carry a module with its kernel's options, none is used on another kernel version" || no "module folders: $n"
run M ':' 'echo "ko=$(merlin_netem_ko)"' 'ZENWIFI_PRO_XT12' 'XT12'
grep -qx "ko=$W/home/netem/xt12-4.19.183/sch_netem.ko" "$W/out.M" && ok "found by odmpid when productid is another name" || no "odmpid: $(cat "$W/out.M")"
run M ':' 'echo "ko=$(merlin_netem_ko)"' 'RT-AX56U'
grep -qx "ko=" "$W/out.M" && ok "a model without a module: none (lf-lagd)" || no "RT-AX56U: $(cat "$W/out.M")"
run M 'echo 4.1.52 > kver' 'echo "ko=$(merlin_netem_ko)"' 'RT-AX86U' 'RT-AX86S'
grep -qx "ko=$W/home/netem/rt-ax86u-4.1.52/sch_netem.ko" "$W/out.M" && ok "RT-AX86S (sold under another name): the RT-AX86U module" || no "RT-AX86S: $(cat "$W/out.M")"

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

# --- E2. the firmware's kernel differs in options that reach the module: never loaded
run E2 'proc_config gt-axe16000-4.19.183 "s/^CONFIG_NET_SWITCHDEV=y$/# CONFIG_NET_SWITCHDEV is not set/; s/^CONFIG_NR_CPUS=.*/CONFIG_NR_CPUS=8/"' 'ipt_lag_apply; echo "state=$(netem_state)"; fw_diag'
! grep -q "^insmod\|lfnetem0" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemconfig ] && [ "$(cat "$r/lag.kind")" = nfqueue ] && [ ! -f "$W/home/.netem-loading" ] \
	&& grep -q "state=other-kernel-config" "$W/out.E2" && ok "a kernel configured differently where it matters: module never loaded, lf-lagd, no trial" || no "E2: $(cat "$W/out.E2" "$f/calls.log" "$r/log" 2>&1)"
grep -q "netem kernel configuration: differs: 2 options" "$W/out.E2" && grep -q "CONFIG_NET_SWITCHDEV: module y, router off" "$W/out.E2" && grep -q "CONFIG_NR_CPUS: module [0-9]*, router 8" "$W/out.E2" \
	&& grep -q "configured differently .*2 options" "$r/log" && ok "...diag and the log name the options that differ" || no "E2 diag: $(cat "$W/out.E2" "$r/log")"
run E3 'proc_config gt-axe16000-4.19.183 "s/^# CONFIG_DEBUG_SPINLOCK is not set$/CONFIG_DEBUG_SPINLOCK=y/"' 'ipt_lag_apply'
[ "$(cat "$r/lag.why")" = netemconfig ] && grep -q "CONFIG_DEBUG_SPINLOCK: module off, router y" "$r/netem.config" && ok "an option that matters, on only on the router, counts too" || no "E3: $(cat "$r/netem.config" "$r/log" 2>&1)"
run E3b 'proc_config gt-axe16000-4.19.183; { gunzip -c config.gz; echo "CONFIG_BCM_SOME_NEW_FEATURE=y"; } | gzip -c > c2.gz; mv c2.gz config.gz' 'ipt_lag_apply'
! grep -q "^insmod" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemconfig ] && grep -q "CONFIG_BCM_SOME_NEW_FEATURE: router y, not in the kernel the module was built for" "$r/netem.config" \
	&& ok "an option the module's kernel doesn't have at all (other kernel source): not loaded" || no "E3b: $(cat "$r/netem.config" "$r/log" 2>&1)"
# (what Merlin 3004.388 has for this model: MD4 built into the kernel - in the
# 3006.102 kernel the module was built for it is a module; nothing netem is
# compiled from names it)
run E4 'proc_config gt-axe16000-4.19.183 "s/^CONFIG_CRYPTO_MD4=m$/CONFIG_CRYPTO_MD4=y/; s/^CONFIG_DEFAULT_HOSTNAME=.*/CONFIG_DEFAULT_HOSTNAME=\"router\"/; s/^CONFIG_USB_STORAGE=.*/# CONFIG_USB_STORAGE is not set/; s/^# CONFIG_NET_SCH_NETEM is not set/CONFIG_NET_SCH_NETEM=y/"; echo "# comment" | gzip -c >> config.gz' 'ipt_lag_apply'
gunzip -c "$f/config.gz" | grep -qx "CONFIG_CRYPTO_MD4=y" && ! gunzip -c "$f/config.gz" | grep -q "^CONFIG_USB_STORAGE=" \
	&& [ "$(cat "$r/lag.kind")" = netem ] && [ "$(cat "$r/netem.config")" = ok ] && ok "options that can't reach the module (a driver, a cipher, a name) may differ: netem is used" || no "E4: $(cat "$r/netem.config" "$r/log" 2>&1)"
run E5 'rm -f config.gz' 'ipt_lag_apply; echo "state=$(netem_state)"'
! grep -q "^insmod" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemconfig ] && grep -q "^unknown: " "$r/netem.config" && ok "a kernel that doesn't show its configuration: module not loaded" || no "E5: $(cat "$r/netem.config" "$f/calls.log" 2>&1)"
run E6 'rm -f "'"$W"'/home/netem/gt-axe16000-4.19.183/kernel-options.gz"' 'ipt_lag_apply'
! grep -q "^insmod" "$f/calls.log" && [ "$(cat "$r/lag.why")" = netemconfig ] && grep -q "kernel-options.gz is missing" "$r/netem.config" && ok "a module without its list of options: not loaded" || no "E6: $(cat "$f/calls.log")"
cp "$REPO/asuswrt-merlin/netem/gt-axe16000-4.19.183/kernel-options.gz" "$W/home/netem/gt-axe16000-4.19.183/"
# (awk stood in by one that fails: the comparison gives no result)
run E6b 'printf "#!/bin/sh\nexit 1\n" > "'"$W"'/bin/awk"; chmod 755 "'"$W"'/bin/awk"' 'netem_config_ok && echo config-ok; cat "$LF_RUN/netem.config"'
rm -f "$W/bin/awk"
! grep -q config-ok "$W/out.E6b" && grep -q "^unknown: the comparison could not be made" "$W/out.E6b" && ok "the comparison itself failing is not a pass: module not loaded" || no "E6b: $(cat "$W/out.E6b")"
run E7 'rm -f config.gz; echo "sch_netem 24576 0 - Live 0xffffffc000a00000" > proc.modules' 'ipt_lag_apply'
[ "$(cat "$r/lag.kind")" = netem ] && ! grep -q "^insmod" "$f/calls.log" && ok "netem already in the kernel (the firmware's own): used without the check" || no "E7: $(cat "$r/log" 2>&1)"

# --- E8. kernel 4.1 firmware has no dummy driver: the self-test runs on an ifb interface
run E8 'echo 4.1.51 > kver; proc_config rt-ax88u-4.1.51; touch no-dummy' 'ipt_lag_apply' RT-AX88U
grep -q "ip link add lfnetem0 type dummy" "$f/calls.log" && grep -q "ip link add lfnetem0 type ifb" "$f/calls.log" && [ "$(cat "$r/netem.selftest")" = ok ] \
	&& grep -q "insmod $W/home/netem/rt-ax88u-4.1.51/sch_netem.ko" "$f/calls.log" && [ "$(cat "$r/lag.kind")" = netem ] && grep -q "ip link del lfnetem0" "$f/calls.log" \
	&& ok "RT-AX88U (kernel 4.1, no dummy driver): self-test on an ifb interface, then netem" || no "E8: $(cat "$f/calls.log" "$r/log")"
run E9 'touch no-dummy no-ifb' 'ipt_lag_apply'
[ "$(cat "$r/lag.why")" = selftest ] && [ "$(cat "$r/netem.selftest")" = nodummy ] && [ "$(cat "$r/lag.kind")" = nfqueue ] && ! grep -q "dev br0 root" "$f/calls.log" \
	&& ok "no test interface at all: no self-test, so no netem (lf-lagd)" || no "E9: $(cat "$r/log")"

# --- F. another model: no netem, lf-lagd directly
run F ':' 'echo "have=$NETEM_HAVE"; ipt_lag_apply; echo "state=$(netem_state)"' RT-AX56U
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
