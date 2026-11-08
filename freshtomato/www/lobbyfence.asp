<!DOCTYPE html>
<!--
	LobbyFence for FreshTomato - the page in FreshTomato's own frame (menu,
	header). The map itself runs in a frame of its own (lobbyfence/app.asp):
	it needs a clean page, without tomato.js changing JavaScript's arrays.
	SPDX-License-Identifier: GPL-3.0-or-later
-->
<html lang="en-GB">
<head>
<meta http-equiv="content-type" content="text/html;charset=utf-8">
<meta name="robots" content="noindex,nofollow">
<base href="/">
<title>[<% ident(); %>] LobbyFence</title>
<link rel="stylesheet" type="text/css" href="tomato.css?rel=<% version(); %>">
<% css(); %>
<script src="tomato.js?rel=<% version(); %>"></script>
<script>

//	<% nvram(''); %>

function lfFit() {
	var f = document.getElementById('lf-frame');
	if (!f) return;
	var top = f.getBoundingClientRect().top + (window.pageYOffset || 0);
	f.style.height = Math.max(560, window.innerHeight - top - 16) + 'px';
}
/* phones: offer the map's own phone layout (no router menu around it) */
function lfPhone() {
	var phone = false;
	try { phone = window.matchMedia('(pointer: coarse)').matches && Math.min(screen.width, screen.height) < 820; } catch (e) {}
	if (phone) document.getElementById('lf-phone').style.display = 'block';
}
function init() {
	if (typeof eventHandler === 'function') eventHandler();
	lfPhone();
	lfFit();
	window.addEventListener('resize', lfFit);
}
</script>
<style>
	#lf-frame { display: block; width: 100%; min-height: 560px; border: 0; background: transparent; }
	#lf-open { float: right; margin-left: 14px; font-size: 90%; }
	#lf-phone { display: none; margin: 6px 0 8px; padding: 12px; border-radius: 6px; background: #f0b400; color: #000;
		font-size: 120%; text-align: center; font-weight: bold; text-decoration: none; }
</style>
</head>

<body onload="init()">
<table id="container">
<tr><td colspan="2" id="header">
	<div class="title"><a href="/">FreshTomato</a></div>
	<div class="version">Version <% version(); %> on <% nv("t_model_name"); %></div>
</td></tr>
<tr id="body"><td id="navi"><script>navi()</script></td>
<td id="content">
<div id="ident"><% ident(); %> | LobbyFence <a id="lf-open" href="ext/lobbyfence/app.asp" target="_blank">open full window &#x2197;</a></div>
<a id="lf-phone" href="ext/lobbyfence/app.asp">On a phone? Open LobbyFence in phone layout &#x2197;</a>
<iframe id="lf-frame" src="ext/lobbyfence/app.asp?v=@LFVER@" title="LobbyFence" allow="fullscreen; clipboard-write" allowfullscreen></iframe>
</td></tr>
</table>
</body>
</html>
