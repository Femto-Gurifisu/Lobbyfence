'use strict';
'require view';
'require uci';
'require fs';
'require ui';
'require rpc';
'require poll';
'require network';

/* LuCI's E() treats a plain string as HTML. This page shows text that comes from
 * outside - device names from DHCP, places from the address search, zone names -
 * so here a plain string is always plain text (nothing in it can run). */
var E = (function(E0) {
	function text(v) { return (typeof v === 'string' || typeof v === 'number') ? [ String(v) ] : v; }
	return function(tag, attr, data) {
		return arguments.length < 3 ? E0(tag, text(attr)) : E0(tag, attr, text(data));
	};
})(window.E);

/*
 * LobbyFence - map (landing page)
 * Draw where a zone's game servers may be, watch allowed / blocked servers,
 * and check the geolocation service. MapLibre GL JS (ES module, WebGL2)
 * with OpenFreeMap vector tiles, recoloured per theme.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/* What went wrong in this browser, for the debug report: script errors,
 * failed promises, error messages the page showed, map errors. The newest 60,
 * a message repeated in a row is counted instead of stored again. */
var LF_ERRORS = window.LF_ERRORS = window.LF_ERRORS || [];
function noteError(kind, msg) {
	var last = LF_ERRORS[LF_ERRORS.length - 1];
	msg = String(msg == null ? '' : msg).replace(/#t=[0-9a-f]+/g, '#t=…').slice(0, 600);
	if (last && last.kind === kind && last.msg === msg) { last.n++; last.t = Date.now(); return; }
	LF_ERRORS.push({ t: Date.now(), kind: kind, msg: msg, n: 1 });
	if (LF_ERRORS.length > 60)
		LF_ERRORS.shift();
}
if (!window.LF_ERRORS_HOOKED && typeof window.addEventListener === 'function') {
	window.LF_ERRORS_HOOKED = true;
	window.addEventListener('error', function(ev) {
		var el = ev.target;
		if (el && el !== window && (el.src || el.href))   /* a script / style / image that did not load */
			noteError('load', (el.tagName || '').toLowerCase() + ' ' + (el.src || el.href));
		else
			noteError('script', (ev.error && ev.error.stack) || ((ev.message || 'error') +
				(ev.filename ? ' (' + ev.filename.replace(/^.*\//, '') + ':' + ev.lineno + ':' + ev.colno + ')' : '')));
	}, true);
	window.addEventListener('unhandledrejection', function(ev) {
		var r = ev.reason;
		noteError('promise', r && (r.stack || r.message) || r);
	});
	/* error messages shown on the page (a failed save, a refused command, ...) */
	var addNote = ui.addNotification;
	if (typeof addNote === 'function') ui.addNotification = function(title, children, type) {
		var node = addNote.apply(ui, arguments);
		if (/error|danger|warning/.test(String(type || '')))
			noteError('shown', ((title ? title + ': ' : '') + (node && node.textContent || '')).replace(/^\s*×/, '').trim());
		return node;
	};
}

var MAPLIBRE_VERSION = '6.15.0';

/* the same page runs on FreshTomato (inside a small LuCI stand-in): no lag
 * simulator there, and its firewall limits zone names to 16 characters */
var TOMATO = window.LF_PLATFORM === 'tomato';
var MERLIN = window.LF_PLATFORM === 'merlin';
var DDWRT = window.LF_PLATFORM === 'ddwrt';
/* FreshTomato and Merlin: the page runs outside LuCI, with a Settings tab */
var EMBED = TOMATO || MERLIN || DDWRT;
var ZONE_ID_MAX = EMBED ? 12 : 32;
var MAPLIBRE_BASES = [
	'https://unpkg.com/maplibre-gl@' + MAPLIBRE_VERSION + '/dist',
	'https://cdn.jsdelivr.net/npm/maplibre-gl@' + MAPLIBRE_VERSION + '/dist'
];
var MAP_STYLE = 'https://tiles.openfreemap.org/styles/positron';
var RASTER_SOURCE = {
	type: 'raster',
	tiles: [ 'https://tile.openstreetmap.org/{z}/{x}/{y}.png' ],
	tileSize: 256,
	maxzoom: 19,
	attribution: '&copy; <a href="https://www.openstreetmap.org/copyright" target="_blank" rel="noopener">OpenStreetMap</a> contributors'
};

var THEMES = {
	midnight: {
		label: _('Midnight (black & grey)'),
		dark: true,
		ui: { 'bg': '#0e0f11', 'panel': '#16171a', 'border': '#2a2b30', 'text': '#e4e4e7', 'muted': '#8b8f97',
		      'btn': '#1f2024', 'hover': '#1d1e22', 'accent': '#d4d4d8', 'accent-text': '#111214' },
		overlay: { circle: '#3b82f6', circleSel: '#93c5fd', circleFill: 0.12, allowed: '#22c55e', blocked: '#ef4444', unknown: '#6b7280' },
		map: { land: '#1b1c1f', water: '#0b0b0c', landuse: '#1f2023', road: '#2c2d32', building: '#242529',
		       border: '#4b4d53', label: '#8b8f97', waterLabel: '#45474d', halo: '#0b0b0c' },
		raster: { 'raster-saturation': -1, 'raster-brightness-min': 0.3, 'raster-brightness-max': 0.04 }
	},
	satellite: {
		label: _('Satellite'),
		dark: true,
		satellite: true,
		ui: { 'bg': '#0e0f11', 'panel': '#16171a', 'border': '#2a2b30', 'text': '#e4e4e7', 'muted': '#8b8f97',
		      'btn': '#1f2024', 'hover': '#1d1e22', 'accent': '#fbbf24', 'accent-text': '#111214' },
		overlay: { circle: '#3b82f6', circleSel: '#93c5fd', circleFill: 0.18, allowed: '#22c55e', blocked: '#ef4444', unknown: '#9ca3af' },
		map: null,
		raster: null
	},
	light: {
		label: _('Light'),
		dark: false,
		ui: { 'bg': '#ffffff', 'panel': '#f7f8fa', 'border': '#dfe3e8', 'text': '#1f2328', 'muted': '#6b7280',
		      'btn': '#ffffff', 'hover': '#eef2f7', 'accent': '#3273dc', 'accent-text': '#ffffff' },
		overlay: { circle: '#2563eb', circleSel: '#1e40af', circleFill: 0.12, allowed: '#1f9d55', blocked: '#d33a3a', unknown: '#9ca3af' },
		map: null,
		raster: null
	}
};
THEMES.galaxy = {
	label: _('Galaxy'),
	dark: true,
	fx: 'galaxy',
	ui: { 'bg': '#0a0718', 'panel': '#120d29', 'border': '#2b2152', 'text': '#ece9ff', 'muted': '#9a90c7',
	      'btn': '#1a1438', 'hover': '#211a46', 'accent': '#a78bfa', 'accent-text': '#0a0718' },
	overlay: { circle: '#3b82f6', circleSel: '#93c5fd', circleFill: 0.14, allowed: '#34d399', blocked: '#f472b6', unknown: '#8b86b0' },
	map: { land: '#1b1440', water: '#05031a', landuse: '#211850', road: '#2f2468', building: '#271d5a',
	       border: '#7c5cff', label: '#c4b5fd', waterLabel: '#5b4bb8', halo: '#05031a' },
	raster: { 'raster-hue-rotate': 250, 'raster-saturation': -0.2, 'raster-brightness-min': 0.05, 'raster-brightness-max': 0.3 }
};
var THEME_ORDER = [ 'midnight', 'satellite', 'light', 'galaxy' ];

/* tiny seeded random numbers, so the stars and drips look the same on every visit */
function seeded(seed) {
	return function() { seed = (seed * 1103515245 + 12345) & 0x7fffffff; return seed / 0x7fffffff; };
}

/* a 512 px tile of stars, used as a repeating background */
function starTile(n, seed) {
	var r = seeded(seed), out = '<svg xmlns="http://www.w3.org/2000/svg" width="512" height="512">';
	for (var i = 0; i < n; i++) {
		var big = r() > 0.92;
		out += '<circle cx="' + (r() * 512).toFixed(1) + '" cy="' + (r() * 512).toFixed(1) + '" r="' + (big ? 1.3 + r() : 0.4 + r() * 0.6).toFixed(2) +
			'" fill="' + [ '#ffffff', '#c7d2fe', '#fde68a', '#bae6fd' ][Math.floor(r() * 4)] + '" opacity="' + (0.4 + r() * 0.6).toFixed(2) + '"/>';
	}
	return 'url("data:image/svg+xml,' + encodeURIComponent(out + '</svg>') + '")';
}

/* decoration drawn over the map for the Galaxy theme (never catches clicks) */
function themeFx(kind) {
	var r, nodes = [], i, x, w, h;
	if (kind === 'galaxy') {
		r = seeded(21);
		nodes.push(E('div', { 'class': 'lf-fx-nebula' }));
		nodes.push(E('div', { 'class': 'lf-fx-nebula lf-fx-nebula2' }));
		nodes.push(E('div', { 'class': 'lf-fx-stars lf-fx-far', 'style': 'background-image:' + starTile(160, 7) }));
		nodes.push(E('div', { 'class': 'lf-fx-stars lf-fx-near', 'style': 'background-image:' + starTile(40, 99) + ';background-size:384px 384px' }));
		for (i = 0; i < 4; i++)
			nodes.push(E('div', { 'class': 'lf-shoot', 'style': 'top:' + (5 + r() * 45).toFixed(0) + '%;left:' + (20 + r() * 75).toFixed(0) + '%;' +
				'animation-duration:' + (6 + r() * 6).toFixed(1) + 's;animation-delay:' + (i * 2.7 + r() * 2).toFixed(1) + 's' }));
	}
	return nodes;
}
var DEFAULT_THEME = 'midnight';

var WORLD_BOUNDS = [ [ -175, -75 ], [ 175, 78 ] ];      /* Fit: every continent, Antarctica included */
var FULL_BOUNDS = [ [ -180, -85 ], [ 180, 85 ] ];       /* "Zoom out completely": pole to pole */

/* Antarctica has no country label in OpenStreetMap, so the basemap shows none */
var EXTRA_LABELS = { type: 'FeatureCollection', features: [
	{ type: 'Feature', properties: { name: 'Antarctica' }, geometry: { type: 'Point', coordinates: [ 100, -73 ] } }
] };

/* add our own continent label, styled like the theme's country labels */
function addExtraLabels(s) {
	var like = null;
	(s.layers || []).forEach(function(l) {
		if (!like && l.type === 'symbol' && /country/.test(String(l.id).toLowerCase()) && l.layout && l.layout['text-font'])
			like = l;
	});
	if (!like || !s.glyphs)
		return s;
	s.sources['lf-labels'] = { type: 'geojson', data: EXTRA_LABELS };
	s.layers.push({
		id: 'lf-label-continent', type: 'symbol', source: 'lf-labels', maxzoom: 6,
		layout: { 'text-field': [ 'get', 'name' ], 'text-font': like.layout['text-font'], 'text-size': 14,
		          'text-letter-spacing': 0.15, 'text-transform': 'uppercase', 'text-allow-overlap': true },
		paint: {
			'text-color': (like.paint && like.paint['text-color']) || '#555',
			'text-halo-color': (like.paint && like.paint['text-halo-color']) || '#fff',
			'text-halo-width': (like.paint && like.paint['text-halo-width']) || 1.2
		}
	});
	return s;
}
var DEFAULT_RADIUS_KM = 500;
var EARTH_KM = 6371.0088;
var POLE_LAT = 85;
var MAX_ROWS = 300;
/* location pin for home, drawn in the theme's circle colour (no shadow box behind it) */
var PIN_PATH = 'M12 1.5C7.6 1.5 4 5 4 9.4c0 5.9 8 13.1 8 13.1s8-7.2 8-13.1C20 5 16.4 1.5 12 1.5z';
function pinSvg(color, size, outline) {
	return '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 24 24" width="' + size + '" height="' + size + '" aria-hidden="true" style="display:block;overflow:visible">' +
		'<path fill="' + color + '"' + (outline ? ' stroke="#ffffff" stroke-width="1.3" stroke-linejoin="round"' : '') + ' d="' + PIN_PATH + '"/>' +
		'<circle cx="12" cy="9.4" r="3" fill="#ffffff"/></svg>';
}
/* which learned servers to show: seconds since last seen (0 = all) */
var RANGES = [ [ 'active', 20 * 60 ], [ 'hour', 3600 ], [ 'day', 86400 ], [ 'all', 0 ] ];

/* LuCI evaluates views as classic scripts; keep the import() out of the parser's way */
var importModule = new Function('url', 'return import(url);');
var maplibrePromise = null;
var baseStylePromise = null;

var callRevert = rpc.declare({
	object: 'uci',
	method: 'revert',
	params: [ 'config' ]
});

var callServiceList = rpc.declare({
	object: 'service',
	method: 'list',
	params: [ 'name' ],
	expect: { '': {} }
});

/* ------------------------------------------------------------- loading */

function addCssText(text) {
	if (document.getElementById('lf-maplibre-css'))
		return;
	var st = document.createElement('style');
	st.id = 'lf-maplibre-css';
	st.textContent = text;
	document.head.appendChild(st);
}

/* The map library's code runs inside the router's admin page, so it may
 * only run when it is exactly the published release: each file is downloaded,
 * its SHA-256 compared with these (MapLibre GL JS 6.15.0 from npm - the same
 * files unpkg and jsDelivr serve), and only then started (from a blob: copy of
 * the checked bytes). A changed copy on a CDN is refused; the next CDN is tried. */
var MAPLIBRE_SHA256 = {
	'maplibre-gl.mjs': 'QRmLI2eafYiSGDQIu+8uq9x0dFvrkCYfa+D2YLeusv0=',
	'maplibre-gl-worker.mjs': 'HGkGY2gzGq5jln7SSpr/z5Ys9V/MbY9TKosED3NtvPo=',
	'maplibre-gl.css': 'qQeYoZUwF3kOWQ9+G9Nf8QOopCY5cstHKQt4rfhvjCA='
};

/* SHA-256 (base64) of an ArrayBuffer. The browser's own on https; router
 * pages are usually plain http, where it doesn't exist - then this one */
function sha256(buf) {
	var subtle = window.crypto && window.crypto.subtle;
	if (subtle && window.isSecureContext)
		return subtle.digest('SHA-256', buf).then(b64);
	return Promise.resolve(b64(sha256js(new Uint8Array(buf))));

	function b64(ab) {
		var b = new Uint8Array(ab), s = '', i;
		for (i = 0; i < b.length; i++) s += String.fromCharCode(b[i]);
		return window.btoa(s);
	}
}

function sha256js(m) {
	var K = [ 0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
		0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
		0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
		0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
		0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
		0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
		0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
		0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2 ];
	var H = [ 0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19 ];
	var n = m.length, total = ((n + 9 + 63) >> 6) << 6, p = new Uint8Array(total), w = new Int32Array(64), dv, i, j;
	var a, b, c, d, e, f, g, h, t1, t2, out;
	p.set(m);
	p[n] = 0x80;
	dv = new DataView(p.buffer);
	dv.setUint32(total - 8, Math.floor(n / 0x20000000));
	dv.setUint32(total - 4, (n << 3) >>> 0);
	for (i = 0; i < total; i += 64) {
		for (j = 0; j < 16; j++) w[j] = dv.getInt32(i + j * 4);
		for (j = 16; j < 64; j++) {
			a = w[j - 15]; b = w[j - 2];
			w[j] = (((a >>> 7) | (a << 25)) ^ ((a >>> 18) | (a << 14)) ^ (a >>> 3)) + w[j - 16] +
				(((b >>> 17) | (b << 15)) ^ ((b >>> 19) | (b << 13)) ^ (b >>> 10)) + w[j - 7] | 0;
		}
		a = H[0]; b = H[1]; c = H[2]; d = H[3]; e = H[4]; f = H[5]; g = H[6]; h = H[7];
		for (j = 0; j < 64; j++) {
			t1 = h + (((e >>> 6) | (e << 26)) ^ ((e >>> 11) | (e << 21)) ^ ((e >>> 25) | (e << 7))) + ((e & f) ^ (~e & g)) + K[j] + w[j] | 0;
			t2 = (((a >>> 2) | (a << 30)) ^ ((a >>> 13) | (a << 19)) ^ ((a >>> 22) | (a << 10))) + ((a & b) ^ (a & c) ^ (b & c)) | 0;
			h = g; g = f; f = e; e = d + t1 | 0; d = c; c = b; b = a; a = t1 + t2 | 0;
		}
		H[0] = H[0] + a | 0; H[1] = H[1] + b | 0; H[2] = H[2] + c | 0; H[3] = H[3] + d | 0;
		H[4] = H[4] + e | 0; H[5] = H[5] + f | 0; H[6] = H[6] + g | 0; H[7] = H[7] + h | 0;
	}
	out = new Uint8Array(32);
	dv = new DataView(out.buffer);
	for (j = 0; j < 8; j++) dv.setUint32(j * 4, H[j] >>> 0);
	return out.buffer;
}

/* one file, checked: resolves with its bytes, rejects when it isn't the release */
function fetchChecked(base, name) {
	var want = (window.LF_TEST_MAPLIBRE_SHA256 || MAPLIBRE_SHA256)[name];
	return window.fetch(base + '/' + name, { credentials: 'omit', cache: 'force-cache' }).then(function(r) {
		if (!r.ok)
			throw new Error('HTTP ' + r.status + ' for ' + name);
		return r.arrayBuffer();
	}).then(function(buf) {
		return sha256(buf).then(function(got) {
			if (want !== '*' && got !== want) {
				noteError('load', 'map library ' + name + ' from ' + base + ' is not the published release (SHA-256 ' + got + ') - refused');
				throw new Error(name + ' from ' + base + ' failed its integrity check');
			}
			return buf;
		});
	});
}

function loadMaplibre() {
	if (maplibrePromise)
		return maplibrePromise;

	maplibrePromise = MAPLIBRE_BASES.reduce(function(chain, base) {
		return chain.catch(function() {
			return Promise.all([ fetchChecked(base, 'maplibre-gl.mjs'), fetchChecked(base, 'maplibre-gl-worker.mjs'),
				fetchChecked(base, 'maplibre-gl.css') ]).then(function(files) {
				var main = URL.createObjectURL(new Blob([ files[0] ], { type: 'text/javascript' }));
				var worker = URL.createObjectURL(new Blob([ files[1] ], { type: 'text/javascript' }));
				return importModule(main).then(function(ml) {
					if (!ml || typeof ml.Map !== 'function')
						throw new Error('MapLibre did not load from ' + base);
					/* (started from a blob: copy it can't find its worker by itself) */
					if (typeof ml.setWorkerUrl === 'function')
						ml.setWorkerUrl(worker);
					addCssText(new TextDecoder().decode(files[2]));
					return ml;
				});
			});
		});
	}, Promise.reject(new Error('start')));

	maplibrePromise.catch(function() { maplibrePromise = null; });
	return maplibrePromise;
}

function loadBaseStyle() {
	if (!baseStylePromise)
		baseStylePromise = fetch(MAP_STYLE).then(function(res) {
			if (!res.ok)
				throw new Error('HTTP ' + res.status);
			return res.json();
		}).catch(function() {
			return null;   /* use the raster fallback */
		});
	return baseStylePromise;
}

/* --------------------------------------------------------------- themes */

/* Recolour a vector style for a theme: every layer gets a flat colour picked
 * from its role (water, roads, borders, labels ...). Widths, zoom ranges and
 * filters are kept. Camera keys are dropped so a style switch never moves the map. */
function themedStyle(base, theme) {
	var s = JSON.parse(JSON.stringify(base)), m = theme.map;

	[ 'center', 'zoom', 'bearing', 'pitch' ].forEach(function(k) { delete s[k]; });
	if (!m)
		return s;

	function role(id) {
		if (/water|ocean|sea|lake|river|marine|bay/.test(id)) return 'water';
		if (/boundary|admin|border/.test(id)) return 'border';
		if (/road|highway|street|transport|tunnel|bridge|rail|aeroway|path|ferry/.test(id)) return 'road';
		if (/building/.test(id)) return 'building';
		if (/park|landcover|landuse|wood|grass|forest|ice|glacier|sand|wetland|national|cemetery|hospital|school|residential|industrial|farm|scrub/.test(id)) return 'landuse';
		return 'land';
	}

	(s.layers || []).forEach(function(l) {
		var id = String(l.id).toLowerCase(), r = role(id), p = l.paint = l.paint || {};
		switch (l.type) {
		case 'background':
			p['background-color'] = m.land;
			delete p['background-pattern'];
			break;
		case 'fill':
			p['fill-color'] = m[r];
			if ('fill-outline-color' in p) p['fill-outline-color'] = m[r];
			delete p['fill-pattern'];
			break;
		case 'line':
			p['line-color'] = m[r];
			delete p['line-pattern'];
			break;
		case 'symbol':
			p['text-color'] = r === 'water' ? m.waterLabel : m.label;
			p['text-halo-color'] = m.halo;
			if ('icon-color' in p) p['icon-color'] = m.label;
			break;
		case 'fill-extrusion':
			p['fill-extrusion-color'] = m.building;
			break;
		case 'circle':
			p['circle-color'] = m.road;
			break;
		case 'hillshade':
			p['hillshade-shadow-color'] = m.halo;
			p['hillshade-highlight-color'] = m.landuse;
			p['hillshade-accent-color'] = m.halo;
			break;
		}
	});
	return s;
}

function rasterStyle(theme) {
	return {
		version: 8,
		sources: { osm: JSON.parse(JSON.stringify(RASTER_SOURCE)) },
		layers: [ { id: 'osm', type: 'raster', source: 'osm', paint: theme.raster ? JSON.parse(JSON.stringify(theme.raster)) : {} } ]
	};
}

/* Sentinel-2 cloudless imagery by EOX: free for non-commercial use with attribution */
var SATELLITE_SOURCE = {
	type: 'raster',
	tiles: [ 'https://tiles.maps.eox.at/wmts/1.0.0/s2cloudless-2020_3857/default/g/{z}/{y}/{x}.jpg' ],
	tileSize: 256,
	maxzoom: 14,
	attribution: '<a href="https://cloudless.eox.at" target="_blank" rel="noopener">EOxCloudless</a> by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2020)'
};

/* sharp close-ups: Esri World Imagery has sub-metre photos where Sentinel-2 stops at 10 m */
var SATELLITE_HD_SOURCE = {
	type: 'raster',
	tiles: [ 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}' ],
	tileSize: 256,
	maxzoom: 19,
	attribution: 'Imagery &copy; <a href="https://www.esri.com" target="_blank" rel="noopener">Esri</a>, Maxar, Earthstar Geographics, and the GIS User Community'
};
var SATELLITE_HD_FROM = 10;   /* zoom where the close-up imagery takes over */

/* satellite photos, with country borders and place names from the vector style on top */
function satelliteStyle(base) {
	var s = {
		version: 8,
		sources: { satellite: JSON.parse(JSON.stringify(SATELLITE_SOURCE)),
		           'satellite-hd': JSON.parse(JSON.stringify(SATELLITE_HD_SOURCE)) },
		layers: [ { id: 'satellite', type: 'raster', source: 'satellite', maxzoom: SATELLITE_HD_FROM + 1 },
		          { id: 'satellite-hd', type: 'raster', source: 'satellite-hd', minzoom: SATELLITE_HD_FROM,
		            paint: { 'raster-opacity': [ 'interpolate', [ 'linear' ], [ 'zoom' ], SATELLITE_HD_FROM, 0, SATELLITE_HD_FROM + 1, 1 ],
		                     'raster-fade-duration': 150 } } ]
	};
	if (!base)
		return s;
	if (base.glyphs) s.glyphs = base.glyphs;   /* a key set to undefined makes MapLibre reject the whole style */
	if (base.sprite) s.sprite = base.sprite;
	Object.keys(base.sources || {}).forEach(function(k) { s.sources[k] = JSON.parse(JSON.stringify(base.sources[k])); });
	(base.layers || []).forEach(function(l) {
		var id = String(l.id).toLowerCase(), c;
		var isBorder = l.type === 'line' && /boundary|admin|border/.test(id);
		var isLabel = l.type === 'symbol' && /place|country|state|city|town|capital|continent|water_name|marine|ocean/.test(id) && !/road|highway|street|poi|transport/.test(id);
		if (!isBorder && !isLabel)
			return;
		c = JSON.parse(JSON.stringify(l));
		c.paint = c.paint || {};
		if (isBorder) {
			c.paint['line-color'] = '#ffffff';
			c.paint['line-opacity'] = 0.55;
		}
		else {
			c.paint['text-color'] = /water|marine|ocean/.test(id) ? '#cfe3ff' : '#ffffff';
			c.paint['text-halo-color'] = 'rgba(0,0,0,0.85)';
			c.paint['text-halo-width'] = 1.4;
			if (c.layout) delete c.layout['icon-image'];
		}
		s.layers.push(c);
	});
	return s;
}

var STYLE_CSS = [
	'.lf-app{background:var(--lf-bg);color:var(--lf-text);border:1px solid var(--lf-border);border-radius:10px;padding:12px;font-size:14px;line-height:1.4}',
	'.lf-app *{box-sizing:border-box}',
	'.lf-bar{display:flex;flex-wrap:wrap;gap:8px;align-items:center}',
	'.lf-spacer{flex:1}',
	'.lf-savebar{display:none;gap:6px;align-items:center}',
	'.lf-app.lf-full .lf-savebar{display:inline-flex;flex-wrap:wrap}',
	'body.lf-fullpage #modal_overlay{z-index:3000!important}',
	'body.lf-fullpage #maincontent>.alert-message,body.lf-fullpage #lf-notices{position:fixed;top:10px;left:50%;transform:translateX(-50%);z-index:3500;width:min(560px,calc(100% - 24px));margin:0}',
	'.lf-homepop .lf-homedel{margin-top:6px}',
	'.lf-app .lf-btn{background:var(--lf-btn);color:var(--lf-text);border:1px solid var(--lf-border);border-radius:6px;padding:6px 12px;font:inherit;line-height:1.2;cursor:pointer;margin:0;height:auto;min-width:0;text-shadow:none;box-shadow:none}',
	'.lf-app .lf-btn:hover:not(:disabled){border-color:var(--lf-accent);background:var(--lf-hover);color:var(--lf-text)}',
	'.lf-app .lf-btn.lf-on,.lf-app .lf-btn.lf-primary,.lf-app .lf-btn.lf-on:hover:not(:disabled),.lf-app .lf-btn.lf-primary:hover:not(:disabled){background:var(--lf-accent);color:var(--lf-accent-text);border-color:var(--lf-accent)}',
	'.lf-app .lf-btn:disabled{opacity:.45;cursor:default}',
	'.lf-app .lf-btn.lf-sm{padding:3px 8px;font-size:12px}',
	'.lf-app .lf-select,.lf-app .lf-input{background:var(--lf-btn);color:var(--lf-text);border:1px solid var(--lf-border);border-radius:6px;padding:5px 8px;font:inherit;height:auto;margin:0;width:auto;min-width:0;box-shadow:none}',
	'.lf-notice{margin:8px 0;min-height:1.3em;color:var(--lf-muted)}',
	'.lf-notice strong{color:var(--lf-text)}',
	'.lf-warn{color:#f59e0b}',
	'.lf-app .lf-link{color:var(--lf-accent);text-decoration:underline;cursor:pointer}',
	'.lf-debug-text{display:block;width:100%;box-sizing:border-box;max-height:40vh;margin:0 0 10px;font:12px/1.4 ui-monospace,Menlo,Consolas,monospace;white-space:pre;overflow:auto;resize:vertical}',
	'.lf-debug-state{margin:8px 0 6px}',
	'.lf-servers-list{max-height:45vh;overflow:auto;margin:6px 0 8px}',
	'.lf-servers-game,.lf-builtin-game{margin:0 0 6px;padding:6px 8px;border:1px solid rgba(128,128,128,.35);border-radius:6px}',
	'.lf-servers-game summary,.lf-builtin-game summary{cursor:pointer}',
	'.lf-servers-builtin{max-height:35vh;overflow:auto;margin:6px 0 8px}',
	'.lf-servers-builtin .lf-muted{opacity:.75}',
	'.lf-servers-builtin h5{margin:.2em 0}',
	'.lf-servers-table{width:100%;border-collapse:collapse;margin:6px 0 2px;font-size:12px}',
	'.lf-servers-table th,.lf-servers-table td{text-align:left;padding:2px 8px 2px 0;border-bottom:1px solid rgba(128,128,128,.2)}',
	'.lf-servers-table tr.lf-imp td{opacity:.75}',
	'.lf-mono{font-family:ui-monospace,Menlo,Consolas,monospace}',
	'.lf-servers-list .lf-muted{opacity:.75}',
	'.lf-bad{color:#ef4444}',
	'.lf-body{display:grid;grid-template-columns:minmax(0,1fr) 340px;gap:12px}',
	'@media (max-width:960px){.lf-body{grid-template-columns:minmax(0,1fr)}.lf-panel{height:auto!important}}',
	'.lf-mapwrap{position:relative;height:72vh;min-height:440px;border-radius:8px;overflow:hidden;border:1px solid var(--lf-border);background:var(--lf-panel)}',
	'.lf-panel{display:flex;flex-direction:column;height:72vh;min-height:440px;background:var(--lf-panel);border:1px solid var(--lf-border);border-radius:8px;overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain;scrollbar-width:thin;scrollbar-color:var(--lf-border) transparent}',
	'@media (max-width:700px){.lf-mapwrap{height:60vh;min-height:300px}}',
	/* stacked layout (map above, panel below): the panel is part of the page, not a box
	   that scrolls on its own - one that is even a pixel taller than its content would
	   keep the finger (overscroll contain) and the page would stop scrolling there */
	'@media (max-width:960px){.lf-app .lf-panel{overflow:visible;overflow-x:clip;overscroll-behavior:auto}.lf-app.lf-full .lf-panel{overflow-x:hidden;overflow-y:auto;overscroll-behavior:contain}}',
	/* the whole panel scrolls, so every section stays reachable however many are open */
	'.lf-panel>*{flex-shrink:0}',
	'.lf-panel::-webkit-scrollbar{width:8px}',
	'.lf-panel::-webkit-scrollbar-thumb{background:var(--lf-border);border-radius:4px}',
	'.lf-sec{padding:10px 12px;border-bottom:1px solid var(--lf-border)}',
	'.lf-sec h4{margin:0 0 6px;font-size:11px;letter-spacing:.08em;text-transform:uppercase;color:var(--lf-muted);font-weight:600;display:flex;align-items:center;gap:6px}',
	'.lf-line{display:flex;align-items:center;gap:6px;margin:3px 0;flex-wrap:wrap}',
	'.lf-dot{display:inline-block;width:9px;height:9px;border-radius:50%;flex:none}',
	'.lf-status{display:flex;align-items:flex-start;gap:6px;margin:4px 0}',
	'.lf-status .lf-dot{margin-top:.42em}',
	'.lf-status-text{flex:1;min-width:0}',
	'.lf-muted{color:var(--lf-muted)}',
	'.lf-sm{font-size:12px}',
	'.lf-circles{max-height:132px;overflow:auto}',
	'.lf-crow{display:flex;align-items:center;gap:4px;margin:4px 0}',
	'.lf-crow .lf-input{width:72px;padding:3px 5px;font-size:12px}',
	'.lf-crow .lf-num{min-width:24px;cursor:pointer;color:var(--lf-muted)}',
	'.lf-crow .lf-num:hover{color:var(--lf-text)}',
	'.lf-app .lf-tabs{display:flex;border-bottom:1px solid var(--lf-border)}',
	'.lf-app .lf-tab{flex:1;background:none;border:0;border-bottom:2px solid transparent;color:var(--lf-muted);padding:8px 4px;font:inherit;font-size:13px;cursor:pointer;display:flex;gap:5px;align-items:center;justify-content:center;margin:0}',
	'.lf-app .lf-tab.lf-on{color:var(--lf-text);border-bottom-color:var(--lf-accent)}',
	'.lf-search{padding:8px 12px;border-bottom:1px solid var(--lf-border)}',
	'.lf-search{display:flex;flex-wrap:wrap;gap:6px}',
	'.lf-search .lf-input{flex:1 1 120px;min-width:0;width:auto}',
	'.lf-search .lf-select,.lf-search .lf-btn{flex:none}',
	'.lf-app .lf-search .lf-select{font-size:12px;padding:4px 6px}',
	'.lf-list{flex:1 0 auto;min-height:160px}',
	'.lf-row{display:flex;gap:8px;align-items:flex-start;padding:7px 12px;border-bottom:1px solid var(--lf-border);cursor:pointer}',
	'.lf-row:hover{background:var(--lf-hover)}',
	'.lf-row .lf-dot{margin-top:5px}',
	'.lf-row-main{flex:1;min-width:0}',
	'.lf-ip{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;word-break:break-all}',
	'.lf-empty{padding:16px 12px;color:var(--lf-muted)}',
	'.lf-overlay{position:absolute;inset:0;display:none;align-items:center;justify-content:center;background:rgba(0,0,0,.35);z-index:5;padding:16px}',
	'.lf-card{max-width:420px;background:var(--lf-panel);color:var(--lf-text);border:1px solid var(--lf-border);padding:20px;border-radius:10px;box-shadow:0 8px 32px rgba(0,0,0,.35)}',
	'.lf-card h3{margin:0 0 8px;color:var(--lf-text)}',
	'.lf-message{position:absolute;inset:0;display:flex;align-items:center;justify-content:center;padding:16px;text-align:center;color:var(--lf-muted)}',
	'.lf-app .maplibregl-popup-content{background:var(--lf-panel);color:var(--lf-text);border:1px solid var(--lf-border);font-size:12.5px;padding:10px 26px 10px 12px}',
	'.lf-app .maplibregl-popup-close-button{color:var(--lf-muted)}',
	'.lf-app .maplibregl-popup-anchor-bottom .maplibregl-popup-tip,.lf-app .maplibregl-popup-anchor-bottom-left .maplibregl-popup-tip,.lf-app .maplibregl-popup-anchor-bottom-right .maplibregl-popup-tip{border-top-color:var(--lf-panel)}',
	'.lf-app .maplibregl-popup-anchor-top .maplibregl-popup-tip,.lf-app .maplibregl-popup-anchor-top-left .maplibregl-popup-tip,.lf-app .maplibregl-popup-anchor-top-right .maplibregl-popup-tip{border-bottom-color:var(--lf-panel)}',
	'.lf-app .maplibregl-popup-anchor-left .maplibregl-popup-tip{border-right-color:var(--lf-panel)}',
	'.lf-app .maplibregl-popup-anchor-right .maplibregl-popup-tip{border-left-color:var(--lf-panel)}',
	'.lf-dark .maplibregl-ctrl-group{background:var(--lf-btn);box-shadow:0 0 0 1px var(--lf-border)}',
	'.lf-dark .maplibregl-ctrl-group button+button{border-top-color:var(--lf-border)}',
	'.lf-dark .maplibregl-ctrl button .maplibregl-ctrl-icon{filter:invert(1)}',
	'.lf-dark .maplibregl-ctrl-attrib{background:rgba(0,0,0,.55);color:var(--lf-muted)}',
	'.lf-dark .maplibregl-ctrl-attrib a{color:var(--lf-muted)}',
	'.lf-dark .maplibregl-ctrl-attrib-button{filter:invert(1)}',
	'.lf-fx{position:absolute;inset:0;z-index:1;pointer-events:none;overflow:hidden}',
	'.lf-fx-stars{position:absolute;inset:0;background-size:512px 512px;mix-blend-mode:screen;opacity:.75}',
	'.lf-fx-far{animation:lf-stars-a 140s linear infinite,lf-twinkle 7s ease-in-out infinite alternate}',
	'.lf-fx-near{animation:lf-stars-b 70s linear infinite,lf-twinkle 2.6s ease-in-out infinite alternate}',
	'@keyframes lf-stars-a{from{background-position:0 0}to{background-position:-512px 256px}}',
	'@keyframes lf-stars-b{from{background-position:0 0}to{background-position:-768px 384px}}',
	'@keyframes lf-twinkle{from{opacity:.25}to{opacity:1}}',
	'.lf-shoot{position:absolute;width:130px;height:2px;border-radius:2px;opacity:0;background:linear-gradient(90deg,rgba(255,255,255,0),#fff);box-shadow:0 0 6px #c7d2fe;transform:rotate(-28deg);animation:lf-shoot linear infinite}',
	'@keyframes lf-shoot{0%{opacity:0;transform:rotate(-28deg) translateX(0)}2%{opacity:1}9%{opacity:0;transform:rotate(-28deg) translateX(-340px)}100%{opacity:0;transform:rotate(-28deg) translateX(-340px)}}',
	'.lf-fx-nebula2{animation:lf-drift2 24s ease-in-out infinite alternate,lf-hue 30s linear infinite;opacity:.4}',
	'@keyframes lf-drift2{from{transform:translate(4%,-3%) rotate(0)}to{transform:translate(-4%,3%) rotate(8deg)}}',
	'@keyframes lf-hue{from{filter:hue-rotate(0)}to{filter:hue-rotate(360deg)}}',
	'.lf-fx-nebula{position:absolute;inset:-10%;mix-blend-mode:screen;opacity:.55;animation:lf-drift 18s ease-in-out infinite alternate;background:' +
		'radial-gradient(ellipse 40% 30% at 20% 30%,rgba(139,92,246,.45),transparent 70%),' +
		'radial-gradient(ellipse 35% 25% at 75% 65%,rgba(236,72,153,.30),transparent 70%),' +
		'radial-gradient(ellipse 30% 40% at 60% 20%,rgba(56,189,248,.25),transparent 70%)}',
	'@keyframes lf-drift{from{transform:translate(0,0) scale(1)}to{transform:translate(-5%,3%) scale(1.15)}}',
	'@media (prefers-reduced-motion:reduce){.lf-fx *{animation:none!important}}',
	'.lf-mapwrap .maplibregl-popup,.lf-mapwrap .maplibregl-marker{z-index:3}',
	'.lf-welcome{max-width:640px;max-height:calc(100% - 24px);overflow:auto}',
	'.lf-welcome h3{margin:0 0 6px}',
	'.lf-welcome p{margin:0 0 10px}',
	'.lf-wcols{display:grid;grid-template-columns:1fr 1fr;gap:16px;margin:4px 0 10px}',
	'@media (max-width:700px){.lf-wcols{grid-template-columns:1fr}}',
	'.lf-welcome h4{margin:0 0 6px;font-size:14px}',
	'.lf-wcan{color:#22c55e}',
	'.lf-wcant{color:#ef4444}',
	'.lf-wlist{list-style:none;margin:0;padding:0;font-size:13px;line-height:1.4}',
	'.lf-wlist li{display:flex;gap:8px;margin:0 0 6px}',
	'.lf-wmark{flex:none;font-weight:bold;width:14px;text-align:center}',
	'.lf-wyes .lf-wmark{color:#22c55e}',
	'.lf-wno .lf-wmark{color:#ef4444}',
	'.lf-wsteps{font-size:13px;color:var(--lf-muted)}',
	'.lf-credit{margin-top:12px;font-size:12px;color:var(--lf-muted);text-align:right;font-style:italic;letter-spacing:.02em}',
	'.lf-wfoot{display:flex;flex-wrap:wrap;justify-content:space-between;align-items:baseline;gap:4px 12px;margin-top:12px}',
	'.lf-wfoot .lf-credit{margin-top:0}',
	'.lf-version{font-size:12px;color:var(--lf-muted)}',
	'.lf-version a{color:inherit;text-decoration:underline}',
	'.lf-version .lf-newer{color:var(--lf-accent);font-weight:600}',
	'.lf-laghead{display:flex;align-items:center;gap:6px;margin-bottom:4px}',
	'.lf-laghead h4{margin:0!important}',
	'.lf-app .lf-laghead .lf-btn{padding:0 7px;line-height:18px;border-radius:50%}',
	'.lf-switch{display:inline-flex;align-items:center;gap:5px;font-size:12px;cursor:pointer;margin:0}',
	'.lf-switch input{margin:0}',
	'.lf-lagrow{display:flex;justify-content:space-between;align-items:center;gap:8px;font-size:12.5px;margin:3px 0}',
	'.lf-lagin{white-space:nowrap;color:var(--lf-muted)}',
	'.lf-laghelp{font-size:12.5px;margin:2px 0 8px;padding:8px 10px;border:1px solid var(--lf-border);border-radius:6px;background:var(--lf-bg)}',
	'.lf-laghelp p{margin:0 0 6px}',
	'.lf-laghelp h4{margin:6px 0 4px!important;font-size:12.5px;text-transform:none;letter-spacing:0}',
	'.lf-laghelp .lf-wlist{font-size:12px}',
	'.lf-app .lf-laghelp h4.lf-wcan{color:#22c55e}',
	'.lf-app .lf-laghelp h4.lf-wcant{color:#ef4444}',
	'.lf-cmd{display:block;margin-top:4px;padding:4px 6px;border-radius:4px;background:var(--lf-bg);border:1px solid var(--lf-border);font-size:11px;word-break:break-all;user-select:all}',
	'.lf-menuwrap{position:relative;display:inline-block}',
	'.lf-menu{position:absolute;top:calc(100% + 4px);left:0;z-index:30;min-width:210px;background:var(--lf-panel);color:var(--lf-text);border:1px solid var(--lf-border);border-radius:8px;padding:6px;box-shadow:0 8px 24px rgba(0,0,0,.35)}',
	'.lf-mitem{display:flex;align-items:center;gap:8px;padding:6px 8px;border-radius:5px;cursor:pointer;white-space:nowrap;margin:0}',
	'.lf-mitem:hover{background:var(--lf-hover)}',
	'.lf-mitem input{margin:0}',
	'.lf-app.lf-full.lf-borderless{padding:0}',
	'.lf-app.lf-full.lf-borderless .lf-bar{padding:6px 8px}',
	'.lf-app.lf-full.lf-borderless .lf-notice:empty{display:none}',
	'.lf-app.lf-full.lf-borderless .lf-body{gap:0}',
	'.lf-app.lf-full.lf-borderless .lf-mapwrap,.lf-app.lf-borderless .lf-panel{border-radius:0;border-width:1px 0 0 0}',
	'.lf-app.lf-full{position:fixed;inset:0;z-index:2000;border-radius:0;border:0;display:flex;flex-direction:column;padding:10px;overflow:hidden;margin:0}',
	'.lf-app:fullscreen{width:100%;height:100%}',
	'.lf-app.lf-full .lf-body{flex:1;min-height:0;grid-template-rows:minmax(0,1fr)}',
	'.lf-app.lf-full .lf-mapwrap,.lf-app.lf-full .lf-panel{height:auto!important;min-height:0}',
	'@media (max-width:960px){.lf-app.lf-full .lf-body{grid-template-rows:minmax(0,1fr) auto}.lf-app.lf-full .lf-panel{max-height:38vh}}',
	'.lf-app.lf-nopanel .lf-body{grid-template-columns:minmax(0,1fr)}',
	'.lf-app.lf-nopanel .lf-panel{display:none}',
	'.lf-seg{display:inline-flex;border:1px solid var(--lf-border);border-radius:6px;overflow:hidden}',
	'.lf-app .lf-seg .lf-btn{border:0;border-radius:0;border-right:1px solid var(--lf-border)}',
	'.lf-app .lf-seg .lf-btn:last-child{border-right:0}',
	'.lf-pop-ips{margin-top:4px}',
	'.lf-pop-rule{margin-top:6px;color:var(--lf-muted)}',
	'.lf-pop-actions{display:flex;gap:6px;flex-wrap:wrap;margin-top:8px}',
	'.lf-badge{display:inline-block;font-size:11px;padding:0 5px;border-radius:4px;border:1px solid var(--lf-border);color:var(--lf-muted);margin-left:4px}',
	'.lf-house-ico{display:inline-block;width:14px;height:14px;margin-right:5px;vertical-align:-2px;line-height:0}',
	'.lf-prompt{position:absolute;left:50%;bottom:28px;transform:translateX(-50%);z-index:6;display:flex;gap:8px;align-items:center;flex-wrap:wrap;justify-content:center;max-width:calc(100% - 24px);background:var(--lf-panel);color:var(--lf-text);border:1px solid var(--lf-border);border-radius:8px;padding:8px 12px;box-shadow:0 6px 24px rgba(0,0,0,.35);font-size:13px}',
	'.lf-crow.lf-sel{background:var(--lf-hover);box-shadow:inset 3px 0 0 #3b82f6;border-radius:4px}',
	'.lf-crow{cursor:pointer;padding:1px 2px}',
	/* shape handles: the dot you see, inside a target big enough for a finger on touch screens */
	'.lf-handle{display:flex;align-items:center;justify-content:center;touch-action:none;-webkit-touch-callout:none;-webkit-user-select:none;user-select:none;-webkit-tap-highlight-color:transparent}',
	'.lf-hdot{flex:none;box-shadow:0 0 3px rgba(0,0,0,.6);pointer-events:none}',
	'.lf-h-vertex .lf-hdot{width:11px;height:11px;border-radius:2px}',
	'.lf-h-centre .lf-hdot{width:16px;height:16px;border-radius:50%}',
	'.lf-h-edge .lf-hdot{width:12px;height:12px;border-radius:50%}',
	'@media (pointer: coarse){.lf-handle{width:44px;height:44px}.lf-h-vertex .lf-hdot{width:16px;height:16px;border-radius:3px}.lf-h-centre .lf-hdot{width:22px;height:22px}.lf-h-edge .lf-hdot{width:18px;height:18px}}',
	'.lf-handle.lf-pressing .lf-hdot{transform:scale(1.35);transition:transform .45s}'
].join('\n');

function injectCss() {
	if (document.getElementById('lobbyfence-css'))
		return;
	var el = document.createElement('style');
	el.id = 'lobbyfence-css';
	el.textContent = STYLE_CSS;
	document.head.appendChild(el);
}

/* ------------------------------------------------------------- geometry */

function toRad(d) { return d * Math.PI / 180; }
function toDeg(r) { return r * 180 / Math.PI; }
function wrapLon(lon) { return ((lon + 540) % 360) - 180; }

function distanceKm(lat1, lon1, lat2, lon2) {
	var dla = toRad(lat2 - lat1), dlo = toRad(lon2 - lon1);
	var a = Math.sin(dla / 2) * Math.sin(dla / 2) +
		Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dlo / 2) * Math.sin(dlo / 2);
	return EARTH_KM * 2 * Math.atan2(Math.sqrt(Math.min(1, a)), Math.sqrt(Math.max(0, 1 - a)));
}

/* [lon, lat] reached from lat/lon after `km` on `bearing` degrees;
 * the longitude is left unwrapped (relative to `lon`) */
function destination(lat, lon, km, bearing) {
	var d = km / EARTH_KM, p1 = toRad(lat), b = toRad(bearing);
	var p2 = Math.asin(Math.sin(p1) * Math.cos(d) + Math.cos(p1) * Math.sin(d) * Math.cos(b));
	var dl = Math.atan2(Math.sin(b) * Math.sin(d) * Math.cos(p1), Math.cos(d) - Math.sin(p1) * Math.sin(p2));
	return [ lon + toDeg(dl), toDeg(p2) ];
}

/* GeoJSON ring approximating a geodesic circle, valid across the
 * antimeridian and around the poles */
function circleRing(c, steps) {
	var n = steps || 96, ring = [], i, p, prev = null;
	var north = distanceKm(c.lat, c.lon, 90, 0) < c.r;
	var south = distanceKm(c.lat, c.lon, -90, 0) < c.r;

	if (north && south)
		return [ [ -180, -POLE_LAT ], [ 180, -POLE_LAT ], [ 180, POLE_LAT ], [ -180, POLE_LAT ], [ -180, -POLE_LAT ] ];

	for (i = 0; i <= n; i++) {
		p = destination(c.lat, c.lon, c.r, i * 360 / n);
		if (prev !== null) {
			while (p[0] - prev > 180) p[0] -= 360;
			while (p[0] - prev < -180) p[0] += 360;
		}
		prev = p[0];
		ring.push(p);
	}

	if (north || south) {
		/* the ring winds once around the pole, so its last point sits 360
		 * degrees from the first: close it along the pole's edge */
		var lat = north ? POLE_LAT : -POLE_LAT;
		ring.push([ ring[ring.length - 1][0], lat ], [ ring[0][0], lat ], ring[0].slice());
	}
	else {
		ring[ring.length - 1] = ring[0].slice();
	}
	return ring;
}

function ringBounds(ring) {
	var b = [ [ Infinity, Infinity ], [ -Infinity, -Infinity ] ];
	ring.forEach(function(p) {
		b[0][0] = Math.min(b[0][0], p[0]); b[0][1] = Math.min(b[0][1], p[1]);
		b[1][0] = Math.max(b[1][0], p[0]); b[1][1] = Math.max(b[1][1], p[1]);
	});
	return b;
}

/* --------------------------------------------------------------- parsing */

function parseCircles(list) {
	var out = [];
	L.toArray(list).forEach(function(item) {
		var p = String(item).split(',');
		if (p.length !== 3)
			return;
		var lat = +p[0], lon = +p[1], r = +p[2];
		if (isFinite(lat) && isFinite(lon) && isFinite(r) && r > 0 &&
		    lat >= -90 && lat <= 90 && lon >= -180 && lon <= 180)
			out.push({ lat: lat, lon: lon, r: r });
	});
	return out;
}

function formatCircle(c) {
	return [ c.lat.toFixed(4), wrapLon(c.lon).toFixed(4), Math.max(1, Math.round(c.r)) ].join(',');
}

/* "<ip> <state> <lat|-> <lon|-> <cc|--> <lastseen>" per line, as written by the router */
function parseServers(text) {
	var rows = [];
	String(text || '').split(/\n/).forEach(function(line) {
		var f = line.trim().split(/\s+/);
		if (f.length < 5 || !/^[0-9a-fA-F:.]+$/.test(f[0]))
			return;
		var located = f[2] !== '-' && f[3] !== '-';
		var lat = located ? +f[2] : null, lon = located ? +f[3] : null;
		if (located && (!isFinite(lat) || !isFinite(lon)))
			return;
		rows.push({
			ip: f[0], state: f[1], lat: lat, lon: lon,
			cc: /^[A-Z]{2}$/.test(f[4]) ? f[4] : '',
			ts: +f[5] || 0
		});
	});
	return rows;
}

/* ------------------------------------------------------------ formatting */

function flag(cc) {
	if (!/^[A-Z]{2}$/.test(cc || ''))
		return '';
	return String.fromCodePoint(127462 + cc.charCodeAt(0) - 65, 127462 + cc.charCodeAt(1) - 65);
}

function ago(ts, now) {
	var s = Math.floor((now || Date.now() / 1000) - ts);
	if (!ts || ts <= 0) return _('never');
	if (s < 60) return _('just now');
	if (s < 3600) return _('%d min ago').format(Math.floor(s / 60));
	if (s < 172800) return _('%d h ago').format(Math.floor(s / 3600));
	return _('%d days ago').format(Math.floor(s / 86400));
}

function fmtNum(n) {
	return (+n || 0).toLocaleString();
}

function dot(colour) {
	return E('span', { 'class': 'lf-dot', 'style': 'background:' + colour });
}

/* ---------------------------------------------------------- presets */

/*
 * Ports per game, as published by the developer ("official") or as reported
 * by players ("community"). remote = the game server's port; either = the
 * port on either side (consoles that always play from the same port).
 */
var PRESET_GROUPS = [
	[ 'any', _('Any game') ],
	[ 'pc', _('PC & console') ],
	[ 'mobile', _('Mobile') ]
];
var EPIC_PORTS = [ '3478-3479', '5060', '5062', '6250', '12000-65000' ];
/* the device a PC & console game runs on - some games use other ports on each */
var PLATFORMS = [ [ 'pc', _('PC') ], [ 'ps', _('PlayStation') ], [ 'xbox', _('Xbox') ] ];
/* mobile games find their match over TCP: 443 (HTTPS, used by most of them)
 * plus the TCP ports the big mobile games are known to use - Call of Duty:
 * Mobile (Activision: 443, 65010 lobby, 65050 chat; players: 3013, 18082),
 * PUBG Mobile (10012, 17500), Free Fire (39003, 39698, 39779), Mobile Legends
 * (5001, 5003, 9001, 30000-30999), Arena of Valor (10001-10094), Clash games
 * (9330-9340), Dragon Nest (10514) */
var MOBILE_TCP_PORTS = [ '443', '3013', '5001', '5003', '9001', '9330-9340', '10001-10094', '10514', '17500', '18082',
	'30000-30999', '39003', '39698', '39779', '65010', '65050' ];
var PRESETS = [
	{ id: 'any_udp', group: 'any', label: _('Any game (all UDP traffic)'), name: _('Any game'), proto: 'udp', remote: [ '1024-65535' ],
	  note: _('Works for every game, including ones not listed. Voice and video calls from this device are checked as well, so start in Monitor mode.') },

	{ id: 'any_mobile', group: 'any', label: _('Any mobile game (TCP 443 + mobile game ports)'), name: _('Mobile games'), proto: 'tcp',
	  remote: MOBILE_TCP_PORTS, mode: 'enforce', burst: 0,
	  note: _('For a phone or tablet: mobile games pick their servers over TCP, mostly port 443. Apps and websites on this device use TCP 443 too, so the ones whose servers are outside the region won\'t load while the zone filters - start in Monitor mode, use Always allow for what you need, or switch the zone off when you are not playing. Starts in Enforce (not Strict), so a new server works until it has been located.') },

	{ id: 'custom', group: 'any', label: _('Custom (your own ports)'), name: '', proto: 'udp', remote: [], custom: true,
	  note: _('Enter the game\'s server ports yourself and give the zone a name.') },

	{ id: 'cod', group: 'pc', label: 'Call of Duty (Black Ops 7/6, Warzone, MW III)', proto: 'udp', either: [ '3074-3079' ], source: 'Activision', official: true, burst: 0 },
	{ id: 'valorant', group: 'pc', label: 'VALORANT', proto: 'udp', remote: [ '7000-8000', '8180-8181' ], source: 'Riot Games', official: true },
	{ id: 'lol', group: 'pc', label: 'League of Legends', proto: 'udp', remote: [ '5000-5500' ], source: 'Riot Games', official: true },
	{ id: 'apex', group: 'pc', label: 'Apex Legends', proto: 'udp', remote: [ '1024-65535' ], source: _('players\' routers'), wide: true, burst: 2,
	  platforms: {
		pc: [ '7700-7799', '8100-8199', '9000-9099', '10000-10599', '10700-10899', '15000-15099', '22200-22299', '27000-27199', '49000-49099' ],
		ps: [ '1000-1099', '1900-1999', '3000-3199', '7700-7799', '8100-8199', '10000-10999', '27000-27199', '27500-27599', '34100-34199' ]
	  },
	  note: _('PC and PlayStation: the ports players\' routers saw in matches. Xbox (not measured yet): every UDP port - narrow it with Ports… after a few matches.') },
	{ id: 'fortnite', group: 'pc', label: 'Fortnite', proto: 'udp', remote: EPIC_PORTS, source: 'Epic Games', official: true, wide: true, burst: 2,
	  platforms: {
		pc: [ '9000-9199', '10500-10599', '15000-15199', '22200-22299', '30300-30399', '32900-32999', '35000-35099', '36800-36899', '39200-39299', '45100-45199' ],
		ps: [ '9000-9199', '10100-10199', '15000-15199', '22200-22299', '36300-36399', '37500-37599', '39900-39999', '41700-41799', '42100-42199', '48200-48299', '51100-51199', '53700-53799', '56100-56199' ]
	  } },
	{ id: 'overwatch', group: 'pc', label: 'Overwatch 2', proto: 'udp', remote: [ '3478-3479', '5060', '5062', '6250', '12000-64000' ], source: 'Blizzard', official: true, wide: true },
	{ id: 'rocketleague', group: 'pc', label: 'Rocket League', proto: 'udp', remote: [ '7000-9000' ], source: 'Psyonix', official: true },
	{ id: 'valve', group: 'pc', label: 'Counter-Strike 2 / Dota 2', proto: 'udp', remote: [ '27000-27100' ], source: _('Steam players') },

	{ id: 'codm', group: 'mobile', label: 'Call of Duty: Mobile', proto: 'udp', remote: [ '7500-8000' ], source: 'Activision', official: true, burst: 0 },
	{ id: 'fortnite_m', group: 'mobile', label: 'Fortnite (mobile)', proto: 'udp', remote: EPIC_PORTS, source: 'Epic Games', official: true, wide: true, burst: 2 },
	{ id: 'pubgm', group: 'mobile', label: 'PUBG Mobile', proto: 'udp', remote: [ '10010-20002' ], source: _('players') },
	{ id: 'freefire', group: 'mobile', label: 'Free Fire', proto: 'udp', remote: [ '10001-10012' ], source: _('players') },
	{ id: 'mlbb', group: 'mobile', label: 'Mobile Legends: Bang Bang', proto: 'both', remote: [ '5001', '5003', '9001', '30000-30999' ], source: _('players') },
	{ id: 'aov', group: 'mobile', label: 'Arena of Valor', proto: 'both', remote: [ '10001-10094', '17000' ], source: _('players') },
	{ id: 'supercell', group: 'mobile', label: 'Clash Royale / Clash of Clans', proto: 'both', remote: [ '9330-9340' ], source: _('players') }
];
var DEFAULT_PRESET = 'any_udp';

/* "Open for server tests" advice for a game: games like Apex Legends check many
 * data centres before a match and need 2 or more; Call of Duty must stay at 0 */
function burstAdvice(p) {
	if (p && p.burst > 0)
		return _('Recommended for %s: %d or more.').format(p.name || p.label, p.burst);
	if (p && p.burst === 0)
		return _('Recommended for %s: 0 (off) - do not raise it.').format(p.name || p.label);
	return _('Varies by game: Apex Legends and Fortnite need 2 or more, Call of Duty should stay at 0 (off). Other games: start at 0 and raise it only if logging in or finding matches fails while filtering.');
}

function presetById(id) {
	return PRESETS.filter(function(p) { return p.id === id; })[0] || null;
}

/* PC & console games are picked together with the device they run on */
function needsPlatform(p) {
	return !!(p && p.group === 'pc');
}

function platformName(id) {
	var f = PLATFORMS.filter(function(x) { return x[0] === id; })[0];
	return f ? f[1] : '';
}

/* the preset as it is on one platform: its own ports there, when the game has them */
function presetOn(p, platform) {
	if (!p || !p.platforms || !p.platforms[platform])
		return p;
	var q = {};
	Object.keys(p).forEach(function(k) { q[k] = p[k]; });
	q.remote = p.platforms[platform];
	q.either = null;
	q.wide = false;
	q.official = false;
	q.source = _('players\' routers on %s').format(platformName(platform));
	q.note = '';
	return q;
}

function platformSelect(cls) {
	return E('select', { 'class': 'cbi-input-select ' + cls, 'style': 'width:100%' },
		[ E('option', { 'value': '' }, _('Choose the device type…')) ].concat(PLATFORMS.map(function(x) {
			return E('option', { 'value': x[0] }, x[1]);
		})));
}

function presetSummary(p) {
	var ports = (p.remote || p.either || []).join(', ');
	var proto = p.proto === 'both' ? 'UDP/TCP' : p.proto.toUpperCase();
	if (p.custom)
		return p.note;
	var where = p.either ? _('on either side') : _('server side');
	var src = p.source ? (p.official ? _('published by %s').format(p.source) : _('reported by %s - may be incomplete').format(p.source)) : '';
	return [ proto + ' ' + ports + ' (' + where + ')', src, p.wide ? _('wide port range') : '', p.note || '' ]
		.filter(function(x) { return x; }).join(' · ');
}

/* ---------------------------------------------------- zone creation */

function isMac(s) {
	return /^[0-9a-f]{2}([:-][0-9a-f]{2}){5}$/i.test(String(s || '').trim());
}

function validDevice(s) {
	return isMac(s) || validAddress(s);
}

function validAddress(s) {
	var m = String(s || '').trim().match(/^([^/]+)(?:\/(\d{1,3}))?$/);
	if (!m)
		return false;
	var a = m[1], pre = m[2] != null ? +m[2] : null;
	var v4 = a.split('.');
	if (v4.length === 4 && v4.every(function(o) { return /^\d{1,3}$/.test(o) && +o <= 255; }))
		return pre === null || pre <= 32;
	if (validV6(a))
		return pre === null || pre <= 128;
	return false;
}

/* IPv6: 8 groups of 1-4 hex digits, "::" at most once, optional IPv4 tail */
function validV6(a) {
	if (!/^[0-9a-fA-F:.]+$/.test(a) || a.indexOf(':') < 0 || a.length > 45)
		return false;
	var dbl = (a.match(/::/g) || []).length;
	if (dbl > 1 || /:::/.test(a))
		return false;
	var parts = a.split(':'), groups = 0, ok = true;
	parts.forEach(function(p, i) {
		if (p === '')
			return;
		if (i === parts.length - 1 && p.indexOf('.') >= 0) {
			var o = p.split('.');
			ok = ok && o.length === 4 && o.every(function(x) { return /^\d{1,3}$/.test(x) && +x <= 255; });
			groups += 2;
		}
		else {
			ok = ok && /^[0-9a-fA-F]{1,4}$/.test(p);
			groups++;
		}
	});
	if (!dbl && (/^:/.test(a) || /:$/.test(a)))
		return false;
	return ok && (dbl ? groups < 8 : groups === 8);
}

function parsePorts(s) {
	var out = [], bad = false;
	String(s || '').split(/[\s,;]+/).forEach(function(t) {
		if (!t)
			return;
		var m = t.match(/^(\d{1,5})(?:-(\d{1,5}))?$/);
		var a = m ? +m[1] : 0, b = m ? (m[2] != null ? +m[2] : a) : 0;
		if (!m || a < 1 || b > 65535 || b < a)
			bad = true;
		else
			out.push(t);
	});
	return bad ? null : out;
}

/* a zone's port list (a list option, or one string) -> [ [low, high], ... ]; bad entries left out */
function portRanges(v) {
	return [].concat(v || []).join(' ').split(/[\s,;]+/).map(function(t) {
		var m = t.match(/^(\d{1,5})(?:-(\d{1,5}))?$/), a = m ? +m[1] : 0, b = m ? (m[2] != null ? +m[2] : a) : 0;
		return (m && a >= 1 && b <= 65535 && a <= b) ? [ a, b ] : null;
	}).filter(Boolean);
}

function inRanges(port, ranges) {
	return ranges.some(function(r) { return port >= r[0] && port <= r[1]; });
}

/* how many ports the ranges cover (overlaps counted once) */
function rangesSize(ranges) {
	var n = 0, end = 0;
	ranges.slice().sort(function(a, b) { return a[0] - b[0]; }).forEach(function(r) {
		var lo = Math.max(r[0], end + 1);
		if (r[1] >= lo) {
			n += r[1] - lo + 1;
			end = r[1];
		}
	});
	return n;
}

function sectionName(label, existing) {
	var base = String(label || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, ZONE_ID_MAX);
	if (!/^[a-z]/.test(base))
		base = ('zone' + (base ? '_' + base : '')).slice(0, ZONE_ID_MAX).replace(/_+$/, '');
	var name = base, i = 2;
	while (existing.indexOf(name) >= 0)
		name = base + '_' + (i++);
	return name;
}

/* stage a new zone (and switch LobbyFence on) in the uci changeset */
function createZone(uciApi, v) {
	var existing = uciApi.sections('lobbyfence').map(function(s) { return s['.name']; });
	var name = sectionName(v.label, existing);

	uciApi.add('lobbyfence', 'zone', name);
	uciApi.set('lobbyfence', name, 'enabled', '1');
	uciApi.set('lobbyfence', name, 'label', v.label || name);
	uciApi.set('lobbyfence', name, 'mode', v.mode || 'enforce');
	uciApi.set('lobbyfence', name, 'strict', v.strict == null ? '1' : (v.strict ? '1' : '0'));
	uciApi.set('lobbyfence', name, 'device', [ isMac(v.device) ? v.device.trim().toLowerCase().replace(/-/g, ':') : v.device.trim() ]);
	uciApi.set('lobbyfence', name, 'proto', v.proto || 'udp');
	if (v.remotePorts && v.remotePorts.length)
		uciApi.set('lobbyfence', name, 'remote_port', v.remotePorts);
	if (v.eitherPorts && v.eitherPorts.length)
		uciApi.set('lobbyfence', name, 'port', v.eitherPorts);
	if (v.localPorts && v.localPorts.length)
		uciApi.set('lobbyfence', name, 'local_port', v.localPorts);
	uciApi.set('lobbyfence', name, 'expire_days', '30');
	if (v.game)
		uciApi.set('lobbyfence', name, 'game', v.game);
	if (v.platform)
		uciApi.set('lobbyfence', name, 'platform', v.platform);
	if (v.burst != null) {
		uciApi.set('lobbyfence', name, 'burst_servers', String(v.burst));
		uciApi.set('lobbyfence', name, 'burst_open', String(v.burstOpen || 20));
	}

	if (!uciApi.get('lobbyfence', 'globals'))
		uciApi.add('lobbyfence', 'globals', 'globals');
	uciApi.set('lobbyfence', 'globals', 'enabled', '1');
	return name;
}

/* ------------------------------------------------------------ polygons */

/* Web-Mercator y; the router uses the same formula (lobbyfence.awk) */
function mercY(lat) {
	var la = toRad(Math.max(-85.05, Math.min(85.05, lat)));
	return Math.log((1 + Math.sin(la)) / Math.cos(la));
}

/* keep longitudes continuous so a polygon may cross the antimeridian */
function normalizePolygon(pts) {
	var out = [], prev = null;
	pts.forEach(function(p) {
		var lon = prev === null ? wrapLon(p[0]) : p[0];
		if (prev !== null) {
			while (lon - prev > 180) lon -= 360;
			while (lon - prev < -180) lon += 360;
		}
		prev = lon;
		out.push([ lon, Math.max(-85, Math.min(85, p[1])) ]);
	});
	return out;
}

/* pts: [[lon, lat], ...]; even-odd test on the Mercator plane, any 360° copy */
function inPolygon(pts, lat, lon) {
	var y = mercY(lat), n = pts.length, c, i, j, x, inside;
	for (c = -1; c <= 1; c++) {
		x = lon + 360 * c;
		inside = false;
		for (i = 0, j = n - 1; i < n; j = i++) {
			var yi = mercY(pts[i][1]), yj = mercY(pts[j][1]);
			if ((yi > y) !== (yj > y) && x < (pts[j][0] - pts[i][0]) * (y - yi) / (yj - yi) + pts[i][0])
				inside = !inside;
		}
		if (inside)
			return true;
	}
	return false;
}

/* ------------------------------------------------- straight edges */

function mercDeg(lat) { return toDeg(mercY(lat)); }
function invMercDeg(y) { return toDeg(2 * Math.atan(Math.exp(toRad(y))) - Math.PI / 2); }

/* 'h' = along a parallel, 'v' = along a meridian, '' = diagonal - as seen on the map */
function edgeKind(a, b, tol) {
	var dx = b[0] - a[0], dy = mercDeg(b[1]) - mercDeg(a[1]), ang;
	if (!dx && !dy)
		return '';
	ang = toDeg(Math.atan2(Math.abs(dy), Math.abs(dx)));
	return ang <= tol ? 'h' : ang >= 90 - tol ? 'v' : '';
}

function samePoint(a, b) {
	return !!a && Math.abs(a[0] - b[0]) < 1e-9 && Math.abs(a[1] - b[1]) < 1e-9;
}

/* exactly straight already? */
function alignedKind(a, b) {
	if (Math.abs(a[1] - b[1]) < 1e-7) return 'h';
	if (Math.abs(a[0] - b[0]) < 1e-7) return 'v';
	return '';
}

function mercArea(pts) {
	var a = 0, n = pts.length, i, j;
	for (i = 0, j = n - 1; i < n; j = i++)
		a += (pts[j][0] + pts[i][0]) * (mercDeg(pts[j][1]) - mercDeg(pts[i][1]));
	return Math.abs(a / 2);
}

/* Align: make EVERY edge straight - each one becomes horizontal or vertical,
 * whichever it is closer to (corners joined by such an edge share one latitude /
 * longitude, the average). A hand-drawn four-corner shape becomes an exact
 * rectangle; an L or a U keeps its outline with square corners. If snapping
 * every edge would fold or flatten the shape (a triangle, a diamond ...), the
 * result is the rectangle around it instead. */
function straightenPolygon(pts, tol) {
	var n = pts.length, px = [], py = [], i, j, k, sx = {}, sy = {}, cx = {}, cy = {}, out, t = tol == null ? 45 : tol;
	if (pts.every(function(p, i) { return alignedKind(p, pts[(i + 1) % n]); }))
		return pts.map(function(p) { return p.slice(); });   /* already straight */
	function find(a, i) { while (a[i] !== i) i = a[i] = a[a[i]]; return i; }
	function union(a, i, j) { a[find(a, i)] = find(a, j); }

	for (i = 0; i < n; i++) { px.push(i); py.push(i); }
	for (i = 0; i < n; i++) {
		j = (i + 1) % n;
		k = edgeKind(pts[i], pts[j], t);
		if (k === 'h') union(py, i, j);
		else if (k === 'v') union(px, i, j);
	}
	for (i = 0; i < n; i++) {
		var gx = find(px, i), gy = find(py, i);
		sx[gx] = (sx[gx] || 0) + pts[i][0]; cx[gx] = (cx[gx] || 0) + 1;
		sy[gy] = (sy[gy] || 0) + mercDeg(pts[i][1]); cy[gy] = (cy[gy] || 0) + 1;
	}
	out = simplifyRect(pts.map(function(p, i) {
		var gx = find(px, i), gy = find(py, i);
		return [ sx[gx] / cx[gx], invMercDeg(sy[gy] / cy[gy]) ];
	}));
	if (tol != null)
		return out.length >= 3 && mercArea(out) >= mercArea(pts) * 0.2 ? out : pts.map(function(p) { return p.slice(); });
	/* every edge straight, nothing folded and most of the area kept - else the surrounding rectangle */
	var ok = out.length >= 4 && out.every(function(p, i) { return alignedKind(p, out[(i + 1) % out.length]); }) &&
		mercArea(out) >= mercArea(pts) * 0.5 && !selfCrossing(out);
	return ok ? out : boundingRect(pts);
}

/* drop repeated corners and corners in the middle of a straight line */
function simplifyRect(pts) {
	var out = pts.slice(), changed = true, i, n, a, b, c;
	while (changed && out.length > 2) {
		changed = false;
		for (i = 0, n = out.length; i < n; i++) {
			a = out[(i + n - 1) % n]; b = out[i]; c = out[(i + 1) % n];
			if (samePoint(a, b) || (alignedKind(a, b) && alignedKind(a, b) === alignedKind(b, c))) {
				out.splice(i, 1);
				changed = true;
				break;
			}
		}
	}
	return out;
}

function boundingRect(pts) {
	var b = ringBounds(pts), w = b[0][0], s = b[0][1], e = b[1][0], nn = b[1][1];
	return [ [ w, s ], [ e, s ], [ e, nn ], [ w, nn ] ];
}

/* does any edge cross a non-neighbouring edge? (on the flat map) */
function selfCrossing(pts) {
	var n = pts.length, i, j;
	function P(p) { return [ p[0], mercDeg(p[1]) ]; }
	function cross(o, a, b) { return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]); }
	for (i = 0; i < n; i++)
		for (j = i + 2; j < n; j++) {
			if (i === 0 && j === n - 1) continue;
			var a = P(pts[i]), b = P(pts[(i + 1) % n]), c = P(pts[j]), d = P(pts[(j + 1) % n]);
			if (cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0)
				return true;
		}
	return false;
}

/* uci: "lat,lon;lat,lon;..." per polygon */
function parsePolygons(list) {
	var out = [];
	L.toArray(list).forEach(function(item) {
		var pts = [], ok = true;
		String(item).split(';').forEach(function(v) {
			var q = v.split(','), lat = +q[0], lon = +q[1];
			if (q.length !== 2 || !isFinite(lat) || !isFinite(lon) || lat < -90 || lat > 90 || lon < -540 || lon > 540)
				ok = false;
			else
				pts.push([ lon, lat ]);
		});
		if (ok && pts.length >= 3)
			out.push(normalizePolygon(pts));
	});
	return out;
}

function formatPolygon(pts) {
	return normalizePolygon(pts).map(function(p) { return p[1].toFixed(4) + ',' + p[0].toFixed(4); }).join(';');
}

function polygonBounds(pts) {
	return ringBounds(pts);
}

/* ------------------------------------------------- address matching */

function v4num(a) {
	var p = String(a).split('.'), n = 0;
	if (p.length !== 4)
		return null;
	for (var i = 0; i < 4; i++) {
		if (!/^\d{1,3}$/.test(p[i]) || +p[i] > 255)
			return null;
		n = n * 256 + (+p[i]);
	}
	return n;
}

function v6groups(a) {
	var m = String(a).match(/^(.*:)(\d+\.\d+\.\d+\.\d+)$/), halves, head, tail, fill, n;
	if (String(a).indexOf(':') < 0)
		return null;
	if (m) {
		n = v4num(m[2]);
		if (n === null)
			return null;
		a = m[1] + Math.floor(n / 65536).toString(16) + ':' + (n % 65536).toString(16);
	}
	halves = String(a).split('::');
	if (halves.length > 2)
		return null;
	head = halves[0] ? halves[0].split(':') : [];
	tail = halves.length === 2 && halves[1] ? halves[1].split(':') : [];
	fill = 8 - head.length - tail.length;
	if (halves.length === 1 ? fill !== 0 : fill < 1)
		return null;
	var all = head.concat(new Array(halves.length === 2 ? fill : 0).fill('0'), tail);
	if (!all.every(function(h) { return /^[0-9a-fA-F]{1,4}$/.test(h); }))
		return null;
	return all.map(function(h) { return parseInt(h, 16); });
}

/* does an allow/block entry (address or subnet) cover this address? */
function cidrMatch(entry, ip) {
	var parts = String(entry).split('/'), bits = parts.length > 1 ? +parts[1] : null;
	var a4 = v4num(parts[0]), b4 = v4num(ip), a6, b6, left, i, take, sh;
	if (a4 !== null && b4 !== null) {
		if (bits === null || bits >= 32)
			return a4 === b4;
		var div = Math.pow(2, 32 - bits);
		return Math.floor(a4 / div) === Math.floor(b4 / div);
	}
	a6 = v6groups(parts[0]); b6 = v6groups(ip);
	if (!a6 || !b6)
		return false;
	left = bits === null ? 128 : Math.min(128, bits);
	for (i = 0; i < 8 && left > 0; i++) {
		take = Math.min(16, left);
		sh = 16 - take;
		if ((a6[i] >> sh) !== (b6[i] >> sh))
			return false;
		left -= take;
	}
	return true;
}

function inList(list, ip) {
	return (list || []).some(function(e) { return cidrMatch(e, ip); });
}

/* devices on the LAN with all their addresses: the router's own list
 * ("lobbyfence devices": DHCP leases, ARP, IPv6 neighbours) merged with LuCI's host hints */
function loadDevices() {
	return Promise.all([
		L.resolveDefault(fs.exec('/usr/sbin/lobbyfence', [ 'devices' ]), null),
		L.resolveDefault(network.getHostHints(), null)
	]).then(function(r) {
		var byMac = {}, order = [];
		function get(mac) {
			mac = String(mac || '').toLowerCase();
			if (!isMac(mac)) return null;
			if (!byMac[mac]) { byMac[mac] = { mac: mac, name: '', ipv4: [], ipv6: [] }; order.push(mac); }
			return byMac[mac];
		}
		function add(arr, a) { if (a && arr.indexOf(a) < 0) arr.push(a); }
		try {
			JSON.parse((r[0] && r[0].code === 0 && r[0].stdout) || '[]').forEach(function(d) {
				var e = get(d.mac);
				if (!e) return;
				e.name = e.name || d.name || '';
				(d.ipv4 || []).forEach(function(a) { add(e.ipv4, a); });
				(d.ipv6 || []).forEach(function(a) { add(e.ipv6, a); });
			});
		} catch (e) {}
		var hints = r[1];
		if (hints && hints.getMACHints) {
			hints.getMACHints(false).forEach(function(h) {
				var e = get(h[0]);
				if (!e) return;
				e.name = e.name || hints.getHostnameByMACAddr(e.mac) || '';
				add(e.ipv4, hints.getIPAddrByMACAddr(e.mac));
				if (hints.getIP6AddrByMACAddr) add(e.ipv6, hints.getIP6AddrByMACAddr(e.mac));
			});
		}
		return order.map(function(m) { return byMac[m]; }).filter(function(d) {
			return d.name || d.ipv4.length || d.ipv6.length;
		}).sort(function(a, b) {
			return (b.name ? 1 : 0) - (a.name ? 1 : 0) || (a.name || '').localeCompare(b.name || '') ||
				(v4num(a.ipv4[0]) || 0) - (v4num(b.ipv4[0]) || 0);
		});
	});
}

function deviceLabel(d) {
	var ips = d.ipv4.concat(d.ipv6.length ? [ d.ipv6[0] + (d.ipv6.length > 1 ? ' +' + (d.ipv6.length - 1) : '') ] : []);
	return (d.name || _('Unnamed device')) + (ips.length ? ' - ' + ips.join(', ') : '') + ' - ' + d.mac.toUpperCase();
}

/* pull IPv4 / IPv6 addresses and subnets out of free text (comments allowed) */
function parseAddressList(text) {
	var seen = {}, list = [], ignored = 0;
	String(text || '').split(/\r?\n/).forEach(function(line) {
		line = line.replace(/#.*$/, '').trim();
		if (!line) return;
		line.split(/[\s,;]+/).forEach(function(tok) {
			if (!tok) return;
			if (validAddress(tok)) {
				if (!seen[tok]) { seen[tok] = 1; list.push(tok); }
			}
			else ignored++;
		});
	});
	return { list: list, ignored: ignored };
}

function store(key, value) {
	try {
		if (value === undefined)
			return JSON.parse(window.localStorage.getItem('lobbyfence.' + key));
		window.localStorage.setItem('lobbyfence.' + key, JSON.stringify(value));
	}
	catch (e) {}
	return null;
}

/* is version a newer than b? ("1.10.0" is newer than "1.9.2") */
function newerVersion(a, b) {
	var x = String(a).split('.'), y = String(b).split('.');
	for (var i = 0; i < Math.max(x.length, y.length); i++) {
		var d = (parseInt(x[i], 10) || 0) - (parseInt(y[i], 10) || 0);
		if (d)
			return d > 0;
	}
	return false;
}

var RELEASES_URL = 'https://github.com/Femto-Gurifisu/Lobbyfence/releases/latest';

/* LobbyFence was called RegionGate before: what this browser remembered under
 * the old name (theme, view, panel, ...) moves over once */
(function() {
	try {
		var ls = window.localStorage, keys = [], i, k;
		for (i = 0; i < ls.length; i++)
			if ((k = ls.key(i)) && k.indexOf('regiongate.') === 0)
				keys.push(k);
		for (i = 0; i < keys.length; i++) {
			k = 'lobbyfence.' + keys[i].slice(11);
			if (ls.getItem(k) === null)
				ls.setItem(k, ls.getItem(keys[i]));
			ls.removeItem(keys[i]);
		}
	}
	catch (e) {}
})();

/* ------------------------------------------------------------- view */

/* OpenWrt: LobbyFence as a home-screen app, like on the other firmwares (its
 * name and icons, the tip on phones, opened from the home screen without
 * LuCI's menus) - lf-app.js, shared with the other firmwares, does it all */
(function() {
	var res = window.L && L.env && L.env.resource, s;
	if (EMBED || !res || !document.head || document.getElementById('lf-appjs'))
		return;
	s = document.createElement('script');
	s.id = 'lf-appjs';
	s.async = true;
	s.src = String(res).replace(/\/resources\/?$/, '') + '/lobbyfence/lf-app.js';
	document.head.appendChild(s);
})();

return view.extend({
	load: function() {
		var self = this;
		return Promise.all([
			uci.load('lobbyfence'),
			L.resolveDefault(uci.changes(), {})
		]).then(function(r) {
			/* changes saved earlier (e.g. before switching tabs) but not applied yet */
			self.pendingApply = !!(r[1] && r[1].lobbyfence && r[1].lobbyfence.length);
		});
	},

	render: function() {
		var self = this;

		injectCss();

		this.circles = {};
		this.polygons = {};
		this.dirty = {};
		this.markers = [];
		this.servers = [];
		this.countries = [];
		this.rules = { allow: [], block: [] };
		this.zone = null;
		this.drawMode = null;
		this.draft = [];
		this.tab = 'in';
		this.filter = '';
		this.status = null;
		this.running = false;
		this.apiResult = null;
		this.full = false;
		this.globe = !!store('globe');
		var vo = store('viewopts') || {};
		this.endless = vo.endless === true;           /* the world repeats left and right (off by default) */
		this.borders = vo.borders !== false;          /* country borders drawn */
		this.labels = vo.labels !== false;            /* place names on the map (off: a plain map) */
		this.wholeWorld = vo.whole === true;          /* zoom out until the whole world is in view */
		this.constrainFn = function(lngLat, zoom) { return self.constrainView(lngLat, zoom); };
		this.passFn = function(lngLat, zoom) { return { center: lngLat, zoom: zoom }; };
		this.borderless = !!vo.borderless;            /* map fills the browser window, no frame */
		this.panelHidden = !!store('nopanel');
		this.themeName = THEMES[store('theme')] ? store('theme') : DEFAULT_THEME;

		uci.sections('lobbyfence', 'zone').forEach(function(z) {
			self.circles[z['.name']] = parseCircles(z.circle);
			self.polygons[z['.name']] = parsePolygons(z.polygon);
		});

		/* toolbar */
		this.zoneSelect = E('select', {
			'class': 'lf-select',
			'title': _('Zone'),
			'change': function() { self.showZone(this.value); }
		});
		this.addButton = E('button', {
			'class': 'lf-btn',
			'click': function(ev) { ev.preventDefault(); self.setDrawMode(self.drawMode === 'circle' ? null : 'circle'); }
		}, _('Add circle'));
		this.polyButton = E('button', {
			'class': 'lf-btn',
			'click': function(ev) {
				ev.preventDefault();
				if (self.drawMode !== 'polygon')
					self.setDrawMode('polygon');
				else if (self.draft.length >= 3)
					self.finishPolygon();
				else
					self.setDrawMode(null);
			}
		}, _('Draw polygon'));
		this.undoButton = E('button', {
			'class': 'lf-btn lf-undocorner', 'style': 'display:none', 'title': _('Take back the last corner (Backspace)'),
			'click': function(ev) { ev.preventDefault(); self.undoDraftPoint(); }
		}, _('Undo corner'));
		this.deleteButton = E('button', {
			'class': 'lf-btn',
			'title': _('Delete the zone shown on the map'),
			'click': function(ev) { ev.preventDefault(); self.confirmDeleteZone(); }
		}, _('Delete zone'));
		this.fitButton = E('button', {
			'class': 'lf-btn',
			'title': _('Show the whole world and keep it that way'),
			'click': function(ev) { ev.preventDefault(); self.fitWorldView(true); }
		}, _('Fit'));
		this.globeButton = E('button', {
			'class': 'lf-btn',
			'click': function(ev) { ev.preventDefault(); self.setGlobe(!self.globe); }
		}, _('Globe'));
		this.viewButton = E('button', {
			'class': 'lf-btn', 'title': _('Map view options'), 'aria-haspopup': 'true',
			'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); self.toggleViewMenu(); }
		}, _('View ▾'));
		this.viewMenu = E('div', { 'class': 'lf-menu', 'style': 'display:none', 'click': function(ev) { ev.stopPropagation(); } });
		document.addEventListener('click', function() { self.toggleViewMenu(false); });
		this.panelButton = E('button', {
			'class': 'lf-btn',
			'title': _('Show or hide the side panel'),
			'click': function(ev) { ev.preventDefault(); self.setPanel(self.panelHidden); }
		}, _('Panel'));
		this.fullButton = E('button', {
			'class': 'lf-btn',
			'title': _('Use the whole screen for the map'),
			'click': function(ev) { ev.preventDefault(); self.toggleFull(); }
		}, _('Full screen'));
		this.homeButton = E('button', {
			'class': 'lf-btn', 'title': _('Set your home location (ZIP code or place name) - shown as a pin on the map'),
			'click': function(ev) { ev.preventDefault(); self.openHome(); }
		}, [ this.homeIco = E('span', { 'class': 'lf-house-ico' }), _('Home') ]);
		this.themeSelect = E('select', {
			'class': 'lf-select',
			'title': _('Colour theme'),
			'change': function() { self.applyTheme(this.value); }
		}, THEME_ORDER.map(function(k) {
			return E('option', { 'value': k }, THEMES[k].label);
		}));

		/* map area */
		this.mapNode = E('div', { 'style': 'position:absolute;inset:0' });
		this.overlay = E('div', { 'class': 'lf-overlay' });
		this.message = E('div', { 'class': 'lf-message' }, E('em', {}, _('Loading map…')));

		/* side panel */
		this.statusSec = E('div', { 'class': 'lf-sec' });
		this.lagSec = E('div', { 'class': 'lf-sec lf-lag' });
		/* remember LobbyFence settings changed while a save is on its way (see stage) */
		if (!uci.lfWrapped) {
			uci.lfWrapped = true;
			[ 'set', 'unset' ].forEach(function(m) {
				var orig = uci[m];
				uci[m] = function() {
					var args = arguments, res = orig.apply(uci, args);
					if (self.inFlight && args[0] === 'lobbyfence')
						self.inFlight.push(function() { orig.apply(uci, args); });
					return res;
				};
			});
		}
		[ this.statusSec, this.lagSec ].forEach(function(sec) {
			sec.addEventListener('focusout', function() {
				window.setTimeout(function() {
					if (self.statusDeferred && !self.editingPanel()) {
						self.statusDeferred = false;
						self.renderStatus();
					}
				}, 0);
			});
		});
		this.regionSec = E('div', { 'class': 'lf-sec' });
		this.tabsNode = E('div', { 'class': 'lf-tabs' });
		this.searchInput = E('input', {
			'class': 'lf-input', 'type': 'search', 'placeholder': _('Search IP / country'), 'title': _('Search by IP address or two-letter country code'),
			'input': function() { self.filter = this.value.trim().toLowerCase(); self.renderServers(); }
		});
		this.listNode = E('div', { 'class': 'lf-list' });
		this.range = RANGES.some(function(r) { return r[0] === store('range'); }) ? store('range') : 'active';
		this.rangeSelect = E('select', {
			'class': 'lf-select', 'title': _('Which learned servers to show'),
			'change': function() { self.range = this.value; store('range', self.range); self.drawServers(); self.renderServers(); }
		}, [
			E('option', { 'value': 'active', 'title': _('Servers your device is exchanging game traffic with right now') }, _('Active now')),
			E('option', { 'value': 'hour' }, _('Last hour')),
			E('option', { 'value': 'day' }, _('Last 24 hours')),
			E('option', { 'value': 'all' }, _('All learned'))
		]);
		this.rangeSelect.value = this.range;
		this.ccFilter = '';
		this.countrySelect = E('select', {
			'class': 'lf-select', 'title': _('Show servers of one country'),
			'change': function() { self.ccFilter = this.value; self.drawServers(); self.renderServers(); }
		}, E('option', { 'value': '' }, _('All countries')));
		this.forgetButton = E('button', {
			'class': 'lf-btn lf-sm', 'title': _('Forget every server this zone has learned'),
			'click': function(ev) { ev.preventDefault(); self.confirmForgetAll(); }
		}, _('Clear'));

		this.notice = E('div', { 'class': 'lf-notice' });

		this.app = E('div', { 'class': 'lf-app' }, [
			E('div', { 'class': 'lf-bar' }, [
				this.zoneSelect,
				E('button', {
					'class': 'lf-btn lf-primary',
					'click': function(ev) { ev.preventDefault(); self.openNewZone(); }
				}, _('New zone…')),
				this.deleteButton,
				this.addButton,
				this.polyButton,
				this.undoButton,
				this.fitButton,
				this.homeButton,
				this.globeButton,
				E('span', { 'class': 'lf-menuwrap' }, [ this.viewButton, this.viewMenu ]),
				this.panelButton,
				this.fullButton,
				E('span', { 'class': 'lf-spacer' }),
				this.saveBar = this.makeSaveBar(),
				this.themeSelect
			]),
			this.notice,
			E('div', { 'class': 'lf-body' }, [
				E('div', { 'class': 'lf-mapwrap' }, [ this.mapNode, this.fxNode = E('div', { 'class': 'lf-fx' }), this.message, this.overlay ]),
				E('div', { 'class': 'lf-panel' }, [
					this.statusSec,
					this.lagSec,
					this.regionSec,
					this.tabsNode,
					E('div', { 'class': 'lf-search' }, [ this.searchInput, this.countrySelect, this.rangeSelect, this.forgetButton ]),
					this.listNode
				])
			])
		]);

		this.applyTheme(this.themeName, true);
		this.setPanel(!this.panelHidden, true);
		if (this.borderless)
			this.setBorderless(true, true);
		this.refreshZoneSelect();
		this.showZone(this.zoneSelect.value || null);

		document.addEventListener('keydown', function(ev) { self.onKey(ev); });
		[ 'fullscreenchange', 'webkitfullscreenchange' ].forEach(function(t) {
			document.addEventListener(t, function() {
				var fsEl = document.fullscreenElement || document.webkitFullscreenElement;
				if (fsEl === self.app)
					self.nativeFull = true;
				else if (self.nativeFull) {
					self.nativeFull = false;
					self.setFull(false);
				}
			});
		});

		loadMaplibre().then(function(ml) {
			self.ml = ml;
			return Promise.all([ loadBaseStyle(), self.waitForAttach() ]);
		}).then(function(res) {
			self.baseStyle = res[0];
			self.initMap();
		}).catch(function(err) {
			self.showMapError(err);
		});

		/* every 5 s while the page is looked at: nothing while it's in a background
		   tab or the screen is off (each question costs the router some work), and
		   every 30 s while LobbyFence is switched off (nothing changes then) */
		poll.add(function() {
			if (document.hidden)
				return;
			if (self.status && self.status.enabled === false && Date.now() - (self.lastRefresh || 0) < 30000)
				return;
			return self.refresh();
		}, 5);
		document.addEventListener('visibilitychange', function() {
			if (!document.hidden && Date.now() - (self.lastRefresh || 0) > 5000)
				self.refresh();
		});
		window.setInterval(function() { self.tick(); }, 1000);

		return E('div', { 'class': 'cbi-map' }, [ E('h2', {}, _('LobbyFence')), this.app ]);
	},

	waitForAttach: function() {
		var node = this.mapNode;
		return new Promise(function(resolve) {
			(function check(n) {
				if (document.body.contains(node) || n > 100)
					resolve();
				else
					window.requestAnimationFrame(function() { check(n + 1); });
			})(0);
		});
	},

	theme: function() {
		return THEMES[this.themeName] || THEMES[DEFAULT_THEME];
	},

	styleFor: function() {
		if (this.theme().satellite)
			return addExtraLabels(satelliteStyle(this.baseStyle));
		return this.baseStyle ? addExtraLabels(themedStyle(this.baseStyle, this.theme())) : rasterStyle(this.theme());
	},

	applyTheme: function(name, initial) {
		var self = this, t;
		this.themeName = THEMES[name] ? name : DEFAULT_THEME;
		t = this.theme();
		if (!initial)
			store('theme', this.themeName);
		this.themeSelect.value = this.themeName;
		Object.keys(t.ui).forEach(function(k) { self.app.style.setProperty('--lf-' + k, t.ui[k]); });
		this.app.classList.toggle('lf-dark', !!t.dark);
		this.homeIco.innerHTML = pinSvg(t.overlay.circle, 14, false);
		if (this.fxNode && this.fxNode.getAttribute('data-fx') !== (t.fx || '')) {
			this.fxNode.setAttribute('data-fx', t.fx || '');
			this.fxNode.innerHTML = '';
			themeFx(t.fx).forEach(function(n) { self.fxNode.appendChild(n); });


		}

		this.renderServers();
		this.renderStatus();
		if (this.map && this.styleReady)
			this.map.setStyle(this.styleFor(), { diff: false });
	},

	showMapError: function(err) {
		noteError('map', 'the map could not be shown: ' + (err && (err.stack || err.message) || err));
		var msg = (this.ml && this.ml.GPUInitializationError && err instanceof this.ml.GPUInitializationError)
			? _('Your browser could not start WebGL2, which the map needs. Try another browser or enable hardware acceleration.')
			: _('The map could not be loaded (%s). This page needs internet access from your browser.').format(err && err.message || err);
		this.message.style.display = 'flex';
		this.message.innerHTML = '';
		this.message.appendChild(E('p', {}, [ msg, E('br'), _('Circles can still be edited in the panel.') ]));
	},

	/* ------------------------------------------------- full screen */

	toggleFull: function() {
		var app = this.app, req = app.requestFullscreen || app.webkitRequestFullscreen;
		var fsEl = document.fullscreenElement || document.webkitFullscreenElement;
		var exit = document.exitFullscreen || document.webkitExitFullscreen;

		if (this.full) {
			if (fsEl && exit)
				try { exit.call(document); } catch (e) {}
			this.setFull(false);
			return;
		}
		/* the CSS version always works; the real one where the browser allows it */
		this.setFull(true);
		if (req)
			try {
				var p = req.call(app);
				if (p && p.catch) p.catch(function() {});
			} catch (e) {}
	},

	/* a touch screen, and the page around the map scrolls (not full screen) */
	touchScroll: function() {
		var coarse = false;
		try { coarse = !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches && !window.matchMedia('(pointer: fine)').matches); } catch (e) {}
		return coarse && !this.full && !this.borderless;
	},

	/* one finger always moves the map (it used to scroll the page on phones, with
	   two fingers for the map - clunky); kept for full screen / borderless switches */
	updateTouchGestures: function() {
		var cg = this.map && this.map.cooperativeGestures;
		if (cg && typeof cg.disable === 'function' && cg.isEnabled())
			cg.disable();
	},

	/* Reset / Save / Save & Apply in the toolbar: borderless and full screen
	   cover the page's own buttons at the bottom (shown only then) */
	makeSaveBar: function() {
		var self = this;
		function btn(cls, label, title, run) {
			var b = E('button', { 'class': 'lf-btn ' + cls, 'title': title, 'click': function(ev) {
				ev.preventDefault();
				if (b.disabled) return;
				b.disabled = true;
				Promise.resolve().then(run).catch(function(err) {
					ui.addNotification(null, E('p', {}, [ String(err && err.message || err) ]), 'error');
				}).then(function() { b.disabled = false; });
			} }, label);
			return b;
		}
		return E('span', { 'class': 'lf-savebar' }, [
			btn('lf-savebtn-reset', _('Reset'), _('Throw away the changes that were not applied'), function() { return self.handleReset(); }),
			btn('lf-savebtn-save', _('Save'), _('Keep the changes without applying them yet'), function() { return self.handleSave(); }),
			btn('lf-primary lf-savebtn-apply', _('Save & Apply'), _('Save the changes and put them into effect'), function() {
				return typeof self.handleSaveApply === 'function' ? self.handleSaveApply(null, '0') : self.handleSave();
			})
		]);
	},

	/* the map covers the whole window: the page's dialogs and messages must come
	   above it (LuCI's Bootstrap and Material themes put them below: z-index 900) */
	updateFullPage: function() {
		document.body.classList.toggle('lf-fullpage', !!(this.full || this.borderless));
	},

	setFull: function(on) {
		var self = this;
		this.full = !!on;
		this.updateTouchGestures();
		this.app.classList.toggle('lf-full', this.full || this.borderless);
		this.updateFullPage();
		this.fullButton.classList.toggle('lf-on', this.full);
		this.fullButton.textContent = this.full ? _('Exit full screen') : _('Full screen');
		document.body.style.overflow = this.full ? 'hidden' : '';
		window.setTimeout(function() { if (self.map) self.map.resize(); }, 60);
	},

	setPanel: function(show, initial) {
		var self = this;
		this.panelHidden = !show;
		if (!initial)
			store('nopanel', this.panelHidden);
		this.app.classList.toggle('lf-nopanel', this.panelHidden);
		this.panelButton.classList.toggle('lf-on', !this.panelHidden);
		window.setTimeout(function() { if (self.map) self.map.resize(); }, 60);
	},

	onKey: function(ev) {
		var t = ev.target || {}, typing = (/^(INPUT|TEXTAREA|SELECT)$/.test(t.tagName || '') && !/^(checkbox|radio|button)$/.test(t.type || '')) || t.isContentEditable;
		var modal = document.body.classList.contains('modal-overlay-active') || document.getElementById('modal');
		if (ev.key === 'Backspace' && !typing && !modal && this.drawMode === 'polygon' && this.draft.length) {
			ev.preventDefault();
			this.undoDraftPoint();
			return;
		}
		if ((ev.key === 'Delete' || ev.key === 'Backspace') && !typing && !modal && !this.drawMode && this.homePopup) {
			ev.preventDefault();
			this.removeHome();
			return;
		}
		if ((ev.key === 'Delete' || ev.key === 'Backspace') && !typing && !modal && !this.drawMode && this.selected) {
			ev.preventDefault();
			this.deleteSelected();
			return;
		}
		if (ev.key === 'Escape') {
			if (this.viewMenu && this.viewMenu.style.display !== 'none')
				this.toggleViewMenu(false);
			else if (this.drawMode)
				this.setDrawMode(null);
			else if (this.homePopup)
				this.closeHomePopup();
			else if (this.selected)
				this.select(null);
			else if (this.full && !this.nativeFull)
				this.setFull(false);
			else if (this.borderless && !this.full && !typing && !modal)
				this.setBorderless(false);
		}
		else if (ev.key === 'Enter' && this.drawMode === 'polygon' && this.draft.length >= 3) {
			ev.preventDefault();
			this.finishPolygon();
		}
	},

	/* -------------------------------------------------------- map */

	initMap: function() {
		var self = this, ml = this.ml, triedFallback = false;

		try {
			this.map = new ml.Map({
				container: this.mapNode,
				style: this.styleFor(),
				center: [ 10, 30 ],
				zoom: 1.2,
				minZoom: 0,
				renderWorldCopies: this.endless,
				attributionControl: { compact: true },
				dragRotate: false,
				pitchWithRotate: false,
				/* phones / tablets: one finger moves the map, two fingers zoom; the page
				   scrolls with a swipe beside the map (toolbar, panel - the map is kept
				   under 2/3 of the screen for that) */
				cooperativeGestures: false
			});
		}
		catch (err) {
			return this.showMapError(err);
		}

		this.map.touchZoomRotate.disableRotation();
		/* no tilting: two fingers sliding up together would tip the map over */
		if (this.map.touchPitch) this.map.touchPitch.disable();
		/* (for the page tests: the map behind this element) */
		try { Object.defineProperty(this.mapNode, 'lfMap', { value: this.map, configurable: true }); } catch (e) {}
		this.map.addControl(new ml.NavigationControl({ showCompass: false }), 'top-right');

		this.map.on('error', function(ev) {
			noteError('map', (ev && ev.error && ev.error.message) || 'map error');
			if (self.styleReady)
				return;
			/* basemap unreachable before it ever loaded: fall back to raster OSM */
			if (!triedFallback) {
				triedFallback = true;
				self.baseStyle = null;
				self.map.setStyle(self.theme().satellite ? satelliteStyle(null) : rasterStyle(self.theme()), { diff: false });
			}
			else {
				self.showMapError(new Error(_('map tiles unreachable')));
			}
		});

		this.map.on('style.load', function() {
			var first = !self.styleReady;
			self.styleReady = true;
			self.message.style.display = 'none';
			self.addLayers();
			if (first) {
				self.bindLayerEvents();
				self.restoreView();
			}
			self.applyProjection();
			self.applyLimits();
			self.applyBorders();
			self.applyLabels();
			self.drawHome();
			self.drawRegions();
			self.drawDraft();
			self.drawServers();
		});

		this.map.on('click', function(ev) {
			if (!self.zone)
				return;
			if (self.swallowClickUntil && Date.now() < self.swallowClickUntil) {
				self.swallowClickUntil = 0;
				return;
			}
			if (self.drawMode === 'circle') {
				self.circles[self.zone].push({ lat: ev.lngLat.lat, lon: wrapLon(ev.lngLat.lng), r: DEFAULT_RADIUS_KM });
				self.setDrawMode(null);
				self.selected = { kind: 'circle', idx: self.circles[self.zone].length - 1 };
				self.regionsChanged();
			}
			else if (self.drawMode === 'polygon') {
				self.addDraftPoint(ev);
			}
			else if (self.selected && !(self.finishedAt && Date.now() - self.finishedAt < 600) &&
			         !(ev.originalEvent && ev.originalEvent.target && ev.originalEvent.target.closest && ev.originalEvent.target.closest('.maplibregl-marker')) &&
			         !(self.map.queryRenderedFeatures && ev.point &&
			         self.map.queryRenderedFeatures(ev.point, { layers: [ 'lf-circle-fill', 'lf-servers' ] }).length)) {
				self.select(null);
			}
		});
		this.map.on('dblclick', function(ev) {
			if (self.drawMode === 'polygon') {
				if (ev.preventDefault) ev.preventDefault();
				if (self.draft.length >= 3)
					self.finishPolygon();
			}
		});
		this.map.on('mousemove', function(ev) {
			if (self.drawMode === 'polygon' && self.draft.length) {
				var prev = self.draft[self.draft.length - 1], c = [ ev.lngLat.lng, ev.lngLat.lat ];
				while (c[0] - prev[0] > 180) c[0] -= 360;
				while (c[0] - prev[0] < -180) c[0] += 360;
				self.cursor = c;
				self.drawDraft();
			}
		});

		/* Fit stays in effect until the user moves the map themselves */
		this.map.on('moveend', function(ev) {
			if (ev && ev.originalEvent)
				self.fitWorld = false;
			/* zoomed out as far as it goes (kept so when the map area changes size) */
			self.atFloor = typeof self.map.getMinZoom === 'function' && self.map.getZoom() <= self.map.getMinZoom() + 0.02;
			self.saveView();
		});
		/* the map area changed size (borderless, panel, full screen, window):
		   the limits depend on it - apply them at once, not on the next move */
		this.map.on('resize', function() {
			var floor = self.atFloor;
			self.applyLimits();
			if (self.wholeWorld && !self.globe && floor)
				self.map.jumpTo({ zoom: self.fitZoom() });
			else if (self.fitWorld)
				self.map.fitBounds(WORLD_BOUNDS, { padding: 8, duration: 0 });
		});
	},

	bindLayerEvents: function() {
		var self = this;

		this.map.on('click', 'lf-servers', function(ev) {
			if (self.drawMode || !ev.features || !ev.features.length)
				return;
			var f = ev.features[0];
			self.openPopup(f.geometry.coordinates, String(f.properties.ips).split(' '), f.properties.cc);
		});
		this.map.on('mousedown', 'lf-circle-fill', function(ev) { self.startShapeDrag(ev); });
		this.map.on('click', 'lf-home', function(ev) {
			if (self.drawMode) return;
			if (ev.originalEvent) ev.originalEvent.lfHome = true;
			self.openHomePopup();
		});
		this.map.on('mouseenter', 'lf-home', function() { if (!self.drawMode) self.map.getCanvas().style.cursor = 'pointer'; });
		this.map.on('mouseleave', 'lf-home', function() { self.map.getCanvas().style.cursor = self.drawMode ? 'crosshair' : ''; });
		this.map.on('touchstart', 'lf-circle-fill', function(ev) {
			if (!ev.points || ev.points.length === 1)
				self.startShapeDrag(ev);
		});
		this.map.on('mouseenter', 'lf-circle-fill', function() { if (!self.drawMode) self.map.getCanvas().style.cursor = 'move'; });
		this.map.on('mouseleave', 'lf-circle-fill', function() { self.map.getCanvas().style.cursor = self.drawMode ? 'crosshair' : ''; });
		this.map.on('mouseenter', 'lf-servers', function() { if (!self.drawMode) self.map.getCanvas().style.cursor = 'pointer'; });
		this.map.on('mouseleave', 'lf-servers', function() { self.map.getCanvas().style.cursor = self.drawMode ? 'crosshair' : ''; });
	},

	addLayers: function() {
		var map = this.map, t = this.theme(), o = t.overlay, empty = { type: 'FeatureCollection', features: [] };

		[ 'lf-circles', 'lf-draft', 'lf-servers' ].forEach(function(id) {
			if (!map.getSource(id))
				map.addSource(id, { type: 'geojson', data: empty });
		});

		if (!map.getLayer('lf-circle-fill'))
			map.addLayer({ id: 'lf-circle-fill', type: 'fill', source: 'lf-circles',
				/* clear inside; a light tint only while a shape is selected for editing */
				/* see-through blue; a little stronger while a shape is selected for editing */
				paint: { 'fill-color': o.circle, 'fill-opacity': [ 'case', [ '==', [ 'get', 'sel' ], 1 ], 0.22, 0.1 ] } });
		if (!map.getLayer('lf-circle-line'))
			map.addLayer({ id: 'lf-circle-line', type: 'line', source: 'lf-circles',
				paint: { 'line-color': [ 'case', [ '==', [ 'get', 'sel' ], 1 ], o.circleSel || o.circle, o.circle ],
					'line-width': [ 'case', [ '==', [ 'get', 'sel' ], 1 ], 3.5, 2 ] } });
		if (!map.getLayer('lf-draft-line'))
			map.addLayer({ id: 'lf-draft-line', type: 'line', source: 'lf-draft',
				filter: [ '==', [ 'geometry-type' ], 'LineString' ],
				paint: { 'line-color': o.circle, 'line-width': this.coarse() ? 3 : 2.5 } });
		if (!map.getLayer('lf-draft-pts'))
			map.addLayer({ id: 'lf-draft-pts', type: 'circle', source: 'lf-draft',
				filter: [ '==', [ 'geometry-type' ], 'Point' ],
				paint: { 'circle-radius': [ 'case', [ '==', [ 'get', 'first' ], 1 ], this.coarse() ? 11 : 7, this.coarse() ? 6 : 4 ],
					'circle-color': o.circle, 'circle-stroke-color': t.dark ? '#000000' : '#ffffff', 'circle-stroke-width': [ 'case', [ '==', [ 'get', 'first' ], 1 ], 2.5, 1 ] } });
		if (!map.getLayer('lf-servers'))
			map.addLayer({ id: 'lf-servers', type: 'circle', source: 'lf-servers',
				paint: {
					'circle-radius': [ 'min', 14, [ '+', 4, [ '*', 2, [ 'sqrt', [ 'get', 'count' ] ] ] ] ],
					'circle-color': [ 'match', [ 'get', 'state' ], 'in', o.allowed, o.blocked ],
					'circle-opacity': [ 'coalesce', [ 'get', 'fade' ], 0.9 ],
					/* a thick ring marks servers you allowed or blocked yourself */
					'circle-stroke-color': [ 'case', [ '==', [ 'get', 'manual' ], '' ], t.dark ? '#000000' : '#ffffff', t.ui.accent ],
					'circle-stroke-width': [ 'case', [ '==', [ 'get', 'manual' ], '' ], 1, 3 ]
				} });
	},

	/* ----------------------------------------------------- camera */

	/* Camera limits. Normal use: MapLibre's own - the map always fills its
	   area (with the endless map off the world fills it in width and height,
	   so zoomed out the poles - on a phone the Americas' west and East Asia -
	   are off screen). "Whole world" (View menu, stays on until switched off):
	   you can zoom out until the entire world is in view, pole to pole and all
	   the way round. */

	/* the zoom where the whole world just fits the map area (-2 at the least) */
	fitZoom: function() {
		var node = this.mapNode, W = node ? node.clientWidth : 0, H = node ? node.clientHeight : 0;
		return (W > 0 && H > 0) ? Math.max(-2, Math.log(Math.min(W, H) / 512) / Math.LN2) : -2;
	},

	/* the zoom where the world just fills the map area (MapLibre's own lowest) */
	fillZoom: function() {
		var node = this.mapNode, W = node ? node.clientWidth : 0, H = node ? node.clientHeight : 0;
		return (W > 0 && H > 0) ? Math.max(0, Math.log(Math.max(W, H) / 512) / Math.LN2) : 0;
	},

	wholeMinZoom: function() { return Math.floor(this.fitZoom() * 1000) / 1000; },

	/* Put the limits in force now and apply them to the camera AT ONCE.
	   MapLibre only checks them on the next move: after switching the endless
	   map off, or a size change, the world stayed half off-screen with an empty
	   strip (or too small / too big) until you zoomed. */
	applyLimits: function() {
		var map = this.map, on;
		if (!map || typeof map.setTransformConstrain !== 'function')
			return;
		on = this.wholeWorld && !this.globe;
		map.setMinZoom(on ? this.wholeMinZoom() : 0);
		/* (a change of the constraint makes MapLibre check the camera right away;
		   it is also lost when the projection changes) */
		map.setTransformConstrain(this.passFn);
		map.setTransformConstrain(on ? this.constrainFn : null);
	},

	setWholeWorld: function(on) {
		var map = this.map;
		this.wholeWorld = !!on;
		this.saveViewOpts();
		this.applyLimits();
		if (!this.wholeWorld || !map)
			return;
		/* switched on: show the whole world now */
		this.fitWorld = false;
		if (this.globe || typeof map.setTransformConstrain !== 'function')
			map.fitBounds(FULL_BOUNDS, { padding: 0, duration: 400 });
		else
			map.easeTo({ center: [ 0, 0 ], zoom: this.fitZoom(), duration: 400 });
		this.saveView();
	},

	/* the camera's limits with "Whole world" on: no further out than the whole
	   world fitting; a world smaller than the map area stays centred, a bigger
	   one never shows empty space at its edges */
	constrainView: function(lngLat, zoom) {
		var map = this.map, ml = this.ml, node = this.mapNode, W = node ? node.clientWidth : 0, H = node ? node.clientHeight : 0;
		var lng = lngLat.lng, lat = Math.max(-85.0511, Math.min(85.0511, lngLat.lat)), ws, x, y, n;
		zoom = Math.max(map ? map.getMinZoom() : -2, Math.min(map ? map.getMaxZoom() : 22, +zoom));
		if (!(W > 0 && H > 0))
			return { center: new ml.LngLat(lng, lat), zoom: zoom };
		zoom = Math.max(zoom, this.fitZoom());
		ws = 512 * Math.pow(2, zoom);
		y = (1 - mercY(lat) / Math.PI) / 2 * ws;
		y = ws <= H ? ws / 2 : Math.max(H / 2, Math.min(ws - H / 2, y));
		n = Math.PI * (1 - 2 * y / ws);
		lat = toDeg(Math.atan(0.5 * (Math.exp(n) - Math.exp(-n))));
		if (!this.endless) {
			x = (lng + 180) / 360 * ws;
			x = ws <= W ? ws / 2 : Math.max(W / 2, Math.min(ws - W / 2, x));
			lng = x / ws * 360 - 180;
		}
		return { center: new ml.LngLat(lng, lat), zoom: zoom };
	},

	fitWorldView: function(animate) {
		this.fitWorld = true;
		if (this.map)
			this.map.fitBounds(WORLD_BOUNDS, { padding: 8, duration: animate ? 400 : 0 });
		this.saveView();
	},

	saveView: function() {
		var c;
		this.fitButton.classList.toggle('lf-on', !!this.fitWorld);
		if (!this.map)
			return;
		c = this.map.getCenter();
		store('view', { fit: !!this.fitWorld, center: [ c.lng, c.lat ], zoom: this.map.getZoom() });
	},

	/* keep the camera the user left - also across Save & Apply page reloads */
	restoreView: function() {
		var v = store('view');
		if (v && !v.fit && v.center && isFinite(v.zoom)) {
			this.fitWorld = false;
			this.map.jumpTo({ center: v.center, zoom: v.zoom });
			this.saveView();
		}
		else {
			this.fitWorldView(false);
		}
	},

	flyTo: function(center, zoom) {
		if (!this.map)
			return;
		this.fitWorld = false;
		this.map.flyTo({ center: center, zoom: Math.max(this.map.getZoom(), zoom) });
	},

	fitTo: function(bounds) {
		if (!this.map)
			return;
		this.fitWorld = false;
		this.map.fitBounds(bounds, { padding: 40, maxZoom: 7 });
	},

	/* --------------------------------------------------- view menu */

	toggleViewMenu: function(open) {
		var self = this, show = open === undefined ? this.viewMenu.style.display === 'none' : !!open;
		function item(label, hint, on, fn) {
			var box = E('input', { 'type': 'checkbox', 'change': function() { fn(this.checked); } });
			box.checked = !!on;
			return E('label', { 'class': 'lf-mitem', 'title': hint }, [ box, E('span', {}, label) ]);
		}
		if (!show) {
			this.viewMenu.style.display = 'none';
			this.viewButton.classList.remove('lf-on');
			return;
		}
		this.viewMenu.innerHTML = '';
		this.viewMenu.appendChild(item(_('Borderless'), _('The map fills the browser window without a frame - Esc to leave'),
			this.borderless, function(on) { self.setBorderless(on); }));
		this.viewMenu.appendChild(item(_('Endless map'), _('Keep scrolling left or right forever - the world repeats instead of ending at the edge'),
			this.endless, function(on) { self.setEndless(on); }));
		this.viewMenu.appendChild(item(_('Country borders'), _('Show the lines between countries'),
			this.borders, function(on) { self.setBorders(on); }));
		this.viewMenu.appendChild(item(_('Place names'), _('Names of countries, cities, seas and so on - switch off for a plain map'),
			this.labels, function(on) { self.setLabels(on); }));
		this.viewMenu.appendChild(item(_('Whole world'), _('Zoom out until the entire world is in view, pole to pole - stays on until you switch it off (zoomed out, the map then no longer fills its whole area)'),
			this.wholeWorld, function(on) { self.setWholeWorld(on); }));
		this.viewMenu.style.display = '';
		this.viewButton.classList.add('lf-on');
	},

	saveViewOpts: function() {
		store('viewopts', { endless: this.endless, borders: this.borders, borderless: this.borderless, labels: this.labels, whole: this.wholeWorld });
	},

	setBorderless: function(on, initial) {
		var self = this;
		this.borderless = !!on;
		if (!initial)
			this.saveViewOpts();
		this.app.classList.toggle('lf-borderless', this.borderless);
		this.app.classList.toggle('lf-full', this.full || this.borderless);
		this.updateFullPage();
		this.updateTouchGestures();
		document.body.style.overflow = (this.full || this.borderless) ? 'hidden' : '';
		window.setTimeout(function() { if (self.map) self.map.resize(); }, 60);
	},

	setEndless: function(on) {
		this.endless = !!on;
		this.saveViewOpts();
		if (this.map && typeof this.map.setRenderWorldCopies === 'function')
			this.map.setRenderWorldCopies(this.endless);
		this.applyLimits();   /* (the limits depend on it: applied now, not on the next move) */
	},

	setBorders: function(on) {
		this.borders = !!on;
		this.saveViewOpts();
		this.applyBorders();
	},

	/* hide or show the basemap's border lines (never our own lf- layers) */
	applyBorders: function() {
		var self = this, st = this.map && this.styleReady && this.map.getStyle && this.map.getStyle();
		if (!st || !st.layers)
			return;
		st.layers.forEach(function(l) {
			if (l.type === 'line' && !/^lf-/.test(l.id) && /boundary|admin|border/.test(String(l.id).toLowerCase()))
				self.map.setLayoutProperty(l.id, 'visibility', self.borders ? 'visible' : 'none');
		});
	},

	setLabels: function(on) {
		this.labels = !!on;
		this.saveViewOpts();
		this.applyLabels();
	},

	/* hide or show every name on the basemap (its text layers, our Antarctica
	   label) - never LobbyFence's own layers (server dots, regions, home pin) */
	applyLabels: function() {
		var self = this, st = this.map && this.styleReady && this.map.getStyle && this.map.getStyle();
		if (!st || !st.layers)
			return;
		st.layers.forEach(function(l) {
			if (l.type === 'symbol' && (!/^lf-/.test(l.id) || l.id === 'lf-label-continent'))
				self.map.setLayoutProperty(l.id, 'visibility', self.labels ? 'visible' : 'none');
		});
	},

	setGlobe: function(on) {
		var self = this;
		this.globe = !!on;
		store('globe', this.globe);
		this.applyProjection();
		this.applyLimits();
		/* (MapLibre swaps the projection a moment later: the limits once more then,
		   and back out to the whole world if that is where the map was) */
		if (this.map && typeof this.map.once === 'function')
			this.map.once('idle', function() {
				self.applyLimits();
				if (self.wholeWorld && !self.globe && self.map.getZoom() <= self.fillZoom() + 0.05)
					self.map.jumpTo({ zoom: self.fitZoom() });
			});
	},

	applyProjection: function() {
		this.globeButton.classList.toggle('lf-on', this.globe);
		if (this.map && this.styleReady && typeof this.map.setProjection === 'function')
			this.map.setProjection({ type: this.globe ? 'globe' : 'mercator' });
	},

	/* ------------------------------------------------- drawing */

	setDrawMode: function(mode) {
		this.drawMode = this.zone ? (mode || null) : null;
		if (this.drawMode && this.prompt && this.prompt.lfAlign)
			this.hidePrompt();
		this.draft = [];
		this.cursor = null;
		this.addButton.classList.toggle('lf-on', this.drawMode === 'circle');
		this.addButton.textContent = this.drawMode === 'circle' ? _('Click the map…') : _('Add circle');
		this.polyButton.classList.toggle('lf-on', this.drawMode === 'polygon');
		this.polyButton.textContent = this.drawMode === 'polygon' ? _('Cancel polygon') : _('Draw polygon');
		if (this.undoButton) {
			this.undoButton.style.display = this.drawMode === 'polygon' ? '' : 'none';
			this.undoButton.disabled = true;
		}
		if (this.map) {
			this.map.getCanvas().style.cursor = this.drawMode ? 'crosshair' : '';
			if (this.map.doubleClickZoom)
				this.map.doubleClickZoom[this.drawMode === 'polygon' ? 'disable' : 'enable']();
		}
		this.drawDraft();
		this.updateNotice();
	},

	addDraftPoint: function(ev) {
		var lng = ev.lngLat.lng, lat = Math.max(-85, Math.min(85, ev.lngLat.lat)), first, prev, a, b, tol;

		if (this.draft.length) {
			prev = this.draft[this.draft.length - 1];
			while (lng - prev[0] > 180) lng -= 360;
			while (lng - prev[0] < -180) lng += 360;

			/* clicking the first corner closes the shape; repeated clicks (double-click) are ignored */
			if (this.map.project && ev.point) {
				first = this.map.project([ this.draft[0][0], this.draft[0][1] ]);
				tol = this.coarse() ? 24 : 10;
				if (this.draft.length >= 3 && Math.abs(first.x - ev.point.x) < tol && Math.abs(first.y - ev.point.y) < tol)
					return this.finishPolygon();
				a = this.map.project([ prev[0], prev[1] ]);
				if (Math.abs(a.x - ev.point.x) < 4 && Math.abs(a.y - ev.point.y) < 4)
					return;
			}
		}
		else {
			lng = wrapLon(lng);
		}
		b = [ lng, lat ];
		this.draft.push(b);
		this.draftChanged();
	},

	/* take back the last corner placed while drawing */
	undoDraftPoint: function() {
		if (this.drawMode !== 'polygon' || !this.draft.length)
			return;
		this.draft.pop();
		if (!this.draft.length) this.cursor = null;
		this.draftChanged();
	},

	draftChanged: function() {
		this.polyButton.textContent = this.draft.length >= 3 ? _('Finish polygon') : _('Cancel polygon');
		if (this.undoButton)
			this.undoButton.disabled = !this.draft.length;
		this.drawDraft();
		this.updateNotice();
	},

	finishPolygon: function() {
		if (this.drawMode !== 'polygon' || this.draft.length < 3 || !this.zone)
			return this.setDrawMode(null);
		this.polygons[this.zone].push(normalizePolygon(this.draft));
		this.setDrawMode(null);
		this.selected = { kind: 'polygon', idx: this.polygons[this.zone].length - 1 };
		this.finishedAt = Date.now();   /* the click that finished it must not deselect it */
		this.regionsChanged();
	},

	/* edges that are not exactly horizontal / vertical yet */
	nearlyStraightEdges: function(pts) {
		var n = pts.length, c = 0;
		for (var i = 0; i < n; i++)
			if (!alignedKind(pts[i], pts[(i + 1) % n])) c++;
		return c;
	},

	/* The align offer belongs to the selected polygon: it stays on screen while the
	 * polygon is selected and has edges that are almost straight, and goes away
	 * when it is deselected, aligned, or the user chooses to keep it as drawn. */
	updateAlignPrompt: function() {
		var self = this, zone = this.zone, sel = this.selected, pts, n, sig;
		if (!sel || sel.kind !== 'polygon' || this.drawMode || !(pts = (this.polygons[zone] || [])[sel.idx])) {
			if (this.prompt && this.prompt.lfAlign) this.hidePrompt();
			return;
		}
		n = this.nearlyStraightEdges(pts);
		sig = zone + '|' + formatPolygon(pts);
		if (!n || this.keepDrawn === sig) {
			if (this.prompt && this.prompt.lfAlign) this.hidePrompt();
			return;
		}
		if (this.prompt && this.prompt.lfAlign === sig)
			return;   /* already showing for exactly this shape */
		this.showPrompt(_('Make every edge straight? Your shape becomes a square / rectangle.'), [
			[ _('Align'), function() { self.straightenSelected(); }, true ],
			[ _('Keep as drawn'), function() { self.keepDrawn = sig; } ]
		]);
		this.prompt.lfAlign = sig;
	},

	/* straighten polygon idx (default: the selected one); tells the user what happened */
	straightenSelected: function(idx) {
		var zone = this.zone, sel = this.selected, polys = this.polygons[zone] || [], cur, out, changed;
		if (idx == null) idx = sel && sel.kind === 'polygon' ? sel.idx : -1;
		cur = polys[idx];
		if (!cur)
			return false;
		out = normalizePolygon(straightenPolygon(cur));
		changed = out.length !== cur.length || out.some(function(p, i) { return Math.abs(p[0] - cur[i][0]) > 1e-9 || Math.abs(p[1] - cur[i][1]) > 1e-9; });
		if (!changed) {
			this.flashNotice(_('Already straight - every edge is level or upright.'));
			return false;
		}
		polys[idx] = out;
		this.regionsChanged();
		this.drawServers();
		this.flashNotice(_('Edges straightened.'));
		return true;
	},

	flashNotice: function(text) {
		var self = this;
		this.flash = text;
		this.updateNotice();
		window.clearTimeout(this.flashTimer);
		this.flashTimer = window.setTimeout(function() { self.flash = null; self.updateNotice(); }, 4000);
	},

	showPrompt: function(text, buttons) {
		var self = this;
		this.hidePrompt();
		this.prompt = E('div', { 'class': 'lf-prompt' }, [ E('span', {}, text) ].concat(buttons.map(function(b) {
			return E('button', {
				'class': 'lf-btn lf-sm' + (b[2] ? ' lf-primary' : ''),
				'click': function(ev) { ev.preventDefault(); self.hidePrompt(); b[1](); }
			}, b[0]);
		})));
		this.mapNode.parentNode.appendChild(this.prompt);
	},

	hidePrompt: function() {
		if (this.prompt) { this.prompt.remove(); this.prompt = null; }
	},

	drawDraft: function() {
		var feats = [], pts = this.draft;
		if (!this.map || !this.styleReady || !this.map.getSource('lf-draft'))
			return;
		if (pts.length) {
			var line = pts.slice();
			if (this.cursor) line.push(this.cursor);
			if (line.length >= 2)
				feats.push({ type: 'Feature', geometry: { type: 'LineString', coordinates: line }, properties: {} });
			/* the first corner grows once the shape can be closed there */
			pts.forEach(function(p, i) {
				feats.push({ type: 'Feature', geometry: { type: 'Point', coordinates: p }, properties: { first: i === 0 && pts.length >= 3 ? 1 : 0 } });
			});
		}
		this.map.getSource('lf-draft').setData({ type: 'FeatureCollection', features: feats });
	},

	/* -------------------------------------------------------- zones */

	refreshZoneSelect: function() {
		var zones = uci.sections('lobbyfence', 'zone'), sel = this.zoneSelect;
		sel.innerHTML = '';
		zones.forEach(function(z) {
			sel.appendChild(E('option', { 'value': z['.name'] }, z.label || z['.name']));
		});
		sel.style.display = zones.length ? '' : 'none';
		this.addButton.disabled = !zones.length;
		this.polyButton.disabled = !zones.length;
		this.deleteButton.style.display = zones.length ? '' : 'none';
	},

	showZone: function(zone) {
		this.serversRev = null;
		this.zone = zone || null;
		this.selected = null;
		this.hidePrompt();
		this.servers = [];
		this.setDrawMode(null);

		if (this.zone && !this.circles[this.zone])
			this.circles[this.zone] = [];
		if (this.zone && !this.polygons[this.zone])
			this.polygons[this.zone] = [];
		if (this.zone)
			this.zoneSelect.value = this.zone;

		var sec = this.zone ? (uci.get('lobbyfence', this.zone) || {}) : {};
		this.countries = L.toArray(sec.country).map(function(c) { return String(c).toUpperCase(); });
		this.rules = { allow: L.toArray(sec.allow_ip), block: L.toArray(sec.block_ip) };

		this.renderWelcome();
		this.updateNotice();
		this.drawRegions();
		this.drawServers();
		this.renderServers();
		this.renderStatus();
		return this.refresh();
	},

	/* fresh counters for the shown zone ("lobbyfence live"), status.json as fallback */
	zoneLive: function() {
		var z = this.zoneStatus(), l = this.live && this.live.zones && this.live.zones[this.zone];
		if (!z && !l) return null;
		return Object.assign({}, z || {}, l || {});
	},

	zoneStatus: function() {
		var zs = (this.status && this.status.zones) || [], zone = this.zone;
		return zs.filter(function(z) { return z.id === zone; })[0] || null;
	},

	/* "enforce" + strict flag, with the router's defaults */
	zoneMode: function() {
		var sec = this.zone ? (uci.get('lobbyfence', this.zone) || {}) : {};
		var mode = sec.mode === 'monitor' ? 'monitor' : 'enforce', strict = sec.strict == null ? true : sec.strict === '1';
		return mode === 'monitor' ? 'monitor' : (strict ? 'strict' : 'enforce');
	},

	setZoneMode: function(m) {
		if (!this.zone || !uci.get('lobbyfence', this.zone))
			return;
		uci.set('lobbyfence', this.zone, 'mode', m === 'monitor' ? 'monitor' : 'enforce');
		uci.set('lobbyfence', this.zone, 'strict', m === 'strict' ? '1' : '0');
		this.stage();
		this.updateNotice();
		this.renderStatus();
		this.renderServers();
	},

	/* status.json + learned servers of the shown zone (polled) */
	refresh: function() {
		var self = this, zone = this.zone;
		this.lastRefresh = Date.now();
		this.refreshing = this.lastRefresh;
		return Promise.all([
			fs.read('/tmp/lobbyfence/status.json').then(JSON.parse).catch(function() { return null; }),
			L.resolveDefault(callServiceList('lobbyfence'), {})
		]).then(function(r) {
			/* the server list can be large: only download it when the router says
			 * it changed (its revision number), or when it is not known yet */
			var zs = r[0] && (r[0].zones || []).filter(function(x) { return x.id === zone; })[0];
			var rev = zs && zs.rev != null ? zone + ':' + zs.rev : null;
			var want = zone && (rev == null || rev !== self.serversRev);
			return Promise.all([
				r[0], r[1],
				want ? fs.read('/tmp/lobbyfence/' + zone + '.servers').then(function(t) { self.serversRev = rev; return t; }).catch(function() { return ''; }) : Promise.resolve(null),
				L.resolveDefault(fs.exec('/usr/sbin/lobbyfence', [ 'live' ]), null)
			]);
		}).then(function(r) {
			try { self.live = r[3] && r[3].code === 0 ? JSON.parse(r[3].stdout) : null; } catch (e) { self.live = null; }
			/* the router reports whole seconds every 5 s; count down locally in between */
			var lz = self.live && self.live.zones && self.live.zones[zone];
			self.openUntil = lz && lz.open_left > 0 ? Date.now() + lz.open_left * 1000 : 0;
			var inst = (r[1] && r[1].lobbyfence && r[1].lobbyfence.instances) || {}, z;
			var ver = self.status && self.status.version;
			self.status = r[0];
			self.running = Object.keys(inst).some(function(k) { return inst[k].running; });
			if (self.welcomeVersion && (self.status && self.status.version) !== ver)
				self.fillVersion(self.welcomeVersion);
			z = self.zoneStatus();
			if (z && z.allow && z.block && zone === self.zone)
				self.rules = { allow: z.allow, block: z.block };
			if (zone && zone === self.zone && r[2] != null)
				self.servers = parseServers(r[2]);
			/* nothing the map or the list shows has changed (same server list, same
			 * live traffic, same rules and filters): skip the redraw - at least once a
			 * minute it still happens, for "last seen" texts and the time filters */
			var lz = self.live && self.live.zones && self.live.zones[zone];
			var sig = [ r[2] != null ? Math.random() : self.serversRev, self.servers.length, JSON.stringify(lz ? [ lz.active, lz.rate ] : null),
				JSON.stringify(self.rules || null), self.range, self.ccFilter || '', self.filter || '', Math.floor(self.routerNow() / 60) ].join('|');
			var same = sig === self.drawnSig && zone === self.drawnZone, ok = true;
			/* each part on its own: one that fails (it shouldn't) must not keep the others
			   - the server list above all - from updating; it is tried again next time */
			function part(name, fn) {
				try { fn(); }
				catch (e) { ok = false; console.error('LobbyFence: ' + name + ':', e); }
			}
			if (!same)
				part('map', function() { self.drawServers(); });
			/* don't rebuild the boxes the user is typing in; catch up when they leave */
			part('panel', function() {
				if (self.editingPanel())
					self.statusDeferred = true;
				else
					self.renderStatus();
			});
			if (!same)
				part('server list', function() { self.renderServers(); });
			if (!same && ok) {
				self.drawnSig = sig;
				self.drawnZone = zone;
			}
		}).finally(function() {
			self.refreshing = 0;
		});
	},

	editingPanel: function() {
		var ae = document.activeElement;
		return !!(ae && /^(INPUT|SELECT|TEXTAREA)$/.test(ae.tagName) &&
			((this.statusSec && this.statusSec.contains(ae)) || (this.lagSec && this.lagSec.contains(ae))));
	},

	renderWelcome: function() {
		var self = this;
		this.overlay.innerHTML = '';
		if (this.zone) {
			this.overlay.style.display = 'none';
			return;
		}
		this.overlay.style.display = 'flex';
		function list(cls, mark, items) {
			return E('ul', { 'class': 'lf-wlist ' + cls }, items.map(function(t) {
				return E('li', {}, [ E('span', { 'class': 'lf-wmark', 'aria-hidden': 'true' }, mark), E('span', {}, t) ]);
			}));
		}
		this.overlay.appendChild(E('div', { 'class': 'lf-card lf-welcome' }, [
			E('h3', {}, _('Welcome to LobbyFence')),
			E('p', {}, _('LobbyFence decides which game servers your console, PC or phone is allowed to connect to, based on where in the world they are.')),
			E('div', { 'class': 'lf-wcols' }, [
				E('div', {}, [
					E('h4', { 'class': 'lf-wcan' }, _('What it can do')),
					list('lf-wyes', '✓', [
						_('You draw an area on the map - a circle or any shape.'),
						_('Game servers outside your area are blocked, so you only join matches hosted inside it.'),
						_('Only the device you pick is filtered. Everything else on your network works as normal.'),
						_('Every server your game uses shows up on the map: green = allowed, red = blocked.'),
						_('Click any server to always allow it or always block it.'),
						_('Comes with ready-made settings for popular games, or set up your own.')
					])
				]),
				E('div', {}, [
					E('h4', { 'class': 'lf-wcant' }, _('What it can\'t do')),
					list('lf-wno', '✗', [
						_('It can\'t lower your ping or make a slow internet connection faster.'),
						_('It picks servers, not players - people from far away can still join a server near you.'),
						_('If your area has few servers, finding a match can take longer or fail.'),
						_('It can\'t make the game\'s matchmaking choose you differently (skill, lobbies).'),
						_('Server locations come from a free database and are sometimes wrong - you can fix them by hand.'),
						_('It can\'t see your game through a VPN, so it won\'t filter while one is on.')
					])
				])
			]),
			E('p', { 'class': 'lf-wsteps' }, _('How to start: 1. Pick your game and device. 2. Draw your area on the map. 3. Press Save & Apply.')),
			E('button', {
				'class': 'lf-btn lf-primary',
				'click': function(ev) { ev.preventDefault(); self.openNewZone(); }
			}, _('Create your first zone')),
			E('div', { 'class': 'lf-wfoot' }, [
				this.welcomeVersion = this.fillVersion(E('div', { 'class': 'lf-version' })),
				E('div', { 'class': 'lf-credit' }, _('Created by Darkness'))
			])
		]));
	},

	/* "LobbyFence 1.1.0 - up to date", or the newer version on GitHub (when this
	   browser could ask), or just a link to the latest release */
	fillVersion: function(el) {
		var v = this.status && this.status.version, latest = this.latestVersion;
		if (!el)
			return el;
		this.askLatest();
		el.innerHTML = '';
		el.appendChild(document.createTextNode(v ? _('LobbyFence %s').format(v) : 'LobbyFence'));
		el.appendChild(document.createTextNode(' · '));
		if (v && latest && newerVersion(latest, v))
			el.appendChild(E('a', { 'class': 'lf-newer', 'href': RELEASES_URL, 'target': '_blank', 'rel': 'noopener noreferrer' },
				_('version %s is out - update').format(latest)));
		else if (v && latest)
			el.appendChild(document.createTextNode(_('up to date')));
		else
			el.appendChild(E('a', { 'href': RELEASES_URL, 'target': '_blank', 'rel': 'noopener noreferrer' }, _('latest version')));
		return el;
	},

	/* the newest LobbyFence on GitHub, asked by this browser (not the router) at most
	   twice a day - nothing is sent but the question itself */
	askLatest: function() {
		var self = this, c = store('latest'), now = Date.now();
		if (this.latestAsked)
			return;
		this.latestAsked = true;
		if (c && typeof c.v === 'string' && now >= +c.t && now - c.t < 12 * 3600 * 1000) {
			this.latestVersion = c.v;
			return;
		}
		if (typeof window.fetch !== 'function')
			return;
		window.fetch('https://api.github.com/repos/Femto-Gurifisu/Lobbyfence/releases/latest',
			{ credentials: 'omit', referrerPolicy: 'no-referrer', cache: 'no-store' }).then(function(r) {
			return r.ok ? r.json() : null;
		}).then(function(j) {
			var v = j && typeof j.tag_name === 'string' ? j.tag_name.replace(/^v/i, '') : '';
			if (!/^\d+(\.\d+){1,3}$/.test(v))
				return;
			self.latestVersion = v;
			store('latest', { v: v, t: Date.now() });
			self.fillVersion(self.welcomeVersion);
			if (!self.editingPanel())
				self.renderStatus();
		}).catch(function() {});
	},

	hasRegion: function() {
		return !!((this.circles[this.zone] || []).length || (this.polygons[this.zone] || []).length || this.countries.length);
	},

	/* while drawing, the line above the map never gets shorter: the map below
	   it must not jump between two taps (the corners would land off target) */
	holdNoticeHeight: function() {
		var h = this.notice.offsetHeight || 0;
		if (h > (this.noticeMin || 0)) this.noticeMin = h;
		this.notice.style.minHeight = this.noticeMin ? this.noticeMin + 'px' : '';
	},

	updateNotice: function() {
		var n = this.notice, sec, parts = [], mode;
		n.innerHTML = '';
		if (!this.drawMode && this.noticeMin) {
			this.noticeMin = 0;
			n.style.minHeight = '';
		}
		if (!this.zone)
			return;

		if (this.drawMode === 'circle') {
			n.appendChild(E('strong', {}, this.coarse() ? _('Tap the map where you want to allow servers. You can resize the circle afterwards.')
				: _('Click the map where you want to allow servers. You can resize the circle afterwards.')));
			this.holdNoticeHeight();
			return;
		}
		if (this.drawMode === 'polygon') {
			var k = this.draft.length, few = this.coarse()
				? _('Tap the map to place the corners of your region (%d so far). Two fingers move the map.')
				: _('Click the map to place the corners of your region (%d so far).');
			var enough = this.coarse()
				? _('%d corners - tap the first (big) corner or Finish polygon to close it. Undo corner takes the last one back.')
				: _('%d corners - click the first corner, double-click or press Enter to finish. Backspace takes the last corner back, Esc cancels.');
			/* room for the longer of the two texts from the start: the map must not move between taps */
			n.appendChild(E('strong', {}, (few.length > enough.length ? few : enough).format(99)));
			this.holdNoticeHeight();
			n.innerHTML = '';
			n.appendChild(E('strong', {}, (k < 3 ? few : enough).format(k)));
			this.holdNoticeHeight();
			return;
		}

		sec = uci.get('lobbyfence', this.zone) || {};
		mode = this.zoneMode();
		if (uci.get('lobbyfence', 'globals', 'enabled') !== '1')
			parts.push(E('span', { 'class': 'lf-warn' }, EMBED ? _('LobbyFence is switched off (Settings tab).') : _('LobbyFence is switched off (Zones page).')));
		if (sec.enabled !== '1')
			parts.push(E('span', { 'class': 'lf-warn' }, _('This zone is disabled.')));
		parts.push(mode === 'strict' ? _('Strict: only servers located inside your region (or allowed by you) get through.')
			: mode === 'enforce' ? _('Enforce: servers located outside your region are blocked; servers not located yet get through.')
			: _('Monitor: nothing is blocked - red dots show what would be.'));
		if (mode !== 'monitor' && !this.hasRegion())
			parts.push(E('span', { 'class': 'lf-warn' }, _('No region drawn yet - every server is blocked except your whitelist. Draw a circle or polygon.')));
		if (this.countries.length)
			parts.push(_('Also allowed: %s.').format(this.countries.join(', ')));
		if (this.flash)
			parts.push(E('strong', { 'class': 'lf-flash' }, this.flash));
		if (this.saving)
			parts.push(E('strong', {}, _('Saving…')));
		else if (this.pendingApply)
			parts.push(E('strong', {}, _('Changes saved - press Save & Apply to activate them.')));

		parts.forEach(function(p, i) {
			if (i) n.appendChild(document.createTextNode(' '));
			n.appendChild(typeof p === 'string' ? document.createTextNode(p) : p);
		});
	},

	/* ------------------------------------------------------ servers */

	/* the router's clock (servers are stamped with it), the browser's as fallback */
	routerNow: function() {
		return (this.live && this.live.time) || (this.status && this.status.updated) || Date.now() / 1000;
	},

	/* servers with packets in the last 30 s, straight from the router (null if unknown) */
	/* { ip: seconds since your device last sent to it } for servers active right now */
	activeSet: function() {
		var z = this.live && this.live.zones && this.live.zones[this.zone], set = {};
		if (!z || !z.active || typeof z.active !== 'object')
			return null;
		if (Array.isArray(z.active))
			z.active.forEach(function(ip) { set[ip] = 0; });
		else
			Object.keys(z.active).forEach(function(ip) { set[ip] = +z.active[ip] || 0; });
		return set;
	},

	/* { ip: packets per second } from the router; -1 = not measured yet */
	rateSet: function() {
		var z = this.live && this.live.zones && this.live.zones[this.zone];
		return (z && z.rate && typeof z.rate === 'object') ? z.rate : null;
	},

	/* real game traffic: at least 1 packet/s (keep-alive pings to allowed servers are
	 * much rarer); before a rate exists, a packet in the last 3 s counts */
	isActive: function(ip, act, rates) {
		if (!(ip in act)) return false;
		if (!rates) return true;   /* older router: no rates, trust its window */
		if (!(ip in rates) || rates[ip] < 0) return act[ip] <= 3;
		return rates[ip] >= 1;
	},

	activeWindow: function() {
		var z = this.live && this.live.zones && this.live.zones[this.zone];
		return (z && +z.active_window) || 15;
	},

	inRange: function(s, act, rates) {
		var secs = 0, r = this.range || 'active';
		if (r === 'active') {
			if (act === undefined) act = this.activeSet();
			if (act)
				return this.isActive(s.ip, act, rates === undefined ? this.rateSet() : rates);
			/* router too old for live traffic: fall back to "seen in the last ~2 passes" */
			secs = Math.max(90, 3 * (+(uci.get('lobbyfence', 'globals', 'interval')) || 20));
		}
		else
			RANGES.forEach(function(x) { if (x[0] === r) secs = x[1]; });
		return !secs || (s.ts > 0 && s.ts >= this.routerNow() - secs);
	},

	visibleServers: function() {
		var self = this, cc = this.ccFilter;
		/* the live lists are built once here, not once per server */
		var act = (this.range || 'active') === 'active' ? this.activeSet() : undefined, rates = this.rateSet();
		return this.servers.filter(function(s) { return self.inRange(s, act, rates) && (!cc || s.cc === cc); });
	},

	/* country dropdown: the countries of the servers in the chosen time range */
	renderCountries: function() {
		var self = this, counts = {}, sel = this.countrySelect, cur = this.ccFilter || '';
		if (!sel) return;
		this.servers.forEach(function(s) { if (s.cc && self.inRange(s)) counts[s.cc] = (counts[s.cc] || 0) + 1; });
		if (cur && !counts[cur]) counts[cur] = 0;
		var key = JSON.stringify(counts);
		if (key === this.ccKey) return;
		this.ccKey = key;
		sel.innerHTML = '';
		sel.appendChild(E('option', { 'value': '' }, _('All countries')));
		Object.keys(counts).sort().forEach(function(cc) {
			sel.appendChild(E('option', { 'value': cc }, flag(cc) + ' ' + cc + ' (' + counts[cc] + ')'));
		});
		sel.value = cur;
	},

	confirmForgetAll: function() {
		var self = this, zone = this.zone;
		if (!zone) return;
		ui.showModal(_('Clear learned servers'), [
			E('p', {}, _('Forget all %d servers this zone has learned? They are learned again the next time the game uses them. In strict mode a forgotten server is blocked until it has been located again (usually within a minute).').format(this.servers.length)),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function() {
					ui.hideModal();
					self.forget([]);
				} }, _('Clear'))
			])
		]);
	},

	forget: function(ips) {
		var self = this;
		return fs.exec('/usr/sbin/lobbyfence', [ 'forget', this.zone ].concat(ips)).then(function(res) {
			if (res.code !== 0)
				ui.addNotification(null, E('p', {}, (res.stderr || res.stdout || '').trim() || _('Could not forget the servers.')), 'error');
			if (self.popup) self.popup.remove();
			return self.refresh();
		});
	},

	/* geography only: in / out / unknown */
	/* while (re)drawing many servers: remember each location's answer for the
	 * current region (thousands of servers share a few hundred places) */
	beginClassify: function() {
		var sig = JSON.stringify([ this.zone, this.circles[this.zone] || [], (this.polygons || {})[this.zone] || [], this.countries ]);
		if (!this.clsCache || this.clsCache.sig !== sig)
			this.clsCache = { sig: sig, map: {} };
		this.clsOn = true;
	},
	endClassify: function() {
		this.clsOn = false;
	},

	classifyFast: function(s) {
		if (this.clsOn && this.clsCache && s.lat != null) {
			var key = s.lat + ',' + s.lon + ',' + s.cc, m = this.clsCache.map;
			return key in m ? m[key] : (m[key] = this.classify(s));
		}
		return this.classify(s);
	},

	classify: function(s) {
		var list = this.circles[this.zone] || [], polys = (this.polygons && this.polygons[this.zone]) || [], i;
		if (s.lat == null || s.lon == null)
			return 'unknown';
		if (!list.length && !polys.length && !this.countries.length)
			return 'out';   /* no region drawn yet: nothing is inside */
		if (this.countries.indexOf(String(s.cc).toUpperCase()) >= 0)
			return 'in';
		for (i = 0; i < list.length; i++)
			if (distanceKm(s.lat, s.lon, list[i].lat, list[i].lon) <= list[i].r)
				return 'in';
		for (i = 0; i < polys.length; i++)
			if (inPolygon(polys[i], s.lat, s.lon))
				return 'in';
		return 'out';
	},

	/* your own rules win, exactly like on the router: allow first, then block */
	ruleFor: function(ip) {
		var r = this.rules || {};
		if (inList(r.allow, ip)) return 'allow';
		if (inList(r.block, ip)) return 'block';
		return '';
	},

	effective: function(s) {
		var rule = this.ruleFor(s.ip);
		return rule === 'allow' ? 'in' : rule === 'block' ? 'out' : (this.clsOn ? this.classifyFast(s) : this.classify(s));
	},

	/* km between a server and the nearest circle edge (null without circles) */
	kmOutside: function(s) {
		var list = this.circles[this.zone] || [], best = null;
		list.forEach(function(c) {
			var d = distanceKm(s.lat, s.lon, c.lat, c.lon) - c.r;
			if (best === null || d < best) best = d;
		});
		return best;
	},

	serverFeatures: function() {
		var self = this, groups = {}, act = this.range === 'active' ? this.activeSet() : null, win = this.activeWindow();
		this.beginClassify();
		this.visibleServers().forEach(function(s) {
			if (s.lat == null)
				return;
			var state = self.effective(s), manual = self.ruleFor(s.ip);
			var key = s.lat.toFixed(2) + ',' + s.lon.toFixed(2) + ',' + state + ',' + manual;
			var g = (groups[key] = groups[key] || { lat: s.lat, lon: s.lon, cc: s.cc, state: state, manual: manual, ips: [], age: Infinity });
			g.ips.push(s.ip);
			if (act && s.ip in act) g.age = Math.min(g.age, act[s.ip]);
		});
		this.endClassify();
		return Object.keys(groups).map(function(k) {
			var g = groups[k];
			return {
				type: 'Feature',
				geometry: { type: 'Point', coordinates: [ g.lon, g.lat ] },
				/* dots fade as the server goes quiet (Active now) */
				properties: { state: g.state, manual: g.manual, cc: g.cc, count: g.ips.length, ips: g.ips.join(' '),
					fade: isFinite(g.age) ? Math.max(0.3, 0.95 - 0.65 * Math.min(1, g.age / win)) : 0.9 }
			};
		});
	},

	drawServers: function() {
		if (!this.map || !this.styleReady || !this.map.getSource('lf-servers'))
			return;
		this.map.getSource('lf-servers').setData({ type: 'FeatureCollection', features: this.serverFeatures() });
	},

	/* popup for one map dot: the servers there and allow / block buttons */
	popupNode: function(ips, cc) {
		var self = this, mode = this.zoneMode(), rules = ips.map(function(ip) { return self.ruleFor(ip); });
		var anyRule = rules.some(function(r) { return r; });
		var state = this.effective({ ip: ips[0], lat: this.popupAt ? this.popupAt[1] : null, lon: this.popupAt ? this.popupAt[0] : null, cc: cc || '' });
		var verdict = state === 'in' ? _('allowed') : (mode === 'monitor' ? _('would be blocked') : _('blocked'));
		var one = ips.length === 1, rule = rules[0];

		function act(action, label, primary) {
			return E('button', {
				'class': 'lf-btn lf-sm' + (primary ? ' lf-primary' : ''),
				'click': ui.createHandlerFn(self, 'setRule', action, ips)
			}, label);
		}

		var actions = [];
		if (one && rule === 'allow')
			actions = [ act('block', _('Block instead')), act('unlist', _('Remove rule')) ];
		else if (one && rule === 'block')
			actions = [ act('allow', _('Allow instead')), act('unlist', _('Remove rule')) ];
		else if (one)
			actions = [ act('allow', _('Always allow'), state !== 'in'), act('block', _('Always block'), state === 'in') ];
		else
			actions = [ act('allow', _('Allow all %d').format(ips.length)), act('block', _('Block all %d').format(ips.length)) ]
				.concat(anyRule ? [ act('unlist', _('Remove rules')) ] : []);

		return E('div', {}, [
			E('strong', {}, ips.length + ' ' + verdict),
			cc ? ' · ' + flag(cc) + ' ' + cc : '',
			(function() {
				var hk = self.home() && self.popupAt ? distanceKm(self.home().lat, self.home().lon, self.popupAt[1], self.popupAt[0]) : null;
				return hk !== null ? E('div', { 'class': 'lf-muted lf-sm' }, _('%s km from home').format(fmtNum(Math.round(hk)))) : '';
			})(),
			E('div', { 'class': 'lf-pop-ips lf-ip' }, ips.slice(0, 8).map(function(ip, i) {
				return E('div', {}, [ ip, rules[i] ? E('span', { 'class': 'lf-badge' }, rules[i] === 'allow' ? _('allowed by you') : _('blocked by you')) : '' ]);
			}).concat(ips.length > 8 ? [ E('div', { 'class': 'lf-muted' }, '… +' + (ips.length - 8)) ] : [])),
			one && rule ? E('div', { 'class': 'lf-pop-rule lf-sm' }, rule === 'allow'
				? _('You always allow this server, wherever it is.') : _('You always block this server, wherever it is.')) : '',
			E('div', { 'class': 'lf-pop-actions' }, actions.concat([ E('button', {
				'class': 'lf-btn lf-sm', 'title': _('Remove from the learned servers (it is learned again when used)'),
				'click': ui.createHandlerFn(self, 'forget', ips)
			}, _('Forget')) ]))
		]);
	},

	openPopup: function(coords, ips, cc) {
		if (!this.map || !this.ml)
			return;
		if (this.popup)
			this.popup.remove();
		this.popupAt = coords;
		this.popupIps = ips;
		this.popupCc = cc;
		this.popup = new this.ml.Popup({ closeButton: true, maxWidth: '280px' })
			.setLngLat(coords)
			.setDOMContent(this.popupNode(ips, cc))
			.addTo(this.map);
	},

	/* allow / block / unlist via the router - takes effect immediately */
	setRule: function(action, ips) {
		var self = this, zone = this.zone;
		return fs.exec('/usr/sbin/lobbyfence', [ action, zone ].concat(ips)).then(function(res) {
			var out = null;
			try { out = JSON.parse((res.stdout || '').trim()); } catch (e) {}
			if (!out || !out.ok) {
				var msg = (res.stderr || res.stdout || '').trim();
				ui.addNotification(null, E('p', {}, /no such zone/.test(msg)
					? _('Press Save & Apply first - the router does not know this zone yet.')
					: _('Could not change the rule: %s').format(msg || _('no answer'))), 'error');
				return;
			}
			if (zone === self.zone)
				self.rules = { allow: out.allow || [], block: out.block || [] };
			self.renderRegions();
			self.drawServers();
			self.renderServers();
			if (self.popup && self.popupIps)
				self.popup.setDOMContent(self.popupNode(self.popupIps, self.popupCc));
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, err.message), 'error');
		});
	},

	focusServer: function(s) {
		if (s.lat == null)
			return;
		this.flyTo([ s.lon, s.lat ], 4);
		this.openPopup([ s.lon, s.lat ], [ s.ip ], s.cc);
	},

	renderServers: function() {
		var self = this, t = this.theme().overlay, groups = { 'in': [], out: [], unknown: [] }, list, rows, q = this.filter;
		var mode = this.zoneMode(), now = this.routerNow(), scroll = this.listNode.scrollTop;
		var act = this.range === 'active' ? this.activeSet() : null;

		this.renderCountries();
		this.beginClassify();
		this.visibleServers().forEach(function(s) { groups[self.effective(s)].push(s); });
		this.endClassify();

		var tabs = [
			[ 'in', _('Allowed'), t.allowed ],
			[ 'out', mode === 'monitor' ? _('Would block') : _('Blocked'), t.blocked ],
			[ 'unknown', _('Unknown'), t.unknown ]
		];
		this.tabsNode.innerHTML = '';
		tabs.forEach(function(tab) {
			self.tabsNode.appendChild(E('button', {
				'class': 'lf-tab' + (self.tab === tab[0] ? ' lf-on' : ''),
				'data-tab': tab[0],
				'click': function(ev) { ev.preventDefault(); self.tab = tab[0]; self.renderServers(); }
			}, [ dot(tab[2]), tab[1], E('span', { 'class': 'lf-muted' }, String(groups[tab[0]].length)) ]));
		});

		this.listNode.innerHTML = '';
		if (!this.zone) {
			this.listNode.appendChild(E('div', { 'class': 'lf-empty' }, _('Create a zone to start learning servers.')));
			return;
		}

		list = groups[this.tab].filter(function(s) {
			return !q || s.ip.toLowerCase().indexOf(q) >= 0 || s.cc.toLowerCase() === q;
		}).sort(function(a, b) { return b.ts - a.ts; });

		if (this.tab === 'out' && mode === 'monitor' && groups.out.length)
			this.listNode.appendChild(E('div', { 'class': 'lf-empty lf-sm' },
				_('Monitor mode: these servers are still reachable. They are blocked once the zone is set to Strict or Enforce.')));
		if (this.tab === 'unknown' && mode === 'strict' && groups.unknown.length)
			this.listNode.appendChild(E('div', { 'class': 'lf-empty lf-sm' },
				_('Strict mode blocks these until they are located (usually within a minute). Allow one by clicking it if you need it now.')));

		if (!list.length) {
			this.listNode.appendChild(E('div', { 'class': 'lf-empty' }, q
				? _('No server matches your search.')
				: this.servers.length && this.range !== 'all' && !this.visibleServers().length
					? (this.range === 'active' ? _('No server is in use right now. Choose "Last hour" or "All learned" to see earlier ones.')
						: _('No server was used in this period. Choose "All learned" to see older ones.'))
				: (this.tab === 'in' ? _('No allowed servers learned yet. Play a match and they will appear here.')
				: this.tab === 'out' ? _('No servers outside your region so far.')
				: _('Every learned server has been located.'))));
			return;
		}

		rows = list.slice(0, MAX_ROWS).map(function(s) {
			var parts = [], km, rule = self.ruleFor(s.ip);
			if (rule)
				parts.push(rule === 'allow' ? _('allowed by you') : _('blocked by you'));
			if (s.lat == null)
				parts.push(s.state === 'unloc' ? _('could not be located') : _('waiting for location'));
			else if (self.tab === 'out' && !rule && (km = self.kmOutside(s)) !== null && km > 0)
				parts.push(_('%s km outside').format(fmtNum(Math.round(km))));
			var hk = self.homeKm(s);
			if (hk !== null)
				parts.push(_('%s km from home').format(fmtNum(Math.round(hk))));
			var rt = self.rateSet();
			if (act && s.ip in act)
				parts.push(rt && rt[s.ip] >= 1 ? _('%s packets/s').format(fmtNum(Math.round(rt[s.ip])))
					: act[s.ip] <= 1 ? _('traffic now') : _('last traffic %d s ago').format(act[s.ip]));
			else if (s.ts)
				parts.push(_('seen %s').format(ago(s.ts, now)));

			return E('div', {
				'class': 'lf-row',
				'title': s.lat == null ? _('Not located yet') : _('Show on map'),
				'click': function() {
					if (s.lat == null)
						self.openRuleDialog(s);
					else
						self.focusServer(s);
				}
			}, [
				dot(self.tab === 'in' ? t.allowed : self.tab === 'out' ? t.blocked : t.unknown),
				E('div', { 'class': 'lf-row-main' }, [
					E('div', { 'class': 'lf-ip' }, s.ip),
					parts.length ? E('div', { 'class': 'lf-muted lf-sm' }, parts.join(' · ')) : ''
				]),
				s.cc ? E('span', { 'class': 'lf-sm', 'title': s.cc }, flag(s.cc) + ' ' + s.cc) : ''
			]);
		});
		rows.forEach(function(r) { self.listNode.appendChild(r); });
		if (list.length > MAX_ROWS)
			this.listNode.appendChild(E('div', { 'class': 'lf-empty lf-sm' },
				_('%d more - narrow it down with the search box.').format(list.length - MAX_ROWS)));
		this.listNode.scrollTop = scroll;
	},

	/* servers without a location have no dot - allow / block them from the list */
	openRuleDialog: function(s) {
		var self = this, rule = this.ruleFor(s.ip);
		function btn(action, label) {
			return E('button', {
				'class': 'cbi-button', 'click': function() { ui.hideModal(); self.setRule(action, [ s.ip ]); }
			}, label);
		}
		ui.showModal(s.ip, [
			E('p', {}, s.state === 'unloc' ? _('The geolocation service could not locate this server.') : _('This server has not been located yet.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')), ' ',
				rule ? btn('unlist', _('Remove rule')) : '', ' ',
				rule !== 'block' ? btn('block', _('Always block')) : '', ' ',
				rule !== 'allow' ? btn('allow', _('Always allow')) : ''
			])
		]);
	},

	/* ------------------------------------------------------- status */

	renderStatus: function() {
		var self = this, t = this.theme().overlay, st = this.status, z = this.zoneStatus(), sec = this.statusSec;
		var enabled = uci.get('lobbyfence', 'globals', 'enabled') === '1', geo = st && st.geo, api, res = this.apiResult;

		/* one status line: coloured dot + text that may wrap under itself */
		function line(colour, content, cls) {
			return E('div', { 'class': 'lf-status' + (cls ? ' ' + cls : '') }, [
				dot(colour), E('span', { 'class': 'lf-status-text' }, content)
			]);
		}
		function muted(text) {
			return E('span', { 'class': 'lf-muted' }, ' · ' + text);
		}

		sec.innerHTML = '';
		sec.appendChild(E('h4', {}, _('Status')));
		this.renderLag();

		if (!enabled)
			sec.appendChild(line(t.unknown, _('LobbyFence is off')));
		else if (this.running)
			sec.appendChild(line(t.allowed, [ _('Running'), st && st.active ? muted(_('rules loaded'))
				: E('span', { 'class': 'lf-warn' }, ' · ' + _('rules not loaded')) ]));
		else
			sec.appendChild(line(t.blocked, [ _('Not running'), ' ', E('button', {
				'class': 'lf-btn lf-sm lf-primary',
				'click': ui.createHandlerFn(this, 'startService')
			}, _('Start LobbyFence')) ]));

		/* the game (preset) the zone filters, and a way to switch it */
		if (this.zone && uci.get('lobbyfence', this.zone)) {
			var gp = this.zonePreset();
			sec.appendChild(E('div', { 'class': 'lf-line lf-zonegame', 'style': 'margin:6px 0 0' }, [
				E('span', { 'class': 'lf-muted lf-sm' }, _('Game') + ':'),
				E('span', { 'class': 'lf-sm', 'style': 'flex:1;min-width:0' }, gp ? (gp.custom ? _('Custom ports') : gp.label + (needsPlatform(gp) && platformName((uci.get('lobbyfence', self.zone) || {}).platform) ? ' · ' + platformName(uci.get('lobbyfence', self.zone).platform) : '') + (self.portsNarrowed(gp) ? ' · ' + _('own ports') : '')) : _('Custom ports')),
				E('button', { 'class': 'lf-btn lf-sm lf-portsseen', 'title': _('The server ports this zone\'s device used while playing - narrow the zone to its game\'s real ports'),
					'click': function(ev) { ev.preventDefault(); self.openPortsSeen(); } }, _('Ports…')),
				E('button', { 'class': 'lf-btn lf-sm lf-changegame', 'title': _('Switch this zone to another game preset (its ports and recommended settings); the device and the region stay'),
					'click': function(ev) { ev.preventDefault(); self.openChangeGame(); } }, _('Change…'))
			]));
		}

		/* filtering mode of the shown zone */
		if (this.zone && uci.get('lobbyfence', this.zone)) {
			var cur = this.zoneMode();
			sec.appendChild(E('div', { 'class': 'lf-line', 'style': 'margin:6px 0' }, [
				E('span', { 'class': 'lf-muted lf-sm' }, _('Filtering') + ':'),
				E('span', { 'class': 'lf-seg' }, [
					[ 'strict', _('Strict') ], [ 'enforce', _('Enforce') ], [ 'monitor', _('Monitor') ]
				].map(function(m) {
					return E('button', {
						'class': 'lf-btn lf-sm' + (cur === m[0] ? ' lf-on' : ''),
						'data-mode': m[0],
						'click': function(ev) { ev.preventDefault(); self.setZoneMode(m[0]); }
					}, m[1]);
				}))
			]));
		}

		if (this.zone && uci.get('lobbyfence', this.zone))
			this.renderBurst(sec, line);

		z = this.zoneLive();
		if (z && z.enabled) {
			sec.appendChild(E('div', { 'class': 'lf-muted lf-sm', 'style': 'margin:2px 0 6px 15px' },
				_('Game packets: %s').format(fmtNum(z.packets)) + ' · ' +
				(z.mode === 'enforce' ? _('Blocked: %s') : _('Would block: %s')).format(fmtNum(z.blocked))));

			/* where the device is, and why nothing may show up yet */
			var devs = z.devices || [], v4 = devs.filter(function(a) { return a.indexOf(':') < 0; });
			if (z.macs && !devs.length)
				sec.appendChild(line(t.blocked, E('span', { 'class': 'lf-warn' },
					_('Device not seen on the network - is it connected? (looked up by MAC address)')), 'lf-sm'));
			else if (devs.length)
				sec.appendChild(line(t.allowed, _('Device at %s').format(
					(v4.length ? v4.join(', ') : devs[0]) + (devs.length > v4.length && v4.length ? ' ' + _('+ %d IPv6').format(devs.length - v4.length) : '')), 'lf-sm'));
			if (this.running && !z.packets)
				sec.appendChild(line(t.unknown, E('span', { 'class': 'lf-warn' },
					_('No game traffic from this device yet. Play a match - if this stays at 0, the device or the ports are wrong (the "Any game" preset catches everything).')), 'lf-sm'));
		}

		if (st && st.offload && DDWRT)
			sec.appendChild(line(t.blocked, E('span', { 'class': 'lf-warn' },
				_('The SFE fast path is on: a connection that is already running skips the filter after its first 128 packets. New servers are still checked. For full filtering set Setup → Basic Setup → Shortcut Forwarding Engine to CTF (or Disable).')), 'lf-sm'));
		else if (st && st.offload)
			sec.appendChild(line(t.blocked, E('span', { 'class': 'lf-warn' }, st.conntrack
				? _('Flow offloading is on - blocked connections are cut, but turning it off (Network → Firewall) is more reliable.')
				: _('Flow offloading is on: a connection that is already running is not cut when its server gets blocked. Turn it off under Network → Firewall → Routing/NAT Offloading, or install the "conntrack" package.')), 'lf-sm'));

		/* geolocation API health, from the router's own bookkeeping */
		if (geo && geo.error)
			api = line(t.blocked, [ _('API problem: '), E('span', { 'class': 'lf-muted' }, geo.error) ]);
		else if (geo && geo.last_ok)
			api = line(t.allowed, [ _('API OK'), muted(_('last lookup %s').format(ago(geo.last_ok, self.routerNow()))) ]);
		else
			api = line(t.unknown, _('API not used yet'));
		if (geo && geo.pending)
			api.lastChild.appendChild(muted(_('%d waiting').format(geo.pending)));
		sec.appendChild(api);

		/* problems the router recorded: the background service crashing, the last error
		   (their times are the router's, so they're measured by its clock, not this PC's) */
		var pr = st && st.problems, nowS = self.routerNow();
		if (pr && pr.crashes > 0 && nowS - pr.crash_time < 7 * 86400)
			sec.appendChild(line(t.blocked, [ E('span', { 'class': 'lf-warn' }, pr.crashes > 1
				? _('The background service stopped unexpectedly %d times (last %s) and was started again.').format(pr.crashes, ago(pr.crash_time, nowS))
				: _('The background service stopped unexpectedly (%s) and was started again.').format(ago(pr.crash_time, nowS))), ' ',
				E('a', { 'href': '#', 'class': 'lf-link', 'click': function(ev) { ev.preventDefault(); self.openDebug(); } }, _('Details…')) ], 'lf-sm lf-problem'));
		if (pr && pr.error && nowS - pr.error_time < 86400)
			sec.appendChild(line(t.blocked, [ _('Last error, %s: ').format(ago(pr.error_time, nowS)), E('span', { 'class': 'lf-muted' }, pr.error) ], 'lf-sm lf-problem'));

		if (res)
			sec.appendChild(res.ok
				? line(t.allowed, _('Test passed: %s → %s %s in %d ms').format(res.ip, flag(res.country), res.country, res.ms), 'lf-sm')
				: line(t.blocked, E('span', { 'class': 'lf-bad' }, _('Test failed: %s').format(res.error)), 'lf-sm'));

		sec.appendChild(E('div', { 'class': 'lf-line', 'style': 'margin-top:8px' }, [
			E('button', {
				'class': 'lf-btn lf-sm',
				'title': _('Ask the geolocation service where 8.8.8.8 is, from the router'),
				'click': ui.createHandlerFn(this, 'testApi')
			}, _('Test API')),
			E('button', {
				'class': 'lf-btn lf-sm',
				'title': _('Collect and locate new servers now'),
				'click': ui.createHandlerFn(this, 'runCycle')
			}, _('Learn now')),
			E('button', {
				'class': 'lf-btn lf-sm lf-debugbtn',
				'title': _('Something not working? Download a report with the logs, crashes and settings, for finding the problem'),
				'click': function(ev) { ev.preventDefault(); self.openDebug(); }
			}, _('Debug…')),
			E('button', {
				'class': 'lf-btn lf-sm lf-serversbtn',
				'title': _('Download the servers LobbyFence has located, by game - or import a file from another router, so those servers are not looked up again'),
				'click': function(ev) { ev.preventDefault(); self.openServersFile(); }
			}, _('Servers file…'))
		]));
		sec.appendChild(this.fillVersion(E('div', { 'class': 'lf-version lf-panel-version', 'style': 'margin-top:6px' })));
	},

	/* ------------------------------------------- lag simulator (netem) */

	renderLag: function() {
		var self = this, sec = this.lagSec, zone = this.zone, t = this.theme().overlay;
		var st = this.status, z = this.zoneStatus(), lag = (z && z.lag) || {};
		if (!sec) return;
		sec.innerHTML = '';
		if (!zone || !uci.get('lobbyfence', zone) || (st && st.lag_supported === false)) {
			/* no netem for this router's kernel: nothing to offer */
			sec.style.display = 'none';
			return;
		}
		sec.style.display = '';
		var on = uci.get('lobbyfence', zone, 'lag') === '1';
		var get = function(o, d) { var v = uci.get('lobbyfence', zone, o); return (v == null || v === '') ? d : v; };

		function save(opt, v) {
			uci.set('lobbyfence', zone, opt, String(v));
			self.stage();
			self.renderLag();
		}
		function num(opt, label, unit, max, step, hint) {
			var input = E('input', {
				'type': 'number', 'class': 'lf-input lf-lag-' + opt, 'min': 0, 'max': max, 'step': step, 'value': get(opt, '0'),
				'style': 'width:70px;padding:2px 5px;font-size:12px', 'title': hint,
				'change': function() {
					var v = parseFloat(this.value);
					if (!isFinite(v) || v < 0 || v > max) { this.value = get(opt, '0'); return; }
					save(opt, step < 1 ? +v.toFixed(2) : Math.round(v));
				}
			});
			return E('label', { 'class': 'lf-lagrow', 'title': hint }, [ E('span', {}, label), E('span', { 'class': 'lf-lagin' }, [ input, ' ', unit ]) ]);
		}
		function list(cls, mark, items) {
			return E('ul', { 'class': 'lf-wlist ' + cls }, items.map(function(x) {
				return E('li', {}, [ E('span', { 'class': 'lf-wmark', 'aria-hidden': 'true' }, mark), E('span', {}, x) ]);
			}));
		}

		var toggle = E('label', { 'class': 'lf-switch', 'title': _('Switch the lag simulator on or off for this zone') }, [
			E('input', { 'type': 'checkbox', 'change': function() { save('lag', this.checked ? 1 : 0); } }),
			E('span', {}, on ? _('On') : _('Off'))
		]);
		toggle.firstChild.checked = on;

		var help = E('div', { 'class': 'lf-laghelp', 'style': this.lagHelp ? '' : 'display:none' }, [
			E('p', {}, _('Makes this device\'s game connection worse on purpose, so you can feel how a game plays on a bad connection - or test a setup before a match.')),
			E('h4', { 'class': 'lf-wcan' }, _('What it can do')),
			list('lf-wyes', '✓', [
				_('Add extra ping (e.g. +50 ms) - on the download, the upload, or both.'),
				_('Make the ping jump up and down (jitter).'),
				_('Lose some packets on purpose (packet loss), like a weak Wi-Fi.'),
				_('Only this zone\'s device and game are affected - everyone else is normal.'),
				_('Switch it off and everything is back to normal at once.')
			]),
			E('h4', { 'class': 'lf-wcant' }, _('What it can\'t do')),
			list('lf-wno', '✗', [
				_('It can\'t lower your ping or make anything faster - it only adds lag.'),
				_('It can\'t change other players\' ping or the game server.'),
				_('It doesn\'t pick different servers or lobbies - that is the region\'s job.'),
				TOMATO ? _('It doesn\'t work while QoS or the bandwidth limiter is on.')
					: DDWRT ? _('It doesn\'t work while QoS is on, and the SFE fast path makes it miss packets.')
					: MERLIN ? _('It can\'t be used by more than 12 zones at the same time.')
					: _('It doesn\'t work while flow offloading is on, and needs a few router packages (see below).')
			])
		]);

		sec.appendChild(E('div', { 'class': 'lf-laghead' }, [
			E('h4', {}, _('Lag simulator')),
			E('button', { 'class': 'lf-btn lf-sm', 'title': _('What does this do?'), 'click': function(ev) {
				ev.preventDefault(); self.lagHelp = !self.lagHelp; help.style.display = self.lagHelp ? '' : 'none';
			} }, '?'),
			E('span', { 'class': 'lf-spacer' }),
			toggle
		]));
		sec.appendChild(help);
		if (!on) {
			sec.appendChild(E('div', { 'class': 'lf-muted lf-sm' }, _('Off - your connection is not changed. Press ? to see what it does.')));
			return;
		}
		var dir = get('lag_direction', 'both');
		var DIRS = [
			[ 'both', _('Both ways'), _('Split half and half between download and upload - the extra ping adds up to the number below.') ],
			[ 'down', _('Download only'), _('Server → you: what you see and hear from the game arrives late.') ],
			[ 'up', _('Upload only'), _('You → server: your moves and shots reach the server late.') ]
		];
		var dirSel = E('select', { 'class': 'lf-select lf-lag-lag_direction', 'style': 'font-size:12px;padding:2px 5px',
			'change': function() { save('lag_direction', this.value); } },
			DIRS.map(function(x) { return E('option', { 'value': x[0] }, x[1]); }));
		dirSel.value = dir;
		sec.appendChild(E('label', { 'class': 'lf-lagrow' }, [ E('span', {}, _('Direction')), dirSel ]));
		sec.appendChild(E('div', { 'class': 'lf-muted', 'style': 'font-size:11.5px;margin:-1px 0 4px' },
			(DIRS.filter(function(x) { return x[0] === dir; })[0] || DIRS[0])[2]));
		sec.appendChild(num('lag_delay', _('Extra ping'), 'ms', 5000, 1, _('Added to your ping (0-5000 ms)')));
		sec.appendChild(num('lag_jitter', _('Jitter (ping jumps by up to)'), 'ms', 2000, 1, _('How much the extra ping varies, up and down')));
		sec.appendChild(num('lag_loss', _('Packet loss'), '%', 100, 0.1, _('Share of packets that are thrown away (0-100 %)')));

		/* what the router reports */
		var tc = st ? st.tc : null, pkg = st && st.pkg === 'apk' ? 'apk add' : 'opkg update && opkg install';
		var need = pkg + ' tc-full kmod-netem kmod-ifb kmod-sched-core' + (dir !== 'down' ? ' kmod-sched-ctinfo' : '');
		function lineMsg(colour, content) {
			return E('div', { 'class': 'lf-status lf-sm' }, [ dot(colour), E('span', { 'class': 'lf-status-text' }, content) ]);
		}
		var nothing = !(+get('lag_delay', 0)) && !(+get('lag_jitter', 0)) && !(+get('lag_loss', 0));
		if (nothing)
			sec.appendChild(lineMsg(t.unknown, _('Set some extra ping, jitter or loss - with all at 0 nothing changes.')));
		else if (this.pendingApply || this.saving || !lag.on)
			sec.appendChild(lineMsg(t.unknown, _('Press Save & Apply to start it.')));
		else if (lag.active)
			sec.appendChild(lineMsg('#f59e0b', [ E('strong', {}, _('Active (%s): +%d ms ping, ±%d ms jitter, %s loss').format(
				{ both: _('both ways'), down: _('download only'), up: _('upload only') }[lag.dir || 'both'] || lag.dir,
				lag.delay, lag.jitter, String(lag.loss) + ' %')),
				MERLIN && st && st.lag_kind ? E('span', { 'class': 'lf-muted', 'title': st.lag_kind === 'netem'
					? _('The kernel\'s own network emulator (netem) adds the lag.')
					: _('LobbyFence\'s helper (lf-lagd) adds the lag - this router has no netem LobbyFence can use.') },
					' · ' + (st.lag_kind === 'netem' ? 'netem' : 'lf-lagd')) : '' ]));
		else if (EMBED && lag.error) {
			var whyT = { nonetem: _('LobbyFence has no netem module for this firmware\'s kernel (%s).').format(st && st.kernel || '?'),
				netemrefused: _('The router\'s kernel refused LobbyFence\'s netem module - it was built for a different firmware build. Nothing was changed.'),
				netemcrash: _('The router restarted while the lag simulator was using netem (perhaps the netem module crashed it), so netem is not used again. If the restart had another cause (a power cut, say), delete %s over SSH and press Save & Apply.').format(MERLIN ? '/jffs/addons/lobbyfence/.netem-loading' : '/jffs/lobbyfence/.netem-loading'),
				selftest: _('The netem module failed its self-test on this router, so it is not used.'),
				noclassify: _('This firmware\'s firewall can\'t pick the lag queue (CLASSIFY is missing).'),
				busy: _('QoS or the bandwidth limiter is using the connection. Turn them off (Advanced › QoS / Bandwidth Limiter), then press Save & Apply.'),
				notc: _('The router\'s traffic control (tc) refused the setup.'), nofilter: _('The router\'s traffic control refused the setup.'),
				nowan: _('No internet connection found for the upload side.'),
				toomany: _('At most 12 zones can use the lag simulator at the same time - switch it off in another zone.'),
				noqueue: _('This firmware\'s kernel has no packet queue (NFQUEUE), which the lag simulator needs on this router.'),
				lagdfail: _('The lag simulator\'s helper (lf-lagd) keeps stopping - see the System Log (lines with "lobbyfence"), then press Save & Apply.') }[lag.error] || _('The lag simulator could not start (%s).').format(lag.error);
			sec.appendChild(lineMsg(t.blocked, E('span', { 'class': 'lf-warn' }, whyT)));
		}
		else if (tc === false || lag.error) {
			var why = { notc: _('The "tc" program is missing.'), noifb: _('The ifb kernel module is missing.'),
				nonetem: _('The netem kernel module is missing.'), noclsact: _('The router\'s traffic control is missing.'),
				noctinfo: _('Upload lag needs the ctinfo kernel module, which is missing.'),
				nofilter: _('The router\'s traffic control is missing a part.') }[lag.error] || _('Router packages are missing.');
			sec.appendChild(lineMsg(t.blocked, [ E('span', { 'class': 'lf-warn' }, why + ' ' + _('Install them once over SSH, then press Save & Apply:')),
				E('code', { 'class': 'lf-cmd' }, need) ]));
		}
		if (st && st.offload)
			sec.appendChild(lineMsg(t.blocked, E('span', { 'class': 'lf-warn' }, DDWRT
				? _('The SFE fast path is on, so most game packets skip the lag. Set Setup → Basic Setup → Shortcut Forwarding Engine to CTF (or Disable).')
				: _('Flow offloading is on, so most game packets skip the lag. Turn it off under Network → Firewall → Routing/NAT Offloading.'))));
	},

	/* the game preset a zone was made from (stored, or recognised from its ports) */
	zoneGame: function(zone) {
		var z = zone || this.zone, id = uci.get('lobbyfence', z, 'game'), p = presetById(id);
		if (p && p.burst != null)
			return p;
		if (p)
			return null;
		var label = String(uci.get('lobbyfence', z, 'label') || '').toLowerCase();
		if (/apex/.test(label)) return presetById('apex');
		if (/call of duty|\bcod\b|warzone/.test(label)) return presetById(/mobile/.test(label) ? 'codm' : 'cod');
		return null;
	},

	/* "Open for server tests" settings and live state */
	renderBurst: function(sec, line) {
		var self = this, t = this.theme().overlay, zone = this.zone, z = this.zoneLive() || {};
		var bs = uci.get('lobbyfence', zone, 'burst_servers');
		var n = (bs == null || bs === '') ? 0 : +bs, open = +(uci.get('lobbyfence', zone, 'burst_open') || 20);

		function num(opt, value, min, max, title) {
			return E('input', {
				'type': 'number', 'class': 'lf-input lf-burst-' + opt, 'min': min, 'max': max, 'step': 1, 'value': value,
				'title': title, 'style': 'width:62px;padding:2px 5px;font-size:12px',
				'change': function() {
					var v = parseInt(this.value, 10);
					if (!isFinite(v) || v < min || v > max) { this.value = value; return; }
					uci.set('lobbyfence', zone, opt, String(v));
					self.stage();
					self.renderStatus();
				}
			});
		}

		sec.appendChild(E('div', { 'class': 'lf-line lf-sm', 'style': 'margin:4px 0',
			'title': _('When this zone sees more than this many servers at once (a game testing data centres while you log in), all servers are let through for a short while. Your region applies again as soon as it is over.') + ' ' + _('0 = off (the default, and recommended). Keep it at 0 for games with strict server checks such as Apex Legends. Whether a game needs it varies: only raise it if logging in or matchmaking fails while filtering. Games such as Call of Duty do not need it.') }, [
			E('span', { 'class': 'lf-muted', 'style': 'flex-basis:100%' }, _('Open for server tests') + (n > 0 ? '' : ' (' + _('off') + ')') + ':'),
			E('span', { 'style': 'white-space:nowrap;display:inline-flex;gap:4px;align-items:center' }, [
				_('more than'), num('burst_servers', n, 0, 10000, _('Servers at once (0 = off)')), _('servers')
			]),
			E('span', { 'style': 'white-space:nowrap;display:inline-flex;gap:4px;align-items:center' }, [
				'→ ' + _('open for'), num('burst_open', open, 1, 3600, _('Seconds the zone stays open after the last burst')), 's'
			]),
			E('span', { 'class': 'lf-muted', 'style': 'flex-basis:100%;font-size:11.5px;line-height:1.35' },
				burstAdvice(this.zoneGame()))
		]));

		var left = this.openLeft();
		if (n > 0 && left > 0)
			sec.appendChild(line('#f59e0b', E('strong', {}, [
				_('Open for server tests - all servers allowed'), ' (',
				E('span', { 'class': 'lf-open-left' }, String(left)), _(' s left)')
			]), 'lf-sm'));
		else if (n > 0 && z.opened > 0)
			sec.appendChild(E('div', { 'class': 'lf-muted lf-sm', 'style': 'margin:0 0 4px 15px' },
				_('%s packets let through during server tests').format(fmtNum(z.opened))));
	},

	openLeft: function() {
		return this.openUntil ? Math.max(0, Math.ceil((this.openUntil - Date.now()) / 1000)) : 0;
	},

	/* once a second: smooth countdown, and redraw the panel when the zone closes */
	tick: function() {
		var el = this.statusSec && this.statusSec.querySelector('.lf-open-left'), left = this.openLeft(), now = Date.now();
		if (el && left > 0)
			el.textContent = String(left);
		else if (el || (this.openUntil && left === 0)) {
			this.openUntil = 0;
			if (this.editingPanel())
				this.statusDeferred = true;
			else
				this.renderStatus();
		}
		/* the page normally refreshes every 5 s through LuCI's own loop - which stops when
		   LuCI's "Refreshing / Paused" switch at the top is paused, and waits while an answer
		   is late. Keep the map and the server list live anyway: every 15 s at most (30 s
		   while LobbyFence is off), never while the page is hidden or a question is out */
		var off = this.status && this.status.enabled === false, wait = this.watchdogMs != null ? this.watchdogMs : 15000;
		if (wait > 0 && !document.hidden && this.app && document.body.contains(this.app) &&
			now - (this.lastRefresh || 0) > (off ? Math.max(wait, 30000) : wait) &&
			(!this.refreshing || now - this.refreshing > 60000))
			this.refresh().catch(function() {});
	},

	startService: function() {
		var self = this;
		return fs.exec('/etc/init.d/lobbyfence', [ 'restart' ]).catch(function(err) {
			ui.addNotification(null, E('p', {}, err.message), 'error');
		}).then(function() {
			return self.refresh();
		});
	},

	testApi: function() {
		var self = this;
		this.apiResult = null;
		return fs.exec('/usr/sbin/lobbyfence', [ 'apitest' ]).then(function(res) {
			try {
				self.apiResult = JSON.parse((res.stdout || '').trim());
			}
			catch (e) {
				self.apiResult = { ok: false, error: (res.stderr || res.stdout || _('no output')).trim() };
			}
		}).catch(function(err) {
			self.apiResult = { ok: false, error: err.message };
		}).then(function() {
			return self.refresh();
		});
	},

	runCycle: function() {
		var self = this;
		return fs.exec('/usr/sbin/lobbyfence', [ 'cycle' ]).catch(function(err) {
			ui.addNotification(null, E('p', {}, err.message), 'error');
		}).then(function() {
			return self.refresh();
		});
	},

	/* -------------------------------------------------------- debug */

	/* what this browser knows, for the end of the report (no sign-in token: the address without its "#...") */
	browserReport: function() {
		var nav = window.navigator || {}, scr = window.screen || {}, lines = [];
		function iso(t) { try { return new Date(t).toISOString().replace('T', ' ').slice(0, 19) + ' UTC'; } catch (e) { return String(t); } }
		lines.push('time: ' + iso(Date.now()) + ' (browser clock)');
		lines.push('page: ' + location.protocol + '//' + location.host + location.pathname);
		lines.push('router type: ' + (window.LF_PLATFORM || 'openwrt (LuCI)'));
		lines.push('browser: ' + (nav.userAgent || '?'));
		lines.push('screen: ' + scr.width + 'x' + scr.height + ' at ' + (window.devicePixelRatio || 1) + 'x, window ' + window.innerWidth + 'x' + window.innerHeight +
			(('ontouchstart' in window) ? ', touch' : '') + ((window.matchMedia && window.matchMedia('(display-mode: standalone)').matches) ? ', opened from the home screen' : ''));
		lines.push('language: ' + (nav.language || '?') + ', online: ' + (nav.onLine !== false ? 'yes' : 'no'));
		lines.push('map: ' + (this.map ? (this.styleReady ? 'shown' : 'started, style not loaded') : 'not shown') +
			', theme ' + this.themeName + (this.globe ? ', globe' : '') + (this.full ? ', full screen' : '') + ', zone shown: ' + (this.zone || 'none'));
		lines.push('unsaved changes on the page: ' + (Object.keys(this.dirty || {}).length || uci.staged ? 'yes' : 'no'));
		lines.push('');
		lines.push('problems seen in this browser (newest last):');
		if (!LF_ERRORS.length)
			lines.push('  (none)');
		LF_ERRORS.forEach(function(e) {
			lines.push('  ' + iso(e.t) + ' [' + e.kind + ']' + (e.n > 1 ? ' (' + e.n + ' times)' : '') + ' ' + String(e.msg).replace(/\n/g, '\n    '));
		});
		return lines.join('\n') + '\n';
	},

	openDebug: function() {
		var self = this, report = null, st = this.status, pr = st && st.problems;
		var stateNode = E('p', { 'class': 'lf-debug-state' }, _('Collecting the report on the router…'));
		var preview = E('textarea', { 'class': 'lf-debug-text', 'readonly': 'readonly', 'rows': 10, 'spellcheck': 'false', 'style': 'display:none' });
		var dlButton = E('button', { 'class': 'cbi-button cbi-button-action important lf-debug-dl', 'disabled': 'disabled',
			'click': function() { if (report) self.download(self.debugFileName(), report); } }, _('Download report'));
		var copyButton = E('button', { 'class': 'cbi-button lf-debug-copy', 'disabled': 'disabled',
			'click': function() {
				if (!report) return;
				self.copyText(report).then(function(ok) {
					stateNode.textContent = ok ? _('Copied - paste it into your problem report.') : _('Could not copy here - use Download instead.');
				});
			} }, _('Copy'));
		var clearButton = (pr && pr.crashes > 0 || pr && pr.error) ? E('button', {
			'class': 'cbi-button lf-debug-clear',
			'title': _('Forget the recorded crashes and the last error (after the problem is solved)'),
			'click': function() {
				clearButton.disabled = true;
				fs.exec('/usr/sbin/lobbyfence', [ 'debug', 'clear' ]).then(function() {
					stateNode.textContent = _('Crash records and the last error were cleared.');
					return self.refresh();
				}).catch(function(err) {
					stateNode.textContent = _('Could not clear them: %s').format(err && err.message || err);
					clearButton.disabled = false;
				});
			} }, _('Clear crash records')) : null;

		ui.showModal(_('Debug report'), [
			E('p', {}, _('If something in LobbyFence is not working right, download this report and attach it to your problem report. It is made on the router right now: its logs, recorded crashes, settings, firewall rules - and what this browser ran into.')),
			E('p', { 'style': 'font-size:90%;opacity:.8' }, _('No passwords, and MAC addresses are partly hidden. It does show your regions and the game servers\' addresses, so look through it before posting it publicly.')),
			(pr && pr.crashes > 0) ? E('p', { 'class': 'lf-warn' }, _('Crashes on record: %d (last %s) - their details are in the report.').format(pr.crashes, ago(pr.crash_time, self.routerNow()))) : null,
			stateNode,
			preview,
			E('div', { 'class': 'right' }, [
				clearButton, clearButton ? ' ' : null,
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')), ' ',
				copyButton, ' ',
				dlButton
			])
		]);

		return L.resolveDefault(fs.exec('/usr/sbin/lobbyfence', [ 'debug' ]).then(function(res) {
			var out = (res && res.stdout) || '';
			if (!out.trim())
				out = '(the router sent no report' + (res && res.code ? ', exit code ' + res.code : '') + ')\n' + ((res && res.stderr) || '');
			else if (res.stderr && res.stderr.trim())
				out += '\n==== Messages while making the report\n' + res.stderr;
			return out;
		}, function(err) {
			noteError('shown', 'debug report: ' + (err && err.message || err));
			return '(could not get the router\'s part of the report: ' + (err && err.message || err) + ')\n';
		}), '').then(function(routerPart) {
			report = routerPart.replace(/\s*$/, '\n') + '\n==== This browser\n' + self.browserReport();
			preview.value = report;
			preview.style.display = '';
			dlButton.disabled = false;
			copyButton.disabled = false;
			stateNode.textContent = _('Ready (%d KB). Preview:').format(Math.max(1, Math.round(report.length / 1024)));
		});
	},

	/* the located servers by game, as a file: downloaded here, imported on another
	   router (or this one after a reset) - those servers then need no lookup */
	openServersFile: function() {
		var self = this, PATH = '/tmp/lobbyfence/servers-import.txt', current = '', busy = false, armedN = 0, polling = false;
		var stateNode = E('p', { 'class': 'lf-debug-state lf-servers-state' }, '');
		var listNode = E('div', { 'class': 'lf-servers-list' }, E('em', {}, _('Looking up the servers saved on the router…')));
		var liveNode = E('p', { 'class': 'lf-muted lf-servers-live', 'style': 'font-size:90%;margin:0 0 6px' }, '');
		var builtinNode = E('div', { 'class': 'lf-servers-builtin' });
		var input = E('input', { 'type': 'file', 'accept': '.txt,text/plain', 'class': 'lf-servers-input', 'style': 'display:none' });
		var paste = E('textarea', { 'class': 'lf-debug-text lf-servers-paste', 'rows': 6, 'spellcheck': 'false',
			'placeholder': _('Paste a servers file here (it starts with "lobbyfence-servers 1")') });
		var pasteBox = E('div', { 'class': 'lf-servers-pastebox', 'style': 'display:none' }, [ paste ]);
		var buttons = [];
		function setBusy(on) { busy = on; buttons.forEach(function(b) { b.disabled = on; }); }
		function fail(what, err) {
			stateNode.textContent = what.format(String(err && err.message || err || _('no answer')).replace(/^lobbyfence: /, '').trim());
		}
		function isFile(text) { return /^lobbyfence-servers 1\r?$/m.test(text); }

		/* the router's export, read into games -> servers (imported ones are marked) */
		function parse(text) {
			var games = [], cur = null;
			String(text).split(/\r?\n/).forEach(function(l) {
				var m;
				if ((m = l.match(/^game ([a-z0-9_]+) ?(.*)$/))) {
					var p = presetById(m[1]);
					cur = { id: m[1], name: m[2] || (p && (p.name || p.label)) || m[1], rows: [] };
					games.push(cur);
				}
				else if (cur && (m = l.match(/^([0-9a-fA-F:.]+) (-?[0-9.]+) (-?[0-9.]+) ([A-Z][A-Z]|--) ([0-9]+)( imported)?$/)))
					cur.rows.push({ ip: m[1], cc: m[4], ts: +m[5], imported: !!m[6] });
			});
			return games.filter(function(g) { return g.rows.length; });
		}
		function render(games) {
			listNode.innerHTML = '';
			if (!games.length) {
				listNode.appendChild(E('p', { 'class': 'lf-servers-empty' }, _('No located servers saved yet. Play a little (or import a file), and they show up here.')));
				return;
			}
			var now = self.routerNow(), MAX = 300;
			games.forEach(function(g) {
				var imp = g.rows.filter(function(r) { return r.imported; }).length, cc = {}, top;
				g.rows.forEach(function(r) { cc[r.cc] = (cc[r.cc] || 0) + 1; });
				top = Object.keys(cc).sort(function(a, b) { return cc[b] - cc[a]; }).slice(0, 4)
					.map(function(c) { return (c === '--' ? '?' : c) + ' ' + cc[c]; }).join(', ');
				var rows = g.rows.slice().sort(function(a, b) { return b.ts - a.ts; });
				var picks = [], delSel;
				function picked() { return picks.filter(function(c) { return c.checked; }).map(function(c) { return c.value; }); }
				function updatePicked() {
					var n = picked().length;
					delSel.disabled = busy || !n;
					delSel.reset(n ? _('Delete selected (%d)').format(n) : _('Delete selected'));
					all.checked = n > 0 && n === picks.length;
					all.indeterminate = n > 0 && n < picks.length;
				}
				var all = E('input', { 'type': 'checkbox', 'class': 'lf-servers-all', 'title': _('Select all'), 'change': function() {
					picks.forEach(function(c) { c.checked = all.checked; });
					updatePicked();
				} });
				var table = E('table', { 'class': 'lf-servers-table' }, [
					E('tr', {}, [ E('th', {}, all), E('th', {}, _('Server')), E('th', {}, _('Country')), E('th', {}, _('Last seen')), E('th', {}, _('From')) ])
				].concat(rows.slice(0, MAX).map(function(r) {
					var c = E('input', { 'type': 'checkbox', 'class': 'lf-servers-pick', 'value': r.ip, 'change': updatePicked });
					picks.push(c);
					return E('tr', { 'class': r.imported ? 'lf-imp' : '' }, [
						E('td', {}, c),
						E('td', { 'class': 'lf-mono' }, E('label', { 'style': 'cursor:pointer', 'click': function(ev) { if (ev.target.tagName !== 'INPUT') { c.checked = !c.checked; updatePicked(); } } }, r.ip)),
						E('td', {}, r.cc === '--' ? '?' : r.cc),
						E('td', {}, ago(r.ts, now)), E('td', {}, r.imported ? _('imported') : _('this router'))
					]);
				})));
				delSel = confirmButton('lf-servers-delsel', _('Delete selected'), function() {
					var ips = picked();
					return { ask: _('Click again to delete %d server(s)').format(ips.length),
						explain: _('This deletes the %d chosen server(s) from the %s list - and from the zones set to %s (they are learned again if they show up). The rest of the list stays.').format(ips.length, g.name, g.name),
						args: [ 'remove-servers', g.id ].concat(ips) };
				});
				delSel.disabled = true;
				listNode.appendChild(E('details', { 'class': 'lf-servers-game', 'data-game': g.id }, [
					E('summary', {}, [
						E('strong', {}, g.name), ' - ',
						E('span', { 'class': 'lf-servers-count' }, _('%d server(s)').format(g.rows.length)),
						E('span', { 'class': 'lf-muted' }, ' (' + _('%d from this router, %d imported').format(g.rows.length - imp, imp) + (top ? ' · ' + top : '') + ')')
					]),
					table,
					rows.length > MAX ? E('p', { 'class': 'lf-muted' }, _('…and %d more - Download or Copy to get them all.').format(rows.length - MAX)) : '',
					E('div', { 'class': 'lf-servers-actions', 'style': 'margin-top:4px' }, [
						delSel, ' ',
						confirmButton('lf-servers-remove', _('Remove this list'), function() {
							return { ask: _('Click again to delete %d server(s)').format(g.rows.length),
								explain: _('This deletes the %s list: its kept and imported locations, and the servers learned by zones set to %s (they are learned and looked up again while you play). Whitelists, blacklists and regions stay.').format(g.name, g.name),
								args: [ 'remove-servers', g.id ] };
						})
					])
				]));
			});
		}
		/* a delete button that asks once more first (a second click within 6 s);
		   what(): { ask, explain, args } for the router's remove-servers */
		function confirmButton(cls, text, what) {
			var armed = null, timer = null, b;
			b = E('button', { 'class': 'cbi-button cbi-button-negative ' + cls, 'click': function(ev) {
				ev.preventDefault();
				if (busy || b.disabled) return;
				if (!armed) {
					armed = what();
					armedN++;
					b.textContent = armed.ask;
					stateNode.textContent = armed.explain;
					timer = window.setTimeout(function() { armed = null; armedN--; b.textContent = b.label; }, 6000);
					return;
				}
				var args = armed.args;
				window.clearTimeout(timer);
				armed = null;
				armedN--;
				setBusy(true);
				stateNode.textContent = _('Removing…');
				fs.exec('/usr/sbin/lobbyfence', args).then(function(r) {
					if (!r || r.code !== 0)
						throw new Error(r && (r.stderr || r.stdout) || _('no answer'));
					stateNode.textContent = String(r.stdout || '').trim();
					return load(openGame()).catch(function() {});
				}).catch(function(err) { fail(_('Could not remove it: %s'), err); }).then(function() { setBusy(false); });
			} }, text);
			b.label = text;
			b.reset = function(t) { b.label = t; if (!armed) b.textContent = t; };
			return b;
		}
		function openGame() {
			var d = listNode.querySelector('details[open]');
			return d ? d.getAttribute('data-game') : null;
		}
		/* the game servers LobbyFence comes with: read-only (they are part of LobbyFence) */
		function renderBuiltin(games) {
			builtinNode.innerHTML = '';
			if (!games.length)
				return;
			builtinNode.appendChild(E('h5', {}, _('Comes with LobbyFence')));
			builtinNode.appendChild(E('p', { 'class': 'lf-muted', 'style': 'font-size:90%;margin:0 0 6px' }, _('Game servers every LobbyFence knows from the start. When your device plays on one, it is placed on the map straight away, with no lookup - and then it is in the list above too, as found by this router. They are part of LobbyFence, so there is nothing to delete here.')));
			games.forEach(function(g) {
				var cc = {};
				g.rows.forEach(function(r) { cc[r.cc] = (cc[r.cc] || 0) + 1; });
				var top = Object.keys(cc).sort(function(a, b) { return cc[b] - cc[a]; }).slice(0, 4)
					.map(function(c) { return (c === '--' ? '?' : c) + ' ' + cc[c]; }).join(', ');
				/* by country, the busiest first, then as listed */
				var rows = g.rows.map(function(r, i) { return { r: r, i: i }; }).sort(function(a, b) {
					return cc[b.r.cc] - cc[a.r.cc] || (a.r.cc < b.r.cc ? -1 : a.r.cc > b.r.cc ? 1 : 0) || a.i - b.i;
				}).map(function(x) { return x.r; });
				builtinNode.appendChild(E('details', { 'class': 'lf-builtin-game', 'data-game': g.id }, [
					E('summary', {}, [
						E('strong', {}, g.name), ' - ',
						E('span', { 'class': 'lf-servers-count' }, _('%d server(s)').format(g.rows.length)),
						top ? E('span', { 'class': 'lf-muted' }, ' (' + top + ')') : ''
					]),
					E('table', { 'class': 'lf-servers-table' }, [
						E('tr', {}, [ E('th', {}, _('Server')), E('th', {}, _('Country')) ])
					].concat(rows.slice(0, 500).map(function(r) {
						return E('tr', {}, [ E('td', { 'class': 'lf-mono' }, r.ip), E('td', {}, r.cc === '--' ? '?' : r.cc) ]);
					})))
				]));
			});
		}
		function loadBuiltin() {
			return fs.exec('/usr/sbin/lobbyfence', [ 'builtin-servers' ]).then(function(r) {
				var text = r && r.code === 0 && r.stdout || '';
				renderBuiltin(isFile(text) ? parse(text) : []);
			}).catch(function() { renderBuiltin([]); });   /* (an older router: just not shown) */
		}
		function load(keepOpen) {
			return fs.exec('/usr/sbin/lobbyfence', [ 'export' ]).then(function(r) {
				var text = r && r.stdout || '';
				if (!r || r.code !== 0 || !isFile(text))
					throw new Error(r && (r.stderr || r.stdout) || _('no answer'));
				current = text;
				var games = parse(text);
				render(games);
				if (keepOpen) {
					var d = listNode.querySelector('details[data-game="' + keepOpen + '"]');
					if (d) d.open = true;
				}
				return games;
			});
		}
		function count(games) {
			return games.reduce(function(n, g) { return n + g.rows.length; }, 0);
		}
		/* while the window is open the lists follow the router - the servers learned while
		   you play - every 10 s; not while something is being done here or servers are ticked */
		function servers(text) { return String(text).replace(/^#.*\n?/gm, ''); }
		function quiet() { return busy || armedN > 0 || !!listNode.querySelector('.lf-servers-pick:checked'); }
		var follow = (self.serversFollowMs != null ? self.serversFollowMs : 10000) > 0 && window.setInterval(function() {
			if (!document.body.contains(listNode)) { window.clearInterval(follow); return; }
			if (document.hidden || polling || quiet() || !current)
				return;
			polling = true;
			fs.exec('/usr/sbin/lobbyfence', [ 'export' ]).then(function(r) {
				var text = r && r.code === 0 && r.stdout || '';
				if (!isFile(text) || !document.body.contains(listNode))
					return;
				liveNode.textContent = _('Updates by itself while this is open - last checked %s.').format(new Date().toLocaleTimeString());
				if (servers(text) === servers(current) || quiet())
					return;
				var open = openGame(), scroll = listNode.scrollTop, d;
				current = text;
				render(parse(text));
				if (open && (d = listNode.querySelector('details[data-game="' + open + '"]')))
					d.open = true;
				listNode.scrollTop = scroll;
			}).catch(function() {}).then(function() { polling = false; });
		}, self.serversFollowMs != null ? self.serversFollowMs : 10000);
		function sendFile(text) {
			if (!isFile(text)) { stateNode.textContent = _('That is not a LobbyFence servers file (made with Download servers or Copy).'); return; }
			if (text.length > 1024 * 1024) { stateNode.textContent = _('That is too big (more than 1 MB).'); return; }
			setBusy(true);
			stateNode.textContent = _('Sending it to the router…');
			var msg;
			fs.write(PATH, text).then(function() {
				return fs.exec('/usr/sbin/lobbyfence', [ 'import-servers', PATH ]);
			}).then(function(r) {
				if (!r || r.code !== 0)
					throw new Error(r && (r.stderr || r.stdout) || _('no answer'));
				msg = String(r.stdout || '').trim().replace(/\n/g, ' - ');
				stateNode.textContent = msg;
				paste.value = '';
				return load().catch(function() {});
			}).catch(function(err) { fail(_('Could not import it: %s'), err); }).then(function() { setBusy(false); });
		}

		var dl = E('button', { 'class': 'cbi-button cbi-button-action important lf-servers-dl', 'click': function() {
			setBusy(true);
			stateNode.textContent = _('Collecting the servers on the router…');
			load().then(function(games) {
				self.download(self.serversFileName(), current);
				var n = count(games);
				stateNode.textContent = (n ? _('Downloaded %d server(s) with their locations, for %d game(s).').format(n, games.length)
					: _('Downloaded - but no located servers yet. Play a little first, then download again.'))
					+ ' ' + _('If the browser blocks it as an insecure download (it does that on http:// router pages), choose Keep - or use Copy.');
			}).catch(function(err) { fail(_('Could not download them: %s'), err); }).then(function() { setBusy(false); });
		} }, _('Download servers'));
		var cp = E('button', { 'class': 'cbi-button lf-servers-copy', 'click': function() {
			setBusy(true);
			load().then(function(games) {
				return self.copyText(current).then(function(ok) {
					stateNode.textContent = ok ? _('Copied %d server(s) - paste them into a message or a text file, and import them with Paste on the other router.').format(count(games))
						: _('Could not copy here - use Download servers.');
				});
			}).catch(function(err) { fail(_('Could not copy them: %s'), err); }).then(function() { setBusy(false); });
		} }, _('Copy'));
		var im = E('button', { 'class': 'cbi-button lf-servers-import', 'click': function() { input.click(); } }, _('Import a file…'));
		var ps = E('button', { 'class': 'cbi-button lf-servers-pastebtn', 'click': function() {
			if (pasteBox.style.display === 'none') { pasteBox.style.display = ''; ps.textContent = _('Import pasted text'); paste.focus(); return; }
			sendFile(String(paste.value || ''));
		} }, _('Paste…'));
		buttons = [ dl, cp, im, ps ];
		input.addEventListener('change', function() {
			var f = input.files && input.files[0];
			if (!f) return;
			if (f.size > 1024 * 1024) { stateNode.textContent = _('That file is too big (more than 1 MB).'); input.value = ''; return; }
			var rd = new FileReader();
			rd.onload = function() { input.value = ''; sendFile(String(rd.result || '')); };
			rd.onerror = function() { stateNode.textContent = _('Could not read that file.'); input.value = ''; };
			rd.readAsText(f);
		});
		ui.showModal(_('Servers file'), [
			E('p', {}, _('Every server LobbyFence has located, by game, with where it is. Share them with another router - or keep them for after a reset - and those servers are known straight away, without asking the geolocation service again.')),
			listNode,
			liveNode,
			builtinNode,
			E('p', { 'style': 'font-size:90%;opacity:.8' }, _('Holds the game servers\' addresses and locations only - nothing about your devices, your address or your regions. Importing adds locations; it does not change your zones or what they block.')),
			pasteBox,
			stateNode,
			input,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close')), ' ',
				ps, ' ', im, ' ', cp, ' ', dl
			])
		]);
		load().catch(function(err) {
			listNode.innerHTML = '';
			fail(_('Could not read the servers on the router: %s'), err);
		}).then(loadBuiltin);
	},

	serversFileName: function() {
		var d = new Date(), p = function(n) { return (n < 10 ? '0' : '') + n; };
		return 'lobbyfence-servers-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) + '.txt';
	},

	debugFileName: function() {
		var d = new Date(), p = function(n) { return (n < 10 ? '0' : '') + n; };
		return 'lobbyfence-debug-' + (window.LF_PLATFORM || 'openwrt') + '-' + d.getFullYear() + p(d.getMonth() + 1) + p(d.getDate()) +
			'-' + p(d.getHours()) + p(d.getMinutes()) + '.txt';
	},

	/* ------------------------------------------------------ regions */

	regionFeatures: function() {
		var sel = this.selected || {};
		var feats = (this.circles[this.zone] || []).map(function(c, idx) {
			return { type: 'Feature', geometry: { type: 'Polygon', coordinates: [ circleRing(c) ] },
				properties: { kind: 'circle', idx: idx, sel: sel.kind === 'circle' && sel.idx === idx ? 1 : 0 } };
		});
		(this.polygons[this.zone] || []).forEach(function(pts, idx) {
			feats.push({ type: 'Feature', geometry: { type: 'Polygon', coordinates: [ pts.concat([ pts[0] ]) ] },
				properties: { kind: 'polygon', idx: idx, sel: sel.kind === 'polygon' && sel.idx === idx ? 1 : 0 } });
		});
		return feats;
	},

	/* ------------------------------------------------------------ home */

	home: function() {
		var v = String(uci.get('lobbyfence', 'globals', 'home') || '').split(','), lat = +v[0], lon = +v[1];
		if (v.length !== 2 || !isFinite(lat) || !isFinite(lon) || lat < -90 || lat > 90 || lon < -180 || lon > 180)
			return null;
		return { lat: lat, lon: lon, label: uci.get('lobbyfence', 'globals', 'home_label') || _('Home') };
	},

	homeKm: function(s) {
		var h = this.home();
		return h && s.lat != null ? distanceKm(h.lat, h.lon, s.lat, s.lon) : null;
	},

	/* Home is drawn inside the map (a symbol layer), not as an HTML marker: page
	 * styles can then never paint a box around it, and it moves with the map. */
	drawHome: function() {
		var self = this, h = this.home(), map = this.map;
		this.homeButton.classList.toggle('lf-on', !!h);
		if (!map || !this.styleReady || !map.getSource)
			return;
		var color = this.theme().overlay.circle, img = 'lf-pin-' + color.replace('#', '');
		var data = { type: 'FeatureCollection', features: h ? [ { type: 'Feature',
			properties: { label: h.label || '' }, geometry: { type: 'Point', coordinates: [ h.lon, h.lat ] } } ] : [] };

		if (!map.getSource('lf-home'))
			map.addSource('lf-home', { type: 'geojson', data: data });
		else
			map.getSource('lf-home').setData(data);

		function addLayer() {
			if (map.getLayer('lf-home'))
				return;
			map.addLayer({ id: 'lf-home', type: 'symbol', source: 'lf-home',
				layout: { 'icon-image': img, 'icon-anchor': 'bottom', 'icon-allow-overlap': true, 'icon-ignore-placement': true } });
		}
		if (map.hasImage && map.hasImage(img))
			return addLayer();
		/* rasterise the pin once per colour at 2x for sharp edges */
		var pic = new Image(68, 68);
		pic.onload = function() {
			if (map.hasImage && !map.hasImage(img))
				map.addImage(img, pic, { pixelRatio: 2 });
			addLayer();
		};
		pic.src = 'data:image/svg+xml;charset=utf-8,' + encodeURIComponent(pinSvg(color, 68, true));
	},

	/* the home pin clicked: its popup - Delete / Backspace (or the button) removes it */
	openHomePopup: function() {
		var self = this, h = this.home(), pop;
		if (!h || !this.map || !this.ml)
			return;
		if (this.selected)
			this.select(null);   /* (so Delete means the home pin, not a shape) */
		this.closeHomePopup();
		pop = this.homePopup = new this.ml.Popup({ closeButton: true, maxWidth: '260px', offset: [ 0, -32 ], className: 'lf-homepop' })
			.setLngLat([ h.lon, h.lat ])
			.setDOMContent(E('div', {}, [
				E('strong', {}, _('Home')), E('div', { 'class': 'lf-sm' }, h.label),
				E('button', { 'class': 'lf-btn lf-sm lf-homedel', 'title': _('Remove the home pin (Delete key)'),
					'click': function(ev) { ev.preventDefault(); self.removeHome(); } }, _('Remove home'))
			]))
			.addTo(this.map);
		pop.on('close', function() { if (self.homePopup === pop) self.homePopup = null; });
	},

	closeHomePopup: function() {
		var p = this.homePopup;
		this.homePopup = null;
		if (p) p.remove();
	},

	removeHome: function() {
		this.closeHomePopup();
		this.setHome(null);
	},

	setHome: function(lat, lon, label) {
		if (!uci.get('lobbyfence', 'globals'))
			uci.add('lobbyfence', 'globals', 'globals');
		if (lat == null) {
			uci.unset('lobbyfence', 'globals', 'home');
			uci.unset('lobbyfence', 'globals', 'home_label');
		}
		else {
			uci.set('lobbyfence', 'globals', 'home', (+lat).toFixed(5) + ',' + (+lon).toFixed(5));
			uci.set('lobbyfence', 'globals', 'home_label', String(label || '').slice(0, 120));
		}
		this.stage();
		this.drawHome();
		this.renderServers();
		if (lat != null)
			this.flyTo([ +lon, +lat ], 6);
	},

	/* ZIP / postal code or place name -> Photon (OpenStreetMap search made for typing ahead) */
	geocode: function(text) {
		var q = String(text || '').trim();
		var url = 'https://photon.komoot.io/api/?limit=6&q=' + encodeURIComponent(q);
		var lang = String(navigator.language || 'en').slice(0, 2).toLowerCase();
		if (/^(en|de|fr|it)$/.test(lang)) url += '&lang=' + lang;
		return fetch(url, { headers: { 'Accept': 'application/json' } }).then(function(res) {
			if (!res.ok) throw new Error('HTTP ' + res.status);
			return res.json();
		}).then(function(data) {
			var seen = {};
			return ((data && data.features) || []).map(function(f) {
				var p = f.properties || {}, c = (f.geometry && f.geometry.coordinates) || [];
				var parts = [ p.postcode && p.postcode !== p.name ? p.postcode : null, p.name, p.city !== p.name ? p.city : null,
					p.state, p.country ].filter(function(x) { return x; });
				return { lat: +c[1], lon: +c[0], label: parts.join(', ') };
			}).filter(function(r) {
				if (!isFinite(r.lat) || !isFinite(r.lon) || !r.label || seen[r.label]) return false;
				return (seen[r.label] = true);
			});
		});
	},

	/* full address lookup (house numbers etc.) - OpenStreetMap Nominatim, one request per search */
	geocodeFull: function(text) {
		var url = 'https://nominatim.openstreetmap.org/search?format=jsonv2&limit=6&q=' + encodeURIComponent(String(text || '').trim());
		return fetch(url, { headers: { 'Accept': 'application/json' } }).then(function(res) {
			if (!res.ok) throw new Error('HTTP ' + res.status);
			return res.json();
		}).then(function(list) {
			return (list || []).map(function(r) {
				return { lat: +r.lat, lon: +r.lon, label: String(r.display_name || '') };
			}).filter(function(r) { return isFinite(r.lat) && isFinite(r.lon) && r.label; });
		});
	},

	openHome: function() {
		var self = this, h = this.home(), timer = null, seq = 0;
		var input = E('input', { 'class': 'cbi-input-text', 'style': 'width:100%', 'placeholder': _('Start typing a ZIP / postal code or place name') });
		var results = E('div', { 'style': 'margin:.6em 0;max-height:240px;overflow:auto' });
		var msg = E('p', { 'style': 'min-height:1.2em;margin:.3em 0' });

		/* suggestions while typing: after a short pause, newest answer wins */
		function show(list, my, full) {
			if (my !== seq) return;   /* an older answer arrived late */
			results.innerHTML = '';
			msg.textContent = list.length ? _('Pick your location:')
				: (full ? _('Nothing found - check the spelling, or add the town.') : _('No suggestions - press Enter for a full address search.'));
			list.forEach(function(r) {
				results.appendChild(E('button', {
					'class': 'cbi-button lf-suggest', 'style': 'display:block;width:100%;text-align:left;margin:.2em 0;white-space:normal',
					'click': function() { ui.hideModal(); self.setHome(r.lat, r.lon, r.label); }
				}, r.label));
			});
		}

		/* Enter / Search: exact address lookup, merged with the quick suggestions */
		function fullSearch() {
			var q = input.value.trim(), my = ++seq;
			window.clearTimeout(timer);
			timer = null;
			if (!q) return;
			msg.textContent = _('Searching for the exact address…');
			Promise.all([
				self.geocodeFull(q).catch(function() { return []; }),
				self.geocode(q).catch(function() { return []; })
			]).then(function(r) {
				var seen = {}, list = r[0].concat(r[1]).filter(function(x) {
					var k = x.lat.toFixed(4) + ',' + x.lon.toFixed(4);
					return seen[k] ? false : (seen[k] = true);
				}).slice(0, 8);
				show(list, my, true);
			});
		}

		function search() {
			var q = input.value.trim(), my = ++seq;
			window.clearTimeout(timer);
			timer = null;
			if (q.length < 3) {
				results.innerHTML = '';
				msg.textContent = q ? _('Keep typing…') : '';
				return;
			}
			msg.textContent = _('Searching…');
			self.geocode(q).then(function(list) {
				show(list, my, false);
			}).catch(function(err) {
				if (my === seq)
					msg.textContent = _('Search failed (%s). Your browser needs internet access.').format(err.message);
			});
		}
		input.addEventListener('input', function() {
			window.clearTimeout(timer);
			timer = window.setTimeout(search, 350);
		});
		input.addEventListener('keydown', function(ev) {
			var first = results.querySelector('button');
			if (ev.key === 'Enter') {
				ev.preventDefault();
				fullSearch();
			}
			else if (ev.key === 'ArrowDown' && first) { ev.preventDefault(); first.focus(); }
		});

		ui.showModal(_('Home location'), [
			E('p', {}, h ? [ _('Current home: '), E('strong', {}, h.label) ] : _('Set where you are, so you can see it on the map and how far away each server is.')),
			E('div', { 'style': 'display:flex;gap:.5em' }, [
				input, E('button', { 'class': 'cbi-button cbi-button-action', 'click': fullSearch }, _('Search'))
			]),
			msg, results,
			E('p', { 'style': 'font-size:85%;opacity:.7' }, _('Suggestions while typing by Photon (komoot); Enter / Search looks up the exact address with OpenStreetMap Nominatim. Data © OpenStreetMap contributors. Only what you type is sent.')),
			E('div', { 'class': 'right' }, [
				h ? E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); self.flyTo([ h.lon, h.lat ], 6); } }, _('Show home')) : '', ' ',
				h ? E('button', { 'class': 'cbi-button cbi-button-remove', 'click': function() { ui.hideModal(); self.setHome(null); } }, _('Remove home')) : '', ' ',
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Close'))
			])
		]);
		window.setTimeout(function() { input.focus(); }, 50);
	},

	/* ---------------------------------------------- select / move / delete */

	select: function(kind, idx) {
		if (kind)
			this.closeHomePopup();
		var same = this.selected && kind && this.selected.kind === kind && this.selected.idx === idx;
		this.selected = kind ? { kind: kind, idx: idx } : null;
		this.updateAlignPrompt();
		if (same) {
			this.updateRegionSource();
			this.renderRegions();
		}
		else
			this.drawRegions();   /* moves the handles to the newly selected shape */
	},

	deleteSelected: function() {
		var sel = this.selected, list;
		if (!sel || !this.zone)
			return false;
		list = sel.kind === 'circle' ? this.circles[this.zone] : this.polygons[this.zone];
		if (!list || !list[sel.idx])
			return false;
		list.splice(sel.idx, 1);
		this.selected = null;
		this.regionsChanged();
		this.drawServers();
		return true;
	},

	/* press on a shape and drag it somewhere else (a plain click just selects it) */
	startShapeDrag: function(ev) {
		var self = this, map = this.map, f, kind, idx, shape, orig, touch, moved = false;
		if (this.drawMode || !ev.features || !ev.features.length)
			return;
		/* pressing a corner / circle handle drags that handle, not the whole shape */
		var tgt = ev.originalEvent && ev.originalEvent.target;
		if (tgt && tgt.closest && tgt.closest('.maplibregl-marker'))
			return;
		if (map.queryRenderedFeatures && ev.point && map.queryRenderedFeatures(ev.point, { layers: [ 'lf-servers' ] }).length)
			return;   /* a server dot on top wins */
		f = ev.features[0];
		kind = f.properties.kind; idx = +f.properties.idx;
		shape = kind === 'circle' ? (this.circles[this.zone] || [])[idx] : (this.polygons[this.zone] || [])[idx];
		if (!shape)
			return;
		if (ev.type === 'touchstart' && this.touchScroll()) {
			/* on a phone one finger over a shape moves the map (a region often
			   covers most of it): the shape is selected, its handles move it */
			if (!this.selected || this.selected.kind !== kind || this.selected.idx !== idx)
				this.select(kind, idx);
			return;
		}
		if (ev.preventDefault)
			ev.preventDefault();   /* no map panning while moving the shape */
		this.select(kind, idx);
		orig = JSON.parse(JSON.stringify(shape));
		touch = ev.type === 'touchstart';

		function clampLat(l) { return Math.max(-85, Math.min(85, l)); }
		function move(e) {
			if (!moved && ev.point && e.point && Math.abs(e.point.x - ev.point.x) + Math.abs(e.point.y - ev.point.y) < 4)
				return;
			if (!moved) {
				moved = true;
				self.markers.forEach(function(m) { m.remove(); });
				self.markers = [];
			}
			var dx = e.lngLat.lng - ev.lngLat.lng, dy = mercDeg(clampLat(e.lngLat.lat)) - mercDeg(clampLat(ev.lngLat.lat));
			if (kind === 'circle') {
				shape.lon = wrapLon(orig.lon + dx);
				shape.lat = clampLat(invMercDeg(mercDeg(clampLat(orig.lat)) + dy));
			}
			else {
				orig.forEach(function(p, i) { shape[i] = [ p[0] + dx, clampLat(invMercDeg(mercDeg(p[1]) + dy)) ]; });
			}
			self.updateRegionSource();
		}
		function up() {
			map.off(touch ? 'touchmove' : 'mousemove', move);
			if (moved) {
				if (kind === 'polygon')
					self.polygons[self.zone][idx] = normalizePolygon(shape);
				self.regionsChanged();
				self.drawServers();
			}
		}
		map.on(touch ? 'touchmove' : 'mousemove', move);
		map.once(touch ? 'touchend' : 'mouseup', up);
	},

	updateRegionSource: function() {
		if (this.map && this.styleReady && this.map.getSource('lf-circles'))
			this.map.getSource('lf-circles').setData({ type: 'FeatureCollection', features: this.regionFeatures() });
	},

	/* a handle: the visible dot inside a target that is finger-sized on touch screens */
	handleElement: function(kind) {
		var self = this, c = this.theme().overlay.circle, ring = this.theme().dark ? '#000' : '#fff', edge = kind === 'edge';
		var el = E('div', {
			'class': 'lf-handle lf-h-' + kind + (kind === 'vertex' ? ' lf-vertex' : ''),
			'title': kind === 'vertex' ? (this.coarse() ? _('Drag to move - hold to remove') : _('Drag to move - right-click to remove')) : '',
			'style': 'cursor:' + (edge ? 'ew-resize' : 'move') + ';touch-action:none'
		}, [ E('div', { 'class': 'lf-hdot', 'style': edge ? 'background:' + ring + ';border:2px solid ' + c : 'background:' + c + ';border:2px solid ' + ring }) ]);
		/* one finger moves the map on phones: while a finger is on a handle, the map
		   holds still (the handle moves, not the map under it as well) */
		function still() {
			var dp = self.map && self.map.dragPan;
			if (dp && dp.isEnabled()) { dp.disable(); self.panHeld = true; }
		}
		function release() {
			window.setTimeout(function() {
				if (self.panHeld && self.map && self.map.dragPan) { self.map.dragPan.enable(); self.panHeld = false; }
			}, 0);
		}
		el.addEventListener('touchstart', still, { passive: true });
		el.addEventListener('touchend', release);
		el.addEventListener('touchcancel', release);
		return el;
	},

	/* a touch screen is the main pointer (bigger targets, tap wording) */
	coarse: function() {
		try { return !!(window.matchMedia && window.matchMedia('(pointer: coarse)').matches); } catch (e) { return false; }
	},

	regionsChanged: function() {
		this.dirty[this.zone] = true;
		this.drawRegions();
		this.stage();
		this.updateAlignPrompt();
	},

	/* write the edited regions of a zone into the uci changeset */
	writeRegions: function(zone) {
		if (!uci.get('lobbyfence', zone))
			return;
		var list = (this.circles[zone] || []).map(formatCircle);
		var polys = (this.polygons[zone] || []).map(formatPolygon);
		if (list.length)
			uci.set('lobbyfence', zone, 'circle', list);
		else
			uci.unset('lobbyfence', zone, 'circle');
		if (polys.length)
			uci.set('lobbyfence', zone, 'polygon', polys);
		else
			uci.unset('lobbyfence', zone, 'polygon');
	},

	/* Every change is saved right away (staged, like LuCI's "Save" button),
	 * so nothing is lost when switching tabs; it takes effect on Save & Apply. */
	stage: function(now) {
		var self = this;
		window.clearTimeout(this.stageTimer);
		this.saving = true;
		this.updateNotice();
		if (!now)
			return new Promise(function(resolve) {
				self.stageTimer = window.setTimeout(function() { resolve(self.stage(true)); }, 400);
			});
		var dirty = this.dirty;
		this.dirty = {};
		Object.keys(dirty).forEach(function(zone) { self.writeRegions(zone); });
		this.saveChain = (this.saveChain || Promise.resolve()).then(function() {
			/* uci.save() reloads the config from the router when it is done, which
			 * drops anything set while it was running: note those edits and redo them */
			self.inFlight = [];
			return uci.save().then(function() {
				var redo = self.inFlight;
				self.inFlight = null;
				if (redo.length) {
					redo.forEach(function(fn) { fn(); });
					self.stage();
				}
			}, function(err) { self.inFlight = null; throw err; });
		}).then(function() {
			self.pendingApply = true;
			if (ui.changes && typeof ui.changes.init === 'function')
				try { ui.changes.init(); } catch (e) {}
		}).catch(function(err) {
			Object.keys(dirty).forEach(function(z) { self.dirty[z] = true; });
			ui.addNotification(null, E('p', {}, _('Could not save the change: %s').format(err && err.message || err)), 'error');
		}).then(function() {
			self.saving = false;
			self.updateNotice();
		});
		return this.saveChain;
	},

	drawRegions: function() {
		var self = this, ml = this.ml, list = this.circles[this.zone] || [], polys = this.polygons[this.zone] || [];

		this.markers.forEach(function(m) { m.remove(); });
		this.markers = [];
		this.renderRegions();

		if (!this.map || !this.styleReady) {
			this.renderServers();
			return;
		}

		this.updateRegionSource();

		/* saved shapes are drawn as clear outlines; only the selected one gets handles */
		var sel = this.selected || {};
		list.forEach(function(c, ci) {
			if (sel.kind !== 'circle' || sel.idx !== ci)
				return;
			var centre = new ml.Marker({ element: self.handleElement('centre'), draggable: true })
				.setLngLat([ c.lon, c.lat ]).addTo(self.map);
			var edge = new ml.Marker({ element: self.handleElement('edge'), draggable: true })
				.setLngLat(destination(c.lat, c.lon, c.r, 90)).addTo(self.map);

			centre.on('drag', function() {
				var p = centre.getLngLat();
				c.lat = Math.max(-89.9, Math.min(89.9, p.lat));
				c.lon = wrapLon(p.lng);
				edge.setLngLat(destination(c.lat, p.lng, c.r, 90));
				self.updateRegionSource();
			});
			edge.on('drag', function() {
				var p = edge.getLngLat();
				c.r = Math.max(1, Math.min(20000, distanceKm(c.lat, c.lon, p.lat, p.lng)));
				self.updateRegionSource();
			});
			[ centre, edge ].forEach(function(m) {
				/* redraw after MapLibre has finished with the handle (it is replaced) */
				m.on('dragend', function() { window.setTimeout(function() { self.regionsChanged(); self.drawServers(); }, 0); });
			});
			self.markers.push(centre, edge);
		});

		polys.forEach(function(pts, pi) {
			if (sel.kind !== 'polygon' || sel.idx !== pi)
				return;
			var vms = [];
			pts.forEach(function(p, vi) {
				var el = self.handleElement('vertex'), links = null, dragging = false;
				var m = new ml.Marker({ element: el, draggable: true }).setLngLat(p).addTo(self.map);
				vms.push(m);
				/* straight edges stay straight: the neighbouring corners follow */
				m.on('dragstart', function() {
					dragging = true;
					holdEnd();   /* moving it, not removing it */
					var n = pts.length, a = (vi + n - 1) % n, b = (vi + 1) % n;
					links = [ [ a, alignedKind(pts[a], pts[vi]) ], [ b, alignedKind(pts[vi], pts[b]) ] ];
				});
				m.on('drag', function() {
					var q = m.getLngLat(), lat = Math.max(-85, Math.min(85, q.lat));
					pts[vi] = [ q.lng, lat ];
					(links || []).forEach(function(l) {
						if (l[1] === 'h') pts[l[0]][1] = lat;
						else if (l[1] === 'v') pts[l[0]][0] = q.lng;
						if (l[1]) vms[l[0]].setLngLat(pts[l[0]]);
					});
					self.updateRegionSource();
				});
				m.on('dragend', function() {
					self.polygons[self.zone][pi] = normalizePolygon(pts);
					/* redraw after MapLibre has finished with the handle (it is replaced) */
					window.setTimeout(function() { self.regionsChanged(); self.drawServers(); }, 0);
				});
				function removeCorner() {
					if (el.lfRemoved || pts.length <= 3)
						return false;
					el.lfRemoved = true;
					pts.splice(vi, 1);
					self.polygons[self.zone][pi] = normalizePolygon(pts);
					self.regionsChanged();
					self.drawServers();
					return true;
				}
				el.addEventListener('contextmenu', function(ev) {
					ev.preventDefault();
					removeCorner();
				});
				/* holding a finger still on a corner removes it (iPhones have no contextmenu) */
				var hold = null, hx = 0, hy = 0;
				function holdEnd(ev) {
					window.clearTimeout(hold); hold = null; el.classList.remove('lf-pressing');
					/* the finger lifting after a removal lands on the map (the handle is
					   gone): that tap must not deselect the shape */
					if (ev && ev.type === 'touchend' && el.lfRemoved)
						self.swallowClickUntil = Date.now() + 700;
				}
				el.addEventListener('touchstart', function(ev) {
					if (!ev.touches || ev.touches.length !== 1) return holdEnd(ev);
					hx = ev.touches[0].clientX; hy = ev.touches[0].clientY;
					el.classList.add('lf-pressing');
					hold = window.setTimeout(function() {
						hold = null;
						el.classList.remove('lf-pressing');
						if (el.lfRemoved || dragging)
							return;
						if (removeCorner()) {
							try { if (navigator.vibrate) navigator.vibrate(15); } catch (e) {}
						}
						else if (pts.length <= 3)
							self.flashNotice(_('A polygon needs at least 3 corners.'));
					}, 650);
				}, { passive: true });
				el.addEventListener('touchmove', function(ev) {
					var t = ev.touches && ev.touches[0];
					if (hold && t && Math.abs(t.clientX - hx) + Math.abs(t.clientY - hy) > 8) holdEnd();
				}, { passive: true });
				el.addEventListener('touchend', holdEnd);
				el.addEventListener('touchcancel', holdEnd);
				self.markers.push(m);
			});

			/* a handle in the middle moves the whole polygon (on phones one finger on
			   the shape scrolls the page, so this is the way to move it there) */
			var cx = 0, cy = 0;
			pts.forEach(function(p) { cx += p[0]; cy += mercDeg(Math.max(-85, Math.min(85, p[1]))); });
			cx /= pts.length; cy /= pts.length;
			var mid = new ml.Marker({ element: self.handleElement('centre'), draggable: true })
				.setLngLat([ cx, invMercDeg(cy) ]).addTo(self.map);
			/* (measured from where the handle was put, not from "dragstart": MapLibre
			   fires that only after the finger has already moved a little) */
			var orig = null, start = mid.getLngLat();
			mid.on('dragstart', function() {
				orig = pts.map(function(p) { return [ p[0], p[1] ]; });
			});
			mid.on('drag', function() {
				if (!orig) return;
				var q = mid.getLngLat(), dx = q.lng - start.lng;
				var dy = mercDeg(Math.max(-85, Math.min(85, q.lat))) - mercDeg(Math.max(-85, Math.min(85, start.lat)));
				orig.forEach(function(p, i) {
					pts[i] = [ p[0] + dx, Math.max(-85, Math.min(85, invMercDeg(mercDeg(Math.max(-85, Math.min(85, p[1]))) + dy))) ];
					if (vms[i]) vms[i].setLngLat(pts[i]);
				});
				self.updateRegionSource();
			});
			mid.on('dragend', function() {
				self.polygons[self.zone][pi] = normalizePolygon(pts);
				window.setTimeout(function() { self.regionsChanged(); self.drawServers(); }, 0);
			});
			self.markers.push(mid);
		});

		this.drawServers();
		this.renderServers();
	},

	renderRegions: function() {
		var self = this, list = this.circles[this.zone] || [], polys = this.polygons[this.zone] || [], sec = this.regionSec;
		var total = list.length + polys.length;

		function num(c, key, step, min, max, title) {
			return E('input', {
				'type': 'number', 'class': 'lf-input', 'step': step, 'min': min, 'max': max, 'title': title,
				'value': key === 'r' ? Math.round(c[key]) : c[key].toFixed(4),
				'change': function() {
					var v = parseFloat(this.value);
					if (!isFinite(v) || v < min || v > max)
						return;
					c[key] = v;
					self.regionsChanged();
				}
			});
		}

		function remove(arr, idx) {
			return E('button', {
				'class': 'lf-btn lf-sm', 'title': _('Remove'),
				'click': function(ev) { ev.preventDefault(); ev.stopPropagation(); arr.splice(idx, 1); self.selected = null; self.regionsChanged(); }
			}, '×');
		}

		var sel = this.selected || {};
		function rowAttrs(kind, idx, extra) {
			return {
				'class': 'lf-crow' + (extra || '') + (sel.kind === kind && sel.idx === idx ? ' lf-sel' : ''),
				'click': function(ev) {
					if (/^(INPUT|BUTTON)$/.test(ev.target.tagName)) return;
					self.select(kind, idx);
				}
			};
		}

		sec.innerHTML = '';
		sec.appendChild(E('h4', {}, [ _('Region'), total ? E('span', {}, '(' + total + ')') : '' ]));

		if (!this.zone) {
			sec.appendChild(E('div', { 'class': 'lf-muted lf-sm' }, _('Create a zone first.')));
			return;
		}
		if (!total) {
			sec.appendChild(E('div', { 'class': 'lf-muted lf-sm' }, this.countries.length
				? _('No circles or polygons - only the listed countries are allowed.')
				: _('Nothing drawn yet. Use Add circle or Draw polygon.')));
			this.renderListsSummary(sec);
			return;
		}

		sec.appendChild(E('div', { 'class': 'lf-circles' }, list.map(function(c, idx) {
			return E('div', rowAttrs('circle', idx), [
				E('span', {
					'class': 'lf-num', 'title': _('Show on map'),
					'click': function() { self.select('circle', idx); self.fitTo(ringBounds(circleRing(c, 32))); }
				}, '○' + (idx + 1)),
				num(c, 'lat', 'any', -90, 90, _('Latitude')),
				num(c, 'lon', 'any', -180, 180, _('Longitude')),
				num(c, 'r', '1', 1, 20000, _('Radius (km)')),
				E('span', { 'class': 'lf-muted lf-sm' }, 'km'),
				remove(list, idx)
			]);
		}).concat(polys.map(function(pts, idx) {
			return E('div', rowAttrs('polygon', idx, ' lf-poly'), [
				E('span', {
					'class': 'lf-num', 'title': _('Show on map'),
					'click': function() { self.select('polygon', idx); self.fitTo(polygonBounds(pts)); }
				}, '▱' + (idx + 1)),
				E('span', { 'class': 'lf-sm', 'style': 'flex:1' }, _('Polygon, %d corners').format(pts.length)),
				E('button', {
					'class': 'lf-btn lf-sm', 'title': _('Make every edge straight - the shape becomes a square / rectangle'),
					'click': function(ev) {
						ev.preventDefault();
						self.straightenSelected(idx);
					}
				}, _('Straighten')),
				remove(polys, idx)
			]);
		}))));
		sec.appendChild(E('div', { 'class': 'lf-muted lf-sm', 'style': 'margin-top:4px' },
			this.selected ? (this.touchScroll()
				? (this.selected.kind === 'circle' ? _('Selected - drag the middle handle to move it, the edge handle to resize it; × in its row removes it.')
					: _('Selected - drag the middle handle to move it, its corners to reshape it; hold a corner to remove it; × in its row removes it.'))
				: _('Selected - drag its handles to reshape, drag it to move it, Delete removes it, Esc deselects.'))
				: this.touchScroll() ? _('Tap a shape to edit it (handles appear). One finger moves the map, two fingers zoom; swipe beside the map to scroll the page.')
				: _('Click a shape to edit it (handles appear); drag a shape to move it.')));
		this.renderListsSummary(sec);
	},

	/* ----------------------------------------------- whitelist / blacklist */

	renderListsSummary: function(sec) {
		var self = this, r = this.rules || { allow: [], block: [] };
		if (!this.zone || !uci.get('lobbyfence', this.zone))
			return;
		sec.appendChild(E('div', { 'class': 'lf-line lf-sm', 'style': 'margin-top:8px' }, [
			E('span', { 'class': 'lf-muted' }, _('Whitelist: %d · Blacklist: %d').format((r.allow || []).length, (r.block || []).length)),
			E('button', {
				'class': 'lf-btn lf-sm', 'style': 'margin-left:auto',
				'click': function(ev) { ev.preventDefault(); self.openLists('allow'); }
			}, _('Manage lists…'))
		]));
	},

	listText: function(kind) {
		var sec = uci.get('lobbyfence', this.zone) || {}, list = (this.rules || {})[kind] || [];
		return [
			'# LobbyFence ' + (kind === 'allow' ? 'whitelist (always allowed)' : 'blacklist (always blocked)'),
			'# zone: ' + (sec.label || this.zone) + ' - exported ' + new Date().toISOString().slice(0, 10),
			'# one address or subnet per line; lines starting with # are ignored'
		].concat(list).join('\n') + '\n';
	},

	download: function(name, text) {
		var url = URL.createObjectURL(new Blob([ text ], { type: 'text/plain' }));
		var a = E('a', { 'href': url, 'download': name, 'style': 'display:none' });
		document.body.appendChild(a);
		a.click();
		window.setTimeout(function() { URL.revokeObjectURL(url); a.remove(); }, 1000);
	},

	copyText: function(text) {
		/* the clipboard API needs https; LuCI is often plain http, so fall back */
		var ta = E('textarea', { 'style': 'position:fixed;left:-9999px;top:0' });
		ta.value = text;
		document.body.appendChild(ta);
		ta.select();
		var ok = false;
		try { ok = document.execCommand('copy'); } catch (e) {}
		ta.remove();
		if (ok || !navigator.clipboard)
			return Promise.resolve(ok);
		return navigator.clipboard.writeText(text).then(function() { return true; }, function() { return false; });
	},

	openLists: function(kind) {
		var self = this, zone = this.zone, sec = uci.get('lobbyfence', zone) || {}, msg;
		var body = E('div');
		var fileInput = E('input', { 'type': 'file', 'accept': '.txt,.csv,.list,text/plain', 'style': 'display:none' });
		var replace = E('input', { 'type': 'checkbox' });
		var addBox = E('textarea', { 'class': 'cbi-input-textarea', 'rows': 3, 'style': 'width:100%',
			'placeholder': _('Addresses or subnets, e.g. 80.20.0.1 or 2a00:1450::/32 - several at once are fine') });

		function setMsg(text, bad) {
			msg.textContent = text || '';
			msg.style.color = bad ? '#d33a3a' : '';
		}

		/* add (or replace with) a list of addresses on the router - live */
		function apply(list, doReplace) {
			var cur = (self.rules || {})[kind] || [], drop, p = Promise.resolve();
			if (!list.length)
				return Promise.resolve(setMsg(_('No valid addresses found.'), true));
			if (doReplace) {
				drop = cur.filter(function(a) { return list.indexOf(a) < 0; });
				if (drop.length)
					p = p.then(function() { return self.setRule('unlist', drop); });
			}
			return p.then(function() { return self.setRule(kind, list); }).then(function() {
				draw();
				setMsg(_('%d address(es) applied.').format(list.length));
			});
		}

		function draw() {
			var list = (self.rules || {})[kind] || [], other = kind === 'allow' ? 'block' : 'allow';
			body.innerHTML = '';
			body.appendChild(E('div', { 'class': 'cbi-tabmenu', 'style': 'margin-bottom:.8em' }, [ 'allow', 'block' ].map(function(k) {
				return E('li', { 'class': 'tabmenu-item-' + k + (k === kind ? ' cbi-tab' : ' cbi-tab-disabled') }, E('a', {
					'href': '#', 'click': function(ev) { ev.preventDefault(); kind = k; setMsg(''); draw(); }
				}, (k === 'allow' ? _('Whitelist') : _('Blacklist')) + ' (' + ((self.rules || {})[k] || []).length + ')'));
			})));
			body.appendChild(E('p', { 'style': 'opacity:.8' }, kind === 'allow'
				? _('Always allowed, wherever they are located - also in strict mode. Use it for login, matchmaking and relay servers.')
				: _('Always blocked, even inside your region.')));
			body.appendChild(E('div', { 'class': 'lf-listbox', 'style': 'max-height:220px;overflow:auto;border:1px solid rgba(128,128,128,.35);border-radius:4px;margin-bottom:.8em' },
				list.length ? list.map(function(a) {
					return E('div', { 'style': 'display:flex;align-items:center;gap:.5em;padding:3px 8px;font-family:monospace' }, [
						E('span', { 'style': 'flex:1' }, a),
						E('button', { 'class': 'cbi-button cbi-button-remove', 'style': 'padding:0 .6em',
							'click': function() { self.setRule('unlist', [ a ]).then(draw); } }, '×')
					]);
				}) : E('em', { 'style': 'display:block;padding:8px' }, _('The list is empty.'))));
			body.appendChild(addBox);
			body.appendChild(E('div', { 'style': 'display:flex;flex-wrap:wrap;gap:.5em;margin:.5em 0' }, [
				E('button', { 'class': 'cbi-button cbi-button-add', 'click': function() {
					var r = parseAddressList(addBox.value);
					apply(r.list, false).then(function() { if (r.list.length) addBox.value = ''; if (r.ignored) setMsg(msg.textContent + ' ' + _('%d entries were not addresses and were skipped.').format(r.ignored)); });
				} }, kind === 'allow' ? _('Add to whitelist') : _('Add to blacklist')),
				E('span', { 'style': 'flex:1' }),
				E('button', { 'class': 'cbi-button', 'click': function() {
					self.download('lobbyfence-' + zone + '-' + (kind === 'allow' ? 'whitelist' : 'blacklist') + '.txt', self.listText(kind));
				} }, _('Download')),
				E('button', { 'class': 'cbi-button', 'click': function() { fileInput.click(); } }, _('Upload…')),
				E('button', { 'class': 'cbi-button', 'click': function() {
					self.copyText(self.listText(kind)).then(function(ok) {
						setMsg(ok ? _('Copied - paste it anywhere to share.') : _('Copying is not allowed by this browser - use Download instead.'), !ok);
					});
				} }, _('Copy'))
			]));
			body.appendChild(E('label', { 'style': 'display:flex;gap:.4em;align-items:center;font-size:90%' }, [
				replace, _('Uploading replaces the list (otherwise it is added to it)')
			]));
			body.appendChild(msg = E('p', { 'style': 'min-height:1.2em;margin:.5em 0' }));
		}

		fileInput.addEventListener('change', function() {
			var f = fileInput.files && fileInput.files[0];
			if (!f) return;
			var rd = new FileReader();
			rd.onload = function() {
				var r = parseAddressList(String(rd.result || ''));
				apply(r.list, replace.checked).then(function() {
					if (r.ignored) setMsg(msg.textContent + ' ' + _('%d entries were not addresses and were skipped.').format(r.ignored));
				});
				fileInput.value = '';
			};
			rd.readAsText(f);
		});

		draw();
		ui.showModal(_('Whitelist & blacklist - %s').format(sec.label || zone), [
			body, fileInput,
			E('p', { 'style': 'font-size:90%;opacity:.8' }, _('Changes take effect on the router immediately.')),
			E('div', { 'class': 'right' }, E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); self.renderRegions(); } }, _('Close')))
		]);
	},

	/* --------------------------------------------------- delete zone */

	confirmDeleteZone: function() {
		var self = this, zone = this.zone, sec = zone ? (uci.get('lobbyfence', zone) || {}) : null;
		if (!sec)
			return;
		ui.showModal(_('Delete zone'), [
			E('p', {}, _('Delete "%s"? Its region, its allow / block rules and the servers it learned are removed.').format(sec.label || zone)),
			E('p', { 'style': 'font-size:90%;opacity:.8' }, _('The change is saved and applied right away, together with any other unsaved changes on this page.')),
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-negative important',
					'click': function() { ui.hideModal(); self.deleteZone(zone); }
				}, _('Delete zone'))
			])
		]);
	},

	deleteZone: function(zone) {
		var next;
		uci.remove('lobbyfence', zone);
		delete this.circles[zone];
		delete this.polygons[zone];
		delete this.dirty[zone];
		window.clearTimeout(this.stageTimer);
		this.saving = false;
		if (this.popup)
			this.popup.remove();
		this.refreshZoneSelect();
		next = uci.sections('lobbyfence', 'zone')[0];
		this.showZone(next ? next['.name'] : null);
		/* Save & Apply, as LuCI's own button does */
		return typeof this.handleSaveApply === 'function' ? this.handleSaveApply(null, '0') : this.handleSave();
	},

	/* ----------------------------------------------------- new zone */

	/* the preset the zone uses: stored, or recognised from its protocol and ports */
	/* the zone's ports differ from its game preset's (narrowed with Ports seen) */
	portsNarrowed: function(p, zone) {
		var sec = uci.get('lobbyfence', zone || this.zone) || {};
		if (!p || p.custom) return false;
		var list = function(v) { return (Array.isArray(v) ? v : (v ? [ v ] : [])).map(String).sort().join(' '); };
		p = presetOn(p, sec.platform);
		return p.either ? list(sec.port) !== list(p.either) : list(sec.remote_port) !== list(p.remote);
	},

	zonePreset: function(zone) {
		var z = zone || this.zone, sec = uci.get('lobbyfence', z) || {}, p = presetById(sec.game);
		if (p)
			return p;
		var list = function(v) { return (Array.isArray(v) ? v : (v ? [ v ] : [])).map(String).sort().join(' '); };
		var rp = list(sec.remote_port), ep = list(sec.port), proto = sec.proto || 'udp';
		return PRESETS.filter(function(q) {
			return !q.custom && q.proto === proto && (q.either ? ep === list(q.either) && !rp : rp === list(q.remote) && !ep);
		})[0] || presetById('custom');
	},

	/* "Ports seen": the server ports the zone's device used while playing (the
	   router keeps them), to narrow a wide preset (Any game, Apex Legends) to
	   the ports its game really uses - so other games' traffic is left alone */
	openPortsSeen: function() {
		var self = this, zone = this.zone, sec = uci.get('lobbyfence', zone);
		if (!sec)
			return;
		var preset = this.zonePreset(zone), rows = [], picks = [];
		var stateNode = E('p', { 'class': 'lf-ports-state', 'style': 'min-height:1.2em;margin:.5em 0' });
		var listNode = E('div', { 'class': 'lf-servers-list lf-ports-list' }, E('em', {}, _('Reading the ports the router has seen…')));
		var round = E('input', { 'type': 'checkbox', 'class': 'lf-ports-round', 'checked': true, 'change': function() { preview(); } });
		var previewNode = E('p', { 'class': 'lf-ports-preview', 'style': 'font-size:90%;margin:.4em 0' });
		var liveNode = E('p', { 'class': 'lf-ports-live', 'style': 'font-size:85%;opacity:.7;margin:.3em 0' });
		var useBtn, clearBtn, busy = false, timer = null, allBox = null;
		/* the ticks the user changed by hand stay as they are when the list refreshes */
		var userSet = {};
		/* the "All" box at the top of the ticks: ticks every port seen, or none */
		function setAll(on) {
			rows.forEach(function(r) { userSet[r.proto + '/' + r.port] = on; });
			picks.forEach(function(c) { c.checked = on; });
			preview();
		}
		/* the zone's own server ports, when they are a narrow set (a game's ports, or ones
		   chosen here before): the ports seen inside them start ticked, so the list shows
		   what the zone filters now. A wide range (Any game, Apex Legends on Xbox) covers
		   nearly every port - then the busy ports are ticked for you instead */
		var zonePorts = portRanges(sec.remote_port);
		var narrow = zonePorts.length > 0 && !portRanges(sec.port).length && !portRanges(sec.local_port).length &&
			rangesSize(zonePorts) <= 20000;
		/* the order: a column, highest first (the port number: lowest first) - remembered */
		var SORTS = {
			total: function(a, b) { return b.total - a.total || b.passes - a.passes || a.port - b.port; },
			passes: function(a, b) { return b.passes - a.passes || b.total - a.total || a.port - b.port; },
			servers: function(a, b) { return b.servers - a.servers || b.total - a.total || a.port - b.port; },
			last: function(a, b) { return b.last - a.last || b.total - a.total || a.port - b.port; },
			port: function(a, b) { return a.port - b.port || (a.proto < b.proto ? -1 : a.proto > b.proto ? 1 : 0); }
		};
		var sortBy = store('portsSort');
		if (!SORTS.hasOwnProperty(sortBy))
			sortBy = 'total';
		var sortSel = E('select', { 'class': 'cbi-input-select lf-ports-sort', 'change': function() { setSort(sortSel.value); } }, [
			E('option', { 'value': 'total' }, _('Packets - most first')),
			E('option', { 'value': 'passes' }, _('Seen in - most passes first')),
			E('option', { 'value': 'servers' }, _('Servers - most first')),
			E('option', { 'value': 'last' }, _('Last seen - newest first')),
			E('option', { 'value': 'port' }, _('Server port - lowest first'))
		]);
		sortSel.value = sortBy;
		function setSort(k) {
			if (!SORTS.hasOwnProperty(k))
				return;
			sortBy = k;
			sortSel.value = k;
			store('portsSort', k);
			render();
			listNode.scrollTop = 0;
		}
		/* a column heading: click to sort by it */
		function head(label, k) {
			if (!k)
				return E('th', {}, label);
			return E('th', { 'class': 'lf-ports-head' + (sortBy === k ? ' lf-on' : ''), 'style': 'cursor:pointer;white-space:nowrap',
				'title': _('Sort by this'), 'click': function() { setSort(k); } },
				label + (sortBy === k ? (k === 'port' ? ' ▲' : ' ▼') : ''));
		}

		function ranges() {
			var nums = picks.filter(function(c) { return c.checked; }).map(function(c) { return +c.value; })
				.sort(function(a, b) { return a - b; }), out = [], cur = null;
			nums.forEach(function(p) {
				var lo = p, hi = p;
				if (round.checked) { lo = Math.floor(p / 100) * 100; hi = Math.min(lo + 99, 65535); lo = Math.max(lo, 1); }
				if (cur && lo <= cur[1] + 1) cur[1] = Math.max(cur[1], hi);
				else out.push(cur = [ lo, hi ]);
			});
			return out.map(function(r) { return r[0] === r[1] ? String(r[0]) : r[0] + '-' + r[1]; });
		}
		function preview() {
			var r = ranges(), n = picks.filter(function(c) { return c.checked; }).length;
			if (allBox) {
				allBox.checked = n > 0 && n === picks.length;
				allBox.indeterminate = n > 0 && n < picks.length;
			}
			useBtn.disabled = !r.length;
			previewNode.textContent = r.length ? _('The zone\'s server ports become: %s').format(r.join(', ')) : _('Tick the ports the game uses.');
		}
		function render() {
			var top = listNode.scrollTop;
			listNode.innerHTML = '';
			picks = [];
			allBox = null;
			if (!rows.length) {
				listNode.appendChild(E('p', { 'class': 'lf-ports-empty' }, _('Nothing seen yet. Play a few matches with this zone switched on - its ports must include the game\'s, so start from Any game or a wide preset like Apex Legends - then open this again.')));
				preview();
				return;
			}
			var now = self.routerNow();   /* "last seen" is the router's time: measure it by the router's clock */
			allBox = E('input', { 'type': 'checkbox', 'class': 'lf-ports-all', 'change': function() { setAll(allBox.checked); } });
			listNode.appendChild(E('table', { 'class': 'lf-servers-table' }, [
				E('tr', {}, [
					E('th', {}, E('label', { 'style': 'cursor:pointer;white-space:nowrap', 'title': _('Tick every port - or none') }, [ allBox, ' ', _('All') ])),
					head(_('Server port'), 'port'), head(_('Packets'), 'total'), head(_('Servers'), 'servers'),
					head(_('Seen in'), 'passes'), head(_('Last seen'), 'last') ])
			].concat(rows.slice().sort(SORTS[sortBy]).map(function(r) {
				var key = r.proto + '/' + r.port;
				var c = E('input', { 'type': 'checkbox', 'class': 'lf-ports-pick', 'value': r.port, 'change': function() { userSet[key] = c.checked; preview(); } });
				/* in the zone's ports now - or, for a wide range: busy, real game traffic (short bursts on
				   many ports are the game's data-centre pings; by the most in one pass, as a ping port
				   seen often adds up to a big total too) */
				c.checked = key in userSet ? userSet[key] : narrow ? inRanges(r.port, zonePorts) : r.peak >= 50;
				picks.push(c);
				return E('tr', {}, [
					E('td', {}, c),
					E('td', { 'class': 'lf-mono' }, E('label', { 'style': 'cursor:pointer', 'click': function(ev) { if (ev.target.tagName !== 'INPUT') { c.checked = !c.checked; userSet[key] = c.checked; preview(); } } }, key)),
					E('td', { 'title': _('Most in one pass: %d').format(r.peak) }, String(r.total)), E('td', {}, String(r.servers)),
					E('td', {}, _('%d pass(es)').format(r.passes)), E('td', {}, ago(r.last, now))
				]);
			}))));
			listNode.scrollTop = top;
			preview();
		}
		/* read again while the window is open: the router adds what it sees on
		   every learning pass, so the list follows a match as it is played */
		function load() {
			if (busy)
				return Promise.resolve();
			busy = true;
			return fs.exec('/usr/sbin/lobbyfence', [ 'ports', zone ]).then(function(r) {
				if (!r || r.code !== 0)
					throw new Error(r && (r.stderr || r.stdout) || _('no answer'));
				rows = String(r.stdout || '').split(/\n/).map(function(l) {
					var m = l.match(/^(udp|tcp)\/([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+) ([0-9]+) ([01])(?: ([0-9]+))?$/);
					return m && { proto: m[1], port: +m[2], servers: +m[3], peak: +m[4], first: +m[5], last: +m[6], passes: +m[7],
						total: m[9] != null ? +m[9] : +m[4] };
				}).filter(Boolean);
				render();
				liveNode.textContent = _('Updates by itself while this is open - last checked %s.').format(new Date().toLocaleTimeString());
			}).catch(function(err) {
				if (!rows.length)
					listNode.innerHTML = '';
				stateNode.textContent = _('Could not read them: %s').format(String(err && err.message || err).replace(/^lobbyfence: /, '').trim());
			}).then(function() { busy = false; });
		}

		clearBtn = E('button', { 'class': 'cbi-button cbi-button-negative lf-ports-clear', 'click': function() {
			fs.exec('/usr/sbin/lobbyfence', [ 'ports', zone, 'clear' ]).then(function() {
				stateNode.textContent = _('Cleared - the list starts again from the next match.');
				return load();
			}).catch(function(err) { stateNode.textContent = String(err && err.message || err); });
		} }, _('Clear list'));
		useBtn = E('button', { 'class': 'cbi-button cbi-button-positive important lf-ports-use', 'disabled': true, 'click': function() {
			var list = ranges();
			if (!list.length)
				return;
			uci.unset('lobbyfence', zone, 'port');
			uci.set('lobbyfence', zone, 'remote_port', list);
			if (!sec.game && preset && !preset.custom)
				uci.set('lobbyfence', zone, 'game', preset.id);
			ui.hideModal();
			self.stage();
			self.refreshZoneSelect();
			self.updateNotice();
			self.renderStatus();
			self.renderServers();
		} }, _('Use these ports'));

		ui.showModal(_('Ports seen - %s').format(sec.label || zone), [
			E('p', {}, _('The server ports this zone\'s device used while playing. Tick the game\'s ports and use them for the zone: it then filters only that game, and other games or apps on the device are left alone. The game stays %s.').format(preset && !preset.custom ? preset.label : _('as it is'))),
			E('label', { 'class': 'lf-ports-sortrow', 'style': 'display:block;font-size:90%;margin:.4em 0' }, [ _('Sort by') + ' ', sortSel,
				E('span', { 'style': 'opacity:.7' }, ' ' + _('(or click a column)')) ]),
			listNode,
			E('label', { 'style': 'display:block;font-size:90%;margin:.4em 0' }, [ round, ' ', _('Round to blocks of 100 ports (the game\'s next servers often use a nearby port)') ]),
			previewNode,
			liveNode,
			E('p', { 'class': 'lf-ports-help', 'style': 'font-size:90%;opacity:.8' }, narrow
				? _('Packets: what the device sent on the port while LobbyFence watched - it grows while you play. Ticked: the ports inside the zone\'s server ports now - untick one to leave it out, tick others to add them. The many short ones are usually the game measuring the ping to its data centres - keep those ticked to keep far data centres blocked there as well.')
				: _('Packets: what the device sent on the port while LobbyFence watched - it grows while you play. Ticked for you: ports with real game traffic (50+ packets in one pass). The many short ones are usually the game measuring the ping to its data centres - tick those too to keep far data centres blocked there as well.')),
			stateNode,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				clearBtn, ' ', useBtn
			])
		]);
		load();
		/* every 5 s until the window closes (Cancel, Use these ports, or another window) */
		timer = window.setInterval(function() {
			if (!document.body.contains(listNode)) {
				window.clearInterval(timer);
				return;
			}
			load();
		}, 5000);
	},

	/* switch a zone to another game: its ports, protocol and the game's recommended
	   settings - the device and the region stay; the learned servers are kept by
	   the router under the old game (Servers file) and the zone learns anew */
	openChangeGame: function() {
		var self = this, zone = this.zone, sec = uci.get('lobbyfence', zone);
		if (!sec)
			return;
		var old = this.zonePreset(zone), preset = old;
		var arr = function(v) { return Array.isArray(v) ? v : (v ? [ v ] : []); };
		var curPorts = arr(sec.port).length ? arr(sec.port) : arr(sec.remote_port);
		var game = E('select', { 'class': 'cbi-input-select lf-cg-game', 'style': 'width:100%' },
			PRESET_GROUPS.map(function(g) {
				return E('optgroup', { 'label': g[1] }, PRESETS.filter(function(p) { return p.group === g[0]; }).map(function(p) {
					return E('option', { 'value': p.id }, p.label);
				}));
			}));
		var info = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var platform = platformSelect('lf-cg-platform');
		var platformRow = E('div', { 'style': 'margin:.6em 0' }, [ E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' }, _('Device type')), platform,
			E('div', { 'class': 'lf-cg-platinfo', 'style': 'font-size:90%;opacity:.8;margin-top:.3em' }) ]);
		var ports = E('input', { 'class': 'cbi-input-text lf-cg-ports', 'style': 'width:100%' });
		var portsLabel = E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' });
		var proto = E('select', { 'class': 'cbi-input-select lf-cg-proto' }, [
			E('option', { 'value': 'udp' }, 'UDP'), E('option', { 'value': 'tcp' }, 'TCP'), E('option', { 'value': 'both' }, _('UDP and TCP'))
		]);
		var burst = E('input', { 'class': 'cbi-input-text lf-cg-burst', 'type': 'number', 'min': 0, 'max': 10000, 'style': 'width:6em' });
		var hint = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var rename = E('input', { 'type': 'checkbox', 'class': 'lf-cg-rename' });
		var renameRow = E('label', { 'style': 'display:flex;gap:.5em;align-items:center;margin:.6em 0' }, [ rename, E('span') ]);
		var error = E('p', { 'style': 'color:#d33a3a;min-height:1.2em;margin:.5em 0 0' });
		var keepNote = E('p', { 'class': 'lf-cg-keep', 'style': 'font-size:90%;margin:.6em 0;display:none' });
		var label = sec.label || zone;
		var oldGame = /^[a-z0-9_]+$/.test(sec.game || '') ? sec.game : 'other';
		var oldName = (presetById(oldGame) || {}).label || (oldGame === 'other' ? _('no game') : oldGame);

		function row(l, fields) {
			return E('div', { 'style': 'margin:.6em 0' }, [ E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' }, l) ].concat(fields));
		}
		/* fill in what the chosen game uses; the zone's own values while it is the same game */
		function fill(first) {
			var base = presetById(game.value) || old;
			platformRow.style.display = needsPlatform(base) ? '' : 'none';
			platformRow.lastChild.textContent = !needsPlatform(base) ? '' : (base.platforms
				? _('%s uses other ports on each device type.').format(base.name || base.label)
				: _('Same ports on every device type.'));
			preset = needsPlatform(base) ? presetOn(base, platform.value) : base;
			portsLabel.textContent = preset.either ? _('Game ports (either side)') : _('Game server ports');
			info.textContent = presetSummary(preset);
			if (first) {
				proto.value = sec.proto || preset.proto;
				ports.value = curPorts.join(' ');
				var bs = sec.burst_servers;
				burst.value = (bs == null || bs === '') ? '0' : String(bs);
			}
			else {
				proto.value = preset.proto;
				ports.value = (preset.remote || preset.either || []).join(' ');
				burst.value = String(preset.burst || 0);
			}
			ports.placeholder = preset.custom ? _('e.g. 3074 or 30000-45000') : '';
			hint.textContent = burstAdvice(preset.burst != null ? preset : null);
			var newName = preset.custom ? '' : (preset.name != null ? preset.name : preset.label);
			var wasDefault = !old.custom && (label === old.label || label === old.name);
			renameRow.style.display = newName && newName !== label ? '' : 'none';
			renameRow.lastChild.textContent = _('Rename the zone to "%s"').format(newName);
			rename.checked = wasDefault;
			rename.dataset.name = newName;
			var other = preset.id !== oldGame;
			keepNote.style.display = other ? '' : 'none';
			keepNote.textContent = other ? _('The servers this zone learned for %s stay saved under %s, with their locations (see Servers file) - nothing is looked up again. The zone then learns %s\'s servers from scratch, so the two games\' servers are never mixed.')
				.format(oldName, oldName, preset.label) : '';
		}
		game.value = old.id;
		platform.value = /^(pc|ps|xbox)$/.test(sec.platform || '') ? sec.platform : '';
		game.addEventListener('change', function() { fill(false); });
		platform.addEventListener('change', function() { fill(false); });
		fill(true);

		ui.showModal(_('Change game – %s').format(label), [
			E('p', {}, _('Pick another game to use its ports and recommended settings. The device and the region you drew stay as they are.')),
			row(_('Game'), [ game, info ]),
			platformRow,
			keepNote,
			E('div', { 'style': 'display:flex;gap:1em;flex-wrap:wrap' }, [
				E('div', { 'style': 'flex:1 1 240px' }, E('div', { 'style': 'margin:.6em 0' }, [ portsLabel, ports ])),
				E('div', {}, row(_('Protocol'), [ proto ]))
			]),
			row(_('Open for server tests'), [
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [ _('more than'), burst, _('servers at once (0 = off)') ]),
				hint
			]),
			renameRow,
			error,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive important lf-cg-apply',
					'click': function() {
						var list = parsePorts(ports.value), bn = parseInt(burst.value || '0', 10);
						if (needsPlatform(preset) && !platform.value)
							return (error.textContent = _('Choose the device type - %s.').format(_('PC, PlayStation or Xbox')));
						if (list === null)
							return (error.textContent = _('Ports must be numbers (1-65535) or ranges like 30000-45000.'));
						if (!list.length)
							return (error.textContent = _('Enter the game\'s ports.'));
						if (!isFinite(bn) || bn < 0 || bn > 10000)
							return (error.textContent = _('Open for server tests: 0-10000 servers.'));
						uci.set('lobbyfence', zone, 'proto', proto.value);
						if (preset.either) {
							uci.set('lobbyfence', zone, 'port', list);
							uci.unset('lobbyfence', zone, 'remote_port');
						}
						else {
							uci.set('lobbyfence', zone, 'remote_port', list);
							uci.unset('lobbyfence', zone, 'port');
						}
						uci.set('lobbyfence', zone, 'game', preset.id);
						if (needsPlatform(preset))
							uci.set('lobbyfence', zone, 'platform', platform.value);
						else
							uci.unset('lobbyfence', zone, 'platform');
						uci.set('lobbyfence', zone, 'burst_servers', String(bn));
						if (!sec.burst_open)
							uci.set('lobbyfence', zone, 'burst_open', '20');
						if (rename.checked && rename.dataset.name && renameRow.style.display !== 'none')
							uci.set('lobbyfence', zone, 'label', rename.dataset.name);
						ui.hideModal();
						self.stage();
						self.refreshZoneSelect();
						self.updateNotice();
						self.renderStatus();
						self.renderServers();
					}
				}, _('Change'))
			])
		]);
	},

	openNewZone: function() {
		var self = this, preset = presetById(DEFAULT_PRESET), nameTouched = false, portsTouched = false;

		var game = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%' },
			PRESET_GROUPS.map(function(g) {
				return E('optgroup', { 'label': g[1] }, PRESETS.filter(function(p) { return p.group === g[0]; }).map(function(p) {
					return E('option', { 'value': p.id }, p.label);
				}));
			}));
		var gameInfo = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var platform = platformSelect('lf-nz-platform');
		var platformInfo = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var platformRow = E('div', { 'style': 'margin:.6em 0' }, [ E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' }, _('Device type')), platform, platformInfo ]);
		var name = E('input', { 'class': 'cbi-input-text', 'placeholder': _('e.g. My shooter'), 'style': 'width:100%',
			'input': function() { nameTouched = !!this.value; } });
		var devicePick = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%;display:none' });
		var device = E('input', { 'class': 'cbi-input-text', 'placeholder': _('192.168.1.50 or aa:bb:cc:dd:ee:ff'), 'style': 'width:100%' });
		var deviceInfo = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var proto = E('select', { 'class': 'cbi-input-select' }, [
			E('option', { 'value': 'udp' }, 'UDP'),
			E('option', { 'value': 'tcp' }, 'TCP'),
			E('option', { 'value': 'both' }, _('UDP and TCP'))
		]);
		var ports = E('input', { 'class': 'cbi-input-text', 'style': 'width:100%',
			'input': function() { portsTouched = true; } });
		var portsLabel = E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' }, _('Game ports'));
		var modeTouched = false;
		var modeSel = E('select', { 'class': 'cbi-input-select', 'style': 'width:100%', 'change': function() { modeTouched = true; } }, [
			E('option', { 'value': 'strict' }, _('Strict - block everything outside the region and anything not located yet')),
			E('option', { 'value': 'enforce' }, _('Enforce - block servers located outside the region')),
			E('option', { 'value': 'monitor' }, _('Monitor - only learn and show, block nothing'))
		]);
		var burst = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 0, 'max': 10000, 'style': 'width:6em',
			'input': function() { burstTouched = true; } });
		var burstOpen = E('input', { 'class': 'cbi-input-text', 'type': 'number', 'min': 1, 'max': 3600, 'value': 20, 'style': 'width:6em' });
		var burstTouched = false;
		var burstHint = E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' });
		var error = E('p', { 'style': 'color:#d33a3a;min-height:1.2em;margin:.5em 0 0' });

		function row(label, fields) {
			return E('div', { 'style': 'margin:.6em 0' }, [
				typeof label === 'string' ? E('label', { 'style': 'display:block;font-weight:bold;margin-bottom:.2em' }, label) : label
			].concat(fields));
		}

		function applyPreset() {
			var base = presetById(game.value) || presetById(DEFAULT_PRESET);
			platformRow.style.display = needsPlatform(base) ? '' : 'none';
			platformInfo.textContent = !needsPlatform(base) ? '' : (base.platforms
				? _('%s uses other ports on each device type.').format(base.name || base.label)
				: _('Same ports on every device type.'));
			preset = needsPlatform(base) ? presetOn(base, platform.value) : base;
			proto.value = preset.proto;
			if (!portsTouched)
				ports.value = (preset.remote || preset.either).join(' ');
			portsLabel.textContent = preset.either ? _('Game ports (either side)') : _('Game server ports');
			gameInfo.textContent = presetSummary(preset);
			/* the game's recommendation (Apex Legends 2, Call of Duty 0, unknown games 0) */
			if (!burstTouched)
				burst.value = String(preset.burst || 0);
			/* a game that needs a gentler start (Any mobile game: Enforce) */
			if (!modeTouched)
				modeSel.value = preset.mode || 'strict';
			burstHint.textContent = burstAdvice(preset.burst != null ? preset : null);
			if (!nameTouched)
				name.value = preset.name != null ? preset.name : preset.label;
			if (preset.custom && !portsTouched)
				ports.placeholder = _('e.g. 3074 or 30000-45000');
		}

		var devices = [];
		function applyDevice() {
			var manual = !devicePick.options.length || devicePick.value === '';
			var d = manual ? null : devices.filter(function(x) { return x.mac === devicePick.value; })[0];
			device.style.display = manual ? '' : 'none';
			if (d) {
				deviceInfo.innerHTML = '';
				deviceInfo.appendChild(E('div', { 'style': 'font-family:monospace' }, [
					E('div', {}, 'IPv4: ' + (d.ipv4.join(', ') || '-')),
					E('div', {}, 'IPv6: ' + (d.ipv6.join(', ') || '-')),
					E('div', {}, 'MAC:  ' + d.mac.toUpperCase())
				]));
				deviceInfo.appendChild(E('div', { 'style': 'margin-top:.3em' }, _('Matched by MAC address, so all of these addresses are covered. On an iPhone set "Private Wi-Fi Address" to Fixed (or Off) for your home network.')));
				return;
			}
			deviceInfo.textContent = (manual && !isMac(device.value))
				? _('An IP address only covers that one address. For phones and tablets pick the device from the list (or enter its MAC address) so all of its IPv4 and IPv6 addresses are covered.')
				: _('Matched by MAC address: covers all of the device\'s IPv4 and IPv6 addresses. On an iPhone set "Private Wi-Fi Address" to Fixed (or Off) for your home network; on Android keep the same MAC for your home network.');
		}

		game.addEventListener('change', function() { portsTouched = false; applyPreset(); });
		platform.addEventListener('change', function() { portsTouched = false; applyPreset(); });
		devicePick.addEventListener('change', applyDevice);
		device.addEventListener('input', applyDevice);
		game.value = DEFAULT_PRESET;
		modeSel.value = 'strict';
		applyPreset();
		applyDevice();

		/* devices the router knows (DHCP / neighbours) */
		loadDevices().then(function(list) {
			if (!list.length)
				return;
			devices = list;
			list.forEach(function(d) {
				devicePick.appendChild(E('option', { 'value': d.mac }, deviceLabel(d)));
			});
			devicePick.appendChild(E('option', { 'value': '' }, _('Enter an address manually…')));
			devicePick.style.display = '';
			applyDevice();
		});

		ui.showModal(_('New zone'), [
			E('p', {}, _('A zone is one game on one of your devices. Pick the game to fill in its ports - or "Any game" if it is not listed.')),
			row(_('Game'), [ game, gameInfo ]),
			platformRow,
			row(_('Device'), [ devicePick, device, deviceInfo ]),
			row(_('Name'), [ name ]),
			E('div', { 'style': 'display:flex;gap:1em;flex-wrap:wrap' }, [
				E('div', { 'style': 'flex:1 1 240px' }, row(portsLabel, [ ports ])),
				E('div', {}, row(_('Protocol'), [ proto ]))
			]),
			row(_('Filtering'), [ modeSel ]),
			row(_('Open for server tests'), [
				E('div', { 'style': 'display:flex;gap:.5em;align-items:center;flex-wrap:wrap' }, [
					_('more than'), burst, _('servers at once opens the zone for'), burstOpen, _('seconds')
				]),
				E('div', { 'style': 'font-size:90%;opacity:.8;margin-top:.3em' },
					_('Lets every server through for a moment when the game tests many data centres at once (0 = off).')),
				burstHint
			]),
			E('p', { 'style': 'font-size:90%;opacity:.8' },
				_('After creating the zone, draw your region on the map and press Save & Apply. Until a region is drawn, every server is blocked (except your whitelist).')),
			error,
			E('div', { 'class': 'right' }, [
				E('button', { 'class': 'cbi-button', 'click': ui.hideModal }, _('Cancel')), ' ',
				E('button', {
					'class': 'cbi-button cbi-button-positive important',
					'click': function() {
						var dev = (devicePick.options.length && devicePick.value) ? devicePick.value : device.value.trim();
						var label = name.value.trim() || preset.label, list = parsePorts(ports.value);
						if (needsPlatform(preset) && !platform.value)
							return (error.textContent = _('Choose the device type - %s.').format(_('PC, PlayStation or Xbox')));
						if (!validDevice(dev))
							return (error.textContent = _('Pick a device, or enter a valid IPv4/IPv6 or MAC address.'));
						if (list === null)
							return (error.textContent = _('Ports must be numbers (1-65535) or ranges like 30000-45000.'));
						if (preset.custom && !list.length)
							return (error.textContent = _('Custom: enter the game\'s server ports.'));
						if (preset.custom && !name.value.trim())
							return (error.textContent = _('Custom: give the zone a name.'));
						var bn = parseInt(burst.value || '0', 10), bo = parseInt(burstOpen.value || '20', 10);
						if (!isFinite(bn) || bn < 0 || bn > 10000 || !isFinite(bo) || bo < 1 || bo > 3600)
							return (error.textContent = _('Open for server tests: 0-10000 servers and 1-3600 seconds.'));

						var sid = createZone(uci, {
							label: label, device: dev, proto: proto.value,
							mode: modeSel.value === 'monitor' ? 'monitor' : 'enforce',
							strict: modeSel.value === 'strict',
							remotePorts: preset.either ? [] : list,
							eitherPorts: preset.either ? list : [],
							burst: bn, burstOpen: bo, game: preset.id,
							platform: needsPlatform(preset) ? platform.value : ''
						});
						self.circles[sid] = [];
						self.polygons[sid] = [];
						ui.hideModal();
						self.stage(true);
						self.refreshZoneSelect();
						self.showZone(sid);
						self.setDrawMode('circle');
					}
				}, _('Create zone'))
			])
		]);
		window.setTimeout(function() { game.focus(); }, 50);
	},

	handleSave: function() {
		var self = this;
		window.clearTimeout(this.stageTimer);
		Object.keys(this.dirty).forEach(function(zone) { self.writeRegions(zone); });
		this.dirty = {};
		return (this.saveChain || Promise.resolve()).then(function() {
			return uci.save();
		}).then(function(r) {
			self.saving = false;
			self.pendingApply = false;
			return r;
		});
	},

	/* "Reset": throw away the saved-but-not-applied LobbyFence changes */
	handleReset: function() {
		window.clearTimeout(this.stageTimer);
		return L.resolveDefault(callRevert('lobbyfence'), null).then(function() {
			window.location.reload();
		});
	}
});
