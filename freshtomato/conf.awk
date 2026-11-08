# conf.awk - reads and writes LobbyFence's configuration file on FreshTomato
#
# The file uses OpenWrt's UCI syntax, so it looks and works the same on both:
#
#   config zone 'game'
#   	option label 'My game'
#   	list circle '50.11,8.68,800'
#
# Jobs (-v mode=...):
#   shell      -> shell assignments for functions.sh (CONFIG_SECTIONS, CONFIG_<s>_<o>)
#   normalize  -> the same configuration, cleanly re-written (invalid lines dropped)
#   edit       -> normalize with one change: -v op=set|add_list|del_list|delete|section
#                 -v sec=<section> [-v opt=<option>] [-v val=<value / section type>]
#   get        -> value of -v sec / -v opt (list items separated by spaces); exit 1 if unset
#   ops        -> normalize with the changes in -v opsfile=<file> replayed onto it, one per
#                 line, fields separated by tabs and %-encoded (%25 % , %09 tab, %0A ...):
#                   set <sec> <opt> <value>       list <sec> <opt> [<item> ...]
#                   unset <sec> <opt>             add <sec> <type>       remove <sec>
#
# Section and option names may only use letters, digits and "_"; values any
# printable text (control characters are dropped). Must work with BusyBox awk.
#
# SPDX-License-Identifier: GPL-3.0-or-later

function valid_name(s) { return s ~ /^[A-Za-z0-9_]+$/ && length(s) <= 64 }

# split a line into words: '...' and "..." quote (\ escapes in "..." and
# outside quotes), quoted parts glued to their neighbours form one word
function words(line,   n, i, c, w, inw, q) {
	n = 0; w = ""; inw = 0; q = ""
	for (i = 1; i <= length(line); i++) {
		c = substr(line, i, 1)
		if (q == "'") {
			if (c == "'") q = ""; else w = w c
			continue
		}
		if (q == "\"") {
			if (c == "\\" && i < length(line)) { i++; w = w substr(line, i, 1) }
			else if (c == "\"") q = ""
			else w = w c
			continue
		}
		if (c == " " || c == "\t") {
			if (inw) { W[++n] = w; w = ""; inw = 0 }
			continue
		}
		if (c == "#" && !inw) break
		inw = 1
		if (c == "'" || c == "\"") q = c
		else if (c == "\\" && i < length(line)) { i++; w = w substr(line, i, 1) }
		else w = w c
	}
	if (inw) W[++n] = w
	return n
}

function clean(v) {
	gsub(/[\001-\037\177]/, "", v)
	return v
}

function squote(v,   n, p, i, o) {
	n = split(v, p, "'")
	o = p[1]
	for (i = 2; i <= n; i++) o = o "'\\''" p[i]
	return "'" o "'"
}

# --------------------------------------------------------------- parsing

{
	sub(/\r$/, "")
	n = words($0)
	if (n == 0) next
	if (W[1] == "config" && n >= 2) {
		cur = ""
		if (!valid_name(W[2])) next
		name = (n >= 3) ? W[3] : sprintf("cfg%02x", nsec + 1)
		if (!valid_name(name)) next
		if (!(name in stype)) { sord[++nsec] = name; nopt[name] = 0 }
		stype[name] = W[2]
		cur = name
		next
	}
	if (cur == "" || n < 3 || !valid_name(W[2])) next
	if (W[1] == "option") {
		k = cur SUBSEP W[2]
		if (!(k in inord)) { oord[cur, ++nopt[cur]] = W[2]; inord[k] = 1 }
		kind[k] = "option"; oval[k] = clean(W[3]); cnt[k] = 1
	} else if (W[1] == "list") {
		k = cur SUBSEP W[2]
		if (!(k in kind) || kind[k] != "list") {
			if (!(k in inord)) { oord[cur, ++nopt[cur]] = W[2]; inord[k] = 1 }
			kind[k] = "list"; cnt[k] = 0
		}
		item[k, ++cnt[k]] = clean(W[3])
	}
}

# ---------------------------------------------------------------- output

function apply_edit(   k, i, j, vc) {
	if (!valid_name(sec)) return
	if (op == "section") {                       # "set cfg.name=type" creates a section
		if (!valid_name(val)) return
		if (!(sec in stype)) { sord[++nsec] = sec; nopt[sec] = 0 }
		stype[sec] = val
		return
	}
	if (!(sec in stype) || stype[sec] == "") return
	if (op == "delete" && opt == "") {
		stype[sec] = ""
		for (i = 1; i <= nopt[sec]; i++) kind[sec, oord[sec, i]] = "gone"
		return
	}
	if (!valid_name(opt)) return
	vc = clean(val)
	k = sec SUBSEP opt
	if (op == "set") {
		if (!(k in inord)) { oord[sec, ++nopt[sec]] = opt; inord[k] = 1 }
		kind[k] = "option"; oval[k] = vc; cnt[k] = 1
	} else if (op == "add_list") {
		if (!(k in kind) || kind[k] != "list") {
			if (!(k in inord)) { oord[sec, ++nopt[sec]] = opt; inord[k] = 1 }
			kind[k] = "list"; cnt[k] = 0
		}
		item[k, ++cnt[k]] = vc
	} else if (op == "del_list") {
		if (kind[k] != "list") return
		j = 0
		for (i = 1; i <= cnt[k]; i++)
			if (item[k, i] != vc) item[k, ++j] = item[k, i]
		cnt[k] = j
	} else if (op == "delete") {
		kind[k] = "gone"
	}
}

function emit_text(   s, i, o, k, j, first) {
	first = 1
	for (s = 1; s <= nsec; s++) {
		name = sord[s]
		if (stype[name] == "") continue
		if (!first) print ""
		first = 0
		print "config " stype[name] " " squote(name)
		for (i = 1; i <= nopt[name]; i++) {
			o = oord[name, i]; k = name SUBSEP o
			if (kind[k] == "option") print "\toption " o " " squote(oval[k])
			else if (kind[k] == "list") for (j = 1; j <= cnt[k]; j++) print "\tlist " o " " squote(item[k, j])
		}
	}
}

function emit_shell(   s, i, o, k, j, v, all, vars) {
	all = ""; vars = ""
	for (s = 1; s <= nsec; s++) {
		name = sord[s]
		if (stype[name] == "") continue
		all = all (all == "" ? "" : " ") name
		print "CONFIG_" name "_TYPE=" squote(stype[name])
		vars = vars " CONFIG_" name "_TYPE"
		for (i = 1; i <= nopt[name]; i++) {
			o = oord[name, i]; k = name SUBSEP o
			if (kind[k] == "option") v = oval[k]
			else if (kind[k] == "list") { v = ""; for (j = 1; j <= cnt[k]; j++) v = v (j > 1 ? " " : "") item[k, j] }
			else continue
			print "CONFIG_" name "_" o "=" squote(v)
			vars = vars " CONFIG_" name "_" o
		}
	}
	print "CONFIG_SECTIONS=" squote(all)
	print "CONFIG_VARS=" squote(vars)
}

function hexval(c) { return index("0123456789abcdef", tolower(c)) - 1 }

function pdecode(v,   o, i, c, h, l) {
	o = ""
	for (i = 1; i <= length(v); i++) {
		c = substr(v, i, 1)
		if (c == "%" && i + 2 <= length(v)) {
			h = hexval(substr(v, i + 1, 1)); l = hexval(substr(v, i + 2, 1))
			if (h >= 0 && l >= 0) { o = o sprintf("%c", h * 16 + l); i += 2; continue }
		}
		o = o c
	}
	return o
}

function apply_ops(file,   line, n, f, i) {
	while ((getline line < file) > 0) {
		sub(/\r$/, "", line)
		n = split(line, f, "\t")
		for (i = 1; i <= n; i++) f[i] = pdecode(f[i])
		op = ""; sec = f[2]; opt = ""; val = ""
		if (f[1] == "set" && n >= 4) { op = "set"; opt = f[3]; val = f[4]; apply_edit() }
		else if (f[1] == "unset" && n >= 3) { op = "delete"; opt = f[3]; if (opt != "") apply_edit() }
		else if (f[1] == "add" && n >= 3) { op = "section"; val = f[3]; apply_edit() }
		else if (f[1] == "remove" && n >= 2) { op = "delete"; apply_edit() }
		else if (f[1] == "list" && n >= 3) {
			opt = f[3]
			if (opt == "") continue
			op = "delete"; apply_edit()
			op = "add_list"
			for (i = 4; i <= n; i++) { val = f[i]; apply_edit() }
		}
	}
	close(file)
}

END {
	if (mode == "edit") { apply_edit(); emit_text() }
	else if (mode == "ops") { apply_ops(opsfile); emit_text() }
	else if (mode == "normalize") emit_text()
	else if (mode == "shell") emit_shell()
	else if (mode == "get") {
		k = sec SUBSEP opt
		if (!(sec in stype) || stype[sec] == "") exit 1
		if (opt == "") { print stype[sec]; exit 0 }
		if (kind[k] == "option") print oval[k]
		else if (kind[k] == "list") { v = ""; for (j = 1; j <= cnt[k]; j++) v = v (j > 1 ? " " : "") item[k, j]; print v }
		else exit 1
	}
}
