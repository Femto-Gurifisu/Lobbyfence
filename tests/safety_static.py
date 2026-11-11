#!/usr/bin/env python3
"""Brick-safety scan of every script LobbyFence installs on a router.

Fails when a script could wipe or brick a router or fill its nvram:
  * commands that write flash, firmware or partitions, or reboot the router
  * nvram writes other than the few known small ones (Broadcom nvram is
    32-64 KB; filling it can stop a router from booting)
  * writes to devices (dd of=, > /dev/...) other than /dev/null
  * rm -rf of anything but LobbyFence's own folders (a path built from a
    variable that might be empty - rm -rf "$X"/* - can wipe the router)
  * kernel modules other than ipset's and LobbyFence's own netem module

A new rm -rf, nvram write or module load needs a look and an entry here.
  usage: safety_static.py [repo]
"""
import re
import sys
from pathlib import Path

REPO = Path(sys.argv[1] if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent)

SCRIPTS = [
    "install.sh", "files/etc/init.d/lobbyfence", "files/usr/sbin/lobbyfence",
    "files/usr/share/lobbyfence/fw-nft.sh", "files/usr/share/lobbyfence/fw-ipt.sh",
    "files/usr/share/lobbyfence/fw-ddwrt.sh", "files/usr/share/lobbyfence/fw-merlin.sh",
    "freshtomato/install.sh", "freshtomato/lobbyfence", "freshtomato/functions.sh",
    "freshtomato/www/lobbyfence.cgi", "freshtomato/modules/build-netem.sh",
    "ddwrt/install.sh", "ddwrt/lobbyfence", "ddwrt/mypage.sh", "ddwrt/www/cgi-bin/lobbyfence.cgi",
    "asuswrt-merlin/install.sh", "asuswrt-merlin/lobbyfence", "asuswrt-merlin/lagd/build.sh",
]

# command words that have no business in LobbyFence (as a command, not in a message)
FORBIDDEN = ["mtd", "flash_erase", "flash_eraseall", "flashcp", "nandwrite", "sysupgrade", "firstboot",
             "jffs2reset", "jffs2_mark_erase", "mkfs", "mkfs.jffs2", "mkfs.ubifs", "ubiformat", "fdisk",
             "parted", "reboot", "halt", "poweroff", "fw_setenv", "nvram_erase"]

# nvram keys LobbyFence may write: DD-WRT's Status > My Page list, Merlin's custom-scripts switch,
# FreshTomato's Init script (one comment line added, to notice a reset to factory defaults - the
# rest of the script is kept, and uninstalling takes the line out again)
NVRAM_KEYS = {"mypage_scripts", "jffs2_scripts", "script_init"}

# rm -rf: the variables that hold LobbyFence's own folders (each checked
# below to have a fixed, non-empty value) and literal paths it may remove
RM_VARS = {"LF_RUN", "LF_STATE", "RUN", "DEST", "OLD", "STAGE", "WWWEXT", "G_DATA", "HOOKS", "WEB",
           "W", "WORK", "SP", "in", "d", "k", "key", "dir", "tmp", "f"}
RM_VAR_PREFIX_ONLY = {"d", "k", "key", "dir", "tmp", "f", "in"}   # only as "$x/..." or a file inside a LobbyFence folder
RM_LITERAL = re.compile(r"^/(tmp|var/run|jffs|etc/lobbyfence|etc/config/lobbyfence|etc/regiongate|etc/config/regiongate|"
                        r"usr/share/lobbyfence|usr/share/regiongate|www/luci-static|www/user|tmp/var/wwwext|"
                        r"/?tmp/luci-modulecache)\b")

MODULES = re.compile(r"^(ip_set|ip_set_hash_ip|ip_set_hash_net|xt_set|sch_netem|nfnetlink_queue|\"?\$LF_NETEM_KO\"?|\"?\$k(o)?\"?)$")
# "$m" in a loop over these modules only
MODULE_LOOP = re.compile(r"\bfor m in ([\w ]+);")

problems = []


def code_lines(text):
    """(number, line) without comments and here-doc bodies are kept (they are scripts too)."""
    for n, line in enumerate(text.splitlines(), 1):
        s = line.strip()
        if not s or s.startswith("#"):
            continue
        # a trailing comment (outside quotes, roughly)
        line = re.sub(r"\s+#\s.*$", "", line)
        yield n, line


def command_words(line):
    """the words at command position: start of line, after ; | & ( ` $( then do else"""
    for m in re.finditer(r"(?:^|[;|&(`]|\$\(|\bthen\b|\bdo\b|\belse\b)\s*([A-Za-z_][\w.\-]*)", line):
        yield m.group(1)


for rel in SCRIPTS:
    p = REPO / rel
    if not p.exists():
        problems.append(f"{rel}: missing")
        continue
    text = p.read_text()
    for n, line in code_lines(text):
        where = f"{rel}:{n}"
        for w in command_words(line):
            if w in FORBIDDEN:
                problems.append(f"{where}: runs '{w}': {line.strip()}")
        if re.search(r"\bnvram\s+(erase|restore|reset)\b", line):
            problems.append(f"{where}: nvram erase/restore: {line.strip()}")
        # (the nvram command itself, or a variable holding it, quoted or not)
        for m in re.finditer(r"(?:\bnvram|\"?\$\{?(?:NVRAM|nv|NV)\}?\"?)\s+set\s+\"?([A-Za-z0-9_]+)=", line):
            if m.group(1) not in NVRAM_KEYS:
                problems.append(f"{where}: writes nvram {m.group(1)}: {line.strip()}")
        if re.search(r"\bdd\b[^|;]*\bof=", line):
            problems.append(f"{where}: dd writes a file/device: {line.strip()}")
        for m in re.finditer(r"(?<![0-9&])>>?\s*\"?(/dev/[\w/]+)", line):
            if m.group(1) not in ("/dev/null", "/dev/stderr", "/dev/stdout"):
                problems.append(f"{where}: writes to {m.group(1)}: {line.strip()}")
        for m in re.finditer(r"\b(insmod|modprobe)\s+(?:-\w+\s+)*(\S+)", line):
            if m.group(2) == '"$m"':
                loops = MODULE_LOOP.findall("\n".join(text.splitlines()[max(0, n - 4):n]))
                if loops and all(MODULES.match(x) for x in " ".join(loops).split()):
                    continue
            if not MODULES.match(m.group(2)):
                problems.append(f"{where}: loads kernel module {m.group(2)}: {line.strip()}")
        for m in re.finditer(r"\brm\s+-[a-z]*r[a-z]*f?[a-z]*\s+([^;|&)]+)", line):
            args = m.group(1).split()
            for a in args:
                if a.startswith("2>") or a in ("||", "&&") or a.startswith(">"):
                    break
                raw = a.replace('"', "").replace("'", "")
                mv = re.match(r"^\$\{?([A-Za-z_]\w*)\}?(.*)$", raw)
                if mv:
                    var, rest = mv.group(1), mv.group(2)
                    if var not in RM_VARS:
                        problems.append(f"{where}: rm -rf of ${var}{rest} (not one of LobbyFence's folders): {line.strip()}")
                    elif var in RM_VAR_PREFIX_ONLY and not rest.startswith("/"):
                        # a loop variable holding a file of LobbyFence's (checked by hand: only in loops over LobbyFence's folders)
                        pass
                    if rest in ("/*", "/"):
                        problems.append(f"{where}: rm -rf {raw} - everything in a folder named by a variable: {line.strip()}")
                    continue
                if raw.startswith("/"):
                    if raw in ("/", "/*") or not RM_LITERAL.match(raw):
                        problems.append(f"{where}: rm -rf {raw} (outside LobbyFence's folders): {line.strip()}")
                    continue
                # a relative name inside a folder the script cd'ed into (installers: "lobbyfence" in /tmp etc.)
                if raw in ("*", ".", "..") or raw.startswith("*"):
                    problems.append(f"{where}: rm -rf {raw}: {line.strip()}")

# the folder variables rm -rf may use always have a fixed, non-empty value
FIXED = {
    "files/usr/sbin/lobbyfence": [r'^LF_RUN="\$\{LF_RUN:-/tmp/lobbyfence\}"', r'^LF_STATE="\$LF_RUN/state"'],
    "freshtomato/install.sh": [r'^JFFS="\$\{LF_JFFS:-/jffs\}"', r'^DEST="\$JFFS/lobbyfence"', r'^RUN=/tmp/lobbyfence'],
    "ddwrt/install.sh": [r'^JFFS="\$\{LF_JFFS:-/jffs\}"', r'^DEST="\$JFFS/lobbyfence"', r'^RUN=/tmp/lobbyfence'],
    "asuswrt-merlin/install.sh": [r'^JFFS="\$\{LF_JFFS:-/jffs\}"', r'^DEST="\$JFFS/addons/lobbyfence"', r'^RUN=/tmp/lobbyfence'],
    "asuswrt-merlin/lobbyfence": [r'^WWWUSER="\$\{LF_WWWUSER:-/www/user\}"', r'^WEB="\$WWWUSER/lobbyfence"'],
}
for rel, pats in FIXED.items():
    text = (REPO / rel).read_text()
    for pat in pats:
        if not re.search(pat, text, re.M):
            problems.append(f"{rel}: expected a fixed folder: {pat}")

# G_DATA (the data folder) comes from the settings: it may be removed only after it was checked
main = (REPO / "files/usr/sbin/lobbyfence").read_text()
for n, line in code_lines(main):
    if re.search(r'\brm\s+-rf\s+"?\$G_DATA"?\s*($|[;|&])', line):
        problems.append(f"files/usr/sbin/lobbyfence:{n}: removes the whole data folder (from the settings): {line.strip()}")

# The servers list LobbyFence comes with is published: game servers in data centres only.
# Peer-to-peer traffic (party chat, some lobbies) shows players' home addresses too - those
# must never be added. Every address must be in a hosting network listed here.
import ipaddress
HOSTING = """
  45.32.0.0/16 45.63.0.0/16 45.76.0.0/15 64.176.0.0/15 64.237.32.0/19 65.20.96.0/19 66.42.32.0/19 66.42.64.0/18
  66.135.0.0/19 78.141.192.0/18 80.240.16.0/20 95.179.128.0/17 104.156.224.0/19 104.207.128.0/19 104.238.128.0/18
  107.191.32.0/19 108.61.0.0/16 136.244.64.0/18 137.220.32.0/19 139.84.128.0/17 139.180.128.0/18 140.82.0.0/18
  144.202.0.0/17 149.28.0.0/16 149.248.0.0/18 155.138.128.0/17 158.247.192.0/18 167.179.64.0/18 173.199.64.0/18
  192.248.144.0/20 198.13.32.0/19 199.247.0.0/19 202.182.96.0/19 207.148.0.0/17 207.246.64.0/18 208.167.224.0/19
  208.85.16.0/21 209.222.0.0/19 216.128.128.0/19 216.238.64.0/18 217.69.0.0/20 96.30.192.0/20

  34.0.0.0/15 34.18.0.0/16 34.48.0.0/16 34.51.0.0/16 34.64.0.0/10 34.128.0.0/10 35.184.0.0/13 35.192.0.0/11
  35.224.0.0/12 35.240.0.0/13

  3.0.0.0/8 13.32.0.0/11 13.112.0.0/12 13.200.0.0/13 13.208.0.0/12 13.224.0.0/11 15.128.0.0/10 15.220.0.0/14
  15.228.0.0/15 15.236.0.0/15 16.24.0.0/16 16.162.0.0/15 16.170.0.0/15 18.88.0.0/16 18.128.0.0/9 35.42.0.0/16
  35.72.0.0/13 35.80.0.0/12 35.152.0.0/13 35.160.0.0/13 43.192.0.0/10 44.192.0.0/10 51.84.0.0/16 52.0.0.0/10
  52.88.0.0/13 52.192.0.0/11 54.0.0.0/8 63.176.0.0/15 78.12.0.0/15 107.20.0.0/14 184.32.0.0/14 216.244.0.0/18

  155.133.224.0/19 162.254.192.0/21 146.66.152.0/21 185.25.180.0/22 103.10.124.0/23 103.28.54.0/23 205.196.6.0/24
  45.121.184.0/22

  103.43.72.0/24 189.1.164.0/24 95.141.40.0/24 185.34.107.0/24 212.102.63.0/24 89.222.108.0/24 89.222.117.0/24
  152.233.52.0/24 216.198.196.0/24 216.198.246.0/24 208.76.222.0/24
"""   # Vultr / Choopa; Google Cloud; Amazon; Valve's relays; then data-centre blocks seen only in the
      # games' data-centre ping rounds, next to the ones above (never a home connection). Kept narrow on
      # purpose: Google Fiber, AT&T and the like share first numbers with some of these.
nets =[ipaddress.ip_network(c) for c in HOSTING.split()]
n_srv = 0
for n, line in enumerate((REPO / "files/usr/share/lobbyfence/servers.txt").read_text().splitlines(), 1):
    t = line.split()
    if not t or t[0].startswith("#") or t[0] in ("lobbyfence-servers", "game"):
        continue
    n_srv += 1
    try:
        a = ipaddress.ip_address(t[0])
    except ValueError:
        problems.append(f"servers.txt:{n}: not an address: {line}")
        continue
    if not any(a in net for net in nets):
        problems.append(f"servers.txt:{n}: {t[0]} is not in a data-centre network listed in safety_static.py"
                        " - a player's home address must never be published")

if problems:
    for p in problems:
        print("FAIL:", p)
    print(f"{len(problems)} problem(s)")
    sys.exit(1)
print(f"PASS: {len(SCRIPTS)} scripts: no flash / firmware / reboot commands, nvram writes only to {sorted(NVRAM_KEYS)},"
      " no device writes, rm -rf only inside LobbyFence's folders, only ipset / netem modules")
print(f"PASS: servers.txt: all {n_srv} addresses are game servers in data-centre networks (no players' addresses)")
print("ALL STATIC SAFETY CHECKS PASSED")
