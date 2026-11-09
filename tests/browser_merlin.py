"""The Asuswrt-Merlin pages in headless Chromium, end to end. A stand-in for
Merlin's web server does what the real one does: serves /www/user files with
"<% %>" processing (do_ej) on .asp/.js/.json, and on POST /start_apply.htm
writes the add-on settings from amng_custom (the whole file, like
write_custom_settings) and runs /jffs/scripts/service-event for the
action_script - in the router namespace set up by merlin_browser_test.sh,
where the real LobbyFence scripts run on Merlin's BusyBox.
    usage: python3 browser_merlin.py <workdir> <router-ns-pid> <maplibre dist> [screenshot dir]
"""
import json
import pathlib
import re
import subprocess
import sys
import threading
import urllib.parse

from playwright.sync_api import sync_playwright

W = pathlib.Path(sys.argv[1])
RTR = sys.argv[2]
DIST = pathlib.Path(sys.argv[3])
SHOTS = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
ENV = dict(line.split("=", 1) for line in (l.replace("export ", "", 1).strip() for l in (W / "env.sh").read_text().splitlines())
           if "=" in line and not line.startswith("unset"))
ENV = {k: v.strip('"') for k, v in ENV.items()}
HOME = pathlib.Path(ENV["LF_HOME"])
RUN = pathlib.Path(ENV["LF_RUN"])
WWWUSER = pathlib.Path(ENV["LF_WWWUSER"])
CS = pathlib.Path(ENV["LF_CUSTOM_SETTINGS"])
PAGE = (RUN / "webui_page").read_text().strip()
results = []
applies = []
events = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


def inr(*cmd, data=None, timeout=150):
    env = ["env"] + ["%s=%s" % (k, v) for k, v in ENV.items() if k.startswith("LF_")] + ["PATH=" + ENV["TPATH"]]
    return subprocess.run(["nsenter", "-t", RTR, "-n", "-m"] + env + list(cmd), input=data, capture_output=True, timeout=timeout)


def custom_settings_obj():
    # httpd's get_custom_settings: "%29s %2999s" per line (a value stops at its first space)
    o = {}
    if CS.exists():
        for line in CS.read_text().splitlines():
            p = line.split()
            if len(p) >= 2:
                o[p[0][:29]] = p[1][:2999]
    return o


def do_ej(text):
    """what Merlin's web server does with <% ... %> in .asp / .js / .json / .htm"""
    def rep(m):
        e = m.group(1).strip()
        if e.startswith("get_custom_settings"):
            return json.dumps(custom_settings_obj())
        mm = re.match(r'nvram_get\("([^"]*)"\)', e)
        if mm:
            return {"preferred_lang": "EN", "firmver": "3.0.0.6"}.get(mm.group(1), "")
        return ""
    return re.sub(r"<%(.*?)%>", rep, text, flags=re.S)


def write_custom_settings(js):
    obj = json.loads(js)
    with open(CS, "w") as f:
        for k, v in obj.items():
            f.write(("%s %s\n" % (k, v))[:3039])


def rc_event(service):
    # rc runs the service-event script after httpd answered
    events.append(service)
    inr("/bin/sh", str(W / "jffs/scripts/service-event"), "restart", service)


STUB_GENERAL = """
function show_menu() {
  var x = new XMLHttpRequest(); x.open('GET', '/require/modules/menuTree.js', false); x.send();
  var m = /\\{url: "(user[0-9]+\\.asp)", tabName: "LobbyFence"\\}/.exec(x.responseText);
  document.getElementById('mainMenu').innerHTML = m ? '<a id="menu-lf" href="/' + m[1] + '">Administration &gt; LobbyFence</a>' : 'no LobbyFence entry';
}
"""


def router_context(b, **opts):
    """a browser context whose http://router.test/ is the stand-in for Merlin's web server"""
    def site(route):
        req = route.request
        url = urllib.parse.urlsplit(req.url)
        path = url.path
        if path == "/start_apply.htm" and req.method == "POST":
            form = dict(urllib.parse.parse_qsl(req.post_data or "", keep_blank_values=True))
            applies.append(form)
            if "amng_custom" in form:
                write_custom_settings(form["amng_custom"])
            for s in (form.get("action_script") or "").split(";"):
                m = re.match(r"(?:re)?start_(\w+)$", s.strip())
                if m:
                    threading.Thread(target=rc_event, args=(m.group(1),), daemon=True).start()
            return route.fulfill(status=200, content_type="text/html", body="<script>done_committing();</script>")
        if path in ("/state.js", "/popup.js", "/help.js", "/validator.js"):
            return route.fulfill(content_type="text/javascript", body="")
        if path == "/general.js":
            return route.fulfill(content_type="text/javascript", body=STUB_GENERAL)
        if path == "/require/modules/menuTree.js":
            r = inr("cat", ENV["LF_MENU_JS"])     # the copy laid over it (only visible in the router)
            return route.fulfill(content_type="text/javascript", body=r.stdout)
        if path == "/" + PAGE:
            f = WWWUSER / PAGE
        elif path.startswith("/user/"):
            f = WWWUSER / path[len("/user/"):]
        else:
            return route.fulfill(status=404, body="")
        if not f.exists():
            return route.fulfill(status=404, body="")
        ext = f.suffix
        body = f.read_bytes()
        if ext in (".asp", ".js", ".json", ".htm"):
            body = do_ej(body.decode("utf-8", "replace")).encode()
        ctype = {".asp": "text/html", ".htm": "text/html", ".js": "text/javascript", ".json": "application/json",
             ".png": "image/png", ".svg": "image/svg+xml"}.get(ext, "application/octet-stream")
        return route.fulfill(content_type=ctype, body=body)

    def dist(route):
        f = DIST / route.request.url.split("/dist/")[1].split("?")[0]
        route.fulfill(status=200 if f.exists() else 404, body=f.read_bytes() if f.exists() else b"",
                      content_type="text/css" if f.suffix == ".css" else "text/javascript", headers={"Access-Control-Allow-Origin": "*"})

    ctx = b.new_context(**opts)
    ctx.route("http://router.test/**", site)
    ctx.route("https://unpkg.com/maplibre-gl@*/dist/*", dist)
    ctx.route("https://tiles.openfreemap.org/styles/positron", lambda r: r.fulfill(content_type="application/json",
              body=json.dumps({"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background"}]}), headers={"Access-Control-Allow-Origin": "*"}))
    ctx.route("https://**", lambda r: r.abort() if "unpkg.com" not in r.request.url and "openfreemap.org/styles" not in r.request.url else r.fallback())
    ctx.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", lambda r: r.fulfill(content_type="application/json", body='{"tag_name": "v1.1.0"}', headers={"Access-Control-Allow-Origin": "*"}))   # (the page asks GitHub for the newest version)
    return ctx


def main():
    errs = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = router_context(b, viewport={"width": 1300, "height": 1100})
        page = ctx.new_page()
        page.on("pageerror", lambda e: errs.append("page: " + str(e)))
        page.on("console", lambda m: m.type == "error" and errs.append("console: " + m.text))

        # ---------------------------------------------------------- outer page
        page.goto("http://router.test/" + PAGE)
        page.wait_for_selector("#mainMenu", timeout=15000)
        check("Merlin frame: the add-on page, with the LobbyFence tab under Administration (menuTree.js laid over)",
              page.locator("#menu-lf").count() == 1 and page.locator("#menu-lf").get_attribute("href") == "/" + PAGE, page.locator("#mainMenu").inner_text())
        fr = page.frame_locator("#lf-frame")
        try:
            page.wait_for_function("""() => { const f = document.getElementById('lf-frame'); const d = f && f.contentDocument;
                return d && d.querySelector('.lf-app') && d.querySelector('.maplibregl-canvas'); }""", timeout=40000)
            ok = True
        except Exception:
            ok = False
        check("map page renders in the frame (same map.js as OpenWrt, real MapLibre)", ok, errs[:4])
        if not ok:
            b.close()
            return
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=20000)
        panel = fr.locator(".lf-panel").inner_text()
        check("router status from the page's data files: running, game packets counted", "Running" in panel and re.search(r"Game packets: [1-9]", panel), panel[:300])
        check("lag panel offered (lf-lagd on this router)", fr.locator(".lf-lag").count() > 0 and fr.locator(".lf-lag").first.is_visible())
        fr.locator(".lf-search select").last.select_option("all")
        frame.wait_for_function("document.querySelectorAll('.lf-row').length >= 1", timeout=10000)
        inside = fr.locator(".lf-list").inner_text()
        fr.locator(".lf-tabs [data-tab=out]").click()
        frame.wait_for_function("document.querySelector('.lf-list') && document.querySelector('.lf-list').innerText.includes('80.20.0.1')", timeout=10000)
        outside = fr.locator(".lf-list").inner_text()
        check("servers learned by the router listed (45.10.0.1 inside, 80.20.0.1 outside)", "45.10.0.1" in inside and "80.20.0.1" in outside, [inside[:200], outside[:200]])
        page.wait_for_timeout(4000)
        check("live data for the map from the file the router keeps fresh - the page sends no requests while just watching",
              (RUN / "web/live.json").exists() and not applies and not events, [events, applies[:2]])
        if SHOTS:
            page.screenshot(path=str(SHOTS / "merlin-map.png"))

        # always allow a server from the list: live, through the add-on API
        n_before = len(applies)
        fr.locator(".lf-row", has_text="80.20.0.1").first.click()
        fr.locator(".maplibregl-popup").get_by_role("button", name="Always allow").first.click()
        frame.wait_for_function("1", timeout=1000)
        ok = False
        for _ in range(40):
            page.wait_for_timeout(250)
            # (the settings are written a moment before the firewall set, in the same step)
            if "allow_ip '80.20.0.1'" in (HOME / "lobbyfence.conf").read_text() and \
                    inr(str(W / "bin/ipset"), "test", "lf_game_fa4", "80.20.0.1").returncode == 0:
                ok = True
                break
        r = inr(str(W / "bin/ipset"), "test", "lf_game_fa4", "80.20.0.1")
        check("Always allow: saved on the router and in the firewall at once (add-on settings + service-event)", ok and r.returncode == 0, r.stderr)
        cs = CS.read_text()
        check("the other add-on's settings untouched (spaces too), LobbyFence's request taken out",
              "other_title Other Addon 1.2\n" in cs and "other_mode fast\n" in cs and "lobbyfence_cmd" not in cs, cs)
        check("each request carries the add-on settings (amng_custom)", any("amng_custom" in a for a in applies[n_before:]))

        # draw a circle: kept in the browser until Save & Apply
        fr.get_by_role("button", name="Add circle").click()
        box = fr.locator(".maplibregl-canvas").bounding_box()
        page.mouse.click(box["x"] + box["width"] * 0.3, box["y"] + box["height"] * 0.6)
        page.wait_for_timeout(2500)
        check("a new circle waits in the browser, the router's settings unchanged",
              (HOME / "lobbyfence.conf").read_text().count("list circle") == 1 and "circle" in (frame.evaluate("localStorage.getItem('lobbyfence.pending')") or ""))
        check("the page shows that changes wait to be applied", frame.locator("#lf-changes").is_visible())
        # a change waiting since before the rename (kept under the old name, RegionGate): still there after a reload
        frame.evaluate("localStorage.setItem('regiongate.pending', localStorage.getItem('lobbyfence.pending')); localStorage.removeItem('lobbyfence.pending')")
        page.reload()
        try:
            page.wait_for_function("""() => { const f = document.getElementById('lf-frame'); const d = f && f.contentDocument;
                return d && d.querySelector('.lf-app') && d.querySelector('.maplibregl-canvas'); }""", timeout=40000)
            frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
            frame.wait_for_function("document.getElementById('lf-changes') && document.getElementById('lf-changes').offsetParent !== null", timeout=20000)
            ok = True
        except Exception:
            ok = False
        check("a change waiting under the old name (RegionGate) is still waiting after the rename",
              ok and "circle" in (frame.evaluate("localStorage.getItem('lobbyfence.pending')") or "")
              and frame.evaluate("localStorage.getItem('regiongate.pending')") is None)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=60000)
            ok = True
        except Exception:
            ok = False
        conf = (HOME / "lobbyfence.conf").read_text()
        check("Save & Apply: sent, applied, confirmed", ok and conf.count("list circle") == 2, conf[-300:])
        check("the earlier Always allow survives the page's Save & Apply", "allow_ip '80.20.0.1'" in conf, conf[-300:])
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.wait_for_function("document.querySelector('.lf-app')", timeout=20000)
        check("nothing waiting any more after Apply", not frame.evaluate("localStorage.getItem('lobbyfence.pending')"))

        # Settings tab
        frame.locator("a.lft-tab[data-tab=settings]").click()
        page.wait_for_timeout(1500)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lfs", timeout=15000)
        txt = frame.locator(".lfs").inner_text()
        check("Settings tab: general settings and the zone", "Enable LobbyFence" in txt and "Game" in txt, txt[:200])
        check("data directory hint is Merlin's", frame.locator("[data-section=globals] input[data-opt=data_dir]").get_attribute("placeholder") == "/jffs/addons/lobbyfence/data")
        iv = frame.locator("[data-section=globals] input[data-opt=interval]")
        iv.fill("30")
        page.wait_for_timeout(1500)
        frame.locator("#lf-reset").click()
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lfs", timeout=15000)
        check("Reset throws the waiting change away", not frame.evaluate("localStorage.getItem('lobbyfence.pending')")
              and frame.locator("[data-section=globals] input[data-opt=interval]").input_value() != "30")
        frame.locator("[data-section=globals] input[data-opt=interval]").fill("25")
        page.wait_for_timeout(1500)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=60000)
            ok = True
        except Exception:
            ok = False
        check("Settings: Save & Apply puts the change into effect", ok and "option interval '25'" in (HOME / "lobbyfence.conf").read_text())
        if SHOTS:
            page.screenshot(path=str(SHOTS / "merlin-settings.png"), full_page=True)

        # lag simulator from the map
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.locator("a.lft-tab[data-tab=map]").click()
        page.wait_for_timeout(1500)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lf-lag", timeout=20000)
        fr = page.frame_locator("#lf-frame")
        fr.locator(".lf-lag input[type=checkbox]").first.check()
        page.wait_for_timeout(500)
        d = fr.locator(".lf-lag .lf-lag-lag_delay")
        d.fill("80")
        d.dispatch_event("change")
        page.wait_for_timeout(1500)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=60000)
            ok = True
        except Exception:
            ok = False
        page.wait_for_timeout(3000)
        frame = page.frame(url=re.compile(r".*/user/lobbyfence/app\.asp.*"))
        try:
            frame.wait_for_function("document.querySelector('.lf-lag') && document.querySelector('.lf-lag').innerText.includes('Active') && document.querySelector('.lf-lag').innerText.includes('lf-lagd')", timeout=30000)
            act = True
        except Exception:
            act = False
        check("lag simulator switched on from the map: lf-lagd running, the map says Active (· lf-lagd)", ok and act and inr("pidof", "lf-lagd").returncode == 0,
              frame.locator(".lf-lag").inner_text()[:300] if frame.locator(".lf-lag").count() else "")
        if SHOTS:
            page.screenshot(path=str(SHOTS / "merlin-lag.png"))

        # served data never contains "<%" (Merlin's web server would run it)
        bad = [f.name for f in (RUN / "web").iterdir() if f.is_file() and "<%" in f.read_text(errors="replace")]
        check("no '<%' in any file the page loads", not bad and "<%" not in (RUN / "status.json").read_text(), bad)

        real = [e for e in errs if "favicon" not in e and "404" not in e and "Not Found" not in e]
        check("no JavaScript errors", not real, real[:6])
        b.close()


if __name__ == "__main__":
    main()
    print("ALL MERLIN BROWSER TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
    sys.exit(0 if all(results) else 1)
