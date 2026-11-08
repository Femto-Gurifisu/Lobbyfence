#!/bin/sh
# Lag simulator bookkeeping of the FreshTomato backend, without a router:
# zones past the 12th get a "toomany" note and no mark; errors reach every zone.
#   usage: tomato_lag_unit.sh <workdir> [shell]
W="$1"; SH="${2:-sh}"
HERE="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$W"
cat > "$W/lagunit.sh" <<EOT
LF_RUN="$W/run"; mkdir -p "\$LF_RUN"; rm -f "\$LF_RUN"/*
have() { [ "\$1" != "nope-tc" ] && type "\$1" >/dev/null 2>&1; }
log() { :; }
LF_TC=nope-tc LF_PROC_MODULES=/dev/null LF_NETEM_KO=/nonexistent
. "$HERE/../files/usr/share/lobbyfence/fw-ipt.sh"
LAG_SUPPORTED=1
zone_load() { Z_LAG=1; Z_LAG_DIR=both; }
ZONES_ON="z1 z2 z3 z4 z5 z6 z7 z8 z9 z10 z11 z12 z13 z14"
ipt_lag_apply
for z in z1 z12 z13 z14; do printf '%s=%s ' \$z "\$(cat "\$LF_RUN/lag.\$z.err")"; done
printf 'm12=%s m13=[%s]\n' "\$(ipt_lag_mark z12)" "\$(ipt_lag_mark z13)"
EOT
out="$($SH "$W/lagunit.sh")"
if [ "$out" = "z1=notc z12=notc z13=toomany z14=toomany m12=0x0c000000 m13=[]" ]; then
	echo "PASS: lag: 12 zones at most, the rest told why and not marked"
else
	echo "FAIL: lag limit: $out"; exit 1
fi
# lag switched off during netem's trial: this boot's guard goes (a later
# restart isn't netem's doing); an earlier boot's guard (a crash) stays
echo boot-a > "$W/boot_id"
cat > "$W/trial.sh" <<EOT
LF_RUN="$W/run"; mkdir -p "\$LF_RUN"
have() { type "\$1" >/dev/null 2>&1; }
log() { :; }
LF_TC=nope-tc LF_PROC_MODULES=/dev/null LF_NETEM_KO=/nonexistent LF_BOOT_ID="$W/boot_id"
LF_NETEM_GUARD="$W/guard" LF_NETEM_OK="$W/ok"
. "$HERE/../files/usr/share/lobbyfence/fw-ipt.sh"
LAG_SUPPORTED=1; ZONES_ON=""
echo "boot-a 10" > "$W/guard"; ipt_lag_apply; [ -f "$W/guard" ] && echo kept1 || echo gone1
echo "boot-0 10" > "$W/guard"; ipt_lag_apply; [ -f "$W/guard" ] && echo kept2 || echo gone2
EOT
out="$($SH "$W/trial.sh" | tr '\n' ' ')"
if [ "$out" = "gone1 kept2 " ]; then
	echo "PASS: lag off during the trial: this boot's trial dropped, an earlier crash still remembered"
else
	echo "FAIL: trial stop: $out"; exit 1
fi
# every boot that uses netem is guarded - also after the trial passed: a router
# that restarts while netem is in use never loads it again by itself (a new
# firmware with the same kernel version could crash it on every boot)
echo boot-a > "$W/boot_id"; rm -f "$W/guard" "$W/ok"; printf 'module-v1' > "$W/fake.ko"
cat > "$W/guard.sh" <<EOT
LF_RUN="$W/run"; mkdir -p "\$LF_RUN"
have() { type "\$1" >/dev/null 2>&1; }
is_uint() { case "\$1" in ''|*[!0-9]*) return 1;; esac; return 0; }
log() { :; }
LF_TC=nope-tc LF_PROC_MODULES=/dev/null LF_NETEM_KO="$W/fake.ko" LF_BOOT_ID="$W/boot_id"
LF_NETEM_GUARD="$W/guard" LF_NETEM_OK="$W/ok" LF_NETEM_TRIAL=0
. "$HERE/../files/usr/share/lobbyfence/fw-ipt.sh"
case "\$1" in
	use) netem_trial && echo used || echo refused;;
	stop) netem_trial_stop; [ -f "$W/guard" ] && echo guard || echo noguard;;
	ok) netem_ok && echo ok || echo notok;;
	check) echo br0 > "\$LF_RUN/lag.devs"; netem_trial_check; netem_ok && echo ok || echo notok;;
esac
EOT
r1="$($SH "$W/guard.sh" use)"                 # boot a: first use, guard written
r2="$($SH "$W/guard.sh" check)"               # no packets through netem yet: not "works"
# pretend it carried traffic: .netem-ok for this kernel build and module
( LF_NETEM_KO="$W/fake.ko"; echo "$(uname -r) $(uname -v | tr -c 'A-Za-z0-9.:+\n' '_') $(cksum < "$W/fake.ko" | awk '{ print $1 }')" ) > "$W/ok"
r3="$($SH "$W/guard.sh" ok)"
r4="$($SH "$W/guard.sh" stop)"                # clean stop: this boot's guard goes
echo boot-b > "$W/boot_id"
r5="$($SH "$W/guard.sh" use)"                 # boot b (netem works): guarded again
echo boot-c > "$W/boot_id"                    # ...the router restarted while netem was in use
r6="$($SH "$W/guard.sh" use)"
printf 'module-v2' > "$W/fake.ko"; r7="$($SH "$W/guard.sh" ok)"
if [ "$r1 $r2 $r3 $r4 $r5 $r6 $r7" = "used notok ok noguard used refused notok" ]; then
	echo "PASS: netem guarded on every boot it is used; a restart while in use (even after the trial) stops it for good; 'works' only after packets went through, and only for that firmware and module"
else
	echo "FAIL: netem guard: $r1 $r2 $r3 $r4 $r5 $r6 $r7"; exit 1
fi
rm -f "$W/guard" "$W/ok"

# multi-WAN failover: the upload queue follows the internet connection
rm -rf "$W/tc" "$W/wan" "$W/guard"; mkdir -p "$W/fbin"
printf '#!/bin/sh\ncase "$3" in 192.168.*) echo "$3 dev br0";; *) echo "$3 via 1.2.3.4 dev $(cat %s/wan 2>/dev/null || echo vlan2)";; esac\n' "$W" > "$W/fbin/ip"
chmod 755 "$W/fbin/ip"; echo "sch_netem 1 0 - Live" > "$W/mods"
cat > "$W/wan.sh" <<EOT
LF_RUN="$W/run"; mkdir -p "\$LF_RUN"; rm -f "\$LF_RUN"/*
have() { type "\$1" >/dev/null 2>&1; }
log() { :; }
LF_TC="$HERE/fake_tomato_tc.sh" FAKE_TC_DIR="$W/tc" LF_IP="$W/fbin/ip" LF_PROC_MODULES="$W/mods" LF_NETEM_KO=/nonexistent
LF_BOOT_ID="$W/boot_id" LF_NETEM_GUARD="$W/guard" LF_NETEM_OK="$W/ok"; export FAKE_TC_DIR
. "$HERE/../files/usr/share/lobbyfence/fw-ipt.sh"
LAG_SUPPORTED=1; ZONES_ON="game"
zone_load() { Z_LAG=1; Z_LAG_DIR=both; Z_LAG_DELAY=50; Z_LAG_JITTER=0; Z_LAG_LOSS=0; }
echo 192.168.1.100 > "\$LF_RUN/game.dev"
ipt_lag_apply; ipt_lag_check; echo ppp1 > "$W/wan"; ipt_lag_check; tr '\n' ' ' < "\$LF_RUN/lag.devs"
EOT
out="$($SH "$W/wan.sh")"
if [ "$out" = "br0 ppp1 " ] && [ ! -f "$W/tc/dev/vlan2" ] && [ -f "$W/tc/dev/ppp1" ]; then
	echo "PASS: internet moved to another device: the upload queue moved with it"; echo "ALL LAG UNIT TESTS PASSED"
else
	echo "FAIL: wan move: $out / $(ls "$W/tc/dev")"; exit 1
fi
