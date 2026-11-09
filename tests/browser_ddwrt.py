"""The DD-WRT page in headless Chromium, end to end. Runs on the LAN side (in
the LAN network namespace set up by ddwrt_browser_test.sh): the browser talks
to LobbyFence's real lighttpd on the router (192.168.1.1:8055). DD-WRT's own
web server (port 80) is played here: its Status > My Page runs LobbyFence's
mypage.sh, as DD-WRT's httpd does for a signed-in user.
    usage: python3 browser_ddwrt.py <workdir> <router-ns-pid> <maplibre dist> [screenshot dir]
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
SHOTS = pathlib.Path(sys.argv[4]) if len(sys.argv) > 4 else None
ENV = dict(line.split("=", 1) for line in (l.replace("export ", "", 1).strip() for l in (W / "env.sh").read_text().splitlines())
           if "=" in line and not line.startswith("unset"))
ENV = {k: v.strip('"') for k, v in ENV.items()}
HOME = pathlib.Path(ENV["LF_HOME"])
RUN = pathlib.Path(ENV["LF_RUN"])
LF = "http://192.168.1.1:8055"
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


def inr(*cmd, data=None):
    env = ["env", "PATH=" + ENV["TPATH"], "LF_HOME=" + str(HOME), "LF_RUN=" + str(RUN)]
    return subprocess.run(["nsenter", "-t", RTR, "-n", "-m"] + env + list(cmd), input=data, capture_output=True, timeout=60)


def wait_applied(page, timeout=25000):
    try:
        page.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=timeout)
        return True
    except Exception:
        return False


def main():
    errs = []
    token = (HOME / ".webtoken").read_text().strip()

    def ddwrt_httpd(route):
        path = route.request.url.split("http://192.168.1.1", 1)[1]
        if path.startswith("/MyPage.asp"):
            r = inr(str(HOME / "mypage.sh"))
            return route.fulfill(content_type="text/html", body=b"<html><body><h1>DD-WRT</h1>" + r.stdout + b"</body></html>")
        return route.fulfill(content_type="text/html", body="<html><body>DD-WRT control panel</body></html>")

    def dist(route):
        f = DIST / route.request.url.split("/dist/")[1].split("?")[0]
        route.fulfill(status=200 if f.exists() else 404, body=f.read_bytes() if f.exists() else b"",
                      content_type="text/css" if f.suffix == ".css" else "text/javascript", headers={"Access-Control-Allow-Origin": "*"})

    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = b.new_context(viewport={"width": 1300, "height": 950})
        ctx.route(re.compile(r"^http://192\.168\.1\.1(/.*)?$"), ddwrt_httpd)     # port 80 only: DD-WRT's own pages
        ctx.route("https://unpkg.com/maplibre-gl@*/dist/*", dist)
        ctx.route("https://tiles.openfreemap.org/styles/positron", lambda r: r.fulfill(content_type="application/json",
                  body=json.dumps({"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background"}]}), headers={"Access-Control-Allow-Origin": "*"}))
        ctx.route("https://**", lambda r: r.abort() if "unpkg.com" not in r.request.url and "openfreemap.org/styles" not in r.request.url else r.fallback())
        ctx.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", lambda r: r.fulfill(content_type="application/json", body='{"tag_name": "v1.1.0"}', headers={"Access-Control-Allow-Origin": "*"}))   # (the page asks GitHub for the newest version)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errs.append("page: " + str(e)))
        page.on("console", lambda m: m.type == "error" and errs.append("console: " + m.text))

        # ---------------------------------------------------- not signed in yet
        page.goto(LF + "/")
        page.wait_for_selector("#lf-signin", timeout=15000)
        link = page.locator("#lf-signin a").get_attribute("href")
        check("without the token: the page says to open it from Status > My Page (link to the router's page)",
              link == "http://192.168.1.1/MyPage.asp" and not page.locator("#lf-footer").is_visible(), link)

        # ---------------------------------------------- Status > My Page -> LobbyFence
        page.goto("http://192.168.1.1/MyPage.asp")
        try:
            page.wait_for_url(LF + "/#map", timeout=15000)
            ok = True
        except Exception:
            ok = False
        check("Status > My Page sends the browser on to LobbyFence; the token leaves the address bar", ok, page.url)
        stored = page.evaluate("localStorage.getItem('lf-token')")
        check("the token is kept in this browser", stored == token, stored)
        try:
            page.wait_for_function("document.querySelector('.lf-app') && document.querySelector('.maplibregl-canvas')", timeout=40000)
            ok = True
        except Exception:
            ok = False
        check("map page renders (same map.js as OpenWrt, real MapLibre, through lighttpd)", ok, errs[:4])
        if not ok:
            b.close()
            return
        page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=20000)
        panel = page.locator(".lf-panel").inner_text()
        check("router status through the CGI: running, game packets counted", "Running" in panel and re.search(r"Game packets: [1-9]", panel), panel[:300])
        page.locator(".lf-search select").last.select_option("all")
        page.wait_for_function("document.querySelectorAll('.lf-row').length >= 1", timeout=10000)
        inside = page.locator(".lf-list").inner_text()
        page.locator(".lf-tabs [data-tab=out]").click()
        page.wait_for_function("document.querySelector('.lf-list') && document.querySelector('.lf-list').innerText.includes('80.20.0.1')", timeout=10000)
        outside = page.locator(".lf-list").inner_text()
        check("servers learned by the router listed (45.10.0.1 inside, 80.20.0.1 outside)", "45.10.0.1" in inside and "80.20.0.1" in outside, [inside[:200], outside[:200]])
        if SHOTS:
            page.screenshot(path=str(SHOTS / "ddwrt-map.png"))

        man = ctx.new_cdp_session(page).send("Page.getAppManifest")
        mj = json.loads(man.get("data") or "{}")
        icon = page.evaluate("fetch('/lobbyfence/icon-512.png').then(r => r.blob()).then(createImageBitmap).then(b => b.width)")
        check("home-screen app: manifest read without errors, icons served", not man.get("errors") and mj.get("start_url") == "/?app=1" and icon == 512,
              [man.get("errors"), (man.get("data") or "")[:160], icon])

        # always allow a server: live, through the CGI
        page.locator(".lf-row", has_text="80.20.0.1").first.click()
        page.locator(".maplibregl-popup").get_by_role("button", name="Always allow").first.click()
        page.wait_for_timeout(1500)
        conf = (HOME / "lobbyfence.conf").read_text()
        r = inr(str(W / "bin/ipset"), "test", "lf_game_fa4", "80.20.0.1")
        check("Always allow: saved on the router and in the firewall at once", "allow_ip '80.20.0.1'" in conf and r.returncode == 0, [conf[-200:], r.stderr])

        # draw a circle, Save & Apply
        page.get_by_role("button", name="Add circle").click()
        box = page.locator(".maplibregl-canvas").bounding_box()
        page.mouse.click(box["x"] + box["width"] * 0.3, box["y"] + box["height"] * 0.6)
        page.wait_for_timeout(2500)
        staged = (RUN / "staged.conf").read_text() if (RUN / "staged.conf").exists() else ""
        check("a new circle is kept on the router, not applied yet", staged.count("list circle") == 2, staged[-300:])
        page.locator("#lf-apply").click()
        ok = wait_applied(page)
        conf = (HOME / "lobbyfence.conf").read_text()
        check("Save & Apply: saved, applied, confirmed (the web server survives the restart it runs)",
              ok and conf.count("list circle") == 2 and not (RUN / "staged.conf").exists(), conf[-300:])
        page.wait_for_timeout(2500)

        # coming back later without the # token: remembered
        page.goto(LF + "/")
        try:
            page.wait_for_function("document.querySelector('.lf-app') && document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        check("opened again later (bookmark / home-screen icon): no sign-in needed", ok and page.locator("#lf-signin").count() == 0)

        # signed in back when LobbyFence was called RegionGate: still signed in
        page.evaluate("([t]) => { localStorage.removeItem('lf-token'); localStorage.setItem('rg-token', t); }", [token])
        page.goto(LF + "/?renamed=1")
        try:
            page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        check("signed in under the old name (RegionGate): still signed in, the token kept under the new name",
              ok and page.locator("#lf-signin").count() == 0 and page.evaluate("localStorage.getItem('lf-token')") == token
              and page.evaluate("localStorage.getItem('rg-token')") is None)

        # Settings tab
        page.locator("a.lft-tab[data-tab=settings]").click()
        page.wait_for_selector(".lfs", timeout=15000)
        txt = page.locator(".lfs").inner_text()
        check("Settings tab: general settings and the zone", "Enable LobbyFence" in txt and "Game" in txt, txt[:200])
        sel = page.locator("[data-zone=game] [data-row=device] select")
        if not sel.count() or not page.locator("[data-zone=game] textarea[data-opt=device]").is_visible():
            page.locator("[data-zone=game] .lfs-zhead").click()
        opts = sel.locator("option").all_inner_texts()
        check("device suggestions from DD-WRT's DHCP leases; a host name with HTML is cleaned, never run",
              any("Console - 192.168.1.100" in o and "<" not in o for o in opts) and page.evaluate("window.__xss") is None, opts)
        page.locator("[data-section=globals] input[data-opt=interval]").fill("25")
        page.wait_for_timeout(1500)
        page.locator("#lf-apply").click()
        ok = wait_applied(page)
        check("Settings: Save & Apply puts the change into effect", ok and "option interval '25'" in (HOME / "lobbyfence.conf").read_text())

        # SFE fast path on: the map page explains it with DD-WRT's own words
        (W / "nvram/sfe").write_text("1\n")
        inr(str(HOME / "lobbyfence"), "status")
        page.goto(LF + "/#map")
        page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('SFE')", timeout=30000)
        panel = page.locator(".lf-panel").inner_text()
        check("SFE on: the map says what it means and where to switch it", "Shortcut Forwarding Engine" in panel, panel[:400])
        (W / "nvram/sfe").write_text("2\n")

        # the Debug section: a crash on record shows in Status; the report is made on the
        # router, gets this browser's part, and downloads as a file
        import time as _t
        (HOME / "data").mkdir(exist_ok=True)
        (HOME / "data/crash.log").write_text("=== crash %d test\nwhat: test crash record\nlast step: testing\n" % int(_t.time()))
        inr(str(HOME / "lobbyfence"), "status")
        page.goto(LF + "/#map")
        page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('stopped unexpectedly')", timeout=30000)
        check("a recorded crash shows in Status with a way to the details", page.locator(".lf-problem .lf-link").count() == 1,
              page.locator(".lf-panel").inner_text()[:400])
        page.evaluate("setTimeout(function() { Promise.reject(new Error('test-rejection-xyz')); }, 0)")
        page.wait_for_timeout(300)
        page.locator(".lf-debugbtn").click()
        try:
            page.wait_for_function("document.querySelector('.lf-debug-state') && /^Ready/.test(document.querySelector('.lf-debug-state').textContent)", timeout=40000)
            ok = True
        except Exception:
            ok = False
        txt = page.evaluate("document.querySelector('.lf-debug-text') ? document.querySelector('.lf-debug-text').value : ''")
        check("Debug: the report is made on the router and shown", ok and txt.startswith("LobbyFence debug report") and "==== DD-WRT" in txt and "test crash record" in txt, txt[:300])
        check("Debug: this browser's part (page, problems seen here), no sign-in token",
              "==== This browser" in txt and "page: http://192.168.1.1:8055/" in txt and "test-rejection-xyz" in txt and token not in txt, txt[-1200:])
        if SHOTS:
            page.screenshot(path=str(SHOTS / "ddwrt-debug.png"))
        with page.expect_download(timeout=10000) as dl:
            page.locator(".lf-debug-dl").click()
        d = dl.value
        body = pathlib.Path(d.path()).read_text()
        check("Download report: a .txt file named by router type and time, the whole report",
              re.fullmatch(r"lobbyfence-debug-ddwrt-\d{8}-\d{4}\.txt", d.suggested_filename) and body == txt, d.suggested_filename)
        page.locator(".lf-debug-clear").click()
        page.wait_for_function("/cleared/.test(document.querySelector('.lf-debug-state').textContent)", timeout=20000)
        check("Clear crash records: gone on the router", not (HOME / "data/crash.log").exists())
        page.get_by_role("button", name="Close").click()

        # borderless covers the page's Reset / Save / Save & Apply at the bottom: the
        # toolbar has them then (and only then), and they work
        check("toolbar save buttons hidden normally (the page's own are visible)", not page.locator(".lf-savebar").is_visible())
        page.get_by_role("button", name="View ▾").click()
        page.locator(".lf-menu").get_by_text("Borderless").click()
        page.keyboard.press("Escape")
        page.wait_for_timeout(500)
        foot = page.locator("#lf-apply").bounding_box()
        covered = page.evaluate("([x, y]) => { const e = document.elementFromPoint(x, y); return !e || !e.closest('#lf-apply'); }",
                                [foot["x"] + foot["width"] / 2, foot["y"] + foot["height"] / 2]) if foot else True
        check("borderless: the toolbar shows Reset / Save / Save & Apply (the page's own are covered)",
              page.locator(".lf-savebar").is_visible() and covered and page.locator(".lf-savebar button").count() == 3)
        before = (HOME / "lobbyfence.conf").read_text()
        page.locator(".lf-seg [data-mode=monitor]").click()
        page.wait_for_timeout(2000)
        page.locator(".lf-savebtn-apply").click()
        ok = wait_applied(page)
        conf = (HOME / "lobbyfence.conf").read_text()
        check("borderless: the toolbar's Save & Apply saves and applies", ok and "option mode 'monitor'" in conf and conf != before, conf[-300:])
        page.wait_for_timeout(2500)
        page.wait_for_function("document.querySelector('.lf-app.lf-borderless') && document.querySelector('.lf-seg')", timeout=30000)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "ddwrt-borderless-save.png"))
        page.locator(".lf-seg [data-mode=enforce]").click()
        page.wait_for_timeout(1500)
        page.locator(".lf-savebtn-apply").click()
        wait_applied(page)
        page.wait_for_timeout(2500)
        page.wait_for_function("document.querySelector('.lf-app.lf-borderless')", timeout=30000)
        page.keyboard.press("Escape")
        page.wait_for_timeout(300)
        check("borderless off: the toolbar buttons go away again", page.locator(".lf-app.lf-borderless").count() == 0 and not page.locator(".lf-savebar").is_visible())

        # a new token (lobbyfence newtoken): this browser is signed out, My Page signs it in again
        inr(str(HOME / "lobbyfence"), "newtoken")
        # an open page notices at its next request ...
        try:
            page.wait_for_selector("#lf-signin", timeout=15000)
            ok = True
        except Exception:
            ok = False
        check("after a new token: an open page switches to 'open it from My Page'", ok and page.evaluate("localStorage.getItem('lf-token')") is None,
              page.locator("body").inner_text()[:200])
        # ... and so does one opened later
        page.goto(LF + "/?later=1")
        try:
            page.wait_for_selector("#lf-signin", timeout=15000)
            ok = True
        except Exception:
            ok = False
        check("...and one opened later", ok)
        page.goto("http://192.168.1.1/MyPage.asp")
        try:
            page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        check("...and works again after that", ok)

        # the phone layout: the home-screen tip
        ph = b.new_context(viewport={"width": 390, "height": 844}, is_mobile=True, has_touch=True, device_scale_factor=3,
                           user_agent="Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36")
        ph.route("https://unpkg.com/maplibre-gl@*/dist/*", dist)
        ph.route("https://tiles.openfreemap.org/styles/positron", lambda r: r.fulfill(content_type="application/json",
                 body=json.dumps({"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background"}]}), headers={"Access-Control-Allow-Origin": "*"}))
        ph.route("https://**", lambda r: r.abort() if "unpkg.com" not in r.request.url and "openfreemap.org/styles" not in r.request.url else r.fallback())
        ph.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", lambda r: r.fulfill(content_type="application/json", body='{"tag_name": "v1.1.0"}', headers={"Access-Control-Allow-Origin": "*"}))   # (the page asks GitHub for the newest version)
        pp = ph.new_page()
        pp.goto(LF + "/#t=" + (HOME / ".webtoken").read_text().strip())
        try:
            pp.wait_for_selector("#lf-install", timeout=20000)
            ok = True
        except Exception:
            ok = False
        try:
            pp.wait_for_function("document.querySelector('.lf-app') && document.querySelector('.maplibregl-canvas')", timeout=40000)
            ok2 = True
        except Exception:
            ok2 = False
        check("on a phone: the map in the phone layout and the 'add to home screen' tip", ok and ok2)
        if SHOTS:
            pp.screenshot(path=str(SHOTS / "ddwrt-phone.png"))
        # the Debug window on a phone: fits the screen, report ready
        try:
            pp.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=30000)
            pp.locator(".lf-debugbtn").scroll_into_view_if_needed()
            pp.locator(".lf-debugbtn").tap()
            pp.wait_for_function("document.querySelector('.lf-debug-state') && /^Ready/.test(document.querySelector('.lf-debug-state').textContent)", timeout=40000)
            ok = True
        except Exception:
            ok = False
        fit = pp.evaluate("""() => { const m = document.querySelector('#modal_overlay .modal'), t = document.querySelector('.lf-debug-text'), d = document.querySelector('.lf-debug-dl');
            const r = m.getBoundingClientRect(), rt = t.getBoundingClientRect(), rd = d.getBoundingClientRect();
            return [r.left >= 0 && r.right <= innerWidth && rt.right <= r.right && rd.right <= innerWidth && document.documentElement.scrollWidth <= innerWidth, r.width, rd.right, innerWidth]; }""")
        check("on a phone: the Debug window fits the screen, report ready", ok and fit[0], fit)
        if SHOTS:
            pp.screenshot(path=str(SHOTS / "ddwrt-phone-debug.png"))
        ph.close()

        real = [e for e in errs if "favicon" not in e and "404" not in e and "401" not in e and "test-rejection-xyz" not in e]
        check("no JavaScript errors", not real, real[:6])
        b.close()


if __name__ == "__main__":
    main()
    print("ALL DD-WRT BROWSER TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
    sys.exit(0 if all(results) else 1)
