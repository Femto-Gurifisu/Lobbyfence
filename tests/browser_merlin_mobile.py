"""Phone test of the Asuswrt-Merlin pages: a touch phone (iPhone-sized
viewport, touch, mobile) swipes over the page. It checks that:
  - one finger moves the map (no two-finger rule), two fingers still move / zoom it
  - one finger over a drawn region moves the map too (the region is selected,
    not dragged away); its handles still move it without scrolling the page
  - the page scrolls with a swipe beside the map (the map leaves room for it):
    every part is reachable, the panel, Save & Apply at the bottom
  - in full screen one finger moves the map as well
  - the router's page offers the phone layout on a phone (not on a computer)
Runs inside merlin_browser_test.sh's router (LF_BROWSER_SCRIPT=browser_merlin_mobile.py),
on browser_merlin.py's stand-in for Merlin's web server.
    usage: python3 browser_merlin_mobile.py <workdir> <router-ns-pid> <maplibre dist> [screenshot dir]
"""
import json
import sys

from playwright.sync_api import sync_playwright

import browser_merlin as bm

check = bm.check
PHONE = dict(viewport={"width": 390, "height": 844}, device_scale_factor=3, is_mobile=True, has_touch=True,
             user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1")


def touch(cdp, page, kind, pts):
    cdp.send("Input.dispatchTouchEvent", {"type": kind, "touchPoints": [{"x": x, "y": y, "id": i} for i, (x, y) in enumerate(pts)]})


def swipe(page, cdp, x, y, dy, fingers=1, dx=0, steps=12):
    """a swipe at (x, y): dy < 0 = the finger(s) move up = the page should scroll down"""
    start = [(x + 40 * i, y) for i in range(fingers)]
    touch(cdp, page, "touchStart", start)
    for k in range(1, steps + 1):
        touch(cdp, page, "touchMove", [(px + dx * k / steps, py + dy * k / steps) for px, py in start])
        page.wait_for_timeout(16)
    page.wait_for_timeout(150)          # (the finger rests before lifting: no fling)
    touch(cdp, page, "touchEnd", [])
    page.wait_for_timeout(450)


def tap(page, cdp, x, y):
    touch(cdp, page, "touchStart", [(x, y)])
    page.wait_for_timeout(40)
    touch(cdp, page, "touchEnd", [])
    page.wait_for_timeout(500)


def sy(page):
    return round(page.evaluate("window.scrollY"))


def box(page, sel):
    return page.evaluate("(s) => { const e = document.querySelector(s); if (!e) return null; const r = e.getBoundingClientRect(); return [r.left, r.top, r.width, r.height]; }", sel)


def beside_map(page):
    """a point on the screen beside the map (toolbar / panel), lowest first: swipes there scroll the page"""
    m = box(page, ".lf-mapwrap")
    if m[1] + m[3] < 790:
        return (195, 830)
    if m[1] > 60:
        return (195, max(20, m[1] - 20))
    return None


CIRCLE = """() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap);
    return JSON.stringify(n.lfMap.getSource('lf-circles').serialize().data.features.filter(f => f.properties.kind === 'circle').map(f => f.geometry.coordinates[0].slice(0, 3))); }"""


def handle_in_map(page):
    """where the selected region's centre handle sits inside the map (moves only when the map or region moves)"""
    return page.evaluate("""() => { const m = document.querySelector('.lf-mapwrap'); const h = [...document.querySelectorAll('.lf-mapwrap .maplibregl-marker')]
        .find(e => getComputedStyle(e.firstElementChild || e).cursor === 'move' || (e.firstElementChild && e.firstElementChild.style.cursor === 'move'));
        if (!m || !h) return null; const a = m.getBoundingClientRect(), b = h.getBoundingClientRect();
        return [Math.round(b.left - a.left + b.width / 2), Math.round(b.top - a.top + b.height / 2)]; }""")


def main():
    errs = []
    with sync_playwright() as p:
        b = p.chromium.launch()
        ctx = bm.router_context(b, **PHONE)
        page = ctx.new_page()
        page.on("pageerror", lambda e: errs.append("page: " + str(e)))
        cdp = ctx.new_cdp_session(page)

        # ------------------------------------------------ the phone layout (app.asp on its own)
        page.goto("http://router.test/user/lobbyfence/app.asp")
        page.wait_for_selector(".maplibregl-canvas", timeout=40000)
        page.wait_for_function("document.querySelector('.lf-panel') && document.querySelector('.lf-panel').innerText.includes('Running')", timeout=20000)
        page.wait_for_timeout(1500)
        m = box(page, ".lf-mapwrap")
        check("phone: the map leaves room for the page around it (under 2/3 of the screen)", m and m[3] < 844 * 0.66, m)
        check("phone: one finger moves the map - no 'use two fingers' rule (MapLibre cooperative gestures off)",
              not page.evaluate("!!document.querySelector('.maplibregl-cooperative-gestures')"))
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-app-top.png"))

        # zoom in on the region drawn around Frankfurt and tap it (beside the server dot on it):
        # selected, its handles show where the map is
        page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); n.lfMap.jumpTo({ center: [8.6821, 50.1109], zoom: 4 }); }")
        page.wait_for_timeout(800)
        m = box(page, ".lf-mapwrap")
        tap(page, cdp, m[0] + m[2] / 2 + 60, m[1] + m[3] / 2 + 40)
        h0 = handle_in_map(page)
        check("phone: a tap on the region selects it (handles shown)", h0 is not None, page.evaluate("document.querySelectorAll('.maplibregl-marker').length"))

        # one finger over the region: the map moves (the region with it), the region isn't dragged, the page stays
        c0 = page.evaluate(CIRCLE)
        s0 = sy(page)
        swipe(page, cdp, m[0] + m[2] / 2, m[1] + m[3] * 0.6, -90, dx=-70)
        h1 = handle_in_map(page)
        check("phone: one finger over the map (and the region on it) moves the map, the page stays",
              h0 is not None and h1 is not None and h1 != h0 and abs(sy(page) - s0) < 5, [h0, h1, s0, sy(page)])
        check("phone: ... and the region stays where it was drawn (not dragged by the finger)", page.evaluate(CIRCLE) == c0)

        page.evaluate("window.scrollTo(0, 0)"); page.wait_for_timeout(300)
        m = box(page, ".lf-mapwrap")
        swipe(page, cdp, m[0] + 60, m[1] + m[3] * 0.5, -120, fingers=2, dx=-80)
        h2 = handle_in_map(page)
        check("phone: two fingers still move the map (the page stays)", h2 is not None and h2 != h1 and sy(page) < 30, [h1, h2, sy(page)])
        pitch = page.evaluate("() => [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap).lfMap.getPitch()")
        check("phone: two fingers sliding up don't tilt the map", pitch == 0, pitch)

        # the region's centre handle: moves the region, the page doesn't scroll
        hb = page.evaluate("""() => { const h = [...document.querySelectorAll('.lf-mapwrap .maplibregl-marker')].find(e => (e.style.cursor === 'move' || (e.firstElementChild && e.firstElementChild.style.cursor === 'move')));
            if (!h) return null; const r = h.getBoundingClientRect(); return [r.left + r.width / 2, r.top + r.height / 2]; }""")
        if hb:
            s2 = sy(page)
            swipe(page, cdp, hb[0], hb[1], 60, dx=50)
            h3 = handle_in_map(page)
            check("phone: dragging the region's handle moves the region, not the page", h3 is not None and h3 != h2 and abs(sy(page) - s2) < 5
                  and page.evaluate(CIRCLE) != c0, [h2, h3, s2, sy(page)])
        else:
            check("phone: region handle found", False)

        # the page: a swipe beside the map scrolls it - everything reachable
        pt = beside_map(page)
        check("phone: the map leaves room beside it to scroll the page", pt is not None, box(page, ".lf-mapwrap"))
        s0 = sy(page)
        swipe(page, cdp, pt[0], pt[1], -300)
        check("phone: one finger swiping beside the map scrolls the page", sy(page) >= s0 + 150, [s0, sy(page)])
        for _ in range(14):
            pt = beside_map(page) or (195, 830)
            swipe(page, cdp, pt[0], pt[1], -450)
        a = box(page, "#lf-apply")
        check("phone: swiping reaches the bottom - Save & Apply on the screen", a and 0 <= a[1] and a[1] + a[3] <= 844 and
              sy(page) >= page.evaluate("document.scrollingElement.scrollHeight - innerHeight") - 2, [a, sy(page)])
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-app-bottom.png"))
        # the panel on a phone: part of the page, not a box of its own that keeps the
        # finger once a few pixels of it scroll (a real phone's fonts can make its content
        # a pixel taller than the box - forced here with an extra pixel)
        page.evaluate("""() => { const p = document.querySelector('.lf-panel'); const x = document.createElement('div');
            x.id = 'lf-test-px'; x.style.cssText = 'height:3px;flex-shrink:0'; p.appendChild(x);
            const h = p.getBoundingClientRect().height; p.style.setProperty('height', (h - 3) + 'px', 'important'); }""")
        ov = page.evaluate("(() => { const p = document.querySelector('.lf-panel'), s = getComputedStyle(p); return [s.overflowY, s.overscrollBehaviorY, p.scrollHeight - p.clientHeight]; })()")
        pb = box(page, ".lf-panel")
        y0 = sy(page)
        swipe(page, cdp, 195, min(800, pb[1] + pb[3] - 60), 350)
        y1 = sy(page)
        swipe(page, cdp, 195, min(800, pb[1] + pb[3] - 60), -200)
        y2 = sy(page)
        check("phone: swiping on the panel scrolls the page, also at the panel's end (both ways)",
              y1 < y0 - 150 and y2 > y1 + 80, [ov, y0, y1, y2])
        check("phone: nothing wider than the screen (no sideways scrolling)",
              page.evaluate("document.scrollingElement.scrollWidth <= innerWidth"), page.evaluate("[document.scrollingElement.scrollWidth, innerWidth]"))
        page.evaluate("() => { const x = document.getElementById('lf-test-px'); x && x.remove(); document.querySelector('.lf-panel').style.removeProperty('height'); }")
        # and back up, swiping beside the map (from the top of the screen)
        for _ in range(14):
            m = box(page, ".lf-mapwrap")
            y = 20 if m[1] > 60 or m[1] + m[3] < 0 else min(830, m[1] + m[3] + 20)
            swipe(page, cdp, 195, y, 450 if y < 400 else 0)
            if y >= 400:
                page.evaluate("window.scrollBy(0, -450)")
        check("phone: and back to the top", sy(page) == 0, sy(page))

        # full screen: one finger moves the map there too
        page.locator(".lf-btn", has_text="Full screen").first.dispatch_event("click")
        page.wait_for_timeout(600)
        m = box(page, ".lf-mapwrap")
        hf0 = handle_in_map(page)
        swipe(page, cdp, m[0] + m[2] / 2, m[1] + m[3] / 2 + 40, -100, dx=60)
        hf1 = handle_in_map(page)
        check("phone, full screen: one finger moves the map", not page.evaluate("!!document.querySelector('.maplibregl-cooperative-gestures')")
              and hf0 is not None and hf1 != hf0, [hf0, hf1])
        page.locator(".lf-btn", has_text="Exit full screen").first.dispatch_event("click")
        page.wait_for_timeout(600)
        check("phone: after full screen one finger still moves the map", not page.evaluate("!!document.querySelector('.maplibregl-cooperative-gestures')"))

        # ------------------------------------------------ a polygon on a phone: its middle handle moves it
        page.evaluate("window.scrollTo(0, 0)"); page.wait_for_timeout(300)
        page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); n.lfMap.jumpTo({ center: [-90, 37.8], zoom: 3 }); }")
        page.wait_for_timeout(800)
        m = box(page, ".lf-mapwrap")
        tap(page, cdp, m[0] + m[2] / 2 + 20, m[1] + m[3] / 2 + 20)
        pos = """() => { const r = e => { const b = e.getBoundingClientRect(); return [Math.round(b.left + b.width / 2), Math.round(b.top + b.height / 2)]; };
            const mk = [...document.querySelectorAll('.lf-mapwrap .maplibregl-marker')];
            const mid = mk.find(e => !e.classList.contains('lf-vertex') && e.style.cursor === 'move');
            const v = mk.filter(e => e.classList.contains('lf-vertex'));
            return { mid: mid ? r(mid) : null, v: v.map(r) }; }"""
        p0 = page.evaluate(pos)
        check("phone: tapping a polygon selects it - corner handles and a middle handle", p0["mid"] is not None and len(p0["v"]) == 4, p0)
        if p0["mid"]:
            s0 = sy(page)
            swipe(page, cdp, p0["mid"][0], p0["mid"][1], 50, dx=60)
            page.wait_for_timeout(300)
            p1 = page.evaluate(pos)
            moved = p1["v"] and all(abs(b[0] - a[0] - 60) <= 12 and abs(b[1] - a[1] - 50) <= 12 for a, b in zip(sorted(p0["v"]), sorted(p1["v"])))
            check("phone: dragging the middle handle moves the whole polygon, the page doesn't scroll",
                  moved and abs(sy(page) - s0) < 5, [p0, p1, s0, sy(page)])
            if bm.SHOTS:
                page.screenshot(path=str(bm.SHOTS / "mobile-polygon-moved.png"))

            # handles are finger-sized; a tap on a corner keeps the shape selected
            sz = page.evaluate("(() => { const v = document.querySelector('.lf-mapwrap .maplibregl-marker.lf-vertex'); const r = v.getBoundingClientRect(); return [r.width, r.height]; })()")
            check("phone: corner and middle handles are finger-sized (44 px targets)", sz[0] >= 40 and sz[1] >= 40, sz)
            v = sorted(p1["v"])[0]
            tap(page, cdp, v[0], v[1])
            check("phone: tapping a corner doesn't deselect the polygon", len(page.evaluate(pos)["v"]) == 4, page.evaluate(pos))
            # one finger drags a corner, the page stays put
            s0 = sy(page)
            q0 = page.evaluate(pos)
            v = sorted(q0["v"])[0]
            swipe(page, cdp, v[0], v[1], 30, dx=-40)
            page.wait_for_timeout(300)
            q1 = page.evaluate(pos)
            moved_one = sum(1 for a, b in zip(sorted(q0["v"]), sorted(q1["v"])) if a != b)
            check("phone: one finger drags a corner (only that corner moves), the page doesn't scroll",
                  len(q1["v"]) == 4 and abs(sy(page) - s0) < 5 and any(abs(b[0] - (v[0] - 40)) <= 10 and abs(b[1] - (v[1] + 30)) <= 10 for b in q1["v"]),
                  [q0, q1, moved_one])
            # holding a finger on a corner removes it (no right-click on phones), but never below 3
            mc = box(page, ".lf-mapwrap"); mcx, mcy = mc[0] + mc[2] / 2, mc[1] + mc[3] / 2
            v = min(q1["v"], key=lambda c: (c[0] - mcx) ** 2 + (c[1] - mcy) ** 2)
            touch(cdp, page, "touchStart", [(v[0], v[1])]); page.wait_for_timeout(900); touch(cdp, page, "touchEnd", []); page.wait_for_timeout(700)
            q2 = page.evaluate(pos)
            check("phone: holding a corner removes it", len(q2["v"]) == 3, q2)
            v = min(q2["v"], key=lambda c: c[0])      # (away from the zoom buttons at the right)
            touch(cdp, page, "touchStart", [(v[0], v[1])]); page.wait_for_timeout(900); touch(cdp, page, "touchEnd", []); page.wait_for_timeout(700)
            check("phone: ...but a polygon keeps at least 3 corners (and says so)", len(page.evaluate(pos)["v"]) == 3 and "at least 3 corners" in page.locator("body").inner_text(), page.evaluate(pos))

        # ------------------------------------------------ drawing a polygon with taps
        npoly = page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); return n.lfMap.getSource('lf-circles').serialize().data.features.filter(f => f.properties.kind === 'polygon').length; }")
        page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); n.lfMap.jumpTo({ center: [100, -30], zoom: 3 }); }")
        page.wait_for_timeout(600)
        page.locator(".lf-btn", has_text="Draw polygon").first.dispatch_event("click")
        page.wait_for_timeout(300)
        m = box(page, ".lf-mapwrap")
        cx, cy = m[0] + m[2] / 2, m[1] + m[3] / 2
        corners = [(cx - 80, cy - 60), (cx + 80, cy - 60), (cx + 80, cy + 60), (cx + 20, cy + 90)]
        for x, y in corners:
            tap(page, cdp, x, y)
        dash = page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); return [n.lfMap.getPaintProperty('lf-draft-line', 'line-dasharray'), n.lfMap.getPaintProperty('lf-draft-line', 'line-width')]; }")
        check("phone: the outline being drawn is a solid line (not dashed)", dash[0] is None and dash[1] >= 2.5, dash)
        nd = lambda: page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); return n.lfMap.getSource('lf-draft').serialize().data.features.filter(f => f.geometry.type === 'Point').length; }")
        placed = page.evaluate("""() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); const r = n.lfMap.getCanvas().getBoundingClientRect();
            return n.lfMap.getSource('lf-draft').serialize().data.features.filter(f => f.geometry.type === 'Point').map(f => { const p = n.lfMap.project(f.geometry.coordinates); return [Math.round(p.x + r.left), Math.round(p.y + r.top)]; }); }""")
        check("phone: each tap places a corner exactly under the finger (the map doesn't jump while drawing)",
              len(placed) == 4 and all(abs(a[0] - b[0]) <= 3 and abs(a[1] - b[1]) <= 3 for a, b in zip(placed, corners)), [placed, corners])
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-polygon-drawing.png"))
        ub = page.locator(".lf-undocorner")
        check("phone: Undo corner is offered while drawing", ub.is_visible())
        ub.dispatch_event("click"); page.wait_for_timeout(300)
        check("phone: Undo corner takes the last corner back", nd() == 3, nd())
        # a finger lands near, not exactly on, the first corner: closes the shape
        tap(page, cdp, corners[0][0] + 15, corners[0][1] + 12)
        page.wait_for_timeout(600)
        n2 = page.evaluate("() => { const n = [...document.querySelectorAll('.lf-mapwrap *')].find(e => e.lfMap); return n.lfMap.getSource('lf-circles').serialize().data.features.filter(f => f.properties.kind === 'polygon').length; }")
        check("phone: tapping near the first corner closes the polygon (finger-sized target)", n2 == npoly + 1 and nd() == 0 and not ub.is_visible(), [npoly, n2, nd()])

        # ------------------------------------------------ switching a zone to another game
        page.locator(".lf-changegame").click()
        page.wait_for_selector(".lf-cg-game", timeout=5000)
        page.locator(".lf-cg-game").select_option("fortnite")
        page.locator(".lf-cg-platform").select_option("ps")
        vals = page.evaluate("[document.querySelector('.lf-cg-ports').value, document.querySelector('.lf-cg-burst').value, document.querySelector('.lf-cg-proto').value]")
        check("change game: picking Fortnite on PlayStation fills its ports, UDP and open for server tests 2", "36300-36399" in vals[0] and vals[1] == "2" and vals[2] == "udp", vals)
        kn = page.locator(".lf-cg-keep")
        check("change game: says the learned servers stay saved under the old game", kn.is_visible() and "stay saved under" in kn.inner_text()
              and "Fortnite" in kn.inner_text(), kn.inner_text())
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-change-game.png"))
        page.locator(".lf-cg-apply").click()
        page.wait_for_timeout(500)
        zg = page.locator(".lf-zonegame").inner_text()
        bs = page.evaluate("document.querySelector('.lf-burst-burst_servers') && document.querySelector('.lf-burst-burst_servers').value")
        check("change game: the zone now shows Fortnite, open for server tests 2 (device and region kept)",
              "Fortnite" in zg and "PlayStation" in zg and bs == "2" and page.evaluate("document.querySelectorAll('.lf-region-row, .lf-circles > *').length") >= 1, [zg, bs])

        # ------------------------------------------------ the home-screen app
        page.evaluate("try { localStorage.removeItem('lobbyfence.installTip') } catch (e) {}")
        page.goto("http://router.test/user/lobbyfence/app.asp")
        page.wait_for_selector("#lf-install", timeout=15000)
        t = page.locator("#lf-install").inner_text()
        check("phone in the browser: a tip to add LobbyFence to the home screen, tap it to see how", "home screen" in t and "tap here" in t, t)
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-app-tip.png"), clip={"x": 0, "y": 0, "width": 390, "height": 260})
        tap(page, cdp, 150, box(page, "#lf-install")[1] + 20)
        g = page.locator("#lf-guide")
        gt = g.inner_text() if g.count() else ""
        check("iPhone: tapping the tip shows the steps (Share > Add to Home Screen > Add) with an arrow to the Share button",
              g.count() == 1 and "Add to Home Screen" in gt and "Share" in gt and page.locator("#lf-guide .lf-g-bottom-center").count() == 1, gt[:300])
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-guide-iphone.png"))
        page.locator("#lf-guide .lf-gok").click()
        check("'Got it' closes the guide, the tip stays", page.locator("#lf-guide").count() == 0 and page.locator("#lf-install").count() == 1)

        # Brave on Android (navigator.brave): its menu at the bottom right, and how to get
        # the real app window (the router's http address allowed as secure in brave://flags)
        bp = ctx.new_page()
        bp.set_viewport_size({"width": 412, "height": 915})
        bp.add_init_script("""Object.defineProperty(Navigator.prototype, 'userAgent', { get: () => 'Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36', configurable: true });
            Object.defineProperty(Navigator.prototype, 'brave', { get: () => ({ isBrave: () => Promise.resolve(true) }), configurable: true });""")
        bp.goto("http://router.test/user/lobbyfence/app.asp")
        bp.wait_for_selector("#lf-install", timeout=15000)
        bp.locator("#lf-install .lf-go").click()
        bt = bp.locator("#lf-guide").inner_text() if bp.locator("#lf-guide").count() else ""
        check("Brave on Android: steps for Brave's menu \u22ee (bottom right) > Add to Home screen, arrow there",
              "Brave" in bt and "Add to Home screen" in bt and bp.locator("#lf-guide .lf-g-bottom-right").count() == 1, bt[:300])
        bp.locator("#lf-guide summary").click()
        bt = bp.locator("#lf-guide").inner_text()
        check("Brave: how to get the real app window (brave://flags, this router's address)",
              "brave://flags" in bt and "Insecure origins treated as secure" in bt and "http://router.test" in bt, bt[-400:])
        if bm.SHOTS:
            bp.screenshot(path=str(bm.SHOTS / "mobile-guide-brave.png"))
        # where the browser can install it (HTTPS, or that setting): one tap opens its own dialog
        bp.evaluate("""() => { window.__prompted = 0; document.getElementById('lf-guide').remove();
            const e = new Event('beforeinstallprompt', { cancelable: true });
            e.prompt = () => { window.__prompted++; return Promise.resolve(); }; e.userChoice = Promise.resolve({ outcome: 'accepted' });
            window.dispatchEvent(e); }""")
        bp.wait_for_timeout(300)
        lab = bp.locator("#lf-install .lf-go").inner_text()
        bp.locator("#lf-install span").click()
        bp.wait_for_timeout(400)
        check("browser offers installing: the tip says Install and a tap opens the browser's own install dialog",
              lab == "Install" and bp.evaluate("window.__prompted") == 1 and bp.locator("#lf-guide").count() == 0, [lab, bp.evaluate("window.__prompted")])
        bp.close()
        page.locator("#lf-install button.lf-x").click()
        page.reload(); page.wait_for_selector(".lf-app", timeout=30000); page.wait_for_timeout(800)
        check("phone: the tip closed stays closed", page.locator("#lf-install").count() == 0)
        man = cdp.send("Page.getAppManifest")
        mj = json.loads(man.get("data") or "{}")
        icons = {i["src"].split("/")[-1]: i for i in mj.get("icons", [])}
        check("app manifest: read by the browser without errors (name, start page, own window, icons)",
              not man.get("errors") and mj.get("name") == "LobbyFence" and mj.get("display") == "standalone"
              and mj.get("start_url") == "/user/lobbyfence/app.asp?app=1" and "icon-512.png" in icons and icons.get("icon-maskable-512.png", {}).get("purpose") == "maskable",
              [man.get("errors"), man.get("url"), (man.get("data") or "")[:200]])
        crossorigin = page.evaluate("document.querySelector('link[rel=manifest]').getAttribute('crossorigin')")
        check("manifest fetched with the login cookie (Merlin's web server wants it for .json)", crossorigin == "use-credentials", crossorigin)
        sizes = page.evaluate("""async () => { const out = {}; for (const n of ['icon-192.png', 'icon-512.png', 'icon-maskable-512.png', 'apple-touch-icon.png', 'favicon-32.png']) {
            const r = await fetch('/user/lobbyfence/' + n); const b = await createImageBitmap(await r.blob()); out[n] = [r.status, r.headers.get('content-type'), b.width]; } return out; }""")
        check("app icons served as images at their sizes (192, 512, maskable 512, iPhone 180, tab 32)",
              sizes == {"icon-192.png": [200, "image/png", 192], "icon-512.png": [200, "image/png", 512], "icon-maskable-512.png": [200, "image/png", 512],
                        "apple-touch-icon.png": [200, "image/png", 180], "favicon-32.png": [200, "image/png", 32]}, sizes)
        meta = page.evaluate("""() => ({ ios: document.querySelector('meta[name=apple-mobile-web-app-capable]')?.content,
            title: document.querySelector('meta[name=apple-mobile-web-app-title]')?.content,
            touch: document.querySelector('link[rel=apple-touch-icon]')?.getAttribute('href') })""")
        check("iPhone home-screen app tags (own window, name, icon)", meta == {"ios": "yes", "title": "LobbyFence", "touch": "/user/lobbyfence/apple-touch-icon.png"}, meta)
        inst = cdp.send("Page.getInstallabilityErrors").get("installabilityErrors", [])
        other = [e["errorId"] for e in inst if e["errorId"] not in ("not-from-secure-origin", "no-matching-service-worker", "no-icon-available")]
        print("installability (http test server):", [e["errorId"] for e in inst])
        check("nothing but the plain-http address keeps Chrome/Brave from installing it", not other, inst)
        # opened from the home screen: an app window (as on an iPhone: navigator.standalone;
        # Chromium can't fake display-mode: standalone)
        app = ctx.new_page()
        app.add_init_script("Object.defineProperty(Navigator.prototype, 'standalone', { get: () => true, configurable: true })")
        app.goto("http://router.test/user/lobbyfence/app.asp?app=1")
        app.wait_for_selector(".lf-app", timeout=30000); app.wait_for_timeout(800)
        check("opened from the home screen: no install tip, a 'Router' link to the router's own pages (no address bar there)",
              app.locator("#lf-install").count() == 0 and app.locator("#lf-router").get_attribute("href") == "/"
              and app.evaluate("document.documentElement.classList.contains('lf-standalone')"))
        if bm.SHOTS:
            app.screenshot(path=str(bm.SHOTS / "mobile-app-standalone.png"))
        app.close()

        # ------------------------------------------------ the router's page: offers the phone layout
        page.goto("http://router.test/" + bm.PAGE)
        page.wait_for_selector("#lf-frame", timeout=15000)
        page.wait_for_timeout(800)
        ph = page.locator("#lf-phone")
        check("router page on a phone: link to the phone layout shown", ph.is_visible() and ph.get_attribute("href") == "/user/lobbyfence/app.asp")
        page.evaluate("try { localStorage.removeItem('lobbyfence.installTip') } catch (e) {}")
        page.reload(); page.wait_for_selector("#lf-frame", timeout=15000)
        page.wait_for_function("() => { const d = document.getElementById('lf-frame').contentDocument; return d && d.querySelector('.lf-app'); }", timeout=40000)
        page.wait_for_timeout(800)
        check("router page on a phone: no 'add to home screen' tip there (only in the phone layout)",
              page.evaluate("document.getElementById('lf-frame').contentDocument.getElementById('lf-install') === null"))
        if bm.SHOTS:
            page.screenshot(path=str(bm.SHOTS / "mobile-asus.png"))
        ctx2 = bm.router_context(b, viewport={"width": 1300, "height": 1000})
        dp = ctx2.new_page()
        dp.goto("http://router.test/" + bm.PAGE)
        dp.wait_for_selector("#lf-frame", timeout=15000)
        dp.wait_for_timeout(500)
        fh = dp.evaluate("document.getElementById('lf-frame').getBoundingClientRect().height")
        check("router page on a computer: no phone link; the map's frame fills the window below it",
              not dp.locator("#lf-phone").is_visible() and 560 <= fh <= 1000, fh)

        real = [e for e in errs if "favicon" not in e and "404" not in e]
        check("no JavaScript errors", not real, real[:5])
        b.close()


if __name__ == "__main__":
    main()
    res = bm.results
    print("ALL MERLIN MOBILE TESTS PASSED" if all(res) else "%d FAILED" % res.count(False))
    sys.exit(0 if all(res) else 1)
