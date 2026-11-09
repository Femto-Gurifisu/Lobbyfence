/*
 * LobbyFence on FreshTomato - a small stand-in for the parts of LuCI's
 * JavaScript API that LobbyFence's pages use (E, _, L, uci, fs, ui, rpc, poll,
 * network, view). The map page is the very same file as on OpenWrt; here it
 * talks to the router through /ext/cgi-bin/lobbyfence.cgi.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
(function(window, document) {
'use strict';

window.LF_PLATFORM = window.LF_PLATFORM || 'tomato';
var CGI = window.LF_CGI || '/ext/cgi-bin/lobbyfence.cgi';

/* LobbyFence was called RegionGate before: what this browser remembered under
 * the old name (settings of the page, changes not applied yet, the install
 * tip) moves over once - before anything reads it */
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

/* ------------------------------------------------------------- router link */

function call(cmdline, data) {
	var body = String(window.LF_TOKEN || '') + '\n' + cmdline + '\n' + (data || '');
	return window.fetch(CGI, {
		method: 'POST', body: body, credentials: 'same-origin', cache: 'no-store',
		headers: { 'Content-Type': 'text/plain' }
	}).then(function(r) {
		if (!r.ok)
			throw new Error(r.status === 401 ? 'Not logged in - reload the page' : 'HTTP error ' + r.status);
		return r.text();
	}).then(function(t) {
		var d;
		try { d = JSON.parse(t); } catch (e) { throw new Error('Unexpected answer from the router'); }
		if (d && d.signin && typeof window.LF_ON_SIGNIN === 'function')
			window.LF_ON_SIGNIN();
		if (d && d.error)
			throw new Error(d.error);
		return d;
	});
}

/* The router link. FreshTomato: the CGI above. Another platform (Merlin)
 * sets window.LF_TRANSPORT (a function getting this file's helpers) before
 * this file runs; the object it returns has the same methods:
 *   config()       -> { text, staged }     the settings the page shows
 *   save(ops)      -> { secs, staged }     keep the page's changes (not applied)
 *   apply()        -> { code, stdout, stderr }
 *   revert(), exec(args) -> { code, stdout, stderr }, read(path) -> text,
 *   running() -> bool */
var cgiTransport = {
	config: function() { return call('config'); },
	/* replayed onto the router's current file, kept aside there until Apply */
	save: function(ops) {
		var merged;
		return call('config').then(function(d) {
			merged = replay(parseConfig(d.text), ops);
			return call('stage', serializeConfig(merged));
		}).then(function(d) { return { secs: merged, staged: !!d.staged }; });
	},
	apply: function() { return call('apply'); },
	revert: function() { return call('revert'); },
	exec: function(args) { return call('exec ' + args.join(' ')); },
	/* another router's servers file (lobbyfence import-servers) */
	importServers: function(text) { return call('import-servers', text); },
	read: function(path) {
		var m;
		if (path === '/tmp/lobbyfence/status.json')
			return call('read status').then(function(d) { return JSON.stringify(d); });
		if ((m = /^\/tmp\/lobbyfence\/([A-Za-z0-9_]+)\.servers$/.exec(path)))
			return call('read servers ' + m[1]).then(function(d) { return d.text; });
		return Promise.reject(new Error('Not available: ' + path));
	},
	running: function() { return call('running').then(function(d) { return !!d.running; }); }
};
var T;   /* set below, once replay / parseConfig exist */

/* ------------------------------------------------------------------- E, _ */

function isElem(n) { return n != null && typeof n === 'object' && n.nodeType === 1; }

function append(node, children) {
	if (Array.isArray(children)) {
		children.forEach(function(c) {
			if (Array.isArray(c)) append(node, c);
			else if (c != null && typeof c === 'object' && c.nodeType) node.appendChild(c);
			else if (c != null) node.appendChild(document.createTextNode(String(c)));
		});
	}
	else if (children != null && typeof children === 'object' && children.nodeType) {
		node.appendChild(children);
	}
	else if (typeof children === 'function') {
		append(node, children(node));
	}
	else if (children != null) {
		/* like LuCI: a plain string is HTML (the map page passes text as [ text ]) */
		node.innerHTML = String(children);
	}
	return node;
}

/* LuCI's E(tag, [attributes], [children]) */
function E(tag, attr, data) {
	var node = isElem(tag) ? tag : document.createElement(tag);
	if (arguments.length === 2 && (Array.isArray(attr) || isElem(attr) || typeof attr !== 'object' || attr === null)) {
		data = attr; attr = null;
	}
	if (attr) {
		Object.keys(attr).forEach(function(k) {
			var v = attr[k];
			if (v == null) return;
			if (typeof v === 'function') node.addEventListener(k, v);
			else if (typeof v === 'object') node.setAttribute(k, JSON.stringify(v));
			else node.setAttribute(k, v);
		});
	}
	return append(node, data);
}

function _(s) { return s; }

/* LuCI's String.format: %s %d %f %x %% with flags, width and precision */
String.prototype.format = function() {
	var args = arguments, i = 0;
	return this.replace(/%(-)?(0)?(\d+)?(?:\.(\d+))?([sdfxXh%])/g, function(m, left, zero, width, prec, t) {
		if (t === '%') return '%';
		var v = args[i++], s;
		switch (t) {
		case 'd': s = String(Math.trunc(+v || 0)); break;
		case 'f': s = (+v || 0).toFixed(prec != null ? +prec : 6); break;
		case 'x': s = (+v >>> 0).toString(16); break;
		case 'X': s = (+v >>> 0).toString(16).toUpperCase(); break;
		default: s = (v == null) ? '' : String(v); if (prec != null) s = s.substring(0, +prec);
		}
		width = +width || 0;
		while (s.length < width) s = left ? s + ' ' : (zero ? '0' : ' ') + s;
		return s;
	});
};

/* -------------------------------------------------------------------- L */

var L = {
	env: { platform: 'tomato' },
	resolveDefault: function(p, d) { return Promise.resolve(p).catch(function() { return d; }); },
	toArray: function(v) {
		if (v == null) return [];
		if (Array.isArray(v)) return v;
		if (typeof v === 'object') return [ v ];
		var s = String(v).trim();
		return s === '' ? [] : s.split(/\s+/);
	},
	url: function() { return '#'; }
};

/* ------------------------------------------------------------------ uci */

/* the router keeps the settings in UCI syntax: config / option / list */
function words(line) {
	var out = [], w = '', inw = false, q = null, c, i;
	for (i = 0; i < line.length; i++) {
		c = line[i];
		if (q === '\'') { if (c === '\'') q = null; else w += c; continue; }
		if (q === '"') {
			if (c === '\\' && i + 1 < line.length) w += line[++i];
			else if (c === '"') q = null;
			else w += c;
			continue;
		}
		if (c === ' ' || c === '\t') { if (inw) { out.push(w); w = ''; inw = false; } continue; }
		if (c === '#' && !inw) break;
		inw = true;
		if (c === '\'' || c === '"') q = c;
		else if (c === '\\' && i + 1 < line.length) w += line[++i];
		else w += c;
	}
	if (inw) out.push(w);
	return out;
}

function parseConfig(text) {
	var secs = {}, n = 0, cur = null;
	String(text || '').split(/\r?\n/).forEach(function(line) {
		var w = words(line), name;
		if (!w.length) return;
		if (w[0] === 'config' && w.length >= 2) {
			name = w[2] || ('cfg' + (n + 1).toString(16));
			cur = secs[name] = { '.name': name, '.type': w[1], '.anonymous': !w[2], '.index': n++ };
		}
		else if (cur && w.length >= 3 && /^[A-Za-z0-9_]+$/.test(w[1])) {
			if (w[0] === 'option') cur[w[1]] = w[2];
			else if (w[0] === 'list') { if (!Array.isArray(cur[w[1]])) cur[w[1]] = []; cur[w[1]].push(w[2]); }
		}
	});
	return secs;
}

function quote(v) { return '\'' + String(v).replace(/'/g, '\'\\\'\'') + '\''; }

function serializeConfig(secs) {
	return Object.keys(secs).map(function(k) { return secs[k]; }).sort(function(a, b) {
		return a['.index'] - b['.index'];
	}).map(function(s) {
		var out = [ 'config ' + s['.type'] + ' ' + quote(s['.name']) ];
		Object.keys(s).forEach(function(o) {
			if (o.charAt(0) === '.' || s[o] == null) return;
			if (Array.isArray(s[o])) s[o].forEach(function(v) { out.push('\tlist ' + o + ' ' + quote(v)); });
			else out.push('\toption ' + o + ' ' + quote(s[o]));
		});
		return out.join('\n');
	}).join('\n\n') + '\n';
}

/* replay the page's changes onto a configuration (like LuCI: "Save" sends the
 * changes, not the page's whole copy - the router may have changed the file
 * meanwhile, e.g. "Always allow" clicked on the map) */
function replay(secs, ops) {
	ops.forEach(function(o) {
		var s = secs[o[1]], max = -1;
		if (o[0] === 'set' && s) s[o[2]] = Array.isArray(o[3]) ? o[3].slice() : o[3];
		else if (o[0] === 'unset' && s) delete s[o[2]];
		else if (o[0] === 'remove') delete secs[o[1]];
		else if (o[0] === 'add' && !s) {
			Object.keys(secs).forEach(function(k) { max = Math.max(max, secs[k]['.index']); });
			secs[o[1]] = { '.name': o[1], '.type': o[2], '.anonymous': false, '.index': max + 1 };
		}
	});
	return secs;
}

T = window.LF_TRANSPORT
	? window.LF_TRANSPORT({ parseConfig: parseConfig, serializeConfig: serializeConfig, replay: replay })
	: cgiTransport;

var uci = {
	data: {},
	ops: [],
	staged: false,
	dirty: false,
	load: function(conf) {
		var self = this;
		return T.config().then(function(d) {
			self.data[conf] = parseConfig(d.text);
			self.staged = !!d.staged;
			self.dirty = false;
			self.ops = [];
			return [ conf ];
		});
	},
	get: function(conf, sid, opt) {
		var s = this.data[conf] && this.data[conf][sid];
		if (!s) return null;
		if (opt == null) return s;
		return s.hasOwnProperty(opt) ? s[opt] : null;
	},
	set: function(conf, sid, opt, val) {
		var s = this.data[conf] && this.data[conf][sid];
		if (!s || opt == null || opt.charAt(0) === '.') return;
		if (val == null || val === '' || (Array.isArray(val) && !val.length)) { this.unset(conf, sid, opt); return; }
		s[opt] = Array.isArray(val) ? val.map(String) : String(val);
		this.ops.push([ 'set', sid, opt, Array.isArray(s[opt]) ? s[opt].slice() : s[opt] ]);
		this.dirty = true;
	},
	unset: function(conf, sid, opt) {
		var s = this.data[conf] && this.data[conf][sid];
		if (s && s.hasOwnProperty(opt)) { delete s[opt]; this.ops.push([ 'unset', sid, opt ]); this.dirty = true; }
	},
	add: function(conf, type, name) {
		var secs = this.data[conf] = this.data[conf] || {}, max = -1;
		Object.keys(secs).forEach(function(k) { max = Math.max(max, secs[k]['.index']); });
		if (!name) { do { name = 'cfg' + Math.floor(Math.random() * 0xffffff).toString(16); } while (secs[name]); }
		secs[name] = { '.name': name, '.type': type, '.anonymous': false, '.index': max + 1 };
		this.ops.push([ 'add', name, type ]);
		this.dirty = true;
		return name;
	},
	remove: function(conf, sid) {
		if (this.data[conf] && this.data[conf][sid]) { delete this.data[conf][sid]; this.ops.push([ 'remove', sid ]); this.dirty = true; }
	},
	sections: function(conf, type, cb) {
		var secs = this.data[conf] || {};
		var list = Object.keys(secs).map(function(k) { return secs[k]; }).filter(function(s) {
			return type == null || s['.type'] === type;
		}).sort(function(a, b) { return a['.index'] - b['.index']; });
		if (typeof cb === 'function') list.forEach(function(s) { cb.call(this, s, s['.name']); });
		return list;
	},
	/* LuCI's "Save": the changes go to the router, but are not applied yet.
	 * They are replayed onto the router's current file, then the page's copy
	 * is that result (plus anything changed while this was under way) */
	save: function() {
		var self = this, ops = this.ops;
		if (!this.data.lobbyfence) return Promise.resolve();
		this.ops = [];
		this.dirty = false;
		return T.save(ops).then(function(d) {
			self.data.lobbyfence = replay(d.secs, self.ops);
			self.staged = !!d.staged;
			updateIndicator();
		}, function(err) { self.ops = ops.concat(self.ops); self.dirty = true; throw err; });
	},
	changes: function() {
		return Promise.resolve(this.staged ? { lobbyfence: [ [ 'set', 'lobbyfence' ] ] } : {});
	},
	apply: function() {
		var self = this;
		return T.apply().then(function(r) {
			if (r.code !== 0)
				throw new Error((r.stderr || r.stdout || 'apply failed').trim());
			self.staged = false;
			return r;
		});
	},
	revert: function() {
		var self = this;
		return T.revert().then(function() { self.staged = false; self.ops = []; });
	}
};

/* ------------------------------------------------------------------- fs */

/* (a servers file to import is written here and then handed to
   "import-servers" - as on OpenWrt; here both go in one request) */
var IMPORT_PATH = '/tmp/lobbyfence/servers-import.txt', importText = null;
var fs = {
	exec: function(path, args) {
		args = (args || []).map(String);
		if (path === '/etc/init.d/lobbyfence')
			return T.exec([ args[0] === 'restart' ? 'restart' : 'unknown' ]);
		if (path === '/usr/sbin/lobbyfence' && args[0] === 'import-servers') {
			if (args[1] !== IMPORT_PATH || importText == null || !T.importServers)
				return Promise.reject(new Error('Not available: ' + args.join(' ')));
			var text = importText;
			importText = null;
			return T.importServers(text);
		}
		if (path === '/usr/sbin/lobbyfence')
			return T.exec(args);
		return Promise.reject(new Error('Not available on FreshTomato: ' + path));
	},
	read: function(path) { return T.read(path); },
	write: function(path, data) {
		if (path !== IMPORT_PATH)
			return Promise.reject(new Error('Not available: ' + path));
		importText = String(data);
		return Promise.resolve(0);
	}
};

/* ------------------------------------------------------------------- ui */

function noticeArea() {
	var a = document.getElementById('lf-notices');
	if (!a) {
		a = E('div', { 'id': 'lf-notices' });
		document.body.appendChild(a);
	}
	return a;
}

var indicator = null;
function updateIndicator() {
	if (!indicator) indicator = document.getElementById('lf-changes');
	if (indicator) {
		indicator.textContent = uci.staged ? _('Unapplied changes') : '';
		indicator.style.display = uci.staged ? '' : 'none';
	}
}

var ui = {
	showModal: function(title, children) {
		var ov = document.getElementById('modal_overlay'), dlg;
		if (!ov) {
			ov = E('div', { 'id': 'modal_overlay' }, E('div', { 'class': 'modal', 'role': 'dialog', 'aria-modal': 'true' }));
			document.body.appendChild(ov);
		}
		dlg = ov.firstChild;
		dlg.innerHTML = '';
		if (title) dlg.appendChild(E('h4', {}, [ String(title) ]));
		append(dlg, children);
		document.body.classList.add('modal-overlay-active');
		return dlg;
	},
	hideModal: function() {
		document.body.classList.remove('modal-overlay-active');
	},
	addNotification: function(title, children, type) {
		var box = E('div', { 'class': 'alert-message fade-in ' + (type || '') }, [
			E('button', { 'class': 'lf-notice-close', 'title': _('Dismiss'), 'click': function() { box.remove(); } }, [ '×' ]),
			title ? E('h4', {}, [ String(title) ]) : null
		]);
		append(box, children);
		noticeArea().appendChild(box);
		window.setTimeout(function() { if (box.parentNode) box.remove(); }, 12000);
		return box;
	},
	createHandlerFn: function(ctx, fn) {
		var args = Array.prototype.slice.call(arguments, 2);
		return function(ev) {
			var f = (typeof fn === 'function') ? fn : ctx[fn], btn = ev && ev.currentTarget;
			if (btn) { btn.classList.add('spinning'); btn.disabled = true; }
			return Promise.resolve(f.apply(ctx, args.concat([ ev ]))).catch(function(err) {
				ui.addNotification(null, E('p', {}, [ String(err && err.message || err) ]), 'error');
			}).then(function() {
				if (btn) { btn.classList.remove('spinning'); btn.disabled = false; }
			});
		};
	},
	changes: { init: function() { updateIndicator(); } }
};

/* ------------------------------------------------------- rpc, poll, network */

var rpc = {
	declare: function(o) {
		if (o.object === 'uci' && o.method === 'revert')
			return function() { return uci.revert(); };
		if (o.object === 'service' && o.method === 'list')
			return function() {
				return T.running().then(function(running) {
					return { lobbyfence: { instances: running ? { instance1: { running: true } } : {} } };
				});
			};
		return function() { return Promise.reject(new Error('not available')); };
	}
};

var poll = {
	add: function(fn, interval) {
		var busy = false;
		window.setInterval(function() {
			if (busy || document.hidden) return;
			busy = true;
			Promise.resolve().then(fn).catch(function() {}).then(function() { busy = false; });
		}, (interval || 5) * 1000);
	}
};

var network = { getHostHints: function() { return Promise.resolve(null); } };

/* ------------------------------------------------------------------ view */

function applyChanges() {
	var msg = E('p', {}, [ _('Applying configuration changes…') ]);
	ui.showModal(_('Save & Apply'), [ msg ]);
	return uci.apply().then(function() {
		msg.textContent = _('Configuration changes applied.');
		updateIndicator();
		window.setTimeout(function() { window.location.reload(); }, 1500);
	}, function(err) {
		ui.hideModal();
		ui.addNotification(null, E('p', {}, [ _('Could not apply the changes: ') + (err && err.message || err) ]), 'error');
	});
}

var BaseView = {
	load: function() { return Promise.resolve(); },
	render: function() { return E('div'); },
	handleSave: function() { return uci.save(); },
	handleSaveApply: function() {
		return Promise.resolve(this.handleSave()).then(function() {
			if (!uci.staged) {
				ui.addNotification(null, E('p', {}, [ _('There are no changes to apply.') ]), 'info');
				return;
			}
			return applyChanges();
		}).catch(function(err) {
			ui.addNotification(null, E('p', {}, [ String(err && err.message || err) ]), 'error');
		});
	},
	handleReset: function() {
		return uci.revert().then(function() { window.location.reload(); });
	}
};

var view = {
	extend: function(proto) {
		var V = function() {};
		V.prototype = Object.assign(Object.create(BaseView), proto);
		return V;
	}
};

/* evaluate a LuCI view file (it ends in "return view.extend({...})") and show it */
function boot(url, container) {
	return window.fetch(url, { credentials: 'same-origin', cache: 'no-cache' }).then(function(r) {
		if (!r.ok) throw new Error('cannot load ' + url);
		return r.text();
	}).then(function(src) {
		var V = new Function('view', 'uci', 'fs', 'ui', 'rpc', 'poll', 'network', 'L', '_', 'E', src)(
			view, uci, fs, ui, rpc, poll, network, L, _, E);
		var v = new V();
		return Promise.resolve(v.load()).then(function(data) { return v.render(data); }).then(function(node) {
			container.innerHTML = '';
			container.appendChild(node);
			updateIndicator();
			return v;
		});
	});
}

window.E = E;
window._ = _;
window.L = L;
window.LF = { call: call, uci: uci, fs: fs, ui: ui, view: view, E: E, boot: boot, updateIndicator: updateIndicator,
	parseConfig: parseConfig, serializeConfig: serializeConfig, replay: replay };

})(window, document);
