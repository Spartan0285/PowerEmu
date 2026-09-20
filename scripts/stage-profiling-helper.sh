#!/bin/bash
# Build a VM helper that can load QEMU plugins, without disturbing the one
# the app ships.
#
# Plugin instrumentation taxes TCG, so the profiling build must never become
# the build whose speed is measured -- that is the whole reason this is a
# separate bundle rather than a reconfigure of the usual one.
#
#   scripts/stage-profiling-helper.sh
#   POWEREMU_HELPER="$PWD/build/PowerEmu VM Prof.app" open build/PowerEmu.app
set -e
cd "$(dirname "$0")/.."
QEMU="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
SRC="build/PowerEmu.app/Contents/Helpers/PowerEmu VM.app"
OUT="build/PowerEmu VM Prof.app"
BIN="$QEMU/build-prof/qemu-system-ppc"

[ -d "$SRC" ] || { echo "build the app first: scripts/build-app.sh" >&2; exit 1; }
if [ ! -x "$BIN" ]; then
    echo "no plugins-enabled build. Configure one with:" >&2
    echo "  cd $QEMU && mkdir -p build-prof && cd build-prof &&" >&2
    echo "  ../configure --target-list=ppc-softmmu --enable-plugins \\" >&2
    echo "      --disable-docs --disable-sdl -Doptimization=3 -Db_lto=true \\" >&2
    echo "      -Dhardening=false && ninja qemu-system-ppc contrib/plugins/libpehot.dylib" >&2
    exit 1
fi

rm -rf "$OUT"
cp -R "$SRC" "$OUT"
cp "$BIN" "$OUT/Contents/MacOS/qemu-system-ppc"
# Copying through the filesystem picks up extended attributes that codesign
# refuses outright, so they go before the signature does.
xattr -cr "$OUT"
codesign --force --sign - --entitlements "$QEMU/accel/hvf/entitlements.plist" \
    "$OUT/Contents/MacOS/qemu-system-ppc" >/dev/null
codesign --force --sign - "$OUT" >/dev/null
codesign --force --sign - "$QEMU/build-prof/contrib/plugins/libpehot.dylib" >/dev/null
echo "staged $OUT"
echo "  plugin: $QEMU/build-prof/contrib/plugins/libpehot.dylib"
