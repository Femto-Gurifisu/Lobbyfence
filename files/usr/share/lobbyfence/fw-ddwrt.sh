# LobbyFence firewall backend: DD-WRT (iptables + ipset), checked on the
# Netgear R7000 (Broadcom Northstar, kernel 4.4)
# Sourced by the lobbyfence script - see "firewall backend" there for the API.
#
# The same chains and sets as on FreshTomato (fw-ipt.sh), with what differs
# on DD-WRT:
#
#  * hardware acceleration (CTF, "Shortcut Forwarding Engine: CTF"): DD-WRT's
#    kernel takes a connection out of CTF when a MARK rule XORs the packet mark
#    with its magic value 0xB16B00B5. LobbyFence does that twice in a row for
#    the game devices' packets, so the connection is excluded and the packet's
#    mark ends up as it was (QoS and the lag simulator keep their marks).
#  * the software fast path (SFE, "Shortcut Forwarding Engine: SFE") has no
#    such switch: once a connection has carried 128 packets it skips the
#    firewall. New servers are still checked; the status page says what that
#    means and how to turn it off.
#  * lag simulator: DD-WRT's kernel has netem built in (no module to load), and
#    DD-WRT brings tc - the same marks and queues as on FreshTomato.
#
# SPDX-License-Identifier: GPL-3.0-or-later

. "${LF_SHARE:-/jffs/lobbyfence/share}/fw-ipt.sh"

TC="${LF_TC:-$( [ -x /usr/sbin/tc ] && echo /usr/sbin/tc || echo tc )}"
# netem is part of the kernel: usable wherever tc is
LAG_SUPPORTED=0
type "$TC" >/dev/null 2>&1 && LAG_SUPPORTED=1
[ -n "${LF_LAG_SUPPORTED:-}" ] && LAG_SUPPORTED="$LF_LAG_SUPPORTED"
CTF_XOR=0xb16b00b5

# CTF on: DD-WRT sets ctf_disable=0 when the "Shortcut Forwarding Engine"
# setting is CTF (nvram sfe=2). LF_CTF=0|1 overrides.
fw_ctf() {
	case "${LF_CTF:-auto}" in 0) return 1;; 1) return 0;; esac
	have nvram || return 1
	[ "$(nvram get ctf_disable 2>/dev/null)" = 0 ] || [ "$(nvram get sfe 2>/dev/null)" = 2 ]
}

# the software fast path (sfe=1): established connections skip the firewall
fw_sfe() {
	case "${LF_SFE:-auto}" in 0) return 1;; 1) return 0;; esac
	have nvram && [ "$(nvram get sfe 2>/dev/null)" = 1 ] && return 0
	grep -q '^fast_classifier ' "${LF_PROC_MODULES:-/proc/modules}" 2>/dev/null
}

# the zone's devices -> LF_CTF_X (the double XOR); the chains are hooked in
# by ipt_mangle (LF_CTF_IN in PREROUTING, LF_CTF_OUT in POSTROUTING)
ipt_ctf_zone() { # zone family
	local f="$2" s="lf_$1" d mac
	eval "d=\"\$Z_DEV$f\""
	[ -n "$d" ] && { echo "-A LF_CTF_IN -m set --match-set ${s}_dev$f src -j LF_CTF_X"; echo "-A LF_CTF_OUT -m set --match-set ${s}_dev$f dst -j LF_CTF_X"; }
	if [ -n "$Z_MACS" ]; then
		for mac in $(one_per_line "$Z_MACS"); do echo "-A LF_CTF_IN -m mac --mac-source $mac -j LF_CTF_X"; done
		echo "-A LF_CTF_OUT -m set --match-set ${s}_mip$f dst -j LF_CTF_X"
	fi
}

# (called inside ipt_mangle, which has "ctf" set)
fw_mangle_extra() {
	[ "${ctf:-0}" = 1 ] || return 0
	echo ":LF_CTF_X - [0:0]"
	echo "-A LF_CTF_X -j MARK --xor-mark $CTF_XOR"
	echo "-A LF_CTF_X -j MARK --xor-mark $CTF_XOR"
}

# netem is built in: nothing to load, no trial
ipt_netem_load() { return 0; }

# where uploads leave when the routing table can't say (DD-WRT's nvram name)
NV_WAN_IF=wan_ifname

fw_diag() {
	fw_v6
	echo "IPv6: $(if [ -f "$LF_RUN/v6.off" ]; then echo 'not filtered (ip6tables refused the rules)'; elif [ "$FW_V6" != 1 ]; then echo 'not in use'; elif [ -f "$LF_RUN/v6.noset" ]; then echo 'filtered, servers learned from the connection table'; else echo filtered; fi)"
	echo "hardware acceleration (CTF): $(fw_ctf && echo 'on - game devices are excluded so their traffic is still checked' || echo off)"
	fw_sfe && echo "software fast path (SFE): ON - connections that are already running skip the filter and the lag simulator; set Setup > Basic Setup > Shortcut Forwarding Engine to CTF or Disable"
	echo "lag simulator: $([ "$LAG_SUPPORTED" = 1 ] && echo "netem (built into the kernel), tc $TC" || echo "tc is missing")"
}

fw_status_json() {
	printf '"platform":"ddwrt","lag_supported":%s,"offload":%s,' "$([ "$LAG_SUPPORTED" = 1 ] && echo true || echo false)" \
		"$(fw_sfe && echo true || echo false)"
	printf '"kernel":"%s","netem":%s,' "$(uname -r 2>/dev/null)" "$([ "$LAG_SUPPORTED" = 1 ] && echo true || echo false)"
	printf '"ipv6":"%s",' "$(if [ -f "$LF_RUN/v6.off" ]; then echo off; elif ! fw_v6; then echo none; elif [ -f "$LF_RUN/v6.noset" ]; then echo no-learning; else echo on; fi)"
	printf '"ctf":%s,"conntrack":false,"tc":%s,"pkg":"",' "$(fw_ctf && echo true || echo false)" "$(have "$TC" && echo true || echo false)"
}
