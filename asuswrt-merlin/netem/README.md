# netem modules for Asuswrt-Merlin

ASUS's firmware doesn't include netem, the Linux kernel's network emulator.
LobbyFence carries the module for the models listed here, built from the
firmware's own kernel source. On any other model the lag simulator uses
LobbyFence's own helper (lf-lagd) instead, which works on every model.

| folder | model | kernel | firmware it was checked against |
| --- | --- | --- | --- |
| `gt-axe16000-4.19.183/` | ASUS GT-AXE16000 | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 and 3004.388.12 |
| `gt-ax6000-4.19.183/` | ASUS GT-AX6000 | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 |
| `gt-ax11000_pro-4.19.183/` | ASUS GT-AX11000 Pro | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 |
| `rt-ax86u_pro-4.19.183/` | ASUS RT-AX86U Pro | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 |
| `rt-ax88u_pro-4.19.183/` | ASUS RT-AX88U Pro | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 |
| `xt12-4.19.183/` | ASUS ZenWiFi Pro XT12 | 4.19.183 (Broadcom HND 5.04, BCM4912) | Asuswrt-Merlin 3006.102.9 |

These are all the models Merlin builds on Broadcom's HND 5.04 SDK with the
BCM4912 profile (94912GW). Each was built with its own kernel configuration
and model define; the six modules came out byte-for-byte identical (the
per-model differences - for example Bluetooth on the XT12 or conntrack
netlink - don't reach netem).

A module is used only when the router's model (`nvram get productid`, or
`odmpid`, the name some models are sold under) and kernel version
(`uname -r`) match its folder name. The kernel checks the module's version
string itself when it is loaded.

Not included yet: the models on Merlin's 3004.388 branch with kernel 4.1
(RT-AX86U, RT-AX86S, RT-AX88U, RT-AX68U, RT-AX58U, RT-AX56U, GT-AX11000,
GT-AXE11000, RT-AC68U V4) and the Wi-Fi 7 models (HND 5.04 BE SDK). They use
lf-lagd.

## Safety steps on the router

1. **The kernel checks the module.** If its version string doesn't match
   the running kernel, the kernel refuses it. Nothing changes and lf-lagd
   is used.
2. **Self-test, once per boot.** LobbyFence creates a private dummy
   interface (198.18.254.1/30, not reachable from anywhere) and puts its
   queue with a netem band on it. It sends three pings through it. netem
   must deliver them (its timers and queue work) before it touches real
   traffic. The interface is removed again afterwards.
3. **A guard on every boot it is used.** This works the same way as on
   FreshTomato. A guard file (`/jffs/addons/lobbyfence/.netem-loading`)
   exists from loading the module until the lag queues are taken down
   cleanly (lag switched off, LobbyFence stopped, a proper shutdown). If the
   router restarts while it is there, LobbyFence never tries netem again by
   itself and uses lf-lagd - also when netem worked before, so a firmware
   update with the same kernel version but a changed kernel can't make the
   module crash the router on every boot. After the queues have carried game
   packets for 2 minutes, `.netem-ok` records that netem works with this
   firmware and module (for the page).
4. **Fallback.** In any of these cases LobbyFence uses lf-lagd, so the
   lag simulator keeps working:
   - QoS or the bandwidth limiter is using the connection
   - the firewall can't set the queue band
   - anything else fails

## How the modules were built

Every model was built the same way as the GT-AXE16000 (below), only with its
own `BUILD_NAME`: Merlin's KernelConfig rules for that model, `make
olddefconfig`, `CONFIG_NET_SCH_NETEM=m`, then `make net/sched/sch_netem.ko`.
Each folder's `kernel-config.gz` is that model's resulting configuration.
Rebuilding the GT-AXE16000 module this way gave the shipped file back byte
for byte.

### The gt-axe16000 module

The module was built from source with the firmware's own build inputs:

- **Source:** RMerl/asuswrt-merlin.ng at tag 3006.102.9
  (b1d6f916a50b9e76adb4c40c92f851b883e593d4), directory
  `release/src-rt-5.04axhnd.675x`, with kernel `kernel/linux-4.19`
  (Linux 4.19.183 plus Broadcom's changes).
- **Toolchain:** ASUS's crosstools-aarch64-gcc-9.2-linux-4.19-glibc-2.30-binutils-2.32
  (from RMerl/am-toolchains, brcm-arm-hnd). This is the compiler the
  firmware is built with.
- **Kernel configuration:**
  1. Start from `config_base.6a.4912`.
  2. Apply Merlin's own KernelConfig rules for the GT-AXE16000 (profile
     94912GW, BUILD_NAME=GT-AXE16000).
  3. Run `make olddefconfig`.
  4. Change only `CONFIG_NET_SCH_NETEM=m`.

  The result is in `kernel-config.gz`.
- **Build:** in-tree, with `make net/sched/sch_netem.ko`. That gives the
  same compiler flags as the firmware's kernel, including `-DGTAXE16000`
  and Broadcom's include paths.
- **Version string:** `4.19.183 SMP preempt mod_unload aarch64`.
  MODVERSIONS is off in this kernel.

## How it was checked

With MODVERSIONS off, the kernel only compares the version string when
loading a module. So I also checked that the module sees the kernel's data
structures exactly as the firmware's kernel lays them out.

ASUS ships three precompiled Broadcom drivers for this model with debug
information in the same tree (`router-sysdep.gt-axe16000/hnd_extra/prebuilt/`:
`bcm_mpm.o`, `otp.o`, `chipinfo.o`). Those were compiled by ASUS against
the real firmware kernel.

`dwarf_layouts.py` reads the layout of every structure from debug
information: its size, plus the offset, bit position and size of every
member, with anonymous unions and structs expanded.

The comparison was between:

- ASUS's objects
- netem and a probe file built here with the same flags plus `-g`

Results:

- **874 structure definitions compared, 874 identical, 0 different.** The
  list includes the ones netem works with:
  - `sk_buff`: 512 bytes, with Broadcom's added fields
  - `net_device`: 2112 bytes
  - `netdev_queue`: 320 bytes
  - `module`: 640 bytes
  - `hrtimer`, `timer_list`, `task_struct`, `sk_buff_head`, `nlattr`, `net`, `device`, `page`, `file_operations`
- **Structures netem itself uses:** 444 of its 539 also appear in ASUS's
  objects, and all 444 match.
- **`Qdisc` and `sock`:** not in ASUS's objects. They are plain Linux
  4.19 structures whose layout depends only on the kernel configuration.
  The configuration-dependent fields around them match (e.g. `netdev_queue`
  with BQL, `net_device` with the traffic-control fields).
- **Firmware versions:** between Merlin 3004.388.12 and 3006.102.9, the
  kernel's headers differ only in two CPU-ID constants in `asm/cputype.h`,
  which don't affect layout. ASUS's prebuilt objects themselves come from
  an earlier 388 build.

To repeat the check (with the toolchain's readelf):

    python3 dwarf_layouts.py aarch64-buildroot-linux-gnu-readelf bcm_mpm.o otp.o chipinfo.o > asus.txt
    python3 dwarf_layouts.py aarch64-buildroot-linux-gnu-readelf probe.o sch_netem-debug.o > here.txt
    # every structure in both files must have an identical line

The module needs only these symbols, all of which the firmware's kernel exports:

- `register_qdisc`, `qdisc_watchdog_*`
- `nla_*`, `skb_*`, `rb_*`
- the usual allocation and lock helpers

### The other models

The same check was run for each model separately: the kernel tree set up
with that model's configuration, netem and a probe file (which pulls in the
network, scheduler, memory, timer, device and file headers with every type
kept) built with `-g`, and compared with that model's own prebuilt ASUS
objects (`router-sysdep.<model>/hnd_extra/prebuilt/bcm_mpm.o`, `otp.o`,
`chipinfo.o`):

| model | compared | identical | different |
| --- | --- | --- | --- |
| GT-AX6000 | 875 | 875 | 0 |
| GT-AX11000 Pro | 875 | 875 | 0 |
| RT-AX86U Pro | 875 | 875 | 0 |
| RT-AX88U Pro | 875 | 875 | 0 |
| ZenWiFi Pro XT12 | 875 | 875 | 0 |
| GT-AXE16000 (again) | 875 | 875 | 0 |

To make sure the check notices a wrong kernel layout, one run used a
configuration with a single network option switched off
(`CONFIG_NET_SWITCHDEV`): it reported `net_device` as different, as it
should.

`SHA256SUMS` in each folder holds the checksum of the module that ships.
