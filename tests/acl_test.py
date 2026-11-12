"""LuCI permission (rpcd ACL) check: every command the pages run is allowed, and
nothing else is. Matching works like rpcd (file.c / session.c): the bare
executable first, then "executable arg arg ..." against fnmatch patterns.
    usage: python3 acl_test.py
"""
import fnmatch
import json
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
ACL = json.loads((ROOT / "luci-app-lobbyfence/root/usr/share/rpcd/acl.d/luci-app-lobbyfence.json").read_text())["luci-app-lobbyfence"]
VIEWS = ROOT / "luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence"
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


def allowed(argv, perm="exec"):
    pats = [p for p, perms in ACL["write"]["file"].items() if perm in perms]
    if any(fnmatch.fnmatchcase(argv[0], p) for p in pats):
        return True
    line = " ".join(argv)
    return any(fnmatch.fnmatchcase(line, p) for p in pats)


# every fs.exec('<path>', [ '<literal>', ... ]) in the views, with sample arguments for the rest
calls = []
for f in ("map.js", "zones.js"):
    for m in re.finditer(r"fs\.exec\('([^']+)',\s*\[\s*('([a-z-]*)'|[A-Za-z_]+)", (VIEWS / f).read_text()):
        if m.group(3) is None:
            continue   # a variable (allow / block / unlist) - checked separately below
        calls.append((f, m.group(1), m.group(3)))
check("found the commands the pages run", len(calls) >= 7, calls)
samples = {"forget": ["game", "80.20.0.1"], "allow": ["game", "80.20.0.1", "2a00::/32"], "block": ["game", "1.2.3.4"],
           "unlist": ["game", "1.2.3.4"], "ports": ["game"], "remove-servers": ["apex", "1.2.3.4"],
           "import-servers": ["/tmp/lobbyfence/servers-import.txt"], "share-servers": ["status"]}
for f, path, first in calls:
    argv = [path] + ([first] if first else [])
    argv_full = argv + samples.get(first, [])
    check("%s may run: %s" % (f, " ".join(argv_full)), allowed(argv_full), argv_full)
check("map page may run: allow/block with a dynamic action word",
      all(allowed(["/usr/sbin/lobbyfence", a, "game", "1.2.3.4"]) for a in ("allow", "block", "unlist")))
check("forget everything in a zone (no addresses)", allowed(["/usr/sbin/lobbyfence", "forget", "game"]))
check("map page may switch sending found servers once a day on and off",
      all(allowed(["/usr/sbin/lobbyfence", "share-servers"] + x) for x in (["status"], ["auto", "on"], ["auto", "off"])))
check("map page may make the debug report and clear the crash records",
      allowed(["/usr/sbin/lobbyfence", "debug"]) and allowed(["/usr/sbin/lobbyfence", "debug", "clear"]))

for bad in (["/usr/sbin/lobbyfence", "import", "game", "/etc/shadow"], ["/usr/sbin/lobbyfence", "teardown"],
            ["/usr/sbin/lobbyfence"], ["/etc/init.d/lobbyfence", "stop"], ["/etc/init.d/lobbyfence", "disable"],
            ["/bin/sh", "-c", "id"], ["/usr/sbin/lobbyfence", "persist"],
            ["/usr/sbin/lobbyfence", "debug", "/etc/shadow"], ["/usr/sbin/lobbyfence", "debug", "clear", "x"],
            ["/usr/sbin/lobbyfence", "share-servers", "now"], ["/usr/sbin/lobbyfence", "share-servers", "preview"],
            ["/usr/sbin/lobbyfence", "share-servers", "auto", "on", "x"]):
    check("not allowed: " + " ".join(bad), not allowed(bad))
check("status files readable", any(fnmatch.fnmatchcase("/tmp/lobbyfence/status.json", p) for p in ACL["read"]["file"]))
check("nothing outside /tmp/lobbyfence is readable", all(p.startswith("/tmp/lobbyfence/") for p in ACL["read"]["file"]))

print("ALL ACL TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
sys.exit(0 if all(results) else 1)
