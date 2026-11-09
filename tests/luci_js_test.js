// Checks for the LuCI views without a browser: syntax, map geometry, the
// MapLibre module loader and the "new zone" flow.   usage: node luci_js_test.js
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const VIEWS = path.join(__dirname, '../luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence');
let failures = 0;
function check(name, fn) {
	return Promise.resolve().then(fn).then(
		() => console.log('PASS: ' + name),
		(e) => { failures++; console.log('FAIL: ' + name + ' - ' + e.message); });
}

// LuCI loads a view as the body of a function and calls it with the
// required modules - do the same here. `edit` may patch the source first.
function loadView(file, deps, exportHelpers, edit) {
	let src = fs.readFileSync(path.join(VIEWS, file), 'utf8');
	if (edit) src = edit(src);
	if (exportHelpers)
		src = src.replace(/return view\.extend\(\{/, 'return { helpers: { ' + exportHelpers.map((h) => h + ': ' + h).join(', ') +
			' }, view: view.extend({').replace(/\}\);\s*$/, '}) };\n');
	return new Function(...Object.keys(deps), src)(...Object.values(deps));
}

// --- tiny browser + LuCI stand-ins
global.window = global;
global.L = {
	resource: (p) => '/luci-static/resources/' + p,
	toArray: (v) => (v == null ? [] : Array.isArray(v) ? v : String(v).split(/\s+/).filter(Boolean)),
	resolveDefault: (p, d) => Promise.resolve(p).catch(() => d)
};
global._ = (s) => s;
String.prototype.format = function () { let i = 0; const a = arguments; return this.replace(/%[sd]/g, () => a[i++]); };
const links = [];
global.document = {
	head: { appendChild: (el) => links.push(el) },
	createElement: (tag) => ({ tag, setAttribute() {}, textContent: '' }),
	getElementById: () => null,
	querySelector: () => null
};
const stubs = {
	view: { extend: (o) => o }, uci: { get: () => null }, fs: {}, ui: {}, form: {},
	rpc: { declare: () => () => Promise.resolve({}) }, poll: { add() {} },
	network: { getHostHints: () => Promise.resolve(null) }
};
const HELPERS = [ 'distanceKm', 'destination', 'circleRing', 'wrapLon', 'parseCircles', 'formatCircle', 'parseServers',
	'validAddress', 'parsePorts', 'portRanges', 'inRanges', 'rangesSize', 'newerVersion', 'sectionName', 'createZone', 'loadMaplibre', 'importModule', 'MAPLIBRE_BASES',
	'themedStyle', 'rasterStyle', 'THEMES', 'THEME_ORDER', 'DEFAULT_THEME', 'flag', 'ago', 'ringBounds',
	'PRESETS', 'PRESET_GROUPS', 'DEFAULT_PRESET', 'presetById', 'presetSummary', 'burstAdvice', 'presetOn', 'needsPlatform', 'PLATFORMS', 'isMac', 'validDevice',
	'mercY', 'normalizePolygon', 'inPolygon', 'parsePolygons', 'formatPolygon', 'v4num', 'v6groups', 'cidrMatch', 'inList',
	'edgeKind', 'alignedKind', 'straightenPolygon', 'mercArea', 'satelliteStyle',
	'parseAddressList', 'deviceLabel', 'RANGES', 'addExtraLabels', 'WORLD_BOUNDS' ];

// even-odd point in polygon on plain lon/lat (what the map draws in mercator)
function inRing(ring, lon, lat) {
	let inside = false;
	for (let i = 0, j = ring.length - 1; i < ring.length; j = i++) {
		const [ xi, yi ] = ring[i], [ xj, yj ] = ring[j];
		if ((yi > lat) !== (yj > lat) && lon < (xj - xi) * (lat - yi) / (yj - yi) + xi)
			inside = !inside;
	}
	return inside;
}
// drawn polygons may extend past +-180; a point shows inside if any world copy is inside
const inDrawn = (ring, lon, lat) => [ -360, 0, 360 ].some((k) => inRing(ring, lon + k, lat));

(async () => {
	for (const f of [ 'map.js', 'zones.js' ])
		await check('syntax ' + f, () => { loadView(f, stubs); });

	await check('no Leaflet left in the views', () => {
		for (const f of [ 'map.js', 'zones.js' ])
			assert(!/leaflet/i.test(fs.readFileSync(path.join(VIEWS, f), 'utf8')), f);
	});

	const mod = loadView('map.js', stubs, HELPERS);
	const h = mod.helpers, v = mod.view;

	await check('MapLibre pinned to an exact version on two CDNs', () => {
		assert.strictEqual(h.MAPLIBRE_BASES.length, 2);
		h.MAPLIBRE_BASES.forEach((b) => assert(/maplibre-gl@\d+\.\d+\.\d+\/dist$/.test(b), b));
	});

	await check('distance Frankfurt-Paris ~ 479 km', () => {
		const d = h.distanceKm(50.1109, 8.6821, 48.8566, 2.3522);
		assert(Math.abs(d - 479) < 3, d);
	});

	await check('destination keeps the radius on every bearing', () => {
		for (let b = 0; b < 360; b += 30) {
			const p = h.destination(50, 8, 800, b);
			assert(Math.abs(h.distanceKm(50, 8, p[1], p[0]) - 800) < 0.01, b);
		}
	});

	// compare drawn polygons with the haversine rule the router uses
	function ringMatches(c, label) {
		const ring = h.circleRing(c, 180);
		assert.deepStrictEqual(ring[0], ring[ring.length - 1], label + ': ring not closed');
		let wrong = 0, total = 0;
		for (let lat = -84; lat <= 84; lat += 3)
			for (let lon = -179; lon <= 179; lon += 3) {
				const d = h.distanceKm(c.lat, c.lon, lat, lon);
				if (Math.abs(d - c.r) < 60) continue;          // skip the boundary band
				total++;
				if (inDrawn(ring, lon, lat) !== (d < c.r)) wrong++;
			}
		assert(wrong === 0, label + ': ' + wrong + ' of ' + total + ' sample points disagree');
	}
	await check('circle polygon: ordinary circle', () => ringMatches({ lat: 50.11, lon: 8.68, r: 800 }, 'Frankfurt'));
	await check('circle polygon: across the antimeridian', () => ringMatches({ lat: -17.7, lon: 178.1, r: 1500 }, 'Fiji'));
	await check('circle polygon: around the north pole', () => ringMatches({ lat: 72, lon: -40, r: 2500 }, 'Greenland'));
	await check('circle polygon: around the south pole', () => ringMatches({ lat: -75, lon: 120, r: 2200 }, 'Antarctica'));
	await check('circle polygon: huge circle', () => ringMatches({ lat: 10, lon: 20, r: 9000 }, 'huge'));
	await check('circle polygon: both poles -> whole map', () => {
		const ring = h.circleRing({ lat: 0, lon: 0, r: 15000 });
		assert(inDrawn(ring, 120, 60) && inDrawn(ring, -120, -60));
	});

	await check('parseCircles keeps valid, drops junk', () => {
		const c = h.parseCircles([ '50.1,8.6,800', 'x,1,2', '95,0,10', '1,2', '10,20,-5', '-33.9,151.2,1500' ]);
		assert.deepStrictEqual(c, [ { lat: 50.1, lon: 8.6, r: 800 }, { lat: -33.9, lon: 151.2, r: 1500 } ]);
	});
	await check('formatCircle rounds and wraps longitude', () => {
		assert.strictEqual(h.formatCircle({ lat: 50.123456, lon: -8.5, r: 799.6 }), '50.1235,-8.5000,800');
		assert.strictEqual(h.formatCircle({ lat: 0, lon: 190, r: 10 }), '0.0000,-170.0000,10');
	});
	await check('parseServers keeps unlocated rows without coordinates', () => {
		const s = h.parseServers('45.1.1.1 in 50.1 8.6 DE 1\n9.9.9.9 pending - - -- 5\n\n80.1.1.1 out 40.7 -74 US 2\n<b> in 1 2 XX 3\n');
		assert.strictEqual(s.length, 3);
		assert.deepStrictEqual(s[1], { ip: '9.9.9.9', state: 'pending', lat: null, lon: null, cc: '', ts: 5 });
		assert.strictEqual(s[2].cc, 'US');
		assert.strictEqual(s[2].ts, 2);
	});

	await check('device address validation', () => {
		[ '192.168.1.50', '10.0.0.0/24', 'fd00::100', '2001:db8::/64' ].forEach((a) => assert(h.validAddress(a), a));
		[ '', 'console', '192.168.1', '300.1.1.1', '1.2.3.4/33', 'fd00::1::2', 'fd00::/129' ].forEach((a) => assert(!h.validAddress(a), a));
	});
	await check('every preset is well formed', () => {
		const groups = h.PRESET_GROUPS.map((g) => g[0]), ids = new Set();
		assert(h.PRESETS.length >= 15, h.PRESETS.length);
		h.PRESETS.forEach((p) => {
			assert(!ids.has(p.id), 'duplicate id ' + p.id); ids.add(p.id);
			assert(groups.includes(p.group), p.id + ' group');
			assert([ 'udp', 'tcp', 'both' ].includes(p.proto), p.id + ' proto');
			assert(!!p.remote !== !!p.either, p.id + ' needs exactly one of remote/either');
			const ports = h.parsePorts((p.remote || p.either).join(' '));
			assert(ports && (ports.length || p.custom), p.id + ' ports ' + (p.remote || p.either));
			// where the ports come from - or, not known yet, every UDP port to narrow with Ports…
			assert(p.group === 'any' || p.source || (p.unmeasured && p.wide && p.remote.join() === '1024-65535'), p.id + ' source');
			assert(h.presetSummary(p).length > 0);
		});
		assert(h.presetById(h.DEFAULT_PRESET).group === 'any');
		assert(h.PRESET_GROUPS.every((g) => h.PRESETS.some((p) => p.group === g[0])), 'no empty group');
		[ 'pc', 'mobile' ].forEach((g) => {
			const labels = h.PRESETS.filter((p) => p.group === g).map((p) => p.label.toLowerCase());
			assert.deepStrictEqual(labels, labels.slice().sort(), g + ' games A to Z');
		});
	});
	await check('new games: Marvel Rivals, Roblox, GTA Online, Battlefield and more', () => {
		const P = (id) => h.presetById(id);
		assert.deepStrictEqual(P('roblox').remote, [ '49152-65535' ]);                  // Roblox support
		assert.deepStrictEqual(P('roblox_m').remote, [ '49152-65535' ]);
		assert(P('roblox').official && P('roblox').wide && P('roblox_m').group === 'mobile');
		assert.deepStrictEqual(P('gta').either, [ '6672', '61455-61458' ]);             // Rockstar, GTA Online & Red Dead Online
		assert.strictEqual(P('gta').burst, 0, 'peer-to-peer: a session is many players at once - never open for them');
		assert(/0 \(off\)/.test(h.burstAdvice(P('gta'))) && /GTA Online/.test(h.burstAdvice(P('gta'))));
		assert(/either side/.test(h.presetSummary(P('gta'))) && /Peer-to-peer/.test(h.presetSummary(P('gta'))));
		assert.deepStrictEqual(P('r6').remote, [ '3074', '6015', '10000-10099' ]);
		assert(/reported by players/.test(h.presetSummary(P('r6'))));
		[ 'marvelrivals', 'battlefield', 'eafc', 'pubg', 'arcraiders', 'dbd' ].forEach((id) => {
			const p = P(id);
			assert(p && p.group === 'pc' && h.needsPlatform(p), id);
			assert.deepStrictEqual(p.remote, [ '1024-65535' ], id + ': every UDP port until measured');
			assert(/match ports not known yet/.test(h.presetSummary(p)) && /Ports…/.test(h.presetSummary(p)), id + ' says so');
			assert(p.burst == null, id + ': general advice');
		});
	});
	await check('preset ports match the published numbers', () => {
		const P = (id) => h.presetById(id);
		assert.deepStrictEqual(P('codm').remote, [ '7500-8000' ]);                     // Activision, CoD Mobile
		assert.deepStrictEqual(P('cod').either, [ '3074-3079' ]);                      // Activision, consoles/PC
		assert.deepStrictEqual(P('valorant').remote, [ '7000-8000', '8180-8181' ]);    // Riot
		assert.deepStrictEqual(P('lol').remote, [ '5000-5500' ]);                      // Riot
		assert.deepStrictEqual(P('rocketleague').remote, [ '7000-9000' ]);             // Psyonix
		assert.deepStrictEqual(P('apex').remote, [ '1024-65535' ]);                   // matches seen on 10200/10600, pings on 270xx
		assert.deepStrictEqual(P('any_udp').remote, [ '1024-65535' ]);
		assert(h.PRESETS.filter((p) => p.group === 'mobile').length >= 6);
		assert(/community|reported/.test(h.presetSummary(P('pubgm'))), 'community presets say so');
		assert(/published by Activision/.test(h.presetSummary(P('codm'))));
	});
	await check('open for server tests: per-game recommendation, custom preset', () => {
		const P = (id) => h.presetById(id);
		// device types: PC & console games are picked with one; some have their own ports on each
		assert.deepStrictEqual(h.PLATFORMS.map(function(x) { return x[0]; }), [ 'pc', 'ps', 'xbox', 'switch' ]);
		assert.deepStrictEqual(h.PLATFORMS.filter(function(x) { return x[2]; }).map(function(x) { return x[1]; }), [ 'PlayStation', 'Xbox', 'Nintendo Switch' ], 'the consoles');
		assert(h.needsPlatform(P('cod')) && h.needsPlatform(P('fortnite')) && !h.needsPlatform(P('any_udp')) && !h.needsPlatform(P('codm')));
		assert.deepStrictEqual(h.presetOn(P('fortnite'), 'ps').remote, [ '9000-9199', '10100-10199', '15000-15199', '22200-22299', '36300-36399', '37500-37599', '39900-39999', '41700-41799', '42100-42199', '48200-48299', '51100-51199', '53700-53799', '56100-56199' ]);
		assert.deepStrictEqual(h.presetOn(P('fortnite'), 'pc').remote, [ '9000-9199', '10500-10599', '15000-15199', '22200-22299', '30300-30399', '32900-32999', '35000-35099', '36800-36899', '39200-39299', '45100-45199' ]);
		assert.deepStrictEqual(h.presetOn(P('apex'), 'pc').remote, [ '7700-7799', '8100-8199', '9000-9099', '10000-10599', '10700-10899', '15000-15099', '22200-22299', '27000-27199', '49000-49099' ]);
		assert.deepStrictEqual(h.presetOn(P('apex'), 'ps').remote, [ '1000-1099', '1900-1999', '3000-3199', '7700-7799', '8100-8199', '10000-10999', '27000-27199', '27500-27599', '34100-34199' ]);
		assert.deepStrictEqual(h.presetOn(P('apex'), 'xbox').remote, [ '1024-65535' ], 'Xbox not measured: every port');
		assert.deepStrictEqual(h.presetOn(P('apex'), 'switch').remote, [ '1024-65535' ], 'Nintendo Switch not measured: every port');
		assert.deepStrictEqual(h.presetOn(P('cod'), 'ps').either, [ '3074-3079' ], 'same ports on every device type');
		assert(!h.presetOn(P('fortnite'), 'ps').wide && P('fortnite').wide, 'presetOn does not change the preset itself');
		assert.strictEqual(P('apex').burst, 2, 'Apex Legends needs 2 or more');
		assert.strictEqual(P('cod').burst, 0, 'Call of Duty stays off');
		assert.strictEqual(P('codm').burst, 0);
		assert(/Apex Legends: 2 or more/.test(h.burstAdvice(P('apex'))));
		assert(/Call of Duty.*0 \(off\)/.test(h.burstAdvice(P('cod'))));
		assert(/Apex Legends and Fortnite need 2 or more.*Call of Duty should stay at 0/.test(h.burstAdvice(null)), 'unknown game: general advice');
		assert.strictEqual(P('fortnite').burst, 2, 'Fortnite: 2 by default');
		assert.strictEqual(P('fortnite_m').burst, 2, 'Fortnite (mobile): 2 by default');
		assert(/Fortnite: 2 or more/.test(h.burstAdvice(P('fortnite'))));
		assert.strictEqual(P('any_udp').name, 'Any game', 'Any game has a name like the others');
		assert(P('custom') && P('custom').custom && P('custom').group === 'any');
	});
	await check('Any mobile game: TCP 443 + the mobile games\' TCP ports, gentle start', () => {
		const m = h.presetById('any_mobile');
		assert(m && m.group === 'any' && m.proto === 'tcp', 'TCP preset in "Any game"');
		assert(m.remote.includes('443'), 'port 443');
		[ '65010', '65050' ].forEach((p) => assert(m.remote.includes(p), 'CoD Mobile lobby/chat ' + p));   // Activision
		[ '30000-30999', '9330-9340', '10001-10094', '17500', '39003' ].forEach((p) => assert(m.remote.includes(p), p));
		assert(!m.remote.includes('80'), 'plain HTTP left out');
		assert(h.parsePorts(m.remote.join(' ')).length === m.remote.length, 'all ports valid');
		assert.strictEqual(m.mode, 'enforce', 'Enforce, not Strict: apps keep working until a server is located');
		assert.strictEqual(m.burst, 0);
		assert(/TCP 443/.test(h.presetSummary(m)) && /won't load/.test(h.presetSummary(m)), 'says what it does to apps');
	});
	await check('device: MAC or IP', () => {
		[ 'aa:bb:cc:dd:ee:ff', 'AA-BB-CC-DD-EE-FF', '192.168.1.5', 'fd00::5' ].forEach((d) => assert(h.validDevice(d), d));
		[ 'aa:bb:cc:dd:ee', 'phone', 'aa:bb:cc:dd:ee:fg' ].forEach((d) => assert(!h.validDevice(d), d));
		[ '2001:db8::1', '::1', 'fe80::1/64', '1:2:3:4:5:6:7:8', '::ffff:192.168.1.1', '2001:db8::/32' ].forEach((d) => assert(h.validDevice(d), d));
		[ '1:2:3:4:5:6:7', '1:2:3:4:5:6:7:8:9', '1::2::3', '12345::1', ':1:2:3:4:5:6:7', '1:2:3:4:5:6:7:' ].forEach((d) => assert(!h.validDevice(d), d));
		assert(h.isMac('AA-bb-CC-dd-EE-ff') && !h.isMac('fd00::1'));
	});
	await check('port parsing', () => {
		assert.deepStrictEqual(h.parsePorts('3074, 30000-45000 9000'), [ '3074', '30000-45000', '9000' ]);
		assert.deepStrictEqual(h.parsePorts(''), []);
		assert.strictEqual(h.parsePorts('0'), null);
		assert.strictEqual(h.parsePorts('70000'), null);
		assert.strictEqual(h.parsePorts('500-100'), null);
		assert.strictEqual(h.parsePorts('abc'), null);
	});
	await check('versions compared part by part (1.10.0 is newer than 1.9.2)', () => {
		assert(h.newerVersion('1.1.0', '1.0.0') && h.newerVersion('1.10.0', '1.9.2') && h.newerVersion('2.0', '1.99.99'));
		assert(h.newerVersion('1.1.1', '1.1') && !h.newerVersion('1.1', '1.1.0') && !h.newerVersion('1.0.0', '1.0.0'));
		assert(!h.newerVersion('1.0.9', '1.1.0') && !h.newerVersion('', '1.0.0'));
	});
	await check('a zone\'s ports as ranges: in them or not, and how many ports they cover', () => {
		assert.deepStrictEqual(h.portRanges([ '10000-10499', '3074' ]), [ [ 10000, 10499 ], [ 3074, 3074 ] ]);
		assert.deepStrictEqual(h.portRanges('7700-7799 10000-10199,27000'), [ [ 7700, 7799 ], [ 10000, 10199 ], [ 27000, 27000 ] ], 'one string too');
		assert.deepStrictEqual(h.portRanges([ '0', '500-100', 'abc', '70000', '' ]), [], 'bad entries left out');
		assert.deepStrictEqual(h.portRanges(undefined), []);
		const r = h.portRanges([ '10200-10299', '27000-27099' ]);
		assert(h.inRanges(10200, r) && h.inRanges(10299, r) && h.inRanges(27054, r));
		assert(!h.inRanges(10199, r) && !h.inRanges(10300, r) && !h.inRanges(30000, r));
		assert.strictEqual(h.rangesSize(h.portRanges([ '1024-65535' ])), 64512);
		assert.strictEqual(h.rangesSize(h.portRanges([ '100-199', '150-249', '300' ])), 151, 'overlaps counted once');
		const ps = h.presetOn(h.presetById('apex'), 'ps').remote;
		assert(h.rangesSize(h.portRanges(ps)) <= 20000, 'Apex Legends on PlayStation: a narrow set of ports');
		assert(h.rangesSize(h.portRanges(h.presetById('any_udp').remote)) > 20000 && h.rangesSize(h.portRanges(h.presetById('fortnite').remote)) > 20000,
			'Any game and Fortnite (Xbox, mobile): wide ranges');
	});
	await check('zone section names are safe and unique', () => {
		assert.strictEqual(h.sectionName('Call of Duty: MW', []), 'call_of_duty_mw');
		assert.strictEqual(h.sectionName('2042 Battlefield', []), 'zone_2042_battlefield');
		assert.strictEqual(h.sectionName('!!!', []), 'zone');
		assert.strictEqual(h.sectionName('Halo', [ 'halo', 'halo_2' ]), 'halo_3');
		assert(/^[a-z][a-z0-9_]{0,40}$/.test(h.sectionName('x'.repeat(100), [])));
	});

	// minimal uci changeset mock
	function fakeUci(initial) {
		const secs = initial;
		return {
			sections: (c, t) => Object.keys(secs).filter((n) => !t || secs[n]['.type'] === t).map((n) => secs[n]),
			add: (c, t, n) => { secs[n] = { '.name': n, '.type': t }; return n; },
			set: (c, s, o, val) => { secs[s][o] = val; },
			unset: (c, s, o) => { delete secs[s][o]; },
			get: (c, s, o) => (secs[s] ? (o ? secs[s][o] : secs[s]) : null),
			secs
		};
	}
	await check('createZone stages a monitor-mode zone and switches LobbyFence on', () => {
		const u = fakeUci({ globals: { '.name': 'globals', '.type': 'globals', enabled: '0' } });
		const sid = h.createZone(u, { label: 'My Shooter', device: '192.168.1.50', proto: 'udp', remotePorts: [ '3074' ] });
		assert.strictEqual(sid, 'my_shooter');
		const z = u.secs[sid];
		assert.strictEqual(z['.type'], 'zone');
		assert.strictEqual(z.mode, 'enforce');
		assert.strictEqual(z.strict, '1', 'strict by default');
		assert.strictEqual(z.enabled, '1');
		assert.deepStrictEqual(z.device, [ '192.168.1.50' ]);
		assert.deepStrictEqual(z.remote_port, [ '3074' ]);
		assert(!('local_port' in z));
		assert.strictEqual(u.secs.globals.enabled, '1');
		assert.strictEqual(h.createZone(u, { label: 'My Shooter', device: '10.0.0.2' }), 'my_shooter_2');
	});
	await check('createZone stores MAC devices and either-side ports', () => {
		const u = fakeUci({ globals: { '.name': 'globals', '.type': 'globals', enabled: '0' } });
		const sid = h.createZone(u, { label: 'Call of Duty', device: 'AA-BB-CC-DD-EE-01', proto: 'udp', remotePorts: [], eitherPorts: [ '3074-3079' ] });
		assert.deepStrictEqual(u.secs[sid].device, [ 'aa:bb:cc:dd:ee:01' ]);
		assert.deepStrictEqual(u.secs[sid].port, [ '3074-3079' ]);
		assert(!('remote_port' in u.secs[sid]));
	});
	await check('createZone honours an explicit monitor mode', () => {
		const u = fakeUci({});
		const sid = h.createZone(u, { label: 'x', device: '10.0.0.9', mode: 'monitor', strict: false });
		assert.strictEqual(u.secs[sid].mode, 'monitor');
		assert.strictEqual(u.secs[sid].strict, '0');
	});
	await check('createZone recreates a missing globals section', () => {
		const u = fakeUci({});
		h.createZone(u, { label: 'a', device: '10.0.0.2' });
		assert.strictEqual(u.secs.globals.enabled, '1');
	});

	await check('live classification follows the circles', () => {
		const ctx = { zone: 'z', circles: { z: [ { lat: 50.11, lon: 8.68, r: 800 } ] }, countries: [ 'US' ] };
		assert.strictEqual(v.classify.call(ctx, { lat: 48.86, lon: 2.35, cc: 'FR' }), 'in');
		assert.strictEqual(v.classify.call(ctx, { lat: 40.71, lon: -74, cc: 'US' }), 'in');
		assert.strictEqual(v.classify.call(ctx, { lat: 35.68, lon: 139.7, cc: 'JP' }), 'out');
		assert.strictEqual(v.classify.call({ zone: 'z', circles: { z: [] }, countries: [] }, { lat: 0, lon: 0, cc: 'XX' }), 'out', 'no region: nothing inside');
		assert.strictEqual(v.classify.call(ctx, { lat: null, lon: null, cc: '' }), 'unknown');
	});
	await check('distance outside the nearest circle', () => {
		const ctx = { zone: 'z', circles: { z: [ { lat: 50.11, lon: 8.68, r: 800 }, { lat: 40.71, lon: -74, r: 100 } ] } };
		const km = v.kmOutside.call(ctx, { lat: 41.9, lon: -87.6 });      // Chicago: ~1145 km from NYC
		assert(km > 1000 && km < 1100, km);
		assert.strictEqual(v.kmOutside.call({ zone: 'z', circles: { z: [] } }, { lat: 0, lon: 0 }), null);
	});
	await check('server dots are grouped per location and state', () => {
		const ctx = {
			zone: 'z', circles: { z: [ { lat: 50.11, lon: 8.68, r: 800 } ] }, polygons: { z: [] }, countries: [], rules: { allow: [], block: [] },
			classify: v.classify, classifyFast: v.classifyFast, beginClassify: v.beginClassify, endClassify: v.endClassify, effective: v.effective, ruleFor: v.ruleFor,
			visibleServers: v.visibleServers, inRange: v.inRange, routerNow: v.routerNow, range: 'all',
			activeSet: v.activeSet, activeWindow: v.activeWindow, rateSet: v.rateSet, isActive: v.isActive,
			servers: h.parseServers('1.1.1.1 in 50.11 8.68 DE 1\n1.1.1.2 in 50.11 8.68 DE 1\n2.2.2.2 out 40.7 -74 US 1\n3.3.3.3 pending - - -- 1\n')
		};
		const f = v.serverFeatures.call(ctx);
		assert.strictEqual(f.length, 2);
		const de = f.find((x) => x.properties.cc === 'DE');
		assert.deepStrictEqual([ de.properties.count, de.properties.state, de.properties.ips ], [ 2, 'in', '1.1.1.1 1.1.1.2' ]);
		assert.deepStrictEqual(de.geometry.coordinates, [ 8.68, 50.11 ]);
	});
	const sample = {
		version: 8, center: [ 1, 2 ], zoom: 3, bearing: 10, pitch: 5, sources: {},
		layers: [
			{ id: 'background', type: 'background', paint: { 'background-color': '#fff' } },
			{ id: 'water', type: 'fill', paint: { 'fill-color': '#abc', 'fill-pattern': 'x' } },
			{ id: 'highway_major', type: 'line', paint: { 'line-color': [ 'interpolate', [ 'linear' ], [ 'zoom' ], 5, '#fff', 10, '#eee' ], 'line-width': 2 } },
			{ id: 'boundary_country', type: 'line', paint: { 'line-color': '#999' } },
			{ id: 'building', type: 'fill', paint: { 'fill-color': '#ddd', 'fill-outline-color': '#ccc' } },
			{ id: 'place_city', type: 'symbol', layout: { 'text-field': '{name}' }, paint: { 'text-color': '#333' } },
			{ id: 'water_name', type: 'symbol', layout: { 'text-field': '{name}' } }
		]
	};
	await check('Midnight recolours the basemap by role and keeps the camera', () => {
		const m = h.THEMES.midnight.map, out = h.themedStyle(sample, h.THEMES.midnight);
		const by = (id) => out.layers.find((l) => l.id === id).paint;
		assert.strictEqual(by('background')['background-color'], m.land);
		assert.strictEqual(by('water')['fill-color'], m.water);
		assert(!('fill-pattern' in by('water')));
		assert.strictEqual(by('highway_major')['line-color'], m.road);
		assert.strictEqual(by('highway_major')['line-width'], 2);
		assert.strictEqual(by('boundary_country')['line-color'], m.border);
		assert.strictEqual(by('building')['fill-outline-color'], m.building);
		assert.strictEqual(by('place_city')['text-color'], m.label);
		assert.strictEqual(by('water_name')['text-color'], m.waterLabel);
		assert.strictEqual(by('water_name')['text-halo-color'], m.halo);
		[ 'center', 'zoom', 'bearing', 'pitch' ].forEach((k) => assert(!(k in out), k));
		assert.strictEqual(sample.layers[0].paint['background-color'], '#fff', 'input untouched');
	});
	await check('Light keeps the original colours', () => {
		const out = h.themedStyle(sample, h.THEMES.light);
		assert.deepStrictEqual(out.layers, sample.layers);
		assert(!('center' in out));
	});
	await check('every theme is complete', () => {
		assert(h.THEMES[h.DEFAULT_THEME] && h.DEFAULT_THEME === 'midnight');
		h.THEME_ORDER.forEach((k) => {
			const t = h.THEMES[k];
			[ 'bg', 'panel', 'border', 'text', 'muted', 'btn', 'hover', 'accent', 'accent-text' ].forEach((u) => assert(/^#[0-9a-f]{6}$/.test(t.ui[u]), k + ' ui ' + u));
			[ 'circle', 'allowed', 'blocked', 'unknown' ].forEach((o) => assert(/^#[0-9a-f]{6}$/.test(t.overlay[o]), k + ' overlay ' + o));
			if (t.map) [ 'land', 'water', 'landuse', 'road', 'building', 'border', 'label', 'waterLabel', 'halo' ].forEach((r) => assert(/^#[0-9a-f]{6}$/.test(t.map[r]), k + ' map ' + r));
		});
	});
	await check('raster fallback is themed too', () => {
		const r = h.rasterStyle(h.THEMES.midnight);
		assert.strictEqual(r.layers[0].paint['raster-saturation'], -1);
		assert(r.layers[0].paint['raster-brightness-min'] > r.layers[0].paint['raster-brightness-max'], 'inverted for a dark map');
		assert.deepStrictEqual(h.rasterStyle(h.THEMES.light).layers[0].paint, {});
	});
	await check('flags, times, escaping', () => {
		assert.strictEqual(h.flag('US'), '\u{1F1FA}\u{1F1F8}');
		assert.strictEqual(h.flag('--'), '');
		assert.strictEqual(h.ago(1000, 1030), 'just now');
		assert.strictEqual(h.ago(1000, 1000 + 7200), '2 h ago');
		assert.strictEqual(h.ago(1000, 1000 + 86400 * 3), '3 days ago');
		assert.strictEqual(h.ago(0, 5), 'never');
	});
	await check('ringBounds', () => {
		const b = h.ringBounds(h.circleRing({ lat: 0, lon: 0, r: 111.2 }, 64));
		assert(Math.abs(b[0][0] + 1) < 0.01 && Math.abs(b[1][1] - 1) < 0.01, JSON.stringify(b));
	});
	await check('handleSave writes circles and unsets empty lists', async () => {
		const calls = [];
		const ctx = { dirty: { a: true, b: true }, circles: { a: [ { lat: 1, lon: 2, r: 3 } ], b: [] }, polygons: { a: [], b: [ [ [ 1, 1 ], [ 2, 1 ], [ 2, 2 ] ] ] } };
		const u = { set: (...a) => calls.push([ 'set' ].concat(a)), unset: (...a) => calls.push([ 'unset' ].concat(a)),
			get: () => ({}), save: () => Promise.resolve('saved') };
		const m2 = loadView('map.js', Object.assign({}, stubs, { uci: u }));
		ctx.writeRegions = m2.writeRegions;
		assert.strictEqual(await m2.handleSave.call(ctx), 'saved');
		assert.strictEqual(ctx.pendingApply, false);
		assert.deepStrictEqual(calls, [
			[ 'set', 'lobbyfence', 'a', 'circle', [ '1.0000,2.0000,3' ] ], [ 'unset', 'lobbyfence', 'a', 'polygon' ],
			[ 'unset', 'lobbyfence', 'b', 'circle' ], [ 'set', 'lobbyfence', 'b', 'polygon', [ '1.0000,1.0000;1.0000,2.0000;2.0000,2.0000' ] ]
		]);
		assert.deepStrictEqual(ctx.dirty, {});
	});

	await check('every edit is saved (staged) right away, once per burst of edits', async () => {
		let saves = 0;
		global.window.setTimeout = setTimeout; global.window.clearTimeout = clearTimeout;
		const calls = [];
		const u = { set: (...a) => calls.push(a), unset: (...a) => calls.push(a), get: () => ({}), save: () => { saves++; return Promise.resolve(); } };
		const m3 = loadView('map.js', Object.assign({}, stubs, { uci: u, ui: { addNotification() {}, changes: { init() {} } } }));
		const ctx = Object.assign(Object.create(m3), { zone: 'z', dirty: {}, circles: { z: [] }, polygons: { z: [] },
			updateNotice() {}, drawRegions() {} });
		ctx.circles.z.push({ lat: 1, lon: 2, r: 3 }); ctx.regionsChanged();
		ctx.circles.z[0].r = 9; ctx.regionsChanged();
		assert.strictEqual(saves, 0, 'debounced');
		await new Promise((r) => setTimeout(r, 500));
		await ctx.saveChain;
		assert.strictEqual(saves, 1, 'one save for two quick edits');
		assert.deepStrictEqual(calls[0], [ 'lobbyfence', 'z', 'circle', [ '1.0000,2.0000,9' ] ]);
		assert.strictEqual(ctx.pendingApply, true);
		assert.strictEqual(ctx.saving, false);
	});
	await check('Satellite replaces Slate; satellite style keeps only borders and place names', () => {
		assert.deepStrictEqual(h.THEME_ORDER, [ 'midnight', 'satellite', 'light', 'galaxy' ]);
		assert(!h.THEMES.blood, 'Blood theme removed');
		assert(!h.THEMES.slate);
		const base = { version: 8, glyphs: 'g', sources: { openmaptiles: { type: 'vector' } }, layers: [
			{ id: 'background', type: 'background' }, { id: 'water', type: 'fill' }, { id: 'highway_major', type: 'line' },
			{ id: 'boundary_country', type: 'line', paint: {} }, { id: 'place_city', type: 'symbol', layout: { 'icon-image': 'x' } },
			{ id: 'road_label', type: 'symbol' }, { id: 'poi_label', type: 'symbol' } ] };
		const st = h.satelliteStyle(base);
		assert.deepStrictEqual(st.layers.map((l) => l.id), [ 'satellite', 'satellite-hd', 'boundary_country', 'place_city' ]);
		assert(/World_Imagery/.test(st.sources['satellite-hd'].tiles[0]) && st.sources['satellite-hd'].maxzoom >= 19 && /Esri/.test(st.sources['satellite-hd'].attribution),
			'sharp imagery when zoomed in');
		assert(st.layers[1].minzoom <= 10 && st.layers[0].maxzoom > st.layers[1].minzoom, 'the two imageries overlap, no gap');
		assert(/eox\.at/.test(st.sources.satellite.tiles[0]) && /Copernicus/.test(st.sources.satellite.attribution));
		assert.strictEqual(st.layers[3].paint['text-color'], '#ffffff');
		assert(!('icon-image' in st.layers[3].layout));
		assert.deepStrictEqual(h.satelliteStyle(null).layers.map((l) => l.id), [ 'satellite', 'satellite-hd' ], 'works without the vector style');
	});
	await check('Antarctica gets a label in the theme\'s country-label style; Fit includes it', () => {
		const base = { version: 8, glyphs: 'g', sources: {}, layers: [
			{ id: 'place_country_major', type: 'symbol', layout: { 'text-font': [ 'Noto Sans Bold' ] }, paint: { 'text-color': '#abc' } } ] };
		const st = h.addExtraLabels(JSON.parse(JSON.stringify(base)));
		const l = st.layers.find((x) => x.id === 'lf-label-continent');
		assert(l && l.paint['text-color'] === '#abc' && l.layout['text-font'][0] === 'Noto Sans Bold');
		assert.strictEqual(st.sources['lf-labels'].data.features[0].properties.name, 'Antarctica');
		assert.strictEqual(h.addExtraLabels({ version: 8, sources: {}, layers: [] }).layers.length, 0, 'no fonts -> no label');
		const lat = st.sources['lf-labels'].data.features[0].geometry.coordinates[1];
		assert(lat > h.WORLD_BOUNDS[0][1] && lat < -60, 'label inside the Fit view');
	});
	await check('dots fade as a server goes quiet', () => {
		const ctx = { zone: 'z', range: 'active', circles: { z: [] }, polygons: { z: [] }, countries: [], rules: { allow: [], block: [] },
			servers: h.parseServers('1.1.1.1 in 10 10 DE 1\n2.2.2.2 in 20 20 FR 1\n'),
			live: { time: 1, zones: { z: { active: { '1.1.1.1': 0, '2.2.2.2': 15 }, active_window: 15 } } },
			classify: v.classify, classifyFast: v.classifyFast, beginClassify: v.beginClassify, endClassify: v.endClassify, effective: v.effective, ruleFor: v.ruleFor, visibleServers: v.visibleServers, inRange: v.inRange,
			routerNow: v.routerNow, activeSet: v.activeSet, activeWindow: v.activeWindow, rateSet: v.rateSet, isActive: v.isActive };
		const f = Object.fromEntries(v.serverFeatures.call(ctx).map((x) => [ x.properties.ips, x.properties.fade ]));
		assert(f['1.1.1.1'] > 0.9 && f['2.2.2.2'] <= 0.31, JSON.stringify(f));
	});
	await check('open countdown runs locally between router updates', () => {
		const ctx = { openUntil: Date.now() + 7400 };
		assert.strictEqual(v.openLeft.call(ctx), 8);
		ctx.openUntil = Date.now() - 10;
		assert.strictEqual(v.openLeft.call(ctx), 0);
		assert.strictEqual(v.openLeft.call({ openUntil: 0 }), 0);
	});
	await check('shapes are blue in every theme', () => {
		h.THEME_ORDER.forEach((k) => assert(/^#(3b82f6|2563eb)$/.test(h.THEMES[k].overlay.circle), k));
	});
	await check('address lists: comments, separators, junk, duplicates', () => {
		const r = h.parseAddressList('# LobbyFence whitelist\n80.20.0.1, 80.20.0.2;  2a00:1450::/32 # relay\nnot-an-ip 80.20.0.1\r\n10.0.0.0/8\n');
		assert.deepStrictEqual(r.list, [ '80.20.0.1', '80.20.0.2', '2a00:1450::/32', '10.0.0.0/8' ]);
		assert.strictEqual(r.ignored, 1);
		assert.deepStrictEqual(h.parseAddressList('').list, []);
	});
	await check('exported list round-trips through the parser', () => {
		const ctx = { zone: 'z', rules: { allow: [ '1.2.3.4', 'fd00::/8' ], block: [] } };
		const m = loadView('map.js', Object.assign({}, stubs, { uci: { get: () => ({ label: 'My game' }) } }));
		const text = m.listText.call(ctx, 'allow');
		assert(/^# LobbyFence whitelist/.test(text) && /My game/.test(text));
		assert.deepStrictEqual(h.parseAddressList(text).list, [ '1.2.3.4', 'fd00::/8' ]);
	});
	await check('device labels show name, all IPv4, first IPv6 and the MAC', () => {
		assert.strictEqual(h.deviceLabel({ mac: 'aa:bb:cc:dd:ee:01', name: 'Phone', ipv4: [ '192.168.1.23' ], ipv6: [ '2601::23', '2601::24' ] }),
			'Phone - 192.168.1.23, 2601::23 +1 - AA:BB:CC:DD:EE:01');
		assert.strictEqual(h.deviceLabel({ mac: 'aa:bb:cc:dd:ee:02', name: '', ipv4: [], ipv6: [] }), 'Unnamed device - AA:BB:CC:DD:EE:02');
	});
	await check('time filter: active / hour / day / all', () => {
		const now = 1000000, srv = [ 60, 1800, 7200, 90000, 0 ].map((ago, i) => ({ ip: '1.1.1.' + i, ts: ago ? now - ago : 0 }));
		const ctx = { zone: 'z', servers: srv, live: { time: now, zones: { z: { active: [ '1.1.1.1' ] } } }, inRange: v.inRange, routerNow: v.routerNow, activeSet: v.activeSet, rateSet: v.rateSet, isActive: v.isActive };
		const count = (r) => { ctx.range = r; return v.visibleServers.call(ctx).map((x) => x.ip); };
		assert.deepStrictEqual(count('active'), [ '1.1.1.1' ], 'active = live traffic, even if seen recently otherwise');
		assert.deepStrictEqual([ count('hour').length, count('day').length, count('all').length ], [ 2, 3, 5 ]);
		ctx.live = { time: now, zones: { z: { active: [] } } };
		assert.deepStrictEqual(count('active'), [], 'nothing in use -> nothing shown');
		ctx.live = { time: now, zones: { z: { active: { '1.1.1.3': 4 }, active_window: 15 } } };
		assert.deepStrictEqual(count('active'), [ '1.1.1.3' ], 'object form with ages');
		assert.deepStrictEqual(v.activeSet.call(ctx), { '1.1.1.3': 4 });
		/* keep-alive pings to an allowed server: seen 2 s ago but only 0.2 packets/s -> not active */
		ctx.live = { time: now, zones: { z: { active: { '1.1.1.0': 2, '1.1.1.1': 0, '1.1.1.2': 2, '1.1.1.3': 9 },
			rate: { '1.1.1.0': 0.2, '1.1.1.1': 30, '1.1.1.2': -1, '1.1.1.3': -1 }, active_window: 15 } } };
		assert.deepStrictEqual(count('active'), [ '1.1.1.1', '1.1.1.2' ], 'rate >= 1 pkt/s, or a packet in the last 3 s before a rate exists');
		ctx.live = { time: now };   /* old router without the live list: recently seen */
		assert.deepStrictEqual(count('active'), [ '1.1.1.0' ]);
	});
	await check('Delete removes the selected shape', () => {
		let changed = 0;
		const ctx = { zone: 'z', circles: { z: [ { lat: 1, lon: 1, r: 5 } ] }, polygons: { z: [ [ [ 0, 0 ], [ 1, 0 ], [ 1, 1 ] ] ] },
			selected: { kind: 'polygon', idx: 0 }, regionsChanged() { changed++; }, drawServers() {} };
		assert.strictEqual(v.deleteSelected.call(ctx), true);
		assert.deepStrictEqual(ctx.polygons.z, []);
		assert.strictEqual(ctx.circles.z.length, 1);
		assert.strictEqual(ctx.selected, null);
		assert.strictEqual(v.deleteSelected.call(ctx), false, 'nothing selected');
		assert.strictEqual(changed, 1);
	});
	await check('polygons: parse, normalise across the antimeridian, format', () => {
		const p = h.parsePolygons([ '60,175;70,175;70,-175;60,-175', '1,2', 'x,1;2,3;4,5', '10,20;10,30;20,25' ]);
		assert.strictEqual(p.length, 2);
		assert.deepStrictEqual(p[0].map((q) => q[0]), [ 175, 175, 185, 185 ], 'continuous longitudes');
		assert.strictEqual(h.formatPolygon(p[0]), '60.0000,175.0000;70.0000,175.0000;70.0000,185.0000;60.0000,185.0000');
		assert.deepStrictEqual(h.parsePolygons([ h.formatPolygon(p[1]) ])[0], p[1], 'round trip');
		assert(h.inPolygon(p[0], 65, 179.9) && h.inPolygon(p[0], 65, -179.9) && !h.inPolygon(p[0], 65, 170));
	});
	await check('map and router agree on every polygon decision', () => {
		const { execFileSync } = require('child_process');
		const AWK = path.join(__dirname, '../files/usr/share/lobbyfence/lobbyfence.awk');
		const polys = [
			'47,5;55,5;55,15;47,15',                                   // box over Germany
			'60,175;70,175;70,-175;60,-175',                           // across the antimeridian
			'30,-120;45,-120;45,-100;38,-110;30,-100',                 // concave (notch)
			'70,-30;84,-30;84,40;70,40'                                // far north (Mercator stretch)
		];
		let rnd = 12345;
		const r = () => (rnd = (rnd * 1103515245 + 12345) % 2147483648) / 2147483648;
		const pts = [];
		for (let i = 0; i < 1500; i++) pts.push([ +(r() * 170 - 85).toFixed(3), +(r() * 360 - 180).toFixed(3) ]);
		const tmp = require('os').tmpdir();
		const cache = path.join(tmp, 'lf_poly_cache'), ips = path.join(tmp, 'lf_poly_ips');
		fs.writeFileSync(cache, pts.map((p, i) => `10.${i >> 8 & 255}.${i & 255}.1 ${p[0]} ${p[1]} XX 1`).join('\n') + '\n');
		fs.writeFileSync(ips, pts.map((p, i) => `10.${i >> 8 & 255}.${i & 255}.1 1`).join('\n') + '\n');
		const parsed = h.parsePolygons(polys);
		for (const awk of [ process.env.LF_TEST_AWK || 'awk' ]) {
			const out = execFileSync(awk, [ '-v', 'op=classify', '-v', 'polygons=' + polys.join(' '), '-f', AWK, cache, ips ]).toString().trim().split('\n');
			let bad = 0;
			out.forEach((line, i) => {
				const js = parsed.some((poly) => h.inPolygon(poly, pts[i][0], pts[i][1])) ? 'in' : 'out';
				if (line.split(' ')[1] !== js) bad++;
			});
			assert.strictEqual(bad, 0, bad + ' of ' + pts.length + ' points disagree (' + awk + ')');
			assert(out.filter((l) => l.split(' ')[1] === 'in').length > 20, 'enough points inside to be meaningful');
		}
	});
	await check('Align makes every edge straight: squares, rectangles, L-shapes', () => {
		const straight = (p) => p.every((q, i) => h.alignedKind(q, p[(i + 1) % p.length]));
		const rough = [ [ 10, 40.3 ], [ 20.2, 39.8 ], [ 19.7, 50.4 ], [ 10.4, 49.7 ] ];
		const sq = h.straightenPolygon(rough);
		assert(sq.length === 4 && straight(sq), 'rectangle');
		const ratio = h.mercArea(sq) / h.mercArea(rough);
		assert(ratio > 0.95 && ratio < 1.05, 'area kept: ' + ratio);
		assert(Math.abs(sq[0][0] - 10.2) < 1e-9 && Math.abs(sq[1][0] - 19.95) < 1e-9, 'meridians at the average longitude');
		// badly drawn: edges 25-35 degrees off still end up a rectangle
		const wonky = [ [ 0, 0 ], [ 10, 4 ], [ 8, 14 ], [ -3, 9 ] ];
		const w2 = h.straightenPolygon(wonky);
		assert(w2.length === 4 && straight(w2), JSON.stringify(w2));
		// an L keeps its six square corners
		const L = [ [ 0, 0 ], [ 10, 0.4 ], [ 10.3, 5 ], [ 5, 5.2 ], [ 4.8, 10 ], [ 0.2, 9.8 ] ];
		const L2 = h.straightenPolygon(L);
		assert(L2.length === 6 && straight(L2), JSON.stringify(L2));
		// a triangle or a diamond can't be made straight by snapping: the rectangle around it
		const tri = h.straightenPolygon([ [ 0, 0 ], [ 10, 0.3 ], [ 0, 10 ] ]);
		assert(tri.length === 4 && straight(tri) && tri[0][0] === 0 && tri[2][1] === 10, JSON.stringify(tri));
		const dia = h.straightenPolygon([ [ 0, 0 ], [ 10, 0.5 ], [ 20, 0 ], [ 10, -0.5 ] ]);
		assert(dia.length === 4 && straight(dia), JSON.stringify(dia));
		// an already straight shape is left as it is
		const rect = [ [ 0, 0 ], [ 5, 0 ], [ 5, 5 ], [ 0, 5 ] ];
		assert.deepStrictEqual(h.straightenPolygon(rect), rect);
		assert.strictEqual(h.edgeKind([ 0, 70 ], [ 10, 70.5 ], 12), 'h');
		assert.strictEqual(h.edgeKind([ 0, 0 ], [ 0.5, 10 ], 12), 'v');
		assert.strictEqual(h.edgeKind([ 0, 0 ], [ 10, 10 ], 12), '');
	});
	await check('address rules: IPv4 / IPv6, exact and subnets', () => {
		assert(h.cidrMatch('80.20.0.1', '80.20.0.1') && !h.cidrMatch('80.20.0.1', '80.20.0.2'));
		assert(h.cidrMatch('80.20.0.0/24', '80.20.0.77') && !h.cidrMatch('80.20.0.0/24', '80.20.1.1'));
		assert(h.cidrMatch('0.0.0.0/0', '1.2.3.4'));
		assert(h.cidrMatch('2a00:1450::/32', '2a00:1450:4001::5') && !h.cidrMatch('2a00:1450::/32', '2a00:1451::5'));
		assert(h.cidrMatch('2a00:1450:4001::5', '2a00:1450:4001:0:0:0:0:5'));
		assert(h.cidrMatch('::ffff:10.0.0.0/120', '::ffff:10.0.0.9'));
		assert(!h.cidrMatch('10.0.0.0/8', 'fd00::1') && !h.cidrMatch('fd00::/8', '10.0.0.1'));
		assert.deepStrictEqual(h.v6groups('::1'), [ 0, 0, 0, 0, 0, 0, 0, 1 ]);
		assert.strictEqual(h.v6groups('1::2::3'), null);
		assert(h.inList([ '1.1.1.1', '80.20.0.0/16' ], '80.20.9.9') && !h.inList([], '1.1.1.1'));
	});
	await check('your rules beat geography; allow beats block', () => {
		const ctx = { zone: 'z', circles: { z: [ { lat: 50.11, lon: 8.68, r: 800 } ] }, polygons: { z: [] }, countries: [],
			rules: { allow: [ '80.20.0.1' ], block: [ '45.10.0.1', '80.20.0.0/24' ] } };
		ctx.classify = v.classify; ctx.ruleFor = v.ruleFor;
		const eff = (ip, lat, lon) => v.effective.call(ctx, { ip, lat, lon, cc: '' });
		assert.strictEqual(eff('45.10.0.1', 50.11, 8.68), 'out', 'blocked although inside');
		assert.strictEqual(eff('80.20.0.1', 40.7, -74), 'in', 'allow wins over the /24 block');
		assert.strictEqual(eff('80.20.0.9', 50.11, 8.68), 'out', 'subnet block');
		assert.strictEqual(eff('9.9.9.9', 50.11, 8.68), 'in', 'geography otherwise');
		assert.strictEqual(eff('9.9.9.8', null, null), 'unknown');
	});
	await check('polygons count as region in the live preview', () => {
		const ctx = { zone: 'z', circles: { z: [] }, polygons: { z: h.parsePolygons([ '38,-80;45,-80;45,-70;38,-70' ]) }, countries: [] };
		assert.strictEqual(v.classify.call(ctx, { lat: 40.7, lon: -74, cc: 'US' }), 'in');
		assert.strictEqual(v.classify.call(ctx, { lat: 50.1, lon: 8.7, cc: 'DE' }), 'out');
	});
	await check('dynamic import from a Function-built loader works', async () => {
		const m = await h.importModule('data:text/javascript,export const Map = function () {}; export const answer = 42;');
		assert.strictEqual(m.answer, 42);
	});
	/* the map library runs inside the router's admin page: a copy that isn't the
	   published release must never run (a CDN serving changed code) */
	const crypto = require('crypto');
	const sha = (t) => crypto.createHash('sha256').update(t).digest('base64');
	const GOOD = { 'maplibre-gl.mjs': 'GOOD main', 'maplibre-gl-worker.mjs': 'GOOD worker', 'maplibre-gl.css': '.good{}' };
	const realFetch0 = global.fetch;
	const cdnFetch = (serve) => (url) => {
		if (/^blob:/.test(url)) return realFetch0(url);
		const name = url.split('/').pop(), body = serve(url, name);
		return body == null ? Promise.reject(new Error('offline'))
			: Promise.resolve({ ok: true, status: 200, arrayBuffer: () => Promise.resolve(new TextEncoder().encode(body).buffer) });
	};
	const loaderView = (log) => loadView('map.js', stubs, HELPERS, (src) => src.replace(
		"var importModule = new Function('url', 'return import(url);');",
		"var importModule = function(url) { return __log.load(url); };"
	).replace("'use strict';", "'use strict'; var __log = window.__log;"));
	await check('loader: a changed copy on the first CDN is refused, the next CDN\'s checked copy runs', async () => {
		window.LF_TEST_MAPLIBRE_SHA256 = Object.fromEntries(Object.entries(GOOD).map(([k, v]) => [ k, sha(v) ]));
		window.isSecureContext = false;      /* router pages: plain http - the built-in SHA-256 */
		const ran = [], workers = [];
		window.__log = { load: async (u) => { const t = await (await fetch(u)).text(); ran.push(t); return { Map: function () {}, setWorkerUrl: (w) => workers.push(w) }; } };
		const realFetch = global.fetch;
		window.fetch = cdnFetch((url, name) => /unpkg/.test(url) ? (name === 'maplibre-gl.mjs' ? 'EVIL main' : GOOD[name]) : GOOD[name]);
		links.length = 0;
		try {
			const m = loaderView();
			const ml = await m.helpers.loadMaplibre();
			assert.strictEqual(typeof ml.Map, 'function');
			assert.deepStrictEqual(ran, [ 'GOOD main' ], 'only the checked copy ran: ' + JSON.stringify(ran));
			assert.strictEqual(workers.length, 1);
			assert.strictEqual(await (await realFetch(workers[0])).text(), 'GOOD worker');
			assert(links.some((el) => el.tag === 'style' && el.textContent === '.good{}'), 'checked CSS added');
		} finally { window.fetch = realFetch; }
	});
	await check('loader: every CDN serving a changed copy -> nothing runs, it rejects (and can retry)', async () => {
		const ran = [];
		window.__log = { load: (u) => { ran.push(u); return Promise.resolve({ Map: function () {} }); } };
		const realFetch = global.fetch;
		window.fetch = cdnFetch((url, name) => 'EVIL ' + name);
		try {
			const m = loaderView();
			await assert.rejects(m.helpers.loadMaplibre(), /integrity/);
			await assert.rejects(m.helpers.loadMaplibre());
			assert.strictEqual(ran.length, 0, 'nothing ran');
		} finally { window.fetch = realFetch; delete window.LF_TEST_MAPLIBRE_SHA256; }
	});
	await check('loader: the release hashes are the real MapLibre 6.15.0 files', () => {
		const src = require('fs').readFileSync(__dirname + '/../luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/map.js', 'utf8');
		assert(/'maplibre-gl\.mjs': 'QRmLI2eafYiSGDQIu\+8uq9x0dFvrkCYfa\+D2YLeusv0='/.test(src));
		assert(/MAPLIBRE_VERSION = '6\.15\.0'/.test(src), 'the hashes belong to 6.15.0 - update both together');
	});

	console.log(failures ? failures + ' FAILED' : 'ALL JS TESTS PASSED');
	process.exit(failures ? 1 : 0);
})();
