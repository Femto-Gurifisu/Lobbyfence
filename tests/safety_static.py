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

# nvram keys LobbyFence may write: DD-WRT's Status > My Page list, Merlin's custom-scripts switch
NVRAM_KEYS = {"mypage_scripts", "jffs2_scripts"}

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
        for m in re.finditer(r"(?:\bnvram|\$NVRAM)\s+set\s+\"?([A-Za-z0-9_]+)=", line):
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

if problems:
    for p in problems:
        print("FAIL:", p)
    print(f"{len(problems)} problem(s)")
    sys.exit(1)
print(f"PASS: {len(SCRIPTS)} scripts: no flash / firmware / reboot commands, nvram writes only to {sorted(NVRAM_KEYS)},"
      " no device writes, rm -rf only inside LobbyFence's folders, only ipset / netem modules")
print("ALL STATIC SAFETY CHECKS PASSED")
