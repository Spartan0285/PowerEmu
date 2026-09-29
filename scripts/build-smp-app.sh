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
export POWEREMU_SMP=1
export POWEREMU_QEMU_BINARY="$QEMU_SRC/build-smp/qemu-system-ppc64-unsigned"
export POWEREMU_QEMU_IMG="$QEMU_SRC/build-smp/qemu-img"
export POWEREMU_OPENBIOS="$FIRMWARE"
export POWEREMU_HELPER_STAGE="$ROOT/build/smp/PowerEmu VM.app"
export POWEREMU_APP_OUT="${POWEREMU_APP_OUT:-$ROOT/build/PowerEmu Integration.app}"
exec bash "$ROOT/scripts/build-app.sh"
