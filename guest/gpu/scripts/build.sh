#!/bin/sh
# Build the PowerEmu GPU kext on a PowerPC Mac (Xcode 2.5, 10.4u SDK) and
# bring the bundle back to guest/gpu/build.
#   Usage: guest/gpu/scripts/build.sh [host]        (default host pbg4)
# ditto in both directions, like guest/scripts/build.sh: the PPC Macs have
# no usable tar and Leopard's zip mangles bundles.
#
# The bundle arrives owned by whoever ran this.  kextload will refuse it
# until it is root:wheel inside the guest -- see the README.
set -e
cd "$(dirname "$0")/.."
host=${1:-pbg4}
REMOTE=PowerEmuGPUKext
tmp=$(mktemp -d /tmp/pe-gpu.XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/src"; cp -R Makefile src Resources "$tmp/src/"
ditto -c "$tmp/src" - | ssh -o ConnectTimeout=60 "$host" "
    mkdir -p $REMOTE && cd $REMOTE && rm -rf src Resources Makefile build &&
    ditto -x - . && make >&2 && ditto -c build -" > "$tmp/out.cpio"
rm -rf build && mkdir build && ditto -x "$tmp/out.cpio" build
ls build
