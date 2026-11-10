"""Runs the LuCI map page in headless Chromium with LuCI and MapLibre stand-ins.

The unpkg URL of MapLibre is intercepted and answered with a small fake ES
module, so the page's real dynamic import() path is exercised. The basemap
style request is answered with a tiny style to check theme recolouring.
    usage: python3 browser_map_test.py [screenshot-dir]
"""
import json
import pathlib
import re
import sys

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAP_JS = (ROOT / "luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js").read_text()
SHOTS = pathlib.Path(sys.argv[1]) if len(sys.argv) > 1 else None

FAKE_MAPLIBRE = r"""
export class GPUInitializationError extends Error {}
class Evented {
  constructor() { this.h = {}; }
  on(t, a, b) { const k = b ? t + ':' + a : t; (this.h[k] = this.h[k] || []).push(b || a); return this; }
  fire(t, ev, layer) { (this.h[layer ? t + ':' + layer : t] || []).slice().forEach((f) => f(ev || {})); }
  off(t, f) { this.h[t] = (this.h[t] || []).filter((x) => x !== f); return this; }
  once(t, f) { const w = (e) => { this.off(t, w); f(e); }; return this.on(t, w); }
}
export class Map extends Evented {
  constructor(o) {
    super();
    if (window.__failGL) throw new GPUInitializationError('no webgl2');
    this.o = o; this.style = o.style; this.sources = {}; this.layers = {}; this.projection = null;
    this.center = { lng: o.center[0], lat: o.center[1] }; this.zoom = o.zoom;
    this.calls = []; this.styles = [o.style];
    this.canvas = document.createElement('canvas'); o.container.appendChild(this.canvas);
    this.touchZoomRotate = { disableRotation() {} };
    window.__map = this;
    setTimeout(() => this.fire('style.load'), 10);
  }
  addControl() {} isStyleLoaded() { return true; } getCanvas() { return this.canvas; }
  addSource(id, s) { this.sources[id] = { data: s.data, setData(d) { this.data = d; } }; }
  getSource(id) { return this.sources[id]; }
  addLayer(l) { this.layers[l.id] = l; } getLayer(id) { return this.layers[id]; }
  setProjection(p) { this.projection = p; }
  setRenderWorldCopies(on) { this.worldCopies = on; }
  getContainer() { return this.o.container; }
  hasImage(n) { return !!(this.images || {})[n]; }
  addImage(n, img, o) { (this.images = this.images || {})[n] = { w: img.naturalWidth, o }; }
  getStyle() { return this.style; }
  setLayoutProperty(id, k, v) { (this.layout = this.layout || {})[id + '.' + k] = v; }
  queryRenderedFeatures(pt, o) { return (window.__qrf || []).filter((f) => !o || !o.layers || o.layers.includes(f.layer)); }
  getCenter() { return this.center; } getZoom() { return this.zoom; }
  _move(kind, args, c, z) { this.calls.push([kind, args]); if (c) this.center = c; if (z != null) this.zoom = z; this.fire('moveend', {}); }
  fitBounds(b, o) { this._move('fitBounds', b, { lng: (b[0][0] + b[1][0]) / 2, lat: (b[0][1] + b[1][1]) / 2 }, 1.1); }
  jumpTo(o) { this._move('jumpTo', o, { lng: o.center[0], lat: o.center[1] }, o.zoom); }
  flyTo(o) { this._move('flyTo', o, { lng: o.center[0], lat: o.center[1] }, o.zoom); }
  userPan(lng, lat, z) { this.center = { lng, lat }; this.zoom = z; this.fire('move', {}); this.fire('moveend', { originalEvent: {} }); }
  setStyle(s) { this.style = s; this.styles.push(s); this.sources = {}; this.layers = {}; setTimeout(() => this.fire('style.load'), 10); }
  resize() { this.resized = (this.resized || 0) + 1; }
  project(p) { return { x: p[0] * 10, y: -p[1] * 10 }; }
  get doubleClickZoom() { const m = this; return { disable() { m.dblZoom = false; }, enable() { m.dblZoom = true; } }; }
  userClick(lng, lat) { this.fire('click', { lngLat: { lng, lat }, point: this.project([lng, lat]) }); }
}
export class Marker extends Evented {
  constructor(o) { super(); this.o = o; (window.__markers = window.__markers || []).push(this); }
  setLngLat(p) { this.p = Array.isArray(p) ? { lng: p[0], lat: p[1] } : p; return this; }
  getLngLat() { return this.p; } addTo() { return this; } remove() { this.removed = true; }
}
export class Popup extends Evented {
  constructor(o) { super(); this.o = o; }
  setLngLat(c) { this.c = c; return this; }
  setHTML(h) { this.html = h; return this; }
  setDOMContent(n) { if (this.node && this.node.parentNode) this.node.replaceWith(n); this.node = n; n.id = 'fake-popup'; this.html = n.outerHTML; return this; }
  addTo(m) { window.__popup = this; if (this.node) m.o.container.appendChild(this.node); return this; }
  remove() { if (this.node && this.node.parentNode) this.node.remove(); this.fire('close'); return this; }
}
export class NavigationControl {}
"""

FAKE_STYLE = {
    "version": 8, "center": [5, 5], "zoom": 4, "sources": {},
    "layers": [{"id": "background", "type": "background", "paint": {"background-color": "#f8f8f8"}}],
}

# Just enough LuCI for the view
HARNESS = r"""
<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;padding:16px;background:#e9ecef;font-family:sans-serif"><div id="root"></div>
<script>
/* (the stand-in map library is not the published release: accept any hash - the real one is checked by browser_real_maplibre.py) */
window.LF_TEST_MAPLIBRE_SHA256 = { 'maplibre-gl.mjs': '*', 'maplibre-gl-worker.mjs': '*', 'maplibre-gl.css': '*' };
window.L = { toArray: v => v == null ? [] : Array.isArray(v) ? v : String(v).split(/\s+/).filter(Boolean),
             resource: p => '/luci-static/resources/' + p,
             resolveDefault: (p, d) => Promise.resolve(p).catch(() => d) };
window._ = s => s;
String.prototype.format = function () { let i = 0; const a = arguments; return this.replace(/%[sd]/g, () => a[i++]); };
window.E = function (tag, attrs, children) {
  if (Array.isArray(tag)) { const f = document.createDocumentFragment(); tag.forEach(c => f.appendChild(c)); return f; }
  const el = document.createElement(tag);
  if (attrs && (typeof attrs !== 'object' || Array.isArray(attrs) || attrs instanceof Node)) { children = attrs; attrs = {}; }
  Object.keys(attrs || {}).forEach(k => {
    if (typeof attrs[k] === 'function') el.addEventListener(k, attrs[k]);
    else if (k === 'value') el.value = attrs[k]; else el.setAttribute(k, attrs[k]);
  });
  /* exactly LuCI's dom.append: strings in an array are text, a lone string is HTML */
  if (Array.isArray(children)) children.forEach(c => { if (c instanceof Node) el.appendChild(c); else if (c != null) el.appendChild(document.createTextNode(String(c))); });
  else if (children instanceof Node) el.appendChild(children);
  else if (children != null) el.innerHTML = String(children);
  return el;
};
window.uciState = {};
window.uci = {
  load: () => Promise.resolve(),
  sections: (c, t) => Object.values(uciState).filter(s => !t || s['.type'] === t),
  get: (c, s, o) => uciState[s] ? (o ? uciState[s][o] : uciState[s]) : null,
  set: (c, s, o, v) => { uciState[s][o] = v; },
  unset: (c, s, o) => { delete uciState[s][o]; },
  add: (c, t, n) => { uciState[n] = { '.name': n, '.type': t }; return n; },
  remove: (c, s) => { delete uciState[s]; },
  save: () => { window.__saved = JSON.parse(JSON.stringify(uciState)); window.__saves = (window.__saves || 0) + 1; return Promise.resolve(); },
  changes: () => Promise.resolve(window.__changes || {})
};
window.fs = {
  write: (p, d) => { (window.__writes = window.__writes || []).push([p, d]); return Promise.resolve(); },
  read: p => window.__files && window.__files[p] != null ? Promise.resolve(window.__files[p]) : Promise.reject(new Error('ENOENT')),
  exec: (cmd, args) => {
    if (args && args[0] === 'devices') return Promise.resolve({ code: 0, stdout: JSON.stringify(window.__devices || []) });
    if (args && args[0] === 'live') return Promise.resolve(window.__live ? { code: 0, stdout: JSON.stringify(window.__live) } : { code: 1, stdout: '' });
    if (args && args[0] === 'builtin-servers') return Promise.resolve(window.__builtin != null ? { code: 0, stdout: window.__builtin } : { code: 1, stdout: '', stderr: 'unknown command' });
    (window.__execs = window.__execs || []).push([cmd].concat(args)); return Promise.resolve(window.__execResult || { code: 0, stdout: '' }); }
};
window.ui = {
  showModal: (title, content) => { const m = E('div', { id: 'modal' }, [ E('h4', {}, title) ].concat(content)); document.body.appendChild(m); },
  hideModal: () => { const m = document.getElementById('modal'); if (m) m.remove(); },
  changes: { init: () => { window.__changesInit = (window.__changesInit || 0) + 1; } },
  createHandlerFn: (ctx, fn, ...args) => function (ev) { return (typeof fn === 'string' ? ctx[fn] : fn).apply(ctx, args.concat([ev])); },
  addNotification: (t, node) => { (window.__notes = window.__notes || []).push(node.textContent); }
};
window.rpc = { declare: () => () => Promise.resolve(window.__services || {}) };
window.poll = { add: fn => { window.__poll = fn; } };
window.network = { getHostHints: () => Promise.resolve(window.__hints ? {
  getMACHints: () => window.__hints.map(h => [h.mac, h.name || h.ip]),
  getIPAddrByMACAddr: m => (window.__hints.find(h => h.mac === m) || {}).ip,
  getHostnameByMACAddr: m => (window.__hints.find(h => h.mac === m) || {}).name
} : null) };
window.viewApi = { extend: o => o };
</script></body></html>
"""

errors = []
results = []


def check(name, cond, detail=""):
    results.append((name, bool(cond), detail))
    print(("PASS: " if cond else "FAIL: ") + name + ("" if cond else f" ({detail})"))


def boot(page, config, files=None, services=None, fail_gl=False, storage=None, clear_storage=True, hints=None, changes=None, live=None):
    page.goto("http://router.test/")
    if clear_storage:
        page.evaluate("localStorage.clear()")
    for k, v in (storage or {}).items():
        page.evaluate("([k, v]) => localStorage.setItem(k, v)", [k, v])
    page.evaluate("""([cfg, files, services, failGL, hints, changes, live]) => {
        window.__files = files; window.__services = services; window.__failGL = failGL; window.__hints = hints;
        window.__changes = changes; window.__live = live;
        window.uciState = JSON.parse(JSON.stringify(cfg)); window.__markers = [];
    }""", [config, files or {}, services or {}, fail_gl, hints, changes, live])
    page.evaluate("""(src) => {
        const v = new Function('view', 'uci', 'fs', 'ui', 'rpc', 'poll', 'network', src)(viewApi, uci, fs, ui, rpc, poll, network);
        window.view = v;
        // these tests drive every refresh themselves (__poll): the page's own timers stay off
        // unless a test turns them on
        v.watchdogMs = 0; v.serversFollowMs = 0;
        return v.load().then(() => { document.getElementById('root').appendChild(v.render()); });
    }""", MAP_JS)
    if not fail_gl:
        page.wait_for_function("window.__map && window.__map.layers['lf-servers']", timeout=5000)


def calls(page, kind):
    return page.evaluate(f"window.__map.calls.filter(c => c[0] === '{kind}').map(c => c[1])")


def main():
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1400, "height": 900})
        page.on("pageerror", lambda e: errors.append(str(e)))
        page.on("console", lambda m: m.type == "error" and errors.append(m.text))
        page.route("http://router.test/", lambda r: r.fulfill(content_type="text/html", body=HARNESS))
        page.route("https://unpkg.com/maplibre-gl@*/dist/maplibre-gl.mjs",
                   lambda r: r.fulfill(content_type="text/javascript", body=FAKE_MAPLIBRE,
                                       headers={"Access-Control-Allow-Origin": "*"}))
        page.route("https://unpkg.com/maplibre-gl@*/dist/maplibre-gl.css",
                   lambda r: r.fulfill(content_type="text/css", body="", headers={"Access-Control-Allow-Origin": "*"}))
        page.route("https://unpkg.com/maplibre-gl@*/dist/maplibre-gl-worker.mjs",
                   lambda r: r.fulfill(content_type="text/javascript", body="", headers={"Access-Control-Allow-Origin": "*"}))
        geo_urls = []
        def nominatim(route):
            geo_urls.append(route.request.url)
            body = {"type": "FeatureCollection", "features": [
                {"geometry": {"coordinates": [-73.9971, 40.7506]}, "properties": {"postcode": "10001", "name": "Manhattan", "city": "New York", "state": "New York", "country": "United States"}},
                {"geometry": {"coordinates": [2.34, 48.86]}, "properties": {"name": "Paris", "city": "Paris", "country": "France"}}]}
            route.fulfill(content_type="application/json", body=json.dumps(body), headers={"Access-Control-Allow-Origin": "*"})
        page.route("https://photon.komoot.io/api/*", nominatim)
        full_urls = []
        def nominatim_full(route):
            full_urls.append(route.request.url)
            body = [{"lat": "42.4089", "lon": "-71.0035", "display_name": "252, Revere Beach Parkway, Revere, Massachusetts, 02151, United States"}]
            route.fulfill(content_type="application/json", body=json.dumps(body), headers={"Access-Control-Allow-Origin": "*"})
        page.route("https://nominatim.openstreetmap.org/search*", nominatim_full)
        page.route("https://tiles.openfreemap.org/styles/positron",
                   lambda r: r.fulfill(content_type="application/json", body=json.dumps(FAKE_STYLE),
                                       headers={"Access-Control-Allow-Origin": "*"}))
        # the page asks GitHub (from the browser) for the newest LobbyFence
        latest = {"tag": "v1.1.0", "asked": 0}
        def github(route):
            latest["asked"] += 1
            route.fulfill(content_type="application/json", body=json.dumps({"tag_name": latest["tag"], "name": "LobbyFence"}),
                          headers={"Access-Control-Allow-Origin": "*"})
        page.route("https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest", github)

        fresh = {"globals": {".name": "globals", ".type": "globals", "enabled": "0"}}
        world = [[-175, -75], [175, 78]]

        # ---- 0. LobbyFence's version in the Status section (also before the first zone), with the newest one on GitHub
        vst = {"version": "1.1.0", "enabled": True, "active": True, "updated": 1, "interval": 20, "zones": []}
        boot(page, fresh, {"/tmp/lobbyfence/status.json": json.dumps(vst)})
        wv = page.locator(".lf-sechead .lf-panel-version")
        page.wait_for_function("document.querySelector('.lf-panel-version') && document.querySelector('.lf-panel-version').innerText.includes('up to date')", timeout=5000)
        check("Status section: LobbyFence's version next to the heading, up to date", wv.is_visible() and wv.inner_text() == "LobbyFence 1.1.0 · up to date"
              and latest["asked"] == 1, [wv.inner_text(), latest["asked"]])
        check("...not on the welcome screen any more", page.locator(".lf-welcome .lf-version").count() == 0 and page.locator(".lf-welcome").count() == 1)
        latest["tag"] = "v1.2.0"
        boot(page, fresh, {"/tmp/lobbyfence/status.json": json.dumps(vst)}, clear_storage=False)
        page.wait_for_timeout(500)
        check("...GitHub is asked at most twice a day", latest["asked"] == 1 and "up to date" in wv.inner_text(), [latest["asked"], wv.inner_text()])
        boot(page, fresh, {"/tmp/lobbyfence/status.json": json.dumps(vst)})     # (another browser asks again)
        page.wait_for_function("document.querySelector('.lf-panel-version a.lf-newer')", timeout=5000)
        nl = wv.locator("a.lf-newer")
        check("a newer version on GitHub: the Status section says so, with a link to it", "version 1.2.0 is out" in nl.inner_text()
              and nl.get_attribute("href") == "https://github.com/Femto-Gurifisu/Lobbyfence/releases/latest" and latest["asked"] == 2,
              [wv.inner_text(), latest["asked"]])
        latest["tag"] = "v1.1.0"

        # ---- 1. fresh install
        hints = [{"mac": "aa:bb:cc:dd:ee:01", "name": "Sams-iPhone", "ip": "192.168.1.23"},
                 {"mac": "aa:bb:cc:dd:ee:02", "name": "", "ip": "192.168.1.40"}]
        page.goto("http://router.test/")
        page.evaluate("""window.__devicesPreset = 1""")
        boot(page, fresh, hints=hints)
        page.evaluate("""window.__devices = [{ mac: 'aa:bb:cc:dd:ee:01', name: 'Sams-iPhone', ipv4: ['192.168.1.23'], ipv6: ['2601:1:2::23'] },
                                           { mac: 'aa:bb:cc:dd:ee:05', name: '', ipv4: ['192.168.1.77'], ipv6: [] }]""")
        check("no Overview: everything on one page (panel present)", page.locator(".lf-panel").count() == 1)
        check("Midnight is the default theme", page.locator(".lf-app.lf-dark").count() == 1 and
              page.evaluate("getComputedStyle(document.querySelector('.lf-app')).backgroundColor") == "rgb(14, 15, 17)")
        bg = page.evaluate("window.__map.style.layers[0].paint['background-color']")
        check("basemap recoloured for Midnight", bg == "#1b1c1f", bg)
        check("style camera ignored", "center" not in page.evaluate("window.__map.style"))
        check("starts fitted to the whole world", calls(page, "fitBounds") == [world])
        check("Fit button shows it is active", "lf-on" in page.locator("button", has_text="Fit").get_attribute("class"))
        check("welcome card shown", page.get_by_text("Welcome to LobbyFence").is_visible())
        check("welcome: what it can and can't do", page.get_by_text("What it can do").is_visible() and page.get_by_text("What it can't do").is_visible()
              and page.locator(".lf-wyes li").count() >= 4 and page.locator(".lf-wno li").count() >= 4)
        check("welcome: created by Darkness", page.get_by_text("Created by Darkness").is_visible())
        if SHOTS:
            page.screenshot(path=str(SHOTS / "welcome.png"))
        check("panel: LobbyFence is off", page.locator(".lf-panel").get_by_text("LobbyFence is off").is_visible())
        check("panel: API not used yet", page.locator(".lf-panel").get_by_text("API not used yet").is_visible())
        check("panel: server list asks for a zone", page.get_by_text("Create a zone to start learning servers.").is_visible())

        # ---- 2. create a zone, add a circle: camera must not move
        page.get_by_role("button", name="Create your first zone").click()
        modal = page.locator("#modal")
        page.wait_for_function("document.querySelectorAll('#modal select')[2].options.length > 0")
        game, platform, picker, proto = modal.locator("select").nth(0), modal.locator(".lf-nz-platform"), modal.locator("select").nth(2), modal.locator("select").nth(3)
        check("Any game: no device type to choose", not platform.is_visible())
        ports = modal.locator("input").nth(2)
        groups = page.evaluate("[...document.querySelectorAll('#modal optgroup')].filter(g => !g.closest('.lf-nz-platform')).map(g => g.label)")
        check("presets grouped: any / PC & console / mobile", groups == ["Any game", "PC & console", "Mobile"], groups)
        check("default preset is Any game", game.input_value() == "any_udp" and ports.input_value() == "1024-65535")
        check("Any game fills in its name like the others", modal.locator("input").nth(1).input_value() == "Any game")
        check("Custom can be picked", "custom" in page.evaluate("[...document.querySelectorAll('#modal select')[0].options].map(o => o.value)"))
        burst_in = modal.locator("input[type=number]").first
        check("open for server tests: Any game starts at 0", burst_in.input_value() == "0")
        game.select_option("apex")
        check("Apex Legends: open for server tests set to 2", burst_in.input_value() == "2")
        check("Apex Legends: recommendation shown", modal.get_by_text("Recommended for Apex Legends: 2 or more").is_visible())
        game.select_option("cod")
        check("Call of Duty: open for server tests set to 0", burst_in.input_value() == "0"
              and modal.get_by_text("Recommended for Call of Duty", exact=False).is_visible())
        game.select_option("custom")
        check("Custom: empty ports and name to fill in", ports.input_value() == "" and modal.locator("input").nth(1).input_value() == "")
        modal.get_by_role("button", name="Create zone").click()
        check("Custom needs ports", modal.get_by_text("Custom: enter the game's server ports").is_visible())
        ports.fill("27015"); modal.get_by_role("button", name="Create zone").click()
        check("Custom needs a name", modal.get_by_text("Custom: give the zone a name").is_visible())
        game.select_option("cod")
        check("Call of Duty preset: either-side 3074-3079",
              ports.input_value() == "3074-3079" and modal.get_by_text("Game ports (either side)").is_visible())
        check("Call of Duty: device type to choose, same ports on each", platform.is_visible() and platform.input_value() == ""
              and modal.get_by_text("Same ports on every device type").is_visible())
        modal.get_by_role("button", name="Create zone").click()
        check("a PC & console game needs the device type", modal.get_by_text("Choose the device type", exact=False).last.is_visible() and page.locator("#modal").count() == 1)
        game.select_option("fortnite")
        platform.select_option("ps")
        check("Fortnite on PlayStation: its own ports", ports.input_value() == "9000-9199 10100-10199 15000-15199 22200-22299 36300-36399 37500-37599 39900-39999 41700-41799 42100-42199 48200-48299 51100-51199 53700-53799 56100-56199", ports.input_value())
        platform.select_option("pc")
        check("Fortnite on PC: its own ports", ports.input_value().startswith("9000-9199 10500-10599") and ports.input_value().endswith("45100-45199"), ports.input_value())
        game.select_option("apex")
        check("Apex Legends on PC: its own ports", ports.input_value() == "7700-7799 8100-8199 9000-9099 10000-10599 10700-10899 15000-15099 22200-22299 27000-27199 49000-49099", ports.input_value())
        platform.select_option("ps")
        check("Apex Legends on PlayStation: its own ports", ports.input_value() == "1000-1099 1900-1999 3000-3199 7700-7799 8100-8199 10000-10999 27000-27199 27500-27599 34100-34199", ports.input_value())
        platform.select_option("xbox")
        check("Apex Legends on Xbox (not measured): every port", ports.input_value() == "1024-65535", ports.input_value())
        groups = platform.evaluate("s => [...s.children].map(c => c.tagName === 'OPTGROUP' ? c.label + ': ' + [...c.children].map(o => o.textContent).join(', ') : c.textContent)")
        check("device type: PC, then the consoles in their own group - Nintendo Switch too",
              groups == ["Choose the device type…", "PC", "Consoles: PlayStation, Xbox, Nintendo Switch"], groups)
        platform.select_option("switch")
        check("Apex Legends on Nintendo Switch (not measured): every port", ports.input_value() == "1024-65535", ports.input_value())
        names = page.evaluate("[...[...document.querySelectorAll('#modal optgroup')].find(g => g.label === 'PC & console').children].map(o => o.textContent)")
        check("PC & console games A to Z - Marvel Rivals, Roblox, GTA Online, Battlefield and more",
              names == sorted(names, key=str.lower) and all(n in names for n in ["Marvel Rivals", "Roblox", "GTA Online (GTA V) / Red Dead Online",
                                                                              "Battlefield 6", "Rainbow Six Siege X", "EA SPORTS FC 26"]), names)
        game.select_option("gta")
        check("GTA Online: Rockstar's ports on either side, open for server tests off, short name",
              ports.input_value() == "6672 61455-61458" and modal.get_by_text("Game ports (either side)").is_visible()
              and burst_in.input_value() == "0" and modal.locator("input").nth(1).input_value() == "GTA Online", ports.input_value())
        game.select_option("marvelrivals")
        check("Marvel Rivals: every UDP port until its ports are known - and says so",
              ports.input_value() == "1024-65535" and modal.get_by_text("match ports not known yet", exact=False).is_visible())
        game.select_option("roblox")
        check("Roblox: UDP 49152-65535, published by Roblox",
              ports.input_value() == "49152-65535" and modal.get_by_text("published by Roblox", exact=False).is_visible())

        # the game list opens in the page, inside the window - the browser's own list is as tall as all
        # 31 entries and, on a Mac, runs over the side panel and the browser's tabs
        pl = page.locator(".lf-pagelist")
        def pl_box():
            return page.evaluate("""() => { const b = document.querySelector('.lf-pagelist'); if (!b) return null;
                const r = b.getBoundingClientRect(); return { top: r.top, bottom: r.bottom, left: r.left, right: r.right,
                vh: innerHeight, vw: innerWidth, scrolls: b.scrollHeight > b.clientHeight }; }""")
        game.select_option("any_udp")
        page.evaluate("""window.__pd = null; document.querySelectorAll('#modal select')[0]
            .addEventListener('mousedown', ev => { window.__pd = ev.defaultPrevented; }, { once: true })""")
        game.click()
        b = pl_box()
        check("game list: a click opens the page's list, not the browser's", pl.count() == 1 and page.evaluate("window.__pd") is True, b)
        check("game list: inside the window", b and b["top"] >= 0 and b["bottom"] <= b["vh"] and b["left"] >= 0 and b["right"] <= b["vw"], b)
        heads = pl.locator(".lf-pl-head").all_inner_texts()
        opts = pl.locator(".lf-pl-opt").all_inner_texts()
        check("game list: the groups and every game", heads == ["Any game", "PC & console", "Mobile"] and len(opts) == page.evaluate("document.querySelectorAll('#modal select')[0].options.length"), (heads, len(opts)))
        check("game list: the current game is marked", pl.locator(".lf-pl-opt[aria-selected=true]").all_inner_texts() == ["Any game (all UDP traffic)"])
        if SHOTS:
            pl.locator(".lf-pl-opt").filter(has_text=re.compile(r"^Marvel Rivals$")).hover()
            page.screenshot(path=str(SHOTS / "game-list.png"))
        pl.locator(".lf-pl-opt").filter(has_text=re.compile(r"^Roblox$")).click()
        check("game list: a pick sets the game and fills in its ports - and the list closes",
              game.input_value() == "roblox" and ports.input_value() == "49152-65535" and pl.count() == 0
              and page.evaluate("document.activeElement === document.querySelectorAll('#modal select')[0]"))
        page.keyboard.press("ArrowDown")
        check("game list: the arrow keys open it too, on the current game", pl.count() == 1
              and pl.locator(".lf-pl-on").inner_text() == "Roblox")
        page.keyboard.press("End")
        end = pl.locator(".lf-pl-on").inner_text()
        page.keyboard.press("Home")
        home = pl.locator(".lf-pl-on").inner_text()
        page.keyboard.type("val")
        check("game list: Home / End and type-to-find", end == "Roblox (mobile)" and home == "Any game (all UDP traffic)"
              and pl.locator(".lf-pl-on").inner_text() == "VALORANT", (end, home))
        page.keyboard.press("Enter")
        check("game list: Enter picks", game.input_value() == "valorant" and pl.count() == 0 and ports.input_value() == "7000-8000 8180-8181")
        page.keyboard.press("ArrowDown")
        page.keyboard.press("Escape")
        check("game list: Escape closes the list, not the dialog", pl.count() == 0 and page.locator("#modal").count() == 1 and game.input_value() == "valorant")
        game.click()
        page.mouse.click(5, 5)
        check("game list: a click elsewhere closes it", pl.count() == 0 and game.input_value() == "valorant")
        proto.click()
        check("short lists keep the browser's own", pl.count() == 0)
        page.keyboard.press("Escape")
        vp = page.viewport_size
        page.set_viewport_size({"width": vp["width"], "height": 460})
        game.click()
        b = pl_box()
        check("game list: a short window - still inside it, and it scrolls", b and b["top"] >= 0 and b["bottom"] <= 460 and b["scrolls"], b)
        page.keyboard.press("Escape")
        page.set_viewport_size(vp)
        game.select_option("roblox")
        platform.select_option("xbox")
        game.select_option("codm")
        check("CoD Mobile preset: UDP 7500-8000, official",
              ports.input_value() == "7500-8000" and proto.input_value() == "udp" and modal.get_by_text("published by Activision", exact=False).is_visible())
        check("name follows the preset", modal.locator("input").nth(1).input_value() == "Call of Duty: Mobile")
        opts = picker.locator("option").all_inner_texts()
        check("device picker lists known devices", opts[0].startswith("Sams-iPhone - 192.168.1.23") and opts[-1].startswith("Enter an address"), opts)
        check("device picker shows IPv4, IPv6 and MAC", "2601:1:2::23" in opts[0] and "AA:BB:CC:DD:EE:01" in opts[0], opts[0])
        check("devices only the router knows are listed too", any("192.168.1.77" in o for o in opts), opts)
        check("picked device shows all its addresses", modal.get_by_text("IPv6: 2601:1:2::23").is_visible())
        check("picked device hides the manual field", not modal.locator("input").nth(0).is_visible())
        check("MAC matching explained", modal.get_by_text("Matched by MAC address", exact=False).is_visible())
        picker.select_option("")
        check("manual entry possible", modal.locator("input").nth(0).is_visible())
        modal.locator("input").nth(0).fill("not-a-device")
        modal.get_by_role("button", name="Create zone").click()
        check("bad device rejected", modal.get_by_text("Pick a device, or enter", exact=False).is_visible())
        picker.select_option("aa:bb:cc:dd:ee:01")
        modal.get_by_role("button", name="Create zone").click()
        check("zone created", page.locator("#modal").count() == 0 and page.locator(".lf-bar select").first.input_value() == "call_of_duty_mobile")
        z = page.evaluate("uciState.call_of_duty_mobile")
        check("new zones filter strictly by default", z.get("mode") == "enforce" and z.get("strict") == "1", z)
        check("new zone stores the game's value (CoD Mobile: 0) and the game", z.get("burst_servers") == "0" and z.get("burst_open") == "20" and z.get("game") == "codm", z)
        page.wait_for_timeout(100)
        check("new zone saved at once", "call_of_duty_mobile" in (page.evaluate("window.__saved") or {}))
        check("zone stores phone MAC + CoD Mobile ports",
              z["device"] == ["aa:bb:cc:dd:ee:01"] and z["remote_port"] == ["7500-8000"] and z["proto"] == "udp" and "port" not in z, z)
        before = len(page.evaluate("window.__map.calls"))
        page.evaluate("window.__map.fire('click', { lngLat: { lng: 8.6821, lat: 50.1109 } })")
        check("circle listed in the panel", page.locator(".lf-crow").count() == 1)
        check("adding a circle does not move the map", len(page.evaluate("window.__map.calls")) == before)
        page.evaluate("""() => { const live = window.__markers.filter(m => !m.removed);
            live[1].p = { lng: 8.6821 + 1000 / (111.32 * Math.cos(50.1109 * Math.PI / 180)), lat: 50.1109 };
            live[1].fire('drag'); live[1].fire('dragend'); }""")
        check("resizing does not move the map", len(page.evaluate("window.__map.calls")) == before)
        check("Fit still active after editing", "lf-on" in page.locator("button", has_text="Fit").get_attribute("class"))

        # ---- 2b. polygons: draw, close on the first corner, double-click, Esc, edit
        page.get_by_role("button", name="Draw polygon").click()
        check("polygon mode explains itself", page.get_by_text("Click the map to place the corners", exact=False).is_visible())
        for lng, lat in [(10, 40), (20, 40), (20, 50)]:
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        check("button offers to finish after 3 corners", page.get_by_role("button", name="Finish polygon").is_visible())
        draft = page.evaluate("window.__map.getSource('lf-draft').data.features.length")
        check("draft corners drawn", draft >= 3, draft)
        page.evaluate("window.__map.userClick(10.2, 40.2)")   # within 10 px of the first corner
        check("clicking the first corner closes the polygon", page.locator(".lf-poly").count() == 1)
        regions = page.evaluate("window.__map.getSource('lf-circles').data.features.map(f => f.properties.kind)")
        check("circle and polygon both drawn", sorted(regions) == ["circle", "polygon"], regions)
        check("draft cleared", page.evaluate("window.__map.getSource('lf-draft').data.features.length") == 0)
        page.get_by_role("button", name="Draw polygon").click()
        check("double-click zoom off while drawing", page.evaluate("window.__map.dblZoom") is False)
        for lng, lat in [(-80, 30), (-70, 30), (-70, 45), (-80, 45)]:
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        page.evaluate("window.__map.userClick(-80, 45)")       # 2nd click of a double-click: ignored
        page.evaluate("window.__map.fire('dblclick', { preventDefault() {} })")
        check("double-click finishes", page.locator(".lf-poly").count() == 2 and page.get_by_text("Polygon, 4 corners").is_visible())
        check("double-click zoom back on", page.evaluate("window.__map.dblZoom") is True)
        page.get_by_role("button", name="Draw polygon").click()
        page.evaluate("window.__map.userClick(0, 0)")
        page.keyboard.press("Escape")
        check("Esc cancels a polygon", page.locator(".lf-poly").count() == 2 and page.get_by_role("button", name="Draw polygon").is_visible())
        page.evaluate("""() => { const v = window.__markers.filter(m => !m.removed && m.o.element.classList.contains('lf-vertex'));
            v[v.length - 1].o.element.dispatchEvent(new MouseEvent('contextmenu', { bubbles: true, cancelable: true })); }""")
        check("right-click removes a corner", page.get_by_text("Polygon, 3 corners").count() == 2)
        page.evaluate("window.view.handleSave()")
        polys = page.evaluate("uciState.call_of_duty_mobile.polygon")
        check("polygons saved as lat,lon lists", len(polys) == 2 and polys[0] == "40.0000,10.0000;40.0000,20.0000;50.0000,20.0000", polys)

        # ---- 2b+. straight edges: align prompt, Straighten, linked corner drag; clear shapes
        def polys_now():
            return page.evaluate("window.view.polygons.call_of_duty_mobile")
        def straight(pts):
            n = len(pts)
            return all(abs(pts[i][1] - pts[(i + 1) % n][1]) < 1e-9 or abs(pts[i][0] - pts[(i + 1) % n][0]) < 1e-9 for i in range(n))
        check("no Snap button any more", page.get_by_role("button", name="Snap").count() == 0)
        page.get_by_role("button", name="Draw polygon").click()
        for lng, lat in [(60, 10), (70.4, 10.5), (70.1, 19.6), (59.8, 20.3)]:
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        page.keyboard.press("Enter")
        check("corners land exactly where clicked", polys_now()[-1][1] == [70.4, 10.5], polys_now()[-1])
        check("prompt offers to make every edge straight", page.get_by_text("Make every edge straight? Your shape becomes a square / rectangle.").is_visible())
        page.evaluate("window.__map.userClick(70.4, 10.5)")   # the click that finished it also reaches the map
        page.wait_for_timeout(1500)
        check("align offer stays on screen while the polygon is selected", page.locator(".lf-prompt").is_visible())
        page.keyboard.press("Escape")
        check("deselecting hides it", page.locator(".lf-prompt").count() == 0)
        page.locator(".lf-poly .lf-num").last.click()
        check("selecting it again brings it back", page.get_by_text("Make every edge straight?", exact=False).is_visible())
        page.get_by_role("button", name="Keep as drawn").click()
        free = polys_now()[-1]
        check("'Keep as drawn' keeps it", not straight(free) and page.locator(".lf-prompt").count() == 0, free)
        page.keyboard.press("Escape"); page.locator(".lf-poly .lf-num").last.click()
        check("...and doesn't ask again for that shape", page.locator(".lf-prompt").count() == 0)
        page.locator(".lf-poly").last.get_by_role("button", name="Straighten").click()
        page.wait_for_timeout(100)
        check("panel Straighten lines it up", straight(polys_now()[-1]), polys_now()[-1])
        check("...and says so", page.get_by_text("Edges straightened.").is_visible())
        page.locator(".lf-poly").last.get_by_role("button", name="Straighten").click()
        check("Straighten on a straight shape explains why nothing changed", page.get_by_text("Already straight", exact=False).is_visible())
        page.keyboard.press("Escape")
        page.get_by_role("button", name="Draw polygon").click()
        for lng, lat in [(30, 10), (40.4, 10.5), (40.1, 19.6), (29.8, 20.3)]:
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        page.keyboard.press("Enter")
        page.get_by_role("button", name="Align").click()
        sq = polys_now()[-1]
        check("'Align' turns a hand-drawn square into an exact rectangle", straight(sq) and len(sq) == 4, sq)
        page.get_by_role("button", name="Draw polygon").click()
        for lng, lat in [(0, 50), (12, 56), (8, 66), (-4, 60)]:      # a badly tilted square (edges ~30 degrees off)
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        page.keyboard.press("Enter")
        page.get_by_role("button", name="Align").click()
        tilt = polys_now()[-1]
        check("'Align' squares up even a badly tilted shape", straight(tilt) and len(tilt) == 4, tilt)
        check("the offer goes away once it's straight", page.locator(".lf-prompt").count() == 0)
        page.keyboard.press("Escape")
        page.get_by_role("button", name="Draw polygon").click()
        for lng, lat in [(0, 60), (20, 75), (40, 60)]:
            page.evaluate(f"window.__map.userClick({lng}, {lat})")
        page.keyboard.press("Enter")
        page.get_by_role("button", name="Align").click()
        tri = polys_now()[-1]
        check("a triangle becomes the rectangle around it", straight(tri) and len(tri) == 4, tri)
        polys = polys_now()
        idx_free = len(polys) - 4
        page.locator(".lf-poly").nth(idx_free).get_by_role("button", name="Straighten").click()
        fixed = polys_now()[idx_free]
        check("Straighten makes the edges straight", straight(fixed), fixed)
        page.wait_for_timeout(600)
        saved_polys = page.evaluate("window.__saved.call_of_duty_mobile.polygon")
        check("edits are saved right away (no Save & Apply needed to keep them)", len(saved_polys) == len(polys_now()), saved_polys)
        check("saved note points to Save & Apply", page.get_by_text("Changes saved - press Save & Apply", exact=False).is_visible())
        check("LuCI's change counter refreshed", page.evaluate("window.__changesInit || 0") >= 1)
        # clear shapes: no fill unless selected; handles only on the selected shape
        fill = json.dumps(page.evaluate("window.__map.layers['lf-circle-fill'].paint['fill-opacity']"))
        check("saved shapes are a see-through blue", fill.replace(" ", "").endswith(",0.22,0.1]"), fill)
        page.locator(".lf-poly").nth(idx_free + 1).click()
        nverts = page.evaluate("window.__markers.filter(m => !m.removed && m.o.element.classList.contains('lf-vertex')).length")
        check("only the selected shape shows handles", nverts == len(polys_now()[idx_free + 1]), nverts)
        check("no circle handles while a polygon is selected - only the polygon's own middle (move) handle",
              page.evaluate("window.__markers.filter(m => !m.removed && !m.o.element.classList.contains('lf-vertex')).length") == 1)
        # drag a corner of the rectangle: its neighbours follow, edges stay straight
        page.evaluate("""() => {
            const v = window.__markers.filter(m => !m.removed && m.o.element.classList.contains('lf-vertex'));
            v[0].fire('dragstart'); v[0].p = { lng: 25, lat: 5 }; v[0].fire('drag'); v[0].fire('dragend');
        }""")
        moved = polys_now()[idx_free + 1]
        check("dragging a corner keeps the rectangle straight", straight(moved) and moved[0] == [25, 5], moved)
        page.keyboard.press("Escape")
        check("deselecting hides all handles", page.evaluate("window.__markers.filter(m => !m.removed).length") == 0)

        # ---- 2b++. switching tabs and coming back keeps everything
        before_regions = page.locator(".lf-crow").count()
        boot(page, page.evaluate("window.__saved"), clear_storage=False, changes={"lobbyfence": [["set", "x"]]})
        check("after a tab switch the regions are still there", page.locator(".lf-crow").count() == before_regions)
        check("and the page says they still need Save & Apply", page.get_by_text("Changes saved - press Save & Apply", exact=False).is_visible())

        # ---- 2d. select a shape, Delete key, drag to move
        def shapes():
            return page.evaluate("[window.view.circles.call_of_duty_mobile.length, window.view.polygons.call_of_duty_mobile.length]")
        def press_shape(kind, idx, lng, lat):
            page.evaluate(f"""window.__map.fire('mousedown', {{ type: 'mousedown', features: [{{ properties: {{ kind: '{kind}', idx: {idx} }} }}],
                lngLat: {{ lng: {lng}, lat: {lat} }}, point: {{ x: 0, y: 0 }}, preventDefault() {{ window.__pd = 1; }} }}, 'lf-circle-fill')""")
        n_c, n_p = shapes()
        press_shape("polygon", 0, 15, 45)
        page.evaluate("window.__map.fire('mouseup', {})")
        check("clicking a shape selects it", page.evaluate("JSON.stringify(window.view.selected)") == '{"kind":"polygon","idx":0}'
              and page.locator(".lf-crow.lf-sel").count() == 1)
        sel_feats = page.evaluate("window.__map.getSource('lf-circles').data.features.filter(f => f.properties.sel).map(f => f.properties.kind)")
        check("selected shape is highlighted on the map", sel_feats == ["polygon"], sel_feats)
        check("map panning held back while pressing a shape", page.evaluate("window.__pd") == 1)
        page.locator(".lf-search input").focus()
        page.keyboard.press("Delete")
        check("Delete while typing does not remove shapes", shapes() == [n_c, n_p])
        page.locator(".lf-search input").blur()
        page.keyboard.press("Delete")
        check("Delete key removes the selected shape", shapes() == [n_c, n_p - 1] and page.evaluate("window.view.selected") is None)
        page.wait_for_timeout(600)
        check("deletion saved", len(page.evaluate("window.__saved.call_of_duty_mobile.polygon || []")) == n_p - 1)
        page.locator(".lf-crow").first.click()
        page.keyboard.press("Escape")
        check("Esc deselects", page.evaluate("window.view.selected") is None)
        page.keyboard.press("Backspace")
        check("Backspace with nothing selected does nothing", shapes() == [n_c, n_p - 1])
        # drag a circle by its body
        c0 = page.evaluate("JSON.parse(JSON.stringify(window.view.circles.call_of_duty_mobile[0]))")
        press_shape("circle", 0, c0["lon"], c0["lat"])
        page.evaluate(f"window.__map.fire('mousemove', {{ lngLat: {{ lng: {c0['lon'] + 10}, lat: {c0['lat']} }}, point: {{ x: 80, y: 0 }} }})")
        page.evaluate("window.__map.fire('mouseup', {})")
        c1 = page.evaluate("window.view.circles.call_of_duty_mobile[0]")
        check("dragging a circle moves it", abs(c1["lon"] - c0["lon"] - 10) < 1e-6 and abs(c1["lat"] - c0["lat"]) < 1e-6 and c1["r"] == c0["r"], [c0, c1])
        # drag a polygon: shape kept, just moved
        p0 = page.evaluate("JSON.parse(JSON.stringify(window.view.polygons.call_of_duty_mobile[0]))")
        press_shape("polygon", 0, p0[0][0], p0[0][1])
        page.evaluate(f"window.__map.fire('mousemove', {{ lngLat: {{ lng: {p0[0][0] - 20}, lat: {p0[0][1] + 5} }}, point: {{ x: -100, y: -40 }} }})")
        page.evaluate("window.__map.fire('mouseup', {})")
        p1 = page.evaluate("window.view.polygons.call_of_duty_mobile[0]")
        check("dragging a polygon moves all corners together",
              all(abs(b[0] - a[0] + 20) < 1e-6 for a, b in zip(p0, p1)) and abs(p1[0][1] - p0[0][1] - 5) < 1e-6, [p0, p1])
        check("a moved straight polygon stays straight", straight(p1) == straight(p0))
        page.wait_for_timeout(600)
        check("move saved", page.evaluate("window.__saved.call_of_duty_mobile.circle[0]").startswith(f"{c1['lat']:.4f},"))
        press_shape("circle", 0, 0, 0)
        page.evaluate("window.__map.fire('mousemove', { lngLat: { lng: 0.0001, lat: 0 }, point: { x: 1, y: 0 } })")
        page.evaluate("window.__map.fire('mouseup', {})")
        check("a tiny wobble is a click, not a move", page.evaluate("window.view.circles.call_of_duty_mobile[0].lon") == c1["lon"])
        page.keyboard.press("Escape")

        # ---- 2c. full screen and panel
        page.get_by_role("button", name="Full screen").click()
        check("full screen fills the window", page.locator(".lf-app.lf-full").count() == 1 and
              page.evaluate("document.querySelector('.lf-app').getBoundingClientRect().height") >= 890)
        page.get_by_role("button", name="Panel").click()
        check("panel can be hidden for a map-only view", page.locator(".lf-app.lf-nopanel").count() == 1 and not page.locator(".lf-panel").is_visible())
        page.wait_for_timeout(150)
        check("map resized after layout changes", page.evaluate("window.__map.resized || 0") >= 1)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "fullscreen-nopanel.png"))
        page.get_by_role("button", name="Panel").click()
        if SHOTS:
            page.screenshot(path=str(SHOTS / "fullscreen.png"))
        page.get_by_role("button", name="Exit full screen").click()
        check("full screen can be left", page.locator(".lf-app.lf-full").count() == 0 and page.locator(".lf-panel").is_visible())

        # ---- 3. user pans -> fit off; Fit -> world again
        page.evaluate("window.__map.userPan(8, 50, 5)")
        check("panning turns Fit off", "lf-on" not in page.locator("button", has_text="Fit").get_attribute("class"))
        check("view remembered", json.loads(page.evaluate("localStorage.getItem('lobbyfence.view')"))["fit"] is False)
        page.locator("button", has_text="Fit").click()
        check("Fit returns to the whole world", calls(page, "fitBounds")[-1] == world)
        check("Fit state remembered", json.loads(page.evaluate("localStorage.getItem('lobbyfence.view')"))["fit"] is True)

        # ---- 3b. View menu: borderless, endless, borders, zoom out completely
        check("by default only country borders are on (not endless, not borderless)",
              page.evaluate("window.__map.o.renderWorldCopies") is False and page.locator(".lf-app.lf-borderless").count() == 0)
        page.locator("button", has_text="View").click()
        menu = page.locator(".lf-menu")
        check("View menu opens", menu.is_visible())
        checks = page.evaluate("[...document.querySelectorAll('.lf-menu .lf-mitem')].map(l => [l.innerText.trim(), l.querySelector('input').checked])")
        check("menu: Country borders and Place names ticked", checks == [["Borderless", False], ["Endless map", False], ["Country borders", True], ["Place names", True], ["Whole world", False]], checks)
        # place names off: every basemap name layer hidden, LobbyFence's own layers untouched
        page.evaluate("""() => { const st = window.__map.getStyle(); st.layers.push({ id: 'place_city', type: 'symbol' }, { id: 'water_name', type: 'symbol' },
            { id: 'lf-label-continent', type: 'symbol' }, { id: 'lf-home', type: 'symbol' }); }""")
        menu.get_by_text("Place names").click()
        lay = page.evaluate("window.__map.layout || {}")
        check("Place names off: every name on the map hidden, the home pin stays",
              lay.get("place_city.visibility") == "none" and lay.get("water_name.visibility") == "none" and
              lay.get("lf-label-continent.visibility") == "none" and "lf-home.visibility" not in lay, lay)
        menu.get_by_text("Place names").click()
        lay = page.evaluate("window.__map.layout || {}")
        check("...and back on", lay.get("place_city.visibility") == "visible", lay)
        menu.get_by_text("Place names").click()
        menu.get_by_text("Endless map").click()
        check("endless can be switched on", page.evaluate("window.__map.worldCopies") is True)
        menu.get_by_text("Borderless").click()
        check("borderless fills the window without a frame",
              page.evaluate("getComputedStyle(document.querySelector('.lf-app')).position") == "fixed" and
              page.evaluate("getComputedStyle(document.querySelector('.lf-app')).paddingTop") == "0px")
        menu.get_by_text("Whole world").click()
        check("Whole world on: zooms out pole to pole", calls(page, "fitBounds")[-1] == [[-180, -85], [180, 85]])
        check("...and stays on (a switch in the menu, not a one-off button)",
              menu.is_visible() and page.evaluate("[...document.querySelectorAll('.lf-menu .lf-mitem')].pop().querySelector('input').checked"))
        page.keyboard.press("Escape")
        check("Esc closes the View menu first", not menu.is_visible())
        page.keyboard.press("Escape")
        check("Esc leaves borderless", page.locator(".lf-app.lf-borderless").count() == 0)
        opts = json.loads(page.evaluate("localStorage.getItem('lobbyfence.viewopts')"))
        check("view options remembered", opts == {"endless": True, "borders": True, "borderless": False, "labels": False, "whole": True}, opts)
        page.evaluate("localStorage.removeItem('lobbyfence.viewopts')")
        page.locator("button", has_text="Fit").click()
        page.evaluate("window.view.handleSave()")

        # ---- 4. reload (what Save & Apply does): stays fitted, never zooms to the circle
        saved = page.evaluate("window.__saved")
        boot(page, saved, clear_storage=False)
        check("after reload: still the whole world", calls(page, "fitBounds") == [world], calls(page, "fitBounds"))
        check("after reload: no jump to the circle", calls(page, "jumpTo") == [] and calls(page, "flyTo") == [])
        # a reload after the user zoomed somewhere keeps that view
        page.evaluate("window.__map.userPan(-74, 40.7, 6)")
        boot(page, saved, clear_storage=False)
        jumps = calls(page, "jumpTo")
        check("after reload: keeps a view the user chose", len(jumps) == 1 and jumps[0]["zoom"] == 6 and calls(page, "fitBounds") == [], jumps)

        # ---- 5. servers panel + API status
        cfg = dict(fresh)
        cfg["globals"] = dict(fresh["globals"], enabled="1")
        cfg["game"] = {".name": "game", ".type": "zone", "label": "Game", "enabled": "1", "mode": "enforce",
                       "circle": ["50.1109,8.6821,800"]}
        servers = ("45.10.0.1 in 50.11 8.68 DE 1700000000\n80.20.0.1 out 40.71 -74.0 US 1700000100\n"
                   "99.1.1.1 out 35.68 139.7 JP 1700000200\n9.9.9.9 pending - - -- 1700000300\n")
        status = {"version": "1.0.0", "enabled": True, "active": True, "updated": 1, "interval": 60,
                  "geo": {"last_ok": 0, "pending": 1, "error": "no answer - check the router's internet connection"},
                  "zones": [{"id": "game", "label": "Game", "enabled": True, "mode": "enforce", "strict": False,
                             "region": True, "servers": 4, "inside": 1, "outside": 2, "pending": 1,
                             "unlocatable": 0, "packets": 12345, "blocked": 67,
                             "devices": ["192.168.1.23", "fd00::23"], "macs": 1}]}
        files = {"/tmp/lobbyfence/game.servers": servers, "/tmp/lobbyfence/status.json": json.dumps(status)}
        services = {"lobbyfence": {"instances": {"instance1": {"running": True}}}}
        boot(page, cfg, files, services)
        page.wait_for_function("document.querySelector('.lf-tabs') && document.querySelector('.lf-tabs').innerText.includes('Blocked')")
        panel = page.locator(".lf-panel")
        check("panel: running, rules loaded", panel.get_by_text("Running").is_visible() and panel.get_by_text("rules loaded").is_visible())
        check("panel: packet counters", panel.get_by_text("Game packets: 12,345").is_visible() and panel.get_by_text("Blocked: 67").is_visible())
        check("panel: API problem shown", panel.get_by_text("API problem:").is_visible())
        check("panel: device addresses", panel.get_by_text("Device at 192.168.1.23 + 1 IPv6").is_visible())
        page.wait_for_function("document.querySelector('.lf-panel-version') && document.querySelector('.lf-panel-version').innerText.includes('is out')", timeout=5000)
        check("panel: LobbyFence's version, and that a newer one is out", page.locator(".lf-panel-version").inner_text() == "LobbyFence 1.0.0 · version 1.1.0 is out - update",
              page.locator(".lf-panel-version").inner_text())
        check("panel: no 'no traffic' warning while packets flow", panel.get_by_text("No game traffic").count() == 0)
        tabs = page.locator(".lf-tab").all_inner_texts()
        check("tabs count allowed / blocked / unknown", [t.split()[-1] for t in tabs] == ["1", "2", "1"], tabs)
        check("allowed list shows the inside server", page.locator(".lf-row .lf-ip").all_inner_texts() == ["45.10.0.1"])
        page.locator(".lf-tab", has_text="Blocked").click()
        rows = page.locator(".lf-row .lf-ip").all_inner_texts()
        check("blocked list, newest first", rows == ["99.1.1.1", "80.20.0.1"], rows)
        check("blocked rows say how far outside", "km outside" in page.locator(".lf-row").first.inner_text())
        page.locator(".lf-search input").fill("jp")
        check("search by country", page.locator(".lf-row .lf-ip").all_inner_texts() == ["99.1.1.1"])
        page.locator(".lf-row").first.click()
        fly = calls(page, "flyTo")
        check("clicking a server flies to it", fly and fly[-1]["center"] == [139.7, 35.68], fly)
        check("and opens its popup", "99.1.1.1" in page.evaluate("window.__popup.html"))
        check("popup offers allow / block", page.locator("#fake-popup").get_by_role("button", name="Always allow").is_visible()
              and page.locator("#fake-popup").get_by_role("button", name="Always block").is_visible())
        check("and leaves Fit mode", "lf-on" not in page.locator("button", has_text="Fit").get_attribute("class"))
        page.locator(".lf-search input").fill("")
        page.locator(".lf-tab", has_text="Unknown").click()
        check("unknown list shows waiting server", "waiting for location" in page.locator(".lf-row").first.inner_text())

        # ---- 5a. open for server tests: settings + live state in the panel
        bs = page.locator(".lf-burst-burst_servers")
        check("panel shows the server-test setting (default 0 = off)", bs.is_visible() and bs.input_value() == "0"
              and "(off)" in page.locator(".lf-panel").inner_text())
        ptxt = page.locator(".lf-panel").inner_text()
        check("panel: unknown game gets the per-game advice", "Apex Legends and Fortnite need 2 or more" in ptxt and "Call of Duty should stay at 0" in ptxt)
        page.evaluate("uciState.game.game = 'apex'; window.view.renderStatus()")
        check("panel: Apex Legends zone shows its recommendation", "Recommended for Apex Legends: 2 or more" in page.locator(".lf-panel").inner_text())
        page.evaluate("delete uciState.game.game; window.view.renderStatus()")
        bs.fill("6"); bs.dispatch_event("change")
        page.wait_for_timeout(600)
        check("changing it saves right away", page.evaluate("window.__saved.game.burst_servers") == "6")
        page.evaluate("window.__live = { zones: { game: { packets: 50, blocked: 3, open_left: 7, opened: 42 } } }")
        page.evaluate("window.__poll()")
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('7 s left')")
        check("live: zone open for server tests", panel.get_by_text("Open for server tests - all servers allowed (7 s left)").is_visible())
        seq = []
        for _ in range(4):
            seq.append(int(page.evaluate("document.querySelector('.lf-open-left').textContent")))
            page.wait_for_timeout(1000)
        check("countdown ticks every second between router updates", seq[0] - seq[-1] >= 2 and all(a - b in (0, 1, 2) for a, b in zip(seq, seq[1:])), seq)
        print("    countdown seen:", seq)
        check("live counters used", panel.get_by_text("Game packets: 50").is_visible())
        page.evaluate("window.__live = { zones: { game: { packets: 60, blocked: 3, open_left: 0, opened: 42 } } }")
        page.evaluate("window.__poll()")
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('42 packets let through')")
        check("live: closed again, shows what it let through", panel.get_by_text("42 packets let through during server tests").is_visible())
        page.evaluate("window.__live = null")
        page.wait_for_timeout(700)
        check("saving indicator clears", page.evaluate("window.view.saving") is False and page.get_by_text("Saving…").count() == 0,
              page.evaluate("[window.view.saving, window.__saves]"))

        # ---- 5a+. only servers in use now by default; time filter; clear
        page.evaluate("window.__live = { time: 1700000300 + 86400 * 2, zones: {} }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        check("old servers hidden in 'Active now'", page.get_by_text("No server is in use right now", exact=False).is_visible()
              and page.evaluate("window.__map.getSource('lf-servers').data.features.length") == 0)
        page.evaluate("window.__live = { time: 1700000300 + 86400 * 2, zones: { game: { active: ['80.20.0.1'] } } }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        feats = page.evaluate("window.__map.getSource('lf-servers').data.features.map(f => f.properties.ips)")
        check("'Active now' shows exactly the servers with live traffic", feats == ["80.20.0.1"], feats)
        page.evaluate("window.__live = { time: 1700000300 + 86400 * 2, zones: { game: { active: { '80.20.0.1': 9 }, active_window: 15 } } }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        page.locator(".lf-tab", has_text="Blocked").click()
        check("list says how long ago the device last sent to it", panel.get_by_text("last traffic 9 s ago", exact=False).is_visible())
        fade = page.evaluate("window.__map.getSource('lf-servers').data.features[0].properties.fade")
        check("a quiet server's dot is fading", 0.3 < fade < 0.7, fade)
        page.evaluate("window.__live = { time: 1700000300 + 86400 * 2, zones: { game: { active: [] } } }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        check("traffic stops: the dot goes away", page.evaluate("window.__map.getSource('lf-servers').data.features.length") == 0)
        page.locator(".lf-search select").last.select_option("all")
        check("'All learned' shows them again", page.evaluate("window.__map.getSource('lf-servers').data.features.length") == 3)
        page.locator(".lf-search select").last.select_option("day")
        page.evaluate("window.__live = { time: 1700000300 + 3600 * 5, zones: {} }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        check("'Last 24 hours' filter", page.evaluate("window.__map.getSource('lf-servers').data.features.length") == 3)
        page.locator(".lf-search select").last.select_option("active")
        page.evaluate("window.__live = null")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        page.get_by_role("button", name="Clear").click()
        page.locator("#modal").get_by_role("button", name="Clear").click()
        page.wait_for_timeout(100)
        check("Clear forgets the zone's learned servers", page.evaluate("window.__execs.slice(-1)[0]") == ["/usr/sbin/lobbyfence", "forget", "game"])

        # ---- 5a+++. country filter
        page.locator(".lf-search select").last.select_option("all")
        cc_opts = page.locator(".lf-search select").first.locator("option").all_inner_texts()
        check("country filter lists the servers' countries", cc_opts[0] == "All countries" and any("US (1)" in o for o in cc_opts) and any("JP (1)" in o for o in cc_opts), cc_opts)
        page.locator(".lf-search select").first.select_option("US")
        tabs = page.locator(".lf-tab").all_inner_texts()
        dots = page.evaluate("window.__map.getSource('lf-servers').data.features.map(f => f.properties.cc)")
        check("filtering by country: list and map", [t.split()[-1] for t in tabs] == ["0", "1", "0"] and dots == ["US"], [tabs, dots])
        page.locator(".lf-search select").first.select_option("")
        check("all countries again", page.evaluate("window.__map.getSource('lf-servers').data.features.length") == 3)

        # ---- 5a++++. home by ZIP code or place name
        page.get_by_role("button", name="Home").click()
        hm = page.locator("#modal")
        hm.locator("input").press_sequentially("10", delay=30)
        page.wait_for_timeout(500)
        check("needs 3 characters before suggesting", hm.get_by_text("Keep typing").is_visible() and not geo_urls)
        hm.locator("input").press_sequentially("001", delay=30)
        page.wait_for_function("document.querySelector('#modal').innerText.includes('Manhattan')")
        check("suggestions appear while typing, one request after the pause", len(geo_urls) == 1 and "q=10001" in geo_urls[-1], geo_urls)
        hm.get_by_role("button", name="10001, Manhattan, New York, New York, United States").click()
        page.wait_for_timeout(600)
        check("home saved", page.evaluate("[window.__saved.globals.home, window.__saved.globals.home_label]") == ["40.75060,-73.99710", "10001, Manhattan, New York, New York, United States"])
        page.wait_for_function("!!window.__map.getLayer('lf-home')")
        home = page.evaluate("""(() => { const m = window.__map, l = m.getLayer('lf-home'), d = m.getSource('lf-home').data;
            return { img: l.layout['icon-image'], anchor: l.layout['icon-anchor'], pt: d.features[0].geometry.coordinates,
                     loaded: m.hasImage(l.layout['icon-image']), html: (window.__markers || []).filter(x => !x.removed).length }; })()""")
        check("home pin is drawn inside the map (no HTML box around it)", home["img"] == "lf-pin-3b82f6" and home["loaded"]
              and home["anchor"] == "bottom" and home["pt"] == [-73.9971, 40.7506] and home["html"] == 0, home)
        check("map flies home", page.evaluate("window.__map.calls.slice(-1)[0][0]") == "flyTo")
        page.locator(".lf-tab", has_text="Blocked").click()
        check("servers show their distance from home", panel.get_by_text("km from home", exact=False).count() >= 1)
        page.get_by_role("button", name="Home").click()
        hm.locator("input").fill("Madrid")
        page.wait_for_function("document.querySelector('#modal').innerText.includes('Pick your location')")
        check("place names are suggested too", "q=Madrid" in geo_urls[-1], geo_urls[-1])
        check("typing never uses the full address service", not full_urls, full_urls)
        hm.locator("input").fill("252 Revere Beach Parkway")
        hm.locator("input").press("Enter")
        page.wait_for_function("document.querySelector('#modal').innerText.includes('Revere Beach Parkway, Revere')")
        check("Enter looks up the exact street address", len(full_urls) == 1 and "q=252%20Revere%20Beach%20Parkway" in full_urls[-1], full_urls)
        first = hm.locator(".lf-suggest").first.inner_text()
        check("the exact address is listed first", first.startswith("252, Revere Beach Parkway"), first)
        hm.locator(".lf-suggest").first.click()
        page.wait_for_timeout(600)
        check("street address saved as home", page.evaluate("window.__saved.globals.home") == "42.40890,-71.00350")
        page.get_by_role("button", name="Home").click()
        hm.get_by_role("button", name="Remove home").click()
        page.wait_for_timeout(600)
        check("home can be removed", page.evaluate("window.__saved.globals.home") is None
              and page.evaluate("window.__map.getSource('lf-home').data.features.length") == 0)
        # the home pin clicked: Delete removes it (Escape only closes its popup; typing never removes it)
        def pin_popup():
            page.evaluate("window.view.setHome(42.4089, -71.0035, 'Revere')")
            page.wait_for_timeout(300)
            page.evaluate("window.__map.fire('click', { originalEvent: {} }, 'lf-home')")
            page.wait_for_timeout(200)
        pin_popup()
        check("clicking the home pin: its popup offers Remove home", page.locator("#fake-popup").get_by_role("button", name="Remove home").count() == 1)
        page.keyboard.press("Escape")
        page.keyboard.press("Delete")
        page.wait_for_timeout(300)
        check("Escape closes the home popup; Delete afterwards does not remove home",
              page.evaluate("window.view.homePopup") is None and page.evaluate("window.__map.getSource('lf-home').data.features.length") == 1)
        pin_popup()
        page.keyboard.press("Delete")
        page.wait_for_timeout(600)
        check("home pin selected + Delete key: home removed (and saved)", page.evaluate("window.__map.getSource('lf-home').data.features.length") == 0
              and page.evaluate("window.__saved.globals.home") is None and page.locator("#fake-popup").count() == 0)
        pin_popup()
        page.keyboard.press("Backspace")
        page.wait_for_timeout(600)
        check("...Backspace too (Mac keyboards)", page.evaluate("window.__map.getSource('lf-home').data.features.length") == 0)
        page.locator(".lf-search select").last.select_option("active")

        # ---- 5a++. whitelist / blacklist manager
        page.get_by_role("button", name="Manage lists…").click()
        lm = page.locator("#modal")
        check("lists dialog opens on the whitelist", lm.get_by_text("Always allowed, wherever they are located", exact=False).is_visible())
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, allow: ['1.2.3.4', '5.6.7.0/24'], block: ['99.1.1.1', '45.10.0.1'] }) }""")
        lm.locator("textarea").fill("1.2.3.4, junk\n5.6.7.0/24")
        lm.get_by_role("button", name="Add to whitelist").click()
        page.wait_for_function("document.querySelector('#modal').innerText.includes('5.6.7.0/24')")
        check("adding sends the addresses to the router", page.evaluate("window.__execs.slice(-1)[0]") == ["/usr/sbin/lobbyfence", "allow", "game", "1.2.3.4", "5.6.7.0/24"])
        check("junk is reported, not sent", lm.get_by_text("1 entries were not addresses", exact=False).is_visible())
        with page.expect_download() as dl:
            lm.get_by_role("button", name="Download").click()
        text = open(dl.value.path()).read()
        check("download is a shareable text list", dl.value.suggested_filename == "lobbyfence-game-whitelist.txt"
              and text.splitlines()[-2:] == ["1.2.3.4", "5.6.7.0/24"] and text.startswith("# LobbyFence whitelist"), text)
        lm.get_by_role("button", name="Copy").click()
        check("copy gives feedback", lm.locator("p").filter(has_text="Cop").count() >= 1)
        import tempfile, os
        up = os.path.join(tempfile.mkdtemp(), "friends-list.txt")
        open(up, "w").write("# from a friend\n80.20.0.1\n2a00:1450::/32\n")
        lm.locator("input[type=checkbox]").check()
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, allow: ['80.20.0.1', '2a00:1450::/32'], block: [] }) }""")
        lm.locator("input[type=file]").set_input_files(up)
        page.wait_for_function("document.querySelector('#modal').innerText.includes('2a00:1450::/32')")
        ex = page.evaluate("window.__execs.slice(-2)")
        check("upload with 'replace' removes old entries, then adds the file's",
              ex[0][:3] == ["/usr/sbin/lobbyfence", "unlist", "game"] and set(ex[0][3:]) == {"1.2.3.4", "5.6.7.0/24"}
              and ex[1] == ["/usr/sbin/lobbyfence", "allow", "game", "80.20.0.1", "2a00:1450::/32"], ex)
        lm.locator(".tabmenu-item-block a").click()
        check("blacklist tab", lm.get_by_text("Always blocked, even inside your region.").is_visible())
        lm.get_by_role("button", name="Close").click()
        check("panel summary updated", panel.get_by_text("Whitelist: 2 · Blacklist: 0").is_visible())
        # back to the state step 5b expects: fresh page, popup of the JP server open
        boot(page, cfg, files, services)
        page.wait_for_function("document.querySelector('.lf-tabs') && document.querySelector('.lf-tabs').innerText.includes('Blocked')")
        page.locator(".lf-tab", has_text="Blocked").click()
        page.locator(".lf-search input").fill("jp")
        page.locator(".lf-row").first.click()
        page.locator(".lf-search input").fill("")

        # ---- 5b. allow / block by clicking a server on the map
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, zone: 'game', action: 'allow', allow: ['99.1.1.1'], block: [] }) }""")
        page.locator("#fake-popup").get_by_role("button", name="Always allow").click()
        page.wait_for_function("document.querySelector('#fake-popup') && document.querySelector('#fake-popup').innerText.includes('allowed by you')")
        last = page.evaluate("window.__execs.slice(-1)[0]")
        check("allow runs on the router at once", last == ["/usr/sbin/lobbyfence", "allow", "game", "99.1.1.1"], last)
        check("popup now offers block / remove", page.locator("#fake-popup").get_by_role("button", name="Block instead").is_visible()
              and page.locator("#fake-popup").get_by_role("button", name="Remove rule").is_visible())
        feat = page.evaluate("window.__map.getSource('lf-servers').data.features.find(f => f.properties.ips === '99.1.1.1').properties")
        check("allowed server turns green with a ring", feat["state"] == "in" and feat["manual"] == "allow", feat)
        tabs = page.locator(".lf-tab").all_inner_texts()
        check("lists follow the rule", [t.split()[-1] for t in tabs] == ["2", "1", "1"], tabs)
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, zone: 'game', action: 'block', allow: [], block: ['99.1.1.1', '45.10.0.1'] }) }""")
        page.locator("#fake-popup").get_by_role("button", name="Block instead").click()
        page.wait_for_function("document.querySelector('#fake-popup').innerText.includes('blocked by you')")
        tabs = page.locator(".lf-tab").all_inner_texts()
        check("blocking an inside server moves it to Blocked", [t.split()[-1] for t in tabs] == ["0", "3", "1"], tabs)
        page.evaluate("window.__map.fire('click', {features:[{properties:{state:'out',cc:'US',ips:'80.20.0.1 80.20.0.2',manual:''},geometry:{coordinates:[-74,40.71]}}]}, 'lf-servers')")
        check("a dot with several servers offers allow-all", page.locator("#fake-popup").get_by_role("button", name="Allow all 2").is_visible())
        if SHOTS:
            page.evaluate("Object.assign(document.getElementById('fake-popup').style, {position:'absolute', left:'260px', top:'220px', zIndex: 4})")
            page.locator("#fake-popup").evaluate("n => n.parentNode.classList.add('maplibregl-popup-content')")
            page.screenshot(path=str(SHOTS / "popup.png"))
        page.evaluate("""window.__execResult = { code: 1, stdout: '', stderr: 'lobbyfence: no such zone: game' }""")
        page.locator("#fake-popup").get_by_role("button", name="Allow all 2").click()
        page.wait_for_timeout(100)
        check("unsaved zone explained", any("Save & Apply first" in n for n in page.evaluate("window.__notes || []")))
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, allow: [], block: [] }) }""")
        page.locator(".lf-tab", has_text="Unknown").click()
        page.locator(".lf-row").first.click()
        check("unlocated servers can be ruled from the list", page.locator("#modal").get_by_role("button", name="Always allow").is_visible())
        page.locator("#modal").get_by_role("button", name="Close").click()
        page.locator(".lf-tab", has_text="Allowed").click()

        # ---- 5c. filtering mode switch on the map page
        check("zone without explicit strict shows Strict", "lf-on" in page.locator(".lf-seg button[data-mode=strict]").get_attribute("class"))
        page.locator(".lf-seg button[data-mode=monitor]").click()
        check("mode switch stages monitor", page.evaluate("[uciState.game.mode, uciState.game.strict]") == ["monitor", "0"])
        page.wait_for_timeout(600)
        check("mode switch saved right away", page.evaluate("window.__saved.game.mode") == "monitor")
        check("monitor relabels the blocked tab", "Would block" in " ".join(page.locator(".lf-tab").all_inner_texts()))
        page.locator(".lf-seg button[data-mode=strict]").click()
        page.wait_for_timeout(600)
        check("back to strict", page.evaluate("[uciState.game.mode, uciState.game.strict]") == ["enforce", "1"])

        # ---- 6. Test API button
        page.evaluate("""window.__execResult = { code: 0, stdout: JSON.stringify({ ok: true, ip: '8.8.8.8', lat: 37.7, lon: -97.8, country: 'US', ms: 120, url: 'x' }) }""")
        page.get_by_role("button", name="Test API").click()
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('Test passed')")
        check("Test API runs the router-side check", page.evaluate("window.__execs.slice(-1)[0]") == ["/usr/sbin/lobbyfence", "apitest"])
        check("Test API success message", panel.get_by_text("Test passed: 8.8.8.8").is_visible())
        page.evaluate("""window.__execResult = { code: 1, stdout: JSON.stringify({ ok: false, error: 'no answer - check DNS', ms: 0, url: 'x' }) }""")
        page.get_by_role("button", name="Test API").click()
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('Test failed')")
        check("Test API failure message", panel.get_by_text("Test failed: no answer - check DNS").is_visible())
        page.get_by_role("button", name="Learn now").click()
        page.wait_for_timeout(100)
        check("Learn now runs a cycle", page.evaluate("window.__execs.slice(-1)[0]") == ["/usr/sbin/lobbyfence", "cycle"])

        # ---- 6a. Ports seen: narrow the zone to the ports its game really used
        zid = page.evaluate("document.querySelector('.lf-zonesel') ? document.querySelector('.lf-zonesel').value : null") or "game"
        page.evaluate("z => { uciState[z].remote_port = [ '1024-65535' ]; }", zid)   # (a wide range, like Any game)
        ports_out = "udp/10200 1 7922 100 200 5 1 25000\nudp/10600 1 4371 100 200 3 1\nudp/27019 2 8 100 200 2 1 400\nudp/27054 1 8 100 200 1 1\n"
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", ports_out)
        page.locator(".lf-portsseen").click()
        pm = page.locator("#modal")
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 4")
        check("Ports… asks the router for the zone's ports", page.evaluate("window.__execs.slice(-1)[0]")[:2] == ["/usr/sbin/lobbyfence", "ports"])
        ticked = page.evaluate("[...document.querySelectorAll('.lf-ports-pick')].map(c => c.checked)")
        check("busy ports ticked for you, the short ping ones not (by the most in one pass, not the total)", ticked == [True, True, False, False], ticked)
        cells = page.evaluate("[...document.querySelectorAll('.lf-ports-list tr')].slice(1).map(r => [r.cells[2].innerText, r.cells[2].title])")
        check("Packets shows the total sent, the busiest pass on hover", cells[0] == ["25000", "Most in one pass: 7922"] and cells[2] == ["400", "Most in one pass: 8"], cells)
        check("...a port from before totals were kept shows its peak", cells[1][0] == "4371", cells)
        check("preview rounds to blocks of 100", "10200-10299, 10600-10699" in pm.locator(".lf-ports-preview").inner_text(), pm.locator(".lf-ports-preview").inner_text())
        pm.locator(".lf-ports-pick").nth(2).check(); pm.locator(".lf-ports-pick").nth(3).check()
        check("ping ports merge into one block", "10200-10299, 10600-10699, 27000-27099" in pm.locator(".lf-ports-preview").inner_text(), pm.locator(".lf-ports-preview").inner_text())
        pm.locator(".lf-ports-round").uncheck()
        check("exact ports without rounding", "10200, 10600, 27019, 27054" in pm.locator(".lf-ports-preview").inner_text(), pm.locator(".lf-ports-preview").inner_text())
        pm.locator(".lf-ports-round").check()
        # live: a new port seen while the window is open shows up by itself; the ticks set by hand stay
        pm.locator(".lf-ports-pick").nth(3).uncheck()
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", ports_out + "udp/10900 1 9000 100 260 1 1\n")
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 5", timeout=9000)
        ticked = page.evaluate("Object.fromEntries([...document.querySelectorAll('.lf-ports-pick')].map(c => [c.value, c.checked]))")
        check("Ports seen refreshes by itself while open", "10900" in ticked, ticked)
        check("...the new busy port ticked, the user's own ticks kept", ticked == {"10200": True, "10600": True, "10900": True, "27019": True, "27054": False}, ticked)
        check("...says it updates by itself", "Updates by itself" in pm.locator(".lf-ports-live").inner_text())
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", ports_out)
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 4", timeout=9000)
        pm.locator(".lf-ports-pick[value='27054']").check()
        game_before = page.evaluate("z => (uciState[z] || {}).game || null", zid)
        pm.locator(".lf-ports-use").click()
        rp = page.evaluate("z => uciState[z].remote_port", zid)
        check("Use these ports sets the zone's server ports", rp == ["10200-10299", "10600-10699", "27000-27099"], rp)
        check("the zone's game stays", page.evaluate("z => (uciState[z] || {}).game || null", zid) == game_before or game_before is None)
        # opened again: the ports already in the zone's server ports show ticked - the short ping ones too
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", ports_out + "udp/30500 1 900 100 200 3 1 900\n")
        page.locator(".lf-portsseen").click()
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 5")
        ticked = page.evaluate("Object.fromEntries([...document.querySelectorAll('.lf-ports-pick')].map(c => [c.value, c.checked]))")
        check("ports already in the zone's own ports show ticked (a busy one outside them is not)",
              ticked == {"10200": True, "10600": True, "27019": True, "27054": True, "30500": False}, ticked)
        check("...the window says what the ticks mean", "inside the zone's server ports now" in pm.locator(".lf-ports-help").inner_text(),
              pm.locator(".lf-ports-help").inner_text())
        check("...and using them as they are keeps the zone's ports", "become: 10200-10299, 10600-10699, 27000-27099" in pm.locator(".lf-ports-preview").inner_text(),
              pm.locator(".lf-ports-preview").inner_text())
        # "All": every port at once - or none
        allb = pm.locator(".lf-ports-all")
        check("the All box shows a part-ticked list as part-ticked", allb.evaluate("c => c.indeterminate") and not allb.is_checked())
        allb.click()
        check("All ticks every port seen, and the ports to use follow",
              page.evaluate("[...document.querySelectorAll('.lf-ports-pick')].every(c => c.checked)") and allb.is_checked()
              and "10200-10299, 10600-10699, 27000-27099, 30500-30599" in pm.locator(".lf-ports-preview").inner_text(), pm.locator(".lf-ports-preview").inner_text())
        pm.locator("th label", has_text="All").click()
        check("...clicked again (on the word too): none, and Use these ports is off",
              page.evaluate("[...document.querySelectorAll('.lf-ports-pick')].every(c => !c.checked)") and not allb.is_checked()
              and pm.locator(".lf-ports-use").is_disabled())
        page.locator(".lf-ports-pick[value='10200']").check()
        check("...one ticked by hand: the All box is part-ticked again", allb.evaluate("c => c.indeterminate"))
        page.locator("#modal").get_by_role("button", name="Cancel").click()
        page.evaluate("window.__execResult = { code: 0, stdout: '' }")
        page.locator(".lf-portsseen").click()
        page.wait_for_function("document.querySelector('.lf-ports-empty')")
        check("nothing seen yet says how to collect them", "Play a few matches" in page.locator("#modal").inner_text())
        check("Use is off with nothing ticked", page.locator(".lf-ports-use").is_disabled())
        page.locator("#modal").get_by_role("button", name="Cancel").click()
        n = page.evaluate("window.__execs.filter(e => e[1] === 'ports').length")
        page.wait_for_timeout(6000)
        check("closed: no more reading", page.evaluate("window.__execs.filter(e => e[1] === 'ports').length") == n)
        # sorting: Sort by (or a click on a column), highest first; remembered for next time
        # (the router's clock here is far from this PC's - like a router that has not synced its time)
        page.evaluate("window.__live = { time: 1000, zones: {} }")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }",
                      "udp/30000 1 60 100 200 9 1 100\nudp/20000 3 500 100 300 2 1 900\nudp/10000 1 50 100 250 5 1 200\n")
        page.locator(".lf-portsseen").click()
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 3")
        order = lambda: page.evaluate("[...document.querySelectorAll('.lf-ports-pick')].map(c => +c.value)")
        check("Ports seen: busiest first by default", order() == [20000, 10000, 30000], order())
        seen = page.evaluate("[...document.querySelectorAll('.lf-ports-pick')].map(c => c.closest('tr').lastChild.innerText)")
        check("Last seen is measured by the router's clock, not the PC's", seen == ["11 min ago", "12 min ago", "13 min ago"], seen)
        # (none of these is in the zone's own ports - 10200-10299, 10600-10699, 27000-27099 - so none starts ticked)
        page.locator(".lf-ports-pick[value='30000']").check()
        page.locator(".lf-ports-sort").select_option("passes")
        check("Sort by Seen in: most passes first", order() == [30000, 10000, 20000], order())
        ticks = page.evaluate("Object.fromEntries([...document.querySelectorAll('.lf-ports-pick')].map(c => [c.value, c.checked]))")
        check("...the ticks stay with their ports", ticks == {"30000": True, "10000": False, "20000": False}, ticks)
        page.locator("th.lf-ports-head", has_text="Servers").click()
        check("a click on a column sorts by it (and the Sort by box follows)", order() == [20000, 10000, 30000]
              and page.locator(".lf-ports-sort").input_value() == "servers", order())
        page.locator("th.lf-ports-head", has_text="Last seen").click()
        check("Last seen: newest first", order() == [20000, 10000, 30000], order())
        page.locator("th.lf-ports-head", has_text="Server port").click()
        check("Server port: lowest first, marked on its column", order() == [10000, 20000, 30000]
              and "▲" in page.locator("th.lf-ports-head.lf-on").inner_text(), order())
        page.locator(".lf-ports-sort").select_option("passes")
        if SHOTS:
            page.screenshot(path=str(SHOTS / "ports-sorted.png"))
        page.wait_for_timeout(5600)   # (a live refresh in between keeps the order)
        check("...kept through the live refresh", order() == [30000, 10000, 20000], order())
        page.locator("#modal").get_by_role("button", name="Cancel").click()
        page.locator(".lf-portsseen").click()
        page.wait_for_function("document.querySelectorAll('.lf-ports-pick').length === 3")
        check("the order chosen is remembered next time", order() == [30000, 10000, 20000]
              and page.locator(".lf-ports-sort").input_value() == "passes", order())
        page.locator(".lf-ports-sort").select_option("total")
        page.locator("#modal").get_by_role("button", name="Cancel").click()
        page.evaluate("window.__execResult = null; window.__live = null")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(200)
        # a crash and an error the router recorded an hour ago by its own clock (years behind this PC's)
        page.evaluate("""() => { const s = window.view.status; window.__upd = s.updated; s.updated = 1700000000;
            s.problems = { crashes: 1, crash_time: 1699996400, error: 'test error', error_time: 1699999000 }; window.view.renderStatus(); }""")
        txt = page.locator(".lf-panel").inner_text()
        check("crash and error notes go by the router's clock", "stopped unexpectedly (1 h ago)" in txt and "Last error, 16 min ago" in txt, txt[-400:])
        page.evaluate("() => { const s = window.view.status; s.updated = window.__upd; delete s.problems; window.view.renderStatus(); }")

        # ---- 6b. Servers file: see the saved servers by game, download / copy / import / paste
        sfile = "# LobbyFence servers file\nlobbyfence-servers 1\ngame game Test game\n45.10.0.1 51.5 -0.1 GB 1700000000\n80.20.0.1 40.7 -74.0 US 1700000000\ngame apex\n99.1.1.1 52.5 13.4 DE 1700000000 imported\n"
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", sfile)
        # an older router without the list LobbyFence comes with: the window works as before, no error
        page.get_by_role("button", name="Servers file…").click()
        page.wait_for_function("document.querySelectorAll('.lf-servers-game').length === 2")
        page.wait_for_timeout(300)
        check("no built-in list from the router: that part is just not shown",
              page.locator(".lf-builtin-game").count() == 0 and "Could not" not in page.locator(".lf-servers-state").inner_text())
        page.locator("#modal").get_by_role("button", name="Close").click()
        page.evaluate("t => { window.__builtin = t; }", "lobbyfence-servers 1\ngame apex Apex Legends\n3.67.124.64 50.1 8.7 DE 1794184212\n"
                      "13.113.128.68 35.7 139.7 JP 1794184212\n63.177.165.222 50.1 8.7 DE 1794184212\ngame cod Call of Duty\n45.32.7.134 40.5 -74.4 US 1794182174\n")
        page.get_by_role("button", name="Servers file…").click()
        sm = page.locator("#modal")
        page.wait_for_function("document.querySelectorAll('.lf-servers-game').length === 2")
        check("dialog opens with the servers saved on the router", page.evaluate("window.__execs.slice(-1)[0]") == ["/usr/sbin/lobbyfence", "export"])
        page.wait_for_function("document.querySelectorAll('.lf-builtin-game').length === 2")
        bi = sm.locator(".lf-servers-builtin")
        b1 = bi.locator(".lf-builtin-game").nth(0).locator("summary").inner_text()
        check("the servers LobbyFence comes with have their own part, one line per game",
              "Comes with LobbyFence" in bi.inner_text() and b1.startswith("Apex Legends") and "3 server(s)" in b1 and "DE 2, JP 1" in b1
              and bi.locator(".lf-builtin-game").nth(1).locator("summary").inner_text().startswith("Call of Duty - 1 server(s)"), b1)
        bi.locator(".lf-builtin-game").nth(0).locator("summary").click()
        cells = bi.locator(".lf-builtin-game").nth(0).locator("tr").nth(1).locator("td")
        check("opening one lists its servers (address, country)", cells.count() == 2 and cells.nth(0).inner_text() == "3.67.124.64" and cells.nth(1).inner_text() == "DE",
              [cells.nth(k).inner_text() for k in range(cells.count())])
        check("...read-only: nothing to tick or delete there", bi.locator("input, button").count() == 0)
        bi.locator(".lf-builtin-game").nth(0).locator("summary").click()
        g1 = sm.locator(".lf-servers-game").nth(0).locator("summary").inner_text()
        g2 = sm.locator(".lf-servers-game").nth(1).locator("summary").inner_text()
        check("one line per game: name, count, this router vs imported, countries",
              "Test game" in g1 and "2 server(s)" in g1 and "2 from this router, 0 imported" in g1 and "GB 1" in g1, g1)
        check("a game known only from an import gets its preset's name", g2.startswith("Apex Legends") and "0 from this router, 1 imported" in g2, g2)
        sm.locator(".lf-servers-game").nth(1).locator("summary").click()
        row = sm.locator(".lf-servers-game").nth(1).locator("tr.lf-imp td")
        check("opening a game lists its servers (address, country, from)", row.nth(1).inner_text() == "99.1.1.1" and row.nth(2).inner_text() == "DE"
              and row.nth(4).inner_text() == "imported", [row.nth(k).inner_text() for k in range(row.count())])
        with page.expect_download() as dl:
            sm.get_by_role("button", name="Download servers").click()
        got = open(dl.value.path()).read()
        check("download is the router's servers file", got == sfile and dl.value.suggested_filename.startswith("lobbyfence-servers-"), dl.value.suggested_filename)
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('Downloaded')")
        st = sm.locator(".lf-servers-state").inner_text()
        check("download counts servers and games, and says what to do if the browser blocks it", "3 server(s)" in st and "2 game(s)" in st and "Keep" in st, st)
        sm.get_by_role("button", name="Copy").click()
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('Cop')")
        check("Copy gives feedback", "Copied 3 server(s)" in sm.locator(".lf-servers-state").inner_text() or "Could not copy" in sm.locator(".lf-servers-state").inner_text(),
              sm.locator(".lf-servers-state").inner_text())
        upf = os.path.join(tempfile.mkdtemp(), "friends-servers.txt")
        open(upf, "w").write(sfile)
        page.evaluate("window.__execResult = { code: 0, stdout: 'imported 2 new server location(s) of 3 in the file.\\n3 imported location(s) kept' }")
        sm.locator(".lf-servers-input").set_input_files(upf)
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('imported 2 new')")
        ex = page.evaluate("window.__execs.slice(-2)")
        check("import writes the file, runs import-servers, then shows the list again", page.evaluate("window.__writes.slice(-1)[0]") == ["/tmp/lobbyfence/servers-import.txt", sfile]
              and ex == [["/usr/sbin/lobbyfence", "import-servers", "/tmp/lobbyfence/servers-import.txt"], ["/usr/sbin/lobbyfence", "export"]], ex)
        # pick single servers to delete
        sm.locator(".lf-servers-game").nth(0).locator("summary").click()
        g0 = sm.locator(".lf-servers-game").nth(0)
        ds = g0.locator(".lf-servers-delsel")
        check("Delete selected waits for a pick", ds.is_disabled())
        g0.locator(".lf-servers-pick").nth(1).check()
        check("picking a server enables Delete selected (1)", ds.is_enabled() and "(1)" in ds.inner_text(), ds.inner_text())
        g0.locator(".lf-servers-all").check()
        check("select all picks every server", g0.locator(".lf-servers-pick:checked").count() == 2 and "(2)" in ds.inner_text())
        g0.locator(".lf-servers-all").uncheck()
        g0.locator("label", has_text="80.20.0.1").click()
        n = len(page.evaluate("window.__execs"))
        ds.click()
        check("Delete selected asks once more first", len(page.evaluate("window.__execs")) == n and "Click again to delete 1" in ds.inner_text()
              and "The rest of the list stays" in sm.locator(".lf-servers-state").inner_text(), ds.inner_text())
        page.evaluate("window.__execResult = { code: 0, stdout: 'removed 1 chosen server(s) of game' }")
        ds.click()
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('removed 1 chosen')")
        check("second click deletes just the picked server", ["/usr/sbin/lobbyfence", "remove-servers", "game", "80.20.0.1"] in page.evaluate("window.__execs"))
        page.wait_for_function("document.querySelector('.lf-servers-game[data-game=game]') && document.querySelector('.lf-servers-game[data-game=game]').open")
        check("the game stays open after the list is read again", True)
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", sfile)
        sm.locator(".lf-servers-game").nth(1).locator("summary").click()
        rb = sm.locator(".lf-servers-game").nth(1).locator(".lf-servers-remove")
        n = len(page.evaluate("window.__execs"))
        rb.click()
        check("Remove asks once more first", len(page.evaluate("window.__execs")) == n and "Click again" in rb.inner_text()
              and "Whitelists, blacklists and regions stay" in sm.locator(".lf-servers-state").inner_text(), rb.inner_text())
        page.evaluate("window.__execResult = { code: 0, stdout: 'removed 1 server(s) of apex' }")
        rb.click()
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('removed 1 server')")
        check("second click removes that game's list on the router", page.evaluate("window.__execs").__contains__(["/usr/sbin/lobbyfence", "remove-servers", "apex"]))
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", sfile)
        n = len(page.evaluate("window.__execs"))
        bad = os.path.join(tempfile.mkdtemp(), "other.txt")
        open(bad, "w").write("1.2.3.4\n")
        sm.locator(".lf-servers-input").set_input_files(bad)
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('not a LobbyFence servers file')")
        check("other files are refused in the page", len(page.evaluate("window.__execs")) == n)
        sm.get_by_role("button", name="Paste…").click()
        check("Paste opens a box to paste a friend's file into", sm.locator(".lf-servers-paste").is_visible())
        sm.locator(".lf-servers-paste").fill(sfile)
        page.evaluate("window.__execResult = { code: 0, stdout: 'imported 0 new server location(s) of 3 in the file.' }")
        sm.get_by_role("button", name="Import pasted text").click()
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('imported 0 new')")
        check("pasted text is imported the same way", page.evaluate("window.__writes.slice(-1)[0]") == ["/tmp/lobbyfence/servers-import.txt", sfile]
              and sm.locator(".lf-servers-paste").input_value() == "")
        page.evaluate("window.__execResult = { code: 1, stdout: '', stderr: 'lobbyfence: busy' }")
        sm.locator(".lf-servers-input").set_input_files(upf)
        page.wait_for_function("document.querySelector('.lf-servers-state').innerText.includes('Could not import it: busy')")
        check("router errors are shown", True)
        sm.get_by_role("button", name="Close").click()
        page.evaluate("window.__execResult = { code: 0, stdout: 'lobbyfence-servers 1\\n' }")
        page.get_by_role("button", name="Servers file…").click()
        page.wait_for_function("document.querySelector('.lf-servers-empty')")
        check("nothing saved yet says so", "No located servers saved yet" in page.locator("#modal").inner_text())
        page.locator("#modal").get_by_role("button", name="Close").click()
        page.evaluate("window.__execResult = null")

        # ---- 6c. the lists follow the router by themselves
        page.evaluate("window.__live = null")
        page.locator(".lf-search select").last.select_option("all")
        page.locator(".lf-tab", has_text="Allowed").click()
        allowed = lambda: int(page.locator(".lf-tab[data-tab=in] .lf-muted").inner_text())
        a0 = allowed()
        def more_servers(*ips):
            page.evaluate("t => { window.__files['/tmp/lobbyfence/game.servers'] += t; }",
                          "".join("%s in 50.11 8.68 DE 1700000400\n" % ip for ip in ips))
        more_servers("45.10.0.7", "45.10.0.8")
        # (nobody clicks, LuCI's own refresh loop is paused: the page's own check every few seconds)
        page.evaluate("window.view.watchdogMs = 300")
        try:
            page.wait_for_function(f"+document.querySelector('.lf-tab[data-tab=in] .lf-muted').innerText === {a0 + 2}", timeout=6000)
            ok = True
        except Exception:
            ok = False
        check("the server list updates by itself, also while LuCI's refresh loop is paused", ok, [a0, allowed()])
        page.evaluate("window.view.watchdogMs = 0")
        # one part failing (the map) must not keep the list from updating
        page.evaluate("""() => { const v = window.view, d = v.drawServers;
            v.drawServers = function() { v.drawServers = d; throw new Error('test: map failed'); }; }""")
        more_servers("45.10.0.9")
        page.evaluate("window.__poll()")
        page.wait_for_timeout(300)
        check("...and when drawing the map fails once, the list still updates", allowed() == a0 + 3, [a0, allowed()])
        page.evaluate("window.__poll()")
        page.wait_for_timeout(300)
        check("...and the map is drawn again on the next refresh", page.evaluate("window.__map.sources['lf-servers'].data.features.length") >= a0 + 3,
              page.evaluate("window.__map.sources['lf-servers'].data.features.length"))
        # the Servers file window: new servers show up while it is open (not while some are ticked)
        page.evaluate("window.view.serversFollowMs = 400")
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; window.__builtin = null; }", sfile)
        page.get_by_role("button", name="Servers file…").click()
        page.wait_for_function("document.querySelectorAll('.lf-servers-game').length === 2")
        c0 = page.locator(".lf-servers-game").nth(0).locator(".lf-servers-count").inner_text()
        page.locator(".lf-servers-game").nth(0).locator("summary").click()
        page.locator(".lf-servers-game").nth(0).locator(".lf-servers-pick").nth(0).check()
        page.evaluate("t => { window.__execResult = { code: 0, stdout: t }; }", sfile.replace("game game Test game\n", "game game Test game\n45.10.0.9 50.1 8.7 DE 1700000400\n"))
        page.wait_for_timeout(1200)
        check("Servers file: nothing is redrawn while servers are ticked", page.locator(".lf-servers-game").nth(0).locator(".lf-servers-count").inner_text() == c0
              and page.locator(".lf-servers-pick:checked").count() == 1)
        page.locator(".lf-servers-game").nth(0).locator(".lf-servers-pick").nth(0).uncheck()
        try:
            page.wait_for_function(f"document.querySelector('.lf-servers-game .lf-servers-count').innerText !== {json.dumps(c0)}", timeout=4000)
            ok = True
        except Exception:
            ok = False
        c1 = page.locator(".lf-servers-game").nth(0).locator(".lf-servers-count").inner_text()
        check("Servers file: new servers show up while the window is open", ok and c1 != c0, [c0, c1])
        check("...the game that was open stays open, and the window says it follows", page.locator(".lf-servers-game").nth(0).evaluate("d => d.open")
              and "Updates by itself" in page.locator(".lf-servers-live").inner_text())
        page.locator("#modal").get_by_role("button", name="Close").click()
        page.evaluate("window.view.serversFollowMs = 0; window.__execResult = null")

        if SHOTS:
            SHOTS.mkdir(parents=True, exist_ok=True)
            page.locator(".lf-tab", has_text="Blocked").click()
            page.screenshot(path=str(SHOTS / "midnight.png"))

        # ---- 7. theme switch
        n_styles = page.evaluate("window.__map.styles.length")
        page.locator(".lf-bar select").last.select_option("light")
        page.wait_for_function(f"window.__map.styles.length > {n_styles} && window.__map.layers['lf-servers']")
        check("Light theme: basemap colours untouched",
              page.evaluate("window.__map.style.layers[0].paint['background-color']") == "#f8f8f8")
        check("Light theme: app no longer dark", page.locator(".lf-app.lf-dark").count() == 0)
        check("Light theme: overlay colours swapped",
              "#2563eb" in json.dumps(page.evaluate("window.__map.layers['lf-circle-line'].paint['line-color']")))
        check("theme switch keeps the camera", page.evaluate("window.__map.calls.slice(-1)[0][0]") == "flyTo")
        check("theme remembered", page.evaluate("localStorage.getItem('lobbyfence.theme')") == '"light"')
        if SHOTS:
            page.screenshot(path=str(SHOTS / "light.png"))
        check("no Slate theme any more", page.locator(".lf-bar select option[value=slate]").count() == 0)
        for fx_theme, part in (("galaxy", ".lf-fx-stars"),):
            page.locator(".lf-bar select").last.select_option(fx_theme)
            page.wait_for_timeout(150)
            check(fx_theme + " theme draws its effect", page.locator(".lf-fx " + part).count() > 0)
            check(fx_theme + " effect never catches clicks", page.evaluate("getComputedStyle(document.querySelector('.lf-fx')).pointerEvents") == "none")
            if SHOTS:
                page.screenshot(path=str(SHOTS / (fx_theme + ".png")))
        check("Blood theme is gone", page.locator(".lf-bar select").last.locator("option[value=blood]").count() == 0)
        check("galaxy stars move", "lf-stars-a" in page.evaluate("getComputedStyle(document.querySelector('.lf-fx-far')).animationName"))
        page.locator(".lf-bar select").last.select_option("satellite")
        page.wait_for_function("window.__map.style.layers[0].id === 'satellite'")
        st = page.evaluate("window.__map.style")
        check("Satellite: imagery with borders and place names on top",
              "eox.at" in st["sources"]["satellite"]["tiles"][0] and [l["id"] for l in st["layers"]] == ["satellite", "satellite-hd"], [l["id"] for l in st["layers"]])
        check("Satellite: dark controls", page.locator(".lf-app.lf-dark").count() == 1)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "satellite.png"))

        # ---- 6b. what this browser remembered under LobbyFence's old name (RegionGate) moves over
        boot(page, cfg, files, services, storage={"regiongate.theme": '"light"', "regiongate.nopanel": "true",
                                                 "lobbyfence.nopanel": "false", "regiongate.view": '{"fit":true}'})
        check("old name: the theme chosen before the rename is used", page.locator(".lf-app.lf-dark").count() == 0 and
              page.evaluate("localStorage.getItem('lobbyfence.theme')") == '"light"')
        check("old name: a setting already made under the new name wins", page.evaluate("localStorage.getItem('lobbyfence.nopanel')") == "false")
        check("old name: nothing left under it", page.evaluate("Object.keys(localStorage).filter(k => k.startsWith('regiongate')).length") == 0,
              page.evaluate("Object.keys(localStorage)"))

        # ---- 7a. lag simulator panel
        boot(page, cfg, files, services)
        lag = page.locator(".lf-lag")
        page.wait_for_function("document.querySelector('.lf-lag') && document.querySelector('.lf-lag').textContent.includes('Lag simulator')")
        check("lag: off by default, says so", "Off - your connection is not changed" in lag.inner_text())
        lag.get_by_role("button", name="?").click()
        check("lag: ? explains what it can and can't do", lag.get_by_text("What it can do").is_visible() and lag.get_by_text("What it can't do").is_visible()
              and lag.get_by_text("only adds lag", exact=False).is_visible())
        lag.locator(".lf-switch input").check()
        page.wait_for_timeout(100)
        dsel = lag.locator(".lf-lag-lag_direction")
        check("lag: direction choice, both ways by default", dsel.input_value() == "both"
              and dsel.locator("option").all_inner_texts() == ["Both ways", "Download only", "Upload only"]
              and "split half and half" in lag.inner_text().lower())
        dsel.select_option("up")
        page.wait_for_timeout(100)
        check("lag: upload only explained", "your moves and shots reach the server late" in lag.inner_text())
        lag.locator(".lf-lag-lag_delay").fill("60"); lag.locator(".lf-lag-lag_delay").dispatch_event("change")
        lag.locator(".lf-lag-lag_jitter").fill("15"); lag.locator(".lf-lag-lag_jitter").dispatch_event("change")
        lag.locator(".lf-lag-lag_loss").fill("1.5"); lag.locator(".lf-lag-lag_loss").dispatch_event("change")
        page.wait_for_timeout(700)
        saved_lag = page.evaluate("[window.__saved.game.lag, window.__saved.game.lag_delay, window.__saved.game.lag_jitter, window.__saved.game.lag_loss]")
        check("lag: settings saved like everything else", saved_lag == ["1", "60", "15", "1.5"], saved_lag)
        check("lag: direction saved", page.evaluate("window.__saved.game.lag_direction") == "up")
        check("lag: asks for Save & Apply", "Press Save & Apply to start it" in lag.inner_text())
        lag.locator(".lf-lag-lag_delay").fill("99999"); lag.locator(".lf-lag-lag_delay").dispatch_event("change")
        check("lag: impossible values refused", lag.locator(".lf-lag-lag_delay").input_value() == "60")
        # the 5-second refresh must not wipe what is being typed
        box = lag.locator(".lf-lag-lag_delay")
        box.click(); box.fill("12")
        page.evaluate("window.view.refresh()")
        page.wait_for_timeout(300)
        check("refresh keeps what you're typing", box.input_value() == "12" and page.evaluate("document.activeElement.classList.contains('lf-lag-lag_delay')"))
        bs_box = page.locator(".lf-burst-burst_servers")
        bs_box.click(); bs_box.fill("3")
        page.evaluate("window.view.refresh()")
        page.wait_for_timeout(300)
        check("...also in the server-test box", page.locator(".lf-burst-burst_servers").input_value() == "3")
        page.locator(".lf-burst-burst_servers").fill("0"); page.locator(".lf-burst-burst_servers").dispatch_event("change")
        box.fill("60"); box.dispatch_event("change")
        page.locator(".lf-laghead h4").click()
        page.wait_for_timeout(300)
        check("leaving the box catches up", page.locator(".lf-lag-lag_delay").input_value() == "60")
        cfg_lag = json.loads(json.dumps(cfg)); cfg_lag["game"].update(lag="1", lag_delay="60", lag_jitter="15", lag_loss="1.5", lag_direction="up")
        miss = json.loads(json.dumps(status)); miss.update(tc=False, pkg="apk")
        miss["zones"][0]["lag"] = {"on": True, "dir": "up", "delay": 60, "jitter": 15, "loss": 1.5, "active": False, "error": "notc"}
        boot(page, cfg_lag, dict(files, **{"/tmp/lobbyfence/status.json": json.dumps(miss)}), services)
        page.wait_for_function("document.querySelector('.lf-lag').innerText.includes('tc-full')")
        check("lag: missing packages explained with the install command", "apk add tc-full kmod-netem kmod-ifb kmod-sched-core kmod-sched-ctinfo" in lag.inner_text()
              and "missing" in lag.inner_text())
        act = json.loads(json.dumps(status)); act.update(tc=True)
        act["zones"][0]["lag"] = {"on": True, "dir": "up", "delay": 60, "jitter": 15, "loss": 1.5, "active": True, "error": ""}
        boot(page, cfg_lag, dict(files, **{"/tmp/lobbyfence/status.json": json.dumps(act)}), services)
        page.wait_for_function("document.querySelector('.lf-lag').innerText.includes('Active')")
        check("lag: active state shown", "Active (upload only): +60 ms ping, ±15 ms jitter, 1.5 % loss" in lag.inner_text(), lag.inner_text())
        if SHOTS:
            page.screenshot(path=str(SHOTS / "lag.png"))
        # with lag, burst and the region open the panel is taller than the map: it scrolls
        lag.get_by_role("button", name="?").click()
        page.wait_for_timeout(100)
        sc = page.evaluate("(() => { const p = document.querySelector('.lf-panel'); return [p.scrollHeight, p.clientHeight, getComputedStyle(p).overflowY]; })()")
        check("panel scrolls when its content is taller than the screen", sc[0] > sc[1] and sc[2] == "auto", sc)
        page.evaluate("document.querySelector('.lf-panel').scrollTop = 1e6")
        page.wait_for_timeout(100)
        last = page.evaluate("""(() => { const p = document.querySelector('.lf-panel').getBoundingClientRect(),
            l = document.querySelector('.lf-list').getBoundingClientRect(); return [l.bottom <= p.bottom + 1, l.height]; })()""")
        check("scrolling down reaches the end of the server list", last[0] and last[1] >= 160, last)
        secs = page.evaluate("[...document.querySelectorAll('.lf-panel > .lf-sec')].map(s => s.getBoundingClientRect().height)")
        check("no section is squashed", all(h == 0 or h > 30 for h in secs), secs)

        # ---- 7a+. phone-sized screen: nothing sticks out sideways
        page.set_viewport_size({"width": 390, "height": 844})
        boot(page, cfg_lag, files, services)
        page.wait_for_timeout(400)
        wide = page.evaluate("""(() => { const vw = document.documentElement.clientWidth, out = [];
            document.querySelectorAll('.lf-app *').forEach(e => { const r = e.getBoundingClientRect();
                if (r.width && r.right > vw + 1 && !e.closest('.lf-mapwrap')) out.push(e.className || e.tagName); });
            return [document.documentElement.scrollWidth, vw, out.slice(0, 8)]; })()""")
        check("phone width: no sideways overflow", wide[0] <= wide[1] + 1 and not wide[2], wide)
        if SHOTS:
            page.screenshot(path=str(SHOTS / "phone.png"), full_page=True)
        page.set_viewport_size({"width": 1400, "height": 900})

        # ---- 7b. nothing learned: diagnostics + stopped service
        quiet = json.loads(json.dumps(status))
        quiet["zones"][0].update(packets=0, blocked=0, devices=[], macs=1)
        files2 = dict(files, **{"/tmp/lobbyfence/status.json": json.dumps(quiet)})
        boot(page, cfg, files2, services)
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('No game traffic')")
        check("diagnostic: no game traffic yet", panel.get_by_text("No game traffic from this device yet", exact=False).is_visible())
        check("diagnostic: device not seen", panel.get_by_text("Device not seen on the network", exact=False).is_visible())
        off = json.loads(json.dumps(status)); off.update(offload=True, conntrack=False)
        boot(page, cfg, dict(files, **{"/tmp/lobbyfence/status.json": json.dumps(off)}), services)
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('Flow offloading is on')")
        check("flow offloading warning", panel.get_by_text("Turn it off under Network", exact=False).is_visible())
        boot(page, cfg, files, services)
        page.wait_for_timeout(300)
        check("no offload warning normally", "Flow offloading" not in page.locator(".lf-panel").inner_text())
        boot(page, cfg, files2, {})
        page.wait_for_function("document.querySelector('.lf-panel').innerText.includes('Not running')")
        page.get_by_role("button", name="Start LobbyFence").click()
        page.wait_for_timeout(100)
        check("Start button restarts the service", page.evaluate("window.__execs.slice(-1)[0]") == ["/etc/init.d/lobbyfence", "restart"])

        # ---- 8. monitor mode wording
        cfg["game"]["mode"] = "monitor"
        boot(page, cfg, files, services)
        page.wait_for_function("document.querySelector('.lf-tabs').innerText.includes('Would block')")
        page.locator(".lf-tab", has_text="Would block").click()
        check("monitor mode explains the list", page.get_by_text("Monitor mode: these servers are still reachable").is_visible())

        # ---- 8b. delete zones from the map
        two = dict(cfg)
        two["second"] = {".name": "second", ".type": "zone", "label": "Second", "enabled": "1", "device": ["10.0.0.5"]}
        boot(page, two, files, services)
        page.evaluate("() => { window.view.handleSaveApply = function(ev, mode) { window.__applied = mode; return this.handleSave(); }; }")
        page.get_by_role("button", name="Delete zone").click()
        check("delete asks first", page.locator("#modal").get_by_text('Delete "Game"?', exact=False).is_visible())
        page.locator("#modal").get_by_role("button", name="Cancel").click()
        check("cancel keeps the zone", page.evaluate("!!uciState.game"))
        page.get_by_role("button", name="Delete zone").click()
        page.locator("#modal").get_by_role("button", name="Delete zone").click()
        check("zone deleted and applied", page.evaluate("!uciState.game && window.__applied === '0' && !window.__saved.game"))
        check("map switches to the next zone", page.locator(".lf-bar select").first.input_value() == "second")
        page.get_by_role("button", name="Delete zone").click()
        page.locator("#modal").get_by_role("button", name="Delete zone").click()
        check("deleting the last zone shows the welcome card", page.get_by_text("Welcome to LobbyFence").is_visible()
              and not page.get_by_role("button", name="Delete zone").is_visible())

        # ---- 9. no WebGL2
        boot(page, fresh, fail_gl=True)
        page.wait_for_function("document.body.innerText.includes('WebGL2')", timeout=5000)
        check("WebGL2 failure explained", True)
        check("panel still works without a map", page.locator(".lf-panel").get_by_text("API not used yet").is_visible())

        # ---- 10. hostile text from the router (labels, error messages, a device's address,
        # a country code from the network) is shown as text - nothing in it runs
        pay = '<img src=x onerror="window.__pwned=(window.__pwned||[]).concat(\'%s\')">'
        hcfg = {"globals": {".name": "globals", ".type": "globals", "enabled": "1", "home": "40.7,-74.0", "home_label": pay % "home_label"},
                "game": {".name": "game", ".type": "zone", "label": pay % "label", "enabled": "1", "mode": "enforce", "device": ["192.168.1.23"],
                         "circle": ["50.1,8.6,800"], "country": [pay % "country"]}}
        hst = {"version": "1.0.0", "enabled": True, "active": True, "updated": 1, "interval": 20,
               "geo": {"last_ok": 1, "pending": 0, "error": pay % "geo_error"},
               "problems": {"crashes": 2, "crash_time": 9999999999, "error": pay % "problem_error", "error_time": 9999999999},
               "zones": [{"id": "game", "label": pay % "status_label", "enabled": True, "mode": "enforce", "strict": True, "region": True,
                          "servers": 2, "inside": 1, "outside": 1, "pending": 0, "unlocatable": 0, "packets": 10, "blocked": 1,
                          "devices": [pay % "devices"], "macs": 0, "allow": [pay % "allow"], "block": [], "rev": 1,
                          "lag": {"on": True, "dir": "both", "delay": 50, "jitter": 0, "loss": 0, "active": False, "error": pay % "lag_error"}}]}
        hsrv = "45.10.0.1 in 50.11 8.68 DE 1700000000\n80.20.0.1 out 40.71 -74.0 <b>X 1700000100\n"
        boot(page, hcfg, {"/tmp/lobbyfence/game.servers": hsrv, "/tmp/lobbyfence/status.json": json.dumps(hst)}, services,
             hints={"aa:bb:cc:dd:ee:ff": {"name": pay % "hint", "ipaddrs": ["192.168.1.23"]}})
        page.wait_for_timeout(1500)
        page.evaluate("window.view.range = 'all'; window.view.renderServers(); window.view.renderStatus()")
        page.evaluate("window.view.openDebug()")
        page.wait_for_timeout(1200)
        shown = page.locator("body").inner_text()
        check("hostile text from the router is shown as text, nothing in it runs",
              not page.evaluate("window.__pwned || []") and shown.count("onerror") >= 3, [page.evaluate("window.__pwned || []"), shown.count("onerror")])

        browser.close()

    real_errors = [e for e in errors if "no webgl2" not in e and "test: map failed" not in e]
    check("no JavaScript errors", not real_errors, real_errors)
    failed = [r for r in results if not r[1]]
    print("ALL BROWSER TESTS PASSED" if not failed else f"{len(failed)} FAILED")
    sys.exit(1 if failed else 0)


if __name__ == "__main__":
    main()
