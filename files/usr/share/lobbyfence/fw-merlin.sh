# LobbyFence firewall backend: Asuswrt-Merlin (iptables + ipset)
# Sourced by the lobbyfence script - see "firewall backend" there for the API.
#
# The same chains and sets as on FreshTomato (fw-ipt.sh), with what differs
# on ASUS's Broadcom (HND) routers:
#
#  * hardware acceleration: Broadcom's flow cache would let a game's packets
#    skip the firewall once a connection runs. The zone chains end their
#    game connections' acceleration with the SKIPLOG target (as ASUS does for
#    its own web pages), and the flow cache is flushed when rules change.
#  * lag simulator: the game's packets are picked in mangle FORWARD (the
#    firewall still decides on every packet afterwards) and then wait in one
#    of two ways:
#     - netem, the kernel's own network emulator, where this router can use
#       it: ASUS's firmware doesn't include it, so LobbyFence carries a module
#       built from the firmware's own kernel source for the models it was
#       checked on (netem/<model>-<kernel>/). The router tests it once per boot
#       on a private test interface before it touches real traffic, and its
#       first use is a two-minute trial (as on FreshTomato): a restart during
#       the trial and netem is never used again. The rule sets the packet's
#       queue band (CLASSIFY) - no packet marks, which ASUS uses for its QoS.
#     - otherwise (other models, QoS using the connection, or anything about
#       netem going wrong) LobbyFence's lf-lagd holds the packets through an
#       NFQUEUE queue. The rule uses --queue-bypass: without lf-lagd, packets
#       simply pass without lag.
#
# SPDX-License-Identifier: GPL-3.0-or-later

LF_NETEM_KO_ENV="${LF_NETEM_KO:-}"
. "${LF_SHARE:-/jffs/addons/lobbyfence/share}/fw-ipt.sh"

LF_LAGD="${LF_LAGD:-${LF_HOME:-/jffs/addons/lobbyfence}/bin/lf-lagd}"
FC="${LF_FC:-fc}"
LAG_QBASE=7400                       # queues 7401..7412, one per lag zone
# netem modules LobbyFence carries: netem/<model>-<kernel>/sch_netem.ko
LF_NETEM_DIR="${LF_NETEM_DIR:-${LF_HOME:-/jffs/addons/lobbyfence}/netem}"
NETEM_TESTDEV=lfnetem0
LF_PROC_CONFIG="${LF_PROC_CONFIG:-/proc/config.gz}"

# the netem module for this router: the firmware's own if it has one, else
# the one LobbyFence carries for exactly this model and kernel (none: empty)
merlin_netem_ko() {
	local k m
	k="$(uname -r 2>/dev/null)"
	if [ -n "$LF_NETEM_KO_ENV" ]; then [ -f "$LF_NETEM_KO_ENV" ] && echo "$LF_NETEM_KO_ENV"; return; fi
	[ -f "/lib/modules/$k/kernel/net/sched/sch_netem.ko" ] && { echo "/lib/modules/$k/kernel/net/sched/sch_netem.ko"; return; }
	# the model's name: productid, or odmpid (the name some models are sold under)
	for m in "$(nvram get productid 2>/dev/null)" "$(nvram get odmpid 2>/dev/null)"; do
		m="$(echo "$m" | tr 'ABCDEFGHIJKLMNOPQRSTUVWXYZ' 'abcdefghijklmnopqrstuvwxyz')"
		[ -n "$m" ] && [ -f "$LF_NETEM_DIR/$m-$k/sch_netem.ko" ] && { echo "$LF_NETEM_DIR/$m-$k/sch_netem.ko"; return; }
	done
}
LF_NETEM_KO="$(merlin_netem_ko)"
NETEM_HAVE=0
if [ -n "$LF_NETEM_KO" ] || grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null; then NETEM_HAVE=1; fi
LAG_SUPPORTED=0
[ -x "$LF_LAGD" ] && LAG_SUPPORTED=1
[ "$NETEM_HAVE" = 1 ] && LAG_SUPPORTED=1

# no CTF on these routers (the flow cache is handled with SKIPLOG)
fw_ctf() { return 1; }

# does this kernel / iptables know a target (in that table)? Tried once in a
# scratch chain, remembered until the next reboot.  ipt_target_ok 4|6 'TARGET [options]' [table]
ipt_target_ok() {
	local f="$1" t="$2" tb="${3:-filter}" key r
	key="$LF_RUN/target.$f.$( [ "$tb" = filter ] || echo "$tb.")$(echo "$t" | tr -c 'A-Za-z0-9\n' '_')"
	if [ ! -f "$key" ]; then
		r="$IPT_RESTORE"; [ "$f" = 6 ] && r="$IP6T_RESTORE"
		if printf '*%s\n:LF_TEST - [0:0]\n-A LF_TEST -j %s\nCOMMIT\n' "$tb" "$t" | $r -n >/dev/null 2>&1; then
			echo 1 > "$key"
		else
			echo 0 > "$key"
		fi
		printf '*%s\n:LF_TEST - [0:0]\n-X LF_TEST\nCOMMIT\n' "$tb" | $r -n >/dev/null 2>&1
	fi
	[ "$(cat "$key" 2>/dev/null)" = 1 ]
}

lag_queue_target() { echo "NFQUEUE --queue-num $1 --queue-bypass"; }
# netem: the zone's band in LobbyFence's prio queue (3 bands for all other
# traffic, then one per lag zone) - the qdisc reads it from skb->priority
lag_band() { printf '%x' $(($1 + 3)); }
lag_class_target() { echo "CLASSIFY --set-class $LAG_HANDLE:$(lag_band "$1")"; }
# the target a zone's queue chain ends in, for the way the lag runs now
lag_target() { # index
	if [ "$(cat "$LF_RUN/lag.kind" 2>/dev/null)" = netem ] || ! ipt_target_ok 4 "$(lag_queue_target $LAG_QBASE)"; then
		lag_class_target "$1"
	else
		lag_queue_target $((LAG_QBASE + $1))
	fi
}

fw_prepare() {
	local f
	FW_SKIP4=""; FW_SKIP6=""
	for f in $(fw_families); do
		ipt_target_ok "$f" SKIPLOG && eval "FW_SKIP$f=SKIPLOG"
	done
}

# lag zones: a queue for the game's packets (mangle FORWARD - the filter
# still sees every packet after its wait)
fw_mangle_extra() { # family
	local f="$1" zn z n c
	[ "$LAG_SUPPORTED" = 1 ] && [ -n "$LAG_ZONES" ] || return 0
	ipt_target_ok "$f" "$(lag_queue_target $LAG_QBASE)" || \
		{ [ "$NETEM_HAVE" = 1 ] && ipt_target_ok "$f" "$(lag_class_target 1)" mangle; } || return 0
	echo ":LF_LAG - [0:0]"
	for zn in $LAG_ZONES; do
		z="${zn%%:*}"; n="${zn#*:}"; c="LF_${z}"
		zone_load "$z"
		Z_DEV4="$(addr_list 4 $Z_DEV)"; Z_DEV6="$(addr_list 6 $Z_DEV)"; Z_MACS="$(mac_list $Z_DEV)"
		echo ":${c}_lo$f - [0:0]"; echo ":${c}_li$f - [0:0]"; echo ":${c}_q - [0:0]"
		# uploads (from the device) and / or downloads (to it)
		ipt_dev_rules LF_LAG "${c}_lo$f" "${c}_li$f" "$f" | case "$Z_LAG_DIR" in
			down) grep -v -- "-j ${c}_lo$f\$";;
			up) grep -v -- "-j ${c}_li$f\$";;
			*) cat;;
		esac
		ipt_port_rules "${c}_lo$f" "${c}_li$f" "${c}_q" "${c}_q"
		echo "-A ${c}_q -j $(lag_target "$n")"
	done
	MANGLE_HOOKS="$MANGLE_HOOKS FORWARD:LF_LAG"
}

# connections that started before the rules: let them through the firewall
# again (the flow cache relearns them, minus the game's)
fw_after_rules() {
	have "$FC" && $FC flush >/dev/null 2>&1
	return 0
}

# the lag is a queue, not a packet mark
ipt_lag_mark() { :; }

# switch every lag zone's queue chain to a target (both families)
lag_chains_set() { # netem|nfqueue
	local zn n f cmd t
	for f in $(fw_families); do
		cmd="$(ipt_of "$f")"
		for zn in $LAG_ZONES; do
			n="${zn#*:}"
			if [ "$1" = netem ]; then t="$(lag_class_target "$n")"; else t="$(lag_queue_target $((LAG_QBASE + n)))"; fi
			$cmd -t mangle -n -L "LF_${zn%%:*}_q" >/dev/null 2>&1 || continue
			# shellcheck disable=SC2086
			$cmd -t mangle -R "LF_${zn%%:*}_q" 1 -j $t 2>/dev/null || return 1
		done
	done
}

# ---- netem

# a module LobbyFence carries is loaded only into a kernel configured like the
# one it was built for. kernel-options.gz next to the module lists that
# kernel's options in two kinds:
#   R NAME value  the option can reach the module's compilation - it is named
#                 in netem's source, in a header netem includes or in the
#                 makefiles that set the compiler's flags (the kernel's own
#                 build system records this) - so the router's kernel
#                 (/proc/config.gz) must have it at this value (n = off)
#   K NAME        any other option that kernel has: free to differ
# An option the router has on that the list doesn't have at all means a
# kernel from other source: not loaded either. So the structures the module
# works with are laid out as it expects, or it stays out. (The firmware's own
# module, or one that is loaded already, isn't LobbyFence's to check.) What
# differs is kept in netem.config for diag.
netem_config_ok() {
	local d r="$LF_RUN/netem.config" n
	case "$LF_NETEM_KO" in "$LF_NETEM_DIR"/*) ;; *) return 0;; esac
	grep -q '^sch_netem ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null && return 0
	d="${LF_NETEM_KO%/*}"
	gunzip -c "$d/kernel-options.gz" > "$r.module" 2>/dev/null
	gunzip -c "$LF_PROC_CONFIG" > "$r.router" 2>/dev/null
	if ! grep -q '^R ' "$r.module" 2>/dev/null || ! grep -q '^CONFIG_' "$r.router" 2>/dev/null; then
		echo "unknown: $(grep -q '^R ' "$r.module" 2>/dev/null && echo "this kernel doesn't show its configuration ($LF_PROC_CONFIG)" || echo "$d/kernel-options.gz is missing")" > "$r"
		rm -f "$r.module" "$r.router"
		log warning "lag simulator: the router's kernel configuration can't be compared with the netem module's - lf-lagd is used instead"
		return 1
	fi
	awk 'NR == FNR {
			if ($1 == "R") { want[$2] = $3; if ($3 != "n") need[$2] = 1 }
			if ($1 == "R" || $1 == "K") known[$2] = 1
			next
		}
		/^CONFIG_[A-Za-z0-9_]+=/ {
			i = index($0, "="); n = substr($0, 1, i - 1); v = substr($0, i + 1)
			if (n == "CONFIG_NET_SCH_NETEM") next
			if (!(n in known)) { print n ": router " v ", not in the kernel the module was built for"; next }
			if (n in want) {
				if (want[n] != v) print n ": module " (want[n] == "n" ? "off" : want[n]) ", router " v
				delete need[n]
			}
		}
		END { for (n in need) print n ": module " want[n] ", router off"; print "=compared" }' "$r.module" "$r.router" | sort > "$r.diff"
	rm -f "$r.module" "$r.router"
	# (no last line: the comparison didn't run to its end - no result, no module)
	if ! grep -qx '=compared' "$r.diff"; then
		echo "unknown: the comparison could not be made" > "$r"; rm -f "$r.diff"
		log warning "lag simulator: the router's kernel configuration can't be compared with the netem module's - lf-lagd is used instead"
		return 1
	fi
	n="$(grep -c '^CONFIG_' "$r.diff")"
	if [ "$n" = 0 ]; then rm -f "$r.diff"; echo ok > "$r"; return 0; fi
	{ echo "differs: $n options"; grep '^CONFIG_' "$r.diff"; } > "$r"; rm -f "$r.diff"
	log warning "lag simulator: this firmware's kernel is configured differently from the one the netem module was built for ($n options, first: $(sed -n 2p "$r")) - lf-lagd is used instead"
	return 1
}

# once per boot, before netem carries real traffic: a private test interface
# with LobbyFence's queue on it, a few pings through the netem band, and the
# packets must come out the other end of netem (its timers and queue work).
# Nothing about it is reachable from outside (198.18.254.0/30, benchmark range).
netem_selftest() {
	local r="$LF_RUN/netem.selftest" d="$NETEM_TESTDEV" sent
	[ -f "$r" ] && { [ "$(cat "$r")" = ok ]; return; }
	echo running > "$r"
	$IPCMD link del "$d" >/dev/null 2>&1
	# (kernel 4.1 firmware has no dummy driver: an ifb interface does the same
	# here - it drops what the router itself sends into it, after the queue)
	if ! $IPCMD link add "$d" type dummy >/dev/null 2>&1 && ! $IPCMD link add "$d" type ifb >/dev/null 2>&1; then
		echo nodummy > "$r"; log warning "lag simulator: netem self-test: no test interface - netem not used"; return 1
	fi
	if $IPCMD link set "$d" up 2>/dev/null && $IPCMD addr add 198.18.254.1/30 dev "$d" 2>/dev/null && \
		$TC qdisc add dev "$d" root handle $LAG_HANDLE: prio bands 4 priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 2>/dev/null && \
		$TC qdisc add dev "$d" parent $LAG_HANDLE:4 handle 81: netem limit 100 delay 20ms 5ms loss 1% 2>/dev/null && \
		$TC filter add dev "$d" parent $LAG_HANDLE: protocol all prio 1 u32 match u32 0 0 flowid $LAG_HANDLE:4 2>/dev/null; then
		ping -c 3 -w 3 -I "$d" 198.18.254.2 >/dev/null 2>&1
		sent="$($TC -s qdisc show dev "$d" 2>/dev/null | awk '/^qdisc netem 81:/ { n = 1; next } n && /Sent/ { for (i = 1; i < NF; i++) if ($(i + 1) ~ /^pkt/) { print $i; exit } }')"
	fi
	$IPCMD link del "$d" >/dev/null 2>&1
	if [ "${sent:-0}" -gt 0 ] 2>/dev/null; then
		echo ok > "$r"; log notice "lag simulator: netem self-test passed ($sent test packets through netem)"; return 0
	fi
	echo failed > "$r"
	log warning "lag simulator: netem self-test failed (packets through netem: ${sent:-none}) - lf-lagd is used instead"
	return 1
}

# LobbyFence's queue on a device: prio (handle 7a:), bands 1-3 for everything
# as before, band 3+n a netem queue for lag zone n (the zone's rule puts its
# packets there with CLASSIFY); zones not lagged this way on this device keep
# a plain fifo in their band
netem_lag_dev() { # device "zone:index ..."
	local d="$1" zl="$2" root zn z n max=0 b
	root="$($TC qdisc show dev "$d" 2>/dev/null | awk '/ root / { print $2, $3; exit }')"
	case "$root" in
		""|*" 0:") ;;                                                     # the kernel's default queue
		"prio $LAG_HANDLE:") $TC qdisc del dev "$d" root 2>/dev/null;;   # ours, from before
		*) NETEM_ERR="busy"; log notice "lag simulator: $d already has a queue ($root) - QoS or the bandwidth limiter is on"; return 1;;
	esac
	for zn in $LAG_ZONES; do n="${zn#*:}"; [ "$n" -gt "$max" ] && max="$n"; done
	$TC qdisc add dev "$d" root handle $LAG_HANDLE: prio bands $((max + 3)) priomap 1 2 2 2 1 2 0 0 1 1 1 1 1 1 1 1 2>/dev/null || \
		{ NETEM_ERR="notc"; return 1; }
	echo "$d" >> "$LF_RUN/lag.devs"
	for b in 1 2 3; do $TC qdisc add dev "$d" parent $LAG_HANDLE:$b handle 7$b: pfifo limit 1000 2>/dev/null; done
	for zn in $zl; do
		z="${zn%%:*}"; n="${zn#*:}"
		zone_load "$z"
		# shellcheck disable=SC2046
		$TC qdisc add dev "$d" parent $LAG_HANDLE:$(lag_band "$n") handle $(printf '%x' $((0x80 + n))): netem $(ipt_netem_args) 2>/dev/null || \
			{ NETEM_ERR="nonetem"; return 1; }
	done
}

# the device the internet is reached through right now
wan_dev_now() {
	$IPCMD route get 8.8.8.8 2>/dev/null | awk '{ for (i = 1; i < NF; i++) if ($i == "dev") { print $(i + 1); exit } }'
}

netem_clear() {
	local d
	for d in $(cat "$LF_RUN/lag.devs" 2>/dev/null); do
		case "$d" in queue*) continue;; esac
		$TC qdisc show dev "$d" 2>/dev/null | grep -q "^qdisc prio $LAG_HANDLE: root" && $TC qdisc del dev "$d" root 2>/dev/null
	done
}

# netem for every lag zone: 0 when it runs, else NETEM_ERR says why
netem_apply() {
	local zn down="" up="" d
	NETEM_ERR=""
	[ "$NETEM_HAVE" = 1 ] || { NETEM_ERR=nonetem; return 1; }
	have "$TC" || { NETEM_ERR=notc; return 1; }
	ipt_target_ok 4 "$(lag_class_target 1)" mangle || { NETEM_ERR=noclassify; return 1; }
	netem_config_ok || { NETEM_ERR=netemconfig; return 1; }
	ipt_netem_load || return 1
	netem_selftest || { NETEM_ERR=selftest; netem_trial_unused; return 1; }
	for zn in $LAG_ZONES; do
		zone_load "${zn%%:*}"
		[ "$Z_LAG_DIR" != up ] && down="$down $zn"
		[ "$Z_LAG_DIR" != down ] && up="$up $zn"
	done
	ipt_lag_devs "$(for zn in $LAG_ZONES; do echo "${zn%%:*}"; done)"
	[ -n "$LAG_UP_DEVS" ] || LAG_UP_DEVS="$(nvram get wan0_ifname 2>/dev/null)"
	if [ -n "$down" ]; then for d in $LAG_DOWN_DEVS; do netem_lag_dev "$d" "$down" || break; done; fi
	if [ -z "$NETEM_ERR" ] && [ -n "$up" ]; then
		if [ -n "$LAG_UP_DEVS" ]; then netem_lag_dev "$LAG_UP_DEVS" "$up" && echo "$LAG_UP_DEVS" > "$LF_RUN/lag.updev"
		else NETEM_ERR="nowan"; fi
	fi
	[ -z "$NETEM_ERR" ] && ! lag_chains_set netem && NETEM_ERR=noclassify
	if [ -n "$NETEM_ERR" ]; then
		netem_clear; rm -f "$LF_RUN/lag.devs" "$LF_RUN/lag.updev"
		# the queues are gone again before carrying traffic: the trial starts again on the next use
		[ "$NETEM_ERR" = netemcrash ] || netem_trial_unused
		return 1
	fi
	echo netem > "$LF_RUN/lag.kind"
	for zn in $LAG_ZONES; do
		zone_load "${zn%%:*}"
		log notice "zone ${zn%%:*}: lag simulator on with netem ($Z_LAG_DIR: $(ipt_netem_args))"
	done
}

# ---- lf-lagd (NFQUEUE)

# lf-lagd arguments for the zone loaded with zone_load: each packet waits
# once, so "both" gives each direction half the ping and jitter
lagd_args() {
	local dl="$Z_LAG_DELAY" jt="$Z_LAG_JITTER"
	if [ "$Z_LAG_DIR" = both ]; then dl=$((dl / 2)); jt=$((jt / 2)); fi
	echo "-d $dl -j $jt -l $Z_LAG_LOSS"
}

lagd_pid() { # zone -> pid if running
	local p
	p="$(cat "$LF_RUN/lagd.$1.pid" 2>/dev/null)"
	# really lf-lagd (not a finished one waiting to be reaped, nor a reused pid)
	[ -n "$p" ] && grep -q lf-lagd "/proc/$p/cmdline" 2>/dev/null && echo "$p"
}

lagd_start() { # zone queue -> 0 when it runs
	local z="$1" q="$2" p n=0
	# shellcheck disable=SC2046
	"$LF_LAGD" -q "$q" $(lagd_args) </dev/null >/dev/null 2>"$LF_RUN/lagd.$z.log" 8>&- 9>&- &
	p=$!
	echo "$p" > "$LF_RUN/lagd.$z.pid"
	# it binds its queue at once - a failure shows within a moment
	while [ "$n" -lt 4 ]; do
		sleep 1
		kill -0 "$p" 2>/dev/null || break
		grep -q "delay" "$LF_RUN/lagd.$z.log" 2>/dev/null && return 0
		n=$((n + 1))
	done
	kill -0 "$p" 2>/dev/null && return 0
	log warning "lag simulator (zone $z): lf-lagd stopped: $(tail -n 1 "$LF_RUN/lagd.$z.log" 2>/dev/null)"
	rm -f "$LF_RUN/lagd.$z.pid"
	return 1
}

lagd_apply() { # error to show when lf-lagd can't be used either
	local zn z n err=""
	echo nfqueue > "$LF_RUN/lag.kind"
	lag_chains_set nfqueue
	if [ ! -x "$LF_LAGD" ]; then err="${1:-lagdfail}"
	else
		modprobe nfnetlink_queue >/dev/null 2>&1
		if ! ipt_target_ok 4 "$(lag_queue_target $LAG_QBASE)"; then
			err=noqueue; log warning "lag simulator: this firmware's kernel has no NFQUEUE - not available"
		fi
	fi
	for zn in $LAG_ZONES; do
		z="${zn%%:*}"; n="${zn#*:}"
		if [ -n "$err" ]; then echo "$err" > "$LF_RUN/lag.$z.err"; continue; fi
		zone_load "$z"
		if lagd_start "$z" $((LAG_QBASE + n)); then
			echo "queue$((LAG_QBASE + n))" >> "$LF_RUN/lag.devs"
			log notice "zone $z: lag simulator on ($Z_LAG_DIR: $(lagd_args))"
		else
			if grep -q "netlink socket\|Protocol not supported\|not supported" "$LF_RUN/lagd.$z.log" 2>/dev/null; then
				echo noqueue > "$LF_RUN/lag.$z.err"
			else
				echo lagdfail > "$LF_RUN/lag.$z.err"
			fi
		fi
	done
}

# ---- both

ipt_lag_clear() {
	local f p
	netem_clear
	for f in "$LF_RUN"/lagd.*.pid; do
		[ -f "$f" ] || continue
		p="$(cat "$f")"
		# (only while it is lf-lagd: the number may belong to another program by now)
		[ -n "$p" ] && grep -q lf-lagd "/proc/$p/cmdline" 2>/dev/null && kill "$p" 2>/dev/null
		rm -f "$f"
	done
	# (any left from before a crash of this script)
	for p in $(pidof lf-lagd 2>/dev/null); do kill "$p" 2>/dev/null; done
	rm -f "$LF_RUN/lag.devs" "$LF_RUN"/lag.*.err "$LF_RUN/lag.zones" "$LF_RUN"/lagd.*.restarts "$LF_RUN/lag.why" "$LF_RUN/lag.updev"
}

# netem where it can run, lf-lagd otherwise
ipt_lag_apply() {
	local z
	ipt_lag_clear
	[ "$LAG_SUPPORTED" = 1 ] || { rm -f "$LF_RUN/lag.kind"; netem_trial_stop; return 0; }
	ipt_lag_zones
	for z in $LAG_OVER; do
		echo toomany > "$LF_RUN/lag.$z.err"
		log warning "zone $z: at most 12 zones can use the lag simulator at once - not for this one"
	done
	[ -n "$LAG_ZONES" ] || { rm -f "$LF_RUN/lag.kind"; netem_trial_stop; return 0; }
	echo "$LAG_ZONES" > "$LF_RUN/lag.zones"
	if [ "${LF_LAG_KIND:-auto}" != nfqueue ] && [ "$NETEM_HAVE" = 1 ]; then
		netem_apply && return 0
		echo "$NETEM_ERR" > "$LF_RUN/lag.why"
		[ -x "$LF_LAGD" ] && log notice "lag simulator: netem not used ($NETEM_ERR) - lf-lagd instead"
		lagd_apply "$NETEM_ERR"
	else
		lagd_apply
	fi
}

# every pass: netem's queues still there (a WAN reconnect or network restart
# drops them) and its trial; an lf-lagd that died is started again (3 times)
ipt_lag_check() {
	local zn z n r d
	[ -s "$LF_RUN/lag.zones" ] || return 0
	if [ "$(cat "$LF_RUN/lag.kind" 2>/dev/null)" = netem ]; then
		[ -s "$LF_RUN/lag.devs" ] || return 0
		netem_trial_check
		# the internet connection moved to another device (dual WAN failover,
		# USB modem): the uploads' queue has to move with it
		if [ -s "$LF_RUN/lag.updev" ]; then
			d="$(wan_dev_now)"
			if [ -n "$d" ] && [ "$d" != "$(cat "$LF_RUN/lag.updev")" ]; then
				log notice "lag simulator: the internet connection is now on $d - moving the upload queue there"
				ipt_lag_apply
				return 0
			fi
		fi
		for d in $(cat "$LF_RUN/lag.devs"); do
			$TC qdisc show dev "$d" 2>/dev/null | grep -q "^qdisc prio $LAG_HANDLE: root" && continue
			log notice "lag simulator queue on $d went missing (network restart?) - setting it up again"
			ipt_lag_apply
			return 0
		done
		return 0
	fi
	for zn in $(cat "$LF_RUN/lag.zones"); do
		z="${zn%%:*}"; n="${zn#*:}"
		[ -f "$LF_RUN/lag.$z.err" ] && continue
		[ -n "$(lagd_pid "$z")" ] && continue
		r="$(cat "$LF_RUN/lagd.$z.restarts" 2>/dev/null)"; r=$((${r:-0} + 1))
		echo "$r" > "$LF_RUN/lagd.$z.restarts"
		if [ "$r" -gt 3 ]; then
			echo lagdfail > "$LF_RUN/lag.$z.err"
			log warning "lag simulator (zone $z): lf-lagd keeps stopping - switched off until the next Save & Apply"
			continue
		fi
		log notice "lag simulator (zone $z): lf-lagd was not running - starting it again"
		zone_load "$z"
		lagd_start "$z" $((LAG_QBASE + n)) || echo lagdfail > "$LF_RUN/lag.$z.err"
	done
	return 0
}

# the map's live data (packets, servers in use) is a file here: written again
# when the page has read the last copy (its access time moved), at most every
# 2 s, and at least once a learning pass (/tmp without access times)
LIVE_AT=""
fw_tick() {
	local f="$LF_RUN/web/live.json" a t
	[ -d "$LF_RUN/web" ] || return 0
	a="$(ls -leu "$f" 2>/dev/null)"
	t="$(date +%s)"
	[ -n "$a" ] && [ "$a" = "$LIVE_SEEN" ] && [ $((t - ${LIVE_AT:-0})) -lt "$G_INTERVAL" ] && return 0
	do_live > "$f.tmp" 2>/dev/null && mv "$f.tmp" "$f"
	LIVE_SEEN="$(ls -leu "$f" 2>/dev/null)"
	LIVE_AT="$t"
}

# netem on this router: none (no module for it), ready, trial, works,
# crashed (a restart during the trial), other-kernel-config, selftest-failed
netem_state() {
	local g
	netem_guard; g=$?
	if [ "$NETEM_HAVE" != 1 ]; then echo none
	elif [ "$g" = 1 ]; then echo crashed
	elif netem_ok; then echo works
	elif [ "$g" = 0 ]; then echo trial
	elif [ -f "$LF_RUN/netem.config" ] && [ "$(cat "$LF_RUN/netem.config")" != ok ]; then echo other-kernel-config
	elif [ -f "$LF_RUN/netem.selftest" ] && [ "$(cat "$LF_RUN/netem.selftest")" != ok ]; then echo selftest-failed
	else echo ready
	fi
}

fw_diag() {
	fw_v6
	echo "IPv6: $(if [ -f "$LF_RUN/v6.off" ]; then echo 'not filtered (ip6tables refused the rules)'; elif [ "$FW_V6" != 1 ]; then echo 'not in use'; elif [ -f "$LF_RUN/v6.noset" ]; then echo 'filtered, servers learned from the connection table'; else echo filtered; fi)"
	echo "hardware acceleration: $(have "$FC" && echo 'flow cache present' || echo 'no flow cache tool'); game connections kept out of it: $(ipt_target_ok 4 SKIPLOG && echo yes || echo 'no (SKIPLOG missing)')"
	echo "lag simulator: $(if [ "$LAG_SUPPORTED" != 1 ]; then echo 'lf-lagd missing'; elif [ ! -s "$LF_RUN/lag.zones" ]; then echo 'not in use'; elif [ "$(cat "$LF_RUN/lag.kind" 2>/dev/null)" = netem ]; then echo "netem, queues on:$(tr '\n' ' ' 2>/dev/null < "$LF_RUN/lag.devs" | sed 's/^/ /; s/ $//')"; else echo "lf-lagd, running for:$(for p in "$LF_RUN"/lagd.*.pid; do [ -f "$p" ] && kill -0 "$(cat "$p")" 2>/dev/null && { p="${p##*/lagd.}"; printf ' %s' "${p%.pid}"; }; done)$([ -s "$LF_RUN/lag.why" ] && echo " (netem not used: $(cat "$LF_RUN/lag.why"))")"; fi)"
	echo "netem: $(netem_state)$([ -n "$LF_NETEM_KO" ] && echo " - module $LF_NETEM_KO")"
	if [ -f "$LF_RUN/netem.config" ] && [ "$(cat "$LF_RUN/netem.config")" != ok ]; then sed 's/^/netem kernel configuration: /' "$LF_RUN/netem.config"; fi
}

fw_status_json() {
	printf '"platform":"merlin","lag_supported":%s,"offload":false,' "$([ "$LAG_SUPPORTED" = 1 ] && echo true || echo false)"
	printf '"kernel":"%s","lag_kind":"%s","netem":"%s",' "$(uname -r 2>/dev/null)" \
		"$(cat "$LF_RUN/lag.kind" 2>/dev/null || { [ "$NETEM_HAVE" = 1 ] && echo netem || echo nfqueue; })" "$(netem_state)"
	printf '"ipv6":"%s",' "$(if [ -f "$LF_RUN/v6.off" ]; then echo off; elif ! fw_v6; then echo none; elif [ -f "$LF_RUN/v6.noset" ]; then echo no-learning; else echo on; fi)"
	printf '"accel_skip":%s,"conntrack":%s,"tc":true,"pkg":"",' "$([ "$(cat "$LF_RUN/target.4.SKIPLOG" 2>/dev/null)" = 1 ] && echo true || echo false)" \
		"$(have conntrack && echo true || echo false)"
}
