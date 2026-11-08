# LobbyFence firewall backend: nftables (OpenWrt fw4)
# Sourced by /usr/sbin/lobbyfence - see "firewall backend" there for the API.
#
# SPDX-License-Identifier: GPL-3.0-or-later

NFT="${NFT:-nft}"
TC="${LF_TC:-tc}"
IPCMD="${LF_IP:-ip}"
# lag simulator: firewall mark bits that send a zone's downloads to its netem queue
LAG_MASK=0x7f000000
LAG_PREF=4915
LAG_SUPPORTED=1
LF_ZONE_MAXLEN=48
FW_RULES="$LF_RUN/ruleset.nft"
FW_SETS="$LF_RUN/sets.nft"

# ------------------------------------------------------------- nft ruleset

emit_zone_sets() {
	local z="$1" f t
	for f in 4 6; do
		[ "$f" = 4 ] && t=ipv4_addr || t=ipv6_addr
		cat <<-EOF
		set z_${z}_dev$f { type $t; flags interval; auto-merge; }
		set z_${z}_fa$f { type $t; flags interval; auto-merge; }
		set z_${z}_fb$f { type $t; flags interval; auto-merge; }
		set z_${z}_mip$f { type $t; }
		set z_${z}_seen$f { type $t; size 65535; flags dynamic,timeout; timeout ${SEEN_TIMEOUT}s; }
		set z_${z}_now$f { type $t; size 65535; flags dynamic,timeout; timeout ${NOW_TIMEOUT}s; gc-interval 5s; counter; }
		set z_${z}_in$f { type $t; size 262144; }
		set z_${z}_out$f { type $t; size 262144; }
		EOF
		[ "$Z_BURST" -gt 0 ] && cat <<-EOF
		set z_${z}_burst$f { type $t; size $Z_BURST; flags dynamic,timeout; timeout ${Z_BURST_WIN}s; gc-interval 1s; }
		set z_${z}_open$f { type $t; size 1024; flags dynamic,timeout; timeout ${Z_BURST_OPEN}s; gc-interval 1s; }
		EOF
	done
	cat <<-EOF
	set z_${z}_mac { type ether_addr; }
	EOF
}

# emit the per-direction chain: emit_dir_chain <zone> <4|6> <o|i>
emit_dir_chain() {
	local z="$1" f="$2" d="$3" ipk peer
	[ "$f" = 4 ] && ipk=ip || ipk=ip6
	[ "$d" = o ] && peer=daddr || peer=saddr
	echo "chain z_${z}_$d$f {"
	echo "$ipk $peer @priv$f return"
	# lag simulator: tag the game's packets so tc sends them through netem -
	# downloads by packet mark (seen on the LAN egress), uploads by connection
	# mark (copied back to the packet on the LAN ingress, before the firewall)
	if [ -n "$Z_LAG_MARK" ]; then
		[ "$d" = i ] && [ "$Z_LAG_DIR" != up ] && echo "meta mark set meta mark & 0x80ffffff | $Z_LAG_MARK"
		[ "$d" = o ] && [ "$Z_LAG_DIR" != down ] && echo "ct mark set ct mark & 0x80ffffff | $Z_LAG_MARK"
	fi
	echo "jump z_${z}_cm"
	# outbound: every packet keeps the server "seen" (long matches stay current);
	# inbound: new connections only
	if [ "$d" = o ]; then
		# "active now": your device sent to this server recently (a server can keep
		# sending for a while after the game has left it, so its packets don't count)
		echo "update @z_${z}_now$f { $ipk $peer }"
		echo "update @z_${z}_seen$f { $ipk $peer }"
	else
		echo "ct state new update @z_${z}_seen$f { $ipk $peer }"
	fi
	echo "$ipk $peer @z_${z}_fa$f return"
	echo "$ipk $peer @z_${z}_fb$f goto z_${z}_x"
	if [ "$Z_BURST" -gt 0 ]; then
		# the device counts as "testing servers" while it is in the open set
		if [ "$d" = o ]; then
			echo "ct state new jump z_${z}_b$f"
			echo "$ipk saddr @z_${z}_open$f goto z_${z}_co"
		else
			echo "$ipk daddr @z_${z}_open$f goto z_${z}_co"
		fi
	fi
	echo "$ipk $peer @z_${z}_in$f return"
	echo "$ipk $peer @z_${z}_out$f goto z_${z}_x"
	[ "$Z_STRICT" = 1 ] && echo "goto z_${z}_x"
	echo "}"
}

emit_zone_chains() {
	local z="$1" proto lp rp pp f ipk sels sel osel isel src dst srcs dsts nl='
'
	case "$Z_PROTO" in
		udp) proto="meta l4proto udp";;
		tcp) proto="meta l4proto tcp";;
		*) proto="meta l4proto { tcp, udp }";;
	esac
	lp="$(port_set "$Z_LPORT")"
	rp="$(port_set "$Z_RPORT")"
	pp="$(port_set "$Z_PORT")"

	# port alternatives, each "outbound match|inbound match"
	sels=""
	[ -n "$lp$rp" ] && sels="$sels${nl}${lp:+th sport $lp }${rp:+th dport $rp}|${lp:+th dport $lp }${rp:+th sport $rp}"
	if [ -n "$pp" ]; then
		# either side: server port or device port
		sels="$sels${nl}th dport $pp|th sport $pp"
		sels="$sels${nl}th sport $pp th dport != $pp|th dport $pp th sport != $pp"
	fi
	if [ -z "$lp$rp$pp" ]; then
		sels="$sels${nl}|"
		log warning "zone $z: no ports set, ALL $Z_PROTO traffic of its devices is filtered"
	fi

	ZONE_JUMPS=""
	for f in 4 6; do
		[ "$f" = 4 ] && ipk=ip || ipk=ip6
		srcs=""; dsts=""
		eval "[ -n \"\$Z_DEV$f\" ]" && { srcs="$ipk saddr @z_${z}_dev$f"; dsts="$ipk daddr @z_${z}_dev$f"; }
		if [ -n "$Z_MACS" ]; then
			srcs="$srcs${srcs:+$nl}meta nfproto ipv$f ether saddr @z_${z}_mac"
			dsts="$dsts${dsts:+$nl}$ipk daddr @z_${z}_mip$f"
		fi
		[ -n "$srcs" ] || continue

		for sel in $(echo "$sels" | sed '/^$/d' | tr ' ' '\001'); do
			sel="$(echo "$sel" | tr '\001' ' ')"
			osel="${sel%%|*}"; isel="${sel#*|}"
			for src in $(echo "$srcs" | tr ' ' '\001'); do
				ZONE_JUMPS="$ZONE_JUMPS${nl}$(echo "$src" | tr '\001' ' ') $proto $osel jump z_${z}_o$f"
			done
			for dst in $(echo "$dsts" | tr ' ' '\001'); do
				ZONE_JUMPS="$ZONE_JUMPS${nl}$(echo "$dst" | tr '\001' ' ') $proto $isel jump z_${z}_i$f"
			done
		done
		emit_dir_chain "$z" "$f" o
		emit_dir_chain "$z" "$f" i
	done

	if [ "$Z_BURST" -gt 0 ]; then
		for f in 4 6; do
			[ "$f" = 4 ] && ipk=ip || ipk=ip6
			# a server that no longer fits into the size-limited burst set means
			# "more than Z_BURST servers at once": (re)open for this device
			echo "chain z_${z}_b$f {"
			echo "add @z_${z}_burst$f { $ipk daddr } return"
			echo "update @z_${z}_open$f { $ipk saddr }"
			echo "}"
		done
	fi

	# counts live in small chains: reading a chain is cheap, while reading a
	# named counter makes nft load every learned server first
	echo "chain z_${z}_cm {"
	echo "counter"
	echo "}"
	if [ "$Z_BURST" -gt 0 ]; then
		echo "chain z_${z}_co {"     # reached by goto: ends like the old "return"
		echo "counter"
		echo "}"
	fi
	echo "chain z_${z}_x {"
	[ "$G_LOG" = 1 ] && echo "limit rate 6/minute burst 3 packets log prefix \"lobbyfence $z: \" level info"
	echo "counter"
	[ "$Z_MODE" = enforce ] && echo "drop" || echo "return"
	echo "}"
}

# full ruleset + static elements + current classification -> $1
build_ruleset() {
	# servers stay in the "seen" sets for two learning passes (min. 2 minutes),
	# so "last seen" is accurate to about one pass
	SEEN_TIMEOUT=$((G_INTERVAL * 2)); [ "$SEEN_TIMEOUT" -ge 120 ] || SEEN_TIMEOUT=120
	# "active now": the device sent to the server within the last NOW_TIMEOUT seconds
	NOW_TIMEOUT=$LF_NOW_TIMEOUT
	local out="$1" z jumps="" body="$LF_RUN/chains.tmp" elems="$LF_RUN/elems.tmp" v a
	: > "$body"; : > "$elems"
	LAG_ZONES=""; local lagn=0
	for z in $ZONES_ON; do
		zone_load "$z"
		Z_LAG_MARK=""
		if [ "$Z_LAG" = 1 ] && [ "$lagn" -lt 127 ]; then
			lagn=$((lagn + 1))
			Z_LAG_MARK="$(printf '0x%08x' $((lagn << 24)))"
			LAG_ZONES="$LAG_ZONES $z:$lagn"
		fi
		Z_DEV4="$(addr_list 4 $Z_DEV)"; Z_DEV6="$(addr_list 6 $Z_DEV)"; Z_MACS="$(mac_list $Z_DEV)"
		if [ -z "$Z_DEV4$Z_DEV6$Z_MACS" ]; then
			log warning "zone $z: no valid device address, zone is inactive"
		fi
		emit_zone_sets "$z" >> "$body"
		emit_zone_chains "$z" >> "$body"
		jumps="$jumps$ZONE_JUMPS"
		[ "$Z_MODE" = enforce ] && [ "$Z_HAS_REGION" = 0 ] && \
			log warning "zone $z: no region drawn yet - every server is blocked except allow_ip"
		for v in 4 6; do
			eval "[ -n \"\$Z_DEV$v\" ] && echo \"add element inet $LF_TABLE z_${z}_dev$v { \$Z_DEV$v }\"" >> "$elems"
			[ "$v" = 4 ] && [ -n "$Z_MACS" ] && echo "add element inet $LF_TABLE z_${z}_mac { $Z_MACS }" >> "$elems"
			a="$(addr_list "$v" $Z_ALLOW)"; [ -n "$a" ] && echo "add element inet $LF_TABLE z_${z}_fa$v { $a }" >> "$elems"
			a="$(addr_list "$v" $Z_BLOCK)"; [ -n "$a" ] && echo "add element inet $LF_TABLE z_${z}_fb$v { $a }" >> "$elems"
		done
	done
	{
		echo "table inet $LF_TABLE"
		echo "delete table inet $LF_TABLE"
		echo "table inet $LF_TABLE {"
		echo "set priv4 { type ipv4_addr; flags interval; elements = { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/3 }; }"
		echo "set priv6 { type ipv6_addr; flags interval; elements = { ::/127, ::ffff:0:0/96, 2001:db8::/32, fc00::/7, fe80::/10, ff00::/8 }; }"
		cat "$body"
		echo "chain forward {"
		echo "type filter hook forward priority $G_PRIORITY; policy accept;"
		[ -n "$jumps" ] && echo "$jumps" | sed '/^$/d'
		echo "}"
		echo "}"
		cat "$elems"
	} > "$out"
	rm -f "$body" "$elems"
}

# the LAN devices the game's downloads leave through (towards the console/PC/phone)
lag_devs() {
	local a d f out="" z
	[ -n "$G_LAG_DEV" ] && { echo "$G_LAG_DEV"; return; }
	for z in "$@"; do
		for a in $(cat "$LF_RUN/$z.dev" 2>/dev/null); do
			# IPv4 and IPv6 (a device may only have IPv6); link-local has no useful route
			case "$a" in fe80:*|FE80:*) continue;; *:*) f=-6;; *) f=-4;; esac
			d="$($IPCMD $f route get "$a" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
			[ -n "$d" ] && case " $out " in *" $d "*) ;; *) out="$out $d";; esac
		done
	done
	[ -n "$out" ] || out="$(uci -q get network.lan.device)"
	[ -n "$out" ] || out=br-lan
	echo $out
}

# remove everything the lag simulator set up
lag_clear() {
	local d n
	for d in $(cat "$LF_RUN/lag.devs" 2>/dev/null); do
		$TC filter del dev "$d" egress pref $LAG_PREF 2>/dev/null
		$TC filter del dev "$d" ingress pref $LAG_PREF 2>/dev/null
		$TC filter del dev "$d" ingress pref $((LAG_PREF - 1)) 2>/dev/null
		$TC filter del dev "$d" ingress pref $((LAG_PREF - 2)) 2>/dev/null
		# drop the clsact hook only if LobbyFence added it and nothing else uses it
		if grep -qx "$d" "$LF_RUN/lag.clsact" 2>/dev/null && [ -z "$($TC filter show dev "$d" egress 2>/dev/null)" ] \
			&& [ -z "$($TC filter show dev "$d" ingress 2>/dev/null)" ]; then
			$TC qdisc del dev "$d" clsact 2>/dev/null
		fi
	done
	for n in $(cat "$LF_RUN/lag.ifbs" 2>/dev/null); do
		$IPCMD link del "$n" 2>/dev/null
	done
	rm -f "$LF_RUN/lag.devs" "$LF_RUN/lag.clsact" "$LF_RUN/lag.ifbs" "$LF_RUN/lag.ctinfo" "$LF_RUN/lag.addrs" "$LF_RUN"/lag.*.err
}

# the lag zones' device addresses (the upload hooks match them)
lag_addrs() {
	local zn
	for zn in $LAG_ZONES; do cat "$LF_RUN/${zn%%:*}.dev" 2>/dev/null; done
}

# netem arguments for the zone loaded with zone_load
lag_netem_args() {
	local a="limit 10000" dl="$Z_LAG_DELAY" jt="$Z_LAG_JITTER"
	# both ways: the packets pass the queue twice (out and back), so each pass
	# gets half - the extra ping still adds up to what was asked for
	if [ "$Z_LAG_DIR" = both ]; then dl=$((dl / 2)); jt=$((jt / 2)); fi
	if [ "$dl" -gt 0 ] || [ "$jt" -gt 0 ]; then
		a="$a delay ${dl}ms"
		[ "$jt" -gt 0 ] && a="$a ${jt}ms"
	fi
	case "$Z_LAG_LOSS" in *[1-9]*) a="$a loss ${Z_LAG_LOSS}%";; esac
	echo "$a"
}

# Each lag zone gets its own ifb device with a netem queue. A filter on the LAN
# device's egress hook (clsact - the device's normal queue and SQM are left alone)
# redirects packets carrying the zone's firewall mark into it.
lag_apply() {
	local zn z n ifb d devs="" err zones="" e a pf m pr
	lag_clear
	[ -n "$LAG_ZONES" ] || return 0
	lag_addrs > "$LF_RUN/lag.addrs"
	for zn in $LAG_ZONES; do zones="$zones ${zn%%:*}"; done
	if ! have "$TC"; then
		for z in $zones; do echo "notc" > "$LF_RUN/lag.$z.err"; done
		log warning "lag simulator needs the tc program (install tc-full)"
		return 1
	fi
	devs="$(lag_devs $zones)"
	for zn in $LAG_ZONES; do
		z="${zn%%:*}"; n="${zn#*:}"; ifb="lflag$n"
		zone_load "$z"
		err=""
		$IPCMD link del "$ifb" 2>/dev/null
		if ! e="$($IPCMD link add "$ifb" type ifb 2>&1)"; then
			err="noifb"
		else
			echo "$ifb" >> "$LF_RUN/lag.ifbs"
			$IPCMD link set "$ifb" up
			# shellcheck disable=SC2046
			if ! e="$($TC qdisc replace dev "$ifb" root netem $(lag_netem_args) 2>&1)"; then
				err="nonetem"
			fi
		fi
		if [ -z "$err" ]; then
			for d in $devs; do
				if ! $TC qdisc show dev "$d" 2>/dev/null | grep -q "qdisc clsact"; then
					if $TC qdisc add dev "$d" clsact 2>/dev/null; then
						echo "$d" >> "$LF_RUN/lag.clsact"
					else
						err="noclsact"; e="cannot add clsact to $d"; break
					fi
				fi
				grep -qx "$d" "$LF_RUN/lag.devs" 2>/dev/null || echo "$d" >> "$LF_RUN/lag.devs"
				if [ "$Z_LAG_DIR" != up ] && ! e="$($TC filter add dev "$d" egress pref $LAG_PREF protocol all \
					handle "$(printf '0x%x' $((n << 24)))/$LAG_MASK" fw action mirred egress redirect dev "$ifb" 2>&1)"; then
					err="nofilter"; break
				fi
				if [ "$Z_LAG_DIR" != down ]; then
					# uploads arrive before the firewall: copy the connection's mark onto
					# the packet first, then redirect like downloads. Only the zone's own
					# devices' packets: the copy replaces a packet's whole mark (other
					# programs may use it) and looks up its connection - work every
					# other device's traffic is spared
					for a in $(cat "$LF_RUN/$z.dev" 2>/dev/null); do
						case "$a" in
							fe80:*|FE80:*) continue;;   # (link-local: not game traffic)
							*:*) pf=ipv6; m="ip6 src $a"; pr=$((LAG_PREF - 2)); case "$a" in */*) ;; *) m="$m/128";; esac;;
							*) pf=ip; m="ip src $a"; pr=$((LAG_PREF - 1)); case "$a" in */*) ;; *) m="$m/32";; esac;;
						esac
						grep -qx "$d $a" "$LF_RUN/lag.ctinfo" 2>/dev/null && continue
						# shellcheck disable=SC2086
						if ! e="$($TC filter add dev "$d" ingress pref $pr protocol $pf \
							u32 match $m action ctinfo cpmark $LAG_MASK continue 2>&1)"; then
							err="noctinfo"; break 2
						fi
						echo "$d $a" >> "$LF_RUN/lag.ctinfo"
					done
					if ! e="$($TC filter add dev "$d" ingress pref $LAG_PREF protocol all \
						handle "$(printf '0x%x' $((n << 24)))/$LAG_MASK" fw action mirred egress redirect dev "$ifb" 2>&1)"; then
						err="nofilter"; break
					fi
				fi
			done
		fi
		if [ -n "$err" ]; then
			echo "$err" > "$LF_RUN/lag.$z.err"
			log warning "zone $z: lag simulator not active ($err): $(echo "$e" | head -n 1)"
		else
			log notice "zone $z: lag simulator on ($Z_LAG_DIR: $(lag_netem_args)) via $devs"
		fi
	done
}

# the LAN device can be recreated (network restart, Wi-Fi reload) and takes the
# lag filters with it: put them back if any went missing. A device that got
# another address (DHCP, a phone given by MAC) needs its upload hook anew.
lag_check() {
	local d
	[ -s "$LF_RUN/lag.devs" ] || return 0
	lag_zones
	if [ "$(lag_addrs)" != "$(cat "$LF_RUN/lag.addrs" 2>/dev/null)" ]; then
		log notice "lag simulator: a device's address changed - setting it up again"
		lag_apply
		return
	fi
	for d in $(cat "$LF_RUN/lag.devs"); do
		$IPCMD link show dev "$d" >/dev/null 2>&1 || continue   # gone for now: try again next pass
		$TC filter show dev "$d" egress pref $LAG_PREF 2>/dev/null | grep -q . && continue
		$TC filter show dev "$d" ingress pref $LAG_PREF 2>/dev/null | grep -q . && continue
		log notice "lag simulator hook on $d went missing (network restart?) - setting it up again"
		lag_apply
		return
	done
}

# zones with the lag simulator on, as "zone:index" (same order as build_ruleset)
lag_zones() {
	local z n=0
	LAG_ZONES=""
	for z in $ZONES_ON; do
		zone_load "$z"
		[ "$Z_LAG" = 1 ] && [ "$n" -lt 127 ] || continue
		n=$((n + 1))
		LAG_ZONES="$LAG_ZONES $z:$n"
	done
}

# Ask for the table's small fixed set: listing the table, its names or its
# counters makes nft load every learned server first (~70 ms at 20000 servers)
table_exists() { $NFT list set inet "$LF_TABLE" priv4 >/dev/null 2>&1; }

nft_apply() { # file
	if ! $NFT -f "$1" 2> "$LF_RUN/nft.err"; then
		log err "nft rejected $1: $(head -n 3 "$LF_RUN/nft.err" | tr '\n' ' ')"
		return 1
	fi
	rm -f "$LF_RUN/nft.err"
}

# seconds the zone stays open (longest remaining timeout in its open sets)
open_left() {
	{ $NFT list set inet "$LF_TABLE" "z_${1}_open4" 2>/dev/null; $NFT list set inet "$LF_TABLE" "z_${1}_open6" 2>/dev/null; } | lfawk expires
}

flow_offload() {
	[ "$(uci -q get firewall.@defaults[0].flow_offloading)" = 1 ] || [ "$(uci -q get firewall.@defaults[0].flow_offloading_hw)" = 1 ]
}

# every zone's counts (match / hit / opened) from its small counting chains:
# counters_load, then counter_of z_<zone>_<name>
counters_load() {
	local z c
	COUNTERS="$(for z in $ZONES_ON; do
		for c in cm:match x:hit co:opened; do
			echo "@z_${z}_${c#*:}"
			$NFT list chain inet "$LF_TABLE" "z_${z}_${c%%:*}" 2>/dev/null
		done
	done | awk '/^@/ { n = substr($1, 2); v[n] = 0; o[++k] = n; next }
		/counter packets/ { for (i = 1; i < NF; i++) if ($i == "packets") v[n] += $(i + 1) }
		END { for (i = 1; i <= k; i++) print o[i], v[o[i]] }')"
}

# ---------------------------------------------------------------- backend API

fw_exists() { table_exists; }

# rules (and the static sets) -> $FW_RULES
fw_build() { build_ruleset "$FW_RULES"; }

# load rules + learned sets ($FW_SETS) in one transaction
fw_commit() {
	cat "$FW_SETS" >> "$FW_RULES"
	nft_apply "$FW_RULES"
}

fw_post_apply() {
	# per-connection packet counts (OpenWrt has them off): Ports seen's packet
	# column and the packets/s of "active now" servers
	[ -w /proc/sys/net/netfilter/nf_conntrack_acct ] && [ "$(cat /proc/sys/net/netfilter/nf_conntrack_acct)" != 1 ] && \
		echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct
	lag_apply
}

fw_remove() {
	table_exists && $NFT delete table inet "$LF_TABLE"
	lag_clear
}

# once per learning pass
fw_check() { lag_check; }

# set commands refreshing a zone's in/out sets from $LF_RUN/<zone>.servers
fw_zone_servers() { lfawk elements -v t="$LF_TABLE" -v p="z_$1" < "$LF_RUN/$1.servers"; }

# set commands for the current addresses of a zone's MAC devices ($LF_RUN/<zone>.mip)
fw_zone_mip() {
	local z="$1" a4 a6
	a4="$(grep -v ':' "$LF_RUN/$z.mip" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
	a6="$(grep ':' "$LF_RUN/$z.mip" | tr '\n' ',' | sed 's/,$//; s/,/, /g')"
	echo "flush set inet $LF_TABLE z_${z}_mip4"
	echo "flush set inet $LF_TABLE z_${z}_mip6"
	[ -n "$a4" ] && echo "add element inet $LF_TABLE z_${z}_mip4 { $a4 }"
	[ -n "$a6" ] && echo "add element inet $LF_TABLE z_${z}_mip6 { $a6 }"
	return 0
}

# apply set commands written by fw_zone_servers / fw_zone_mip
fw_load_sets() { [ -s "$1" ] && table_exists && nft_apply "$1"; }

# public addresses in a zone's "seen" sets, one per line
fw_seen() {
	{
		$NFT list set inet "$LF_TABLE" "z_${1}_seen4" 2>/dev/null
		$NFT list set inet "$LF_TABLE" "z_${1}_seen6" 2>/dev/null
	} | lfawk harvest
}

# "<addr> <seconds since the device last sent to it> <packets>" for servers active now
fw_now() {
	{ $NFT list set inet "$LF_TABLE" "z_${1}_now4" 2>/dev/null; $NFT list set inet "$LF_TABLE" "z_${1}_now6" 2>/dev/null; } | \
		lfawk ages -v window="$LF_NOW_TIMEOUT"
}

fw_open_left() { open_left "$1"; }

# swap a zone's allow/block sets for the current configuration (zone_load done)
fw_override() {
	local z="$1" f a
	: > "$LF_RUN/override.nft"
	for f in 4 6; do
		echo "flush set inet $LF_TABLE z_${z}_fa$f" >> "$LF_RUN/override.nft"
		echo "flush set inet $LF_TABLE z_${z}_fb$f" >> "$LF_RUN/override.nft"
		a="$(addr_list "$f" $Z_ALLOW)"; [ -n "$a" ] && echo "add element inet $LF_TABLE z_${z}_fa$f { $a }" >> "$LF_RUN/override.nft"
		a="$(addr_list "$f" $Z_BLOCK)"; [ -n "$a" ] && echo "add element inet $LF_TABLE z_${z}_fb$f { $a }" >> "$LF_RUN/override.nft"
	done
	nft_apply "$LF_RUN/override.nft" || return 1
	rm -f "$LF_RUN/override.nft"
}

# platform fields for status.json
fw_status_json() {
	printf '"platform":"openwrt","lag_supported":true,'
	printf '"offload":%s,"conntrack":%s,' "$(flow_offload && echo true || echo false)" "$(have conntrack && echo true || echo false)"
	printf '"tc":%s,"pkg":"%s",' "$(have "$TC" && echo true || echo false)" "$(have apk && echo apk || echo opkg)"
}

# for the debug report: the table without the (long) server lists, offloading, lag, packages
fw_debug() {
	echo "nftables table inet $LF_TABLE (server lists left out):"
	$NFT -t list table inet "$LF_TABLE" 2>&1 | head -n 400
	echo
	echo "flow offloading: software $(uci -q get firewall.@defaults[0].flow_offloading || echo 0), hardware $(uci -q get firewall.@defaults[0].flow_offloading_hw || echo 0)"
	have "$TC" && { echo "traffic control (lag simulator):"; $TC qdisc show 2>&1 | head -n 40; }
	echo "packages:"
	if have apk; then apk list -I 2>/dev/null; elif have opkg; then opkg list-installed 2>/dev/null; fi | \
		grep -E '^(lobbyfence|luci-app-lobbyfence|nftables|kmod-sched|kmod-nft|tc|conntrack|curl|firewall4)' | sed 's/^/  /'
}
