#!/usr/bin/env python3
"""tools/sync-servers.py: a shared servers file is checked line by line and only
game servers in data-centre networks, for listed client-server games, are added
to the built-in list - each once."""
import pathlib, shutil, subprocess, sys, tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
fails = 0
def check(what, ok, detail=""):
    global fails
    print(("PASS: " if ok else "FAIL: ") + what + ("" if ok else f" - {detail}"))
    fails += 0 if ok else 1

with tempfile.TemporaryDirectory() as d:
    d = pathlib.Path(d)
    for f in ("tools/sync-servers.py", "tools/server-networks.txt", "files/usr/share/lobbyfence/servers.txt",
              "luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js", "tests/safety_static.py"):
        (d / f).parent.mkdir(parents=True, exist_ok=True)
        shutil.copy(REPO / f, d / f)
    before = (d / "files/usr/share/lobbyfence/servers.txt").read_text()
    share = d / "share.txt"
    share.write_text("""lobbyfence-servers 1
# sent with Send to LobbyFence - LobbyFence 1.3.3
game apex Apex Legends
155.133.248.36 52.2961 4.9549 NL 1794416301
155.133.248.99 52.2961 4.9549 NL 1794416301
155.133.248.99 52.2961 4.9549 NL 1794416301
73.12.44.5 40.7 -74.0 US 1794416301
3.3.3.3 95 10 US 1794416301
3.3.3.4 10 10 US 9999999999
game sf6 Street Fighter 6
3.4.5.6 40 -70 US 1794416301
game gta GTA Online
3.4.5.7 40 -70 US 1794416301
game other Victor's PS5
3.4.5.8 40 -70 US 1794416301
game valorant VALORANT
3.120.9.9 50.11 8.68 DE 1794416301
""")
    run = lambda *a: subprocess.run([sys.executable, str(d / "tools/sync-servers.py"), *a], capture_output=True, text=True)
    r = run("--dry-run", str(share))
    check("dry run changes nothing", r.returncode == 0 and (d / "files/usr/share/lobbyfence/servers.txt").read_text() == before, r.stdout + r.stderr)
    r = run(str(share))
    after = (d / "files/usr/share/lobbyfence/servers.txt").read_text()
    added = [l for l in after.splitlines() if l not in before.splitlines()]
    check("adds the new data-centre server once, after its game", r.returncode == 0 and
          sum(l.startswith("155.133.248.99 ") for l in after.splitlines()) == 1, r.stdout)
    check("an address already listed is not added again", sum(l.startswith("155.133.248.36 ") for l in after.splitlines()) == 1)
    check("a home address, a bad location and a time in the future are left out",
          not any(l.split()[0] in ("73.12.44.5", "3.3.3.3", "3.3.3.4") for l in added), added)
    check("peer-to-peer games, Custom zones and their labels are left out",
          not any(x in after for x in ("3.4.5.6", "3.4.5.7", "3.4.5.8", "Victor")), added)
    check("a listed game not in the list yet gets its own section",
          "game valorant VALORANT\n3.120.9.9 50.11 8.68 DE 1794416301" in after, added)
    check("exactly those two lines are new", sorted(added) == sorted(["155.133.248.99 52.2961 4.9549 NL 1794416301",
          "game valorant VALORANT", "3.120.9.9 50.11 8.68 DE 1794416301"]), added)
    r = run(str(share))
    check("running it again adds nothing", (d / "files/usr/share/lobbyfence/servers.txt").read_text() == after, r.stdout)
    # the private form's answers, downloaded as .csv: each answer that holds a servers file
    import csv
    resp = d / "responses.csv"
    with open(resp, "w", newline="") as f:
        w = csv.writer(f)
        w.writerow(["Timestamp", "Servers"])
        w.writerow(["2026/11/12 1:00:00 AM GMT-5", "lobbyfence-servers 1\ngame apex Apex Legends\n155.133.248.120 52.2961 4.9549 NL 1794416301\n73.12.44.9 1 1 US 1794416301\n"])
        w.writerow(["2026/11/12 1:05:00 AM GMT-5", "hello, not a file"])
        w.writerow(["2026/11/12 1:09:00 AM GMT-5", "lobbyfence-servers 1\r\ngame fortnite Fortnite\r\n3.120.9.10 50.11 8.68 DE 1794416301\r\n155.133.248.120 52.2961 4.9549 NL 1794416301\r\n"])
    r = run(str(resp))
    after2 = (d / "files/usr/share/lobbyfence/servers.txt").read_text()
    new2 = [l for l in after2.splitlines() if l not in after.splitlines()]
    check("a form's answers file: every answer holding a servers file is read, other answers skipped",
          r.returncode == 0 and "responses.csv answer 1:" in r.stdout and "responses.csv answer 3:" in r.stdout
          and "answer 2" not in r.stdout, r.stdout)
    check("from the answers only the new data-centre servers go in, under their game",
          sorted(new2) == sorted(["155.133.248.120 52.2961 4.9549 NL 1794416301", "3.120.9.10 50.11 8.68 DE 1794416301",
                                  "155.133.248.120 52.2961 4.9549 NL 1794416301"])   # once per game: Apex and Fortnite
          and "73.12.44.9" not in after2, new2)
    check("it says to delete the answers afterwards", "Delete all responses" in r.stdout, r.stdout)
    r = run()
    check("without files it explains how to use it", r.returncode == 2 and "responses.csv" in r.stdout, r.stdout[-300:])
    import ipaddress
    nets = [ipaddress.ip_network(c) for c in " ".join(l.split("#")[0] for l in (d / "tools/server-networks.txt").read_text().splitlines()).split()]
    check("every address in the merged list is in a data-centre network",
          all(any(ipaddress.ip_address(l.split()[0]) in n for n in nets) for l in after2.splitlines()
              if l and l[0].isdigit()))

print("ALL TESTS PASSED" if not fails else f"{fails} FAILED")
sys.exit(1 if fails else 0)
