"""The FreshTomato pages in headless Chromium, end to end: the browser talks to
the real CGI, which runs the real router script in the router namespace set up
by tomato_browser_test.sh (FreshTomato's BusyBox, ipset, legacy iptables).
    usage: python3 browser_tomato.py <workdir> <router-ns-pid> <maplibre dist> <tomato.js> <tomato.css> [screenshot dir]
"""
import json
import pathlib
import re
import subprocess
import sys

from playwright.sync_api import sync_playwright

W = pathlib.Path(sys.argv[1])
RTR = sys.argv[2]
DIST = pathlib.Path(sys.argv[3])
TOMATO_JS = pathlib.Path(sys.argv[4])
TOMATO_CSS = pathlib.Path(sys.argv[5])
SHOTS = pathlib.Path(sys.argv[6]) if len(sys.argv) > 6 else None
ENV = dict(line.split("=", 1) for line in (l.replace("export ", "", 1).strip() for l in (W / "env.sh").read_text().splitlines())
           if "=" in line and not line.startswith("unset"))
ENV = {k: v.strip('"') for k, v in ENV.items()}
HOME = pathlib.Path(ENV["LF_HOME"])
RUN = pathlib.Path(ENV["LF_RUN"])
WWWEXT = pathlib.Path(ENV["LF_WWWEXT"])
TOKEN = (W / "nvram/http_id").read_text().strip()
results = []
cgi_log = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


def inr(*cmd, data=None):
    env = ["env", "PATH=" + ENV["TPATH"], "LF_HOME=" + str(HOME), "LF_RUN=" + str(RUN), "LF_NVRAM=" + ENV["LF_NVRAM"],
           "LF_LEASES=" + ENV["LF_LEASES"], "LF_IPV6=0", "LF_WWWEXT=" + str(WWWEXT)]
    return subprocess.run(["nsenter", "-t", RTR, "-n", "-m"] + env + list(cmd), input=data, capture_output=True, timeout=60)


def asp(text):
    """what FreshTomato's web server does with <% ... %>"""
    def rep(m):
        e = m.group(1).strip()
        if e.startswith("nvram("):
            return "\nnvram = {\n\t'http_id': '%s',\n\t'lan_ipaddr': '192.168.1.1',\n\t'web_mx': '',\n\t'wl_unit': '0'};\n" % TOKEN
        if e.startswith("ident("):
            return "router"
        if e.startswith("version("):
            return "2026.1"
        if e.startswith("nv("):
            return "Asus RT-AC68U"
        return ""
    return re.sub(r"<%(.*?)%>", rep, text, flags=re.S)


def main():
    errs = []

    def site(route):
        req = route.request
        path = req.url.split("http://router.test", 1)[1].split("?")[0].split("#")[0]
        if path == "/ext/cgi-bin/lobbyfence.cgi":
            body = req.post_data_buffer or b""
            cgi_log.append(body.split(b"\n")[1].decode() if b"\n" in body else "")
            r = inr(str(WWWEXT / "cgi-bin/lobbyfence.cgi"), data=body + b"\n")
            return route.fulfill(status=200, content_type="text/html", body=r.stdout)
        if path == "/tomato.js":
            return route.fulfill(content_type="text/javascript", body=TOMATO_JS.read_bytes())
        if path == "/tomato.css":
            return route.fulfill(content_type="text/css", body=TOMATO_CSS.read_bytes())
        if path.startswith("/ext/"):
            f = WWWEXT / path[len("/ext/"):]
            if not f.exists():
                return route.fulfill(status=404, body="")
            if f.suffix == ".asp":
                return route.fulfill(content_type="text/html", body=asp(f.read_text()))
            # (FreshTomato's httpd: .js, .png, .txt by their type; no .json)
            ctype = {".js": "text/javascript", ".png": "image/png", ".txt": "text/plain"}.get(f.suffix, "application/octet-stream")
            return route.fulfill(content_type=ctype, body=f.read_bytes())
        return route.fulfill(status=404, body="")

    def dist(route):
        f = DIST / route.request.url.split("/dist/")[1].split("?")[0]
        route.fulfill(status=200 if f.exists() else 404, body=f.read_bytes() if f.exists() else b"",
                      content_type="text/css" if f.suffix == ".css" else "text/javascript", headers={"Access-Control-Allow-Origin": "*"})

    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1300, "height": 950})
        ctx.route("http://router.test/**", site)
        ctx.route("https://unpkg.com/maplibre-gl@*/dist/*", dist)
        ctx.route("https://tiles.openfreemap.org/styles/positron", lambda r: r.fulfill(content_type="application/json",
                  body=json.dumps({"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background"}]}), headers={"Access-Control-Allow-Origin": "*"}))
        ctx.route("https://**", lambda r: r.abort() if "unpkg.com" not in r.request.url and "openfreemap.org/styles" not in r.request.url else r.fallback())
        page = ctx.new_page()
        page.on("pageerror", lambda e: errs.append("page: " + str(e)))
        page.on("console", lambda m: m.type == "error" and errs.append("console: " + m.text))

        # ---------------------------------------------------------- outer page
        page.goto("http://router.test/ext/lobbyfence.asp")
        page.wait_for_selector("#navi a", timeout=15000)
        nav = page.locator("#navi").inner_text()
        check("FreshTomato frame: menu drawn by the firmware's own tomato.js", "Administration" in nav and "Status" in nav, nav[:200])
        check("FreshTomato menu has the LobbyFence entry (added at start)", page.locator("#navi a[href='ext/lobbyfence.asp']").count() == 1, nav[-200:])
        fr = page.frame_locator("#lf-frame")
        frame = None
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
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        ap = ctx.new_page()
        ap.goto("http://router.test/ext/lobbyfence/app.asp")
        ap.wait_for_selector(".lf-app", timeout=30000)
        man = ctx.new_cdp_session(ap).send("Page.getAppManifest")
        mj = json.loads(man.get("data") or "{}")
        icon = ap.evaluate("fetch('/ext/lobbyfence/icon-512.png').then(r => r.blob()).then(createImageBitmap).then(b => b.width)")
        check("home-screen app: manifest (a .txt - FreshTomato serves no .json) read without errors, icons served",
              not man.get("errors") and mj.get("start_url") == "/ext/lobbyfence/app.asp?app=1" and mj.get("display") == "standalone" and icon == 512,
              [man.get("errors"), (man.get("data") or "")[:160], icon])
        check("on a computer: no 'add to home screen' tip", ap.locator("#lf-install").count() == 0)
        ap.close()
        check("on a computer: no 'phone layout' link above the map", page.locator("#lf-phone").count() == 1 and not page.locator("#lf-phone").is_visible())
        check("the map frame is clean (tomato.js's Array changes not in it)", frame.evaluate("typeof Array.prototype.remove") == "undefined"
              and page.evaluate("typeof Array.prototype.remove") == "function")
        frame.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=20000)
        panel = fr.locator(".lf-panel").inner_text()
        check("router status through the CGI: running, game packets counted", "Running" in panel and re.search(r"Game packets: [1-9]", panel), panel[:300])
        check("lag panel hidden when the router has no netem for its kernel", fr.locator(".lf-lag").count() == 0 or not fr.locator(".lf-lag").first.is_visible())
        fr.locator(".lf-search select").last.select_option("all")
        frame.wait_for_function("document.querySelectorAll('.lf-row').length >= 1", timeout=10000)
        inside = fr.locator(".lf-list").inner_text()
        fr.locator(".lf-tabs [data-tab=out]").click()
        frame.wait_for_function("document.querySelector('.lf-list') && document.querySelector('.lf-list').innerText.includes('80.20.0.1')", timeout=10000)
        outside = fr.locator(".lf-list").inner_text()
        check("servers learned by the router listed (45.10.0.1 inside, 80.20.0.1 outside)", "45.10.0.1" in inside and "80.20.0.1" in outside, [inside[:200], outside[:200]])
        if SHOTS:
            page.screenshot(path=str(SHOTS / "tomato-map.png"))

        # always allow a server from the list: live, through the CGI
        fr.locator(".lf-row", has_text="80.20.0.1").first.click()
        fr.locator(".maplibregl-popup").get_by_role("button", name="Always allow").first.click()
        page.wait_for_timeout(1500)
        conf = (HOME / "lobbyfence.conf").read_text()
        r = inr(str(W / "bin/ipset"), "test", "lf_game_fa4", "80.20.0.1")
        check("Always allow: saved on the router and in the firewall at once", "allow_ip '80.20.0.1'" in conf and r.returncode == 0, [conf[-200:], r.stderr])

        # draw a circle: kept on the router (staged), then Save & Apply
        fr.get_by_role("button", name="Add circle").click()
        box = fr.locator(".maplibregl-canvas").bounding_box()
        page.mouse.click(box["x"] + box["width"] * 0.3, box["y"] + box["height"] * 0.6)
        page.wait_for_timeout(2500)
        staged = (RUN / "staged.conf").read_text() if (RUN / "staged.conf").exists() else ""
        check("a new circle is kept on the router, not applied yet", staged.count("list circle") == 2 and (HOME / "lobbyfence.conf").read_text().count("list circle") == 1, staged[-300:])
        check("the page shows that changes wait to be applied", frame.locator("#lf-changes").is_visible())
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=20000)
            ok = True
        except Exception:
            ok = False
        conf = (HOME / "lobbyfence.conf").read_text()
        check("Save & Apply: saved, applied, confirmed", ok and conf.count("list circle") == 2 and not (RUN / "staged.conf").exists(), conf[-300:])
        check("the earlier Always allow survives the page's Save & Apply", "allow_ip '80.20.0.1'" in conf, conf[-300:])
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.wait_for_function("document.querySelector('.lf-app')", timeout=20000)

        # Settings tab
        frame.locator("a.lft-tab[data-tab=settings]").click()
        page.wait_for_timeout(1500)
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lfs", timeout=15000)
        txt = frame.locator(".lfs").inner_text()
        check("Settings tab: general settings and the zone", "Enable LobbyFence" in txt and "Game" in txt, txt[:200])
        iv = frame.locator("[data-section=globals] input[data-opt=interval]")
        iv.fill("abc")
        page.wait_for_timeout(1200)
        check("a wrong value is marked and not kept", "cbi-input-invalid" in (iv.get_attribute("class") or "") and not (RUN / "staged.conf").exists())
        iv.fill("30")
        page.wait_for_timeout(1500)
        staged = (RUN / "staged.conf").read_text() if (RUN / "staged.conf").exists() else ""
        check("a good value is kept on the router", "option interval '30'" in staged, staged[:300])
        frame.locator("[data-zone=game] .lfs-zhead").click() if not frame.locator("[data-zone=game] textarea[data-opt=device]").is_visible() else None
        dv = frame.locator("[data-zone=game] textarea[data-opt=device]")
        sel = frame.locator("[data-zone=game] [data-row=device] select")
        opts = sel.locator("option").all_inner_texts()
        check("device suggestions from the router; a host name with HTML is cleaned, never run", any("Console - 192.168.1.100" in o and "<" not in o for o in opts)
              and frame.evaluate("window.__xss") is None and frame.locator("[data-row=device] img").count() == 0, opts)
        frame.locator("#lf-reset").click()
        page.wait_for_timeout(2500)
        check("Reset throws the waiting change away", not (RUN / "staged.conf").exists() and "option interval '30'" not in (HOME / "lobbyfence.conf").read_text())
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lfs", timeout=15000)
        frame.locator("[data-section=globals] input[data-opt=interval]").fill("25")
        page.wait_for_timeout(1500)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=20000)
            ok = True
        except Exception:
            ok = False
        check("Settings: Save & Apply puts the change into effect", ok and "option interval '25'" in (HOME / "lobbyfence.conf").read_text())
        if SHOTS:
            page.screenshot(path=str(SHOTS / "tomato-settings.png"), full_page=True)

        # a new zone from the map's game list: id short enough for ipset / iptables
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.locator("a.lft-tab[data-tab=map]").click()
        page.wait_for_timeout(1500)
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lf-app", timeout=20000)
        fr = page.frame_locator("#lf-frame")
        fr.locator(".lf-bar").get_by_role("button", name="New zone…").click()
        modal = fr.locator(".modal")
        modal.locator("select").first.select_option("apex")
        modal.locator(".lf-nz-platform").select_option("pc")
        page.wait_for_timeout(300)
        modal.get_by_role("button", name="Create zone").click()
        page.wait_for_timeout(2500)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=25000)
            ok = True
        except Exception:
            ok = False
        conf = (HOME / "lobbyfence.conf").read_text()
        m = re.search(r"config zone '(apex[a-z0-9_]*)'", conf)
        zid = m.group(1) if m else ""
        r = inr(str(W / "bin/iptables"), "-n", "-L", "LF_%s_o4" % zid)
        check("new zone from a game preset: short id, its firewall rules loaded", ok and zid and len(zid) <= 12 and r.returncode == 0, [zid, r.stderr[-200:]])

        # "Any mobile game": TCP 443 + mobile game ports, starts in Enforce
        page.wait_for_timeout(2500)
        frame = page.frame(url=re.compile(r".*/ext/lobbyfence/app\.asp.*"))
        frame.wait_for_selector(".lf-app", timeout=20000)
        fr = page.frame_locator("#lf-frame")
        fr.locator(".lf-bar").get_by_role("button", name="New zone…").click()
        modal = fr.locator(".modal")
        modal.locator("select").first.select_option("any_mobile")
        page.wait_for_timeout(300)
        sels = modal.locator("select")
        vals = [sels.nth(i).input_value() for i in range(sels.count())]
        ins = modal.locator("input")
        texts = [ins.nth(i).input_value() for i in range(ins.count())]
        info = modal.inner_text()
        check("New zone: Any mobile game fills in TCP, port 443 and the game ports, Enforce mode, and says what it does to apps",
              "tcp" in vals and "enforce" in vals and "strict" not in vals[1:]
              and any(t.startswith("443 ") and "65010" in t for t in texts) and "won't load" in info, [vals, texts, info[:300]])
        modal.get_by_role("button", name="Create zone").click()
        page.wait_for_timeout(2500)
        frame.locator("#lf-apply").click()
        try:
            frame.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=25000)
            ok = True
        except Exception:
            ok = False
        conf = (HOME / "lobbyfence.conf").read_text()
        m = re.search(r"config zone '(mobile[a-z0-9_]*)'(.*?)(?=\nconfig |\Z)", conf, re.S)
        zid, body = (m.group(1), m.group(2)) if m else ("", "")
        r = inr(str(W / "bin/iptables"), "-S", "LF_%s_po4" % zid)
        check("mobile zone saved (TCP, 443, Enforce, strict off) and its TCP rules loaded",
              ok and "option proto 'tcp'" in body and "list remote_port '443'" in body and "option strict '0'" in body
              and "option mode 'enforce'" in body and b"-p tcp -m multiport --dports 443," in r.stdout, [zid, body[:400], r.stdout[:300]])

        # a page from another web site can't use the CGI (no session token)
        r = inr(str(WWWEXT / "cgi-bin/lobbyfence.cgi"), data=b"\nexec block game 45.10.0.1\n")
        check("CGI without the page's token does nothing", b"error" in r.stdout and "45.10.0.1" not in (HOME / "lobbyfence.conf").read_text().split("block_ip")[-1][:30])

        real = [e for e in errs if "favicon" not in e and "404" not in e]
        check("no JavaScript errors", not real, real[:6])
        b.close()


if __name__ == "__main__":
    main()
    print("ALL TOMATO BROWSER TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
    sys.exit(0 if all(results) else 1)
