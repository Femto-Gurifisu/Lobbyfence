# functions.sh - the parts of OpenWrt's config API LobbyFence uses, for FreshTomato
#
# FreshTomato has no UCI. LobbyFence keeps its settings in one file written in
# UCI syntax ($LF_CONF_FILE); this file reads it the way OpenWrt's
# /lib/functions.sh does (config_load / config_get / config_get_bool /
# config_foreach) and offers a small "uci" for the few edits the router script
# makes itself (always allow / always block a server).
#
# SPDX-License-Identifier: GPL-3.0-or-later

LF_CONF_FILE="${LF_CONF_FILE:-/jffs/lobbyfence/lobbyfence.conf}"
# changes made on the web page but not applied yet ("Save" without "Apply")
LF_CONF_STAGED="${LF_CONF_STAGED:-/tmp/lobbyfence/staged.conf}"
LF_CONF_AWK="${LF_CONF_AWK:-${LF_SHARE:-/jffs/lobbyfence/share}/conf.awk}"

config_load() {
	# forget what the last config_load set (an option may be gone since)
	[ -n "$CONFIG_VARS" ] && unset $CONFIG_VARS
	CONFIG_SECTIONS=""; CONFIG_VARS=""
	[ -f "$LF_CONF_FILE" ] || return 0
	eval "$(awk -v mode=shell -f "$LF_CONF_AWK" "$LF_CONF_FILE")"
}

# config_get <var> <section> <option> [default]
config_get() {
	case "$2$3" in *[!A-Za-z0-9_]*|'') eval "$1=\$4"; return;; esac
	eval "$1=\${CONFIG_${2}_${3}:-\$4}"
}

# config_get_bool <var> <section> <option> [default]
config_get_bool() {
	local _v
	config_get _v "$2" "$3" "$4"
	case "$_v" in
		1|on|true|yes|enabled) _v=1;;
		0|off|false|no|disabled) _v=0;;
		*) _v="${4:-0}";;
	esac
	eval "$1=\$_v"
}

# config_foreach <function> [type]
config_foreach() {
	local _f="$1" _t="$2" _s _st
	for _s in $CONFIG_SECTIONS; do
		eval "_st=\$CONFIG_${_s}_TYPE"
		[ -z "$_t" ] || [ "$_st" = "$_t" ] && "$_f" "$_s"
	done
	return 0
}

# one edit, applied to the live file and to changes waiting on the web page
_lf_conf_edit() { # op sec opt val
	local f
	for f in "$LF_CONF_FILE" "$LF_CONF_STAGED"; do
		[ -f "$f" ] || continue
		awk -v mode=edit -v op="$1" -v sec="$2" -v opt="$3" -v val="$4" -f "$LF_CONF_AWK" "$f" > "$f.tmp" && \
			mv "$f.tmp" "$f"
	done
}

# uci [-q] get|set|add_list|del_list|delete|commit lobbyfence.<section>[.<option>][=<value>]
uci() {
	local _q=0 _cmd _p _v _sec _opt _rest
	[ "$1" = -q ] && { _q=1; shift; }
	_cmd="$1"; _p="$2"
	case "$_cmd" in
		commit|changes|revert) return 0;;
	esac
	case "$_p" in *=*) _v="${_p#*=}"; _p="${_p%%=*}";; *) _v="";; esac
	case "$_p" in lobbyfence.*) _rest="${_p#lobbyfence.}";; *) return 1;; esac
	_sec="${_rest%%.*}"; _opt=""
	[ "$_sec" = "$_rest" ] || _opt="${_rest#*.}"
	case "$_cmd" in
		get)
			[ -f "$LF_CONF_FILE" ] || return 1
			awk -v mode=get -v sec="$_sec" -v opt="$_opt" -f "$LF_CONF_AWK" "$LF_CONF_FILE";;
		set)
			[ -f "$LF_CONF_FILE" ] || : > "$LF_CONF_FILE"
			if [ -z "$_opt" ]; then _lf_conf_edit section "$_sec" "" "$_v"; else _lf_conf_edit set "$_sec" "$_opt" "$_v"; fi;;
		add_list) _lf_conf_edit add_list "$_sec" "$_opt" "$_v";;
		del_list) _lf_conf_edit del_list "$_sec" "$_opt" "$_v";;
		delete) _lf_conf_edit delete "$_sec" "$_opt" "";;
		*) [ "$_q" = 1 ] || echo "uci: unsupported command $_cmd" >&2; return 1;;
	esac
}
