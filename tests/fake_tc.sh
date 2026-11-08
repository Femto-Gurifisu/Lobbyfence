#!/bin/sh
# tc stand-in for the namespace test. Every command first goes to the real tc
# (built from iproute2), so syntax errors fail the test. When the test kernel
# simply lacks a module OpenWrt ships (netem, the fw classifier), a stand-in
# with the same plumbing is used: tbf instead of netem, a u32 address match
# instead of the firewall-mark match (ctinfo, which copies the connection mark
# onto uploads, is simply skipped).
REAL="$LF_REAL_TC"; LOG="$LF_TC_LOG"
echo "$*" >> "$LOG"
out="$("$REAL" "$@" 2>&1)"; rc=$?
if [ $rc = 0 ]; then
	[ -n "$out" ] && echo "$out"
	exit 0
fi
case "$out" in
	*"kind is unknown"*|*"No such file or directory"*|*"Unknown filter"*|*"not found"*) ;;
	*) echo "$out" >&2; echo "TC-ERROR $* :: $out" >> "$LOG"; exit $rc;;
esac
echo "KERNEL-MISSING $*" >> "$LOG"
case " $* " in
	*" root netem "*) exec "$REAL" $(echo "$*" | sed 's/ root netem .*/ root tbf rate 1gbit burst 200k latency 2s/');;
	*" ingress "*" fw action "*) exec "$REAL" $(echo "$*" | sed "s| handle [^ ]* fw | u32 match ip src $LF_TC_DEVIP/32 match ip dport 3074 0xffff |");;
	*" fw action "*) exec "$REAL" $(echo "$*" | sed "s| handle [^ ]* fw | u32 match ip dst $LF_TC_DEVIP/32 |");;
	*" action ctinfo "*) exit 0;;   # restores the connection mark - nothing to stand in for
esac
echo "$out" >&2
exit $rc
