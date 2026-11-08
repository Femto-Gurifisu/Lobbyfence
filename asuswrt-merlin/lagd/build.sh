#!/bin/sh
# Builds lf-lagd as a static ARM binary (runs on every ARM router - 32-bit
# userland on ARMv7 and ARMv8 kernels - with no libraries needed).
#
#   sh build.sh <path to an ARM gcc> [output]
#
# The shipped binary was built with FreshTomato's hndtools-arm-uclibc-7.5
# (gcc 7.5, uClibc-ng), from github.com/FreshTomato-Project/freshtomato-arm
# (release/src-rt-6.x.4708/toolchains/hndtools-arm-uclibc-7.5/usr/bin/arm-linux-gcc).
# For a native test build: sh build.sh gcc /tmp/lf-lagd
#
# SPDX-License-Identifier: GPL-3.0-or-later
set -e
CC="${1:?usage: sh build.sh <arm gcc> [output]}"
OUT="${2:-$(dirname "$0")/../bin/lf-lagd}"
case "$CC" in
	*arm*) "$CC" -static -Os -Wall -march=armv7-a -mfloat-abi=soft -o "$OUT" "$(dirname "$0")/lf-lagd.c"
	       "${CC%gcc}strip" "$OUT";;
	*) "$CC" -O2 -Wall -o "$OUT" "$(dirname "$0")/lf-lagd.c";;
esac
echo "built $OUT"
