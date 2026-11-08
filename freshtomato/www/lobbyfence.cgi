#!/bin/sh
# LobbyFence for FreshTomato and DD-WRT - the web page's link to the router
#
# FreshTomato's web server runs this (as /ext/cgi-bin/lobbyfence.cgi) only for
# logged-in users; on DD-WRT LobbyFence's own small web server runs it
# (through cgi-bin/lobbyfence.cgi, which sets LF_TOKEN_FILE). The POST body
# comes on stdin:
#
#   line 1   the page's token (FreshTomato: nvram http_id; DD-WRT: the token
#            in LF_TOKEN_FILE) - stops other web sites and other people on
#            the network from sending commands
#   line 2   command and arguments, separated by spaces
#   rest     data (the configuration for "stage")
#
# Every answer is JSON. Only the commands below are possible.
#
# SPDX-License-Identifier: GPL-3.0-or-later

LF_HOME="${LF_HOME:-/jffs/lobbyfence}"
LF="$LF_HOME/lobbyfence"
export LF_RUN="${LF_RUN:-/tmp/lobbyfence}"
CONF="${LF_CONF_FILE:-$LF_HOME/lobbyfence.conf}"
STAGED="${LF_CONF_STAGED:-$LF_RUN/staged.conf}"
CONF_AWK="${LF_CONF_AWK:-$LF_HOME/share/conf.awk}"
NVRAM="${LF_NVRAM:-nvram}"

# text -> JSON string body (no quotes around it)
jstr() {
	tr -d '\000-\010\013\014\016-\037' | awk 'BEGIN { ORS = "" }
		function rep(s, a, b,   n, p, i, o) { n = split(s, p, a); o = p[1]; for (i = 2; i <= n; i++) o = o b p[i]; return o }
		{ s = rep($0, "\\", "\\\\"); s = rep(s, "\"", "\\\""); s = rep(s, "\t", "\\t"); s = rep(s, "\r", "\\r")
		  print (NR > 1 ? "\\n" : "") s }'
}

fail() { printf '{"error":"%s"}\n' "$(printf '%s' "$1" | jstr)"; exit 0; }

valid_zone() { case "$1" in ''|*[!A-Za-z0-9_]*) return 1;; esac; [ "${#1}" -le 64 ]; }
valid_addr() { case "$1" in ''|*[!0-9A-Fa-f:./]*) return 1;; esac; [ "${#1}" -le 49 ]; }

# run a command, answer like LuCI's fs.exec: {"code":..,"stdout":"..","stderr":".."}
run() {
	local out="$LF_RUN/cgi.out.$$" err="$LF_RUN/cgi.err.$$" rc
	"$@" > "$out" 2> "$err" < /dev/null
	rc=$?
	printf '{"code":%d,"stdout":"%s","stderr":"%s"}\n' "$rc" "$(jstr < "$out")" "$(jstr < "$err")"
	rm -f "$out" "$err"
}

mkdir -p "$LF_RUN"
IFS= read -r token
IFS= read -r cmdline
token="$(printf '%s' "$token" | tr -d '\r')"
cmdline="$(printf '%s' "$cmdline" | tr -d '\r')"

# same token as the page FreshTomato gave this browser (DD-WRT: the token
# LobbyFence keeps in a file, which the router's Status > My Page hands out)
if [ -n "${LF_TOKEN_FILE:-}" ]; then
	expect="$(cat "$LF_TOKEN_FILE" 2>/dev/null)"
	why="not signed in - open LobbyFence from the router's Status > My Page"
else
	expect="$($NVRAM get http_id 2>/dev/null)"
	why="session expired - reload the page"
fi
if [ -z "$expect" ] || [ "$token" != "$expect" ]; then
	printf '{"error":"%s","signin":true}\n' "$why"; exit 0
fi

set -f
set -- $cmdline
set +f
cmd="$1"; [ $# -gt 0 ] && shift

case "$cmd" in
	read)
		case "$1" in
			status) cat "$LF_RUN/status.json" 2>/dev/null || fail "no status yet";;
			servers)
				valid_zone "$2" || fail "bad zone"
				if [ -f "$LF_RUN/$2.servers" ]; then
					printf '{"text":"%s"}\n' "$(jstr < "$LF_RUN/$2.servers")"
				else
					fail "no servers"
				fi;;
			*) fail "unknown file";;
		esac;;
	exec)
		sub="$1"; [ $# -gt 0 ] && shift
		case "$sub" in
			live|devices|cycle|export) run "$LF" "$sub";;
			apitest) run "$LF" apitest;;
			restart) run "$LF" restart;;
			debug)
				# the debug report, or "debug clear" (forget the crash records)
				case "$1" in ''|clear) run "$LF" debug $1;; *) fail "not allowed";; esac;;
			ports)
				valid_zone "$1" || fail "bad zone"
				case "$2" in ''|clear) ;; *) fail "bad argument";; esac
				[ $# -le 2 ] || fail "bad argument"
				run "$LF" ports "$@";;
			remove-servers)
				case "$1" in ''|*[!a-z0-9_]*) fail "bad game";; esac
				[ ${#1} -le 32 ] || fail "bad game"
				g="$1"; shift
				for a in "$@"; do valid_addr "$a" || fail "bad address"; done
				run "$LF" remove-servers "$g" "$@";;
			forget|allow|block|unlist)
				valid_zone "$1" || fail "bad zone"
				z="$1"; shift
				for a in "$@"; do valid_addr "$a" || fail "bad address"; done
				[ "$sub" = forget ] || [ $# -gt 0 ] || fail "no address"
				run "$LF" "$sub" "$z" "$@";;
			*) fail "not allowed";;
		esac;;
	import-servers)
		# the rest of the body: another router's servers file (lobbyfence export)
		out="$LF_RUN/cgi.out.$$"; err="$LF_RUN/cgi.err.$$"
		"$LF" import-servers - > "$out" 2> "$err"
		rc=$?
		printf '{"code":%d,"stdout":"%s","stderr":"%s"}\n' "$rc" "$(jstr < "$out")" "$(jstr < "$err")"
		rm -f "$out" "$err";;
	config)
		# what the page shows: changes waiting to be applied, else the live settings
		if [ -f "$STAGED" ]; then f="$STAGED"; st=true; else f="$CONF"; st=false; fi
		printf '{"staged":%s,"text":"%s"}\n' "$st" "$( [ -f "$f" ] && jstr < "$f")";;
	stage)
		# the rest of the body is the whole configuration: cleaned, then kept
		# aside until "apply" (like LuCI's Save)
		awk -v mode=normalize -f "$CONF_AWK" > "$STAGED.new" || fail "could not read the configuration"
		[ -f "$CONF" ] && awk -v mode=normalize -f "$CONF_AWK" "$CONF" > "$LF_RUN/live.norm"
		if [ -f "$LF_RUN/live.norm" ] && cmp -s "$STAGED.new" "$LF_RUN/live.norm"; then
			rm -f "$STAGED.new" "$STAGED"
			st=false
		else
			mv "$STAGED.new" "$STAGED"
			st=true
		fi
		rm -f "$LF_RUN/live.norm"
		printf '{"ok":true,"staged":%s}\n' "$st";;
	revert)
		rm -f "$STAGED"
		printf '{"ok":true}\n';;
	apply)
		if [ -f "$STAGED" ]; then
			cp "$STAGED" "$CONF.new" && mv "$CONF.new" "$CONF" && rm -f "$STAGED" || fail "could not save the configuration"
		fi
		run "$LF" reload;;
	running)
		# (its command line, not just the number: the loop may have died and
		# the number gone to another program)
		p="$(cat "$LF_RUN/daemon.pid" 2>/dev/null | tr -cd '0-9')"
		r=false
		[ -n "$p" ] && case "$(tr '\000' ' ' 2>/dev/null < "/proc/$p/cmdline")" in *lobbyfence*" daemon "*) r=true;; esac
		printf '{"running":%s}\n' "$r";;
	*) fail "unknown command";;
esac
