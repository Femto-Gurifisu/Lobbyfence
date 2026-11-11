# LobbyFence firewall backend: iptables + ipset (FreshTomato)
# Sourced by the lobbyfence script - see "firewall backend" there for the API.
#
# Learned servers live in ipsets (hash:ip), the rules in a few small chains
# (LF_*) hooked into FORWARD. Tomato rebuilds its firewall from scratch now
# and then (WAN reconnect, settings saved): the sets survive that, and the
# "Firewall" script hook ("lobbyfence fwhook") puts the chains back.
#
# SPDX-License-Identifier: GPL-3.0-or-later

IPT_BIN="${LF_IPT:-iptables}"
IP6T_BIN="${LF_IP6T:-ip6tables}"
IPT_RESTORE_BIN="${LF_IPT_RESTORE:-iptables-restore}"
IP6T_RESTORE_BIN="${LF_IP6T_RESTORE:-ip6tables-restore}"
# every call goes through xt_run (below): it waits out the xtables lock
IPT=lf_ipt4
IP6T=lf_ipt6
IPT_RESTORE=lf_iptr4
IP6T_RESTORE=lf_iptr6
IPSET="${LF_IPSET:-ipset}"
LF_CONNTRACK="${LF_CONNTRACK:-/proc/net/nf_conntrack}"
# lag simulator: FreshTomato's kernel has no netem built in; LobbyFence brings
# the module, built from FreshTomato's own kernel source for its kernel version
TC="${LF_TC:-tc}"
IPCMD="${LF_IP:-ip}"
LAG_MASK=0x7f000000
LAG_HANDLE=7a
LF_NETEM_KO="${LF_NETEM_KO:-${LF_HOME:-/jffs/lobbyfence}/modules/$(uname -r 2>/dev/null)/sch_netem.ko}"
# netem is guarded on every boot it is used: the guard file (holding this
# boot's id) is written before the module is loaded and stays while the lag
# queues are up; a clean stop (lag switched off, LobbyFence stopped, the
# router shut down properly) takes it away. A guard left over from an earlier
# boot means the router restarted while netem was in use - maybe the module
# crashed it: it is never loaded again by itself, so a module that crashes a
# router (a new firmware with the same kernel version, say) does so once, not
# on every boot. .netem-ok records the kernel build and module netem has
# carried traffic with for LF_NETEM_TRIAL seconds (for the page).
LF_NETEM_GUARD="${LF_NETEM_GUARD:-${LF_HOME:-/jffs/lobbyfence}/.netem-loading}"
LF_NETEM_OK="${LF_NETEM_OK:-${LF_HOME:-/jffs/lobbyfence}/.netem-ok}"
LF_NETEM_TRIAL="${LF_NETEM_TRIAL:-120}"
LF_BOOT_ID="${LF_BOOT_ID:-/proc/sys/kernel/random/boot_id}"
LAG_SUPPORTED=0
if [ -f "$LF_NETEM_KO" ] || grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null; then LAG_SUPPORTED=1; fi
# ipset names hold 31 characters, iptables chain names 28: lf_<zone>_burst4_t
LF_ZONE_MAXLEN=16
FW_RULES="$LF_RUN/rules"
FW_SETS="$LF_RUN/sets.ipset"
# Broadcom CTF (hardware NAT acceleration) leaves alone connections whose
# packets carry this mark - the same bypass FreshTomato uses for its VPNs
CTF_MARK="0x01/0x7"

# --------------------------------------------------------------- helpers

# The system's own firewall scripts (a firewall rebuild, UPnP, a VPN) hold the
# xtables lock for a moment at a time. Depending on the build, iptables then
# fails at once ("Another app is currently holding the xtables lock"), or
# waits - for good. Every LobbyFence call waits a bounded time instead:
# with "-w <seconds>" where iptables has it, else tried again once a second;
# up to LF_XT_WAIT seconds (15), then the command's own error is reported.
# Once a wait has run out, calls in the next 30 s barely wait, so a lock
# that is never let go costs one wait, not one per command.
xt_wait_opt() { # binary -> 1 when it has "-w <seconds>" (checked once per boot)
	local k="$LF_RUN/xtw.$(echo "${1##*/}" | tr -c 'A-Za-z0-9\n' '_')" v=""
	if [ ! -f "$k" ]; then
		if "$1" -h 2>&1 | grep -q -e '-w \[seconds\]' -e '--wait=<seconds>'; then echo 1 > "$k"; else echo 0 > "$k"; fi
	fi
	read -r v 2>/dev/null < "$k"
	[ "$v" = 1 ]
}
xt_run() { # binary args...   (stdin: from the file in $XT_IN, so a retry gets it again)
	local bin="$1" i=0 rc e="$LF_RUN/xt.err.$$" g="$LF_RUN/xt.gaveup.$$" t wait="${LF_XT_WAIT:-15}" native=0
	shift
	# (no RAM folder yet - a status or debug report before the first start: as it is)
	if [ ! -d "$LF_RUN" ]; then
		if [ -n "$XT_IN" ]; then "$bin" "$@" < "$XT_IN"; else "$bin" "$@"; fi
		return
	fi
	is_uint "$wait" || wait=15
	if [ -f "$g" ]; then
		read -r t 2>/dev/null < "$g"
		[ $(( $(date +%s) - ${t:-0} )) -lt 30 ] 2>/dev/null && wait=1
	fi
	xt_wait_opt "$bin" && native=1
	while :; do
		if [ "$native" = 1 ]; then
			if [ -n "$XT_IN" ]; then "$bin" -w "$wait" "$@" < "$XT_IN" 2> "$e"; else "$bin" -w "$wait" "$@" 2> "$e"; fi
		else
			if [ -n "$XT_IN" ]; then "$bin" "$@" < "$XT_IN" 2> "$e"; else "$bin" "$@" 2> "$e"; fi
		fi
		rc=$?
		if [ "$rc" -eq 0 ]; then
			[ -f "$g" ] && rm -f "$g"
			break
		fi
		grep -q 'xtables lock' "$e" 2>/dev/null || break
		if [ "$native" = 1 ] || [ "$i" -ge "$wait" ]; then
			date +%s > "$g"
			break
		fi
		i=$((i + 1))
		sleep 1
	done
	cat "$e" >&2 2>/dev/null
	rm -f "$e"
	return "$rc"
}
lf_ipt4() { xt_run "$IPT_BIN" "$@"; }
lf_ipt6() { xt_run "$IP6T_BIN" "$@"; }
lf_iptr() { # binary args... < rules
	local in="$LF_RUN/xt.in.$$" rc
	[ -d "$LF_RUN" ] || { "$@"; return; }
	cat > "$in"
	XT_IN="$in"
	xt_run "$@"
	rc=$?
	XT_IN=""
	rm -f "$in"
	return "$rc"
}
lf_iptr4() { lf_iptr "$IPT_RESTORE_BIN" "$@"; }
lf_iptr6() { lf_iptr "$IP6T_RESTORE_BIN" "$@"; }

# IPv6 filtering: only when the router does IPv6 (LF_IPV6=0|1 overrides)
fw_v6() {
	if [ -z "$FW_V6" ]; then
		[ -f "$LF_RUN/v6.off" ] && FW_V6=0
	fi
	if [ -z "$FW_V6" ]; then
		case "${LF_IPV6:-auto}" in
			0) FW_V6=0;;
			1) FW_V6=1;;
			*) FW_V6=0
			   [ -f /proc/net/if_inet6 ] && have "$IP6T_BIN" && \
				$IP6T -n -L FORWARD >/dev/null 2>&1 && FW_V6=1;;
		esac
	fi
	[ "$FW_V6" = 1 ]
}

fw_families() { fw_v6 && echo "4 6" || echo 4; }

fw_modules() {
	[ -f "$LF_RUN/.modules" ] && return 0
	local m
	for m in ip_set ip_set_hash_ip ip_set_hash_net xt_set; do
		modprobe "$m" >/dev/null 2>&1
	done
	: > "$LF_RUN/.modules"
}

# CTF bypass wanted: CTF on (ctf_disable=0) and QoS off (QoS turns CTF off
# and uses the packet marks itself). LF_CTF=0|1 overrides.
fw_ctf() {
	case "${LF_CTF:-auto}" in 0) return 1;; 1) return 0;; esac
	have nvram || return 1
	[ "$(nvram get ctf_disable 2>/dev/null)" = 0 ] && [ "$(nvram get qos_enable 2>/dev/null)" != 1 ]
}

ipt_of() { [ "$1" = 6 ] && echo "$IP6T" || echo "$IPT"; }
ipset_fam() { [ "$1" = 6 ] && echo inet6 || echo inet; }

# load an iptables-restore file without touching anyone else's rules
ipt_restore() { # 4|6 file [quiet]
	local r="$IPT_RESTORE"
	[ "$1" = 6 ] && r="$IP6T_RESTORE"
	if ! $r -n < "$2" 2> "$LF_RUN/ipt.err"; then
		[ -n "$3" ] || log err "iptables-restore rejected $2: $(head -n 3 "$LF_RUN/ipt.err" | tr '\n' ' ')"
		return 1
	fi
	rm -f "$LF_RUN/ipt.err"
}

# what a refused rules file was refused for, in one line: the tool's message
# and - when it names a line - that line of the file
ipt_err_text() { # file
	local n
	n="$(sed -n 's/.*line \([0-9][0-9]*\) failed.*/\1/p' "$LF_RUN/ipt.err" 2>/dev/null | head -n 1)"
	printf '%s' "$(head -n 2 "$LF_RUN/ipt.err" 2>/dev/null | tr '\n' ' ')"
	is_uint "$n" && printf '(line %s of the rules: %s)' "$n" "$(sed -n "${n}p" "$1" 2>/dev/null)"
}

# IPv6 rules for what this firmware's ip6tables can do -> the file to load
#   v6.noset  no SET target (some FreshTomato builds): the lines that add
#             servers to sets go, and what only works through them - the
#             "open for server tests" burst (its jump on new connections, the
#             checks of its set). IPv6 servers are then learned from the
#             connection table (v6_from_conntrack).
#   v6.noct   no connection-state match (IPv6 is switched off in the firmware,
#             so its connection tracking isn't loaded): the lines with it go
ipt_v6_file() { # file
	if [ -f "$LF_RUN/v6.noset" ]; then
		sed -e '/ -j SET /d' -e '/ -m conntrack /d' -e '/ --match-set lf_[A-Za-z0-9_]*_op6 /d' "$1" > "$1.noset"
		echo "$1.noset"
	elif [ -f "$LF_RUN/v6.noct" ]; then
		sed '/ -m conntrack /d' "$1" > "$1.noct"
		echo "$1.noct"
	else
		echo "$1"
	fi
}

# load one family's rules file. When ip6tables refuses the IPv6 rules, they
# are tried again without what it can't do (ipt_v6_file); what is left still
# filters. Strict zones drop new IPv6 servers before they reach the connection
# table, so without the SET target the game uses IPv4 there. IPv6 problems
# never stop IPv4.
ipt_load() { # 4|6 file
	local f="$1" file="$2" try
	if [ "$f" != 6 ]; then
		ipt_restore 4 "$file" quiet && return 0
		log err "iptables-restore rejected $file: $(ipt_err_text "$file")"
		return 1
	fi
	try="$(ipt_v6_file "$file")"
	ipt_restore 6 "$try" quiet && { rm -f "$LF_RUN/v6.refused"; return 0; }
	if [ ! -f "$LF_RUN/v6.noset" ] && grep -q "SET" "$LF_RUN/ipt.err" 2>/dev/null; then
		: > "$LF_RUN/v6.noset"
		try="$(ipt_v6_file "$file")"
		if ipt_restore 6 "$try" quiet; then
			log warning "IPv6: this firmware's ip6tables can't add servers to ipsets - IPv6 game servers are learned from the connection list instead (strict zones block new IPv6 servers before they can be learned, so the game uses IPv4 there)"
			rm -f "$LF_RUN/v6.refused"
			return 0
		fi
		rm -f "$LF_RUN/v6.noset"
	elif [ ! -f "$LF_RUN/v6.noset" ] && [ ! -f "$LF_RUN/v6.noct" ]; then
		: > "$LF_RUN/v6.noct"
		try="$(ipt_v6_file "$file")"
		if ipt_restore 6 "$try" quiet; then
			log warning "IPv6: this firmware's ip6tables refuses rules that look at the state of a connection (IPv6 switched off in the firmware?) - IPv6 is filtered without them: servers that contact the device first are not learned, and \"open for server tests\" does not open IPv6"
			rm -f "$LF_RUN/v6.refused"
			return 0
		fi
		rm -f "$LF_RUN/v6.noct"
	fi
	log err "IPv6 rules rejected - IPv6 traffic is not filtered: $(ipt_err_text "$try")"
	# for the debug report: what was refused, and what the kernel said
	{
		echo "refused $(date '+%F %T' 2>/dev/null): $(ipt_err_text "$try")"
		echo "kernel messages (last 5):"
		dmesg 2>/dev/null | tail -n 5 | sed 's/^/  /'
		echo "the rules:"
		awk '{ printf "%4d  %s\n", NR, $0 }' "$try" 2>/dev/null | head -n 120
	} > "$LF_RUN/v6.refused" 2>/dev/null
	: > "$LF_RUN/v6.off"
	ipt_remove 6
	return 0
}

ipset_restore() { # file
	[ -s "$1" ] || return 0
	if ! $IPSET -exist restore < "$1" 2> "$LF_RUN/ipset.err"; then
		log err "ipset rejected $1: $(head -n 3 "$LF_RUN/ipset.err" | tr '\n' ' ')"
		return 1
	fi
	rm -f "$LF_RUN/ipset.err"
}

# "a, b, c" (addr_list / mac_list output) -> one per line
one_per_line() { echo "$1" | tr ',' '\n' | sed 's/^ *//; /^$/d'; }

# restore commands that give set $1 exactly the members on stdin (swap: no gap)
ipset_fill() { # name type family
	local n="$1" t="$2" fa="$3" a
	echo "create $n $t family $fa"
	echo "create ${n}_t $t family $fa"
	echo "flush ${n}_t"
	while read -r a; do [ -n "$a" ] && echo "add ${n}_t $a"; done
	echo "swap ${n}_t $n"
	echo "destroy ${n}_t"
}

# a set with timeouts: kept (with its contents) while its parameters are the
# same, otherwise replaced by a fresh one
ipset_timed() { # name family maxelem timeout
	local n="$1" fa="$2" mx="$3" to="$4" cur
	echo "$n" >> "$LF_RUN/sets.want"
	cur="$(awk -v n="$n" '$1 == n { print $2, $3, $4 }' "$LF_RUN/sets.have")"
	if [ "$cur" = "$fa $mx $to" ]; then
		return 0
	elif [ -n "$cur" ]; then
		echo "create ${n}_t hash:ip family $fa maxelem $mx timeout $to"
		echo "swap ${n}_t $n"
		echo "destroy ${n}_t"
	else
		echo "create $n hash:ip family $fa maxelem $mx timeout $to"
	fi
}

ipset_want() { echo "$1" >> "$LF_RUN/sets.want"; }

# "3074 3075-3079" -> multiport lists of at most 15 ports (a range counts 2)
port_chunks() {
	local out="" w=0 t a b c
	for t in $(echo "$1" | tr ',' ' '); do
		case "$t" in
			*[!0-9-]*|-*|*-|*-*-*) log warning "zone $Z_ID: ignoring bad port '$t'"; continue;;
		esac
		a="${t%-*}"; b="${t#*-}"
		num_fix a b
		if [ "$a" -lt 1 ] || [ "$b" -gt 65535 ] || [ "$b" -lt "$a" ]; then
			log warning "zone $Z_ID: ignoring bad port '$t'"; continue
		fi
		[ "$a" = "$b" ] && { c=1; t="$a"; } || { c=2; t="$a:$b"; }
		if [ $((w + c)) -gt 15 ]; then echo "$out"; out=""; w=0; fi
		out="${out:+$out,}$t"; w=$((w + c))
	done
	[ -n "$out" ] && echo "$out"
	return 0
}

# --------------------------------------------------------------- rules

# the zone's game ports: rules sending the device's outgoing packets from
# chain $1 to $3 and its incoming ones from $2 to $4 (each packet once)
ipt_port_rules() { # out-chain in-chain out-target in-target
	local po="$1" pi="$2" go="$3" gi="$4" protos p lp rp pp l r
	case "$Z_PROTO" in udp) protos=udp;; tcp) protos=tcp;; *) protos="udp tcp";; esac
	lp="$(port_chunks "$Z_LPORT")"; rp="$(port_chunks "$Z_RPORT")"; pp="$(port_chunks "$Z_PORT")"
	for p in $protos; do
		if [ -n "$lp$rp" ]; then
			for l in ${lp:-ANY}; do for r in ${rp:-ANY}; do
				echo "-A $po -p $p$( [ "$l" = ANY ] || echo " -m multiport --sports $l")$( [ "$r" = ANY ] || echo " -m multiport --dports $r") -g $go"
				echo "-A $pi -p $p$( [ "$l" = ANY ] || echo " -m multiport --dports $l")$( [ "$r" = ANY ] || echo " -m multiport --sports $r") -g $gi"
			done; done
		fi
		# either side: server port or device port
		for l in $pp; do echo "-A $po -p $p -m multiport --dports $l -g $go"; echo "-A $pi -p $p -m multiport --sports $l -g $gi"; done
		for l in $pp; do echo "-A $po -p $p -m multiport --sports $l -g $go"; echo "-A $pi -p $p -m multiport --dports $l -g $gi"; done
		[ -z "$lp$rp$pp" ] && { echo "-A $po -p $p -g $go"; echo "-A $pi -p $p -g $gi"; }
	done
}

# rules sending the zone's devices' packets to chains $1 (from the device)
# and $2 (to the device) -> stdout
ipt_dev_rules() { # parent out-chain in-chain family
	local s="lf_$Z_ID" f="$4" d mac
	eval "d=\"\$Z_DEV$f\""
	[ -n "$d" ] && { echo "-A $1 -m set --match-set ${s}_dev$f src -j $2"; echo "-A $1 -m set --match-set ${s}_dev$f dst -j $3"; }
	if [ -n "$Z_MACS" ]; then
		for mac in $(one_per_line "$Z_MACS"); do echo "-A $1 -m mac --mac-source $mac -j $2"; done
		echo "-A $1 -m set --match-set ${s}_mip$f dst -j $3"
	fi
	return 0
}

# chains and rules of one zone for one family -> stdout (zone_load done)
ipt_zone() { # zone family
	local z="$1" f="$2" s="lf_$1" c="LF_$1" p lp rp pp sk
	lp="$(port_chunks "$Z_LPORT")"; rp="$(port_chunks "$Z_RPORT")"; pp="$(port_chunks "$Z_PORT")"
	[ -n "$lp$rp$pp" ] || log warning "zone $z: no ports set, ALL $Z_PROTO traffic of its devices is filtered"

	for p in po pi o i cm x; do echo ":${c}_$p$( [ "$p" = cm ] || [ "$p" = x ] || echo "$f") - [0:0]"; done
	[ "$Z_BURST" -gt 0 ] && { echo ":${c}_b$f - [0:0]"; echo ":${c}_co - [0:0]"; }

	# which packets belong to the zone: its devices and their game ports
	ipt_dev_rules LF_FWD "${c}_po$f" "${c}_pi$f" "$f"
	ipt_port_rules "${c}_po$f" "${c}_pi$f" "${c}_o$f" "${c}_i$f"

	# outbound (device -> server)
	echo "-A ${c}_o$f -m set --match-set lf_priv$f dst -j RETURN"
	# hardware acceleration would let the game's later packets skip all this
	# (FW_SKIP4 / FW_SKIP6: a target that keeps the flow out of it, if any)
	eval "sk=\"\$FW_SKIP$f\""
	[ -n "$sk" ] && echo "-A ${c}_o$f -j $sk"
	# lag simulator: the game's packets get the zone's mark, tc sends marked
	# packets through netem (uploads on the WAN side, downloads on the LAN side)
	[ -n "$Z_LAG_MARK" ] && [ "$Z_LAG_DIR" != down ] && echo "-A ${c}_o$f -j MARK --set-xmark $Z_LAG_MARK/$LAG_MASK"
	echo "-A ${c}_o$f -j ${c}_cm"
	# "active now": the device sent to this server within the last seconds;
	# every packet keeps the server "seen" (long matches stay current)
	echo "-A ${c}_o$f -j SET --add-set ${s}_now$f dst --exist"
	echo "-A ${c}_o$f -j SET --add-set ${s}_seen$f dst --exist"
	echo "-A ${c}_o$f -m set --match-set ${s}_fa$f dst -j RETURN"
	echo "-A ${c}_o$f -m set --match-set ${s}_fb$f dst -g ${c}_x"
	if [ "$Z_BURST" -gt 0 ]; then
		echo "-A ${c}_o$f -m conntrack --ctstate NEW -j ${c}_b$f"
		echo "-A ${c}_o$f -m set --match-set ${s}_op$f src -g ${c}_co"
	fi
	echo "-A ${c}_o$f -m set --match-set ${s}_in$f dst -j RETURN"
	echo "-A ${c}_o$f -m set --match-set ${s}_out$f dst -g ${c}_x"
	echo "-A ${c}_o$f -j SET --add-set ${s}_nw$f dst --exist"
	[ "$Z_STRICT" = 1 ] && echo "-A ${c}_o$f -g ${c}_x"

	# inbound (server -> device): new connections count as "seen"
	echo "-A ${c}_i$f -m set --match-set lf_priv$f src -j RETURN"
	[ -n "$sk" ] && echo "-A ${c}_i$f -j $sk"
	[ -n "$Z_LAG_MARK" ] && [ "$Z_LAG_DIR" != up ] && echo "-A ${c}_i$f -j MARK --set-xmark $Z_LAG_MARK/$LAG_MASK"
	echo "-A ${c}_i$f -j ${c}_cm"
	echo "-A ${c}_i$f -m conntrack --ctstate NEW -j SET --add-set ${s}_seen$f src --exist"
	echo "-A ${c}_i$f -m set --match-set ${s}_fa$f src -j RETURN"
	echo "-A ${c}_i$f -m set --match-set ${s}_fb$f src -g ${c}_x"
	[ "$Z_BURST" -gt 0 ] && echo "-A ${c}_i$f -m set --match-set ${s}_op$f dst -g ${c}_co"
	echo "-A ${c}_i$f -m set --match-set ${s}_in$f src -j RETURN"
	echo "-A ${c}_i$f -m set --match-set ${s}_out$f src -g ${c}_x"
	echo "-A ${c}_i$f -m conntrack --ctstate NEW -j SET --add-set ${s}_nw$f src --exist"
	[ "$Z_STRICT" = 1 ] && echo "-A ${c}_i$f -g ${c}_x"

	# "open for server tests": a new server that no longer fits into the
	# size-limited burst set means "more than N servers at once" - (re)open
	if [ "$Z_BURST" -gt 0 ]; then
		echo "-A ${c}_b$f -j SET --add-set ${s}_bu$f dst"
		echo "-A ${c}_b$f -m set ! --match-set ${s}_bu$f dst -j SET --add-set ${s}_op$f src --exist"
		echo "-A ${c}_co -j RETURN"
	fi
	# counting chains: their last rule carries the count
	echo "-A ${c}_cm -j RETURN"
	[ "$G_LOG" = 1 ] && echo "-A ${c}_x -m limit --limit 6/min --limit-burst 3 -j LOG --log-prefix \"lobbyfence $z: \" --log-level 6"
	[ "$Z_MODE" = enforce ] && echo "-A ${c}_x -j DROP" || echo "-A ${c}_x -j RETURN"
}

# the zone's sets (static ones filled, the others kept) -> stdout
ipset_zone() { # zone family
	local f="$2" s="lf_$1" fa
	fa="$(ipset_fam "$f")"
	eval "one_per_line \"\$Z_DEV$f\"" | ipset_fill "${s}_dev$f" hash:net "$fa"
	one_per_line "$(addr_list "$f" $Z_ALLOW)" | ipset_fill "${s}_fa$f" hash:net "$fa"
	one_per_line "$(addr_list "$f" $Z_BLOCK)" | ipset_fill "${s}_fb$f" hash:net "$fa"
	ipset_want "${s}_dev$f"; ipset_want "${s}_fa$f"; ipset_want "${s}_fb$f"
	# filled by refresh_sets: created here when missing
	echo "create ${s}_mip$f hash:ip family $fa"
	echo "create ${s}_in$f hash:ip family $fa maxelem 262144"
	echo "create ${s}_out$f hash:ip family $fa maxelem 262144"
	ipset_want "${s}_mip$f"; ipset_want "${s}_in$f"; ipset_want "${s}_out$f"
	ipset_timed "${s}_seen$f" "$fa" 65536 "$SEEN_TIMEOUT"
	ipset_timed "${s}_now$f" "$fa" 65536 "$LF_NOW_TIMEOUT"
	# servers the zone knows nothing about yet (not inside, outside or listed):
	# the learning loop's quick check every 2 s - emptied by each learning pass
	ipset_timed "${s}_nw$f" "$fa" 65536 "$SEEN_TIMEOUT"
	if [ "$Z_BURST" -gt 0 ]; then
		ipset_timed "${s}_bu$f" "$fa" "$Z_BURST" "$Z_BURST_WIN"
		ipset_timed "${s}_op$f" "$fa" 1024 "$Z_BURST_OPEN"
	fi
}

# CTF bypass for the zone's devices (mangle table)
ipt_ctf_zone() { # zone family
	local f="$2" s="lf_$1" d mac
	eval "d=\"\$Z_DEV$f\""
	[ -n "$d" ] && { echo "-A LF_CTF_IN -m set --match-set ${s}_dev$f src -j MARK --set-mark $CTF_MARK"; echo "-A LF_CTF_OUT -m set --match-set ${s}_dev$f dst -j MARK --set-mark $CTF_MARK"; }
	if [ -n "$Z_MACS" ]; then
		for mac in $(one_per_line "$Z_MACS"); do echo "-A LF_CTF_IN -m mac --mac-source $mac -j MARK --set-mark $CTF_MARK"; done
		echo "-A LF_CTF_OUT -m set --match-set ${s}_mip$f dst -j MARK --set-mark $CTF_MARK"
	fi
}

# LobbyFence's chains that exist right now in a table: ipt_chains 4|6 filter|mangle
ipt_chains() { $(ipt_of "$1") -t "$2" -S 2>/dev/null | awk '$1 == "-N" && $2 ~ /^LF_/ { print $2 }'; }

# the iptables-restore lines that leave exactly <want> (0|1) jumps from a
# built-in chain to one of LobbyFence's: counted, not just checked - a jump
# added twice (two applies at once, a check that failed on the xtables lock)
# would otherwise stay behind when LobbyFence is stopped. Nothing is changed
# when iptables can't be asked.   ipt_jump 4|6 table chain target want
ipt_jump() {
	local out n
	out="$($(ipt_of "$1") -t "$2" -S "$3" 2>/dev/null)" || return 0
	n="$(printf '%s\n' "$out" | grep -c -x -- "-A $3 -j $4")"
	if [ "${n:-0}" -lt "$5" ]; then
		echo "-I $3 1 -j $4"
	else
		while [ "$n" -gt "$5" ]; do echo "-D $3 -j $4"; n=$((n - 1)); done
	fi
}

# (re)write the rules files for every family -> $FW_RULES.<4|6>
ipt_rules() {
	local f z cmd ctf=0 old want
	fw_ctf && ctf=1
	fw_prepare
	ipt_lag_zones
	for f in $(fw_families); do
		cmd="$(ipt_of "$f")"
		want="$LF_RUN/chains.want"
		{
			echo "*filter"
			echo ":LF_FWD - [0:0]"
			for z in $ZONES_ON; do
				zone_load "$z"
				Z_DEV4="$(addr_list 4 $Z_DEV)"; Z_DEV6="$(addr_list 6 $Z_DEV)"; Z_MACS="$(mac_list $Z_DEV)"
				Z_LAG_MARK="$(ipt_lag_mark "$z")"
				ipt_zone "$z" "$f"
			done > "$LF_RUN/zone.rules"
			awk '/^:/ { print substr($1, 2) }' "$LF_RUN/zone.rules" > "$want"
			echo LF_FWD >> "$want"
			# chains of zones that are gone: emptied, then removed below
			for old in $(ipt_chains "$f" filter); do grep -qx "$old" "$want" || echo ":$old - [0:0]"; done
			cat "$LF_RUN/zone.rules"
			ipt_jump "$f" filter FORWARD LF_FWD 1
			for old in $(ipt_chains "$f" filter); do grep -qx "$old" "$want" || echo "-X $old"; done
			echo "COMMIT"
			# (some firmware has no mangle table for IPv6)
			$cmd -t mangle -n -L FORWARD >/dev/null 2>&1 && ipt_mangle "$f" "$ctf"
		} > "$FW_RULES.$f"
	done
	rm -f "$LF_RUN/zone.rules" "$want"
}

# the mangle table: CTF bypass chains (FreshTomato) and what the platform adds
# (fw_mangle_extra: chain lines and rules on stdout, its hooks in MANGLE_HOOKS
# as "BUILTIN:CHAIN ..."); LobbyFence chains no longer wanted are taken out
ipt_mangle() { # family ctf
	local f="$1" ctf="$2" body="$LF_RUN/mangle.rules" want="$LF_RUN/mchains.want" z old h b
	MANGLE_HOOKS=""
	{
		if [ "$ctf" = 1 ]; then
			echo ":LF_CTF_IN - [0:0]"
			echo ":LF_CTF_OUT - [0:0]"
			for z in $ZONES_ON; do
				zone_load "$z"
				Z_DEV4="$(addr_list 4 $Z_DEV)"; Z_DEV6="$(addr_list 6 $Z_DEV)"; Z_MACS="$(mac_list $Z_DEV)"
				ipt_ctf_zone "$z" "$f"
			done
			MANGLE_HOOKS="PREROUTING:LF_CTF_IN POSTROUTING:LF_CTF_OUT"
		fi
		fw_mangle_extra "$f"
	} > "$body"
	awk '/^:/ { print substr($1, 2) }' "$body" > "$want"
	echo "*mangle"
	for old in $(ipt_chains "$f" mangle); do grep -qx "$old" "$want" || echo ":$old - [0:0]"; done
	# every chain declared before any rule refers to it
	grep '^:' "$body"
	grep -v '^:' "$body"
	for h in $MANGLE_HOOKS; do
		ipt_jump "$f" mangle "${h%%:*}" "${h#*:}" 1
	done
	for old in $(ipt_chains "$f" mangle); do
		grep -qx "$old" "$want" && continue
		for b in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
			ipt_jump "$f" mangle "$b" "$old" 0
		done
		echo "-X $old"
	done
	echo "COMMIT"
	rm -f "$body" "$want"
}

# platform hooks (nothing to do on FreshTomato): before the rules are written,
# additions to the mangle table, after the rules are in place
fw_prepare() { :; }
fw_mangle_extra() { :; }
fw_after_rules() { :; }

# ---------------------------------------------------------------- backend API

# rules hooked in and the sets present
fw_exists() {
	$IPT -n -L LF_FWD >/dev/null 2>&1 && $IPT -C FORWARD -j LF_FWD 2>/dev/null
}

# sets + rules files for the configuration
fw_build() {
	local z f
	fw_modules
	# servers stay in the "seen" sets for two learning passes (min. 2 minutes)
	SEEN_TIMEOUT=$((G_INTERVAL * 2)); [ "$SEEN_TIMEOUT" -ge 120 ] || SEEN_TIMEOUT=120
	# (IPv6 refused earlier: every apply tries again - the settings may have changed)
	rm -f "$LF_RUN/v6.off"
	FW_V6=""; fw_v6
	$IPSET list -t 2>/dev/null | lfawk ipset_headers > "$LF_RUN/sets.have"
	: > "$LF_RUN/sets.want"
	{
		for f in $(fw_families); do
			if [ "$f" = 4 ]; then
				printf '%s\n' 0.0.0.0/8 10.0.0.0/8 100.64.0.0/10 127.0.0.0/8 169.254.0.0/16 172.16.0.0/12 192.0.0.0/24 \
					192.0.2.0/24 192.168.0.0/16 198.18.0.0/15 198.51.100.0/24 203.0.113.0/24 224.0.0.0/3
			else
				printf '%s\n' ::/127 ::ffff:0:0/96 2001:db8::/32 fc00::/7 fe80::/10 ff00::/8
			fi | ipset_fill "lf_priv$f" hash:net "$(ipset_fam "$f")"
			ipset_want "lf_priv$f"
			for z in $ZONES_ON; do
				zone_load "$z"
				Z_DEV4="$(addr_list 4 $Z_DEV)"; Z_DEV6="$(addr_list 6 $Z_DEV)"; Z_MACS="$(mac_list $Z_DEV)"
				[ -z "$Z_DEV4$Z_DEV6$Z_MACS" ] && [ "$f" = 4 ] && log warning "zone $z: no valid device address, zone is inactive"
				[ "$Z_MODE" = enforce ] && [ "$Z_HAS_REGION" = 0 ] && [ "$f" = 4 ] && \
					log warning "zone $z: no region drawn yet - every server is blocked except allow_ip"
				ipset_zone "$z" "$f"
			done
		done
	} > "$FW_RULES.ipset"
	ipt_rules
}

# sets first (the rules refer to them), then the rules, then old sets away
fw_commit() {
	local f n
	ipset_restore "$FW_RULES.ipset" || return 1
	ipset_restore "$FW_SETS" || return 1
	for f in $(fw_families); do
		ipt_load "$f" "$FW_RULES.$f" || return 1
	done
	# IPv6 switched off since the last apply: take the IPv6 rules away
	if ! fw_v6 && have "$IP6T_BIN" && $IP6T -n -L LF_FWD >/dev/null 2>&1; then
		ipt_remove 6
	fi
	for n in $($IPSET list -n 2>/dev/null); do
		case "$n" in lf_*) grep -qx "$n" "$LF_RUN/sets.want" || $IPSET destroy "$n" 2>/dev/null;; esac
	done
	return 0
}

fw_post_apply() {
	# per-connection packet counts, for the packets/s of "active now" servers
	[ -w /proc/sys/net/netfilter/nf_conntrack_acct ] && [ "$(cat /proc/sys/net/netfilter/nf_conntrack_acct)" != 1 ] && \
		echo 1 > /proc/sys/net/netfilter/nf_conntrack_acct
	fw_ctf && echo 1 > "$LF_RUN/ctf.on" || rm -f "$LF_RUN/ctf.on"
	ipt_lag_apply
	fw_after_rules
	return 0
}

# ------------------------------------------------------------ lag simulator

# zones with the lag simulator on, as "zone:index" (index -> mark and tc band)
ipt_lag_zones() {
	local z n=0
	LAG_ZONES=""; LAG_OVER=""
	for z in $ZONES_ON; do
		zone_load "$z"
		[ "$Z_LAG" = 1 ] || continue
		# 16 queue bands: 3 for normal traffic, 12 zones, one spare
		[ "$n" -lt 12 ] || { LAG_OVER="$LAG_OVER $z"; continue; }
		n=$((n + 1))
		LAG_ZONES="$LAG_ZONES $z:$n"
	done
}

ipt_lag_mark() { # zone -> its mark, empty when the zone has no lag
	local zn
	[ "$LAG_SUPPORTED" = 1 ] || return 0
	for zn in $LAG_ZONES; do
		[ "${zn%%:*}" = "$1" ] && { printf '0x%08x' $(( ${zn#*:} << 24 )); return 0; }
	done
}

# netem arguments for the zone loaded with zone_load
ipt_netem_args() {
	local a="limit 10000" dl="$Z_LAG_DELAY" jt="$Z_LAG_JITTER"
	# both ways: the packets pass twice (out and back), so each pass gets half
	if [ "$Z_LAG_DIR" = both ]; then dl=$((dl / 2)); jt=$((jt / 2)); fi
	if [ "$dl" -gt 0 ] || [ "$jt" -gt 0 ]; then
		a="$a delay ${dl}ms"
		[ "$jt" -gt 0 ] && a="$a ${jt}ms"
	fi
	case "$Z_LAG_LOSS" in *[1-9]*) a="$a loss ${Z_LAG_LOSS}%";; esac
	echo "$a"
}

boot_id() { cat "$LF_BOOT_ID" 2>/dev/null || echo unknown; }
uptime_s() { awk '{ printf "%d", $1 }' /proc/uptime; }

# the kernel build and module netem works with ("works" holds for these only)
netem_id() {
	echo "$(uname -r 2>/dev/null) $(uname -v 2>/dev/null | tr -c 'A-Za-z0-9.:+\n' '_') $(cksum < "$LF_NETEM_KO" 2>/dev/null | awk '{ print $1 }')"
}
netem_ok() { [ -f "$LF_NETEM_OK" ] && [ "$(cat "$LF_NETEM_OK" 2>/dev/null)" = "$(netem_id)" ]; }

# the guard is this boot's (0), from an earlier boot (1), or there is none (2)
netem_guard() {
	local g t
	[ -f "$LF_NETEM_GUARD" ] || return 2
	read -r g t 2>/dev/null < "$LF_NETEM_GUARD"
	[ "$g" = "$(boot_id)" ] && [ "$(uptime_s)" -ge "${t:-0}" ] 2>/dev/null && return 0
	return 1
}

# before netem is used: 1 = the router restarted while netem was in use on an
# earlier boot - netem is not used
netem_trial() {
	netem_guard; case $? in 0) return 0;; 1) return 1;; esac
	echo "$(boot_id) $(uptime_s)" > "$LF_NETEM_GUARD"; sync
	return 0
}

# netem was not used after all (nothing set up): this boot's guard goes
netem_trial_unused() {
	netem_guard && { rm -f "$LF_NETEM_GUARD"; sync; }
	return 0
}

# netem stopped carrying traffic (lag switched off, LobbyFence stopped, a
# clean shutdown): a restart after this isn't netem's doing - this boot's
# guard goes. A guard from an earlier boot (a restart while netem was in use)
# stays.
netem_trial_stop() {
	netem_guard && { rm -f "$LF_NETEM_GUARD"; sync; }
	return 0
}

# packets that went through netem queues right now (0 when none / unknown)
netem_sent() {
	local d n=0 p
	for d in $(cat "$LF_RUN/lag.devs" 2>/dev/null); do
		case "$d" in queue*) continue;; esac
		p="$($TC -s qdisc show dev "$d" 2>/dev/null | awk '/^qdisc netem/ { on = 1; next } on && /Sent/ { for (i = 1; i < NF; i++) if ($(i + 1) ~ /^pkt/) s += $i; on = 0 } END { print s + 0 }')"
		case "$p" in ''|*[!0-9]*) ;; *) n=$((n + p));; esac
	done
	echo "$n"
}

# every pass: netem has carried game traffic for LF_NETEM_TRIAL seconds on
# this kernel and module -> recorded as working (the guard stays while in use)
netem_trial_check() {
	local g t
	netem_ok && return 0
	netem_guard || return 0
	[ -s "$LF_RUN/lag.devs" ] || return 0
	read -r g t 2>/dev/null < "$LF_NETEM_GUARD"
	[ $(( $(uptime_s) - ${t:-0} )) -ge "$LF_NETEM_TRIAL" ] || return 0
	[ "$(netem_sent)" -gt 0 ] || return 0
	netem_id > "$LF_NETEM_OK"; sync
	log notice "lag simulator: the netem module has carried game traffic for $LF_NETEM_TRIAL seconds - it works on this firmware"
}

# the netem module, loaded once
ipt_netem_load() {
	local err rc
	if ! netem_trial; then
		NETEM_ERR="netemcrash"; return 1
	fi
	grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null && return 0
	if [ ! -f "$LF_NETEM_KO" ]; then
		netem_trial_unused
		NETEM_ERR="nonetem"; log warning "lag simulator: no netem module for kernel $(uname -r)"; return 1
	fi
	err="$(insmod "$LF_NETEM_KO" 2>&1)"; rc=$?
	if [ "$rc" -gt 128 ]; then
		# insmod itself was killed (a kernel oops while loading): never again
		NETEM_ERR="netemcrash"; echo crashed > "$LF_NETEM_GUARD"; sync
		log err "lag simulator: loading the netem module crashed ($rc) - it is not tried again: $err"
		return 1
	elif [ "$rc" != 0 ]; then
		netem_trial_unused
		NETEM_ERR="netemrefused"
		log warning "lag simulator: the kernel refused the netem module: $err $(dmesg 2>/dev/null | grep -i netem | tail -n 1)"
		return 1
	fi
	log notice "lag simulator: netem module loaded"
}

# where a zone's downloads leave (towards the device) and where uploads leave (WAN)
ipt_lag_devs() {
	local zones="$1" z a d out=""
	for z in $zones; do
		for a in $(cat "$LF_RUN/$z.dev" 2>/dev/null); do
			case "$a" in *:*|*/*) continue;; esac
			d="$($IPCMD route get "$a" 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
			[ -n "$d" ] && case " $out " in *" $d "*) ;; *) out="$out $d";; esac
		done
	done
	[ -n "$out" ] || out="$(nvram get lan_ifname 2>/dev/null)"
	[ -n "$out" ] || out=br0
	LAG_DOWN_DEVS="$out"
	d="$($IPCMD route get 8.8.8.8 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
	[ -n "$d" ] || d="$(nvram get "${NV_WAN_IF:-wan_iface}" 2>/dev/null)"
	LAG_UP_DEVS="$d"
}

# our queue on a device: a prio qdisc (handle 7a:) whose first 3 bands carry
# everything as before, plus one netem band per lag zone picked by the mark
ipt_lag_dev() { # device "zone:index ..."
	local d="$1" zl="$2" root zn z n bands=3 b
	root="$($TC qdisc show dev "$d" 2>/dev/null | awk '/ root / { print $2, $3; exit }')"
	case "$root" in
		""|*" 0:") ;;                                           # the kernel's default queue
		"prio $LAG_HANDLE:") $TC qdisc del dev "$d" root 2>/dev/null;;   # ours, from before
		*) NETEM_ERR="busy"; log warning "lag simulator: $d already has a queue ($root) - QoS or the bandwidth limiter is on"; return 1;;
	esac
	for zn in $zl; do bands=$((bands + 1)); done
	$TC qdisc add dev "$d" root handle $LAG_HANDLE: prio bands $bands priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 2>/dev/null || \
		{ NETEM_ERR="notc"; return 1; }
	echo "$d" >> "$LF_RUN/lag.devs"
	for b in 1 2 3; do $TC qdisc add dev "$d" parent $LAG_HANDLE:$b handle 7$b: pfifo limit 1000 2>/dev/null; done
	b=3
	for zn in $zl; do
		z="${zn%%:*}"; n="${zn#*:}"; b=$((b + 1))
		zone_load "$z"
		# shellcheck disable=SC2046
		$TC qdisc add dev "$d" parent $LAG_HANDLE:$(printf '%x' $b) handle $(printf '%x' $((0x80 + n))): netem $(ipt_netem_args) 2>/dev/null || \
			{ NETEM_ERR="nonetem"; return 1; }
		$TC filter add dev "$d" parent $LAG_HANDLE: protocol all prio 1 handle $(printf '0x%x' $((n << 24)))/$LAG_MASK fw \
			flowid $LAG_HANDLE:$(printf '%x' $b) 2>/dev/null || { NETEM_ERR="nofilter"; return 1; }
	done
}

ipt_lag_clear() {
	local d
	for d in $(cat "$LF_RUN/lag.devs" 2>/dev/null); do
		$TC qdisc show dev "$d" 2>/dev/null | grep -q "^qdisc prio $LAG_HANDLE: root" && $TC qdisc del dev "$d" root 2>/dev/null
	done
	rm -f "$LF_RUN/lag.devs" "$LF_RUN"/lag.*.err "$LF_RUN/lag.zones" "$LF_RUN/lag.updev"
}

ipt_lag_apply() {
	local zn z down="" up="" d
	ipt_lag_clear
	[ "$LAG_SUPPORTED" = 1 ] || return 0
	ipt_lag_zones
	for z in $LAG_OVER; do
		echo toomany > "$LF_RUN/lag.$z.err"
		log warning "zone $z: at most 12 zones can use the lag simulator at once - not for this one"
	done
	[ -n "$LAG_ZONES" ] || { netem_trial_stop; return 0; }
	NETEM_ERR=""
	if ! have "$TC"; then NETEM_ERR="notc"
	else ipt_netem_load
	fi
	if [ -z "$NETEM_ERR" ]; then
		# a zone's mark goes to the download side, the upload side or both
		for zn in $LAG_ZONES; do
			zone_load "${zn%%:*}"
			[ "$Z_LAG_DIR" != up ] && down="$down $zn"
			[ "$Z_LAG_DIR" != down ] && up="$up $zn"
		done
		ipt_lag_devs "$(for zn in $LAG_ZONES; do echo "${zn%%:*}"; done)"
		if [ -n "$down" ]; then for d in $LAG_DOWN_DEVS; do ipt_lag_dev "$d" "$down" || break; done; fi
		if [ -z "$NETEM_ERR" ] && [ -n "$up" ]; then
			if [ -n "$LAG_UP_DEVS" ]; then ipt_lag_dev "$LAG_UP_DEVS" "$up" && echo "$LAG_UP_DEVS" > "$LF_RUN/lag.updev"
			else NETEM_ERR="nowan"; fi
		fi
	fi
	echo "$LAG_ZONES" > "$LF_RUN/lag.zones"
	for zn in $LAG_ZONES; do
		z="${zn%%:*}"
		if [ -n "$NETEM_ERR" ]; then
			echo "$NETEM_ERR" > "$LF_RUN/lag.$z.err"
		else
			zone_load "$z"
			log notice "zone $z: lag simulator on ($Z_LAG_DIR: $(ipt_netem_args))"
		fi
	done
	if [ -n "$NETEM_ERR" ]; then
		ipt_lag_clear; echo "$LAG_ZONES" > "$LF_RUN/lag.zones"
		for zn in $LAG_ZONES; do echo "$NETEM_ERR" > "$LF_RUN/lag.${zn%%:*}.err"; done
		for z in $LAG_OVER; do echo toomany > "$LF_RUN/lag.$z.err"; done
		# the queues are gone again before carrying traffic: we got through
		# loading and setting up, the trial starts again on the next use
		[ "$NETEM_ERR" = netemcrash ] || netem_trial_unused
	fi
}

# a WAN reconnect or network restart recreates devices and drops our queue
ipt_lag_check() {
	local d
	[ -s "$LF_RUN/lag.devs" ] || return 0
	netem_trial_check
	# the internet connection moved to another device (multi-WAN failover):
	# the uploads' queue has to move with it
	if [ -s "$LF_RUN/lag.updev" ]; then
		d="$($IPCMD route get 8.8.8.8 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }')"
		if [ -n "$d" ] && [ "$d" != "$(cat "$LF_RUN/lag.updev")" ]; then
			log notice "lag simulator: the internet connection is now on $d - moving the upload queue there"
			ipt_lag_apply
			return
		fi
	fi
	for d in $(cat "$LF_RUN/lag.devs"); do
		$TC qdisc show dev "$d" 2>/dev/null | grep -q "^qdisc prio $LAG_HANDLE: root" && continue
		log notice "lag simulator queue on $d went missing (network restart?) - setting it up again"
		ipt_lag_apply
		return
	done
}

# take every LobbyFence chain out of one family's tables
ipt_remove() { # 4|6
	local f="$1" cmd t c b
	cmd="$(ipt_of "$f")"
	if [ "$f" = 6 ]; then have "$IP6T_BIN" || return 0; else have "$IPT_BIN" || return 0; fi
	$cmd -n -L FORWARD >/dev/null 2>&1 || return 0     # (no IPv6 in this kernel)
	{
		for t in filter mangle; do
			$cmd -t "$t" -n -L >/dev/null 2>&1 || continue
			echo "*$t"
			for c in $(ipt_chains "$f" "$t"); do echo ":$c - [0:0]"; done
			[ "$t" = filter ] && ipt_jump "$f" filter FORWARD LF_FWD 0
			if [ "$t" = mangle ]; then
				for c in $(ipt_chains "$f" mangle); do
					for b in PREROUTING INPUT FORWARD OUTPUT POSTROUTING; do
						ipt_jump "$f" mangle "$b" "$c" 0
					done
				done
			fi
			for c in $(ipt_chains "$f" "$t"); do echo "-X $c"; done
			echo "COMMIT"
		done
	} > "$LF_RUN/remove.$f"
	grep -q '^[:-]' "$LF_RUN/remove.$f" && ipt_restore "$f" "$LF_RUN/remove.$f"
	rm -f "$LF_RUN/remove.$f"
}

fw_remove() {
	local n
	ipt_remove 4
	ipt_remove 6
	for n in $($IPSET list -n 2>/dev/null); do
		case "$n" in lf_*) $IPSET destroy "$n" 2>/dev/null;; esac
	done
	rm -f "$LF_RUN/ctf.on" "$LF_RUN/sets.last"
	# (what ip6tables could not do is found out again at the next start)
	rm -f "$LF_RUN/v6.off" "$LF_RUN/v6.noset" "$LF_RUN/v6.noct"
	ipt_lag_clear
	netem_trial_stop
	return 0
}

# once per learning pass: CTF switched on/off since the last apply -> rules again
fw_check() {
	local want=0 have=0
	ipt_lag_check
	fw_ctf && want=1
	[ -f "$LF_RUN/ctf.on" ] && have=1
	[ "$want" = "$have" ] && return 0
	log notice "hardware acceleration (CTF) changed - updating the rules"
	FW_V6=""
	ipt_rules
	for f in $(fw_families); do ipt_load "$f" "$FW_RULES.$f"; done
	fw_post_apply
}

# Tomato rebuilt its firewall (the "Firewall" script hook): the sets are still
# there, only the chains are gone - put them back without the full apply
fw_rules_only() {
	local f
	$IPSET list -n "lf_priv4" >/dev/null 2>&1 || return 1
	SEEN_TIMEOUT=$((G_INTERVAL * 2)); [ "$SEEN_TIMEOUT" -ge 120 ] || SEEN_TIMEOUT=120
	FW_V6=""
	ipt_rules
	for f in $(fw_families); do ipt_load "$f" "$FW_RULES.$f" || return 1; done
	fw_post_apply
}

fw_zone_servers() {
	fw_v6
	lfawk ipset_load -v p="lf_$1" -v v6="$FW_V6" < "$LF_RUN/$1.servers"
}

fw_zone_mip() {
	local z="$1" f
	for f in $(fw_families); do
		if [ "$f" = 4 ]; then grep -v ':' "$LF_RUN/$z.mip"; else grep ':' "$LF_RUN/$z.mip"; fi | \
			ipset_fill "lf_${z}_mip$f" hash:ip "$(ipset_fam "$f")"
	done
}

fw_load_sets() { [ -s "$1" ] && $IPSET list -n lf_priv4 >/dev/null 2>&1 && ipset_restore "$1"; }

# the zone's game connections in the connection table (-v family=4|6|"")
ipt_ct() { # zone fam
	local ct="$LF_CONNTRACK"
	[ -r "$ct" ] || ct=/proc/net/ip_conntrack
	[ -r "$ct" ] && [ -s "$LF_RUN/$1.dev" ] || return 0
	ct_sift "$1" "$ct" | lfawk ct_packets -v devs="$LF_RUN/$1.dev" -v family="$2" -v proto="$Z_PROTO" \
		-v lp="$Z_LPORT" -v rp="$Z_RPORT" -v pp="$Z_PORT"
}

# ip6tables without the SET target: IPv6 servers are learned from the
# connection table instead, and "active now" means their packet count grew
v6_from_conntrack() { [ -f "$LF_RUN/v6.noset" ] && fw_v6; }

ipt_v6_active() { # zone -> "<addr> <seconds since its count grew> <packets>"
	local z="$1" st="$LF_RUN/$1.ct6" t
	t="$(awk '{ printf "%d", $1 }' /proc/uptime)"
	[ -f "$st" ] || : > "$st"
	ipt_ct "$z" 6 | awk -v t="$t" -v f="$st" -v w="$LF_NOW_TIMEOUT" -v out="$st.new" '
		BEGIN { while ((getline l < f) > 0) { split(l, a, " "); pk[a[1]] = a[2]; lc[a[1]] = a[3] } printf "" > out }
		$2 < 0 { next }
		{ last = (($1 in pk) && $2 == pk[$1]) ? lc[$1] : t
		  print $1, $2, last > out
		  if (t - last <= w) printf "%s %d %d\n", $1, t - last, $2 }'
	mv "$st.new" "$st" 2>/dev/null
}

fw_seen() {
	{
		$IPSET list "lf_${1}_seen4" 2>/dev/null
		fw_v6 && $IPSET list "lf_${1}_seen6" 2>/dev/null
	} | lfawk ipset_members
	if v6_from_conntrack; then
		zone_load "$1"
		ipt_ct "$1" 6 | awk '{ print $1 }'
	fi
}

# the learning loop's 2-second check, cheap: has the zone talked to a server it
# doesn't know since the last learning pass? (1 = no; 0 = yes or can't tell)
fw_new_traffic() {
	local o
	v6_from_conntrack && return 0           # (IPv6 then comes from the connection table)
	o="$($IPSET list "lf_${1}_nw4" 2>/dev/null; fw_v6 && $IPSET list "lf_${1}_nw6" 2>/dev/null)"
	case "$o" in
		*"Members:"?[0-9a-fA-F]*) return 0;;
		*"Members:"*) return 1;;
	esac
	return 0                                # (no such set - rules from an older version)
}

# a learning pass took the zone's servers in: start the quick check afresh
fw_new_reset() {
	$IPSET flush "lf_${1}_nw4" 2>/dev/null
	fw_v6 && $IPSET flush "lf_${1}_nw6" 2>/dev/null
	return 0
}

fw_now() {
	local z="$1"
	ipt_ct "$z" "" > "$LF_RUN/$z.ctp"
	{
		$IPSET list "lf_${z}_now4" 2>/dev/null
		fw_v6 && $IPSET list "lf_${z}_now6" 2>/dev/null
	} | lfawk ipset_ages -v window="$LF_NOW_TIMEOUT" -v pk="$LF_RUN/$z.ctp"
	rm -f "$LF_RUN/$z.ctp"
	v6_from_conntrack && ipt_v6_active "$z"
	return 0
}

fw_open_left() {
	{
		$IPSET list "lf_${1}_op4" 2>/dev/null
		fw_v6 && $IPSET list "lf_${1}_op6" 2>/dev/null
	} | lfawk ipset_expires
}

fw_override() {
	local z="$1" f fa
	for f in $(fw_families); do
		fa="$(ipset_fam "$f")"
		one_per_line "$(addr_list "$f" $Z_ALLOW)" | ipset_fill "lf_${z}_fa$f" hash:net "$fa"
		one_per_line "$(addr_list "$f" $Z_BLOCK)" | ipset_fill "lf_${z}_fb$f" hash:net "$fa"
	done > "$LF_RUN/override.ipset"
	ipset_restore "$LF_RUN/override.ipset" || return 1
	rm -f "$LF_RUN/override.ipset"
}

counters_load() {
	COUNTERS="$({
		$IPT -L -v -x -n 2>/dev/null
		fw_v6 && $IP6T -L -v -x -n 2>/dev/null
	} | lfawk ipt_counts)"
}

fw_diag() {
	fw_v6
	echo "IPv6: $(if [ -f "$LF_RUN/v6.off" ]; then echo 'not filtered (ip6tables refused the rules)'; elif [ "$FW_V6" != 1 ]; then echo 'not in use'; elif [ -f "$LF_RUN/v6.noset" ]; then echo 'filtered, servers learned from the connection table'; elif [ -f "$LF_RUN/v6.noct" ]; then echo 'filtered, without the rules that look at connection states'; else echo filtered; fi)"
	echo "hardware acceleration (CTF): $(fw_ctf && echo 'on - game devices are marked so their traffic is still checked' || echo off)"
	echo "lag simulator: $([ "$LAG_SUPPORTED" = 1 ] && echo "netem module for $(uname -r) $(grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" && echo loaded || echo 'not loaded')" || echo "no netem module for $(uname -r)")"
}

fw_status_json() {
	printf '"platform":"tomato","lag_supported":%s,"offload":false,' "$([ "$LAG_SUPPORTED" = 1 ] && echo true || echo false)"
	printf '"kernel":"%s","netem":%s,' "$(uname -r 2>/dev/null)" "$(grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null && echo true || echo false)"
	printf '"ipv6":"%s",' "$(if [ -f "$LF_RUN/v6.off" ]; then echo off; elif ! fw_v6; then echo none; elif [ -f "$LF_RUN/v6.noset" ]; then echo no-learning; else echo on; fi)"
	printf '"ctf":%s,"conntrack":%s,"tc":%s,"pkg":"",' "$(fw_ctf && echo true || echo false)" \
		"$(have conntrack && echo true || echo false)" "$(have "$TC" && echo true || echo false)"
}

# for the debug report: LobbyFence's rules and sets (sizes, not their contents), lag
fw_debug() {
	local t f
	for f in $(fw_families); do
		for t in mangle filter raw; do
			echo "$( [ "$f" = 6 ] && echo ip6tables || echo iptables ) -t $t (LobbyFence's rules):"
			$(ipt_of "$f") -t "$t" -S 2>&1 | grep -E 'LF_|lf_' | head -n 150
		done
	done
	echo
	echo "ipsets (headers):"
	$IPSET list -t 2>/dev/null | awk '/^Name: / { p = ($2 ~ /^lf_/) } p' | head -n 200
	echo
	echo "lag simulator: $([ "$LAG_SUPPORTED" = 1 ] && echo supported || echo 'not supported')$(grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null && echo ', netem loaded')"
	have "$TC" && $TC qdisc show 2>&1 | head -n 40
	echo "IPv6 state: $(ls "$LF_RUN"/v6.* 2>/dev/null | sed 's#.*/##' | tr '\n' ' ')"
	if [ -f "$LF_RUN/v6.refused" ]; then
		echo
		echo "IPv6 rules that ip6tables refused:"
		head -n 140 "$LF_RUN/v6.refused"
	fi
	return 0
}
