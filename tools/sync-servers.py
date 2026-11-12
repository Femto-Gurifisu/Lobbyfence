#!/usr/bin/env python3
"""Merge shared servers files into the list LobbyFence comes with.

People send their routers' game servers with Servers file -> Send to LobbyFence
on the map page: a GitHub report ("Servers: ...", label "servers") with the file
attached or pasted. This reads those reports (or files you give it), checks every
line and adds the new servers to files/usr/share/lobbyfence/servers.txt.

  tools/sync-servers.py                 open "Servers:" reports on GitHub (needs gh)
  tools/sync-servers.py FILE...         files you downloaded yourself ("-" = stdin)
  tools/sync-servers.py --dry-run ...   only report what would be added
  tools/sync-servers.py --close ...     afterwards, thank and close the reports read

Only servers for listed client-server games (not peer-to-peer ones, "Any game" or
Custom), inside the data-centre networks of tools/server-networks.txt, with a
sane location, are taken - so no player's own address gets into the list. An
address already listed for that game is left as it is. Run
python3 tests/safety_static.py afterwards, then commit.
"""
import ipaddress
import json
import pathlib
import re
import subprocess
import sys
import time
import urllib.request

REPO = pathlib.Path(__file__).resolve().parent.parent
LIST = REPO / "files/usr/share/lobbyfence/servers.txt"
MAPJS = REPO / "luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js"
NETS = REPO / "tools/server-networks.txt"
GH_REPO = "Femto-Gurifisu/Lobbyfence"
ATTACH = re.compile(r"https://github\.com/(?:user-attachments/files|[\w.-]+/[\w.-]+/files)/[\w./%-]+")


def networks():
    text = " ".join(l.split("#")[0] for l in NETS.read_text().splitlines())
    return [ipaddress.ip_network(c) for c in text.split()]


def games():
    """{id: label} for the games whose servers may be shared, read from map.js"""
    js = MAPJS.read_text()
    p2p = re.search(r"var P2P_GAMES = \[([^\]]*)\]", js)
    p2p = set(re.findall(r"'([a-z0-9_]+)'", p2p.group(1))) if p2p else set()
    out = {}
    for m in re.finditer(r"\{ id: '([a-z0-9_]+)', group: '([a-z]+)', label: (?:_\()?'((?:[^'\\]|\\.)*)'", js):
        gid, group, label = m.group(1), m.group(2), m.group(3).replace("\\'", "'")
        if group in ("pc", "mobile") and gid not in p2p:
            out[gid] = label
    return out


def read_list():
    """the built-in list as [lines], {(game, address)}, {game: index of its last line}"""
    lines = LIST.read_text().split("\n")
    have, end, g = set(), {}, None
    for i, l in enumerate(lines):
        t = l.split()
        if t[:1] == ["game"] and len(t) > 1:
            g = t[1]
            end[g] = i
        elif t and not t[0].startswith("#") and t[0] != "lobbyfence-servers" and g:
            have.add((g, t[0]))
            end[g] = i
    return lines, have, end


def parse(text, ok_games, nets, now):
    """[(game, line)] that pass every check, and a list of reasons for what didn't"""
    rows, skipped, g = [], [], None
    if not re.search(r"^lobbyfence-servers 1\r?$", text, re.M):
        return rows, ["not a LobbyFence servers file"]
    for l in text.splitlines():
        t = l.strip().split()
        if not t or t[0].startswith("#") or t[0] == "lobbyfence-servers":
            continue
        if t[0] == "game":
            g = t[1] if len(t) > 1 and t[1] in ok_games else False
            if g is False:
                skipped.append(f"game {t[1] if len(t) > 1 else '?'}: not a listed client-server game")
            continue
        if not g:
            continue
        why = None
        try:
            a = ipaddress.ip_address(t[0])
            if not any(a in n for n in nets):
                why = "not in a known game-server network"
        except ValueError:
            why = "not an address"
        if not why:
            try:
                lat, lon, cc, seen = float(t[1]), float(t[2]), t[3], int(t[4])
                if abs(lat) > 90 or abs(lon) > 180 or not re.fullmatch(r"[A-Z]{2}|--", cc):
                    why = "bad location"
                elif seen > now + 86400 or seen < 1_500_000_000:
                    why = "bad time"
            except (IndexError, ValueError):
                why = "bad line"
        if why:
            skipped.append(f"{t[0]} ({g}): {why}")
            continue
        rows.append((g, f"{t[0]} {float(t[1]):g} {float(t[2]):g} {t[3]} {int(t[4])}"))
    return rows, skipped


def gh(*args):
    return subprocess.run(["gh", *args], check=True, capture_output=True, text=True).stdout


def reports():
    """open reports titled "Servers:" (or labelled servers): [(number, text of their files)]"""
    out = []
    data = json.loads(gh("issue", "list", "-R", GH_REPO, "--state", "open", "--limit", "200",
                         "--json", "number,title,body,labels"))
    for it in data:
        if not (it["title"].startswith("Servers:") or any(l["name"] == "servers" for l in it["labels"])):
            continue
        texts = [it["body"] or ""]
        for url in ATTACH.findall(it["body"] or ""):
            try:
                with urllib.request.urlopen(url, timeout=30) as r:
                    texts.append(r.read(2_000_000).decode("utf-8", "replace"))
            except Exception as e:
                print(f"#{it['number']}: could not download {url}: {e}", file=sys.stderr)
        # a pasted file sits in the body, maybe inside a ``` block
        out.append((it["number"], "\n".join(t.replace("```", "") for t in texts)))
    return out


def main(argv):
    dry = "--dry-run" in argv
    close = "--close" in argv
    files = [a for a in argv if not a.startswith("--")]
    ok_games, nets, now = games(), networks(), int(time.time())
    sources = []
    if files:
        for f in files:
            sources.append((f, sys.stdin.read() if f == "-" else pathlib.Path(f).read_text(errors="replace")))
    else:
        sources = [(f"#{n}", t) for n, t in reports()]
        if not sources:
            print("no open Servers: reports")
            return 0

    lines, have, end = read_list()
    new = {}            # game -> [lines]
    for name, text in sources:
        rows, skipped = parse(text, ok_games, nets, now)
        added = 0
        for g, row in rows:
            key = (g, row.split()[0])
            if key in have:
                continue
            have.add(key)
            new.setdefault(g, []).append(row)
            added += 1
        print(f"{name}: {len(rows)} server(s) checked, {added} new, {len(skipped)} left out")
        for s in skipped[:20]:
            print(f"   left out: {s}")
        if len(skipped) > 20:
            print(f"   ... and {len(skipped) - 20} more")

    total = sum(len(v) for v in new.values())
    for g, rows in sorted(new.items()):
        print(f"  {g}: +{len(rows)}")
    if dry or not total:
        print(f"{total} new server(s)" + (" - nothing written (--dry-run)" if dry and total else ""))
    else:
        # each game's new servers after its last line; a game not in the list yet goes at the end
        for g in sorted(new, key=lambda g: -end.get(g, len(lines))):
            if g in end:
                i = end[g] + 1
                lines[i:i] = new[g]
            else:
                while lines and lines[-1] == "":
                    lines.pop()
                lines += [f"game {g} {ok_games[g]}"] + new[g] + [""]
        LIST.write_text("\n".join(lines))
        print(f"{total} new server(s) written to {LIST.relative_to(REPO)} - now run python3 tests/safety_static.py and commit")
    if close and not files and not dry:
        for name, _ in sources:
            gh("issue", "close", name.lstrip("#"), "-R", GH_REPO, "--comment",
               "Thanks! The new servers in this report are in the list LobbyFence comes with from the next version on.")
            print(f"closed {name}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
