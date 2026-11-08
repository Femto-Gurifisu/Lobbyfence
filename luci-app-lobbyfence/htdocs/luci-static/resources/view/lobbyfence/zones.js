'use strict';
'require view';
'require form';
'require uci';
'require ui';
'require fs';

/*
 * LobbyFence - settings and zones
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

function validateCircle(section_id, value) {
	if (value == null || value === '')
		return true;
	var p = String(value).split(',');
	if (p.length !== 3)
		return _('Use latitude,longitude,radius_km - for example 50.11,8.68,800');
	var lat = +p[0], lon = +p[1], r = +p[2];
	if (!isFinite(lat) || lat < -90 || lat > 90)
		return _('Latitude must be between -90 and 90');
	if (!isFinite(lon) || lon < -180 || lon > 180)
		return _('Longitude must be between -180 and 180');
	if (!isFinite(r) || r <= 0)
		return _('Radius must be a positive number of kilometres');
	return true;
}

function validatePolygon(section_id, value) {
	if (value == null || value === '')
		return true;
	var pts = String(value).split(';');
	if (pts.length < 3)
		return _('A polygon needs at least 3 corners');
	for (var i = 0; i < pts.length; i++) {
		var q = pts[i].split(','), lat = +q[0], lon = +q[1];
		if (q.length !== 2 || !isFinite(lat) || !isFinite(lon) || lat < -90 || lat > 90 || lon < -540 || lon > 540)
			return _('Corner %d is not "latitude,longitude"').format(i + 1);
	}
	return true;
}

function validateCountry(section_id, value) {
	if (value == null || value === '' || /^[A-Za-z]{2}$/.test(value))
		return true;
	return _('Use a two-letter country code such as DE, US or JP');
}

/* LobbyFence as a home-screen app: opened from the home screen this page too
 * shows without LuCI's menus (lf-app.js - see map.js) */
(function() {
	if (typeof window === 'undefined' || typeof document === 'undefined') return;
	var res = window.L && L.env && L.env.resource, s;
	if (window.LF_PLATFORM || !res || !document.head || document.getElementById('lf-appjs'))
		return;
	s = document.createElement('script');
	s.id = 'lf-appjs';
	s.async = true;
	s.src = String(res).replace(/\/resources\/?$/, '') + '/lobbyfence/lf-app.js';
	document.head.appendChild(s);
})();

return view.extend({
	load: function() {
		return Promise.all([
			uci.load('lobbyfence'),
			L.resolveDefault(fs.exec('/usr/sbin/lobbyfence', [ 'devices' ]), null)
		]);
	},

	render: function(data) {
		var devices = [];
		try { devices = JSON.parse((data && data[1] && data[1].code === 0 && data[1].stdout) || '[]'); } catch (e) {}
		var m, s, o;

		m = new form.Map('lobbyfence', _('LobbyFence - Zones'),
			_('A zone ties a game (its ports) on one or more of your devices to the regions its servers may be in. Draw the allowed regions on the <em>Map</em> page.'));

		/* ---------------------------------------------------- general */
		s = m.section(form.NamedSection, 'globals', 'globals', _('General settings'));
		s.addremove = false;

		o = s.option(form.Flag, 'enabled', _('Enable LobbyFence'));
		o.rmempty = false;

		o = s.option(form.Value, 'interval', _('Learning interval'),
			_('Seconds between passes that collect newly seen servers, locate them and update the filter.'));
		o.datatype = 'and(uinteger,range(15,3600))';
		o.placeholder = '60';

		o = s.option(form.Flag, 'log_blocked', _('Log blocked connections'),
			_('Writes a rate-limited line to the system log for every dropped connection attempt.'));

		o = s.option(form.Value, 'geo_url', _('Geolocation service'),
			_('Batch endpoint compatible with ip-api.com. The free ip-api.com service is HTTP only and for non-commercial use.'));
		o.placeholder = 'http://ip-api.com/batch';
		o.modalonly = true;

		o = s.option(form.Value, 'max_batches', _('Lookups per pass'),
			_('Each lookup locates up to 100 addresses. Requests are additionally limited to 14 per minute.'));
		o.datatype = 'and(uinteger,range(1,14))';
		o.placeholder = '4';

		o = s.option(form.Value, 'data_dir', _('Data directory'),
			_('Learned servers and locations are stored here so they survive a reboot.'));
		o.placeholder = '/etc/lobbyfence';

		/* ------------------------------------------------------- zones */
		s = m.section(form.GridSection, 'zone', _('Zones'));
		s.addremove = true;
		s.anonymous = false;
		s.sortable = true;
		s.nodescriptions = true;
		s.addbtntitle = _('Add zone…');

		o = s.option(form.Flag, 'enabled', _('Enabled'));
		o.editable = true;
		o.rmempty = false;

		o = s.option(form.Value, 'label', _('Name'));
		o.placeholder = _('e.g. My shooter');

		o = s.option(form.ListValue, 'mode', _('Mode'),
			_('<strong>Enforce</strong> drops connections to servers located outside the region (the default). <strong>Monitor</strong> only learns servers and counts what would be blocked.'));
		o.value('enforce', _('Enforce'));
		o.value('monitor', _('Monitor'));
		o.default = 'enforce';

		o = s.option(form.Flag, 'strict', _('Strict'),
			_('Also drop servers that have not been located yet (the default). A new server is usually located within a minute; allow it on the map if you need it sooner.'));
		o.default = '1';
		o.editable = true;

		o = s.option(form.DynamicList, 'device', _('Devices'),
			_('MAC address (recommended - covers all of the device\'s IPv4 and IPv6 addresses, best for phones) or an IPv4/IPv6 address or subnet.'));
		o.datatype = 'or(macaddr,ipaddr)';
		o.rmempty = false;
		/* suggestions: devices on the network, shown with their name and addresses */
		devices.forEach(function(d) {
			var ips = (d.ipv4 || []).concat(d.ipv6 || []);
			o.value(d.mac, (d.name || _('Unnamed device')) + (ips.length ? ' - ' + ips.join(', ') : '') + ' (' + String(d.mac).toUpperCase() + ')');
		});

		o = s.option(form.ListValue, 'proto', _('Protocol'));
		o.value('udp', 'UDP');
		o.value('tcp', 'TCP');
		o.value('both', _('UDP and TCP'));
		o.default = 'udp';

		o = s.option(form.DynamicList, 'port', _('Game ports (either side)'),
			_('Matches when the game server or your device uses one of these ports (e.g. 3074 for Call of Duty on consoles).'));
		o.datatype = 'portrange';

		o = s.option(form.DynamicList, 'remote_port', _('Server ports'),
			_('Ports the game servers use (e.g. 7000-8000). Set some ports - without any, ALL traffic of the device is filtered.'));
		o.datatype = 'portrange';
		o.modalonly = true;

		o = s.option(form.DynamicList, 'local_port', _('Device ports'),
			_('Ports the game uses on your device.'));
		o.datatype = 'portrange';
		o.modalonly = true;

		o = s.option(form.DynamicList, 'country', _('Allowed countries'),
			_('Servers located in these countries are allowed in addition to the circles.'));
		o.validate = validateCountry;
		o.modalonly = true;

		o = s.option(form.DynamicList, 'circle', _('Allowed circles'),
			_('latitude,longitude,radius_km - easier to edit on the Map page.'));
		o.validate = validateCircle;
		o.modalonly = true;

		o = s.option(form.DynamicList, 'polygon', _('Allowed polygons'),
			_('Corners as lat,lon;lat,lon;lat,lon... (at least 3) - draw them on the Map page instead.'));
		o.validate = validatePolygon;
		o.modalonly = true;

		o = s.option(form.DynamicList, 'allow_ip', _('Always allow'),
			_('Addresses or subnets that are never blocked, e.g. login, matchmaking or relay servers.'));
		o.datatype = 'ipaddr';
		o.modalonly = true;

		o = s.option(form.DynamicList, 'block_ip', _('Always block'));
		o.datatype = 'ipaddr';
		o.modalonly = true;

		o = s.option(form.Value, 'burst_servers', _('Open for server tests'),
			_('When this zone sees more than this many servers at once (a game testing data centres while you log in), it lets all of them through for a short while. Your region applies again as soon as it is over.') + ' ' +
			_('It varies by game: Apex Legends needs 2 or more, Call of Duty should stay at 0 (off). For other games start at 0 and raise it only if logging in or finding matches fails while filtering. 0 turns it off.'));
		o.datatype = 'and(uinteger,range(0,10000))';
		o.placeholder = '0';
		o.modalonly = true;

		o = s.option(form.Value, 'burst_open', _('Open for (seconds)'),
			_('How long the zone stays open after the last time it saw that many servers at once.'));
		o.datatype = 'and(uinteger,range(1,3600))';
		o.placeholder = '20';
		o.modalonly = true;

		o = s.option(form.Flag, 'lag', _('Lag simulator'),
			_('Makes this device\'s game connection worse on purpose (extra ping, jitter, packet loss) to test how a game plays on a bad connection. It only adds lag - it can never lower your ping. Needs the packages tc-full, kmod-netem, kmod-ifb and kmod-sched-core (plus kmod-sched-ctinfo for upload lag).'));
		o.modalonly = true;

		o = s.option(form.ListValue, 'lag_direction', _('Lag direction'),
			_('Both ways splits the extra ping half and half. Download only: the game\'s packets reach you late. Upload only: your packets reach the server late (needs kmod-sched-ctinfo).'));
		o.value('both', _('Both ways'));
		o.value('down', _('Download only'));
		o.value('up', _('Upload only'));
		o.default = 'both'; o.depends('lag', '1'); o.modalonly = true;

		o = s.option(form.Value, 'lag_delay', _('Extra ping (ms)'));
		o.datatype = 'and(uinteger,range(0,5000))'; o.placeholder = '0'; o.depends('lag', '1'); o.modalonly = true;

		o = s.option(form.Value, 'lag_jitter', _('Jitter (ms)'), _('How much the extra ping jumps up and down.'));
		o.datatype = 'and(uinteger,range(0,2000))'; o.placeholder = '0'; o.depends('lag', '1'); o.modalonly = true;

		o = s.option(form.Value, 'lag_loss', _('Packet loss (%)'), _('Share of the game\'s packets that are thrown away, e.g. 1 or 0.5.'));
		o.datatype = 'and(ufloat,max(100))'; o.placeholder = '0'; o.depends('lag', '1'); o.modalonly = true;

		o = s.option(form.Value, 'expire_days', _('Forget servers after (days)'),
			_('Servers not seen for this long are removed from the learned list. 0 keeps them forever.'));
		o.datatype = 'uinteger';
		o.placeholder = '30';
		o.modalonly = true;

		return m.render().then(function(node) {
			/* Save every change right away (like the "Save" button) so nothing is lost
			 * when switching tabs; changes take effect on "Save & Apply". */
			var timer = null;
			node.addEventListener('widget-change', function() {
				window.clearTimeout(timer);
				timer = window.setTimeout(function() {
					m.parse().then(function() {
						return uci.save();
					}).then(function() {
						if (ui.changes && typeof ui.changes.init === 'function')
							ui.changes.init();
					}).catch(function() { /* invalid input: keep it until it is fixed */ });
				}, 800);
			});
			return node;
		});
	}
});
