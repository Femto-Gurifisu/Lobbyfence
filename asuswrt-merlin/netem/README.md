# netem modules for Asuswrt-Merlin

ASUS's firmware doesn't include netem, the Linux kernel's network emulator.
LobbyFence carries the module for the models listed here, built from the
firmware's own kernel source. On any other model the lag simulator uses
LobbyFence's own helper (lf-lagd) instead, which works on every model.

| folder | model | kernel | built from |
| --- | --- | --- | --- |
| `gt-be98_pro-4.19.294/` | ASUS GT-BE98 Pro | 4.19.294 (HND 5.04 BE, BCM6813) | Merlin 3006.102.9 |
| `rt-be96u-4.19.294/` | ASUS RT-BE96U | 4.19.294 (HND 5.04 BE, BCM6813) | Merlin 3006.102.9 |
| `rt-be88u-4.19.294/` | ASUS RT-BE88U, RT-BE7200 | 4.19.294 (HND 5.04 BE, BCM6813) | Merlin 3006.102.9 |
| `rt-be86u-4.19.294/` | ASUS RT-BE86U | 4.19.294 (HND 5.04 BE, BCM6813) | Merlin 3006.102.9 |
| `rt-be92u-4.19.294/` | ASUS RT-BE92U | 4.19.294 (HND 5.04 BE, BCM6765) | Merlin 3006.102.9 |
| `rt-be58_go-4.19.294/` | ASUS RT-BE58 Go | 4.19.294 (HND 5.04 BE, BCM6764, 32-bit) | Merlin 3006.102.9 |
| `gt-axe16000-4.19.183/` | ASUS GT-AXE16000 | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 (same kernel headers in 3004.388.12) |
| `gt-ax6000-4.19.183/` | ASUS GT-AX6000 | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 |
| `gt-ax11000_pro-4.19.183/` | ASUS GT-AX11000 Pro | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 |
| `rt-ax86u_pro-4.19.183/` | ASUS RT-AX86U Pro | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 |
| `rt-ax88u_pro-4.19.183/` | ASUS RT-AX88U Pro | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 |
| `xt12-4.19.183/` | ASUS ZenWiFi Pro XT12 | 4.19.183 (HND 5.04, BCM4912) | Merlin 3006.102.9 |
| `rt-ax86u-4.1.52/` | ASUS RT-AX86U, RT-AX86S | 4.1.52 (HND 5.02L.07p2, profile 962118GW) | Merlin 3004.388.13 |
| `rt-ax68u-4.1.52/` | ASUS RT-AX68U | 4.1.52 (HND 5.02L.07p2, profile 962118GW) | Merlin 3004.388.13 |
| `gt-axe11000-4.1.52/` | ASUS GT-AXE11000 | 4.1.52 (HND 5.02L.07p2, profile 962118GW) | Merlin 3004.388.13 |
| `rt-ax58u-4.1.52/` | ASUS RT-AX58U, RT-AX3000 (V1) | 4.1.52 (HND 5.02 675x, profile 96750GW, 32-bit) | Merlin 3004.388.13 |
| `rt-ax88u-4.1.51/` | ASUS RT-AX88U | 4.1.51 (HND 5.02, profile 94908HND) | Merlin 3004.388.13 |
| `gt-ax11000-4.1.51/` | ASUS GT-AX11000 | 4.1.51 (HND 5.02, profile 94908HND) | Merlin 3004.388.13 |

These are all the models Merlin 3004.388.13 and 3006.102.9 build firmware
for, except the GT-BE19000AI (not in Merlin's published source yet). Each
was built with its own kernel configuration and model define. Models that
share a kernel tree and processor came out byte-for-byte identical (the
per-model differences - for example Bluetooth on the XT12 or conntrack
netlink - don't reach netem): one module for the five 64-bit Wi-Fi 7 models,
one for the six 4.19.183 models, one for the RT-AX86U / RT-AX68U /
GT-AXE11000, one for the RT-AX88U / GT-AX11000. The RT-BE58 Go and RT-AX58U
have 32-bit processors and a module of their own each.

A module is used only when the router's model (`nvram get productid`, or
`odmpid`, the name some models are sold under) and kernel version
(`uname -r`) match its folder name, and the router's kernel is configured
like the one the module was built for (step 1 below). The installer copies
only the module and options list for the router it runs on.

Each folder holds:

- `sch_netem.ko` - the module, and `SHA256SUMS` with its checksum
- `kernel-config.gz` - the kernel configuration it was built with
- `kernel-options.gz` - that configuration's options, each marked as one
  that can reach netem's compilation (`R`, with its value) or one that
  can't (`K`); this is what the router compares

Any other model uses lf-lagd.

## Safety steps on the router

1. **The kernel must be configured like the module's.** Before the module
   is loaded, LobbyFence compares the running kernel's own configuration
   (`/proc/config.gz`) with `kernel-options.gz` next to the module:
   - every option that can reach netem's compilation (marked `R`: 340 to
     490 per model) must have the value the module was built with - on,
     off, built in or a module, and every number;
   - the router must not have an option on that the list doesn't have at
     all: that kernel comes from other source;
   - the other options the module's kernel has (marked `K`: drivers, file
     systems, ciphers and so on) may differ.

   If the check fails, or the kernel doesn't show its configuration, the
   module is never loaded and lf-lagd is used; `lobbyfence diag` lists the
   options that differ. See "Which options are compared" below for where
   the two kinds come from and how that was tested.
2. **The kernel checks the module.** If its version string doesn't match
   the running kernel, the kernel refuses it. Nothing changes and lf-lagd
   is used.
3. **Self-test, once per boot.** LobbyFence creates a private test
   interface (198.18.254.1/30, not reachable from anywhere; a dummy
   interface, or an ifb interface on the kernel 4.1 models, whose firmware
   has no dummy driver) and puts its
   queue with a netem band on it. It sends three pings through it. netem
   must deliver them (its timers and queue work) before it touches real
   traffic. The interface is removed again afterwards.
4. **A guard on every boot it is used.** This works the same way as on
   FreshTomato. A guard file (`/jffs/addons/lobbyfence/.netem-loading`)
   exists from loading the module until the lag queues are taken down
   cleanly (lag switched off, LobbyFence stopped, a proper shutdown). If the
   router restarts while it is there, LobbyFence never tries netem again by
   itself and uses lf-lagd - also when netem worked before, so a firmware
   update with the same kernel version but a changed kernel can't make the
   module crash the router on every boot. After the queues have carried game
   packets for 2 minutes, `.netem-ok` records that netem works with this
   firmware and module (for the page).
5. **Fallback.** In any of these cases LobbyFence uses lf-lagd, so the
   lag simulator keeps working:
   - QoS or the bandwidth limiter is using the connection
   - the firewall can't set the queue band
   - anything else fails

## How the modules were built

Every model was built the same way as the GT-AXE16000 (below), only with its
own `BUILD_NAME`: Merlin's KernelConfig rules for that model, `make
olddefconfig`, `CONFIG_NET_SCH_NETEM=m`, then `make net/sched/sch_netem.ko`.
Each folder's `kernel-config.gz` is that model's resulting configuration,
and `kernel-options.gz` the list `kernel_options.py` made from it and from
the build's records (see "Which options are compared").
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
`chipinfo.o`), for the six kernel 4.19.183 models:

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

### The kernel 4.1 and Wi-Fi 7 models

Built the same way from Merlin 3004.388.13 (kernel 4.1, ASUS's gcc 5.5
toolchains) and 3006.102.9 (Wi-Fi 7, ASUS's gcc 10.3 toolchains): each
model's `config_base` file, Merlin's KernelConfig rules for that model,
`make olddefconfig`, `CONFIG_NET_SCH_NETEM=m`, `make net/sched/sch_netem.ko`
in the firmware's kernel tree. Version strings: `4.1.51` / `4.1.52` /
`4.19.294`, each with `SMP preempt mod_unload aarch64` (or `ARMv7 p2v8` on
the two 32-bit models).

The layout check, per model, against that model's own precompiled ASUS
objects that carry debug information (type names reduced to the type they
stand for, so only layout counts):

| model | ASUS objects | structure definitions compared | identical | different |
| --- | --- | --- | --- | --- |
| RT-AX88U | 18 (`router-sysdep.rt-ax88u/hnd_extra/prebuilt/`) | 4024 | 3984 | 40 |
| GT-AX11000 | 18 | 4024 | 3984 | 40 |
| RT-AX86U | 20 | 4456 | 4415 | 41 |
| RT-AX68U | 20 | 4456 | 4415 | 41 |
| GT-AXE11000 | 20 | 4456 | 4415 | 41 |
| GT-BE98 Pro | 1 (`bcmdrivers/broadcom/net/gdx/impl1/prebuilt/gdx_hw.o`) | 477 | 477 | 0 |
| RT-BE96U, RT-BE88U, RT-BE86U | the same object | 477 | 477 | 0 |
| RT-BE92U | the same object | 477 | 475 | 2 |

What the differences are:

- **Kernel 4.1 models:** `cred` and `user_struct` differ in every ASUS
  object: ASUS compiled those drivers without the kernel's key store
  (`CONFIG_KEYS`), which the firmware's kernel configuration
  (`config_base.6a`) has on. netem uses neither. The rest (4 structures on
  the RT-AX88U / GT-AX11000, `sk_buff` alone on the others) are in one
  object only, `nciTMSkmod.o` - Trend Micro's module, compiled elsewhere
  against another configuration. In every Broadcom object that has them,
  `sk_buff` (512 bytes), `net_device` (1856), `netdev_queue` (384), `sock`,
  `net`, `module`, `hrtimer`, `timer_list`, `sk_buff_head` and `nlattr` are
  identical to the build here. `Qdisc` and `Qdisc_ops` aren't in ASUS's
  objects; in this kernel they have no configuration-dependent members.
- **Wi-Fi 7 models:** ASUS's `gdx_hw.o` was compiled for the BCM6813 and
  includes `Qdisc` (320 bytes), `Qdisc_ops`, `sk_buff` (576), `net_device`
  (2112), `netdev_queue` and `sock`: all identical, as are all 452 of
  netem's own structures that appear in it. On the RT-BE92U (BCM6765, a
  different kernel configuration from the object's) `net` and `proto` differ
  from it, as expected; the structures netem works with are identical there
  too.
- **RT-AX58U and RT-BE58 Go:** ASUS ships no object with debug information
  for these two 32-bit models, so there is nothing to compare against. Their
  modules come from the same procedure that passes the comparison on every
  other model, and on the router they depend on the kernel configuration
  check like all the others.

On the kernel 4.1 models every symbol the module needs is exported by the
firmware's kernel as well (checked against the kernel source).

## Which options are compared

A kernel built from the same source with the same compiler lays out its
structures the same way when its configuration is the same. But not every
option matters to netem: whether a USB driver or a cipher is built can't
change anything netem is compiled from. The kernel's build system keeps
exactly this record. For every object it compiles, `scripts/basic/fixdep`
writes down each `CONFIG_` option that is named in the source file or in any
header it includes (in the object's `.cmd` file), and the object is rebuilt
when one of those changes and only then.

`kernel_options.py` takes that record for netem (`.sch_netem.o.cmd` and
`.sch_netem.mod.o.cmd`) and adds:

- the options named in the makefiles that set the compiler's flags: the
  kernel's top `Makefile`, `arch/<arch>/Makefile`, `scripts/Makefile.*` and
  Broadcom's `bcmkernel/Makefile*` in full, and the flag and condition
  lines of the makefiles in netem's folder and above (`net/sched`, `net`) -
  their other lines only say which objects get built,
- the options behind the two generated headers (`bounds.h`,
  `asm-offsets.h`),
- the options that say which compiler built the kernel.

Every option of the model's configuration that is in this set is marked `R`
in `kernel-options.gz` with its value (`n` when off); the rest are marked
`K`. Names and paths (the string options) are always `K`. On the
GT-AXE16000 that gives 438 `R` and 2,710 `K`.

The router then accepts a kernel only when every `R` option matches and no
option outside the list is on (the rule in step 1 above).

### How the list was tested

**Other Merlin releases.** For 23 model / release pairs, the kernel
configuration that release gives the model was rebuilt from the release's
own source (its build rules, `config_base`, Kconfig files and profile), the
check was run on it, and netem was built with it:

| model | releases | options that differ from the shipped module's | check | module |
| --- | --- | --- | --- | --- |
| RT-AX88U, RT-AX68U | 3004.388.5, 388.8_4 | none | passes | (same configuration) |
| RT-AX88U, GT-AX11000, RT-AX86U, RT-AX68U, GT-AXE11000, RT-AX58U | 3004.388.4 | 1 (`NETFILTER_XT_TARGET_TEE`, a firewall module later releases add) | passes | identical |
| GT-AXE16000 | 3004.388.4, 388.7, 388.13 | 39 to 42 (ipset and `xt_set` as modules, MD4, PPP) | passes | identical |
| GT-AX6000, ZenWiFi Pro XT12 | 3004.388.13 | 41, 48 | passes | identical |
| GT-AXE16000 | 3006.102.3 | 3 (PPP) | passes | identical |
| GT-AXE16000 | 3006.102.5-wifi6 | none | passes | (same configuration) |
| GT-BE98 Pro | 3006.102.3, 102.5, 102.7_2 | 1 (`USB_NET_CDC_NCM`), 1, none on (two more listed as off) | passes | identical |
| RT-BE92U | 3006.102.5, 102.7_2 | 1, none on | passes | identical |
| RT-BE58 Go | 3006.102.7_2 | none on | passes | identical |

"Identical" means byte for byte the module that ships. So wherever the
check let a different configuration through, the module would have come out
the same.

**Switched options.** In ten further builds (six models), 15 or 30 random
`K` options were switched off in the configuration before building; Kconfig
then switches what depends on them as well, 16 to 95 options in all.

- In four of them the check still passed (RT-AX88U twice, RT-AX58U,
  RT-BE58 Go; 23 to 34 options different): the module came out identical.
- In the other six the check refused the configuration, because the
  switch had also turned off an `R` option or turned on one the list doesn't
  have. In one of those the module did come out different: GT-AXE16000 with
  `ACCEL_PPTP` off - an option named in Broadcom's `blog.h`, which netem
  includes. Switching off that option alone gave the same result.

So in all 22 cases where the check let a different configuration through
(18 from other releases, 4 with switched options), the module was the same,
and it refused the configuration that changed it.

**The kernel source across releases.** The headers netem is compiled from
are the same in these Merlin releases as in the one the module was built
from (compared file by file in Merlin's repository):

- kernel 4.1 models: 3004.388.4 to 388.13 - no difference at all from
  388.6 on; 388.4 and 388.5 differ in `usb/cdc.h`, which netem doesn't
  include
- kernel 4.19.183 models: 3004.388.4 to 388.13 and 3006.102.1 to 102.9 -
  only two CPU-ID constants in `asm/cputype.h`. (The separate
  3006.102.5-wifi6 release also has one more flag bit and three macros in
  `bcm_netdevice.h` and another netlink number - no structure differs.)
- Wi-Fi 7 models: 3006.102.3 to 102.9 - two CPU-ID constants in
  `asm/cputype.h`; five Broadcom headers and `linux/spi/spi.h` differ too,
  but netem includes none of them. (3006.102.1 and 102.2 have kernel
  4.19.275: no module, lf-lagd.)

A later release that changes one of these headers without changing an
option would not be noticed by the configuration check; the self-test and
the guard (steps 3 and 4) are there for that.

`SHA256SUMS` in each folder holds the checksum of the module that ships.
