// Zones page (zones.js): runs the view against a recording stand-in for LuCI's
// form classes, then checks every option's input rule with LuCI's REAL
// validation.js when a LuCI checkout is given.
//   usage: node zones_page_test.js [path/to/luci/modules/luci-base/htdocs/luci-static/resources]
'use strict';
const fs = require('fs');
const path = require('path');
const assert = require('assert');

const SRC = fs.readFileSync(path.join(__dirname, '../luci-app-lobbyfence/htdocs/luci-static/resources/view/lobbyfence/zones.js'), 'utf8');
const LUCI = process.argv[2];
let failed = 0;
async function check(name, fn) {
	try { await fn(); console.log('PASS: ' + name); }
	catch (e) { failed++; console.log('FAIL: ' + name + ' - ' + (e && e.message)); }
}

String.prototype.format = function() { const a = arguments; let i = 0; return this.replace(/%[sd]/g, () => String(a[i++])); };
global._ = (s) => s;

/* ---- recording stand-in for LuCI's form module */
const options = {};
class Opt {
	constructor(type, name, title, descr) { Object.assign(this, { type, name, title, descr, values: [], deps: [] }); options[name] = this; }
	value(k, v) { this.values.push([ k, v ]); }
	depends(k, v) { this.deps.push([ k, v ]); }
}
class Section {
	constructor(type, a, b, title) { this.type = type; this.title = title; }
	option(type, name, title, descr) { return new Opt(type.name, name, title, descr); }
	tab() {}
	taboption(tab, type, name, title, descr) { return this.option(type, name, title, descr); }
}
const form = {
	Map: class { constructor() { this.sections = []; } section(type, a, b, c) { const s = new Section(type.name, a, b, c); this.sections.push(s); return s; }
		render() { return Promise.resolve({ addEventListener() {} }); } parse() { return Promise.resolve(); } },
	NamedSection: function NamedSection() {}, TypedSection: function TypedSection() {}, GridSection: function GridSection() {},
	Flag: function Flag() {}, Value: function Value() {}, ListValue: function ListValue() {}, DynamicList: function DynamicList() {},
	DummyValue: function DummyValue() {}, MultiValue: function MultiValue() {}, TextValue: function TextValue() {}, Button: function Button() {}
};
const view = { extend: (o) => o };
global.L = { resolveDefault: (p, d) => Promise.resolve(p).catch(() => d), toArray: (x) => x == null ? [] : Array.isArray(x) ? x : String(x).split(/\s+/) };
const v = new Function('view', 'form', 'uci', 'ui', 'fs', SRC.replace(/^'require [^']+';$/mg, ''))(view, form,
	{ load: () => Promise.resolve() }, { changes: null }, { exec: () => Promise.resolve({ code: 0, stdout: '[]' }) });

(async () => {
	await v.render([ null, { code: 0, stdout: '[{"mac":"aa:bb:cc:dd:ee:01","name":"Phone","ipv4":["192.168.1.23"],"ipv6":[]}]' } ]);

	await check('lag simulator options are on the Zones page', () => {
		for (const n of [ 'lag', 'lag_direction', 'lag_delay', 'lag_jitter', 'lag_loss' ]) assert(options[n], n + ' missing');
		assert.strictEqual(options.lag.type, 'Flag');
		[ 'lag_direction', 'lag_delay', 'lag_jitter', 'lag_loss' ].forEach((n) => assert.deepStrictEqual(options[n].deps, [ [ 'lag', '1' ] ], n + ' only shown when lag is on'));
	});
	await check('lag direction: both / down / up, both by default (like the map panel and the router)', () => {
		assert.deepStrictEqual(options.lag_direction.values.map((x) => x[0]), [ 'both', 'down', 'up' ]);
		assert.strictEqual(options.lag_direction.default, 'both');
	});
	await check('open for server tests: 0 (off) by default, per-game advice', () => {
		assert.strictEqual(options.burst_servers.placeholder, '0');
		assert(/Apex Legends needs 2 or more/.test(options.burst_servers.descr) && /Call of Duty should stay at 0/.test(options.burst_servers.descr));
	});

	if (!LUCI) { console.log('SKIP: LuCI validation checks (no LuCI checkout given)'); return; }

	/* ---- LuCI's real validator */
	const baseclass = { extend(props) { const C = function() { if (this.__init__) this.__init__.apply(this, arguments); }; Object.assign(C.prototype, props); C.extend = baseclass.extend; return C; } };
	global.L.raise = (t, m) => { throw new Error(t + ': ' + m); };
	const vsrc = fs.readFileSync(path.join(LUCI, 'validation.js'), 'utf8').replace(/^'require [^']+';$/mg, '');
	const Factory = new Function('baseclass', 'L', vsrc)(baseclass, global.L);
	const factory = new Factory();
	function valid(type, value) {
		const field = { value, classList: { add() {}, remove() {} }, setAttribute() {}, dispatchEvent() {} };
		const vd = factory.create(field, type, true);
		vd.value = value;
		return vd.vstack[0].apply(vd, vd.vstack[1]) === true;
	}
	await check('every input rule on the page is one LuCI understands', () => {
		const bad = Object.values(options).filter((o) => o.datatype).filter((o) => { try { factory.compile(o.datatype); return false; } catch (e) { return true; } });
		assert.deepStrictEqual(bad.map((o) => o.name + ': ' + o.datatype), []);
	});
	await check('packet loss accepts 0-100 with decimals only', () => {
		const t = options.lag_loss.datatype;
		for (const ok of [ '0', '1.5', '0.25', '100' ]) assert(valid(t, ok), ok + ' refused');
		for (const no of [ '101', '-1', 'abc', '1,5' ]) assert(!valid(t, no), no + ' accepted');
	});
	await check('extra ping / jitter ranges', () => {
		assert(valid(options.lag_delay.datatype, '80') && !valid(options.lag_delay.datatype, '5001') && !valid(options.lag_delay.datatype, '1.5'));
		assert(valid(options.lag_jitter.datatype, '2000') && !valid(options.lag_jitter.datatype, '2001'));
	});
	await check('whole-number fields refuse decimals (the router only takes whole numbers)', () => {
		const ranged = Object.values(options).filter((o) => /range\(/.test(o.datatype || ''));
		assert(ranged.length >= 6, ranged.length);
		ranged.forEach((o) => assert(!valid(o.datatype, '20.5'), o.name + ' accepts 20.5'));
	});
	await check('servers / ports / devices', () => {
		assert(valid(options.burst_servers.datatype, '0') && valid(options.burst_servers.datatype, '2') && !valid(options.burst_servers.datatype, '-1'));
		const port = Object.values(options).find((o) => o.datatype === 'portrange');
		assert(valid('portrange', '3074') && valid('portrange', '30000-45000') && !valid('portrange', '70000'), port && port.name);
		const dev = Object.values(options).find((o) => /macaddr/.test(o.datatype || ''));
		assert(valid(dev.datatype, 'aa:bb:cc:dd:ee:ff') && valid(dev.datatype, '192.168.1.23') && !valid(dev.datatype, 'console'));
	});
})().then(() => {
	console.log(failed ? failed + ' FAILED' : 'ALL ZONES PAGE TESTS PASSED');
	process.exit(failed ? 1 : 0);
});
