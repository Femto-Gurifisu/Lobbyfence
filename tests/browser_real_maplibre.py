"""The map page against the REAL MapLibre GL JS build (WebGL via SwiftShader).

browser_map_test.py uses a small MapLibre stand-in so it runs anywhere; this
test loads the actual library files, so drawing (shapes, server dots, the home
pin), themes, the globe and the View menu are checked on the real renderer.
    usage: python3 browser_real_maplibre.py <maplibre-dist-dir> [screenshot-dir] [positron style.json]
    (the dist directory of a maplibre-gl release, e.g. from its GitHub dist.zip)
"""
import json
import math
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


def globe_edge_gaps(page, lngs):
    """The globe turned to each longitude, small, and its outline measured row by row against the circle it should
    be: the most any row falls short of it (pixels - 0 when whole), and the map's padding on the panel's side."""
    import io
    from PIL import Image
    worst, where, shot = 0, None, None
    pad = page.evaluate("window.view.map.getPadding().right || 0")
    # (the map itself: the page's own layers - shapes, servers, the pin - hidden meanwhile, their edges aren't the globe's)
    hidden = page.evaluate("""(() => { const m = window.view.map, ids = m.getStyle().layers.map(l => l.id)
            .filter(id => id.startsWith('lf-') && m.getLayoutProperty(id, 'visibility') !== 'none');
        ids.forEach(id => m.setLayoutProperty(id, 'visibility', 'none')); return ids; })()""")
    for lng in lngs:
        page.evaluate("lng => window.view.map.jumpTo({ center: [lng, 5], zoom: 1.2, bearing: 0, pitch: 0 })", lng)
        page.wait_for_function("window.view.map.loaded() && window.view.map.areTilesLoaded()", timeout=15000)
        page.wait_for_timeout(250)
        g = page.evaluate("""(() => { const m = window.view.map, c = m.getCanvas().getBoundingClientRect(), p = m.project(m.getCenter()),
            n = parseInt(getComputedStyle(document.querySelector('.lf-app')).getPropertyValue('--lf-space').trim().slice(1), 16);
            return { left: c.left, top: c.top, w: c.width, h: c.height, x: p.x, y: p.y, space: [n >> 16, (n >> 8) & 255, n & 255] }; })()""")
        im = Image.open(io.BytesIO(page.screenshot(clip={"x": g["left"], "y": g["top"], "width": g["w"], "height": g["h"]}))).convert("RGB")
        px, W, H = im.load(), im.size[0], im.size[1]
        globe = lambda x, y: sum(abs(a - b) for a, b in zip(px[x, y], g["space"])) > 18
        cx = int(round(g["x"]))
        col = [y for y in range(H) if globe(cx, y)]
        if not col:
            worst, where = 999, (lng, "no globe")
            break
        top, bot = col[0], col[-1]
        r, cy = (bot - top) / 2.0, (bot + top) / 2.0
        lo, hi = max(0, int(cx - r - 30)), min(W - 1, int(cx + r + 30))
        for y in range(int(cy - 0.85 * r), int(cy + 0.85 * r), 3):
            half = math.sqrt(r * r - (y - cy) ** 2)
            xs = [x for x in range(lo, hi + 1) if globe(x, y)]
            if not xs:
                worst, where = 999, (lng, "row %d empty" % y)
                break
            short = max(xs[0] - (cx - half), (cx + half) - xs[-1])   # (the edge left of / right of where it should be)
            if short > worst:
                worst, where, shot = short, (lng, y, xs[0], xs[-1], round(cx - half), round(cx + half)), im
    page.evaluate("ids => ids.forEach(id => window.view.map.setLayoutProperty(id, 'visibility', 'visible'))", hidden)
    if SHOTS and shot:
        shot.save(str(SHOTS / "real-globe-edge.png"))   # (where it fell shortest)
    return {"worst": round(worst, 1), "at": where, "pad": pad}


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
        page.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", lambda r: r.fulfill(content_type="application/json", body='{"tag_name": "v1.1.0"}', headers={"Access-Control-Allow-Origin": "*"}))   # (the page asks GitHub for the newest version)

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
        # around the globe: space that sets it apart - its sea is the colour of the flat map's surroundings, so with
        # those around it the globe melted into the background (a user's recording)
        bgjs = """(() => { const a = document.querySelector('.lf-app'), cs = getComputedStyle(a), hex = (h) => { const n = parseInt(h.slice(1), 16);
            return 'rgb(' + (n >> 16) + ', ' + ((n >> 8) & 255) + ', ' + (n & 255) + ')'; };
            return { bg: getComputedStyle(document.querySelector('.lf-mapwrap')).backgroundColor, space: hex(cs.getPropertyValue('--lf-space').trim()),
                     sea: hex(cs.getPropertyValue('--lf-sea').trim()), globe: a.classList.contains('lf-globe') }; })()"""
        bg = page.evaluate(bgjs)
        check("real MapLibre: around the globe, space that sets it apart - not the sea colour", bg["globe"] and bg["bg"] == bg["space"] and bg["space"] != bg["sea"], bg)
        # labels on a spinning globe: placed afresh every frame - with MapLibre's fade between placements names from the
        # far side showed through, in the wrong places, for a moment (a user's recording)
        check("real MapLibre: on the globe, labels placed on every frame (no fade between placements)", page.evaluate("window.view.map._fadeDuration") == 0)
        # the globe's edge on the panel's side, turning it: whole - with the view off-centre (clear of the panel) MapLibre
        # left out the tiles at the edge there and a slice of the globe went missing as it turned (a user's recording)
        fixed = page.evaluate("""(() => { const t = window.view.map._camera.transform, v = t && t._verticalPerspectiveTransform;
            return !!(v && Object.getPrototypeOf(v).lfFullDepth); })()""")
        check("real MapLibre: the globe's tiles worked out with the view off-centre (the fix is in place)", fixed)
        gaps = globe_edge_gaps(page, range(-150, 180, 15))
        check("real MapLibre: the globe's edge whole all the way round as it turns, panel open (no slice missing)",
              gaps["pad"] > 0 and gaps["worst"] <= 3, gaps)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-globe.png"))
        page.get_by_role("button", name="Globe").click()
        page.wait_for_timeout(800)
        bg = page.evaluate(bgjs)
        check("real MapLibre: ...the flat map again: the sea past the world's edge", not bg["globe"] and bg["bg"] == bg["sea"], bg)
        check("real MapLibre: ...and labels fading in and out again", page.evaluate("window.view.map._fadeDuration") == 300)

        page.locator("button", has_text="View").click()
        page.locator(".lf-menu").get_by_text("Endless map").click()
        page.locator(".lf-menu").get_by_text("Country borders").click()
        # Zoomed out as far as it goes, the whole world is in view - Greenland's north to Antarctica (WORLD_BOUNDS), all the
        # way round - as big as it fits in the part of the map in view (the panel over the map's corner covers the rest:
        # the map's padding). That is Fit's view too. A world smaller than the part in view sits in its middle (sea around
        # it); a bigger one never shows empty space at its edges.
        whole = """() => { const m = window.view.map, c = m.getContainer(), w = c.clientWidth - (m.getPadding().right || 0), h = c.clientHeight;
            const l = m.project([-180, 0]).x, r = m.project([180, 0]).x, t = m.project([0, 84]).y, b = m.project([0, -78]).y;
            const endless = window.view.endless, ws = r - l;
            return [(endless || (l >= -1 && r <= w + 1)) && t >= -1 && b <= h + 1 && (ws >= w - 3 || b - t >= h - 3)
                    && (endless || ws >= w - 3 || Math.abs((l + r) / 2 - w / 2) < 2), [l, r, t, b, w, h].map(Math.round), m.getZoom(), m.getMinZoom()]; }"""
        proper = """() => { const m = window.view.map, c = m.getContainer(), w = c.clientWidth - (m.getPadding().right || 0), h = c.clientHeight;
            const l = m.project([-180, 0]).x, r = m.project([180, 0]).x, t = m.project([0, 85.0511]).y, b = m.project([0, -85.0511]).y;
            const okx = window.view.endless || (r - l > w ? l <= 2 && r >= w - 2 : Math.abs((l + r) / 2 - w / 2) < 2);
            const oky = b - t > h ? t <= 2 && b >= h - 2 : Math.abs((t + b) / 2 - h / 2) < 2;
            return [okx && oky, [l, r, t, b, w, h].map(Math.round), m.getZoom()]; }"""
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        page.wait_for_timeout(300)
        r = page.evaluate(whole)
        check("real MapLibre: zoomed out as far as it goes, the whole world is in view (Greenland to Antarctica, all the way round)", r[0], r)
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        r2 = page.evaluate(whole)
        check("real MapLibre: ...and no further (the world does not shrink past that)", r2[0] and abs(r2[2] - r[2]) < 0.01, [r, r2])
        # the bug from a user's recording: endless map off after scrolling sideways left an empty strip
        # (the world half off-screen) until the next zoom - now put right at once
        page.evaluate("window.view.setEndless(true)")
        page.evaluate("window.view.map.jumpTo({ center: [150, 0], zoom: 2.2 })")
        page.wait_for_timeout(300)
        page.evaluate("window.view.setEndless(false)")
        page.wait_for_timeout(300)
        r = page.evaluate(proper)
        check("real MapLibre: endless map off after scrolling sideways - no empty strip, without touching the map", r[0], r)
        # the map area changes size (borderless, panel) while zoomed out all the way: still the whole world, at once
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        page.wait_for_timeout(300)
        page.evaluate("window.view.setBorderless(true)")
        page.wait_for_timeout(900)
        r = page.evaluate(whole)
        check("real MapLibre: zoomed out, borderless on: the whole world fitted to the bigger area at once", r[0], r)
        page.evaluate("window.view.setBorderless(false); window.view.setPanel(false)")
        page.wait_for_timeout(900)
        r = page.evaluate(whole)
        check("real MapLibre: ...borderless off, panel hidden: fitted again at once", r[0], r)
        page.evaluate("window.view.setPanel(true)")
        page.wait_for_timeout(900)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(900)
        r = page.evaluate(whole)
        check("real MapLibre: on a phone too (the world is wider than the screen at zoom 0)", r[0] and r[2] < 0, r)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-zoomout-phone.png"))
        page.set_viewport_size({"width": 1400, "height": 900})
        page.wait_for_timeout(900)
        check("real MapLibre: no Whole world in the View menu (zoomed out, the whole world is in view anyway)",
              page.evaluate("window.view.toggleViewMenu(true), [...document.querySelectorAll('.lf-menu .lf-mitem')].every(l => !/Whole world/.test(l.innerText))"))
        page.keyboard.press("Escape")
        # Fit: the whole world, as big as it fits in the part in view, in its middle
        seen = """() => { const m = window.view.map, c = m.getContainer(), pad = m.getPadding().right || 0;
            const w = c.clientWidth, h = c.clientHeight, v = w - pad, l = m.project([-180, 0]).x, r = m.project([180, 0]).x;
            const t = m.project([0, 84]).y, u = m.project([0, -78]).y, p = document.querySelector('.lf-panel'), pr = p.getBoundingClientRect(),
                  cr = c.getBoundingClientRect(), at = document.querySelector('.maplibregl-ctrl-attrib').getBoundingClientRect(),
                  nav = document.querySelector('.maplibregl-ctrl-zoom-in').getBoundingClientRect();
            return { w, h, pad, zoom: m.getZoom(), fit: window.view.fitWorld, ws: Math.round(r - l),
                     whole: l >= -1 && r <= v + 1 && t >= -1 && u <= h + 1 && (r - l >= v - 3 || u - t >= h - 3),
                     centred: Math.abs((l + r) / 2 - v / 2) < 2, sides: r - l < v - 3,
                     over: p.offsetParent !== null && getComputedStyle(p).position === 'absolute', panel: Math.round(pr.width),
                     inview: pad === 0 || Math.abs(cr.right - pr.left + 10 - pad) <= 2,
                     attrib: at.right <= cr.right - pad + 1, navleft: nav.left - cr.left < 60,
                     sea: getComputedStyle(document.querySelector('.lf-mapwrap')).backgroundColor }; }"""
        seawater = """(() => { const c = (window.view.theme().map || {}).water || '#0b1622', n = parseInt(c.slice(1), 16);
                  return 'rgb(' + (n >> 16) + ', ' + ((n >> 8) & 255) + ', ' + (n & 255) + ')'; })()"""
        page.evaluate("window.view.fitWorldView(false)")
        page.wait_for_timeout(600)
        r = page.evaluate(seen)
        check("real MapLibre: the panel over the map's corner (%d px); the map leaves the part under it out" % r["panel"],
              r["over"] and r["pad"] == r["panel"] + 20 and r["inview"], r)
        check("real MapLibre: ...Fit: the whole world, Greenland to Antarctica, as big as it fits in the part in view (%dx%d), in its middle"
              % (r["w"] - r["pad"], r["h"]), r["whole"] and r["centred"] and r["fit"], r)
        check("real MapLibre: ...the map's credits are not under the panel, the zoom buttons top left", r["attrib"] and r["navleft"], r)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-fit-page.png"))
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 }, { originalEvent: {} })")
        page.wait_for_timeout(300)
        r2 = page.evaluate(seen)
        check("real MapLibre: ...zooming out goes no further than Fit: Fit and the zoomed-out map are one and the same",
              abs(r2["zoom"] - r["zoom"]) < 0.01 and r2["whole"], [r, r2])
        # folding the panel away: the whole map in view, Fit (still in effect) fits the world to all of it
        page.evaluate("window.view.fitWorldView(false)")
        page.locator(".lf-ptab").click()
        page.wait_for_timeout(700)
        r = page.evaluate(seen)
        check("real MapLibre: the panel folded away: no padding, Fit fits the world to the whole map, in its middle",
              r["pad"] == 0 and r["whole"] and r["centred"] and r["fit"] and r["attrib"], r)
        check("real MapLibre: ...the space at its sides (a map wider than the world is tall) is the style's sea, not the panel colour",
              r["sides"] and r["sea"] == page.evaluate(seawater), r)
        page.locator(".lf-ptab").click()
        page.wait_for_timeout(700)
        r = page.evaluate(seen)
        check("real MapLibre: ...back: Fit fits the part in view again", r["pad"] == r["panel"] + 20 and r["whole"] and r["centred"] and r["fit"], r)
        # the full window / borderless on a wide screen: the map spans it, the panel over its corner, the world in the middle
        page.set_viewport_size({"width": 2100, "height": 1000})
        page.evaluate("window.view.setBorderless(true)")
        page.wait_for_timeout(900)
        page.evaluate("window.view.fitWorldView(false)")
        page.wait_for_timeout(600)
        r = page.evaluate(seen)
        check("real MapLibre: a wide screen, borderless (%dx%d map, %d px panel over it): Fit shows the whole world, sea at its sides"
              % (r["w"], r["h"], r["panel"]), r["over"] and r["whole"] and r["centred"] and r["sides"] and r["fit"], r)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-fit-wide-panel.png"))
        page.set_viewport_size({"width": 2400, "height": 1000})
        page.evaluate("window.view.setPanel(false)")
        page.wait_for_timeout(900)
        r = page.evaluate(seen)
        check("real MapLibre: ...wider still, the panel hidden (Fit stays in effect): the whole world in the middle", r["pad"] == 0 and r["whole"] and r["centred"] and r["fit"], r)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "real-fit-wide.png"))
        # zoomed in by hand, then out again: back to the whole world, no further
        page.evaluate("window.view.map.zoomTo(3, { duration: 0 }, { originalEvent: {} })")
        page.wait_for_timeout(400)
        r = page.evaluate(proper)
        check("real MapLibre: zoomed in by hand: no empty space at the edges", r[0] and page.evaluate("window.view.fitWorld === false"), r)
        page.evaluate("window.view.map.zoomTo(-2, { duration: 0 })")
        page.wait_for_timeout(400)
        r = page.evaluate(whole)
        check("real MapLibre: ...zoomed out again: the whole world", r[0], r)
        page.set_viewport_size({"width": 1400, "height": 900})
        page.evaluate("window.view.setBorderless(false); window.view.setPanel(true)")
        page.wait_for_timeout(900)
        page.set_viewport_size({"width": 390, "height": 844})
        page.wait_for_timeout(900)
        page.evaluate("window.view.fitWorldView(false)")
        page.wait_for_timeout(600)
        r = page.evaluate(seen)
        check("real MapLibre: a phone: the panel below the map (not over it), Fit shows the whole world across the screen",
              not r["over"] and r["pad"] == 0 and r["whole"] and r["fit"], r)
        page.set_viewport_size({"width": 1400, "height": 900})
        page.wait_for_timeout(900)
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
