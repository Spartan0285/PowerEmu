#!/bin/bash
# Reproduce the combined experimental package without replacing the normal app.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_SRC="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
FIRMWARE="${POWEREMU_OPENBIOS:-$ROOT/build/smp/openbios-smp.elf}"
EXPECTED=8f01bb0c217d692f1ae228f57508417cdbd100f422d626a2cfe6a422cdbe747b
[ -f "$FIRMWARE" ] || { echo "Missing SMP firmware: $FIRMWARE (see docs/HARMONY-SMP-INTEGRATION.md)" >&2; exit 1; }
[ "$(shasum -a 256 "$FIRMWARE" | cut -d ' ' -f1)" = "$EXPECTED" ] || {
    echo "Firmware does not match the validated SMP handoff" >&2; exit 1;
}
[ -x "$QEMU_SRC/build-smp/qemu-system-ppc64-unsigned" ] || {
    echo "Build the merged PPC64 emulator in $QEMU_SRC/build-smp first (see integration document)" >&2; exit 1;
}
# build-smp is a SEPARATE build directory from build/, and nothing rebuilds it
# automatically.  0.3.3 shipped because of exactly that: the four-CPU work was
# committed and built in build/, tested there, and then this script quietly
# packaged a build-smp binary from two days earlier that still capped mac99 at
# two.  The app offered four CPUs, the emulator refused them, and the release
# was out before anyone ran that combination.
#
# So: refuse to package an emulator older than the sources it was built from,
# and prove it can do the thing the app will offer.
NEWEST_SRC=$(find "$QEMU_SRC/hw" "$QEMU_SRC/target" "$QEMU_SRC/include" \
                  -name '*.c' -o -name '*.h' -o -name '*.m' 2>/dev/null \
             | xargs stat -f '%m %N' 2>/dev/null | sort -rn | sed -n '1p' || true)
NEWEST_T=${NEWEST_SRC%% *}
BIN_T=$(stat -f %m "$QEMU_SRC/build-smp/qemu-system-ppc64-unsigned")
if [ -n "$NEWEST_T" ] && [ "$NEWEST_T" -gt "$BIN_T" ]; then
    echo "build-smp/qemu-system-ppc64-unsigned is older than the sources." >&2
    echo "  newest source: ${NEWEST_SRC#* }" >&2
    echo "Rebuild it before packaging:  ninja -C $QEMU_SRC/build-smp qemu-system-ppc64" >&2
    exit 1
fi
# The app offers up to four CPUs when it ships a capability record, so the
# emulator being packaged has to accept four.  Ask it.
# Capture rather than pipe into grep: grep -q closes the pipe on its first
# match, the emulator takes SIGPIPE, and under pipefail that fails the build.
CAP_OUT=$("$QEMU_SRC/build-smp/qemu-system-ppc64-unsigned" -nographic \
          -machine mac99 -smp 5 -m 128 2>&1 || true)
case "$CAP_OUT" in
    *"max CPUs supported by machine 'mac99' is 4"*) ;;
    *)  echo "the emulator in build-smp does not support four CPUs on mac99." >&2
        echo "Packaging it would offer a CPU count the emulator refuses." >&2
        echo "  it said: $CAP_OUT" >&2
        exit 1 ;;
esac

export POWEREMU_SMP=1
export POWEREMU_QEMU_BINARY="$QEMU_SRC/build-smp/qemu-system-ppc64-unsigned"
export POWEREMU_QEMU_IMG="$QEMU_SRC/build-smp/qemu-img"
export POWEREMU_OPENBIOS="$FIRMWARE"
export POWEREMU_HELPER_STAGE="$ROOT/build/smp/PowerEmu VM.app"
export POWEREMU_APP_OUT="${POWEREMU_APP_OUT:-$ROOT/build/PowerEmu Integration.app}"
exec bash "$ROOT/scripts/build-app.sh"
