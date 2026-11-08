'use strict';
'require view';
'require uci';
'require ui';
'require fs';

/*
 * LobbyFence for FreshTomato and Asuswrt-Merlin - Settings tab: general settings and every
 * zone's options (what LuCI's "Zones" page offers on OpenWrt). Regions are
 * drawn on the Map tab. Each change is kept on the router at once
 * ("Save"); Save & Apply puts it into effect.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

var ZONE_ID_MAX = 12;

function intIn(min, max) {
	return function(v) {
		if (!/^\d+$/.test(v)) return _('Whole number please');
		v = +v;
		return (v < min || v > max) ? _('Between %d and %d').format(min, max) : true;
	};
}

function pct(v) {
	if (!/^\d+(\.\d+)?$/.test(v)) return _('A number such as 1 or 0.5 please');
	return +v > 100 ? _('At most 100') : true;
}

function isV4(s) {
	var p = s.split('.');
	return p.length === 4 && p.every(function(x) { return /^\d{1,3}$/.test(x) && +x <= 255; });
}
function isV6(s) { return /^[0-9A-Fa-f:.]+$/.test(s) && s.indexOf(':') >= 0 && s.length <= 45 && (s.match(/::/g) || []).length <= 1; }
function isAddr(s) {
	var m = /^([^/]+)(?:\/(\d{1,3}))?$/.exec(s);
	if (!m) return false;
	if (isV4(m[1])) return m[2] == null || +m[2] <= 32;
	if (isV6(m[1])) return m[2] == null || +m[2] <= 128;
	return false;
}
function isMac(s) { return /^[0-9A-Fa-f]{2}([:-][0-9A-Fa-f]{2}){5}$/.test(s); }
function isPortRange(s) {
	var m = /^(\d{1,5})(?:-(\d{1,5}))?$/.exec(s);
	if (!m) return false;
	var a = +m[1], b = m[2] != null ? +m[2] : a;
	return a >= 1 && b <= 65535 && a <= b;
}

var LISTS = {
	device: [ function(s) { return isMac(s) || isAddr(s); }, _('a MAC address or an IPv4/IPv6 address') ],
	port: [ isPortRange, _('a port or range such as 3074 or 30000-45000') ],
	remote_port: [ isPortRange, _('a port or range such as 3074 or 30000-45000') ],
	local_port: [ isPortRange, _('a port or range such as 3074 or 30000-45000') ],
	country: [ function(s) { return /^[A-Za-z]{2}$/.test(s); }, _('a two-letter country code such as DE or US') ],
	allow_ip: [ isAddr, _('an IPv4/IPv6 address or subnet') ],
	block_ip: [ isAddr, _('an IPv4/IPv6 address or subnet') ]
};

function sectionName(label, existing) {
	var base = String(label || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '').slice(0, ZONE_ID_MAX);
	if (!/^[a-z]/.test(base))
		base = ('zone' + (base ? '_' + base : '')).slice(0, ZONE_ID_MAX).replace(/_+$/, '');
	var name = base, i = 2;
	while (existing.indexOf(name) >= 0)
		name = base + '_' + (i++);
	return name;
}

var CSS = [
	'.lfs{background:var(--lft-card);border:1px solid var(--lft-border);border-radius:10px;padding:14px 16px;margin-top:0}',
	'.lfs h3{margin:0 0 10px;font-size:16px}',
	'.lfs-intro{color:var(--lft-muted);margin:0 0 14px}',
	'.lfs-sec{border-top:1px solid var(--lft-border);padding-top:12px;margin-top:12px}',
	'.lfs-row{display:grid;grid-template-columns:220px minmax(0,1fr);gap:4px 14px;align-items:start;padding:6px 0}',
	'.lfs-row label{font-weight:600;padding-top:4px}',
	'.lfs-help{color:var(--lft-muted);font-size:12px;margin-top:2px}',
	'.lfs-err{color:var(--lft-danger);font-size:12px;margin-top:2px}',
	'.lfs-row input[type=text],.lfs-row input[type=number],.lfs-row select,.lfs-row textarea{width:100%;max-width:420px}',
	'.lfs-row textarea{min-height:52px;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:12.5px}',
	'.lfs-zone{border:1px solid var(--lft-border);border-radius:8px;margin:10px 0;overflow:hidden}',
	'.lfs-zhead{display:flex;align-items:center;gap:10px;padding:8px 12px;cursor:pointer;background:var(--lft-bg)}',
	'.lfs-zhead b{flex:1}',
	'.lfs-zbody{padding:4px 12px 10px}',
	'.lfs-badge{font-size:11px;padding:1px 7px;border-radius:9px;border:1px solid var(--lft-border);color:var(--lft-muted)}',
	'.lfs-badge.on{color:var(--lft-ok);border-color:var(--lft-ok)}',
	'.lfs-add{display:flex;gap:8px;align-items:center;margin-top:10px;flex-wrap:wrap}',
	'@media (max-width:700px){.lfs-row{grid-template-columns:1fr}}'
].join('\n');

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('lobbyfence'),
			L.resolveDefault(fs.exec('/usr/sbin/lobbyfence', [ 'devices' ]), null)
		]);
	},

	stage: function() {
		var self = this;
		window.clearTimeout(this.timer);
		this.timer = window.setTimeout(function() {
			uci.save().catch(function(err) {
				ui.addNotification(null, E('p', {}, [ _('Could not save the change: %s').format(err && err.message || err) ]), 'error');
			});
		}, 600);
	},

	handleSave: function() {
		window.clearTimeout(this.timer);
		return uci.save();
	},

	/* one input bound to one option */
	field: function(sid, f) {
		var self = this, input, err = E('div', { 'class': 'lfs-err', 'style': 'display:none' }), v = uci.get('lobbyfence', sid, f.opt);
		function bad(msg) {
			input.classList.toggle('cbi-input-invalid', !!msg);
			err.textContent = msg || '';
			err.style.display = msg ? '' : 'none';
		}
		if (f.type === 'flag') {
			input = E('input', { 'type': 'checkbox', 'data-opt': f.opt });
			input.checked = (v == null || v === '') ? !!f.def : v === '1';
			input.addEventListener('change', function() {
				uci.set('lobbyfence', sid, f.opt, input.checked ? '1' : '0');
				if (f.onchange) f.onchange(input.checked);
				self.stage();
			});
		}
		else if (f.type === 'select') {
			input = E('select', { 'class': 'cbi-input-select', 'data-opt': f.opt }, f.options.map(function(o) {
				return E('option', { 'value': o[0] }, [ o[1] ]);
			}));
			input.value = (v == null || v === '') ? f.def : v;
			input.addEventListener('change', function() { uci.set('lobbyfence', sid, f.opt, input.value); self.stage(); });
		}
		else if (f.type === 'list') {
			var rule = LISTS[f.opt];
			input = E('textarea', { 'class': 'cbi-input-textarea', 'data-opt': f.opt, 'placeholder': f.placeholder || _('one per line'), 'rows': 2 });
			input.value = L.toArray(v).join('\n');
			input.addEventListener('input', function() {
				var items = input.value.split(/[\s,]+/).filter(function(x) { return x !== ''; }), wrong;
				wrong = items.filter(function(x) { return !rule[0](x); });
				if (wrong.length) { bad(_('"%s" is not %s').format(wrong[0], rule[1])); return; }
				bad(null);
				if (f.opt === 'country') items = items.map(function(x) { return x.toUpperCase(); });
				uci.set('lobbyfence', sid, f.opt, items);
				self.stage();
			});
		}
		else {
			input = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'data-opt': f.opt, 'placeholder': f.placeholder || '' });
			input.value = v == null ? '' : v;
			input.addEventListener('input', function() {
				var val = input.value.trim(), ok = (val === '' || !f.validate) ? true : f.validate(val);
				if (ok !== true) { bad(ok); return; }
				bad(null);
				uci.set('lobbyfence', sid, f.opt, val);
				if (f.onchange) f.onchange(val);
				self.stage();
			});
		}
		return E('div', { 'class': 'lfs-row', 'data-row': f.opt }, [
			E('label', {}, [ f.label ]),
			E('div', {}, [ input, err, f.help ? E('div', { 'class': 'lfs-help' }, [ f.help ]) : null, f.extra ? f.extra(input) : null ])
		]);
	},

	zoneCard: function(s, devices, open) {
		var self = this, sid = s['.name'], body, badge, title;
		var circles = L.toArray(s.circle).length, polys = L.toArray(s.polygon).length;
		badge = E('span', { 'class': 'lfs-badge' + (s.enabled === '1' ? ' on' : '') }, [ s.enabled === '1' ? _('on') : _('off') ]);
		title = E('b', {}, [ s.label || sid ]);

		function deviceHelper(input) {
			if (!devices.length) return null;
			var sel = E('select', { 'class': 'cbi-input-select', 'style': 'margin-top:4px' }, [ E('option', { 'value': '' }, [ _('Add a device on your network…') ]) ]
				.concat(devices.map(function(d) {
					var ips = (d.ipv4 || []).concat(d.ipv6 || []);
					return E('option', { 'value': d.mac }, [ (d.name || _('Unnamed device')) + (ips.length ? ' - ' + ips.join(', ') : '') + ' (' + String(d.mac).toUpperCase() + ')' ]);
				})));
			sel.addEventListener('change', function() {
				if (!sel.value) return;
				input.value = (input.value.trim() ? input.value.trim() + '\n' : '') + sel.value;
				input.dispatchEvent(new Event('input'));
				sel.value = '';
			});
			return sel;
		}

		var fields = [
			{ opt: 'enabled', label: _('Enabled'), type: 'flag', def: false, onchange: function(on) {
				badge.textContent = on ? _('on') : _('off'); badge.classList.toggle('on', on); } },
			{ opt: 'label', label: _('Name'), placeholder: _('e.g. My shooter'), onchange: function(v) { title.textContent = v || sid; } },
			{ opt: 'mode', label: _('Mode'), type: 'select', def: 'enforce', options: [ [ 'enforce', _('Enforce - block servers outside the region') ], [ 'monitor', _('Monitor - only learn and count') ] ] },
			{ opt: 'strict', label: _('Strict'), type: 'flag', def: true,
			  help: _('Also block servers that have not been located yet (usually located within a minute).') },
			{ opt: 'device', label: _('Devices'), type: 'list', extra: deviceHelper,
			  help: _('MAC address (best - covers all of the device\'s addresses) or an IPv4/IPv6 address, one per line.') },
			{ opt: 'proto', label: _('Protocol'), type: 'select', def: 'udp', options: [ [ 'udp', 'UDP' ], [ 'tcp', 'TCP' ], [ 'both', _('UDP and TCP') ] ] },
			{ opt: 'port', label: _('Game ports (either side)'), type: 'list',
			  help: _('Matches when the server or your device uses one of these ports (e.g. 3074 for Call of Duty).') },
			{ opt: 'remote_port', label: _('Server ports'), type: 'list',
			  help: _('Ports the game servers use. Without any ports, ALL traffic of the device is filtered.') },
			{ opt: 'local_port', label: _('Device ports'), type: 'list' },
			{ opt: 'country', label: _('Allowed countries'), type: 'list', help: _('Servers in these countries are allowed in addition to the region on the map.') },
			{ opt: 'allow_ip', label: _('Always allow'), type: 'list', help: _('Never blocked, e.g. login or matchmaking servers.') },
			{ opt: 'block_ip', label: _('Always block'), type: 'list' },
			{ opt: 'burst_servers', label: _('Open for server tests'), placeholder: '0', validate: intIn(0, 10000),
			  help: _('More than this many servers at once (a game testing data centres) lets them all through for a short while. Apex Legends needs 2 or more, Call of Duty should stay at 0 (off).') },
			{ opt: 'burst_open', label: _('Open for (seconds)'), placeholder: '20', validate: intIn(1, 3600) },
			{ opt: 'expire_days', label: _('Forget servers after (days)'), placeholder: '30', validate: intIn(0, 36500),
			  help: _('Servers not seen for this long are removed. 0 keeps them forever.') },
			{ opt: 'lag', label: _('Lag simulator'), type: 'flag', def: false,
			  help: _('Makes this device\'s game connection worse on purpose (extra ping, jitter, packet loss) to test how a game plays on a bad connection. It only adds lag - it can never lower your ping. Not while QoS or the bandwidth limiter is on.') },
			{ opt: 'lag_direction', label: _('Lag direction'), type: 'select', def: 'both',
			  options: [ [ 'both', _('Both ways (half each)') ], [ 'down', _('Download only') ], [ 'up', _('Upload only') ] ] },
			{ opt: 'lag_delay', label: _('Extra ping (ms)'), placeholder: '0', validate: intIn(0, 5000) },
			{ opt: 'lag_jitter', label: _('Jitter (ms)'), placeholder: '0', validate: intIn(0, 2000), help: _('How much the extra ping jumps up and down.') },
			{ opt: 'lag_loss', label: _('Packet loss (%)'), placeholder: '0', validate: pct, help: _('Share of the game\'s packets thrown away, e.g. 1 or 0.5.') }
		];

		body = E('div', { 'class': 'lfs-zbody', 'style': open ? '' : 'display:none' },
			fields.map(function(f) { return self.field(sid, f); }).concat([
				E('div', { 'class': 'lfs-row' }, [ E('label', {}, [ _('Region') ]), E('div', { 'class': 'lfs-help', 'style': 'padding-top:4px' }, [
					_('%d circle(s) and %d shape(s) - draw and change them on the Map tab.').format(circles, polys) ]) ]),
				E('div', { 'class': 'right' }, [ E('button', { 'class': 'cbi-button cbi-button-negative', 'click': function(ev) {
					ev.preventDefault();
					ui.showModal(_('Delete zone'), [
						E('p', {}, [ _('Delete the zone "%s" and its learned servers?').format(s.label || sid) ]),
						E('div', { 'class': 'right' }, [
							E('button', { 'class': 'cbi-button', 'click': function() { ui.hideModal(); } }, [ _('Cancel') ]), ' ',
							E('button', { 'class': 'cbi-button cbi-button-negative important', 'click': function() {
								ui.hideModal();
								uci.remove('lobbyfence', sid);
								card.remove();
								self.stage();
							} }, [ _('Delete') ])
						])
					]);
				} }, [ _('Delete zone') ]) ])
			]));
		var card = E('div', { 'class': 'lfs-zone', 'data-zone': sid }, [
			E('div', { 'class': 'lfs-zhead', 'click': function() { body.style.display = body.style.display === 'none' ? '' : 'none'; } }, [
				title, E('span', { 'class': 'lfs-help' }, [ sid ]), badge ]),
			body
		]);
		return card;
	},

	render: function(data) {
		var self = this, devices = [], zonesBox, addInput;
		try { devices = JSON.parse((data && data[1] && data[1].code === 0 && data[1].stdout) || '[]'); } catch (e) {}
		if (!document.getElementById('lfs-css'))
			document.head.appendChild(E('style', { 'id': 'lfs-css' }, [ CSS ]));
		if (!uci.get('lobbyfence', 'globals'))
			uci.add('lobbyfence', 'globals', 'globals');

		var general = [
			{ opt: 'enabled', label: _('Enable LobbyFence'), type: 'flag', def: false },
			{ opt: 'interval', label: _('Learning interval (seconds)'), placeholder: '20', validate: intIn(15, 3600),
			  help: _('How often newly seen servers are collected, located and filtered.') },
			{ opt: 'log_blocked', label: _('Log blocked connections'), type: 'flag', def: false,
			  help: _('A rate-limited line in the system log (Status > Logs) for blocked connection attempts.') },
			{ opt: 'geo_url', label: _('Geolocation service'), placeholder: 'http://ip-api.com/batch',
			  help: _('Batch endpoint compatible with ip-api.com (free, HTTP only, non-commercial use).') },
			{ opt: 'max_batches', label: _('Lookups per pass'), placeholder: '4', validate: intIn(1, 14),
			  help: _('Each lookup locates up to 100 addresses; at most 14 lookups per minute.') },
			{ opt: 'data_dir', label: _('Data directory'), placeholder: window.LF_PLATFORM === 'merlin' ? '/jffs/addons/lobbyfence/data' : '/jffs/lobbyfence/data',
			  help: _('Learned servers and locations are saved here (on JFFS) so they survive a reboot.') }
		];

		zonesBox = E('div', {}, uci.sections('lobbyfence', 'zone').map(function(s, i, all) {
			return self.zoneCard(s, devices, all.length === 1);
		}));

		addInput = E('input', { 'type': 'text', 'class': 'cbi-input-text', 'placeholder': _('Name of the new zone'), 'style': 'max-width:260px' });
		var add = E('div', { 'class': 'lfs-add' }, [
			addInput,
			E('button', { 'class': 'cbi-button cbi-button-add', 'click': function(ev) {
				ev.preventDefault();
				var label = addInput.value.trim() || _('My game');
				var existing = uci.sections('lobbyfence').map(function(x) { return x['.name']; });
				var sid = sectionName(label, existing);
				uci.add('lobbyfence', 'zone', sid);
				uci.set('lobbyfence', sid, 'enabled', '1');
				uci.set('lobbyfence', sid, 'label', label);
				uci.set('lobbyfence', sid, 'mode', 'enforce');
				uci.set('lobbyfence', sid, 'strict', '1');
				uci.set('lobbyfence', sid, 'proto', 'udp');
				uci.set('lobbyfence', sid, 'remote_port', [ '1024-65535' ]);
				addInput.value = '';
				zonesBox.appendChild(self.zoneCard(uci.get('lobbyfence', sid), devices, true));
				self.stage();
			} }, [ _('Add zone') ]),
			E('span', { 'class': 'lfs-help' }, [ _('Tip: the "New zone" window on the Map tab fills in the ports for popular games.') ])
		]);

		return E('div', { 'class': 'lfs' }, [
			E('h3', {}, [ _('LobbyFence - Settings') ]),
			E('p', { 'class': 'lfs-intro' }, [ _('A zone ties a game (its ports) on one of your devices to the region its servers may be in. Draw the regions on the Map tab. Changes are kept on the router as you make them and take effect with Save & Apply.') ]),
			E('div', { 'class': 'lfs-sec', 'data-section': 'globals' }, [ E('h3', {}, [ _('General') ]) ].concat(general.map(function(f) { return self.field('globals', f); }))),
			E('div', { 'class': 'lfs-sec', 'data-section': 'zones' }, [ E('h3', {}, [ _('Zones') ]), zonesBox, add ])
		]);
	}
});
