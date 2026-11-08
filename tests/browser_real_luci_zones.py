"""The Zones page inside the REAL LuCI JavaScript framework (luci.js, form.js,
ui.js, uci.js, rpc.js) in headless Chromium. The router's ubus API is played by
this script, so rendering, LuCI's own validation and saving are all real.
    usage: python3 browser_real_luci_zones.py <luci/modules/luci-base/htdocs/luci-static/resources> [screenshot-dir]
"""
import json
import pathlib
import sys

from playwright.sync_api import sync_playwright

LUCI = pathlib.Path(sys.argv[1])
SHOTS = pathlib.Path(sys.argv[2]) if len(sys.argv) > 2 else None
VIEWS = pathlib.Path(__file__).resolve().parent.parent / "luci-app-lobbyfence/htdocs/luci-static/resources/view"
results = []


def check(name, cond, detail=""):
    results.append(bool(cond))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


PAGE = """<!doctype html><html><head><meta charset="utf-8"><title>LuCI</title>
<style>.hidden{display:none}.cbi-input-invalid{outline:2px solid red}</style></head>
<body><div id="maincontent"><div id="view"><div class="spinning">Loading view…</div></div></div>
<script src="/luci-static/resources/cbi.js"></script>
<script src="/luci-static/resources/luci.js"></script>
<script>
L = new LuCI({
  media: '/luci-static/bootstrap', resource: '/luci-static/resources', scriptname: '/cgi-bin/luci',
  pathinfo: '/admin/services/lobbyfence/zones', documentroot: '/www', requestpath: ['admin','services','lobbyfence','zones'],
  dispatchpath: ['admin','services','lobbyfence','zones'], ubuspath: '/ubus/', sessionid: 'deadbeef',
  token: 'tok', nodespec: { satisfied: true, readonly: false }, apply_rollback: 90, apply_holdoff: 4, apply_timeout: 5, apply_display: 1.5, rollback_token: null,
  pollinterval: 5
});
L.require('ui').then(function(ui) { return ui.instantiateView('lobbyfence/zones'); });
</script></body></html>"""

CONFIG = {
    "globals": {".anonymous": False, ".type": "globals", ".name": "globals", ".index": 0, "enabled": "1", "interval": "20"},
    "game": {".anonymous": False, ".type": "zone", ".name": "game", ".index": 1, "enabled": "1", "label": "Game",
             "mode": "enforce", "strict": "1", "device": ["192.168.1.23"], "remote_port": ["1024-65535"], "proto": "udp"},
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
            elif (obj, meth) == ("file", "exec"):
                res = {"code": 0, "stdout": json.dumps([{"mac": "aa:bb:cc:dd:ee:01", "name": "Phone", "ipv4": ["192.168.1.23"], "ipv6": []}])}
            elif (obj, meth) == ("file", "list"):
                res = {"entries": []}
            elif obj == "luci" and meth == "getFeatures":
                res = {}
            out.append({"jsonrpc": "2.0", "id": m.get("id"), "result": [0, res]})
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
        page.route("http://router.test/cgi-bin/luci/admin/services/lobbyfence/zones", lambda r: r.fulfill(content_type="text/html", body=PAGE))
        page.route("http://router.test/luci-static/resources/**", static)
        # LobbyFence's app files (lf-app.js, manifest, icons), where the installer puts them
        REPO = pathlib.Path(__file__).resolve().parent.parent
        def appfile(route):
            n = route.request.url.split("/luci-static/lobbyfence/")[1].split("?")[0]
            f = {"manifest.json": REPO / "luci-app-lobbyfence/htdocs/luci-static/lobbyfence/manifest.json",
                 "lf-app.js": REPO / "freshtomato/www/lobbyfence/lf-app.js"}.get(n, REPO / "app-icon" / n)
            ct = {"json": "application/manifest+json", "js": "text/javascript", "png": "image/png"}.get(n.rsplit(".", 1)[-1], "text/plain")
            route.fulfill(status=200 if f.exists() else 404, content_type=ct, body=f.read_bytes() if f.exists() else b"")
        page.route("http://router.test/luci-static/lobbyfence/**", appfile)
        page.route("http://router.test/ubus/**", ubus)
        page.route("http://router.test/cgi-bin/luci/admin/translations/**", lambda r: r.fulfill(content_type="text/javascript", body=""))
        # a slow router: answers to "uci set" take 1.5 s (delayed inside the page, so the test keeps running)
        page.add_init_script("""(() => { const send = XMLHttpRequest.prototype.send;
            XMLHttpRequest.prototype.send = function(body) {
                if (window.__slowSet && typeof body === 'string' && body.indexOf('"set"') >= 0) { const x = this; setTimeout(() => send.call(x, body), 1500); return; }
                return send.call(this, body); }; })()""")
        page.goto("http://router.test/cgi-bin/luci/admin/services/lobbyfence/zones")
        try:
            page.wait_for_selector(".cbi-map", timeout=15000)
            ok = True
        except Exception:
            ok = False
        check("real LuCI: the Zones page renders", ok, errs[:4])
        if not ok:
            b.close()
            return
        check("real LuCI: general settings and the zone are shown",
              page.get_by_text("General settings").is_visible() and page.get_by_text("Game", exact=True).count() >= 1)
        # automatic save: a second change made while the first is still being saved must not be lost
        page.evaluate("window.__slowSet = true")
        iv = page.locator("[data-name='interval'] input")
        iv.fill("30"); iv.dispatch_event("keyup"); iv.dispatch_event("change"); iv.dispatch_event("blur")
        page.wait_for_timeout(1100)      # the 800 ms timer fired: that save now waits for the router
        mb = page.locator("[data-name='max_batches'] input")
        mb.fill("6"); mb.dispatch_event("keyup"); mb.dispatch_event("change"); mb.dispatch_event("blur")
        page.wait_for_timeout(5000)
        page.evaluate("window.__slowSet = false")
        g = {}
        for s_ in state["sets"]:
            if s_.get("section") == "globals":
                g.update(s_.get("values", {}))
        check("real LuCI: two quick changes both reach the router (slow router)", g.get("interval") == "30" and g.get("max_batches") == "6", g)
        check("real LuCI: and the page still shows them", iv.input_value() == "30" and page.locator("[data-name='max_batches'] input").input_value() == "6")

        # open the zone's edit dialog
        page.locator(".cbi-section-table-row .cbi-button-edit, .cbi-button-edit").first.click()
        page.wait_for_selector("#modal_overlay .cbi-section, .modal .cbi-section", timeout=10000)
        modal = page.locator(".modal").first
        check("real LuCI: zone dialog opens", modal.is_visible())
        lag = modal.locator("[data-name='lag'] input[type=checkbox]")
        check("real LuCI: lag simulator switch in the dialog", lag.count() == 1)
        delay_row = modal.locator("[data-name='lag_delay']")
        check("real LuCI: lag fields hidden while the switch is off", delay_row.count() == 0 or not delay_row.is_visible())
        lag.check()
        page.wait_for_timeout(300)
        check("real LuCI: switching it on shows direction, ping, jitter and loss",
              all(modal.locator("[data-name='%s']" % n).is_visible() for n in ("lag_direction", "lag_delay", "lag_jitter", "lag_loss")))
        sel = modal.locator("[data-name='lag_direction'] select")
        check("real LuCI: direction defaults to Both ways", sel.input_value() == "both" and sel.locator("option").count() == 3,
              sel.locator("option").all_inner_texts())
        inp = modal.locator("[data-name='lag_delay'] input")
        inp.fill("12.5"); inp.dispatch_event("keyup"); inp.dispatch_event("blur")
        page.wait_for_timeout(200)
        check("real LuCI: 12.5 ms refused (whole numbers only)", "cbi-input-invalid" in (inp.get_attribute("class") or ""))
        inp.fill("80"); inp.dispatch_event("keyup"); inp.dispatch_event("blur")
        loss = modal.locator("[data-name='lag_loss'] input")
        loss.fill("1.5"); loss.dispatch_event("keyup"); loss.dispatch_event("blur")
        page.wait_for_timeout(200)
        check("real LuCI: 80 ms and 1.5 % loss accepted", "cbi-input-invalid" not in (inp.get_attribute("class") or "")
              and "cbi-input-invalid" not in (loss.get_attribute("class") or ""))
        sel.select_option("up")
        bs = modal.locator("[data-name='burst_servers'] input")
        check("real LuCI: server tests shows 0 (off) as the default", bs.get_attribute("placeholder") == "0")
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-luci-zone.png"))
        modal.get_by_role("button", name="Save").click()
        page.wait_for_timeout(1200)
        saved = {}
        for s in state["sets"]:
            if s.get("section") == "game":
                saved.update(s.get("values", {}))
        check("real LuCI: lag settings saved to the router", saved.get("lag") == "1" and saved.get("lag_delay") == "80"
              and saved.get("lag_loss") == "1.5" and saved.get("lag_direction") == "up", saved)
        # the page's own Save & Apply
        apply_log = []
        page.route("http://router.test/cgi-bin/luci/admin/uci/**", lambda r: (apply_log.append(r.request.url.split("/admin/uci/")[1].split("?")[0]),
                   r.fulfill(status=200, content_type="application/json", body='{"token":"t"}') if "apply_rollback" in r.request.url else r.fulfill(status=204, body="")))
        page.route("http://router.test/cgi-bin/cgi-exec*", lambda r: r.fulfill(status=200, body=""))
        iv = page.locator("[data-name='interval'] input")
        n_sets = len(state["sets"])
        iv.fill("45"); iv.dispatch_event("keyup"); iv.dispatch_event("change")
        page.locator(".cbi-page-actions").get_by_text("Save & Apply", exact=True).first.click()
        try:
            page.wait_for_function("document.body.innerText.includes('Configuration changes applied')", timeout=15000)
            ok = True
        except Exception:
            ok = False
        g = {}
        for s_ in state["sets"][n_sets:]:
            if s_.get("section") == "globals":
                g.update(s_.get("values", {}))
        check("real LuCI: Zones page Save & Apply saves the change and applies it", ok and g.get("interval") == "45" and "apply_rollback" in apply_log, [g, apply_log])

        real = [e for e in errs if "favicon" not in e and "404" not in e]
        check("real LuCI: no JavaScript errors", not real, real[:4])
        b.close()


if __name__ == "__main__":
    main()
    print("ALL REAL-LUCI ZONES TESTS PASSED" if all(results) else "%d FAILED" % results.count(False))
    sys.exit(0 if all(results) else 1)
