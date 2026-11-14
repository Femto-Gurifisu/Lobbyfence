# lobbyfence.awk - helper routines for LobbyFence
#
# One file, many small jobs. The job is picked with -v op=<name>:
#
#   addrs     tokens -> "4 <addr>" / "6 <addr>" / "mac <mac>" / "bad <token>"
#             (CIDR allowed; MACs normalised to lower case with colons)
#   neigh     "mac ip" lines -> addresses of the MACs in -v macs
#   public    tokens -> public unicast host addresses only
#   harvest   `nft list set` output -> public addresses found in it
#   merge     <zone list> <harvested>   -> updated zone list   (-v now, expire, zmax, statf)
#   pending   <geo cache> <all zone ips> -> addresses still to locate (-v now, retry)
#   geojson   addresses -> JSON array for a batch lookup
#   georesp   batch lookup response -> geo cache lines            (-v now)
#   classify  <geo cache> <zone list> -> "ip state lat lon cc lastseen"
#                                       (-v circles, polygons, countries)
#   elements  classify output -> nft commands refreshing in/out sets (-v t, p)
#   prune     <all zone ips> <geo cache> -> de-duplicated, referenced cache
#   expires   `nft list set` output -> longest remaining timeout in seconds
#   devices   "ip <mac> <addr>" / "lease <mac> <addr> <host>" -> JSON device list
#   ages      `nft list set` output -> "<addr> <seconds since last update> <packets>" (-v window)
#   export    <geo cache> <names> <"game addr lastseen"> <imported locations> -> shared server file
#   shared_in      a shared server file -> imported-location lines (-v now, maxn, statf)
#   shared_merge   <imported locations> <new lines> -> merged, one per game and address (-v statf)
#   shared_hit     <addresses> <known locations...> -> geo cache lines for those found (the first file with one wins)
#   ct_ports       /proc/net/nf_conntrack -> "<proto>/<server port> <servers> <packets> <in the zone's ports 1|0>"
#   ports_merge    tally + ct_ports of this pass -> tally "<proto>/<port> <servers> <packets> <first> <last> <passes>" (-v now)
#   ports_show     tally -> tally lines + " <in the zone's ports 1|0>" (-v lp rp pp)
#   clean_ips, clean_cache, clean_ports
#                  saved zone list / geo cache / ports tally -> damaged lines left out (-v now, statf)
#   maskmac        debug report -> MAC addresses partly hidden, cut at -v max bytes
#
#   FreshTomato, DD-WRT, Asuswrt-Merlin (iptables + ipset):
#   ipset_members  `ipset list` -> public addresses in the sets
#   ipset_ages     `ipset list` -> "<addr> <seconds since last update> <packets>" (-v window, pk)
#   ipset_expires  `ipset list` -> longest remaining timeout in seconds
#   ipset_headers  `ipset list -t` -> "<name> <family> <maxelem> <timeout>"
#   ipset_load     classify output -> `ipset restore` commands for the in/out sets (-v p, v6)
#   ct_packets     /proc/net/nf_conntrack -> "<server> <packets from the device>" (-v devs)
#   ipt_counts     `iptables -L -v -x -n` -> "z_<zone>_match|hit|opened <packets>"
#
# Must stay compatible with BusyBox awk (no gawk extensions, no regex
# interval expressions).
#
# SPDX-License-Identifier: GPL-3.0-or-later

function is_num(s) { return s ~ /^-?[0-9]+(\.[0-9]+)?$/ }

# (a leading 0 is refused: C libraries and the firewall tools read it
# differently - octal or not at all)
function is_v4(s,   p, n, i) {
	n = split(s, p, ".")
	if (n != 4) return 0
	for (i = 1; i <= 4; i++)
		if (p[i] !~ /^[0-9]+$/ || length(p[i]) > 3 || p[i] + 0 > 255 || (length(p[i]) > 1 && substr(p[i], 1, 1) == "0")) return 0
	return 1
}

# eight groups of 1-4 hex digits, "::" once for a run of zero groups, an
# IPv4 address as the last two
function is_v6(s,   t, n, parts, i, np, groups) {
	if (index(s, ":") == 0) return 0
	if (s !~ /^[0-9A-Fa-f:.]+$/) return 0
	if (length(s) > 45) return 0
	if (index(s, ":::")) return 0
	if (s ~ /^:[^:]/ || s ~ /[^:]:$/) return 0
	t = s
	n = gsub(/::/, "", t)
	if (n > 1) return 0
	np = split(s, parts, ":")
	groups = 0
	for (i = 1; i <= np; i++) {
		if (parts[i] == "") continue
		if (i == np && index(parts[i], ".")) {
			if (!is_v4(parts[i])) return 0
			groups += 2
			continue
		}
		if (parts[i] !~ /^[0-9A-Fa-f]+$/ || length(parts[i]) > 4) return 0
		groups++
	}
	return n ? groups <= 7 : groups == 8
}

# "4", "6" or "" for an address with an optional /prefix (1-32 / 1-128:
# a /0 - every address - isn't something to allow or block one by one)
function fam(s,   a, n) {
	n = split(s, a, "/")
	if (n > 2) return ""
	if (n == 2 && (a[2] !~ /^[0-9]+$/ || length(a[2]) > 3 || a[2] + 0 < 1)) return ""
	if (is_v4(a[1])) { if (n == 2 && a[2] + 0 > 32) return ""; return "4" }
	if (is_v6(a[1])) { if (n == 2 && a[2] + 0 > 128) return ""; return "6" }
	return ""
}

# an address typed by someone: "192.168.1.05/024" -> "192.168.1.5/24"
# (leading zeros dropped; anything else as it is)
function norm_addr(s,   a, n, p, i, o) {
	n = split(s, a, "/")
	if (n > 2 || split(a[1], p, ".") != 4) return s
	for (i = 1; i <= 4; i++) if (p[i] !~ /^[0-9]+$/ || length(p[i]) > 3) return s
	o = (p[1] + 0) "." (p[2] + 0) "." (p[3] + 0) "." (p[4] + 0)
	if (n == 2) { if (a[2] !~ /^[0-9]+$/ || length(a[2]) > 3) return s; o = o "/" (a[2] + 0) }
	return o
}

function hex2num(h,   i, c, v) {
	v = 0
	h = tolower(h)
	if (h == "") return 0
	for (i = 1; i <= length(h); i++) {
		c = index("0123456789abcdef", substr(h, i, 1))
		if (c == 0) return -1
		v = v * 16 + c - 1
	}
	return v
}

# Keep in sync with the priv4/priv6 sets emitted by /usr/sbin/lobbyfence.
function is_private(ip,   p, a, b, c, v) {
	if (is_v4(ip)) {
		split(ip, p, ".")
		a = p[1] + 0; b = p[2] + 0; c = p[3] + 0
		if (a == 0 || a == 10 || a == 127 || a >= 224) return 1
		if (a == 100 && b >= 64 && b <= 127) return 1
		if (a == 169 && b == 254) return 1
		if (a == 172 && b >= 16 && b <= 31) return 1
		if (a == 192 && b == 168) return 1
		if (a == 192 && b == 0 && (c == 0 || c == 2)) return 1
		if (a == 198 && (b == 18 || b == 19)) return 1
		if (a == 198 && b == 51 && c == 100) return 1
		if (a == 203 && b == 0 && c == 113) return 1
		return 0
	}
	if (is_v6(ip)) {
		ip = tolower(ip)
		if (substr(ip, 1, 2) == "::") return 1          # ::, ::1, ::ffff:a.b.c.d
		split(ip, p, ":")
		v = hex2num(p[1])
		if (v < 0) return 1
		if (v >= 64512 && v <= 65023) return 1          # fc00::/7
		if (v >= 65152 && v <= 65215) return 1          # fe80::/10
		if (v >= 65280) return 1                        # ff00::/8
		if (v == 8193 && hex2num(p[2]) == 3512) return 1 # 2001:db8::/32
		return 0
	}
	return 1
}

function is_mac(s,   h) {
	h = "[0-9A-Fa-f][0-9A-Fa-f]"
	return s ~ ("^" h "[:-]" h "[:-]" h "[:-]" h "[:-]" h "[:-]" h "$")
}

function norm_mac(s) {
	s = tolower(s)
	gsub(/-/, ":", s)
	return s
}

function is_public_host(s) {
	return index(s, "/") == 0 && fam(s) != "" && !is_private(s)
}

function rad(d) { return d * 0.017453292519943295 }

# great-circle distance in km (haversine)
function dist_km(la1, lo1, la2, lo2,   dla, dlo, a) {
	dla = rad(la2 - la1)
	dlo = rad(lo2 - lo1)
	a = sin(dla / 2) * sin(dla / 2) + cos(rad(la1)) * cos(rad(la2)) * sin(dlo / 2) * sin(dlo / 2)
	if (a > 1) a = 1
	return 6371.0088 * 2 * atan2(sqrt(a), sqrt(1 - a))
}

# Web-Mercator y for a latitude: polygons are drawn on a Mercator map, so
# "inside" is decided in that plane - exactly what the user sees.
function merc_y(la) {
	if (la > 85.05) la = 85.05
	if (la < -85.05) la = -85.05
	la = rad(la)
	return log((1 + sin(la)) / cos(la))
}

# polygons: items separated by blanks, each "lat,lon;lat,lon;..." (>= 3 points)
function wrap_lon(lo) {
	while (lo > 180) lo -= 360
	while (lo < -180) lo += 360
	return lo
}

# Longitudes are made continuous (first corner within +-180, each next one
# within 180 degrees of the previous) so a polygon may cross the antimeridian.
# The map page does exactly the same.
function parse_polygons(   t, v, q, n, m, i, j, k, lo, prev, la) {
	np = 0
	n = split(polygons, t, /[ \t]+/)
	for (i = 1; i <= n; i++) {
		if (t[i] == "") continue
		m = split(t[i], v, ";")
		if (m < 3) continue
		k = 0
		for (j = 1; j <= m; j++) {
			if (split(v[j], q, ",") != 2 || !is_num(q[1]) || !is_num(q[2])) { k = -1; break }
			if (q[1] + 0 < -90 || q[1] + 0 > 90 || q[2] + 0 < -540 || q[2] + 0 > 540) { k = -1; break }
			lo = q[2] + 0
			if (k == 0) lo = wrap_lon(lo)
			else {
				while (lo - prev > 180) lo -= 360
				while (lo - prev < -180) lo += 360
			}
			prev = lo
			la = q[1] + 0
			if (la > 85) la = 85
			if (la < -85) la = -85
			k++
			px[np + 1, k] = lo
			py[np + 1, k] = merc_y(la)
		}
		if (k >= 3) { np++; pn[np] = k }
	}
}

# even-odd ray casting; a point counts if any 360-degree copy of it is inside
function in_polygon(p, la, lo,   y, c, i, j, x, k) {
	y = merc_y(la)
	for (c = -1; c <= 1; c++) {
		x = lo + 360 * c
		k = 0
		j = pn[p]
		for (i = 1; i <= pn[p]; i++) {
			if ((py[p, i] > y) != (py[p, j] > y) &&
			    x < (px[p, j] - px[p, i]) * (y - py[p, i]) / (py[p, j] - py[p, i]) + px[p, i])
				k = !k
			j = i
		}
		if (k) return 1
	}
	return 0
}

function parse_region(   t, q, n, i, la, lo, r) {
	nc = 0; ncc = 0
	parse_polygons()
	n = split(circles, t, /[ \t;]+/)
	for (i = 1; i <= n; i++) {
		if (t[i] == "") continue
		if (split(t[i], q, ",") != 3) continue
		if (!is_num(q[1]) || !is_num(q[2]) || !is_num(q[3])) continue
		la = q[1] + 0; lo = q[2] + 0; r = q[3] + 0
		if (la < -90 || la > 90 || lo < -180 || lo > 180 || r <= 0) continue
		nc++; clat[nc] = la; clon[nc] = lo; crad[nc] = r
	}
	n = split(toupper(countries), t, /[ \t,;]+/)
	for (i = 1; i <= n; i++)
		if (t[i] ~ /^[A-Z][A-Z]$/) { cc_ok[t[i]] = 1; ncc++ }
	has_region = (nc > 0 || ncc > 0 || np > 0)
}

# No circle, polygon or country yet means nothing is inside: in strict and
# enforce mode every located server is blocked until a region is drawn.
function inside(la, lo, cc,   i) {
	if (!has_region) return 0
	if (cc in cc_ok) return 1
	for (i = 1; i <= nc; i++)
		if (dist_km(la, lo, clat[i], clon[i]) <= crad[i]) return 1
	for (i = 1; i <= np; i++)
		if (in_polygon(i, la, lo)) return 1
	return 0
}

# JSON helpers for flat objects (enough for ip-api style responses)
function jstr(r, k,   m) {
	if (match(r, "\"" k "\"[ \t\r\n]*:[ \t\r\n]*\"[^\"]*\"")) {
		m = substr(r, RSTART, RLENGTH)
		sub(/^"[^"]*"[ \t\r\n]*:[ \t\r\n]*"/, "", m)
		sub(/"$/, "", m)
		return m
	}
	return ""
}
function jnum(r, k,   m) {
	if (match(r, "\"" k "\"[ \t\r\n]*:[ \t\r\n]*-?[0-9.]+")) {
		m = substr(r, RSTART, RLENGTH)
		sub(/^"[^"]*"[ \t\r\n]*:[ \t\r\n]*/, "", m)
		return m
	}
	return ""
}

function emit_set(s,   i, line, k) {
	if (!cnt[s]) return
	line = ""; k = 0
	for (i = 1; i <= cnt[s]; i++) {
		line = line (k ? ", " : "") lst[s, i]
		k++
		if (k == 400 || i == cnt[s]) {
			print "add element inet " t " " p "_" s " { " line " }"
			line = ""; k = 0
		}
	}
}

# ipset: fill a spare set and swap it in - the live set is replaced in one step
function ipset_emit(s,   i, nm, tmp) {
	nm = p "_" s; tmp = nm "_t"
	print "create " tmp " hash:ip family " (index(s, "6") ? "inet6" : "inet") " maxelem 262144"
	print "flush " tmp
	for (i = 1; i <= cnt[s]; i++) print "add " tmp " " lst[s, i]
	print "swap " tmp " " nm
	print "destroy " tmp
}

BEGIN {
	if (op == "georesp") RS = "}"
	if (op == "classify") {
		parse_region()
		# the previous result for the same region: a server whose location is
		# unchanged keeps its verdict without the geometry being redone
		if (prev != "")
			while ((getline l < prev) > 0) {
				split(l, pf, " ")
				if (pf[2] == "in" || pf[2] == "out") pkey[pf[1]] = pf[3] SUBSEP pf[4] SUBSEP pf[5] SUBSEP pf[2]
			}
	}
	if (now == "") now = 0
	now += 0
	expire += 0
	retry += 0
}

# ---------------------------------------------------------------- addrs
op == "addrs" {
	for (i = 1; i <= NF; i++) {
		if (is_mac($i)) { print "mac", norm_mac($i); continue }
		x = norm_addr($i)
		f = fam(x)
		print (f == "" ? "bad" : f), (f == "" ? $i : x)
	}
	next
}

# ---------------------------------------------------------------- neigh
op == "neigh" {
	if (!nmac) {
		nmac = split(tolower(macs), mm, /[ ,]+/)
		for (i = 1; i <= nmac; i++) if (mm[i] != "") want[mm[i]] = 1
	}
	m = norm_mac($1)
	if ((m in want) && fam($2) != "" && index($2, "/") == 0 && tolower(substr($2, 1, 4)) != "fe80" && !($2 in seen)) {
		seen[$2] = 1
		print $2
	}
	next
}

# --------------------------------------------------------------- public
op == "public" {
	for (i = 1; i <= NF; i++)
		if (is_public_host($i) && !($i in seen)) { seen[$i] = 1; print $i }
	next
}

# -------------------------------------------------------------- harvest
op == "harvest" {
	line = $0
	if (!inel) {
		pos = index(line, "elements = {")
		if (!pos) next
		inel = 1
		line = substr(line, pos + 12)
	}
	pos = index(line, "}")
	if (pos) { line = substr(line, 1, pos - 1); inel = 0 }
	gsub(/,/, " ", line)
	n = split(line, tk, /[ \t]+/)
	for (i = 1; i <= n; i++)
		if (tk[i] != "" && is_public_host(tk[i]) && !(tk[i] in seen)) {
			seen[tk[i]] = 1
			print tk[i]
		}
	next
}

# ---------------------------------------------------------------- merge
op == "merge" && FILENAME == ARGV[1] {
	if ($1 != "" && !($1 in ls)) { ord[++no] = $1; ls[$1] = $2 + 0 }
	next
}
op == "merge" {
	if ($1 == "") next
	if (!($1 in ls)) { ord[++no] = $1; ls[$1] = now; added++ }
	else { if (ls[$1] < now) touched++; ls[$1] = now }
	next
}

# ---------------------------------------------------------------- clean
# learned data read back from flash: a damaged line (power cut, full or worn
# flash) is dropped instead of being taken as a server or a location - a
# location line without numbers would otherwise mark its server "outside"
# for good, and one bad address makes the firewall refuse the whole list.
# Missing / garbled "last seen" times become "now" (the server is kept).
op == "clean_ips" {
	if ($0 ~ /^[ \t]*$/) next
	if (!is_public_host($1) || ($1 in seen)) { bad++; next }
	seen[$1] = 1
	print $1, ($2 ~ /^[0-9]+$/ ? $2 : now)
	next
}
op == "clean_cache" {
	if ($0 ~ /^[ \t]*$/) next
	ts = ($5 ~ /^[0-9]+$/ ? $5 : now)
	if (!is_public_host($1)) { bad++; next }
	if ($2 == "-" && $3 == "-") { print $1, "-", "-", "--", ts; next }
	if (!is_num($2) || !is_num($3) || $2 + 0 < -90 || $2 + 0 > 90 || $3 + 0 < -180 || $3 + 0 > 180) { bad++; next }
	print $1, $2, $3, ($4 ~ /^[A-Z][A-Z]$/ ? $4 : "--"), ts
	next
}

# credentials in what the report shows - e.g. a paid geolocation service's
# key in its address (".../batch?key=SECRET"): key=, apikey=, token=,
# password=, secret=, ... -> "key=(hidden)"
function hide_secrets(s,   low, o, p, q, v) {
	low = tolower(s); o = ""
	while (match(low, /(api_?key|access_?key|key|token|secret|password|passwd|pass|auth)=/)) {
		p = RSTART + RLENGTH - 1                     # up to and with the "="
		# (only a whole word: "monkey=" is not "key=")
		if (RSTART > 1 && substr(low, RSTART - 1, 1) ~ /[a-z0-9_]/) {
			o = o substr(s, 1, p); s = substr(s, p + 1); low = substr(low, p + 1); continue
		}
		v = substr(s, p + 1); q = match(v, /[&'" \t,;)]/) ? RSTART - 1 : length(v)
		if (q > 0) { o = o substr(s, 1, p) "(hidden)"; s = substr(s, p + 1 + q); low = substr(low, p + 1 + q) }
		else { o = o substr(s, 1, p); s = substr(s, p + 1); low = substr(low, p + 1) }
	}
	return o s
}

# -------------------------------------------------------------- maskmac
# the debug report: MAC addresses partly hidden - "70:9e:29:**:**:01" keeps
# the maker part, and the number says which lines are the same device
op == "maskmac" {
	if (!mre) { h = "[0-9A-Fa-f][0-9A-Fa-f]"; mre = h ":" h ":" h ":" h ":" h ":" h }
	out = ""; s = $0
	while (match(s, mre)) {
		pre = substr(s, 1, RSTART - 1); m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
		# (part of something longer - an IPv6 address - stays as it is)
		if ((pre != "" && substr(pre, length(pre)) ~ /[0-9A-Fa-f:]/) || substr(s, 1, 1) ~ /[0-9A-Fa-f:]/) { out = out pre m; continue }
		k = tolower(m)
		if (!(k in alias)) alias[k] = sprintf("%02d", ++nalias)
		out = out pre substr(k, 1, 8) ":**:**:" alias[k]
	}
	out = hide_secrets(out s)
	# (a size limit: the page gets at most so much of a command's output)
	if (max > 0 && (bytes += length(out) + 1) > max - 200) {
		if (!cut++) print "... (the report was cut here: longer than " max " bytes)"
		next
	}
	print out
	next
}

# -------------------------------------------------------------- pending
op == "pending" && FILENAME == ARGV[1] {
	if ($1 != "") known[$1] = ($2 != "-" || $5 + 0 >= now - retry)
	next
}
op == "pending" {
	if ($1 != "" && !(($1 in known) && known[$1]) && !($1 in seen)) {
		seen[$1] = 1
		print $1
	}
	next
}

# -------------------------------------------------------------- geojson
op == "geojson" {
	if (is_public_host($1)) out = out (nj++ ? "," : "") "\"" $1 "\""
	next
}

# -------------------------------------------------------------- georesp
op == "georesp" {
	q = jstr($0, "query")
	if (q == "" || !is_public_host(q)) next
	if (jstr($0, "status") == "success") {
		la = jnum($0, "lat"); lo = jnum($0, "lon")
		cc = toupper(jstr($0, "countryCode"))
		if (!is_num(la) || !is_num(lo)) next
		if (cc !~ /^[A-Z][A-Z]$/) cc = "--"
		# a place off the globe (a broken or tampered answer) counts as not located
		if (la + 0 < -90 || la + 0 > 90 || lo + 0 < -180 || lo + 0 > 180) print q, "-", "-", "--", now
		else print q, la, lo, cc, now
	} else {
		print q, "-", "-", "--", now
	}
	next
}

# ------------------------------------------------------------- classify
op == "classify" && FILENAME == ARGV[1] {
	if ($1 != "") { glat[$1] = $2; glon[$1] = $3; gcc[$1] = $4 }
	next
}
op == "classify" {
	if ($1 == "") next
	ip = $1; ts = ($2 == "" ? 0 : $2)
	ccount["all"]++
	if (!(ip in glat)) { ccount["pending"]++; print ip, "pending", "-", "-", "--", ts; next }
	if (glat[ip] == "-") { ccount["unloc"]++; print ip, "unloc", "-", "-", "--", ts; next }
	k = glat[ip] SUBSEP glon[ip] SUBSEP gcc[ip]
	if ((ip in pkey) && index(pkey[ip], k SUBSEP) == 1)
		v = substr(pkey[ip], length(k) + 2)
	else if (k in memo)
		v = memo[k]   # many servers share one city's coordinates
	else
		v = memo[k] = (inside(glat[ip] + 0, glon[ip] + 0, gcc[ip]) ? "in" : "out")
	print ip, v, glat[ip], glon[ip], gcc[ip], ts
	ccount[v]++
	# which servers are allowed / blocked (no timestamps): lets the caller skip
	# the firewall update when this has not changed
	if (statef != "") print ip, v > statef
	next
}

# ------------------------------------------------------------- elements
op == "elements" {
	if ($1 == "" || ($2 != "in" && $2 != "out")) next
	s = $2 (index($1, ":") ? "6" : "4")
	lst[s, ++cnt[s]] = $1
	next
}

# ---------------------------------------------------------------- prune
op == "prune" && FILENAME == ARGV[1] {
	if ($1 != "") ref[$1] = 1
	next
}
op == "prune" {
	if ($1 == "" || !($1 in ref)) next
	if (!($1 in row)) pord[++np] = $1
	row[$1] = $0
	next
}

# -------------------------------------------------------------- devices
op == "devices" {
	if (!is_mac($2)) next
	m = norm_mac($2)
	if (m == "00:00:00:00:00:00" || m == "ff:ff:ff:ff:ff:ff") next
	if (!(m in dseen)) { dseen[m] = 1; dord[++nd] = m }
	if ($1 == "lease" && $4 != "" && $4 != "*") {
		h = $4; gsub(/[^A-Za-z0-9._ -]/, "", h); dhost[m] = h
	}
	a = $3
	if (index(a, "/") || fam(a) == "") next
	if (tolower(substr(a, 1, 4)) == "fe80") next
	if ((m SUBSEP a) in dhas) next
	dhas[m, a] = 1
	if (fam(a) == "4") d4[m] = d4[m] (d4[m] == "" ? "" : ",") "\"" a "\""
	else d6[m] = d6[m] (d6[m] == "" ? "" : ",") "\"" a "\""
	next
}

# ----------------------------------------------------------------- ages
function dur_secs(d,   v, secs) {
	sub(/[,}]+$/, "", d); secs = 0
	while (match(d, /^[0-9]+(ms|h|m|s|d)/)) {
		v = substr(d, RSTART, RLENGTH); d = substr(d, RLENGTH + 1)
		if (v ~ /ms$/) secs += (v + 0) / 1000
		else if (v ~ /h$/) secs += (v + 0) * 3600
		else if (v ~ /d$/) secs += (v + 0) * 86400
		else if (v ~ /m$/) secs += (v + 0) * 60
		else secs += v + 0
	}
	return secs
}
op == "ages" {
	line = $0
	if (!inel) {
		pos = index(line, "elements = {")
		if (!pos) next
		inel = 1
		line = substr(line, pos + 12)
	}
	pos = index(line, "}")
	if (pos) { line = substr(line, 1, pos - 1); inel = 0 }
	n = split(line, chunk, ",")
	for (c = 1; c <= n; c++) {
		m = split(chunk[c], tk, /[ \t]+/)
		ip = ""; left = -1; pk = 0
		for (i = 1; i <= m; i++) {
			if (tk[i] == "") continue
			if (ip == "") ip = tk[i]
			if (tk[i] == "expires" && i < m) left = dur_secs(tk[i + 1])
			if (tk[i] == "packets" && i < m) pk = tk[i + 1] + 0
		}
		if (ip == "" || !is_public_host(ip) || (ip in aseen)) continue
		aseen[ip] = 1
		age = (left < 0) ? 0 : window - left
		if (age < 0) age = 0
		printf "%s %d %d\n", ip, int(age + 0.5), pk
	}
	next
}

# -------------------------------------------------------------- expires
# durations look like 1h2m3s400ms, 19s992ms, 3m
op == "expires" {
	for (i = 1; i < NF; i++) {
		if ($i != "expires") continue
		d = $(i + 1); sub(/[,}]+$/, "", d); secs = 0
		while (match(d, /^[0-9]+(ms|h|m|s|d)/)) {
			v = substr(d, RSTART, RLENGTH); d = substr(d, RLENGTH + 1)
			if (v ~ /ms$/) secs += (v + 0) / 1000
			else if (v ~ /h$/) secs += (v + 0) * 3600
			else if (v ~ /d$/) secs += (v + 0) * 86400
			else if (v ~ /m$/) secs += (v + 0) * 60
			else secs += v + 0
		}
		if (secs > maxexp) maxexp = secs
	}
	next
}

# ------------------------------------------------------- ipset (FreshTomato)
# `ipset list` output: the member lines of the sets ("<addr> timeout <s>")
function ipset_member(   ip) {
	if ($0 ~ /^Name:/) { inm = 0; return "" }
	if ($0 ~ /^Members:/) { inm = 1; return "" }
	if (!inm || NF == 0) return ""
	ip = $1
	if (!is_public_host(ip)) return ""
	return ip
}

# public addresses in the sets, once each
op == "ipset_members" {
	ip = ipset_member()
	if (ip != "" && !(ip in seen)) { seen[ip] = 1; print ip }
	next
}

# "<addr> <seconds since last update> <packets>" (-v window; -v pk: "<addr> <packets>" file)
op == "ipset_ages" && FNR == 1 && NR == 1 && pk != "" {
	while ((getline l < pk) > 0) { split(l, ipa, " "); pkts[ipa[1]] = ipa[2] }
	close(pk)
}
op == "ipset_ages" {
	ip = ipset_member()
	if (ip == "" || (ip in aseen)) next
	aseen[ip] = 1
	left = -1
	for (i = 2; i < NF; i++) if ($i == "timeout") left = $(i + 1) + 0
	age = (left < 0) ? 0 : window - left
	if (age < 0) age = 0
	printf "%s %d %d\n", ip, int(age + 0.5), (ip in pkts) ? pkts[ip] : -1
	next
}

# longest remaining timeout in the sets, in seconds
op == "ipset_expires" {
	if ($0 ~ /^Name:/) { inm = 0; next }
	if ($0 ~ /^Members:/) { inm = 1; next }
	if (!inm) next
	for (i = 2; i < NF; i++) if ($i == "timeout" && $(i + 1) + 0 > maxexp) maxexp = $(i + 1) + 0
	next
}

# `ipset list -t` -> "<name> <family> <maxelem> <timeout>" (only the parameters
# that need a new set when they change; the hash size grows by itself)
op == "ipset_headers" {
	if ($1 == "Name:") { if (hn != "") print hn, hf, hm, ht; hn = $2; hf = "inet"; hm = 65536; ht = 0; next }
	if ($1 == "Header:") {
		for (i = 2; i < NF; i++) {
			if ($i == "family") hf = $(i + 1)
			if ($i == "maxelem") hm = $(i + 1)
			if ($i == "timeout") ht = $(i + 1)
		}
	}
	next
}

# classify output -> `ipset restore` commands that rebuild a zone's in/out
# sets in a spare set and swap it in (-v p=<set prefix>, v6=0|1)
op == "ipset_load" {
	if ($1 == "" || ($2 != "in" && $2 != "out")) next
	s = $2 (index($1, ":") ? "6" : "4")
	lst[s, ++cnt[s]] = $1
	next
}

# /proc/net/nf_conntrack -> "<server> <packets the device sent to it>"
# (-v devs: file with the zone's device addresses; needs nf_conntrack_acct)
function v6_norm(s,   g, n, i, out, bs, bl, cs, cl) {
	s = tolower(s)
	if (index(s, "::")) return s
	n = split(s, g, ":")
	if (n != 8) return s
	for (i = 1; i <= 8; i++) { sub(/^0+/, "", g[i]); if (g[i] == "") g[i] = "0" }
	bs = 0; bl = 0; cs = 0; cl = 0
	for (i = 1; i <= 8; i++) {
		if (g[i] == "0") { if (!cl) cs = i; cl++; if (cl > bl) { bl = cl; bs = cs } }
		else cl = 0
	}
	out = ""
	if (bl < 2) {
		for (i = 1; i <= 8; i++) out = out (i > 1 ? ":" : "") g[i]
		return out
	}
	for (i = 1; i < bs; i++) out = out (i > 1 ? ":" : "") g[i]
	out = out "::"
	for (i = bs + bl; i <= 8; i++) out = out g[i] (i < 8 ? ":" : "")
	return out
}
# (-v family=6: IPv6 only; -v proto, lp, rp, pp: only the zone's game traffic,
#  as the firewall rules pick it; servers without packet counts give -1)
function in_ports(p, list,   n, t, i, a, b) {
	n = split(list, t, /[ ,]+/)
	for (i = 1; i <= n; i++) {
		if (t[i] == "") continue
		a = t[i]; b = t[i]
		if (index(t[i], "-")) { a = substr(t[i], 1, index(t[i], "-") - 1); b = substr(t[i], index(t[i], "-") + 1) }
		if (p + 0 >= a + 0 && p + 0 <= b + 0) return 1
	}
	return 0
}
function game_ports(dp, sp,   m) {          # dp: device port, sp: server port
	if (lp == "" && rp == "" && pp == "") return 1
	m = 0
	if (lp != "" || rp != "") m = (lp == "" || in_ports(dp, lp)) && (rp == "" || in_ports(sp, rp))
	if (!m && pp != "") m = in_ports(dp, pp) || in_ports(sp, pp)
	return m
}
# ---- the server ports a zone's device used, over time ("Ports seen"): a
# game's real ports, so a zone can be narrowed to them
function port_line_ok() {
	return $1 ~ /^(udp|tcp)\/[0-9]+$/ && NF >= 6 && $2 ~ /^[0-9]+$/ && $3 ~ /^[0-9]+$/ && \
		$4 ~ /^[0-9]+$/ && $5 ~ /^[0-9]+$/ && $6 ~ /^[0-9]+$/ && port_ok(substr($1, 5) + 0)
}
# the packets counted on a port so far (lines from before totals were kept: their peak)
function port_total() {
	return (NF >= 7 && $7 ~ /^[0-9]+$/) ? $7 + 0 : $3 + 0
}
function port_ok(n) {      # web, DNS, time, mDNS / SSDP: never a game's server port
	return n >= 1 && n <= 65535 && n != 53 && n != 80 && n != 123 && n != 443 && n != 853 && n != 1900 && n != 5353
}
op == "clean_ports" {
	if (port_line_ok()) print $1, $2, $3, $4, $5, $6, port_total()
	else if ($0 != "") bad++
	next
}
op == "ports_merge" && FILENAME == ARGV[1] {
	if (!port_line_ok()) next
	if (!($1 in tpv)) tpo[++tnpo] = $1
	tpv[$1] = 1; tps[$1] = $2; tpk[$1] = $3; tpf[$1] = $4; tpl[$1] = $5; tpn[$1] = $6; tpt[$1] = port_total()
	next
}
op == "ports_merge" {
	if ($1 !~ /^(udp|tcp)\/[0-9]+$/ || !port_ok(substr($1, 5) + 0) || $2 !~ /^[0-9]+$/) next
	if (!($1 in tpv)) { tpo[++tnpo] = $1; tpv[$1] = 1; tps[$1] = 0; tpk[$1] = 0; tpf[$1] = now; tpn[$1] = 0; tpt[$1] = 0 }
	if ($2 + 0 > tps[$1]) tps[$1] = $2 + 0
	# peak: the most in one pass; total: the packets sent since the pass before, added up
	if ($3 ~ /^[0-9]+$/ && $3 + 0 > tpk[$1]) tpk[$1] = $3 + 0
	if ($5 ~ /^[0-9]+$/) tpt[$1] += $5
	if (tpl[$1] != now) tpn[$1]++
	tpl[$1] = now
	next
}
op == "ports_show" {
	if (!port_line_ok()) next
	print $1, $2, $3, $4, $5, $6, game_ports(-1, substr($1, 5) + 0), port_total()
	next
}
(op == "ct_packets" || op == "ct_ports") && FNR == 1 && NR == 1 {
	while ((getline l < devs) > 0) if (l != "") ctdev[(index(l, ":") ? v6_norm(l) : l)] = 1
	close(devs)
	# (Ports seen: each connection's packet count at the pass before - -v ctlast)
	if (ctlast != "") {
		while ((getline ctl < ctlast) > 0) if (split(ctl, ctla, " ") == 2) cprev[ctla[1]] = ctla[2] + 0
		close(ctlast)
	}
}
op == "ct_packets" || op == "ct_ports" {
	if (proto != "" && proto != "both" && $3 != proto) next
	if (proto == "both" && $3 != "udp" && $3 != "tcp") next
	k = 0; split("", ctsrc); split("", ctdst); split("", ctpk); split("", ctsp); split("", ctdp)
	for (i = 1; i <= NF; i++) {
		if (substr($i, 1, 4) == "src=") { k++; ctsrc[k] = substr($i, 5); if (index(ctsrc[k], ":")) ctsrc[k] = v6_norm(ctsrc[k]) }
		else if (substr($i, 1, 4) == "dst=") { ctdst[k] = substr($i, 5); if (index(ctdst[k], ":")) ctdst[k] = v6_norm(ctdst[k]) }
		else if (substr($i, 1, 6) == "sport=") ctsp[k] = substr($i, 7)
		else if (substr($i, 1, 6) == "dport=") ctdp[k] = substr($i, 7)
		else if (substr($i, 1, 8) == "packets=") ctpk[k] = substr($i, 9) + 0
	}
	if (k < 2) next
	if (ctsrc[1] in ctdev) d = 1
	else if (ctsrc[2] in ctdev) d = 2
	else next
	sv = ctdst[d]
	if (!is_public_host(sv)) next
	if (family == "6" && !index(sv, ":")) next
	if (family == "4" && index(sv, ":")) next
	if (op == "ct_ports") {
		# every port the device talks to servers on - which of them the zone's ports cover
		pk = $3 "/" ctdp[d]
		if (!(pk in cpn)) { pord[++npt] = pk; cpk[pk] = -1; cpin[pk] = game_ports(ctsp[d], ctdp[d]) }
		if (!((pk, sv) in cpsv)) { cpsv[pk, sv] = 1; cpn[pk]++ }
		if (d in ctpk) {
			cpk[pk] = (cpk[pk] < 0 ? 0 : cpk[pk]) + ctpk[d]
			# the packets sent since the pass before (-v ctnext: where this pass's counts go)
			if (ctnext != "") {
				ck = $3 "|" ctsrc[1] "|" ctsp[1] "|" ctdst[1] "|" ctdp[1]
				cdel[pk] += (ck in cprev && ctpk[d] >= cprev[ck]) ? ctpk[d] - cprev[ck] : ctpk[d]
				print ck, ctpk[d] > ctnext
			}
		}
		next
	}
	if (!game_ports(ctsp[d], ctdp[d])) next
	if (!(sv in ctp)) { cord[++nct] = sv; ctp[sv] = -1 }
	if (d in ctpk) ctp[sv] = (ctp[sv] < 0 ? 0 : ctp[sv]) + ctpk[d]
	next
}

# `iptables -L -v -x -n` -> "z_<zone>_match|hit|opened <packets>" from the
# counting chains LF_<zone>_cm / _x / _co (their last rule carries the count)
op == "ipt_counts" {
	if ($1 == "Chain") { ch = $2; next }
	if ($1 !~ /^[0-9]+$/) next
	if (ch ~ /^LF_.*_cm$/) { nm = "match"; z = substr(ch, 4, length(ch) - 6) }
	else if (ch ~ /^LF_.*_co$/) { nm = "opened"; z = substr(ch, 4, length(ch) - 6) }
	else if (ch ~ /^LF_.*_x$/) { nm = "hit"; z = substr(ch, 4, length(ch) - 5) }
	else next
	if ($3 == "LOG") next
	key = "z_" z "_" nm
	if (!(key in icnt)) iord[++nic] = key
	icnt[key] += $1
	next
}

# --------------------------------------------- shared server files
# The file people swap: each game's servers and where they are, so another
# router can skip looking them up.
#   lobbyfence-servers 1
#   game <id> <name...>
#   <address> <latitude> <longitude> <country> <last seen, unix time>
# Imported locations are kept as "<address> <lat> <lon> <country> <seen> <game>"
# ("... own" for the ones this router found itself, kept after a zone changed game).
function ex_add(g, line,   ip) {
	ip = line; sub(/ .*/, "", ip)
	if ((g SUBSEP ip) in exs) return
	exs[g SUBSEP ip] = 1
	if (!(g in exn)) { exo[++nexo] = g; exn[g] = 0 }
	exl[g, ++exn[g]] = line
}
# where a server of a game came from: the list LobbyFence comes with, a servers file
# imported here - even when the device has played on it since, or this router had
# found it before - or else this router
function ex_from(g, ip) {
	if ((g SUBSEP ip) in ex_bi) return " builtin"
	if ((g SUBSEP ip) in ex_imp) return " imported"
	return ""
}
# export: geo.cache, the zones' games and names, "game address seen" of the zones'
# servers, the kept / imported locations, the list LobbyFence comes with (optional)
op == "export" && FILENAME == ARGV[1] {
	if (is_public_host($1) && is_num($2) && is_num($3)) loc[$1] = $2 " " $3 " " ($4 ~ /^[A-Z][A-Z]$/ ? $4 : "--")
	next
}
op == "export" && FILENAME == ARGV[2] {
	if ($1 ~ /^[a-z0-9_]+$/ && !($1 in gname)) { gname[$1] = $0; sub(/^[^ ]+ */, "", gname[$1]) }
	next
}
op == "export" && FILENAME == ARGV[3] {
	if ($2 in loc) { ex_zg[++ex_zn] = $1; ex_zl[ex_zn] = $2 " " loc[$2] " " ($3 ~ /^[0-9]+$/ ? $3 : 0) }
	next
}
op == "export" && FILENAME == ARGV[4] {
	if (NF >= 6 && $6 ~ /^[a-z0-9_]+$/ && is_public_host($1) && is_num($2) && is_num($3)) {
		ex_sg[++ex_sn] = $6; ex_sl[ex_sn] = $1 " " $2 " " $3 " " $4 " " $5
		if ($7 != "own") ex_imp[$6 SUBSEP $1] = 1
	}
	next
}
op == "export" {
	sub(/\r$/, "")
	if ($1 == "game") ex_bg = $2
	else if (ex_bg != "" && $1 ~ /^[0-9]/) ex_bi[ex_bg SUBSEP $1] = 1
	next
}
op == "shared_in" {
	sub(/\r$/, "")
	if ($0 ~ /^[ \t]*(#|$)/) next
	if (!hdr) {
		if ($1 == "lobbyfence-servers" && $2 == "1") { hdr = 1; next }
		exit
	}
	if ($1 == "game") { g = ($2 ~ /^[a-z0-9_]+$/ && length($2) <= 32) ? $2 : "other"; next }
	if (si_n >= maxn) { over++; next }
	if (NF < 4 || !is_public_host($1) || !is_num($2) || !is_num($3) || $2 + 0 < -90 || $2 + 0 > 90 ||
	    $3 + 0 < -180 || $3 + 0 > 180 || $4 !~ /^([A-Z][A-Z]|--)$/) { bad++; next }
	ts = ($5 ~ /^[0-9]+$/ && $5 + 0 <= now) ? $5 + 0 : now
	print $1, $2, $3, $4, ts, (g == "" ? "other" : g)
	si_n++
	next
}
op == "shared_merge" {
	if (NF < 6) next
	k = $6 SUBSEP $1
	own = ($7 == "own")
	line = $1 " " $2 " " $3 " " $4 " " $5 " " $6
	if (!(k in sm)) { smo[++nsm] = k; sm[k] = line; smt[k] = $5 + 0; smown[k] = own; if (FILENAME != ARGV[1]) smadd++ }
	else {
		if ($5 + 0 > smt[k]) { sm[k] = line; smt[k] = $5 + 0 }
		if (!own) smown[k] = 0         # in an imported file once: counts as imported from then on
	}
	next
}
op == "shared_hit" && FILENAME == ARGV[1] {
	if ($1 != "") want[$1] = 1
	next
}
op == "shared_hit" {
	if (NF >= 5 && ($1 in want) && !($1 in shit)) { shit[$1] = 1; print $1, $2, $3, $4, $5 }
	next
}

# ---- sending found servers to LobbyFence (share-servers): only this router's own
# finds, for the listed client-server games, in data-centre networks, and not
# already in the built-in list or sent before - so no player's own address
function ip4n(s,   sh_a) {
	if (s !~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/) return -1
	split(s, sh_a, ".")
	if (sh_a[1] > 255 || sh_a[2] > 255 || sh_a[3] > 255 || sh_a[4] > 255) return -1
	return ((sh_a[1] * 256 + sh_a[2]) * 256 + sh_a[3]) * 256 + sh_a[4]
}
# share_pick: networks, games, built-in list, sent list, export -> "seen game address lat lon cc"
op == "share_pick" && FILENAME == ARGV[1] {
	sub(/#.*/, "")
	for (i = 1; i <= NF; i++) {
		if (split($i, sh_c, "/") != 2 || sh_c[2] !~ /^[0-9]+$/ || sh_c[2] + 0 > 32 || (sh_b = ip4n(sh_c[1])) < 0) continue
		sh_sz = 2 ^ (32 - sh_c[2])
		sh_nb[++sh_nn] = sh_b - sh_b % sh_sz; sh_ns[sh_nn] = sh_sz
	}
	next
}
op == "share_pick" && FILENAME == ARGV[2] { if ($1 ~ /^[a-z0-9_]+$/) sh_okg[$1] = 1; next }
op == "share_pick" && FILENAME == ARGV[4] { if (NF >= 2) sh_have[$1 SUBSEP $2] = 1; next }
op == "share_pick" && FILENAME == ARGV[3] {
	sub(/\r$/, "")
	if ($1 == "game") sh_kg = $2
	else if ($1 ~ /^[0-9]/ && sh_kg != "") sh_have[sh_kg SUBSEP $1] = 1
	next
}
op == "share_pick" {
	sub(/\r$/, "")
	if ($1 == "game") { sh_pg = ($2 in sh_okg) ? $2 : ""; next }
	if (sh_pg == "" || NF != 5) next          # (a sixth field: imported from elsewhere - not this router's find)
	if (!is_num($2) || !is_num($3) || $2 + 0 < -90 || $2 + 0 > 90 || $3 + 0 < -180 || $3 + 0 > 180 ||
	    $4 !~ /^([A-Z][A-Z]|--)$/ || $5 !~ /^[0-9]+$/) next
	if ((sh_pg SUBSEP $1) in sh_have || (sh_pg SUBSEP $1) in sh_picked) next
	if ((sh_a = ip4n($1)) < 0) next
	for (i = 1; i <= sh_nn; i++) if (sh_a >= sh_nb[i] && sh_a < sh_nb[i] + sh_ns[i]) break
	if (i > sh_nn) next
	sh_picked[sh_pg SUBSEP $1] = 1
	print $5, sh_pg, $1, $2, $3, $4
	next
}
# share_text: games file, then the picked lines (newest first) -> the servers file to send
# (at most max characters - the rest goes next time); "game address" of each sent to pairs
op == "share_text" && FILENAME == ARGV[1] {
	if ($1 ~ /^[a-z0-9_]+$/) { sh_lab = $0; sub(/^[^ ]+ +/, "", sh_lab); sh_glabel[$1] = sh_lab; sh_gorder[++sh_ngo] = $1 }
	next
}
op == "share_text" {
	if (NF != 6 || !($2 in sh_glabel)) next
	sh_l = $3 " " $4 " " $5 " " $6 " " $1
	sh_h = ($2 in sh_cnt) ? 0 : length($2) + length(sh_glabel[$2]) + 7     # (its "game" line, the first time)
	if (sh_size + sh_h + length(sh_l) + 1 > max - 300) { sh_more++; next }
	sh_size += sh_h + length(sh_l) + 1
	sh_srow[$2] = sh_srow[$2] sh_l "\n"; sh_cnt[$2]++; sh_sn++
	print $2, $3 > pairs
	next
}
# share_enc: text -> one application/x-www-form-urlencoded field (name=value)
function urlenc(s,   i, ch, o) {
	if (!sh_encinit) { for (i = 1; i < 256; i++) sh_ordc[sprintf("%c", i)] = i; sh_encinit = 1 }
	o = ""
	for (i = 1; i <= length(s); i++) {
		ch = substr(s, i, 1)
		o = o (ch ~ /[A-Za-z0-9_.~-]/ ? ch : sprintf("%%%02X", sh_ordc[ch]))
	}
	return o
}
op == "share_enc" {
	if (!sh_started) { printf "%s=", field; sh_started = 1 }
	printf "%s%%0A", urlenc($0)
	next
}

END {
	if (op == "classify" && countf != "")
		printf "%d %d %d %d %d\n", ccount["all"], ccount["in"], ccount["out"], ccount["pending"], ccount["unloc"] > countf
	if (op == "merge") {
		nk = 0
		for (i = 1; i <= no; i++) {
			ip = ord[i]
			if (expire > 0 && ls[ip] < now - expire) { expired++; continue }
			kept[++nk] = ip
		}
		# more than -v zmax servers: the ones seen longest ago go. zcut is the
		# smallest time with at most zmax servers seen then or later; servers
		# seen just before it fill up the rest (in the order they were learned)
		zcut = -1
		if (zmax > 0 && nk > zmax) {
			lo = hi = ls[kept[1]]
			for (i = 2; i <= nk; i++) { if (ls[kept[i]] > hi) hi = ls[kept[i]]; if (ls[kept[i]] < lo) lo = ls[kept[i]] }
			hi++
			while (lo < hi) {
				mid = int((lo + hi) / 2); c = 0
				for (i = 1; i <= nk; i++) if (ls[kept[i]] >= mid) c++
				if (c <= zmax) hi = mid; else lo = mid + 1
			}
			zcut = lo; c = 0
			for (i = 1; i <= nk; i++) if (ls[kept[i]] >= zcut) c++
			zfill = zmax - c
			dropped = nk - zmax
		}
		for (i = 1; i <= nk; i++) {
			ip = kept[i]
			if (ls[ip] < zcut) {
				if (ls[ip] == zcut - 1 && zfill > 0) zfill--
				else continue
			}
			print ip, ls[ip]
		}
		if (statf != "") print (added + 0), (touched + 0), (expired + 0), (dropped + 0) > statf
	} else if (op == "geojson") {
		print "[" out "]"
	} else if (op == "elements") {
		print "flush set inet " t " " p "_in4"
		print "flush set inet " t " " p "_in6"
		print "flush set inet " t " " p "_out4"
		print "flush set inet " t " " p "_out6"
		emit_set("in4"); emit_set("in6"); emit_set("out4"); emit_set("out6")
	} else if (op == "prune") {
		for (i = 1; i <= np; i++) print row[pord[i]]
	} else if (op == "devices") {
		printf "["
		for (i = 1; i <= nd; i++) {
			m = dord[i]
			if (d4[m] == "" && d6[m] == "" && !(m in dhost)) continue
			printf "%s{\"mac\":\"%s\",\"name\":\"%s\",\"ipv4\":[%s],\"ipv6\":[%s]}", (nout++ ? "," : ""), m, dhost[m], d4[m], d6[m]
		}
		print "]"
	} else if (op == "expires" || op == "ipset_expires") {
		printf "%d\n", (maxexp > 0 ? int(maxexp + 0.999) : 0)
	} else if (op == "ipset_headers") {
		if (hn != "") print hn, hf, hm, ht
	} else if (op == "ipset_load") {
		ipset_emit("in4"); ipset_emit("out4")
		if (v6) { ipset_emit("in6"); ipset_emit("out6") }
	} else if (op == "ct_packets") {
		for (i = 1; i <= nct; i++) print cord[i], ctp[cord[i]]
	} else if (op == "ports_merge") {
		# forgotten after 30 days unused
		for (i = 1; i <= tnpo; i++) if (now - tpl[tpo[i]] < 2592000) print tpo[i], tps[tpo[i]], tpk[tpo[i]], tpf[tpo[i]], tpl[tpo[i]], tpn[tpo[i]], tpt[tpo[i]]
	} else if (op == "ct_ports") {
		for (i = 1; i <= npt; i++)
			if (ctnext != "") print pord[i], cpn[pord[i]], cpk[pord[i]], cpin[pord[i]], (cpk[pord[i]] < 0 ? -1 : cdel[pord[i]] + 0)
			else print pord[i], cpn[pord[i]], cpk[pord[i]], cpin[pord[i]]
	} else if (op == "ipt_counts") {
		for (i = 1; i <= nic; i++) print iord[i], icnt[iord[i]]
	} else if (op == "clean_ips" || op == "clean_cache" || op == "clean_ports") {
		if (statf != "") print (bad + 0) > statf
	} else if (op == "export") {
		# the zones' servers first (their last-seen times), then the kept / imported
		# ones no zone has now - each game and address once
		for (i = 1; i <= ex_zn; i++) { ip = ex_zl[i]; sub(/ .*/, "", ip); ex_add(ex_zg[i], ex_zl[i] ex_from(ex_zg[i], ip)) }
		for (i = 1; i <= ex_sn; i++) { ip = ex_sl[i]; sub(/ .*/, "", ip); ex_add(ex_sg[i], ex_sl[i] ex_from(ex_sg[i], ip)) }
		print "# LobbyFence servers - each game's servers and where they are, so another"
		print "# router can import them and skip looking them up (LobbyFence -> Servers file)."
		if (when != "") print "# exported " when
		print "# game <id> <name>, then one server a line:"
		print "#   <address> <latitude> <longitude> <country> <last seen, unix time> [imported | builtin]"
		print "# (imported: from a servers file imported here; builtin: in the list LobbyFence"
		print "# comes with; neither: found by this router)"
		print "lobbyfence-servers 1"
		for (i = 1; i <= nexo; i++) {
			g = exo[i]
			print "game " g (gname[g] != "" ? " " gname[g] : "")
			for (j = 1; j <= exn[g]; j++) print exl[g, j]
		}
	} else if (op == "shared_in") {
		if (statf != "") print (hdr ? si_n + 0 : -1), (bad + 0), (over + 0) > statf
	} else if (op == "shared_merge") {
		for (i = 1; i <= nsm; i++) print sm[smo[i]] (smown[smo[i]] ? " own" : "")
		if (statf != "") print (smadd + 0) > statf
	} else if (op == "share_text") {
		if (sh_sn) {
			print "lobbyfence-servers 1"
			print "# sent by " (ver != "" ? ver : "LobbyFence") " (share-servers) - game servers in data-centre networks only"
			for (i = 1; i <= sh_ngo; i++) if (sh_gorder[i] in sh_cnt) { print "game " sh_gorder[i] " " sh_glabel[sh_gorder[i]]; printf "%s", sh_srow[sh_gorder[i]] }
		}
		if (statf != "") print (sh_sn + 0), (sh_more + 0) > statf
	}
}
