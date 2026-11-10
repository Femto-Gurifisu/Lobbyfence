/*
 * LobbyFence as a home-screen app (Asuswrt-Merlin, FreshTomato, DD-WRT and
 * OpenWrt): the map page is the app (manifest + icons next to this file). On a phone opened in
 * the browser, a one-line tip says how to add it to the home screen (with an
 * Install button where the browser offers one); opened from the home screen,
 * or anywhere outside the router's own page (a full window, the phone layout,
 * DD-WRT's page on its own port) a "Router" link leads to the router's pages.
 * SPDX-License-Identifier: GPL-3.0-or-later
 */
(function() {
	'use strict';
	var KEY = 'lobbyfence.installTip';

	function standalone() {
		try {
			if (window.matchMedia('(display-mode: standalone)').matches || window.matchMedia('(display-mode: fullscreen)').matches)
				return true;
		} catch (e) {}
		return window.navigator.standalone === true;    /* iPhone / iPad home-screen apps */
	}
	function phone() {
		try { return window.matchMedia('(pointer: coarse)').matches && Math.min(screen.width, screen.height) < 820; } catch (e) { return false; }
	}
	function embedded() {
		try { return window.self !== window.top; } catch (e) { return true; }
	}
	function ios() {
		var ua = navigator.userAgent || '';
		return /iPhone|iPad|iPod/.test(ua) || (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1);
	}
	function get(k) { try { return window.localStorage.getItem(k); } catch (e) { return null; } }
	function set(k, v) { try { window.localStorage.setItem(k, v); } catch (e) {} }

	var css = document.createElement('style');
	css.textContent =
		'#lf-install{display:flex;align-items:center;gap:8px;margin:8px 12px 0;padding:8px 10px;border-radius:8px;' +
		'background:var(--lft-card,#fff);border:1px solid var(--lft-border,#d5dbe3);border-left:4px solid var(--lft-accent,#1f6fd1);font-size:13px}' +
		'#lf-install img{width:28px;height:28px;border-radius:7px;flex:none}' +
		'#lf-install span{flex:1}' +
		'#lf-install button{font:inherit;font-size:13px;border-radius:6px;padding:5px 10px;cursor:pointer;border:1px solid var(--lft-border,#d5dbe3);' +
		'background:var(--lft-card,#fff);color:inherit}' +
		'#lf-install button.lf-go{background:var(--lft-accent,#1f6fd1);border-color:var(--lft-accent,#1f6fd1);color:var(--lft-accent-text,#fff)}' +
		'#lf-install button.lf-x{border:0;background:none;font-size:18px;padding:0 4px;color:var(--lft-muted,#6b7785)}' +
		'#lf-install{cursor:pointer}' +
		'#lf-guide{position:fixed;inset:0;z-index:4000;background:rgba(0,0,0,.55);display:flex;align-items:center;justify-content:center;padding:16px;box-sizing:border-box}' +
		'#lf-guide .lf-gbox{background:var(--lft-card,#fff);color:var(--lft-text,#1f2933);border-radius:12px;padding:16px 18px;width:100%;max-width:420px;' +
		'max-height:calc(100% - 140px);overflow:auto;box-shadow:0 10px 40px rgba(0,0,0,.35);font-size:15px;line-height:1.45}' +
		'#lf-guide .lf-ghead{display:flex;align-items:center;gap:10px;font-size:16px}' +
		'#lf-guide .lf-ghead img{width:40px;height:40px;border-radius:10px}' +
		'#lf-guide .lf-gsub{margin:10px 0 4px;color:var(--lft-muted,#6b7785);font-size:13px}' +
		'#lf-guide ol{margin:6px 0 10px;padding-left:22px}#lf-guide li{margin:6px 0}' +
		'#lf-guide .lf-gmore{font-size:13px;color:var(--lft-muted,#6b7785);margin:6px 0 10px}#lf-guide .lf-gmore p{margin:4px 0}' +
		'#lf-guide .lf-gok{display:block;width:100%;font:inherit;font-weight:600;padding:9px;border-radius:8px;cursor:pointer;' +
		'border:1px solid var(--lft-accent,#1f6fd1);background:var(--lft-accent,#1f6fd1);color:var(--lft-accent-text,#fff)}' +
		'#lf-guide .lf-garrow{position:fixed;display:flex;flex-direction:column;align-items:center;gap:4px;color:#fff;font-size:13px;font-weight:600;' +
		'text-shadow:0 1px 3px rgba(0,0,0,.8);pointer-events:none;animation:lf-bob 1s ease-in-out infinite alternate}' +
		'#lf-guide .lf-garrow::after{content:"";width:0;height:0;border-left:16px solid transparent;border-right:16px solid transparent}' +
		'#lf-guide .lf-g-top-right{top:6px;right:6px;flex-direction:column-reverse;align-items:flex-end}' +
		'#lf-guide .lf-g-top-right::after,#lf-guide .lf-g-bottom-right::after{margin-right:6px}' +
		'#lf-guide .lf-g-top-right::after{border-bottom:24px solid #fff}' +
		'#lf-guide .lf-g-bottom-right{bottom:6px;right:6px;align-items:flex-end}' +
		'#lf-guide .lf-g-bottom-center{bottom:6px;left:50%;margin-left:-100px;width:200px;text-align:center}' +
		'#lf-guide .lf-g-bottom-right::after,#lf-guide .lf-g-bottom-center::after{border-top:24px solid #fff}' +
		'@keyframes lf-bob{from{transform:translateY(0)}to{transform:translateY(6px)}}' +
		'@media (prefers-reduced-motion:reduce){#lf-guide .lf-garrow{animation:none}}' +
		'#lf-router{font-size:13px;color:var(--lft-muted,#6b7785);text-decoration:none;padding:6px 8px}' +
		'html.lf-standalone body{padding-bottom:env(safe-area-inset-bottom)}' +
		/* OpenWrt, opened as LobbyFence's app: LobbyFence without LuCI's own menus
		   (Bootstrap, OpenWrt 2020, Material, Footstrap) */
		'html.lf-appmode body>header,html.lf-appmode #mainmenu,html.lf-appmode .main-left,html.lf-appmode footer,' +
		'html.lf-appmode .fs-sidebar,html.lf-appmode .fs-footer{display:none!important}' +
		'html.lf-appmode .main-right{margin-left:0!important;width:auto!important}' +
		'#lf-router.lf-router-luci{display:inline-block;padding:8px 0 0}';
	document.head.appendChild(css);

	var me = document.currentScript && document.currentScript.src || '';
	var dir = me.replace(/[^\/]*$/, '');
	var deferred = null, tip = null;

	/* OpenWrt: the map and zones pages are LuCI's pages. While one of them is
	   open, its name and icons are LobbyFence's (some themes - Footstrap - make
	   all of LuCI an app with their own; those are put back on the way out:
	   Footstrap changes pages without reloading). Opened from LobbyFence's own
	   home-screen icon (its manifest starts it with ?lf=app), LuCI's menus are
	   hidden - but not in a theme's LuCI app. */
	var luci = !window.LF_PLATFORM && !!(window.L && window.L.env && document.getElementById('maincontent'));
	var OURS = /\/admin\/services\/lobbyfence(\/|$)/;
	var theirs = null, mine = [], appMode = false;
	function add(tag, attrs) {
		var n = document.createElement(tag);
		Object.keys(attrs).forEach(function(k) { n.setAttribute(k, attrs[k]); });
		document.head.appendChild(n);
		mine.push(n);
	}
	function sessionGet(k) { try { return window.sessionStorage.getItem(k); } catch (e) { return null; } }
	function sessionSet(k) { try { window.sessionStorage.setItem(k, '1'); } catch (e) {} }
	function routerLink(on) {
		var r = document.getElementById('lf-router'), mc = document.getElementById('maincontent');
		if (!on) { if (r) r.parentNode.removeChild(r); return; }
		if (r || !mc) return;
		r = document.createElement('a');
		r.id = 'lf-router'; r.className = 'lf-router-luci';
		r.href = (window.L.env.scriptname || '/cgi-bin/luci') + '/'; r.textContent = 'Router ↗';
		r.title = 'All of the router\'s settings (LuCI)';
		mc.insertBefore(r, mc.firstChild);
	}
	function luciPage() {
		var on = OURS.test(location.pathname), root = document.documentElement;
		if (on && !theirs) {
			theirs = [];
			Array.prototype.forEach.call(document.head.querySelectorAll('link[rel=manifest],link[rel~=icon],link[rel=apple-touch-icon],' +
				'meta[name=apple-mobile-web-app-title]'), function(n) { theirs.push(n); n.parentNode.removeChild(n); });
			add('link', { 'rel': 'manifest', 'href': dir + 'manifest.json' });
			add('link', { 'rel': 'icon', 'type': 'image/png', 'sizes': '32x32', 'href': dir + 'favicon-32.png' });
			add('link', { 'rel': 'apple-touch-icon', 'href': dir + 'apple-touch-icon.png' });
			add('meta', { 'name': 'apple-mobile-web-app-title', 'content': 'LobbyFence' });
			if (!document.head.querySelector('meta[name=apple-mobile-web-app-capable]')) {
				add('meta', { 'name': 'mobile-web-app-capable', 'content': 'yes' });
				add('meta', { 'name': 'apple-mobile-web-app-capable', 'content': 'yes' });
			}
		}
		else if (!on && theirs) {
			mine.forEach(function(n) { if (n.parentNode) n.parentNode.removeChild(n); });
			theirs.forEach(function(n) { document.head.appendChild(n); });
			mine = []; theirs = null;
			if (document.title === 'LobbyFence') document.title = (window.L.env.hostname || 'OpenWrt');
			if (tip && tip.parentNode) tip.parentNode.removeChild(tip);
		}
		if (on && (phone() || appMode)) document.title = 'LobbyFence';
		root.classList.toggle('lf-appmode', on && appMode);
		routerLink(on && appMode);
	}
	if (luci) {
		document.documentElement.classList.add('lf-luci');
		appMode = standalone() && (/[?&]lf=app(&|$)/.test(location.search) || sessionGet('lobbyfence.app') === '1');
		if (appMode) sessionSet('lobbyfence.app');
		luciPage();
		/* pages changed without reloading (Footstrap): follow them */
		[ 'pushState', 'replaceState' ].forEach(function(m) {
			var orig = history[m];
			if (typeof orig !== 'function') return;
			history[m] = function() { var r = orig.apply(this, arguments); setTimeout(luciPage, 0); return r; };
		});
		window.addEventListener('popstate', function() { setTimeout(luciPage, 0); });
	}

	/* Chrome / Brave / Edge on Android offer their own install prompt (only on HTTPS pages) */
	window.addEventListener('beforeinstallprompt', function(ev) {
		ev.preventDefault();
		deferred = ev;
		if (tip) showTip();
	});
	window.addEventListener('appinstalled', function() { set(KEY, 'installed'); if (tip) tip.remove(); });

	/* which browser, for the guide: name, the steps, and where its menu usually is */
	function browser() {
		var ua = navigator.userAgent || '';
		if (ios()) {
			if (/CriOS/.test(ua)) return { name: 'Chrome', arrow: 'top-right', steps: [
				'Tap the Share button ⬆ in the address bar (top right).',
				'Tap “Add to Home Screen”.', 'Tap “Add”.' ] };
			if (/FxiOS|EdgiOS|OPiOS/.test(ua)) return { name: 'your browser', arrow: null, steps: [
				'Open the browser’s menu and tap “Share”.',
				'Scroll down and tap “Add to Home Screen”.', 'Tap “Add”.' ] };
			return { name: 'Safari', arrow: 'bottom-center', steps: [
				'Tap Share ⬆ at the bottom of the screen (on newer iPhones tap ⋯ first, then Share; in Brave tap ⋯, then Share).',
				'Scroll down and tap “Add to Home Screen”.',
				'Leave “Open as Web App” on if it’s there, then tap “Add”.' ] };
		}
		if (navigator.brave) return { name: 'Brave', chromium: 'brave', arrow: 'bottom-right', steps: [
			'Tap Brave’s menu ⋮ – bottom right (top right if your address bar is at the top).',
			'Tap “Add to Home screen”.', 'Tap “Add”, then “Add” (or “Add automatically”) again.' ] };
		if (/SamsungBrowser/.test(ua)) return { name: 'Samsung Internet', arrow: 'bottom-right', steps: [
			'Tap the menu ☰ at the bottom right.', 'Tap “Add page to”, then “Home screen”.', 'Tap “Add”.' ] };
		if (/EdgA/.test(ua)) return { name: 'Edge', chromium: 'edge', arrow: 'bottom-center', steps: [
			'Tap the menu ⋯ at the bottom.', 'Tap “Add to phone”, then “Add to Home screen”.', 'Tap “Add”.' ] };
		if (/Firefox/.test(ua)) return { name: 'Firefox', arrow: null, steps: [
			'Tap Firefox’s menu ⋮ (top or bottom right).', 'Tap “Add to Home screen” (“Add app to Home screen”).', 'Tap “Add”.' ] };
		if (/Chrome/.test(ua)) return { name: 'Chrome', chromium: 'chrome', arrow: 'top-right', steps: [
			'Tap Chrome’s menu ⋮ at the top right.', 'Tap “Add to Home screen”.', 'Tap “Add” (or “Create shortcut”), then “Add”.' ] };
		return { name: 'your browser', arrow: null, steps: [
			'Open the browser’s menu.', 'Tap “Add to Home screen”.', 'Tap “Add”.' ] };
	}

	function el(tag, cls, text) {
		var e = document.createElement(tag);
		if (cls) e.className = cls;
		if (text != null) e.textContent = text;
		return e;
	}

	/* the browser's own install dialog where it has one, the guide otherwise */
	function install() {
		if (deferred) {
			var d = deferred; deferred = null;
			d.prompt();
			Promise.resolve(d.userChoice).then(function(c) {
				if (c && c.outcome === 'accepted') { set(KEY, 'installed'); if (tip) tip.remove(); }
				else if (tip) showTip();
			});
			return;
		}
		guide();
	}

	/* a web page can't open the browser's menu itself: show where to tap */
	function guide() {
		var b = browser(), old = document.getElementById('lf-guide');
		if (old) old.remove();
		var g = el('div'); g.id = 'lf-guide';
		g.setAttribute('role', 'dialog'); g.setAttribute('aria-label', 'Add LobbyFence to the home screen');
		var box = el('div', 'lf-gbox');
		var head = el('div', 'lf-ghead');
		var img = el('img'); img.src = dir + 'icon-192.png'; img.alt = '';
		head.appendChild(img);
		head.appendChild(el('strong', null, 'Add LobbyFence to your home screen'));
		box.appendChild(head);
		box.appendChild(el('p', 'lf-gsub', 'Browsers don’t let a page add itself – three taps in ' + b.name + ':'));
		var ol = el('ol');
		b.steps.forEach(function(t) { ol.appendChild(el('li', null, t)); });
		box.appendChild(ol);
		if (b.chromium) {
			/* Chromium installs pages as apps only from secure addresses; for the router's
			   own plain-http address that can be allowed in the browser's settings */
			var more = el('details', 'lf-gmore');
			more.appendChild(el('summary', null, 'Want it to open as its own app, without the address bar?'));
			var host = location.protocol + '//' + location.host;
			[ 'Open ' + b.chromium + '://flags in the address bar.',
			  'Search for “Insecure origins treated as secure”.',
			  'Type ' + host + ' into its box, set it to “Enabled” and tap “Relaunch”.',
			  'Come back here: this tip then has an “Install” button that does it in one tap.' ].forEach(function(t, i) {
				more.appendChild(el('p', null, (i + 1) + '. ' + t));
			});
			box.appendChild(more);
		}
		var ok = el('button', 'lf-gok', 'Got it'); ok.type = 'button';
		ok.addEventListener('click', function() { g.remove(); });
		box.appendChild(ok);
		g.appendChild(box);
		if (b.arrow) {
			var ar = el('div', 'lf-garrow lf-g-' + b.arrow);
			ar.appendChild(el('span', null, b.arrow === 'bottom-center' ? 'Share / menu is down here' : 'The menu is usually here'));
			g.appendChild(ar);
		}
		g.addEventListener('click', function(ev) { if (ev.target === g) g.remove(); });
		document.body.appendChild(g);
	}

	function showTip() {
		var old = document.getElementById('lf-install');
		if (old) old.remove();
		tip = el('div'); tip.id = 'lf-install';
		tip.setAttribute('role', 'button'); tip.tabIndex = 0;
		var img = el('img'); img.src = dir + 'icon-192.png'; img.alt = '';
		tip.appendChild(img);
		tip.appendChild(el('span', null, deferred ? 'Install LobbyFence as an app on this phone.'
			: 'Add LobbyFence to your home screen – tap here to see how.'));
		var go = el('button', 'lf-go', deferred ? 'Install' : 'Show me'); go.type = 'button';
		tip.appendChild(go);
		var x = el('button', 'lf-x', '×'); x.type = 'button';
		x.title = 'Don\'t show this again'; x.setAttribute('aria-label', 'Close');
		x.addEventListener('click', function(ev) { ev.stopPropagation(); set(KEY, 'closed'); tip.remove(); });
		tip.appendChild(x);
		tip.addEventListener('click', install);
		tip.addEventListener('keydown', function(ev) { if (ev.key === 'Enter' || ev.key === ' ') { ev.preventDefault(); install(); } });
		/* above the tabs; on OpenWrt (inside LuCI's page) above the map page */
		var top = document.getElementById('lf-top') || document.getElementById('view');
		if (top && top.parentNode) top.parentNode.insertBefore(tip, top);
		else document.body.insertBefore(tip, document.body.firstChild);
	}

	function start() {
		var app = standalone(), top = document.getElementById('lf-top');
		if (app)
			document.documentElement.classList.add('lf-standalone');
		/* a way to the router's own pages whenever the page is not inside them: the
		   app (no address bar), FreshTomato's / Merlin's "open full window" and phone
		   layout, and DD-WRT's page on a port of its own - not in the frame of the
		   router's page, under its menu (LuCI: luciPage) */
		if ((app || (window.LF_PLATFORM && !embedded())) && top && !document.getElementById('lf-router')) {
			var a = document.createElement('a');
			a.id = 'lf-router'; a.href = window.LF_ROUTER_URL || '/'; a.textContent = 'Router ↗';
			a.title = 'The router\'s own pages';
			top.appendChild(a);
		}
		if (app)
			return;
		/* only in the phone layout (the page on its own) - not inside the
		   router's page, where it runs in a frame */
		if (phone() && !embedded() && !get(KEY))
			showTip();
	}
	if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
	else start();
})();
