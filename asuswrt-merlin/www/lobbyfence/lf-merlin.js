/*
 * LobbyFence on Asuswrt-Merlin - the web page's link to the router.
 *
 * Merlin's web server can't run LobbyFence's commands, so:
 *  - what the page shows are files the router keeps in /user/lobbyfence/d/
 *    (status, server lists, settings, live data, answers);
 *  - a request goes through Merlin's add-on API: the page saves the add-on
 *    settings (/jffs/addons/custom_settings.txt) with one extra key,
 *    "lobbyfence_cmd", and asks for the "restart_lobbyfence" event; the
 *    router's service-event script hands it to LobbyFence, which takes the
 *    key out again and writes the answer to d/res-<id>.json. Long requests
 *    go in pieces (the settings file holds 8 KB for all add-ons).
 *  - changes made on the page are kept in this browser until Save & Apply,
 *    then sent as a list of changes, replayed onto the router's settings as
 *    they are at that moment.
 * Loaded before lf-shim.js. SPDX-License-Identifier: GPL-3.0-or-later
 */
(function(window) {
'use strict';

window.LF_PLATFORM = 'merlin';

var BASE = '/user/lobbyfence/d/';
var KEY = 'lobbyfence_cmd';
var PENDING = 'lobbyfence.pending';
var CHUNK = 2400;          /* one settings value holds 2999 characters */
var SETTINGS_MAX = 7600;   /* of 8192 for all add-ons together */

function get(name, opt) {
	return window.fetch(BASE + name + '?_=' + Date.now(), { credentials: 'same-origin', cache: 'no-store' }).then(function(r) {
		if (r.status === 404 && opt) return null;
		if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? 'Not logged in - reload the page' : 'HTTP error ' + r.status);
		return r.text();
	});
}

function getJSON(name, opt) {
	return get(name, opt).then(function(t) {
		if (t == null) return null;
		try { return JSON.parse(t); } catch (e) { if (opt) return null; throw new Error('Unexpected answer from the router'); }
	});
}

function sleep(ms) { return new Promise(function(r) { window.setTimeout(r, ms); }); }

/* every byte that isn't plain goes as %XX (no spaces, quotes, < or newlines) */
function pctEncode(s) {
	return encodeURIComponent(s).replace(/[!'()*]/g, function(c) {
		return '%' + c.charCodeAt(0).toString(16).toUpperCase();
	});
}

/* the add-on settings as they are on the router (other add-ons' too) */
function addonSettings() {
	return get('cs.json', true).then(function(t) {
		var o = {};
		String(t || '').split('\n').forEach(function(l) {
			var i = l.indexOf(' ');
			if (i > 0 && l.slice(0, i) !== KEY) o[l.slice(0, i)] = l.slice(i + 1).replace(/\r$/, '');
		});
		return o;
	});
}

function currentPage() {
	try { return window.parent.location.pathname.replace(/^\//, '') || 'index.asp'; }
	catch (e) { return 'index.asp'; }
}

/* ask the router for a service event, optionally with the add-on settings */
function submit(script, settings) {
	var body = new URLSearchParams();
	body.append('current_page', currentPage());
	body.append('next_page', currentPage());
	body.append('group_id', '');
	body.append('modified', '0');
	body.append('action_mode', 'apply');
	body.append('action_script', script);
	body.append('action_wait', '0');
	body.append('first_time', '');
	if (settings) body.append('amng_custom', JSON.stringify(settings));
	return window.fetch('/start_apply.htm', {
		method: 'POST', body: body, credentials: 'same-origin', cache: 'no-store'
	}).then(function(r) {
		if (!r.ok) throw new Error(r.status === 401 || r.status === 403 ? 'Not logged in - reload the page' : 'HTTP error ' + r.status);
	});
}

function waitFor(id, part, last, timeout) {
	var until = Date.now() + timeout;
	function poll() {
		return getJSON('res-' + id + '.json', true).then(function(d) {
			if (d && d.error) throw new Error(d.error);
			if (d && d.done) return d;
			if (d && !last && d.ack >= part) return d;
			if (Date.now() > until)
				throw new Error('The router did not answer. Is LobbyFence installed with its service-event hook? (System Log shows "lobbyfence")');
			return sleep(400).then(poll);
		});
	}
	return sleep(250).then(poll);
}

/* one request at a time: there is one settings key for it */
var queue = Promise.resolve();

function send(text, timeout) {
	var run = function() {
		var id = Date.now().toString(36) + Math.random().toString(36).slice(2, 8);
		var data = pctEncode(text);
		return addonSettings().then(function(others) {
			var room = SETTINGS_MAX - JSON.stringify(others).length - 64, size = Math.min(CHUNK, room), parts = [], i = 0, n;
			if (size < 300)
				throw new Error('The add-on settings file is full (other add-ons use almost all of its 8 KB)');
			while (i < data.length) {
				n = Math.min(size, data.length - i);
				/* don't cut a %XX in half */
				if (i + n < data.length) { var p = data.lastIndexOf('%', i + n - 1); if (p > i + n - 3) n = p - i; }
				parts.push(data.substr(i, n));
				i += n;
			}
			if (!parts.length) parts.push('');
			var step = function(k) {
				var s = {};
				Object.keys(others).forEach(function(key) { s[key] = others[key]; });
				s[KEY] = id + ' ' + (k + 1) + '/' + parts.length + ' ' + parts[k];
				var last = k === parts.length - 1;
				return submit('restart_lobbyfence', s).then(function() {
					return waitFor(id, k + 1, last, last ? (timeout || 30000) : 20000);
				}).then(function(d) { return last ? d : step(k + 1); });
			};
			return step(0);
		});
	};
	var p = queue.then(run, run);
	queue = p.catch(function() {});
	return p;
}

function loadPending() {
	try { return JSON.parse(window.localStorage.getItem(PENDING) || '[]') || []; } catch (e) { return memPending; }
}
function storePending(ops) {
	memPending = ops;
	try { if (ops.length) window.localStorage.setItem(PENDING, JSON.stringify(ops)); else window.localStorage.removeItem(PENDING); } catch (e) {}
}
var memPending = [];

/* the page's changes as lines for the router (conf.awk "ops") */
function opsText(ops) {
	return ops.map(function(o) {
		var f;
		if (o[0] === 'set') f = Array.isArray(o[3]) ? [ 'list', o[1], o[2] ].concat(o[3]) : [ 'set', o[1], o[2], o[3] ];
		else if (o[0] === 'unset') f = [ 'unset', o[1], o[2] ];
		else if (o[0] === 'add') f = [ 'add', o[1], o[2] ];
		else if (o[0] === 'remove') f = [ 'remove', o[1] ];
		else return null;
		return f.map(function(x) { return pctEncode(String(x == null ? '' : x)); }).join('\t');
	}).filter(Boolean).join('\n');
}

window.LF_TRANSPORT = function(h) {
	return {
		config: function() {
			return getJSON('config.json').then(function(d) {
				var pending = loadPending(), text = (d && d.text) || '';
				if (pending.length)
					text = h.serializeConfig(h.replay(h.parseConfig(text), pending));
				return { text: text, staged: pending.length > 0 };
			});
		},
		save: function(ops) {
			var pending = loadPending().concat(ops);
			storePending(pending);
			return this.config().then(function(d) { return { secs: h.parseConfig(d.text), staged: d.staged }; });
		},
		apply: function() {
			var pending = loadPending();
			if (!pending.length) return Promise.resolve({ code: 0, stdout: '', stderr: '' });
			return send('apply\n' + opsText(pending), 120000).then(function(d) {
				if (d.code === 0) storePending([]);
				return d;
			});
		},
		revert: function() { storePending([]); return Promise.resolve(); },
		exec: function(args) {
			if (args[0] === 'live') {
				/* a file the router writes again each time it has been read (no
				 * request: every service event also pauses ASUS's WAN watchdog) */
				return get('live.json', true).then(function(t) {
					return { code: 0, stdout: t || '', stderr: '' };
				});
			}
			/* (the debug report can take a while on a router with many servers) */
			return send(args.join(' '), args[0] === 'debug' ? 120000 : undefined).then(function(d) {
				return { code: d.code, stdout: d.stdout || '', stderr: d.stderr || '' };
			});
		},
		/* another router's servers file: sent in pieces like the settings (up to ~300 KB) */
		importServers: function(text) {
			/* (the router takes a request in at most 200 pieces) */
			if (pctEncode('import-servers\n' + text).length > CHUNK * 190)
				return Promise.reject(new Error('This file is too big to send to an Asuswrt-Merlin router at once - split it into smaller files'));
			return send('import-servers\n' + text, 300000).then(function(d) {
				return { code: d.code, stdout: d.stdout || '', stderr: d.stderr || '' };
			});
		},
		read: function(path) {
			var m;
			if (path === '/tmp/lobbyfence/status.json') return get('status.json');
			if ((m = /^\/tmp\/lobbyfence\/([A-Za-z0-9_]+)\.servers$/.exec(path)))
				return get(m[1] + '.servers.json', true).then(function(t) {
					if (t == null) throw new Error('no servers yet');
					return t;
				});
			return Promise.reject(new Error('Not available: ' + path));
		},
		running: function() {
			return getJSON('status.json', true).then(function(d) { return !!(d && d.daemon); });
		}
	};
};

})(window);
