#!/bin/sh
# Build PowerEmu Tools on a PowerPC Mac (Xcode 2.5/3.1, 10.4u SDK) and bring
# the two apps back to guest/build.   Usage: guest/scripts/build.sh [host]
# The G4 has no tar and Leopard's zip mangles bundles, so both directions use
# ditto's cpio archives.
set -e
cd "$(dirname "$0")/.."
host=${1:-g4}
REMOTE=PowerEmuGuest
tmp=$(mktemp -d /tmp/pe-guest.XXXXXX); trap 'rm -rf "$tmp"' EXIT
mkdir "$tmp/src"; cp -R Makefile src Resources "$tmp/src/"
ditto -c "$tmp/src" - | ssh -o ConnectTimeout=60 "$host" "
    ulimit -d unlimited 2>/dev/null
    mkdir -p $REMOTE && cd $REMOTE && rm -rf src Resources Makefile && ditto -x - . &&
    make all >&2 && ditto -c build -" > "$tmp/out.cpio"
rm -rf build && mkdir build && ditto -x "$tmp/out.cpio" build
rm -f build/PowerEmuAgent build/PowerEmuInstaller
ls build
