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
RM_LITERAL = re.compile(r"^/(tmp|var/run|jffs|etc/lobbyfence|etc/config/lobbyfence|"
                        r"usr/share/lobbyfence|www/luci-static|www/user|tmp/var/wwwext|"
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
HOSTING = " ".join(l.split("#")[0] for l in (REPO / "files/usr/share/lobbyfence/server-networks.txt").read_text().splitlines())
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

# the map page's copy (Send to LobbyFence sends only servers in these networks)
_js = (REPO / "luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js").read_text()
_m = re.search(r"var SERVER_NETWORKS = '([^']*)'", _js)
if not _m or _m.group(1).split() != HOSTING.split():
    problems.append("map.js SERVER_NETWORKS is not the same list as files/usr/share/lobbyfence/server-networks.txt")

# the router sends the same games' servers as the page (share-servers), to the same form
_p2p = set(re.findall(r"'([a-z0-9_]+)'", re.search(r"var P2P_GAMES = \[([^\]]*)\]", _js).group(1)))
_page_games = [f"{m.group(1)} {m.group(3)}" for m in re.finditer(
    r"\{ id: '([a-z0-9_]+)', group: '([a-z]+)', label: (?:_\()?'((?:[^'\\]|\\.)*)'", _js)
    if m.group(2) in ("pc", "mobile") and m.group(1) not in _p2p]
_router_games = [l for l in (REPO / "files/usr/share/lobbyfence/share-games.txt").read_text().splitlines() if l and not l.startswith("#")]
if [g.replace("\\'", "'") for g in _page_games] != _router_games:
    problems.append("files/usr/share/lobbyfence/share-games.txt is not the map page's list of games that may be shared")
_main = (REPO / "files/usr/sbin/lobbyfence").read_text()
_form = re.search(r"var SHARE_URL = 'https://docs\.google\.com/forms/d/e/([\w-]+)/viewform'", _js)
if not _form or f"https://docs.google.com/forms/d/e/{_form.group(1)}/formResponse" not in _main:
    problems.append("the router (SHARE_URL in files/usr/sbin/lobbyfence) does not send to the map page's form")

if "var SHARE_URL = 'https://docs.google.com/forms/d/e/" not in _js or "FORM_ID_HERE" in _js:
    problems.append("map.js SHARE_URL is not LobbyFence's Google Form yet (Send to LobbyFence)")

if problems:
    for p in problems:
        print("FAIL:", p)
    print(f"{len(problems)} problem(s)")
    sys.exit(1)
print(f"PASS: {len(SCRIPTS)} scripts: no flash / firmware / reboot commands, nvram writes only to {sorted(NVRAM_KEYS)},"
      " no device writes, rm -rf only inside LobbyFence's folders, only ipset / netem modules")
print(f"PASS: servers.txt: all {n_srv} addresses are game servers in data-centre networks (no players' addresses)")
print("ALL STATIC SAFETY CHECKS PASSED")
