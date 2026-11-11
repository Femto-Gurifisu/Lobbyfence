"""The Map page inside the REAL LuCI JavaScript framework with the REAL MapLibre
build: drawing, the side panel and saving go through LuCI's own uci/rpc/fs code
to a ubus API played by this script.
    usage: python3 browser_real_luci_map.py <luci resources dir> <maplibre dist dir> [screenshot-dir]
"""
import json
import pathlib
import sys

from playwright.sync_api import sync_playwright

LUCI = pathlib.Path(sys.argv[1])
DIST = pathlib.Path(sys.argv[2])
SHOTS = pathlib.Path(sys.argv[3]) if len(sys.argv) > 3 else None
VIEWS = pathlib.Path(__file__).resolve().parent.parent / "luci-app-lobbyfence/htdocs/luci-static/resources/view"
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>LuCI</title>
<style>.hidden{display:none}</style></head>
<body><header><a class="brand" href="/">OpenWrt</a></header><div id="maincontent"><div id="view"><div class="spinning">Loading view…</div></div></div>
<script src="/luci-static/resources/cbi.js"></script>
<script src="/luci-static/resources/luci.js"></script>
<script>
L = new LuCI({
  media: '/luci-static/bootstrap', resource: '/luci-static/resources', scriptname: '/cgi-bin/luci',
  pathinfo: '/admin/services/lobbyfence/map', documentroot: '/www', requestpath: ['admin','services','lobbyfence','map'],
  dispatchpath: ['admin','services','lobbyfence','map'], ubuspath: '/ubus/', sessionid: 'deadbeef',
  token: 'tok', nodespec: { satisfied: true, readonly: false }, apply_rollback: 90, apply_holdoff: 4, apply_timeout: 5, apply_display: 1.5, rollback_token: null,
  pollinterval: 5
});
L.require('ui').then(function(ui) { return ui.instantiateView('lobbyfence/map'); });
</script></body></html>"""

STATUS = {"version": "1.0.0", "enabled": True, "active": True, "updated": 1700000500, "interval": 20, "tc": True, "pkg": "apk",
          "geo": {"last_ok": 1700000400, "pending": 0, "error": ""},
          "zones": [{"id": "game", "label": "Game", "enabled": True, "mode": "enforce", "strict": True, "region": True, "servers": 2,
                     "inside": 1, "outside": 1, "pending": 0, "unlocatable": 0, "packets": 10, "blocked": 1, "devices": ["192.168.1.23"],
                     "macs": 0, "allow": [], "block": [], "rev": 1, "lag": {"on": False, "dir": "both", "delay": 0, "jitter": 0, "loss": 0, "active": False, "error": ""},
                     "burst": 0, "burst_open": 20, "open_left": 0, "opened": 0}]}
CONFIG = {
    "globals": {".anonymous": False, ".type": "globals", ".name": "globals", ".index": 0, "enabled": "1", "interval": "20"},
    "game": {".anonymous": False, ".type": "zone", ".name": "game", ".index": 1, "enabled": "1", "label": "Game",
             "mode": "enforce", "strict": "1", "device": ["192.168.1.23"], "remote_port": ["1024-65535"], "proto": "udp",
             "circle": ["50.1109,8.6821,800"]},
}


def main():
    calls, errs = [], []
    state = {"config": json.loads(json.dumps(CONFIG)), "sets": []}

    def ubus(route):
        body = json.loads(route.request.post_data or "null")
        reqs = body if isinstance(body, list) else [body]
        out = []
        for m in reqs:
            if m.get("method") == "list":
                out.append({"jsonrpc": "2.0", "id": m.get("id"), "result": {}})
                continue
            _sid, obj, meth, args = m["params"]
            calls.append((obj, meth))
            res = {}
            if (obj, meth) == ("session", "access"):
                res = {"access": True}
            elif (obj, meth) == ("uci", "get"):
                res = {"values": state["config"]} if args.get("config") == "lobbyfence" else {"values": {}}
            elif (obj, meth) == ("uci", "changes"):
                res = {"changes": {}}
            elif (obj, meth) == ("uci", "set"):
                state["sets"].append(args)
                sec = state["config"].setdefault(args["section"], {})
                sec.update(args.get("values", {}))
            elif (obj, meth) == ("uci", "delete"):
                state["sets"].append({"delete": args})
                if not args.get("options"):
                    state["config"].pop(args.get("section"), None)
            elif (obj, meth) == ("uci", "add"):
                state["sets"].append({"add": args})
                name = args.get("name") or "cfg%02x" % len(state["config"])
                state["config"][name] = dict(args.get("values", {}), **{".type": args.get("type"), ".name": name, ".anonymous": not args.get("name"), ".index": len(state["config"])})
                res = {"section": name}
            elif (obj, meth) == ("file", "exec"):
                cmd = args.get("params") or []
                if cmd[:1] in (["allow"], ["block"], ["unlist"]):
                    act, ips = cmd[0], cmd[2:]
                    rules = state.setdefault("rules", {"allow": [], "block": []})
                    for ip in ips:
                        for k in ("allow", "block"):
                            if ip in rules[k]:
                                rules[k].remove(ip)
                        if act != "unlist":
                            rules[act].append(ip)
                    state.setdefault("execs", []).append(cmd)
                    res = {"code": 0, "stdout": json.dumps({"ok": True, "allow": rules["allow"], "block": rules["block"]})}
                elif cmd[:1] == ["live"]:
                    res = {"code": 0, "stdout": json.dumps({"time": 1700000500, "zones": {"game": {"active": {}, "rate": {}, "active_window": 15, "packets": 10, "blocked": 1, "open_left": 0, "opened": 0}}})}
                else:
                    res = {"code": 0, "stdout": json.dumps([{"mac": "aa:bb:cc:dd:ee:01", "name": "Phone", "ipv4": ["192.168.1.23"], "ipv6": []}])}
            elif (obj, meth) == ("file", "read"):
                pth = args.get("path", "")
                if pth.endswith("status.json"):
                    res = {"data": json.dumps(STATUS)}
                elif pth.endswith("game.servers"):
                    state.setdefault("server_reads", []).append(pth)
                    res = {"data": "45.10.0.1 in 50.11 8.68 DE 1700000000\n80.20.0.1 out 40.71 -74.0 US 1700000100\n"}
                else:
                    res = None
            elif (obj, meth) == ("service", "list"):
                res = {"lobbyfence": {"instances": {"i": {"running": True}}}}
            elif obj == "luci-rpc":
                # a device on the LAN can name itself anything (DHCP host name)
                res = {"aa:bb:cc:dd:ee:66": {"name": "<img src=x onerror=window.__xss2=1>Evil-TV", "ipaddrs": ["192.168.1.66"], "ip6addrs": []}} if meth == "getHostHints" else {}
            elif (obj, meth) == ("file", "list"):
                res = {"entries": []}
            elif obj == "luci" and meth == "getFeatures":
                res = {}
            out.append({"jsonrpc": "2.0", "id": m.get("id"), "result": [0, res] if res is not None else [4]})
        route.fulfill(content_type="application/json", body=json.dumps(out if isinstance(body, list) else out[0]))

    def static(route):
        url = route.request.url.split("?")[0]
        rel = url.split("/luci-static/resources/", 1)[1]
        f = (VIEWS / rel[len("view/"):]) if rel.startswith("view/") else (LUCI / rel)
        if not f.exists():
            return route.fulfill(status=404, body="")
        route.fulfill(content_type="text/javascript" if rel.endswith(".js") else "application/octet-stream", body=f.read_bytes())

    with sync_playwright() as p:
        b = p.chromium.launch()
        page = b.new_page(viewport={"width": 1300, "height": 900})
        page.on("pageerror", lambda e: errs.append(str(e)))
        page.on("console", lambda m: m.type == "error" and errs.append(m.text))
        REPO = pathlib.Path(__file__).resolve().parent.parent
        APPFILES = {"manifest.json": REPO / "luci-app-lobbyfence/htdocs/luci-static/lobbyfence/manifest.json",
                    "lf-app.js": REPO / "freshtomato/www/lobbyfence/lf-app.js"}
        def appfile(route):
            n = route.request.url.split("/luci-static/lobbyfence/")[1].split("?")[0]
            f = APPFILES.get(n, REPO / "app-icon" / n)
            ct = {"json": "application/manifest+json", "js": "text/javascript", "png": "image/png"}.get(n.rsplit(".", 1)[-1], "text/plain")
            route.fulfill(status=200 if f.exists() else 404, content_type=ct, body=f.read_bytes() if f.exists() else b"")
        apply_log, apply_seq = [], []
        def routes(pg, html=None):
            pg.route("http://router.test/cgi-bin/luci/admin/services/lobbyfence/map*", lambda r: r.fulfill(content_type="text/html", body=html or PAGE))
            pg.route("http://router.test/luci-static/resources/**", static)
            pg.route("http://router.test/luci-static/lobbyfence/**", appfile)
            pg.route("http://router.test/ubus/**", ubus)
            def uci_http(route):
                kind = route.request.url.split("/admin/uci/")[1].split("?")[0]
                apply_log.append(kind)
                if kind == "apply_rollback":
                    apply_seq.append(len(state["sets"]))
                    route.fulfill(status=200, content_type="application/json", body=json.dumps({"token": "t0k"}))
                else:
                    route.fulfill(status=204, body="")
            pg.route("http://router.test/cgi-bin/luci/admin/uci/**", uci_http)
            pg.route("http://router.test/cgi-bin/cgi-exec*", lambda r: r.fulfill(status=200, body=""))   # LuCI's reachability probe
            def dist(route):
                f = DIST / route.request.url.split("/dist/")[1].split("?")[0]
                route.fulfill(status=200 if f.exists() else 404, body=f.read_bytes() if f.exists() else b"",
                              content_type="text/css" if f.suffix == ".css" else "text/javascript", headers={"Access-Control-Allow-Origin": "*"})
            pg.route("https://unpkg.com/maplibre-gl@*/dist/*", dist)
            pg.route("https://tiles.openfreemap.org/styles/positron", lambda r: r.fulfill(content_type="application/json",
                       body=json.dumps({"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background"}]}), headers={"Access-Control-Allow-Origin": "*"}))
            pg.route("https://**", lambda r: r.abort() if "unpkg.com" not in r.request.url and "openfreemap.org/styles" not in r.request.url else r.fallback())
            pg.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", lambda r: r.fulfill(content_type="application/json", body='{"tag_name": "v1.1.0"}', headers={"Access-Control-Allow-Origin": "*"}))   # (the page asks GitHub for the newest version)
            pg.route("http://router.test/cgi-bin/luci/admin/translations/**", lambda r: r.fulfill(content_type="text/javascript", body=""))
        routes(page)
        page.goto("http://router.test/cgi-bin/luci/admin/services/lobbyfence/map")
        b2 = b  # noqa
        try:
            page.wait_for_function("document.querySelector('.lf-app') && document.querySelector('.maplibregl-canvas')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        check("real LuCI + MapLibre: the map page renders", ok, errs[:4])
        if not ok:
            b.close()
            return
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('Running')", timeout=15000)
        check("real LuCI: router status shown (file read + service list through ubus)", "Game packets: 10" in page.locator(".lf-panel").inner_text())
        # the (possibly large) server list is only downloaded when its revision changes
        n0 = len(state.get("server_reads", []))
        page.evaluate("""() => L.require('view.lobbyfence.map').then(v => { window.__draws = 0; const d = v.drawServers;
            v.drawServers = function() { window.__draws++; return d.apply(this, arguments); };
            return v.refresh().then(() => v.refresh()).then(() => v.refresh()); })""")
        check("real LuCI: nothing changed -> the map is not redrawn", page.evaluate("window.__draws") <= 1, page.evaluate("window.__draws"))
        page.wait_for_timeout(300)
        check("real LuCI: unchanged server list is not downloaded again", len(state.get("server_reads", [])) == n0, [n0, len(state.get("server_reads", []))])
        page.evaluate("window.__draws = 0")
        STATUS["zones"][0]["rev"] = 2
        page.evaluate("() => L.require('view.lobbyfence.map').then(v => v.refresh())")
        page.wait_for_timeout(300)
        check("real LuCI: ...and is redrawn when the list changes", page.evaluate("window.__draws") >= 1)
        check("real LuCI: a new revision is downloaded once", len(state.get("server_reads", [])) == n0 + 1, [n0, len(state.get("server_reads", []))])
        page.locator(".lf-search select").last.select_option("all")
        page.wait_for_timeout(300)
        check("real LuCI: servers listed", page.locator(".lf-row").count() >= 1)
        page.wait_for_function("document.querySelector('.lf-lag') && document.querySelector('.lf-lag').textContent.includes('Lag simulator')", timeout=10000)
        page.locator(".lf-lag .lf-switch input").check()
        page.wait_for_timeout(600)          # the save of the switch is now on its way (router answers slowly)
        page.locator(".lf-lag-lag_delay").fill("80"); page.locator(".lf-lag-lag_delay").dispatch_event("change")
        page.get_by_role("button", name="Add circle").click()
        canvas = page.locator(".maplibregl-canvas").bounding_box()
        page.mouse.click(canvas["x"] + canvas["width"] * 0.3, canvas["y"] + canvas["height"] * 0.6)
        page.wait_for_timeout(5000)
        saved = {}
        for s_ in state["sets"]:
            if s_.get("section") == "game":
                saved.update(s_.get("values", {}))
        check("real LuCI: lag settings staged to the router", saved.get("lag") == "1" and saved.get("lag_delay") == "80", saved)
        circles = saved.get("circle")
        check("real LuCI: a new circle is staged to the router", isinstance(circles, list) and len(circles) == 2, circles)
        check("real LuCI: LuCI's change list refreshed (uci changes asked)", ("uci", "changes") in calls)
        # the race itself: a setting changed while a save is still waiting for the router
        page.evaluate("""() => Promise.all([ L.require('uci'), L.require('view.lobbyfence.map') ]).then(([ uci, v ]) => {
            uci.set('lobbyfence', 'game', 'lag_jitter', '7');
            v.stage(true);                                   /* save starts, router not answered yet */
            return new Promise((ok) => setTimeout(ok, 5)).then(() => {
                uci.set('lobbyfence', 'game', 'lag_loss', '2');  /* ...edit while it is on its way */
                v.stage();
            });
        })""")
        page.wait_for_timeout(3000)
        saved = {}
        for s_ in state["sets"]:
            if s_.get("section") == "game":
                saved.update(s_.get("values", {}))
        check("real LuCI: a setting changed during a save still reaches the router", saved.get("lag_jitter") == "7" and saved.get("lag_loss") == "2", saved)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-luci-map.png"))
        # whitelist / blacklist window: add, upload, download - live on the router
        page.locator(".lf-panel").get_by_role("button", name="Manage lists…").click()
        lm = page.locator(".modal")
        lm.locator("textarea").fill("80.20.0.1, not-an-ip\n2a00:1450::/32")
        lm.get_by_role("button", name="Add to whitelist").click()
        page.wait_for_timeout(800)
        check("real LuCI: lists window adds addresses on the router", ["allow", "game", "80.20.0.1", "2a00:1450::/32"] in state.get("execs", []), state.get("execs"))
        check("real LuCI: ...shows them and says what was skipped", lm.get_by_text("80.20.0.1").is_visible() and lm.get_by_text("1 entries were not addresses", exact=False).is_visible())
        with page.expect_download() as dl:
            lm.get_by_role("button", name="Download").click()
        text = pathlib.Path(dl.value.path()).read_text()
        check("real LuCI: download gives a shareable list", "80.20.0.1" in text and "2a00:1450::/32" in text and dl.value.suggested_filename == "lobbyfence-game-whitelist.txt",
              [dl.value.suggested_filename, text[:120]])
        lm.locator("li.tabmenu-item-block a").click()
        up = pathlib.Path(SHOTS or "/tmp") / "lf-upload.txt"
        up.write_text("# from a friend\n99.1.1.1\n99.1.1.2 # relay\n")
        lm.locator("input[type=file]").set_input_files(str(up))
        page.wait_for_timeout(800)
        check("real LuCI: uploading a list blocks those servers", ["block", "game", "99.1.1.1", "99.1.1.2"] in state.get("execs", []), state.get("execs"))
        lm.get_by_role("button", name="Close").click()
        check("real LuCI: panel counts the lists", "Whitelist: 2 · Blacklist: 2" in page.locator(".lf-panel").inner_text(), page.locator(".lf-panel").inner_text()[-300:])

        # home: type a ZIP, pick the suggestion -> saved and drawn as a pin on the real map
        def photon(route):
            route.fulfill(content_type="application/json", headers={"Access-Control-Allow-Origin": "*"}, body=json.dumps({"type": "FeatureCollection", "features": [
                {"geometry": {"coordinates": [-71.0, 42.41]}, "properties": {"postcode": "02151", "name": "<img src=x onerror=window.__xss=1>Revere", "city": "Revere", "state": "Massachusetts", "country": "United States"}}]}))
        page.route("https://photon.komoot.io/**", photon)
        page.route("https://nominatim.openstreetmap.org/**", lambda r: r.fulfill(content_type="application/json", headers={"Access-Control-Allow-Origin": "*"}, body="[]"))
        page.locator(".lf-bar").get_by_role("button", name="Home").click()
        hm = page.locator(".modal")
        hm.locator("input").press_sequentially("02151", delay=40)
        hm.get_by_role("button", name="02151", exact=False).first.click()
        page.wait_for_timeout(2500)
        g = {}
        for x in state["sets"]:
            if x.get("section") == "globals":
                g.update(x.get("values", {}))
        check("real LuCI: text from the address search can't run code (shown as text)", page.evaluate("window.__xss") is None)
        check("real LuCI: home saved to the router", g.get("home") == "42.41000,-71.00000" and "Revere" in g.get("home_label", ""), g)
        hasimg = page.evaluate("""() => L.require('view.lobbyfence.map').then(v => { const m = v.map;
            return !!(m && m.getLayer('lf-home') && m.hasImage(m.getLayoutProperty('lf-home', 'icon-image'))); })""")
        check("real LuCI: home pin drawn on the map", hasimg)
        page.locator(".lf-bar").get_by_role("button", name="Home").click()
        page.wait_for_timeout(300)
        check("real LuCI: the odd name is displayed literally", page.locator(".modal").get_by_text("<img src=x", exact=False).count() >= 1 and page.evaluate("window.__xss") is None)
        page.keyboard.press("Escape")
        page.locator(".modal").get_by_role("button", name="Close").click()

        # Save & Apply from LuCI's own footer: a shape drawn just before must be saved first, then applied
        page.get_by_role("button", name="Add circle").click()
        canvas = page.locator(".maplibregl-canvas").bounding_box()
        page.mouse.click(canvas["x"] + canvas["width"] * 0.7, canvas["y"] + canvas["height"] * 0.4)
        n_sets = len(state["sets"])
        page.locator(".cbi-page-actions").get_by_text("Save & Apply", exact=True).first.click()   # at once, before the auto-save
        try:
            page.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=15000)
            applied = True
        except Exception:
            applied = False
        later = [x for x in state["sets"][n_sets:] if x.get("section") == "game" and "circle" in x.get("values", {})]
        check("real LuCI: Save & Apply saves the new shape first", later and len(later[-1]["values"]["circle"]) == 3, later[-1:] if later else state["sets"][n_sets:])
        check("real LuCI: ...then applies (rollback-protected) and confirms", applied and apply_log[:1] == ["apply_rollback"] and "confirm" in apply_log, apply_log)
        check("real LuCI: the save happened before the apply", later and apply_seq and apply_seq[0] > max(i for i, x in enumerate(state["sets"]) if x.get("section") == "game" and "circle" in x.get("values", {})), apply_seq)

        # Reset: throws away saved-but-not-applied LobbyFence changes on the router, then reloads
        page.wait_for_function("document.querySelector('.lf-app')", timeout=20000)
        page.wait_for_timeout(1500)
        n_calls = len(calls)
        page.locator(".cbi-page-actions").get_by_role("button", name="Reset").click()
        page.wait_for_timeout(2000)
        check("real LuCI: Reset reverts LobbyFence's pending changes on the router", ("uci", "revert") in calls[n_calls:], calls[n_calls:])
        check("real LuCI: ...and the page comes back", page.locator(".lf-app").count() == 1)

        # borderless with LuCI's Bootstrap theme (its dialogs sit at z-index 900, the
        # borderless map at 2000): dialogs come above the map, and the toolbar has
        # Reset / Save / Save & Apply (LuCI's own buttons at the bottom are covered)
        page.add_style_tag(content="#modal_overlay{position:fixed;top:0;bottom:0;background:rgba(0,0,0,.7);z-index:900;overflow:auto;opacity:0;visibility:hidden}"
                           " .modal{width:90%;margin:5em auto;max-width:600px;background:#fff}"
                           " body.modal-overlay-active #modal_overlay{left:0;right:0;opacity:1;visibility:visible}")
        page.locator(".lf-bar").get_by_role("button", name="View ▾").click()
        page.locator(".lf-menu").get_by_text("Borderless").click()
        page.keyboard.press("Escape")
        page.wait_for_timeout(400)
        page.locator(".lf-bar").get_by_role("button", name="Delete zone").click()
        page.wait_for_timeout(300)
        top = page.evaluate("""() => { const m = document.querySelector('#modal_overlay .modal'); if (!m) return 'no modal';
            const r = m.getBoundingClientRect(), e = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
            return e && e.closest('#modal_overlay') ? 'modal' : (e ? e.className : 'nothing'); }""")
        check("real LuCI + Bootstrap theme, borderless: a dialog shows above the map", top == "modal", top)
        page.locator(".modal").get_by_role("button", name="Cancel").click()
        check("real LuCI, borderless: Reset / Save / Save & Apply in the toolbar", page.locator(".lf-savebar").is_visible()
              and page.locator(".lf-savebar button").all_inner_texts() == ["Reset", "Save", "Save & Apply"], page.locator(".lf-savebar button").all_inner_texts())
        n_apply = len(apply_log)
        page.locator(".lf-seg [data-mode=monitor]").click()
        page.wait_for_timeout(1500)
        page.locator(".lf-savebtn-apply").click()
        try:
            page.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=15000)
            ok = True
        except Exception:
            ok = False
        check("real LuCI, borderless: the toolbar's Save & Apply goes through LuCI's apply (with rollback protection)",
              ok and "apply_rollback" in apply_log[n_apply:], apply_log[n_apply:])
        # (LuCI reloads the page after applying; borderless is remembered - switch it off for what follows)
        page.wait_for_function("!document.body.classList.contains('modal-overlay-active') && document.querySelector('.lf-app.lf-borderless .lf-seg')", timeout=30000)
        page.wait_for_timeout(1000)
        page.locator(".lf-bar").get_by_role("button", name="View ▾").click()
        page.locator(".lf-menu").get_by_text("Borderless").click()
        page.keyboard.press("Escape")
        page.wait_for_function("!document.querySelector('.lf-app.lf-borderless') && !document.body.classList.contains('lf-fullpage')", timeout=5000)

        # Delete zone: removed on the router and applied in one go
        n_calls, n_apply = len(calls), len(apply_log)
        page.locator(".lf-bar").get_by_role("button", name="Delete zone").click()
        page.locator(".modal").get_by_role("button", name="Delete zone").click()
        try:
            page.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=15000)
            ok = True
        except Exception:
            ok = False
        dels = [x for x in state["sets"] if "delete" in x and x["delete"].get("section") == "game"]
        check("real LuCI: deleting a zone removes it on the router and applies", ok and dels and "apply_rollback" in apply_log[n_apply:], [dels, apply_log[n_apply:]])

        # after the reload there is no zone: create one from the welcome card
        page.wait_for_function("document.body.innerText.includes('Create your first zone')", timeout=20000)
        page.get_by_role("button", name="Create your first zone").click()
        modal = page.locator(".modal")
        page.wait_for_function("document.querySelectorAll('.modal select')[2] && document.querySelectorAll('.modal select')[2].options.length > 1", timeout=10000)
        opts = modal.locator("select").nth(2).locator("option").all_inner_texts()
        check("real LuCI: a hostile device name is shown as text, never run", page.evaluate("window.__xss2") is None
              and any("<img src=x" in o for o in opts), opts)
        # the game list in LuCI's dialog: in the dialog's layer, on top, inside the window - and Escape
        # closes only the list (LuCI closes the whole dialog on Escape)
        modal.locator("select").first.click()
        info = page.evaluate("""() => { const b = document.querySelector('.lf-pagelist'); if (!b) return null;
            const r = b.getBoundingClientRect(), e = document.elementFromPoint(r.left + 30, r.top + 30);
            return { layer: !!b.closest('#modal_overlay'), onTop: !!(e && e.closest('.lf-pagelist')), top: r.top, bottom: r.bottom, vh: innerHeight }; }""")
        check("real LuCI: the game list opens in the dialog's layer, on top and inside the window",
              info and info["layer"] and info["onTop"] and info["top"] >= 0 and info["bottom"] <= info["vh"], info)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-luci-game-list.png"))
        page.keyboard.press("Escape")
        check("real LuCI: Escape closes the game list, not the dialog",
              page.locator(".lf-pagelist").count() == 0 and page.evaluate("document.body.classList.contains('modal-overlay-active')"))
        modal.locator("select").first.select_option("apex")
        modal.locator(".lf-nz-platform").select_option("pc")
        page.wait_for_timeout(300)
        check("real LuCI: New zone picks no device by itself", modal.locator("select").nth(2).input_value() == "")
        modal.locator("select").nth(2).select_option("aa:bb:cc:dd:ee:01")
        modal.get_by_role("button", name="Create zone").click()
        page.wait_for_timeout(2500)
        adds = [x["add"] for x in state["sets"] if "add" in x and x["add"].get("type") == "zone"]
        later = {}
        for x in state["sets"]:
            if x.get("section") == "apex_legends":
                later.update(x.get("values", {}))
        vals = dict((adds[-1].get("values") or {}) if adds else {}, **later)
        check("real LuCI: a new zone reaches the router with its game settings", adds and adds[-1].get("name") == "apex_legends"
              and vals.get("burst_servers") == "2" and vals.get("game") == "apex", [adds[-1:], later])
        check("real LuCI: and the map switches to it, ready to draw", page.locator(".lf-bar select").first.input_value() == "apex_legends")

        check("real LuCI: the page is a home-screen app (manifest + icon), no install tip on a computer",
              page.evaluate("!!document.querySelector('link[rel=manifest]') && !!document.querySelector('link[rel=apple-touch-icon]')")
              and page.locator("#lf-install").count() == 0)

        # on a phone: the tip that says how to add LobbyFence to the home screen
        ph = b.new_context(**p.devices["iPhone 13"])
        pp = ph.new_page()
        pp.on("pageerror", lambda e: errs.append(str(e)))
        routes(pp)
        pp.goto("http://router.test/cgi-bin/luci/admin/services/lobbyfence/map")
        try:
            pp.wait_for_function("document.querySelector('.lf-app') && document.getElementById('lf-install')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        man = pp.evaluate("fetch(document.querySelector('link[rel=manifest]').href).then(r => r.json()).then(m => [m.start_url, m.display, m.icons.length])") if ok else None
        check("real LuCI on a phone: the 'add to home screen' tip above the map, the manifest opens the map as an app",
              ok and pp.evaluate("document.getElementById('lf-install').nextElementSibling === document.getElementById('view')")
              and man == ["/cgi-bin/luci/admin/services/lobbyfence/map?lf=app", "standalone", 3], man)
        if ok:
            pp.locator("#lf-install").click()
            pp.wait_for_timeout(300)
            check("real LuCI on a phone: the tip opens the how-to", "Add to Home Screen" in pp.locator("#lf-guide").inner_text())
            if SHOTS:
                pp.screenshot(path=str(SHOTS / "luci-phone-guide.png"))
        ph.close()

        # opened from the home screen: LobbyFence on its own (LuCI's menus hidden, a way back to them)
        ph = b.new_context(**p.devices["iPhone 13"])
        pp = ph.new_page()
        pp.add_init_script("Object.defineProperty(navigator, 'standalone', { get: () => true })")
        pp.on("pageerror", lambda e: errs.append(str(e)))
        routes(pp)
        pp.goto("http://router.test/cgi-bin/luci/admin/services/lobbyfence/map?lf=app")    # (the manifest's start address)
        try:
            pp.wait_for_function("document.querySelector('.lf-app') && document.getElementById('lf-router')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        st = pp.evaluate("""[document.title, getComputedStyle(document.querySelector('body > header')).display,
            document.getElementById('lf-router').getAttribute('href'), !!document.getElementById('lf-install'),
            Array.from(document.querySelectorAll('link[rel~=icon]')).map(l => l.getAttribute('href'))]""") if ok else None
        check("real LuCI as a home-screen app: LobbyFence's name and icon, LuCI's menus hidden, a link back to the router, no tip",
              ok and st[0] == "LobbyFence" and st[1] == "none" and st[2] == "/cgi-bin/luci/" and not st[3]
              and st[4] and all("/luci-static/lobbyfence/" in h for h in st[4]), st)
        if SHOTS and ok:
            pp.screenshot(path=str(SHOTS / "luci-phone-app.png"))
        ph.close()

        # a theme that makes all of LuCI an app of its own (Footstrap: its manifest and icon, pages
        # changed without reloading): LobbyFence's while on its pages, the theme's again elsewhere;
        # in the theme's own app (no ?lf=app) LuCI's menus stay
        THEMED = PAGE.replace("<title>LuCI</title>", '<title>LuCI</title><link rel="manifest" href="/luci-static/theme/manifest.json">'
                              '<link rel="apple-touch-icon" href="/luci-static/theme/app-icon.png"><link rel="icon" href="/luci-static/theme/logo.png">')
        ph = b.new_context(**p.devices["iPhone 13"])
        pp = ph.new_page()
        pp.add_init_script("Object.defineProperty(navigator, 'standalone', { get: () => true })")
        pp.on("pageerror", lambda e: errs.append(str(e)))
        routes(pp, THEMED)
        pp.route("http://router.test/luci-static/theme/**", lambda r: r.fulfill(status=200, body=b""))
        pp.goto("http://router.test/cgi-bin/luci/admin/services/lobbyfence/map")
        try:
            pp.wait_for_function("document.querySelector('.lf-app') && document.querySelector('link[rel=manifest]').href.includes('/lobbyfence/')", timeout=30000)
            ok = True
        except Exception:
            ok = False
        LINKS = "Array.from(document.querySelectorAll('link[rel=manifest],link[rel~=icon],link[rel=apple-touch-icon]')).map(l => l.getAttribute('href').replace(/^https?:..[^/]+/, '')).sort()"
        on = pp.evaluate(LINKS) if ok else None
        menus = pp.evaluate("getComputedStyle(document.querySelector('body > header')).display") if ok else None
        pp.evaluate("history.pushState(null, '', '/cgi-bin/luci/admin/status/overview')")
        pp.wait_for_timeout(200)
        off = pp.evaluate(LINKS)
        check("a theme with its own app (Footstrap): LobbyFence's name and icon on its pages, the theme's back elsewhere, its menus kept in its own app",
              ok and all("/luci-static/lobbyfence/" in h for h in on) and menus != "none"
              and off == ["/luci-static/theme/app-icon.png", "/luci-static/theme/logo.png", "/luci-static/theme/manifest.json"], [on, menus, off])
        ph.close()

        real = [e for e in errs if "favicon" not in e and "404" not in e]
        check("real LuCI: no JavaScript errors", not real, real[:4])
        b.close()


if __name__ == "__main__":
    main()
    print("ALL REAL-LUCI MAP TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
    sys.exit(0 if all(results) else 1)
