#!/bin/sh
# Builds sch_netem.ko (the kernel's network emulator, GPL-2.0) for FreshTomato
# ARM routers: FreshTomato's kernel has netem switched off, so LobbyFence's lag
# simulator brings the module. It is built from FreshTomato's own kernel source
# and toolchain, with the kernel configuration of the R7000 / RT-AC68U class
# builds, and carries the kernel's symbol versions (CONFIG_MODVERSIONS): a
# kernel that differs refuses to load it instead of running it.
#
#   usage: build-netem.sh <workdir> [release tag, default 2026.4]
# Needs git, make, gcc (for the kernel's host tools) and ~1 GB of disk.
set -e
W="$1"; TAG="${2:-2026.4}"
[ -n "$W" ] || { echo "usage: $0 <workdir> [tag]"; exit 1; }
mkdir -p "$W"; cd "$W"
[ -d ft ] || git clone -q --depth 1 --branch "$TAG" --filter=blob:none --sparse \
	https://github.com/FreshTomato-Project/freshtomato-arm.git ft
cd ft
git sparse-checkout set --no-cone '/release/src-rt-6.x.4708/linux/linux-2.6.36/' \
	'/release/src-rt-6.x.4708/toolchains/hndtools-arm-uclibc-7.5/' '/release/src-rt-6.x.4708/include/' \
	'/release/src-rt-6.x.4708/common/include/' '/release/src-rt-6.x.4708/ctf/' '/release/src-rt-6.x.4708/Makefile'
T="$PWD/release/src-rt-6.x.4708"; K="$T/linux/linux-2.6.36"
export PATH="$T/toolchains/hndtools-arm-uclibc-7.5/usr/bin:$PATH" SRCBASE="$T"
M="make ARCH=arm CROSS_COMPILE=arm-brcm-linux-uclibcgnueabi-"

# the kernel configuration as FreshTomato's "KernelConfig" step makes it for
# the R7000 builds (r7000e / r7000z), plus netem as a module
python3 - "$T" <<'PY'
import re, subprocess, sys
T = sys.argv[1]
mk = open(T + '/Makefile').read()
body = mk[mk.index('define KernelConfig'):]
body = body[body.index('\n') + 1: body.index('\nendef')].replace('$(call extrawlConfig, $(1))', '').strip()[1:]
vals = dict(NVRAM_SIZE='0', KERN_SIZE_OPT='n', NAND='y', USB='USB', HFS='y', IPV6SUPP='y', DPSTA='y',
            EBTABLES='y', NVRAM_64K='y', WIREGUARD='y')
cfg = T + '/linux/linux-2.6.36/.config'
open(cfg, 'w').write(open(T + '/linux/linux-2.6.36/config_base').read())
sh = re.sub(r'\$\(([A-Za-z0-9_]+)\)', lambda m: cfg if m.group(1) == '1' else vals.get(m.group(1), ''), body).replace('$$', '$')
subprocess.run(['bash', '-c', sh], check=True)
PY
cd "$K"
sed -i 's/^# CONFIG_NET_SCH_NETEM is not set/CONFIG_NET_SCH_NETEM=m/' .config
yes "" | $M oldconfig >/dev/null
$M modules_prepare >/dev/null

# the symbol versions of everything netem uses, from the kernel's own objects
$M net/sched/sch_netem.o >/dev/null
OBJS="kernel/module.o arch/arm/kernel/armksyms.o arch/arm/kernel/unwind.o arch/arm/kernel/traps.o mm/slub.o
	kernel/spinlock.o kernel/time/timekeeping.o lib/nlattr.o kernel/printk.o net/sched/sch_api.o
	net/sched/sch_generic.o net/sched/sch_fifo.o lib/random32.o net/core/rtnetlink.o net/core/dev.o net/core/skbuff.o"
for o in $OBJS; do $M "$o" >/dev/null; done
for o in $OBJS; do arm-brcm-linux-uclibcgnueabi-nm "$o"; done | \
	awk '$2 == "A" && $3 ~ /^__crc_/ { printf "0x%s\t%s\tvmlinux\tEXPORT_SYMBOL\n", substr($1, length($1) - 7), substr($3, 7) }' | \
	sort -u -k2,2 > "$W/Module.symvers"
for s in $(arm-brcm-linux-uclibcgnueabi-nm -u net/sched/sch_netem.o | awk '{ print $2 }' | grep -v '^__this_module$'); do
	grep -q "	$s	" "$W/Module.symvers" || { echo "no symbol version for $s"; exit 1; }
done

rm -rf "$W/netem"; mkdir -p "$W/netem"
cp net/sched/sch_netem.c "$W/netem/"; echo 'obj-m := sch_netem.o' > "$W/netem/Makefile"
$M M="$W/netem" KBUILD_EXTRA_SYMBOLS="$W/Module.symvers" modules >/dev/null
arm-brcm-linux-uclibcgnueabi-strip --strip-debug "$W/netem/sch_netem.ko"
echo "built $W/netem/sch_netem.ko for $(strings "$W/netem/sch_netem.ko" | sed -n 's/^vermagic=//p')"
