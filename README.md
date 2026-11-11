# LobbyFence

A geographic game-server filter for OpenWrt, FreshTomato, Asuswrt-Merlin and DD-WRT. LobbyFence watches which servers a
game on your network talks to, looks up where they are, and — once you switch it
on — blocks connections to servers outside the regions you allow. Regions are
circles and polygons you draw on a map, country codes, or any mix of them.
Zones filter **strictly** by default: only servers located inside your region
(or allowed by you) get through.

https://github.com/user-attachments/assets/8853105d-9a10-4cfd-ab1b-c39192d5d10d

> **Use at your own risk.** LobbyFence runs as root on your router and changes
> its firewall. It is free software with **no warranty**: the author is not
> liable for a bricked or unreachable router, lost connections or anything
> else that happens from using it - see [Disclaimer](#disclaimer) and
> [Safety](#safety) for what it does and doesn't touch.

* Pure shell + awk + nftables: no compiled code, nothing extra to install on a
  stock OpenWrt 23.05 / 24.10 router.
* Lives in its own `inet lobbyfence` table, so firewall reloads don't touch it.
* Opens on a map (MapLibre GL JS with OpenFreeMap tiles): create a zone, draw
  circles, and watch learned servers turn green or red as you drag. A side
  panel lists allowed, blocked and not-yet-located servers, shows whether the
  service is running, and tests the geolocation API on demand.
* Click any server on the map to **always allow** or **always block** it - the
  change takes effect on the router at once, no Save & Apply needed.
* Full-screen map view, optionally without the side panel.
* Click a circle or polygon to select it, press **Delete** to remove it, or
  drag it to move it.
* **Home:** set your location by ZIP / postal code, place name or street
  address - suggestions while you type (Photon by komoot), and Enter runs an
  exact address lookup (OpenStreetMap Nominatim); it shows as a dark-blue location pin on the map and every
  server shows its distance from home. The server list can be filtered by
  country.
* **Whitelist / blacklist** per zone (always allowed / always blocked
  servers): add addresses, download the list as a text file, upload it again
  or share it - changes take effect on the router at once.
* The map shows only the servers in use **right now** by default (your device
  sent to them in the last 15 seconds - dots fade as a server goes quiet); switch to the last hour, last 24 hours or everything
  learned (kept for `expire_days`, 30 by default), or clear the learned
  servers.
* Zones can be created and deleted right on the map (deleting also removes
  the zone's learned servers on the router).
* Map styles: Midnight (black & grey, the default), Satellite (Sentinel-2
  imagery, sharp Esri close-ups, borders and place names), Light, Galaxy
  (deep-space colours with drifting nebulae, moving and twinkling stars and
  shooting stars). The effects never get in the way of clicks and stop if your
  system asks for reduced motion.
* **Open for server tests** (off by default): when a zone sees more than a set
  number of servers at once (a game testing data centres at login), all of
  them are let through for a few seconds, then your region applies again.
  It varies by game: **Apex Legends needs 2 or more** (it checks several data
  centres before a match), **Call of Duty should stay at 0**. Choosing a game
  in *New zone* fills in its recommendation; for other games start at 0 and
  raise it only if a game can't log in or find matches while filtering.
* Every change on the map is saved immediately - switching tabs loses
  nothing - and takes effect when you press **Save & Apply**.
* IPv4 and IPv6.

## How it works

```
 console ──► router forward hook ──► internet
                │
                ├─ new connection on the game's ports? remember the server address
                ├─ always-allow list ............................ allow
                ├─ always-block list ............................ drop*
                ├─ located inside a circle / allowed country .... allow
                ├─ located outside .............................. drop*
                └─ not located yet ........... allow  (strict mode: drop*)

 every interval:  collect new addresses → locate them (100 per request)
                  → recompute inside/outside → update nft sets atomically
 every 2 s:       a server not seen before? start that pass right away
 newly blocked:   its open connections are cut (conntrack -D)
 * monitor mode only counts these as "would block"
```

Learned servers and their locations are kept in RAM and written to
`/etc/lobbyfence` sparingly — within about 15 minutes of new servers being
found, otherwise every six hours, and on shutdown — so the flash isn't worn,
and they are restored after a reboot.

## Requirements

* A router with one of: OpenWrt 23.05 or newer (fw4 / nftables), FreshTomato
  on an ARM router, Asuswrt-Merlin 384.15+ on an HND model, or a recent DD-WRT
  build on a Broadcom ARM router (see [Install](#install))
* Internet access from the router to the geolocation service
* The gaming device needs a fixed address (a static DHCP lease) - or pick it
  by its MAC address

## Install

Download the package for your router's firmware from the
[latest release](https://github.com/Femto-Gurifisu/Lobbyfence/releases/latest):

| Firmware | Package | Logs in as | Before the first install |
|---|---|---|---|
| OpenWrt 23.05 or newer | `lobbyfence-openwrt.tar.gz` | `root` | - |
| FreshTomato (ARM) | `lobbyfence-freshtomato.tar.gz` | `root` | [JFFS and SSH on](#freshtomato) |
| Asuswrt-Merlin (HND, 384.15+) | `lobbyfence-asuswrt-merlin.tar.gz` | your router login (e.g. `admin`) | [JFFS and SSH on](#asuswrt-merlin) |
| DD-WRT (Broadcom ARM, e.g. R7000) | `lobbyfence-ddwrt.tar.gz` | `root` | [JFFS and SSH on](#dd-wrt) |

Then, on a computer on the same network, open a terminal and run the two
lines for your firmware. The first goes to your **Downloads** folder, where
your browser saved the package; the second copies the package to the router
and installs it. You are asked for the router's password once.

* **Windows:** use **Command Prompt** (not PowerShell - it can't send a file
  with `<`). **Mac / Linux:** Terminal. The same two lines work in both.
* `cd Downloads` works when the window opens in your home folder (it
  normally does). If it says there is no such folder, use
  `cd %USERPROFILE%\Downloads` (Windows) or `cd ~/Downloads` (Mac / Linux).
* Run them on your computer, **not** in a window already logged in to the
  router (a prompt like `root@DD-WRT` or `root@unknown`): the `ssh` line logs
  in by itself.
* **"The system cannot find the file specified"** (or *No such file*): the
  package isn't in that folder, or the browser renamed it because it was
  downloaded more than once. `dir lobbyfence*` (Mac / Linux: `ls lobbyfence*`)
  shows its name - e.g. `lobbyfence-ddwrt (1).tar.gz`; put that name in quotes
  at the end of the second line.

Use your router's address if it isn't the one below (ASUS routers usually use
192.168.50.1, most others 192.168.1.1).

**OpenWrt**

```sh
cd Downloads
ssh root@192.168.1.1 "cat > /tmp/lf.tgz && cd /tmp && rm -rf lobbyfence-install && tar -xzf lf.tgz && sh lobbyfence-install/install.sh" < lobbyfence-openwrt.tar.gz
```

Then open LuCI: **Services > LobbyFence**.

**FreshTomato**

```sh
cd Downloads
ssh root@192.168.1.1 "cat > /tmp/lf.tgz && cd /tmp && rm -rf lobbyfence-install && tar -xzf lf.tgz && sh lobbyfence-install/freshtomato/install.sh" < lobbyfence-freshtomato.tar.gz
```

Then open **http://192.168.1.1/ext/lobbyfence.asp**, or click **LobbyFence** in
FreshTomato's menu.

**Asuswrt-Merlin**

```sh
cd Downloads
ssh admin@192.168.50.1 "cat > /tmp/lf.tgz && cd /tmp && rm -rf lobbyfence-install && tar -xzf lf.tgz && sh lobbyfence-install/asuswrt-merlin/install.sh" < lobbyfence-asuswrt-merlin.tar.gz
```

Then open **Administration > LobbyFence** in the router's menu (the installer
also prints the page's address).

**DD-WRT**

```sh
cd Downloads
ssh root@192.168.1.1 "cat > /tmp/lf.tgz && cd /tmp && rm -rf lobbyfence-install && tar -xzf lf.tgz && sh lobbyfence-install/ddwrt/install.sh" < lobbyfence-ddwrt.tar.gz
```

Then open the router's page, **Status > My Page** - it takes you to LobbyFence.

**Updating:** the same two lines with the new package. Settings and learned
servers are kept.

The package unpacks into `/tmp/lobbyfence-install`. Don't unpack it into
`/tmp/lobbyfence` or delete that folder while LobbyFence runs: that's where it
keeps its working files.

**Uninstalling:** the installer keeps a copy of itself on the router.
`remove` / `--uninstall` keeps your settings and learned servers; `purge` /
`--purge` deletes those too and leaves the router as it was before.

| Firmware | Remove | Remove everything |
|---|---|---|
| OpenWrt | `ssh root@192.168.1.1 "sh /usr/share/lobbyfence/install.sh --uninstall"` | `... --uninstall --purge"` |
| FreshTomato, DD-WRT | `ssh root@192.168.1.1 "sh /jffs/lobbyfence/install.sh remove"` | `... purge"` |
| Asuswrt-Merlin | `ssh admin@192.168.50.1 "sh /jffs/addons/lobbyfence/install.sh remove"` | `... purge"` |

**"WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED"** from `ssh` means a
different device answered on that address before - for example you swapped
routers. If you did, make your computer forget the old one and try again:
`ssh-keygen -R 192.168.1.1`. If you didn't, stop and check what is on your
network.

**OpenWrt without a computer:** LobbyFence can also install itself straight
from this repository (the latest code, over HTTPS), in an SSH session on the
router:

```sh
uclient-fetch -q -O /tmp/lf-install.sh https://raw.githubusercontent.com/Femto-Gurifisu/Lobbyfence/main/install.sh
LF_SOURCE=https://raw.githubusercontent.com/Femto-Gurifisu/Lobbyfence/main sh /tmp/lf-install.sh
```

On a phone, the map page offers to put LobbyFence on your home screen (a tip
above the map, with the steps for your browser); the icon opens straight to
the map.

**Which version do I have?** The map page's Status section shows it next to
its heading - *LobbyFence 1.2.0 · up to date*, or *version 1.3.0 is out -
update* with a link to the latest release. To know that, your
browser (not the router) asks GitHub for the newest release, at most twice a
day; nothing else is sent. From the command line: `lobbyfence version`.

**Building the packages yourself:** `sh tools/build-packages.sh` writes the
four packages and their checksums to `dist/`. The `Makefile`s build proper
`lobbyfence` and `luci-app-lobbyfence` packages with the OpenWrt SDK.

### Coming from RegionGate

LobbyFence was called RegionGate before. Install LobbyFence the usual way
(on any of the four firmwares, the same commands as an update) and the
installer switches RegionGate off and removes it, and moves its settings and
learned servers over - on DD-WRT also the web page's port and sign-in, so the
page keeps working without signing in again. Changes made in LuCI or on the
page and not applied yet come along too. If LobbyFence already has settings
of its own, RegionGate's are left where they were and the installer says
where.

Some addresses changed with the name: LuCI's page is now Services →
LobbyFence, FreshTomato's `/ext/lobbyfence.asp`, the command `lobbyfence`. A
home-screen icon added for RegionGate on FreshTomato or Asuswrt-Merlin needs
to be added again (DD-WRT's keeps working).

## FreshTomato

LobbyFence also runs on **FreshTomato** routers with an ARM CPU (for example
RT-AC68U, RT-AC3200, R7000, R8000, EA6900). It is the same program and the
same map page; only the firewall part differs (iptables + ipset instead of
nftables).

**Before you start:** turn on JFFS under *Administration > JFFS* (tick
*Enable*, press *Format / Erase* once, *Save*). LobbyFence lives there, so it
survives reboots (and normally firmware upgrades too).

**SSH:** *Administration > Admin Access > SSH Daemon*.

**Install, update, uninstall:** see [Install](#install).

What is different on FreshTomato:

* **Lag simulator** - FreshTomato's kernel has no `netem` of its own, so
  LobbyFence brings one: `sch_netem.ko`, built from FreshTomato's own GPL
  kernel source for kernel `2.6.36.4brcmarm` (ARM builds of FreshTomato
  2026.x for R7000-class routers; `freshtomato/modules/build-netem.sh` rebuilds
  it). It is loaded only when a zone has lag switched on. The kernel checks
  every symbol's version before accepting it, so on a router whose kernel
  differs it is simply refused and nothing changes - the map then says the
  lag simulator isn't available. Every boot that uses netem is guarded:
  if the router restarts while netem is in use (for example because the
  module crashed it), LobbyFence notices after the reboot and doesn't use
  netem again by itself, so a bad module - or a firmware update it no longer
  fits - can't put the router in a restart loop (delete
  `/jffs/lobbyfence/.netem-loading` to try again). Switching the lag off,
  stopping LobbyFence or shutting the router down properly ends the guard,
  so a restart after that isn't blamed on netem. It works the same as on
  OpenWrt (download, upload or both; delay, jitter, loss), but it **needs QoS
  and the bandwidth limiter off**, because those use the same place in the
  router's traffic control - the map says so if they are on.
* **CPU use.** The learning loop checks every 2 seconds for servers it hasn't
  seen. That check is now a quick look at a small set that holds only unknown
  servers, instead of reading the whole server list. On a 1 GHz router like
  the R7000 it uses a few percent of one core; each learning pass (every
  *interval* seconds) adds a short burst. An **open map page** costs more,
  because it asks the router for the live data every 5 seconds. That request
  only reads the zone's devices' connections from the connection table. The
  page stops asking while its tab is in the background or the screen is off,
  and asks only every 30 seconds while LobbyFence is switched off. When
  LobbyFence is switched off, its learning loop doesn't run at all.
  `tests/tomato_cpu_test.sh` measures all of this.
* The page has two tabs: **Map** (the same map as on OpenWrt) and
  **Settings** (general settings and each zone's options - what the *Zones*
  page is on OpenWrt). Changes are kept on the router as you make them and
  take effect with **Save & Apply**; **Reset** throws them away.
* Zone names (the short id, not the label) are at most 16 characters; the map
  page makes them short enough by itself.
* FreshTomato rebuilds its firewall now and then (WAN reconnect, saving
  settings). LobbyFence's rules come back within a second through FreshTomato's
  firewall event, and the learning loop checks every pass as well.
* With hardware acceleration (CTF) on, LobbyFence marks the game device's
  packets so the router still checks them - the same trick FreshTomato uses
  for its VPNs. Nothing to configure. With QoS on, CTF is off anyway.
* Packets per second for servers in use come from the router's connection
  counters (switched on automatically). Connections opened before the
  counters were on show no rate; the map then goes by when the server was
  last seen instead of hiding it.
* IPv6: if the router's `ip6tables` can't add addresses to a set (many
  FreshTomato builds - the log says *Extension SET (target) is not
  supported*), IPv4 works as usual and IPv6 game servers are picked up from
  the router's connection list instead, so they still appear on the map.
  In zones with *strict* on (the default) a new IPv6 server is dropped before
  it gets into that list, so it can't be learned: those zones block the
  game's IPv6 servers, and the game uses IPv4, where everything works.
* **Servers missing from the map?** Run
  `/jffs/lobbyfence/lobbyfence diag` on the router. It explains, per zone,
  what was learned, what was seen in the last two minutes and what counts as
  active right now.
* Files: program and pages in `/jffs/lobbyfence`, settings in
  `/jffs/lobbyfence/lobbyfence.conf` (UCI syntax, like OpenWrt), learned
  servers in `/jffs/lobbyfence/data` (saved about every 15 minutes when new
  servers appear, and at shutdown). Boot, firewall and shutdown hooks:
  `/jffs/etc/config/lobbyfence.init`, `.fire`, `.shut`.
* The menu entry is added by laying a copy of the firmware's own `tomato.js`
  (with one extra line) over the original until the next reboot. To leave the
  menu alone, create the file `/jffs/lobbyfence/.nomenu`; the page still works
  at the address above.
* Command line on the router: `/jffs/lobbyfence/lobbyfence status`,
  `... list <zone>`, `... whereis <address>`, `... restart`, and the other
  commands below.

Not supported: MIPS FreshTomato builds (older firewall tools, usually no curl).

## Asuswrt-Merlin

LobbyFence runs on **Asuswrt-Merlin** for ASUS routers with Broadcom's HND
platform - the Wi-Fi 6 / 6E RT-AX and GT-AX models (for example RT-AX86U,
RT-AX88U, RT-AX58U, GT-AX6000, RT-AX86U Pro, RT-AX88U Pro) and the Wi-Fi 7
RT-BE and GT-BE models (for example GT-BE98 Pro, RT-BE96U, RT-BE88U) - on firmware
384.15 or newer (needs Merlin's add-on support; stock ASUS firmware can't run
add-ons). It is the same program and the same map page as on FreshTomato:
iptables + ipset, with the page added to Merlin's web interface through its
add-on API.

**Before you start:** turn on *Administration > System > Persistent JFFS2
partition* (Merlin has it on by default) and SSH (*Administration > System >
Enable SSH: LAN only*).

**Install, update, uninstall:** see [Install](#install). Use your router's
login name and address - ASUS routers default to 192.168.50.1, and the login
name is the one you chose for the web interface. The page is in the router's
menu: **Administration**, tab **LobbyFence** (next to *Tweaks*); the installer
also prints its address, e.g. `http://192.168.50.1/user1.asp`.

What is different on Asuswrt-Merlin:

* LobbyFence lives in `/jffs/addons/lobbyfence` (program, settings in
  `lobbyfence.conf`, learned servers in `data/`). It starts from Merlin's
  user scripts: one line each, marked `# LobbyFence`, in
  `/jffs/scripts/services-start`, `firewall-start`, `service-event` and
  `services-stop` - other add-ons' lines stay as they are. The installer
  switches on *Enable JFFS custom scripts and configs* if it was off.
* The page is a Merlin add-on page (one of the 20 `userN.asp` slots) with the
  map in a frame; *open full window* shows it on its own. It has the **Map**
  and **Settings** tabs. Changes you make wait **in your browser** until
  **Save & Apply**, which sends them to the router; a server you *always
  allow / block* on the map takes effect at once.
* Merlin's web server can't run LobbyFence's commands, so the page hands each
  request over through the add-on settings file
  (`/jffs/addons/custom_settings.txt`, key `lobbyfence_cmd`, taken out again
  at once) and the `restart_lobbyfence` service event. Each request writes
  that file (on JFFS) and makes the web server save the router settings, and
  the system log shows a "service-event" line - fine for clicks and Save &
  Apply. Just watching the map sends nothing: the live data is a file the
  learning loop writes again each time the page has read it.
* **On a phone**, ASUS's pages are desktop-sized: the LobbyFence page shows a
  yellow *Open LobbyFence in phone layout* link (the map page on its own, made
  for small screens; the same link is on FreshTomato's page). On touch screens
  the map works like other web maps on phones: **one finger scrolls the page,
  two fingers move and zoom the map**. Tap a region to select it. Its
  middle handle moves it (circles and polygons alike), and the edge or corner
  handles reshape it. In *Full screen* one finger moves the map again.
* **Home-screen app** (ASUS and FreshTomato): the phone layout can be added to
  a phone's home screen. It then has its own LobbyFence icon and opens without
  the browser's tabs. On an **iPhone**, tap *Share*, then *Add to Home Screen*;
  it opens in its own window. On **Android** (Brave, Chrome), open the browser
  menu (⋮), then *Add to Home screen*. Android browsers open a page in its own
  window only over HTTPS; the router's page is plain `http://`, so there the
  icon opens LobbyFence in the browser. In the phone layout (not inside the router's
  own page), it shows a one-line tip (× hides it). Tapping the tip opens the browser's own install dialog
  where the browser offers one. Otherwise it shows the steps for that browser
  (Safari, Brave, Chrome, Samsung Internet, Edge, Firefox), with an arrow to
  where its menu usually is. A web page can't open the browser's menu itself.
  For Brave, Chrome and Edge it also explains how to get a real app window:
  in `brave://flags` / `chrome://flags` / `edge://flags`, allow the router's
  `http://` address under *Insecure origins treated as secure*. The tip then
  gets an *Install* button. Opened from the home screen, a *Router* link
  leads to the router's own pages. You log in as usual; after the router logs
  you out, its login page brings you back to the map. Files: `manifest.json`
  (FreshTomato: `manifest.txt`, because its web server serves no `.json`),
  `lf-app.js`, and icons from `app-icon/` (`icon.svg` is the source).
* **Hardware acceleration** (Broadcom's flow cache / Runner) would let the
  game's packets skip the firewall once a connection runs. LobbyFence keeps
  just the game's connections out of it (the `SKIPLOG` target ASUS itself uses)
  and flushes the flow cache when its rules change. Everything else stays
  accelerated.
* **Lag simulator** - two ways, picked automatically:
  * **netem** (the kernel's own network emulator, the same as on OpenWrt and
    FreshTomato) on every model Merlin builds firmware for today:

    | Models | Kernel |
    | --- | --- |
    | GT-BE98 Pro, RT-BE96U, RT-BE88U / RT-BE7200, RT-BE86U, RT-BE92U, RT-BE58 Go | 4.19.294 |
    | GT-AXE16000, GT-AX6000, GT-AX11000 Pro, RT-AX86U Pro, RT-AX88U Pro, ZenWiFi Pro XT12 | 4.19.183 |
    | RT-AX86U / RT-AX86S, RT-AX68U, GT-AXE11000, RT-AX58U / RT-AX3000 | 4.1.52 |
    | RT-AX88U, GT-AX11000 | 4.1.51 |

    ASUS's firmware has no netem, so LobbyFence carries a module built from
    the firmware's own kernel source with each model's own configuration and
    compiler. Sixteen of the eighteen were also checked against ASUS's own
    precompiled drivers for that model (the kernel structures both use are
    laid out identically); ASUS ships none with debug information for the
    RT-AX58U and RT-BE58 Go, so those two rest on the build and the check on
    the router. The details are in `asuswrt-merlin/netem/README.md`. A
    module is used only on a matching model and kernel (`nvram get
    productid` or `odmpid`, `uname -r`), and it has to pass four safety
    steps:
    1. The router's own kernel configuration (`/proc/config.gz`) must be
       exactly the one the module was built for. If one option differs -
       another firmware build, say - the module is never loaded.
    2. A self-test once per boot, on a private test interface, before it
       touches real traffic.
    3. A guard on every boot it is used: if the router restarts while
       netem is in use, netem is never used again by itself.
    4. A fallback to lf-lagd whenever anything about it doesn't work.
       That includes QoS or the bandwidth limiter using the connection.

    The zone's rule puts its game packets in their own netem queue (CLASSIFY,
    no packet marks).
  * **lf-lagd** on every other model, and whenever netem can't be used: a small C program (one static ARM
    binary; source and build script in `asuswrt-merlin/lagd/`). The firewall
    hands the zone's game packets to it through the kernel's packet queue
    (NFQUEUE); it holds each one for the delay (plus jitter, minus loss) and
    lets it go. Nothing in the kernel is changed, so it can't crash the
    router. If `lf-lagd` stops, packets simply pass without lag, and the next
    pass starts it again. It doesn't use the router's QoS, so QoS settings
    don't get in its way.

  The map shows which one is running ("Active … · netem" or "· lf-lagd"), and
  `lobbyfence diag` shows it too, with netem's state. Either way, up to 12 zones
  can use the lag simulator at once.
* Zone names (the short id) are at most 16 characters, like on FreshTomato.
* Command line: `/jffs/addons/lobbyfence/lobbyfence status`, `... diag`,
  `... list <zone>`, `... whereis <address>`, `... restart`.

Supported models: the ones Merlin builds firmware for, on 3004.388.x or
3006.102.x.

* Wi-Fi 6 / 6E: RT-AX86U / S / Pro, RT-AX88U / Pro, RT-AX68U, RT-AX58U /
  RT-AX3000 (V1), GT-AX6000, GT-AX11000 / Pro, GT-AXE11000, GT-AXE16000,
  ZenWiFi Pro XT12.
* Wi-Fi 7: GT-BE98 Pro, RT-BE96U, RT-BE88U / RT-BE7200, RT-BE86U, RT-BE92U,
  RT-BE58 Go. Their firmware has the same firewall parts, flow cache and
  add-on support as the Wi-Fi 6 models (checked in Merlin 3006.102.9's
  source and kernel configuration). LobbyFence has not been run on a real
  Wi-Fi 7 router yet - reports are welcome.

Models Merlin has stopped building for (RT-AX56U, RT-AC68U V4) work on their
last Merlin release, with lf-lagd for the lag simulator. The GT-BE19000AI
isn't in Merlin's published source yet; it also uses lf-lagd.

Not supported: older Wi-Fi 5 models (RT-AC68U v1-v3, RT-AC88U, RT-AC3100,
RT-AC5300, ...) - their CTF acceleration would let game traffic skip the
filter, so the installer stops on them (kernel 2.6); many can run FreshTomato
instead. RT-AC86U (end-of-life Merlin 386) was not built against.

## DD-WRT

LobbyFence also runs on **DD-WRT** - checked on the **Netgear R7000**
(Broadcom ARM, kernel 4.4; recent DD-WRT builds, which bring ipset). Other
Broadcom ARM routers on the same builds (R6400, R6700, R8000, EA6900, ...)
should work the same way. It is the same program and the same map page as on
the other routers; the firewall part is FreshTomato's (iptables + ipset).

**Before you start:**

1. Turn on JFFS: *Administration > Management > JFFS2 Support*: *Enable*,
   tick *Clean JFFS2* once, *Apply Settings*, then reboot.
2. Turn on SSH: *Services > Services > Secure Shell*: *SSHd Enable*, *Apply
   Settings*. You log in as `root` with the router's password.

**Install, update, uninstall:** see [Install](#install). Then open the
router's page and go to **Status > My Page** - it takes you to LobbyFence.

What is different on DD-WRT:

* **The page has its own address.** DD-WRT's web server can't show add-on
  pages, so LobbyFence runs a small web server of its own (DD-WRT's
  lighttpd) on port **8055** of the router's LAN address. *Status > My Page*
  (which needs the router's login) hands your browser a sign-in key and
  opens `http://192.168.1.1:8055/`. The browser remembers the key, so a
  bookmark or the home-screen app keeps working. Without the key the page
  only shows where to get it, and the router refuses its commands - other
  people on your Wi-Fi can't change anything. `lobbyfence newtoken` makes a
  new key (every browser has to come through *My Page* again).
  `lobbyfence url` prints the address with the key. **Router ↗** at the top
  of the page leads back to DD-WRT's own pages (http or https, as you opened
  *My Page*).
* **Lag simulator:** netem is built into DD-WRT's kernel and DD-WRT has
  `tc`, so it simply works - no module, no trial run. It needs **QoS off**
  (QoS uses the same place in the router's traffic control - the map says so
  if it is on).
* **Hardware acceleration:** with *Shortcut Forwarding Engine* set to
  **CTF**, LobbyFence takes the game devices' connections out of CTF (DD-WRT's
  own mechanism: a special packet mark, applied twice so the mark itself stays
  unchanged), so their packets are still checked and lagged. Nothing to
  configure. With it set to **SFE** (the software fast path), a connection
  that has already carried 128 packets skips the firewall: new servers are
  still checked, but a running match isn't cut when its server gets blocked,
  and most packets skip the lag. The map says so; for full filtering choose
  CTF or Disable under *Setup > Basic Setup*.
* The page has two tabs, **Map** and **Settings**, like on FreshTomato.
* DD-WRT rebuilds its firewall now and then; LobbyFence's rules come back at
  once through DD-WRT's firewall hook, and the learning loop checks every
  pass as well.
* Files: program, pages and settings in `/jffs/lobbyfence`
  (`lobbyfence.conf`, UCI syntax), learned servers in `/jffs/lobbyfence/data`.
  Hooks: `/jffs/etc/config/lobbyfence.startup` (boot), `.firewall`, and
  `K90lobbyfence` (shutdown); a watchdog line in `/tmp/cron.d/lobbyfence`
  (needs *Cron* on, the default). *My Page* runs `/jffs/lobbyfence/mypage.sh`
  (nvram `mypage_scripts`).
* Command line: `/jffs/lobbyfence/lobbyfence status`, `... diag`,
  `... list <zone>`, `... restart`, `... url`, and the commands below.
* If your build has no lighttpd, the filter still works (set it up over SSH
  with the commands below); the installer says so.

## Quick start

1. Open LobbyFence's page (OpenWrt: **LuCI → Services → LobbyFence**; the
   other firmwares: see [Install](#install)) - it opens on the map. Click
   **Create your first zone**, pick the **game** and, for PC and console
   games, the **device type** (its ports are filled in - see
   [Game presets](#game-presets)) and the **device** from the list of devices
   on your network. The zone starts in **Monitor** mode, so nothing is blocked
   yet.
2. Click the map where you want to play and drag the circle's edge dot to size
   it - or use **Draw polygon**: click the corners, then click the first
   corner, double-click or press Enter (Esc cancels). LobbyFence then offers to
   **Align** it: every edge is made exactly straight (level or upright), so a
   hand-drawn shape becomes a clean square / rectangle (an L-shape keeps its
   square corners; a triangle becomes the rectangle around it). The offer stays
   on screen while the polygon is selected; *Straighten* in the panel does the
   same at any time. Saved shapes are drawn as clear
   outlines; click one to edit it (its handles appear), drag it to move it,
   press Delete to remove it. Press **Save & Apply**.
3. Play a few sessions. Learned servers appear as dots (green inside your
   circles, red outside); the panel next to the map lists them and shows how many
   packets *would* have been blocked.
4. Zones start in **Strict** mode: servers outside your region *and* servers
   not located yet are blocked (a new server is usually located within
   20-60 seconds). Switch between **Strict / Enforce / Monitor** in the panel.
   If a server you need is blocked - a login, matchmaking or relay server -
   click it and choose **Always allow**.

If matchmaking breaks, put the login / matchmaking / relay servers in
*Always allow* (look for red dots that you know aren't game servers).

## Configuration (`/etc/config/lobbyfence`)

| Option (globals)     | Default                    | Meaning |
|----------------------|----------------------------|---------|
| `enabled`            | `0`                        | Master switch |
| `interval`           | `20`                       | Seconds between learning passes (≥ 15) |
| `geo_url`            | `http://ip-api.com/batch`  | ip-api.com–compatible batch endpoint |
| `max_batches`        | `4`                        | Lookups per pass, 100 addresses each (also capped at 14/minute) |
| `data_dir`           | `/etc/lobbyfence`          | Where learned data is kept |
| `persist_interval`   | `21600`                    | How often "last seen" times are saved (s) |
| `log_blocked`        | `0`                        | Log drops to syslog (rate limited) |
| `priority`           | `-5`                       | nftables forward hook priority |

| Option (zone)   | Meaning |
|-----------------|---------|
| `enabled`       | Zone on/off |
| `label`         | Display name |
| `mode`          | `enforce` (default) or `monitor` |
| `strict`        | Also drop servers not located yet (default `1`) |
| `device`        | List: MAC address (recommended, covers all of the device's IPv4/IPv6 addresses) or an IPv4/IPv6 address / subnet |
| `proto`         | `udp`, `tcp` or `both` |
| `port`          | List: ports / ranges matched on either side (server or device) |
| `remote_port`   | List: server-side ports / ranges |
| `local_port`    | List: device-side ports / ranges |
| `circle`        | List: `latitude,longitude,radius_km` |
| `polygon`       | List: `lat,lon;lat,lon;lat,lon...` (at least 3 corners; may cross the antimeridian) |
| `country`       | List: two-letter country codes |
| `allow_ip`      | List: always allowed addresses / subnets (wins over everything) |
| `block_ip`      | List: always blocked addresses / subnets |
| `expire_days`   | Forget servers not seen for this many days (`0` = never) |
| `burst_servers` | Open for server tests: more than this many servers within `burst_window` seconds opens the zone (default `0` = off; Apex Legends and Fortnite: 2 or more, Call of Duty: 0) |
| `burst_open`    | Seconds the zone stays open after the last such burst (default `20`) |
| `lag` / `lag_delay` / `lag_jitter` / `lag_loss` | Lag simulator: on/off, extra ping (ms), jitter (ms), packet loss (%) - all default `0` |
| `lag_direction` | `both` (default, split half and half), `down` or `up` |
| `burst_window`  | What "at once" means, in seconds (default `10`) |

Set at least one port. Without ports, *all* traffic of the device (of the
chosen protocol) goes through the filter.

Several zones may cover the same device. A packet matching more than one zone
must pass every one of them.

## Game presets

The new-zone dialog fills in the ports for these games. "Official" means the
numbers come from the developer (directly or via an esports body quoting
them); "community" means players reported them, so they may be incomplete.
If a game isn't listed - or nothing shows up on the map - use
**Any game (all UDP traffic)**.

PC & console games (fighting games too) are picked together with the
**device type** - PC, or a console: PlayStation, Xbox or Nintendo Switch -
because some games use other ports on each (Fortnite and Apex Legends below);
the others use the same ports everywhere. The zone panel shows it next to the game (*Fortnite ·
PlayStation*), and **Change…** switches it.

| Preset | Ports | Source |
|--------|-------|--------|
| Any game | UDP 1024-65535 (server side) | - |
| Any mobile game | TCP 443, 3013, 5001, 5003, 9001, 9330-9340, 10001-10094, 10514, 17500, 18082, 30000-30999, 39003, 39698, 39779, 65010, 65050 (server side); starts in Enforce | 443 / 65010 / 65050: official - [Activision](https://support.activision.com/content/atvi/support/web/en/articles/ports-used-for-call-of-duty-games.html) (CoD: Mobile); the rest: community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports) |
| Custom | your own ports and name | - |
| Apex Legends | PC: UDP 7700-7799, 8100-8199, 9000-9099, 10000-10599, 10700-10899, 15000-15099, 22200-22299, 27000-27199, 49000-49099 · PlayStation: UDP 1000-1099, 1900-1999, 3000-3199, 7700-7799, 8100-8199, 10000-10999, 27000-27199, 27500-27599, 34100-34199 · Xbox and Nintendo Switch: UDP 1024-65535 (not measured yet) | players' routers (EA's own list - 1024-1124, 37000-40000 - misses the match ports) |
| Call of Duty (BO7/BO6, Warzone, MW III) | UDP 3074-3079, either side | official - [Activision](https://support.activision.com/content/atvi/support/web/en/articles/ports-used-for-call-of-duty-games.html) |
| Counter-Strike 2 / Dota 2 | UDP 27000-27100 | community |
| Fortnite | PC: UDP 9000-9199, 10500-10599, 15000-15199, 22200-22299, 30300-30399, 32900-32999, 35000-35099, 36800-36899, 39200-39299, 45100-45199 · PlayStation: UDP 9000-9199, 10100-10199, 15000-15199, 22200-22299, 36300-36399, 37500-37599, 39900-39999, 41700-41799, 42100-42199, 48200-48299, 51100-51199, 53700-53799, 56100-56199 · Xbox, Nintendo Switch and mobile: UDP 3478-3479, 5060, 5062, 6250, 12000-65000 ([Epic Games](https://fortnitehelp.epicgames.com/help/en-US/c5719335176219/c5719372265755/a000084266), wide range) | players' routers (PC, PlayStation); Epic Games (Xbox, Nintendo Switch, mobile) |
| GTA Online (GTA V) / Red Dead Online | UDP 6672, 61455-61458, either side - peer-to-peer, see below | official - Rockstar ([GTA Online](https://support.rockstargames.com/articles/52C2oBx4yUOClVNK6enH8z), [Red Dead Online](https://support.rockstargames.com/articles/3LzU9sNfbcR8Z2sZ8gpFLH/red-dead-online-pc-connection-troubleshooting)) |
| League of Legends | UDP 5000-5500 | official - Riot, via [British Esports](https://britishesports.org/wp-content/uploads/2023/02/PORT-IP-24-25.pdf) |
| Overwatch 2 | UDP 3478-3479, 5060, 5062, 6250, 12000-64000 | official - Blizzard, via [NASEF](https://www.nasef.org/overwatch-it-help-page) (wide range) |
| Rainbow Six Siege X | UDP 3074, 6015, 10000-10099 | community - [Netduma forum](https://forum.netduma.com/topic/38151-duma-not-recognizing-rainbow-six-siege-xr1000/), [IPFire forum](https://community.ipfire.org/t/rainbow-six-siege-server/4361) |
| Roblox (PC, console and mobile) | UDP 49152-65535 (wide range) | official - [Roblox](https://en.help.roblox.com/hc/articles/203312880) |
| Rocket League | UDP 7000-9000 | official - Psyonix, via [British Esports](https://britishesports.org/wp-content/uploads/2023/02/PORT-IP-24-25.pdf) |
| VALORANT | UDP 7000-8000, 8180-8181 | official - [Riot](https://support.riotgames.com/en-us/valorant/support-tools/how-to-set-up-port-forwarding) |
| ARC Raiders, Battlefield 6, Dead by Daylight, EA SPORTS FC 26, Marvel Rivals, PUBG: BATTLEGROUNDS | UDP 1024-65535 (server side) - their match ports aren't published or measured yet: narrow the zone with [Ports…](#narrowing-a-zone-to-its-games-real-ports-ports) after a few matches | - |
| **Fighting games:** Street Fighter 6 | UDP 30840-30859, 30870-30879, either side - peer-to-peer, see below | community - Capcom's ports, via [portforward.com](https://portforward.com/street-fighter-6/) |
| **Fighting games:** Dragon Ball Xenoverse 2, Dragon Ball: Sparking! ZERO, Guilty Gear -Strive-, Mortal Kombat 1, Super Smash Bros. Ultimate, TEKKEN 8 | UDP 1024-65535 (server side) - peer-to-peer, see below; their match ports aren't published or measured yet: narrow the zone with [Ports…](#narrowing-a-zone-to-its-games-real-ports-ports) after a few matches | - |
| Arena of Valor | UDP/TCP 10001-10094, 17000 | community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports) |
| Call of Duty: Mobile | UDP 7500-8000 | official - [Activision](https://support.activision.com/content/atvi/support/web/en/articles/ports-used-for-call-of-duty-games.html) |
| Clash Royale / Clash of Clans | UDP/TCP 9330-9340 | community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports) |
| Free Fire | UDP 10001-10012 | community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports) |
| Mobile Legends: Bang Bang | UDP/TCP 5001, 5003, 9001, 30000-30999 | community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports), [OpenWrt forum](https://forum.openwrt.org/t/port-forward-mobile-legends-port/71959) |
| PUBG Mobile | UDP 10010-20002 | community - [Netduma forum list](https://forum.netduma.com/topic/55803-list-of-mobile-games-and-its-ports) |

*Open for server tests* is filled in per game: Apex Legends and Fortnite
(PC/console and mobile) 2 (raise it if needed); Call of Duty, Call of Duty:
Mobile, GTA Online and the fighting games 0 (off). Other games start at 0.

**GTA Online and Red Dead Online are peer-to-peer:** the other players in your
session connect to your console or PC directly (from UDP 6672 when they can),
so LobbyFence locates *them*, not servers - the smaller the region, the fewer
players end up in your session. A session is many players at once, so *Open
for server tests* stays off. Players' addresses are never added to the
servers list LobbyFence comes with.

**Fighting games are peer-to-peer too:** a match is your console or PC and
the other player's, directly, so LobbyFence locates your opponents - only
players inside your region get through. The game may check a few opponents at
once before a match, so *Open for server tests* stays off for these as well.

**Games whose match ports aren't known yet** (ARC Raiders, Battlefield 6,
Dead by Daylight, EA SPORTS FC 26, Marvel Rivals, PUBG: BATTLEGROUNDS) start
with every UDP port, like *Any game*. After a few matches, **Ports…** shows the
ports the game really used: keep those, and the device's other traffic (voice
chat, other games) is left alone. **Roblox** uses its own wide range
(49152-65535), which voice and video calls on the same device (Discord and the
like) use too.

**Changing a zone's game:** the panel shows the zone's game with a
*Change…* button. Pick another preset to switch the zone to that game's
ports, protocol and *Open for server tests* value. You can rename the zone to
match. The device, the region and the learned servers stay. Press Save &
Apply afterwards.

**Any mobile game** is for a phone or tablet: mobile games find their match
(lobby, matchmaking) over TCP, mostly on port 443, so filtering those
connections keeps the game to servers in your region. Port 443 is also what
every app and website uses, so while the zone filters, apps and sites on that
device whose servers are outside your region won't load. It therefore starts
in **Enforce** (a new server works until it has been located) rather than
Strict; start in Monitor to see what it would block, use *Always allow* for
apps you need, or switch the zone off when you aren't playing. Port 80 (plain
HTTP, in Activision's list for downloads) is left out so web pages keep
working. The game's own UDP traffic isn't filtered by this preset - add a
second zone with the game's UDP preset for that.

Server-side ports are matched on the server's end of the connection, so phones
and PCs (which use random ports themselves) are matched correctly. "Either side"
also catches consoles that always play from the same port.

## No servers on the map?

Work down this list - the side panel shows most of it:

1. **Service running?** The panel should say *Running · rules loaded*. If it
   says *Not running*, press **Start LobbyFence**. (Versions before this one
   didn't start the service after installing, so Save & Apply had no effect
   until a reboot - re-run the installer.)
2. **Device seen?** The panel shows *Device at …*. For phones and tablets pick
   the device by its MAC address: phones use several IPv4/IPv6 addresses and
   change them. On an iPhone set *Private Wi-Fi Address* to *Fixed* (or *Off*)
   for your home network.
3. **Game packets above 0?** Play a match. If the counter stays at 0, the ports
   don't match the game - switch the zone to **Any game** (Zones page: delete
   the ports and set *Server ports* to `1024-65535`).
4. **API working?** Press **Test API**. Servers waiting for a location appear
   under *Unknown*, not on the map.
5. On the router: `lobbyfence status`, `lobbyfence list <zone>`, and
   `logread -e lobbyfence`.

## Something not working? The debug report

The map page's Status section has a **Debug…** button. It makes a report on
the router right then and adds what the browser ran into, then lets you
**Download** it as a `.txt` file (or **Copy** it). Attach it when you report a
problem. It contains:

* router, firmware and LobbyFence version, memory, flash space;
* what LobbyFence sees per zone (the same as `lobbyfence diag`);
* recorded crashes, the last error, LobbyFence's own log (kept in memory, so
  it works with the router's system log switched off - DD-WRT's default),
  the system log's LobbyFence lines and the learning loop's error output;
* the settings, LobbyFence's firewall rules (not the long server lists), what
  is saved on flash;
* the platform's own parts (web page, hooks, menu, cron);
* from the browser: page, browser, screen, and its errors (script errors,
  failed requests, error messages the page showed, map errors).

It holds **no passwords** (of the router's nvram only a few model / version
keys are read) and no sign-in token, and MAC addresses are partly hidden
(`70:9e:29:**:**:01` - the number tells devices apart). It does show your
regions and the game servers' addresses: look through it before posting it in
public. The report is at most 240 KB.

**Crashes:** if LobbyFence's background service (the learning loop) stops
without a clean stop - killed for lack of memory, a fatal error, or stopped by
force - it is started again (watchdog / procd), and the stop is recorded with
what it was doing, its last error output and the kernel's memory messages.
The newest 8 records are kept on flash (`<data_dir>/crash.log`), so they
survive a reboot. Status then shows *The background service stopped
unexpectedly …* and the last error; **Clear crash records** in the Debug
window (or `lobbyfence debug clear`) forgets them once the problem is solved.

From the command line: `lobbyfence debug > /tmp/lf-debug.txt` (on FreshTomato
and DD-WRT `/jffs/lobbyfence/lobbyfence debug`, on Merlin
`/jffs/addons/lobbyfence/lobbyfence debug`).

## Narrowing a zone to its game's real ports (Ports…)

Some games don't use the ports their maker publishes - Apex Legends' matches,
for example, were seen on 10200 and 10600 - so the Any game and Apex Legends
presets take every UDP port. That also catches other games and apps on the
same device. **Ports…** (next to *Change…* under the zone's game) fixes that:

1. Play a few matches with the zone on (the router notes the server ports the
   device used on every learning pass with game traffic, for 30 days).
2. Open **Ports…**: the ports seen, busiest first (**Sort by**, or click a
   column, to order them by passes, servers, last seen or port number). With
   a wide range such as Any game, ports with real game traffic are ticked for
   you; the many short ones are usually the game pinging its data centres -
   tick those too to keep far data centres blocked. When the zone already has
   a narrow set of ports (a game's own, or ones chosen here before), the ports
   seen inside them start ticked, so the list shows what the zone filters now.
3. **Use these ports**. With *Round to blocks of 100* (on by default) 10200
   becomes 10200-10299, so the game's next servers on a nearby port are still
   caught. The zone keeps its game; the panel then says *own ports*.

From the command line: `lobbyfence ports <zone>` (and `... clear`).

## Sharing located servers (Servers file)

Every server a router locates is already saved on that router for good - it
survives reboots and is never looked up again while a zone still knows it. The
**Servers file…** button (Status section, next to **Debug…**) is for the other
cases: a new or reset router, a second router, or a friend who plays the same
games.

* The dialog lists what is saved, one line per game: how many servers, how
  many this router found and how many were imported, and their countries.
  Open a game to see its servers (address, country, last seen, from where).
  While it is open it follows the router every 10 seconds, so the servers
  found while you play show up (not while you have servers ticked).
* **Download servers** saves every located server, grouped by the game of the
  zone that found it, with its location: `lobbyfence-servers-YYYYMMDD.txt`.
  Browsers flag downloads from `http://` router pages as insecure - choose
  *Keep*, or use **Copy** and paste the text wherever you want it.
* **Paste…** imports a servers file someone sent you as text.
* **Delete selected**: tick servers in a game's list (or the box at the top
  for all of them) to delete just those - from the kept list and from the
  zones set to that game. The rest of the list stays.
* **Remove this list** (inside each game) deletes that game's list: its kept
  and imported locations, and the servers learned by zones set to that game
  (they are learned and looked up again as you play). It asks once more
  first. Whitelists, blacklists and regions are not touched.
* **Import a servers file…** adds those locations to the router. When one of
  those servers shows up later, its location is taken from the file - no
  lookup - and the log says *located N server address(es) from known
  locations (no lookup)*.

LobbyFence also comes with a list of known **Apex Legends**, **Call of
Duty** and **Fortnite** servers and where they are (`/usr/share/lobbyfence/servers.txt`, the
same format as a servers file). The Servers file window lists them under
**Comes with LobbyFence**, by game (read-only: they are part of LobbyFence);
from the command line, `lobbyfence builtin-servers`. A router that sees one
of them places it straight away, with no lookup - even before anything has
been imported - and it shows up on the map as soon as the device plays on it
(and from then on in the game's list above, as found by this router). The
router's own and imported locations come first. The list holds game servers
in data centres only: players' own addresses, which peer-to-peer traffic
(party chat, some lobbies) also shows, are never added to it.

Servers are filed under the game the zone was set to when it found them.
Switch a zone to another game (**Change game**) and its learned servers stay
saved under the old game, with their locations - the zone then learns the new
game's servers from scratch. The same happens when a zone is deleted. Servers
kept this way count as *from this router* in the dialog, not as imported.

Importing only adds locations. It doesn't add servers to a zone, doesn't
change what is blocked, and doesn't touch whitelists or blacklists. The file
holds game-server addresses and locations only - nothing about your devices,
your own address or your regions. Up to 20,000 imported locations are kept
(newest first); files over 1 MB, private addresses and bad lines are skipped.

The locations come from the geolocation service (by default ip-api.com, whose
free tier is for non-commercial use). Sharing a file with friends or between
your own routers is fine; check the service's terms before publishing a large
list publicly.

From the command line: `lobbyfence export > servers.txt` and
`lobbyfence import-servers servers.txt` (or `-` for standard input), and
`lobbyfence remove-servers <game id|all> [address...]`.

## Command line

```
lobbyfence status [json]            zones, learned servers, counters
lobbyfence list <zone> [state]      servers of a zone (in, out, pending, unloc)
lobbyfence whereis <address>        locate one address, check it against every zone
lobbyfence apitest [address]        check that the geolocation service answers
lobbyfence allow <zone> <addr...>   always allow these servers (live, saved to the config)
lobbyfence block <zone> <addr...>   always block these servers (live, saved to the config)
lobbyfence unlist <zone> <addr...>  remove those rules again
lobbyfence live                     current counters and server-test state (JSON)
lobbyfence devices                  devices on the network: MAC, name, IPv4 and IPv6 (JSON)
lobbyfence import <zone> <file|->   add known server addresses
lobbyfence export                   located servers by game (the Servers file)
lobbyfence import-servers <file|->  add the locations from a Servers file (no lookups)
lobbyfence remove-servers <game|all> [addr...]  delete a game's servers list, or just those servers
lobbyfence ports <zone> [clear]     the server ports the zone's device used while playing
lobbyfence forget <zone> [addr...]  drop learned addresses
lobbyfence cycle                    run a learning pass now
lobbyfence apply                    rebuild the firewall table
lobbyfence persist                  write learned data to flash now
lobbyfence diag                     what the map shows and why (servers missing?)
lobbyfence debug [clear]            the debug report; "clear" forgets the crash records
```

`/etc/init.d/lobbyfence start|stop|restart|status_report` manage the service.

## Things to know

* **Geolocation is approximate.** Free databases sometimes place a server in
  the company's home country instead of the data centre. Check odd results
  with `lobbyfence whereis`, and use *Always allow / Always block* to correct
  them.
* **Privacy.** The addresses of the game servers you connect to are sent to the
  geolocation service (from your router's public IP). Nothing about your own
  devices is included.
* **ip-api.com's free tier** (batch endpoint) allows 15 requests a minute
  per internet address, 100 addresses each, plain HTTP only, and
  non-commercial use only. LobbyFence stays inside that: at most 14 requests
  a minute counting every kind (learning, *Test API*, `whereis`), 100
  addresses each, and it obeys the service's own count - when its `X-Rl`
  header says nothing is left (other devices on your connection use it too)
  or it answers "too many requests" (429), LobbyFence sends nothing until the
  time in `X-Ttl` has passed, so the address is never banned. Each server is
  looked up once and remembered (unlocatable ones are retried weekly). For
  anything else, point `geo_url` at a paid or self-hosted endpoint that speaks
  the same batch format.
* **Open for server tests** is counted by the router's firewall itself, so even
  a burst lasting one second is caught. It opens the zone for every device of
  the zone, including servers outside your region, and also lets servers
  through that strict mode would hold back - your own *Always block* rules
  still apply. It is off by default (`0`); the *New zone* window fills in the
  chosen game's recommendation. An outside server that was let
  in while the zone was open is cut off again when it closes.
* **Lag simulator (netem)** - in the map panel, per zone. It makes the zone's
  device's game connection worse on purpose: **extra ping**, **jitter** (ping
  jumping up and down) and **packet loss**, so you can feel how a game plays on
  a bad connection. *It can't* lower your ping, change other players' ping or
  the server, or pick different lobbies - it only ever adds lag. Only that
  device's game traffic is affected; everyone else is normal, and switching it
  off restores everything at once. Choose the **direction**: *Download only*
  (the game's packets reach you late), *Upload only* (your packets reach the
  server late) or *Both ways* (the default - the extra ping is split half and
  half, so the total is what you entered). Packet loss applies to each chosen
  direction. It needs a few packages, installed once over SSH:
  `apk add tc-full kmod-netem kmod-ifb kmod-sched-core kmod-sched-ctinfo`
  (OpenWrt 25) or `opkg update && opkg install tc-full kmod-netem kmod-ifb
  kmod-sched-core kmod-sched-ctinfo` (`kmod-sched-ctinfo` is only needed for
  upload lag),
  and flow offloading must be off. LobbyFence hooks in next to your LAN
  interface's normal queue (tc clsact + an ifb device per zone; uploads are
  recognised by their connection mark, restored with tc ctinfo for the zone's
  devices' packets only), so SQM and other queue setups are left alone.
* **Security:** the LuCI pages may only run the handful of LobbyFence
  commands they need (live status, devices, API test, allow / block / forget,
  restart) and read `/tmp/lobbyfence/`. Names that come from outside - DHCP
  host names, address-search results - are always shown as plain text.
  ip-api.com's free tier is plain HTTP, so someone on the path could fake a
  server's location; its answers are checked strictly (address, numbers,
  two-letter country, at most 1 MB), and `geo_url` can point at an HTTPS
  service instead.
  The map library (MapLibre GL JS) comes from a public CDN (unpkg, else
  jsDelivr) and runs inside the router's admin page, so the page checks it
  first: each file's SHA-256 must match the published 6.15.0 release, or it
  is not run (a CDN serving changed code can't take over your router page).
  On FreshTomato and Merlin the page's requests need the router's login; on
  DD-WRT LobbyFence's own small web server (LAN address only, port 8055)
  needs a 128-bit token that only the signed-in Status > My Page hands out.
  Settings that end up as arguments of other programs (`geo_url`,
  `lag_dev`, `data_dir`) are checked first, and the debug report hides keys
  and passwords in addresses (`key=`, `token=`, ...).
* **Firmware upgrades:** your settings and learned servers are kept
  (`/lib/upgrade/keep.d/lobbyfence`). The program itself is not part of the
  firmware, so after upgrading run the install command again - your zones,
  regions and servers are all still there.
* **List files** are plain text: one address or subnet per line, `#` starts a
  comment, so lists from friends, forums or spreadsheets can be uploaded
  as they are. Anything that isn't an address is skipped and reported.
* **Saving:** map changes are saved (staged) at once, like LuCI's *Save*
  button, and show up in LuCI's *Unsaved changes* counter until you press
  **Save & Apply**. **Reset** on the map page throws away LobbyFence changes
  that were saved but not applied yet.
* **No region drawn** means nothing is inside: in strict and enforce mode every
  server is blocked (except your whitelist) until you draw a circle or polygon
  or list a country.
* **Polygons** are checked on the same flat (Web-Mercator) map you draw them
  on, so a server inside the drawn shape is inside for the router too - the
  test suite checks that the map and the router agree point for point.
* **View menu** on the map: *Borderless* (the map fills the browser window
  without a frame - Esc leaves it), *Endless map* (keep scrolling sideways; the
  world repeats - off by default), *Country borders* (on by default), and *Zoom out completely* (pole to
  pole). The choices are remembered in your browser.
* **Fit** shows the whole world and stays that way (also after Save & Apply)
  until you pan or zoom yourself. Otherwise the map keeps the view you left it
  in; it never jumps to a circle on its own. Click a circle's number in the
  panel to zoom to it.
* **The map** loads MapLibre GL JS from unpkg (jsDelivr as fallback) and tiles
  from OpenFreeMap, so the browser you use for LuCI needs internet access and
  WebGL2. The router itself only needs to reach the geolocation service.
* **How fast you are kicked:** a new server is spotted within about 2 seconds
  and located right away, so in Enforce mode an outside server is cut off a
  few seconds after you join it (in Strict mode it never gets through at all).
  When a server turns "blocked" - by your region, or by clicking *Block* on the
  map - the router also drops its existing connections, so the game loses it
  immediately instead of when the connection times out.
* **Active now** shows the servers your device is actually playing on: at
  least one packet per second, measured by the router. Allowed servers that
  only get an occasional keep-alive ping drop off the map within seconds.
* **Flow offloading** (software or hardware, Network → Firewall) makes the
  router skip the firewall for connections that are already running. Blocking
  still works when a connection starts, and with the `conntrack` package
  installed LobbyFence also cuts running ones (`apk add conntrack` or
  `opkg install conntrack`). The map's panel warns you when offloading is on;
  turning it off is the most reliable choice.
* Region filtering decides *which servers* you may reach. It can't make a game
  match you against nearby players if the game doesn't want to.

## Safety

A router that stops booting or that you can't reach any more is the worst
thing an add-on can do. What LobbyFence does and doesn't do about that:

* **It never touches the firmware, the bootloader or flash partitions.** No
  `mtd`, `sysupgrade`, `firstboot`, `mkfs` or the like, and it never reboots
  the router. It adds its own files (OpenWrt: the LuCI app and
  `/usr/share/lobbyfence`; the others: one folder on JFFS), its own firewall
  rules and, on DD-WRT and Asuswrt-Merlin, one small nvram setting each
  (DD-WRT: the *Status > My Page* entry; Merlin: custom scripts on, which
  other add-ons need too and which stays on).
* **It filters only the zone's device, only forwarded traffic, only on the
  game's ports.** Traffic to the router itself - its web page, SSH, DNS, DHCP -
  is never filtered, so a mistake in a zone can't lock you out of the router.
  The lag simulator only delays the zone device's game traffic.
* **Boot, firewall and shutdown never wait for it long.** The startup and
  firewall hooks return at once (the work runs in the background), and
  shutdown waits at most about 20 seconds even if another LobbyFence command
  hangs. If the system holds the firewall lock (UPnP, a VPN, a firewall
  rebuild), LobbyFence waits up to 15 seconds and then reports it - it never
  waits forever.
* **If its rules can't be put in place, none are left.** When the firewall
  refuses LobbyFence's rules (a kernel without a feature they need, say), it
  takes out the old ones too, so the router works as it would without
  LobbyFence - never with old or half-loaded rules. The page shows the reason,
  and LobbyFence tries again on every learning pass.
* **It never fills the flash or the memory.** Learned servers are saved
  sparingly, files have size limits, and LobbyFence leaves the last 256 KB of
  the flash / JFFS to the router: when space runs out it keeps its data in
  memory and says so. A crash record goes to the flash at most once every 10
  minutes, so a learning loop that keeps stopping can't wear it out. Each zone
  keeps at most 20000 servers (the ones seen most recently), so a zone whose
  ports also catch other traffic can't fill the router's memory.
* **A kernel module that might crash is never loaded again after a crash.**
  The lag simulator's netem module (FreshTomato, some Merlin models) is
  guarded on every boot it is used: if the router restarts while netem is in
  use, it is not loaded again by itself - also after a firmware update the
  module no longer fits. At most one restart, never a loop.
* **It only stops its own programs.** Before stopping its learning loop, web
  server or lag helper, LobbyFence checks the process is still that program -
  a process number from a file may belong to something else by then.
* **Uninstalling leaves the router as it was.** `purge` takes out the files,
  hooks, nvram entry, firewall rules, sets and queues - also ones left by a
  LobbyFence command still running at that moment.

**If something goes wrong:** LobbyFence only ever blocks the zone's device, so
use another device to reach the router. Switch LobbyFence off on its page, or
uninstall it over SSH (see [Install](#install)). If you can't get in at all,
your firmware's own reset (or OpenWrt's failsafe mode) brings the router back
to its defaults.

All of this is checked by tests: `tests/safety_static.py` scans every script
that goes onto a router, and the end-to-end tests check reachability, the
hooks with a hung command, the firewall lock, a full flash, and that an
install from the release package followed by `purge` leaves nvram, JFFS,
hooks, firewall and web folders exactly as before (see [Tests](#tests)). They
run in emulated routers - each firmware's own BusyBox, iptables / ipset or
nftables in Linux network namespaces - not on real hardware, so they make
problems unlikely, not impossible.

## Tests

`tests/` contains the checks used during development:

* `safety_static.py` — every script that goes onto a router, scanned for
  anything that could brick or wipe one: flash / firmware / reboot commands,
  nvram writes other than LobbyFence's two small ones, writes to devices,
  `rm -rf` outside LobbyFence's own folders, kernel modules other than
  ipset's and LobbyFence's netem.
* `openwrt_install_test.sh <workdir> <busybox>` — the OpenWrt installer from
  the release package, in a private mount namespace with stand-in `/etc`,
  `/usr`, `/www`: files where LuCI and procd expect them, an update keeps the
  settings, `--uninstall --purge` leaves those folders exactly as before.
* The brick-safety sections of `netns_test.sh`, `tomato_netns_test.sh`,
  `merlin_netns_test.sh` and `ddwrt_netns_test.sh`: a zone filtering every
  port and protocol never cuts the device off the router's own services; the
  boot, firewall and shutdown hooks don't hold the router up while another
  LobbyFence command hangs; the firewall lock held by the system (both kinds
  of iptables builds); a nearly full flash; a rule set the firewall refuses
  (no rules left, the next pass tries again); a learning loop that keeps
  stopping (the flash written at most every 10 minutes); an update while
  running (Merlin: still one page slot and one tab); install from the release
  package (unpacked by that firmware's BusyBox) and `purge` leaving nvram,
  JFFS, hooks, cron, web folders, firewall and ipsets exactly as before.
* `unit_awk.sh` — the awk helpers (address handling, distance, parsing, the
  20000-server limit per zone).
* `netns_test.sh` — end-to-end: a LAN client, a router running LobbyFence and
  fake game servers in Linux network namespaces, with a fake geolocation API.
  Needs root, `nft`, `python3`, a BusyBox binary and OpenWrt's `uci`; the lag
  simulator checks also need an iproute2 `tc` (`LF_REAL_TC=/path/to/tc`).
* `luci_js_test.js` — syntax, map geometry and zone-creation logic of the LuCI
  views (Node.js).
* `browser_map_test.py` — the map page in headless Chromium (Playwright) with
  LuCI and MapLibre stand-ins: welcome screen, new-zone dialog, drawing,
  saving, server dots, WebGL2 failure.
* `browser_real_maplibre.py <maplibre-dist> [shots] [positron.json]` — the
  same page on the **real** MapLibre GL JS build (WebGL via SwiftShader):
  shapes, server dots, the home pin, every theme, the globe, the View menu and
  real mouse drags. Pass the `dist` folder of a maplibre-gl release (its
  `dist.zip` on GitHub); with OpenFreeMap's `styles/positron/style.json`
  (github.com/hyperknot/openfreemap-styles) it also checks the real basemap
  layers: country borders on/off and the Antarctica label in every theme.
* `browser_real_luci_zones.py <luci-resources-dir>` and
  `browser_real_luci_map.py <luci-resources-dir> <maplibre-dist>` — both pages
  inside the **real LuCI framework** (luci.js, form.js, ui.js, uci.js, rpc.js
  from openwrt/luci) with a scripted ubus API: rendering, LuCI's validation,
  and saving to the router, including edits made while a save is under way.
* `perf_test.sh <workdir> <busybox> <uci-prefix> <openwrt> [servers]` — load
  benchmark with many learned servers (default 20000).
* `acl_test.py` — LuCI permissions: every command the pages run is allowed,
  anything else (other LobbyFence commands, other programs) is not.
* `tomato_netns_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset>` —
  the FreshTomato port end to end in network namespaces: BusyBox built with
  FreshTomato's own configuration as `/bin/sh` and as the only tools, legacy
  iptables, ipset 6.38 (FreshTomato's version), installed by its installer
  into a fake `/jffs`: filtering, learning, server tests, firewall rebuilds,
  CTF marks, the CGI, saving to JFFS, a simulated reboot, IPv6 learning
  without the SET target, `diag`, and the lag simulator's tc setup (against
  `fake_tomato_tc.sh`, which records the commands, since the test kernel is
  not FreshTomato's).
* `tomato_browser_test.sh ... <maplibre-dist> <freshtomato www dir>` — the
  FreshTomato pages in headless Chromium against that router: FreshTomato's own
  `tomato.js` with the added menu entry, the map and settings tabs, Save /
  Apply / Reset through the real CGI (a rule clicked on the map survives a
  later Save & Apply of other changes), a new zone's firewall rules.
* `ddwrt_netns_test.sh <workdir> <ddwrt-busybox> <its applet list> <full-busybox> <ipset> <lighttpd prefix>` —
  the DD-WRT port end to end, made from the FreshTomato test: BusyBox built
  with DD-WRT's configuration as `/bin/sh`, ipset 7, legacy iptables and
  lighttpd 1.4.82 (DD-WRT's version), installed by `ddwrt/install.sh`: the
  same filter checks, plus DD-WRT's hooks (`.startup`, `.firewall`, `K90`),
  `/tmp/cron.d`, the CTF exclusion (the double XOR leaves the packet mark
  unchanged), the SFE warning, the built-in netem's tc setup, *My Page*, the
  web server (LAN address only, token file not served) and every CGI command
  over real HTTP, new tokens, and the watchdog restarting the web server.
* `ddwrt_browser_test.sh ... <maplibre-dist>` — the DD-WRT page in headless
  Chromium running on the LAN side: sign-in through *My Page*, the token
  leaving the address bar and being remembered, map, live allow, Save &
  Apply, Settings, the SFE note, a new token, the phone layout's home-screen
  tip.
* `tomato_cpu_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset> [servers] [seconds]` —
  CPU time of the learning loop, of an open map page's requests, and with
  LobbyFence switched off, with two zones and a 3000-connection table. It
  also estimates the figures for a 1 GHz ARM router.
* `tomato_lag_unit.sh <workdir> [shell]` — the FreshTomato lag simulator's
  12-zone limit, netem's trial guard when the lag is switched off during
  the trial, and the upload queue following a WAN failover, without a router.
* `merlin_netns_test.sh <workdir> <merlin-busybox> <full-busybox> <ipset> <merlin-files>`
  — the Asuswrt-Merlin port end to end in network namespaces: BusyBox 1.25.1
  built from Merlin's tree with its RT-AX86U configuration (no builtin
  `echo` / `printf` / `test`) as `/bin/sh` and the only tools, ipset 7.6
  (Merlin's), Merlin's own `helper.sh` and `menuTree.js`, installed by its
  installer next to another add-on: hooks, page and menu entry, requests the
  way Merlin's web server sends them (`merlin_page.py`), long requests in
  pieces, firewall rebuilds, the lag simulator for real (lf-lagd behind
  NFQUEUE: +120 ms measured on game traffic only, queue bypass when it
  stops; the netem module refused -> lf-lagd carries the lag; the game's
  rule switched to CLASSIFY and back in the real firewall), boot / shutdown,
  uninstall.
* `geo_limit_test.sh <workdir> <busybox>` — the geolocation service's free
  tier, against `fake_geo.py` behaving like ip-api.com (15 a minute, `X-Rl`,
  `X-Ttl`, 429, 100 per request): a burst of 2500 new servers, `whereis` and
  *Test API* counted, other devices using up the count, a 429, a clock jump.
* `merlin_unit.sh <workdir> [shell]` — the Merlin rules this test kernel
  can't load: `SKIPLOG` in the zone chains, the lag queue per direction.
* `merlin_netem_unit.sh <workdir> [shell]` — the Merlin lag simulator's choice
  between netem and lf-lagd, with stand-ins for the GT-AXE16000's `tc`, `ip`,
  `ping` and `insmod`. It covers:
  - which module is picked: one per model and kernel version, each fitting
    its checksum and kernel configuration
  - the kernel configuration check (an option that differs, one only the
    router has, no `/proc/config.gz`) - the module is never loaded
  - the self-test on a private test interface (dummy, or ifb on kernel 4.1)
    before any real device gets a queue
  - the queues and CLASSIFY bands
  - the trial
  - every fallback: QoS on, self-test failing, module refused, a restart
    during an earlier trial, another model
  - a network restart dropping the queue, a WAN failover moving it
  - the lag switched off or LobbyFence stopped during the trial (a later
    restart is not taken for a crash)
* `LF_BROWSER_SCRIPT=browser_merlin_mobile.py merlin_browser_test.sh ...` — the
  same pages on a touch phone (390×844, real touch events): one finger over
  the map and a region scrolls the page without moving them, two fingers move
  the map, a region's handle moves it without scrolling, Save & Apply reachable
  at the bottom, full screen gives one finger back to the map, the router's
  page offers the phone layout (not on a computer). It also checks the
  home-screen app: the tip (and that × keeps it closed), the manifest as
  Chromium reads it, the icons at their sizes, the iPhone tags, and that the
  app window gets the *Router* link.
* `merlin_browser_test.sh ... <maplibre-dist>` — the Merlin pages in headless
  Chromium with a stand-in for Merlin's web server (`<% %>` processing,
  `start_apply.htm`, add-on settings): menu entry, map, live data, always
  allow, Save & Apply of changes kept in the browser, Settings tab, lag
  simulator from the map.
* `tomato_perf_test.sh <workdir> <tomato-busybox> <full-busybox> <ipset> [servers]` —
  the same load benchmark for the FreshTomato port (ipset / iptables).
* `zones_page_test.js [luci-resources-dir]` — the Zones page options; given
  LuCI's `modules/luci-base/htdocs/luci-static/resources` it checks every input
  rule with LuCI's own `validation.js`.

## Disclaimer

LobbyFence is provided "as is", without warranty of any kind, express or
implied, including the warranties of merchantability and fitness for a
particular purpose. You install and run it at your own risk. In no event shall
the author or contributors be liable for any claim, damages or other
liability - including a router that no longer starts ("bricked"), can't be
reached, loses its settings or must be reset, lost or interrupted
connections, lost data, or any other loss - arising from, out of or in
connection with the software or its use. Sections 15 and 16 of the GNU
General Public License (`LICENSE`) say the same in legal terms.

Keep a backup of your router's settings, know how to reset your router, and
make sure you are allowed to change the network you install it on. Whether a
game's terms allow filtering which servers you connect to is for you to
check. The default geolocation service (ip-api.com) is free for
non-commercial use only.

## License

Copyright (C) 2026 Femto-Gurifisu

LobbyFence is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, either version 3 of the License, or (at your option) any later
version (GPL-3.0-or-later). It comes with no warranty - see `LICENSE` for the
full text.

MapLibre GL JS (loaded by the map page) is
BSD-3-Clause. Map tiles: OpenFreeMap, © OpenMapTiles, data © OpenStreetMap
contributors. Satellite imagery: EOxCloudless by EOX IT Services GmbH
(contains modified Copernicus Sentinel data 2020), free for non-commercial use
(CC BY-NC-SA 4.0); close-ups (zoom 10 and in): Esri World Imagery (© Esri,
Maxar, Earthstar Geographics) under Esri's terms of use.
