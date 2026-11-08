#!/bin/sh
# A stand-in for FreshTomato's tc (the test kernel has no prio / fw / netem):
# logs every call and keeps the root queue of each device in a file, so
# "tc qdisc show" answers like the real one.
#   env: FAKE_TC_DIR (state + log)
D="${FAKE_TC_DIR:?}"
mkdir -p "$D/dev"
echo "tc $*" >> "$D/tc.log"
st=0; [ "$1" = -s ] && { st=1; shift; }
case "$1 $2" in
	"qdisc show")
		dev="$4"
		if [ -f "$D/dev/$dev" ]; then
			# (-s: netem queues report packets once "$D/traffic" exists - game traffic went through)
			while IFS= read -r l; do
				echo "$l"
				case "$l" in "qdisc netem "*) [ "$st" = 1 ] && [ -f "$D/traffic" ] && echo " Sent 8400 bytes 100 pkt (dropped 0, overlimits 0 requeues 0)";; esac
			done < "$D/dev/$dev"
		else echo "qdisc pfifo_fast 0: root refcnt 2 bands 3"; fi;;
	"qdisc add")
		dev="$4"
		case "$*" in
			*" root handle "*)
				[ -f "$D/dev/$dev" ] && { echo "RTNETLINK answers: File exists" >&2; exit 2; }
				h="$(echo "$*" | sed 's/.* handle \([0-9a-f]*:\).*/\1/')"; k="$(echo "$*" | sed 's/.* handle [0-9a-f]*: \([a-z_]*\).*/\1/')"
				echo "qdisc $k $h root refcnt 2" > "$D/dev/$dev";;
			*" netem "*) [ -f "$D/no-netem" ] && { echo "Unknown qdisc \"netem\"" >&2; exit 2; }; echo "qdisc netem ${*#* handle } parent" >> "$D/dev/$dev";;
			*) echo "qdisc child ${*#* handle }" >> "$D/dev/$dev";;
		esac;;
	"qdisc del") rm -f "$D/dev/$4";;
	"filter add") echo "filter ${*#* parent }" >> "$D/dev/$4";;
esac
exit 0
