"""What Merlin's web server does when LobbyFence's page sends a request:
writes the add-on settings (httpd's write_custom_settings: the page's whole
object, "key value" lines) and runs the service-event script, then waits for
the answer file - the same steps and chunking as lf-merlin.js.

  merlin_page.py send <text> [chunk size]     -> prints the final answer (JSON)
  merlin_page.py ops '<json list of page changes>' [chunk size]
                                              -> "apply" with those changes, like Save & Apply
  merlin_page.py event <service>              -> just the event (no settings)
Environment: LF_CUSTOM_SETTINGS, LF_RUN, MERLIN_SCRIPTS (the /jffs/scripts dir)
"""
import json
import os
import random
import subprocess
import sys
import time
import urllib.parse

CS = os.environ["LF_CUSTOM_SETTINGS"]
DATA = os.path.join(os.environ["LF_RUN"], "web")
SCRIPTS = os.environ["MERLIN_SCRIPTS"]


def pct(s):
    q = urllib.parse.quote(s, safe="")
    return q.replace("~", "~")


def others():
    out = {}
    try:
        for line in open(CS, encoding="utf-8", errors="replace"):
            line = line.rstrip("\n")
            i = line.find(" ")
            if i > 0 and line[:i] != "lobbyfence_cmd":
                out[line[:i]] = line[i + 1:]
    except FileNotFoundError:
        pass
    return out


def write_custom_settings(obj):
    # httpd: json -> "key value\n" per entry, the whole file replaced
    with open(CS, "w") as f:
        for k, v in obj.items():
            line = "%s %s\n" % (k, v)
            f.write(line[:3039])


def event(service):
    subprocess.run(["/bin/sh", os.path.join(SCRIPTS, "service-event"), "restart", service], timeout=120)


def wait(rid, part, last, timeout):
    end = time.time() + timeout
    path = os.path.join(DATA, "res-%s.json" % rid)
    while time.time() < end:
        try:
            d = json.load(open(path))
            if d.get("error") or d.get("done"):
                return d
            if not last and d.get("ack", 0) >= part:
                return d
        except (FileNotFoundError, ValueError):
            pass
        time.sleep(0.2)
    return {"timeout": True}


def send(text, size=2400):
    rid = "t%x%04d" % (int(time.time() * 1000), random.randint(0, 9999))
    data = pct(text)
    parts, i = [], 0
    while i < len(data):
        n = min(size, len(data) - i)
        if i + n < len(data):
            p = data.rfind("%", i, i + n)
            if p > i + n - 3:
                n = p - i
        parts.append(data[i:i + n])
        i += n
    if not parts:
        parts = [""]
    for k, part in enumerate(parts):
        s = others()
        s["lobbyfence_cmd"] = "%s %d/%d %s" % (rid, k + 1, len(parts), part)
        write_custom_settings(s)
        event("lobbyfence")
        last = k == len(parts) - 1
        d = wait(rid, k + 1, last, 120 if last else 20)
        if last or d.get("error") or d.get("timeout"):
            d["parts"] = len(parts)
            return d
    return {}


def ops_text(ops):
    # the same lines lf-merlin.js builds (each field %-encoded, tab-separated)
    lines = []
    for o in ops:
        if o[0] == "set":
            f = ["list", o[1], o[2]] + o[3] if isinstance(o[3], list) else ["set", o[1], o[2], o[3]]
        elif o[0] == "unset":
            f = ["unset", o[1], o[2]]
        elif o[0] == "add":
            f = ["add", o[1], o[2]]
        elif o[0] == "remove":
            f = ["remove", o[1]]
        else:
            continue
        lines.append("\t".join(pct(str(x)) for x in f))
    return "\n".join(lines)


if __name__ == "__main__":
    if sys.argv[1] == "ops":
        print(json.dumps(send("apply\n" + ops_text(json.loads(sys.argv[2])), int(sys.argv[3]) if len(sys.argv) > 3 else 2400)))
    elif sys.argv[1] == "send":
        print(json.dumps(send(sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 2400)))
    elif sys.argv[1] == "event":
        event(sys.argv[2])
