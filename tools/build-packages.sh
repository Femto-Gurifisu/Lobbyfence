#!/bin/sh
# Build the four LobbyFence release packages:
#   dist/lobbyfence-openwrt.tar.gz
#   dist/lobbyfence-freshtomato.tar.gz
#   dist/lobbyfence-asuswrt-merlin.tar.gz
#   dist/lobbyfence-ddwrt.tar.gz
#
# Each one unpacks to a folder named lobbyfence-install - not "lobbyfence",
# which is the name of the folder a running LobbyFence keeps its memory files
# in (/tmp/lobbyfence). The files in a package are the ones its installer
# copies (the FILES list in the installer), the installer itself, the
# defaults and, for the kernel modules and programs LobbyFence brings, what
# they were built from.
#
#   sh tools/build-packages.sh [output folder]      (default: dist)
#
# SPDX-License-Identifier: GPL-3.0-or-later

set -eu
cd "$(dirname "$0")/.."
OUT="${1:-dist}"
TOP=lobbyfence-install
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# the source paths an installer copies: the first field of its FILES lines
installer_files() { # installer
	awk '/^FILES="$/ { on = 1; next } on && /^"$/ { exit } on && NF { split($0, f, ":"); print f[1] }' "$1"
}

list() { # platform -> the package's files, one per line
	echo LICENSE
	echo README.md
	case "$1" in
		openwrt)
			echo install.sh
			installer_files install.sh
			echo files/etc/config/lobbyfence;;
		freshtomato)
			echo freshtomato/install.sh
			installer_files freshtomato/install.sh
			echo freshtomato/lobbyfence.conf
			echo freshtomato/modules/build-netem.sh
			for d in freshtomato/modules/*/; do
				[ -f "$d/sch_netem.ko" ] || continue
				echo "${d}sch_netem.ko"
				[ ! -f "${d}Module.symvers.netem" ] || echo "${d}Module.symvers.netem"
			done;;
		asuswrt-merlin)
			echo asuswrt-merlin/install.sh
			installer_files asuswrt-merlin/install.sh
			echo freshtomato/lobbyfence.conf
			echo asuswrt-merlin/lagd/lf-lagd.c
			echo asuswrt-merlin/lagd/build.sh
			echo asuswrt-merlin/netem/README.md
			echo asuswrt-merlin/netem/dwarf_layouts.py
			for d in asuswrt-merlin/netem/*/; do
				[ -f "$d/sch_netem.ko" ] || continue
				echo "${d}SHA256SUMS"
				echo "${d}kernel-config.gz"
			done;;
		ddwrt)
			echo ddwrt/install.sh
			installer_files ddwrt/install.sh
			echo freshtomato/lobbyfence.conf;;
	esac
}

mkdir -p "$OUT"
for p in openwrt freshtomato asuswrt-merlin ddwrt; do
	rm -rf "$WORK/$TOP"
	mkdir -p "$WORK/$TOP"
	list "$p" | LC_ALL=C sort -u > "$WORK/$p.list"
	while read -r f; do
		[ -f "$f" ] || { echo "$p: $f is missing" >&2; exit 1; }
		mkdir -p "$WORK/$TOP/$(dirname "$f")"
		cp -p "$f" "$WORK/$TOP/$f"
	done < "$WORK/$p.list"
	# the same file modes for everyone: scripts and programs executable, the rest not
	find "$WORK/$TOP" -type d -exec chmod 755 {} +
	find "$WORK/$TOP" -type f -exec chmod 644 {} +
	for x in install.sh freshtomato/install.sh asuswrt-merlin/install.sh ddwrt/install.sh \
		files/usr/sbin/lobbyfence files/etc/init.d/lobbyfence freshtomato/lobbyfence asuswrt-merlin/lobbyfence \
		ddwrt/lobbyfence ddwrt/mypage.sh freshtomato/www/lobbyfence.cgi ddwrt/www/cgi-bin/lobbyfence.cgi \
		asuswrt-merlin/bin/lf-lagd freshtomato/modules/build-netem.sh asuswrt-merlin/lagd/build.sh; do
		[ ! -f "$WORK/$TOP/$x" ] || chmod 755 "$WORK/$TOP/$x"
	done
	( cd "$WORK" && LC_ALL=C tar -cf - --owner=0 --group=0 --numeric-owner --mtime=@0 --sort=name "$TOP" ) | gzip -9n > "$OUT/lobbyfence-$p.tar.gz"
	# what came out: every file of the list, nothing else
	n="$(tar -tzf "$OUT/lobbyfence-$p.tar.gz" | grep -v '/$' | wc -l)"
	[ "$n" -eq "$(wc -l < "$WORK/$p.list")" ] || { echo "$p: $n files in the package, $(wc -l < "$WORK/$p.list") expected" >&2; exit 1; }
	printf '%-44s %4s files %8s bytes\n' "$OUT/lobbyfence-$p.tar.gz" "$n" "$(wc -c < "$OUT/lobbyfence-$p.tar.gz")"
done
( cd "$OUT" && sha256sum lobbyfence-*.tar.gz > SHA256SUMS )
echo "checksums: $OUT/SHA256SUMS"
