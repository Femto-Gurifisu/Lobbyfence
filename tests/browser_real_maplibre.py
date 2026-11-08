"""The map page against the REAL MapLibre GL JS build (WebGL via SwiftShader).

browser_map_test.py uses a small MapLibre stand-in so it runs anywhere; this
test loads the actual library files, so drawing (shapes, server dots, the home
pin), themes, the globe and the View menu are checked on the real renderer.
    usage: python3 browser_real_maplibre.py <maplibre-dist-dir> [screenshot-dir] [positron style.json]
    (the dist directory of a maplibre-gl release, e.g. from its GitHub dist.zip)
"""
import json
import pathlib
import sys

sys.argv, ARGS = sys.argv[:1] + sys.argv[2:3], sys.argv[1:]
import browser_map_test as T  # noqa: E402  (harness, LuCI stand-ins, boot())
from playwright.sync_api import sync_playwright  # noqa: E402

DIST = pathlib.Path(ARGS[0])
# optional: the OpenFreeMap positron style.json (github.com/hyperknot/openfreemap-styles)
POSITRON = pathlib.Path(ARGS[2]) if len(ARGS) > 2 else None
SHOTS = pathlib.Path(ARGS[1]) if len(ARGS) > 1 else None
check = T.check

STYLE = {"version": 8, "sources": {}, "layers": [{"id": "background", "type": "background", "paint": {"background-color": "#ddd"}}]}


def serve_dist(route):
    name = route.request.url.split("/dist/")[1].split("?")[0]
    f = DIST / name
    if not f.exists():
        return route.fulfill(status=404, body="")
    ctype = "text/css" if name.endswith(".css") else "text/javascript"
    route.fulfill(content_type=ctype, body=f.read_bytes(), headers={"Access-Control-Allow-Origin": "*"})


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch(args=["--use-gl=angle", "--use-angle=swiftshader", "--enable-unsafe-swiftshader", "--ignore-gpu-blocklist"])
        page = browser.new_page(viewport={"width": 1400, "height": 900})
        errs = []
        page.on("pageerror", lambda e: errs.append(str(e)))
        page.on("console", lambda m: m.type == "error" and "Failed to load resource" not in m.text and errs.append(m.text))
        page.route("http://router.test/", lambda r: r.fulfill(content_type="text/html", body=T.HARNESS))
        page.route("https://unpkg.com/maplibre-gl@*/dist/*", serve_dist)
        page.route("https://tiles.openfreemap.org/styles/positron",
                   lambda r: r.fulfill(content_type="application/json", body=json.dumps(STYLE), headers={"Access-Control-Allow-Origin": "*"}))
        page.route("https://tiles.maps.eox.at/**", lambda r: r.abort())
        page.route("https://server.arcgisonline.com/**", lambda r: r.abort())
        page.route("https://tile.openstreetmap.org/**", lambda r: r.abort())

        cfg = {"globals": {".name": "globals", ".type": "globals", "enabled": "1", "home": "40.75060,-73.99710", "home_label": "10001, Manhattan"},
               "game": {".name": "game", ".type": "zone", "label": "Game", "enabled": "1", "mode": "enforce", "device": ["192.168.1.23"],
                        "circle": ["50.1109,8.6821,800"], "polygon": ["30.0000,-100.0000;30.0000,-80.0000;45.0000,-80.0000;45.0000,-100.0000"]}}
        servers = "45.10.0.1 in 50.11 8.68 DE 1700000000\n80.20.0.1 out 40.71 -74.0 US 1700000100\n"
        status = {"version": "1.0.0", "enabled": True, "active": True, "updated": 1, "interval": 20, "tc": True,
                  "geo": {"last_ok": 1, "pending": 0, "error": ""},
                  "zones": [{"id": "game", "label": "Game", "enabled": True, "mode": "enforce", "strict": True, "region": True,
                             "servers": 2, "inside": 1, "outside": 1, "pending": 0, "unlocatable": 0, "packets": 10, "blocked": 1,
                             "devices": ["192.168.1.23"], "macs": 0, "allow": [], "block": []}]}
        files = {"/tmp/lobbyfence/game.servers": servers, "/tmp/lobbyfence/status.json": json.dumps(status)}
        services = {"lobbyfence": {"instances": {"i": {"running": True}}}}
        T.boot(page, cfg, files, services, fail_gl=True, storage={"lobbyfence.range": json.dumps("all")})  # (fail_gl only skips the stand-in wait)
        page.evaluate("window.view.range = 'all'; window.view.renderServers && window.view.renderServers()")
        try:
            page.wait_for_function("window.view && window.view.map && window.view.styleReady", timeout=30000)
            ok = True
        except Exception:
            ok = False
        check("real MapLibre: map and style load (WebGL)", ok, errs[:3])
        if not ok:
            browser.close()
            return
        page.wait_for_function("window.view.map.getLayer('lf-home')", timeout=10000)
        page.evaluate("window.view.drawServers()")
        page.wait_for_timeout(1500)
        layers = page.evaluate("['lf-circle-fill','lf-servers','lf-home'].map(id => !!window.view.map.getLayer(id))")
        check("real MapLibre: shape, server and home layers exist", all(layers), layers)
        pin = page.evaluate("""(() => { const m = window.view.map, img = m.getLayer('lf-home').layout && m.getLayoutProperty('lf-home', 'icon-image');
            return [img, m.hasImage(img)]; })()""")
        check("real MapLibre: home pin image loaded", pin[1] and pin[0] == "lf-pin-3b82f6", pin)
        page.evaluate("window.view.map.jumpTo({ center: [-73.9971, 40.7506], zoom: 5 })")
        page.wait_for_timeout(1500)
        hit = page.evaluate("""(() => { const m = window.view.map, p = m.project([-73.9971, 40.7506]);
            return m.queryRenderedFeatures([[p.x - 4, p.y - 30], [p.x + 4, p.y - 2]], { layers: ['lf-home'] }).length; })()""")
        check("real MapLibre: the pin is drawn just above home (tip on the spot)", hit >= 1, hit)
        box = page.evaluate("""(() => { const m = window.view.map, p = m.project([-73.9971, 40.7506]), r = m.getCanvas().getBoundingClientRect();
            return [r.left + p.x, r.top + p.y - 16]; })()""")
        page.mouse.click(box[0], box[1])
        page.wait_for_timeout(500)
        check("real MapLibre: clicking the pin shows the home address", page.locator(".maplibregl-popup").filter(has_text="10001, Manhattan").count() == 1)
        page.keyboard.press("Escape")
        no_dom = page.evaluate("document.querySelectorAll('.maplibregl-marker.lf-home, .lf-home').length")
        check("real MapLibre: no HTML box for the pin", no_dom == 0, no_dom)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-midnight.png"))
        page.evaluate("window.view.map.jumpTo({ center: [8.68, 50.11], zoom: 3 })")
        page.wait_for_timeout(1200)
        srv = page.evaluate("""(() => { const m = window.view.map, p = m.project([8.68, 50.11]);
            return m.queryRenderedFeatures([[p.x - 8, p.y - 8], [p.x + 8, p.y + 8]], { layers: ['lf-servers'] }).length; })()""")
        check("real MapLibre: server dot drawn", srv >= 1, srv)
        circ = page.evaluate("""(() => { const m = window.view.map, p = m.project([8.68, 50.11]);
            return m.queryRenderedFeatures(p, { layers: ['lf-circle-fill'] }).length; })()""")
        check("real MapLibre: circle drawn", circ >= 1, circ)

        for theme in ("light", "galaxy", "satellite", "midnight"):
            page.locator(".lf-bar select").last.select_option(theme)
            page.wait_for_timeout(1500)
            st = page.evaluate("""(() => { const m = window.view.map, img = m.getLayer('lf-home') && m.getLayoutProperty('lf-home', 'icon-image');
                return [!!m.getLayer('lf-circle-fill'), !!m.getLayer('lf-servers'), !!img && m.hasImage(img)]; })()""")
            check("real MapLibre: theme %s keeps shapes, servers and the pin" % theme, all(st), st)
            if SHOTS:
                page.screenshot(path=str(SHOTS / ("real-theme-%s.png" % theme)))

        page.get_by_role("button", name="Globe").click()
        page.wait_for_timeout(1500)
        proj = page.evaluate("(window.view.map.getProjection && window.view.map.getProjection() || {}).type")
        check("real MapLibre: globe projection", proj == "globe", proj)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-globe.png"))
        page.get_by_role("button", name="Globe").click()
        page.wait_for_timeout(800)

        page.locator("button", has_text="View").click()
        page.locator(".lf-menu").get_by_text("Endless map").click()
        page.locator(".lf-menu").get_by_text("Country borders").click()
        # normal use: zooming out stops where the map still fills its whole area (no unused space)
        fills = """() => { const m = window.view.map, c = m.getContainer(), w = c.clientWidth, h = c.clientHeight;
            const l = m.project([-180, 0]).x, r = m.project([180, 0]).x, t = m.project([0, 85]).y, b = m.project([0, -85]).y;
            /* (with the endless map the world repeats left and right: only top to bottom must be filled) */
            return [(window.view.endless || (l <= 2 && r >= w - 2)) && t <= 2 && b >= h - 2, [l, r, t, b, w, h].map(Math.round), m.getZoom(), window.view.endless]; }"""
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        r = page.evaluate(fills)
        check("real MapLibre: zooming out normally, the map always fills its area", r[0], r)
        # the bug from a user's recording: endless map off after scrolling sideways left an empty strip
        # (the world half off-screen) until the next zoom - now put right at once
        page.evaluate("window.view.map.jumpTo({ center: [150, 0], zoom: 1.2 })")
        page.wait_for_timeout(300)
        page.evaluate("window.view.setEndless(false)")
        page.wait_for_timeout(300)
        r = page.evaluate(fills)
        check("real MapLibre: endless map off after scrolling sideways - no empty strip, without touching the map", r[0], r)
        page.evaluate("window.view.setEndless(true)")
        page.locator(".lf-menu").get_by_text("Whole world").click()
        page.wait_for_timeout(1200)
        z = page.evaluate("window.view.map.getZoom()")
        check("real MapLibre: Whole world zooms out", z < 1.5, z)
        # the WHOLE world in view (MapLibre's own limit kept it filling the map area: poles cut off)
        world = """() => { const m = window.view.map, c = m.getContainer(), w = c.clientWidth, h = c.clientHeight;
            const l = m.project([-180, 0]).x, r = m.project([180, 0]).x, t = m.project([0, 85]).y, b = m.project([0, -85]).y;
            return [l >= -1 && r <= w + 1 && t >= -1 && b <= h + 1 && (r - l >= w - 3 || b - t >= h - 3), [l, r, t, b, w, h].map(Math.round), m.getZoom(), m.getMinZoom()]; }"""
        r = page.evaluate(world)
        check("real MapLibre: Whole world - the entire world is in view (pole to pole, all 360 degrees)", r[0], r)
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        r2 = page.evaluate(world)
        check("real MapLibre: no zooming out past that (the world does not shrink further)", r2[0] and abs(r2[2] - r[2]) < 0.01 and abs(r2[3] - r[2]) < 0.01, r2)
        page.evaluate("window.view.map.zoomTo(3, { duration: 0 })")
        page.wait_for_timeout(300)
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        page.wait_for_timeout(300)
        r = page.evaluate(world)
        check("real MapLibre: Whole world stays on - zoomed in and out again, the whole world again", r[0] and page.evaluate("window.view.wholeWorld === true"), r)
        # the map area changes size (borderless, panel): applied at once, still the whole world
        page.evaluate("window.view.setEndless(false); window.view.setBorderless(true)")
        page.wait_for_timeout(900)
        r = page.evaluate(world)
        check("real MapLibre: Whole world + borderless on: fitted to the bigger area at once", r[0], r)
        page.evaluate("window.view.setBorderless(false); window.view.setPanel(false)")
        page.wait_for_timeout(900)
        r = page.evaluate(world)
        check("real MapLibre: ...borderless off, panel hidden: fitted again at once", r[0], r)
        page.evaluate("window.view.setPanel(true)")
        page.wait_for_timeout(900)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(900)
        r = page.evaluate(world)
        check("real MapLibre: on a phone too (the world is wider than the screen at zoom 0)", r[0] and r[2] < 0, r)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-zoomout-phone.png"))
        page.set_viewport_size({"width": 1400, "height": 900})
        page.wait_for_timeout(900)
        page.evaluate("window.view.toggleViewMenu(true)")
        page.locator(".lf-menu").get_by_text("Whole world").click()
        page.wait_for_timeout(600)
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        r = page.evaluate(fills)
        check("real MapLibre: Whole world off - the map fills its area again", r[0] and page.evaluate("window.view.wholeWorld === false"), r)
        page.keyboard.press("Escape")
        page.get_by_role("button", name="Draw polygon").click()
        for lng, lat in [(-10, 0), (12, 3), (10, 20), (-12, 17)]:
            page.evaluate("([lng, lat]) => { const m = window.view.map; m.fire('click', { lngLat: { lng, lat }, point: m.project([lng, lat]) }); }", [lng, lat])
        page.keyboard.press("Enter")
        page.wait_for_timeout(500)
        check("real MapLibre: align offer after drawing", page.locator(".lf-prompt").is_visible())
        page.get_by_role("button", name="Align").click()
        page.wait_for_timeout(500)
        pts = page.evaluate("window.view.polygons.game[window.view.polygons.game.length - 1]")
        straight = all(abs(pts[i][1] - pts[(i + 1) % len(pts)][1]) < 1e-9 or abs(pts[i][0] - pts[(i + 1) % len(pts)][0]) < 1e-9 for i in range(len(pts)))
        check("real MapLibre: Align gives a rectangle", straight and len(pts) == 4, pts)

        # real mouse: drag the new rectangle, then one of its corners
        page.keyboard.press("Escape")
        page.evaluate("window.view.map.jumpTo({ center: [0, 10], zoom: 3 })")
        page.wait_for_timeout(800)
        def px(lng, lat):
            return page.evaluate("""([lng, lat]) => { const m = window.view.map, p = m.project([lng, lat]), r = m.getCanvas().getBoundingClientRect();
                return [r.left + p.x, r.top + p.y]; }""", [lng, lat])
        before = page.evaluate("window.view.polygons.game[window.view.polygons.game.length - 1]")
        cx = sum(q[0] for q in before) / 4; cy = sum(q[1] for q in before) / 4
        a = px(cx, cy)
        page.mouse.click(a[0], a[1])
        page.wait_for_timeout(300)
        check("real MapLibre: clicking a shape selects it", page.evaluate("window.view.selected && window.view.selected.kind") == "polygon")
        page.mouse.move(a[0], a[1]); page.mouse.down(); page.mouse.move(a[0] + 60, a[1] + 40, steps=8); page.mouse.up()
        page.wait_for_timeout(400)
        after = page.evaluate("window.view.polygons.game[window.view.polygons.game.length - 1]")
        check("real MapLibre: dragging moves the shape", after[0][0] > before[0][0] + 1 and after[0][1] < before[0][1] - 1, [before[0], after[0]])
        v = page.locator(".lf-vertex").first
        bb = v.bounding_box()
        check("real MapLibre: corner handles shown", page.locator(".lf-vertex").count() == 4)
        page.mouse.move(bb["x"] + bb["width"] / 2, bb["y"] + bb["height"] / 2); page.mouse.down()
        page.mouse.move(bb["x"] + 40, bb["y"] - 30, steps=8); page.mouse.up()
        page.wait_for_timeout(400)
        moved = page.evaluate("window.view.polygons.game[window.view.polygons.game.length - 1]")
        straight = all(abs(moved[i][1] - moved[(i + 1) % 4][1]) < 1e-9 or abs(moved[i][0] - moved[(i + 1) % 4][0]) < 1e-9 for i in range(4))
        unchanged = sum(1 for q in moved if q in after)
        check("real MapLibre: dragging a corner moves only that corner's edges (rectangle kept)", straight and unchanged == 1, [after, moved])
        page.keyboard.press("Delete")
        page.wait_for_timeout(300)
        check("real MapLibre: Delete removes it", len(page.evaluate("window.view.polygons.game")) == 1)

        # circle: select it, drag its edge handle outwards -> bigger radius, same centre
        page.locator(".lf-crow .lf-num").first.click()
        page.wait_for_function("!window.view.map.isMoving()", timeout=10000)
        page.wait_for_timeout(300)
        r0 = page.evaluate("window.view.circles.game[0].r")
        c0 = page.evaluate("[window.view.circles.game[0].lat, window.view.circles.game[0].lon]")
        edge = page.evaluate("""(() => { const els = [...document.querySelectorAll('.maplibregl-marker')].filter(e => getComputedStyle(e).cursor === 'ew-resize' || e.style.cursor === 'ew-resize' || e.querySelector('[style*="ew-resize"]'));
            const r = els.length ? els[0].getBoundingClientRect() : null; return r ? [r.left + r.width / 2, r.top + r.height / 2] : null; })()""")
        check("real MapLibre: circle edge handle shown", edge is not None, edge)
        if edge:
            page.mouse.move(edge[0], edge[1]); page.mouse.down(); page.mouse.move(edge[0] + 80, edge[1], steps=8); page.mouse.up()
            page.wait_for_timeout(400)
            r1 = page.evaluate("window.view.circles.game[0].r")
            c1 = page.evaluate("[window.view.circles.game[0].lat, window.view.circles.game[0].lon]")
            check("real MapLibre: dragging the edge resizes the circle, centre stays", r1 > r0 * 1.05 and c1 == c0, [r0, r1, c0, c1])
        page.keyboard.press("Escape")

        # the real OpenFreeMap "positron" style (tiles are offline here; its layers are what matter)
        if POSITRON:
            st = json.loads(POSITRON.read_text().replace("__TILEJSON_DOMAIN__", "tiles.openfreemap.org"))
            page.unroute("https://tiles.openfreemap.org/styles/positron")
            page.route("https://tiles.openfreemap.org/styles/positron",
                       lambda r: r.fulfill(content_type="application/json", body=json.dumps(st), headers={"Access-Control-Allow-Origin": "*"}))
            page.route("https://tiles.openfreemap.org/**", lambda r: r.abort() if "/styles/" not in r.request.url else r.fallback())
            merr = []
            T.boot(page, cfg, files, services, fail_gl=True, storage={"lobbyfence.theme": json.dumps("midnight")})
            page.wait_for_function("window.view && window.view.styleReady", timeout=30000)
            page.evaluate("window.__merr = []; window.view.map.on('error', e => { const m = String(e.error && e.error.message || e.error); if (!/fetch|AJAX|Failed|network/i.test(m)) window.__merr.push(m); })")
            for theme in ("midnight", "light", "galaxy", "satellite"):
                page.locator(".lf-bar select").last.select_option(theme)
                page.wait_for_function("window.view.map.isStyleLoaded() || window.view.map.getStyle()", timeout=10000)
                page.wait_for_timeout(1500)
                info = page.evaluate("""(() => { const s = window.view.map.getStyle(), ids = s.layers.map(l => l.id);
                    return { ant: ids.includes('lf-label-continent'), borders: ids.filter(i => /boundary/.test(i)).length,
                             ours: ['lf-circle-fill', 'lf-servers', 'lf-home'].every(i => ids.includes(i)), n: ids.length }; })()""")
                check("real style, %s: Antarctica label, borders and LobbyFence layers" % theme, info["ant"] and info["borders"] >= 2 and info["ours"], info)
            page.locator(".lf-bar select").last.select_option("midnight")
            page.wait_for_timeout(1500)
            page.locator("button", has_text="View").click()
            page.locator(".lf-menu").get_by_text("Country borders").click()
            page.wait_for_timeout(300)
            vis = page.evaluate("window.view.map.getStyle().layers.filter(l => /boundary/.test(l.id)).map(l => (l.layout || {}).visibility || 'visible')")
            check("real style: Country borders off hides every border line", vis and all(x == "none" for x in vis), vis)
            page.locator(".lf-menu").get_by_text("Country borders").click()
            page.wait_for_timeout(300)
            vis = page.evaluate("window.view.map.getStyle().layers.filter(l => /boundary/.test(l.id)).map(l => (l.layout || {}).visibility || 'visible')")
            check("real style: and back on", all(x == "visible" for x in vis), vis)
            page.locator(".lf-menu").get_by_text("Country borders").click()     # off, then a theme change must keep it off
            page.keyboard.press("Escape")
            page.locator(".lf-bar select").last.select_option("light")
            page.wait_for_timeout(1500)
            vis = page.evaluate("window.view.map.getStyle().layers.filter(l => /boundary/.test(l.id)).map(l => (l.layout || {}).visibility || 'visible')")
            check("real style: borders stay off after changing theme", vis and all(x == "none" for x in vis), vis)
            # Place names off: a plain map - every name layer of the real style hidden, also across a theme change
            names = """window.view.map.getStyle().layers.filter(l => l.type === 'symbol' && (!/^lf-/.test(l.id) || l.id === 'lf-label-continent'))
                .map(l => (l.layout || {}).visibility || 'visible')"""
            page.evaluate("window.view.toggleViewMenu(true)")
            page.locator(".lf-menu").get_by_text("Place names").click()
            page.keyboard.press("Escape")
            page.wait_for_timeout(300)
            vis = page.evaluate(names)
            ours = page.evaluate("(window.view.map.getLayoutProperty('lf-home', 'visibility') || 'visible')")
            check("real style: Place names off hides every name (%d name layers), the home pin stays" % len(vis), len(vis) >= 5 and all(x == "none" for x in vis) and ours == "visible", [vis, ours])
            if SHOTS:
                page.screenshot(path=str(SHOTS / "real-no-names.png"))
            page.locator(".lf-bar select").last.select_option("satellite")
            page.wait_for_timeout(1500)
            vis = page.evaluate(names)
            check("real style: names stay off after changing theme (satellite)", vis and all(x == "none" for x in vis), vis)
            page.evaluate("window.view.toggleViewMenu(true)")
            page.locator(".lf-menu").get_by_text("Place names").click()
            page.keyboard.press("Escape")
            page.wait_for_timeout(300)
            vis = page.evaluate(names)
            check("real style: and back on", vis and all(x == "visible" for x in vis), vis)
            check("real style: MapLibre accepts every themed style", not page.evaluate("window.__merr"), page.evaluate("window.__merr"))

        real = [e for e in errs if "net::" not in e and "AJAXError" not in e and "Failed to fetch" not in e]
        check("real MapLibre: no JavaScript errors", not real, real[:5])
        browser.close()


if __name__ == "__main__":
    main()
    bad = [r for r in T.results if not r[1]]
    print("ALL REAL-MAPLIBRE TESTS PASSED" if not bad else "%d FAILED" % len(bad))
    sys.exit(1 if bad else 0)
