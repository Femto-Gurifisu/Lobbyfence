#!/bin/sh
# Stand-ins for the GT-AXE16000's tc / ip / ping / insmod / iptables for the
# netem unit test (the test kernel has no netem, prio, dummy or fw). One
# script, called by the name of the tool it stands in for. State + log in
# FAKE_DIR; switches: no-dummy, no-ifb, kver (the kernel version), netem-broken (netem passes nothing),
# insmod-fail, no-classify, busy.<dev> (a QoS queue on that device), wan
# (the internet device, default eth0).
D="${FAKE_DIR:?}"; mkdir -p "$D/dev"
me="${0##*/}"
echo "$me $*" >> "$D/calls.log"
case "$me" in
tc)
	s=0; [ "$1" = -s ] && { s=1; shift; }
	case "$1 $2" in
		"qdisc show")
			dev="$4"
			if [ -f "$D/busy.$dev" ]; then echo "qdisc htb 1: root refcnt 2 r2q 10 default 0x10"
			elif [ -f "$D/dev/$dev" ]; then
				while IFS= read -r l; do
					echo "$l"
					if [ "$s" = 1 ]; then
						case "$l" in "qdisc netem "*)
							n=0; [ -f "$D/netem-broken" ] || n="$(cat "$D/pings.$dev" 2>/dev/null || echo 0)"
							[ -f "$D/traffic" ] && [ ! -f "$D/netem-broken" ] && n=$((n + 100))   # (game packets went through)
							echo " Sent $((n * 84)) bytes $n pkt (dropped 0, overlimits 0 requeues 0)";;
						esac
					fi
				done < "$D/dev/$dev"
			else echo "qdisc mq 0: root"; fi;;
		"qdisc add")
			dev="$4"
			case "$*" in
				*" root handle "*)
					[ -f "$D/dev/$dev" ] && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
					echo "qdisc $(echo "$*" | sed 's/.* handle \([0-9a-f]*:\) \([a-z_]*\).*/\2 \1/') root refcnt 2" > "$D/dev/$dev";;
				*" netem "*) echo "qdisc netem ${*#* handle }" >> "$D/dev/$dev";;
				*) echo "qdisc child ${*#* handle }" >> "$D/dev/$dev";;
			esac;;
		"qdisc del") rm -f "$D/dev/$4";;
		"filter add") echo "filter ${*#* parent }" >> "$D/dev/$4";;
	esac;;
ip)
	case "$1 $2" in
		"link add") [ -f "$D/no-$5" ] && { echo "RTNETLINK answers: Operation not supported" >&2; exit 2; }
			touch "$D/link.$3";;
		"link del") [ -f "$D/link.$3" ] || exit 1; rm -f "$D/link.$3" "$D/dev/$3" "$D/pings.$3";;
		"route get")
			case "$3" in 192.168.*) echo "$3 dev br0 src 192.168.50.1 uid 0";;
				*) echo "$3 via 100.64.0.1 dev $(cat "$D/wan" 2>/dev/null || echo eth0) src 100.64.0.2 uid 0";; esac;;
	esac
	exit 0;;
ping)
	dev=""; while [ $# -gt 0 ]; do [ "$1" = -I ] && dev="$2"; shift; done
	[ -f "$D/link.$dev" ] && [ -f "$D/dev/$dev" ] && echo 3 > "$D/pings.$dev"
	exit 1;;                        # (nobody answers on the test interface)
insmod)
	[ -f "$D/insmod-fail" ] && { echo "insmod: can't insert '$1': invalid module format" >&2; exit 1; }
	echo "sch_netem 24576 0 - Live 0xffffffc000a00000" >> "$D/proc.modules";;
iptables|ip6tables)
	case "$*" in
		*" -L "*) grep -qx "${*##* }" "$D/chains" 2>/dev/null;;
		*" -R "*) echo "$*" >> "$D/ipt.log";;
	esac;;
iptables-restore|ip6tables-restore)
	in="$(cat)"
	case "$in" in *CLASSIFY*) [ -f "$D/no-classify" ] && exit 1;; esac
	case "$in" in *"-A LF_TEST -j CLASSIFY"*) echo "$in" | grep -q '^\*mangle' || exit 1;; esac
	exit 0;;
uname) cat "$D/kver" 2>/dev/null || echo 4.19.183;;
esac
exit 0
