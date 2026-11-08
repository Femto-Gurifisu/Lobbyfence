<!DOCTYPE html PUBLIC "-//W3C//DTD XHTML 1.0 Transitional//EN" "http://www.w3.org/TR/xhtml1/DTD/xhtml1-transitional.dtd">
<!--
	LobbyFence for Asuswrt-Merlin - the add-on page in the router's own frame
	(menu, header; mounted as /userN.asp, a tab under Administration). The map
	runs in a frame of its own (/user/lobbyfence/app.asp).
	SPDX-License-Identifier: GPL-3.0-or-later
-->
<html xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta http-equiv="X-UA-Compatible" content="IE=Edge"/>
<meta http-equiv="Content-Type" content="text/html; charset=utf-8"/>
<meta http-equiv="Pragma" content="no-cache"/>
<meta http-equiv="Expires" content="-1"/>
<link rel="shortcut icon" href="images/favicon.png"/>
<link rel="icon" href="images/favicon.png"/>
<title>LobbyFence</title>
<link rel="stylesheet" type="text/css" href="index_style.css"/>
<link rel="stylesheet" type="text/css" href="form_style.css"/>
<script language="JavaScript" type="text/javascript" src="/state.js"></script>
<script language="JavaScript" type="text/javascript" src="/general.js"></script>
<script language="JavaScript" type="text/javascript" src="/popup.js"></script>
<script language="JavaScript" type="text/javascript" src="/help.js"></script>
<script type="text/javascript" language="JavaScript" src="/validator.js"></script>
<style>
	#lf-frame { display: block; width: 100%; height: 900px; border: 0; background: #fff; border-radius: 4px; }
	#lf-open { float: right; font-size: 12px; color: #FFCC00; }
	#lf-phone { display: none; margin: 8px 0 10px; padding: 14px; border-radius: 6px; background: #FFCC00; color: #000;
		font-size: 28px; line-height: 1.3; text-align: center; font-weight: bold; text-decoration: none; }
</style>
<script>
function SetCurrentPage() {
	document.form.next_page.value = window.location.pathname.substring(1);
	document.form.current_page.value = window.location.pathname.substring(1);
}
/* the frame as tall as the window below it (the map's page scrolls inside it) */
function lfFit() {
	var f = document.getElementById('lf-frame');
	if (!f) return;
	var top = f.getBoundingClientRect().top + (window.pageYOffset || 0);
	f.style.height = Math.min(1200, Math.max(560, window.innerHeight - top - 16)) + 'px';
}
/* phones: ASUS's pages are desktop-sized - offer the map's own phone layout */
function lfPhone() {
	var phone = false;
	try { phone = window.matchMedia('(pointer: coarse)').matches && Math.min(screen.width, screen.height) < 820; } catch (e) {}
	if (phone) document.getElementById('lf-phone').style.display = 'block';
}
function initial() {
	SetCurrentPage();
	show_menu();
	lfPhone();
	lfFit();
	window.addEventListener('resize', lfFit);
}
</script>
</head>
<body onload="initial();" class="bg">
<div id="TopBanner"></div>
<div id="Loading" class="popup_bg"></div>
<iframe name="hidden_frame" id="hidden_frame" src="" width="0" height="0" frameborder="0"></iframe>
<form method="post" name="form" action="start_apply.htm" target="hidden_frame">
<input type="hidden" name="current_page" value=""/>
<input type="hidden" name="next_page" value=""/>
<input type="hidden" name="group_id" value=""/>
<input type="hidden" name="modified" value="0"/>
<input type="hidden" name="action_mode" value="apply"/>
<input type="hidden" name="action_wait" value="5"/>
<input type="hidden" name="first_time" value=""/>
<input type="hidden" name="action_script" value=""/>
<input type="hidden" name="preferred_lang" id="preferred_lang" value="<% nvram_get("preferred_lang"); %>"/>
<input type="hidden" name="firmver" value="<% nvram_get("firmver"); %>"/>
<table class="content" align="center" cellpadding="0" cellspacing="0">
<tr>
<td width="17">&nbsp;</td>
<td valign="top" width="202">
<div id="mainMenu"></div>
<div id="subMenu"></div>
</td>
<td valign="top">
<div id="tabMenu" class="submenuBlock"></div>
<table width="98%" border="0" align="left" cellpadding="0" cellspacing="0">
<tr>
<td align="left" valign="top">
<table width="760px" border="0" cellpadding="5" cellspacing="0" bordercolor="#6b8fa3" class="FormTitle" id="FormTitle">
<tr>
<td bgcolor="#4D595D" colspan="3" valign="top">
<div>&nbsp;</div>
<div class="formfonttitle">LobbyFence <a id="lf-open" href="/user/lobbyfence/app.asp" target="_blank">open full window &#x2197;</a></div>
<div style="margin:10px 0 10px 5px;" class="splitLine"></div>
<div class="formfontdesc">Game servers by region: which servers your games may use, on a map. Changes take effect with <b>Save &amp; Apply</b> inside the page.</div>
<a id="lf-phone" href="/user/lobbyfence/app.asp">On a phone? Open LobbyFence in phone layout &#x2197;</a>
<iframe id="lf-frame" src="/user/lobbyfence/app.asp?v=@LFVER@" title="LobbyFence" allow="fullscreen; clipboard-write" allowfullscreen="true"></iframe>
</td>
</tr>
</table>
</td>
</tr>
</table>
</td>
<td width="10" align="center" valign="top">&nbsp;</td>
</tr>
</table>
</form>
<div id="footer"></div>
</body>
</html>
