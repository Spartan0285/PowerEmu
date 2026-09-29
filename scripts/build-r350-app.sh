#!/bin/bash
# Build an isolated Radeon 9800 Pro validation app. The ordinary PowerEmu
# bundle and the default Radeon 9200 device remain unchanged.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
QEMU_SRC="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
FIRMWARE="${POWEREMU_OPENBIOS:-$ROOT/build/r350/openbios-r350.elf}"

[ -x "$QEMU_SRC/build-r350/qemu-system-ppc64-unsigned" ] || {
    echo "Missing R350 emulator build" >&2; exit 1
}
[ -f "$FIRMWARE" ] || { echo "Missing R350 OpenBIOS image" >&2; exit 1; }

export POWEREMU_SMP=1
export POWEREMU_R350_EXPERIMENT=1
export POWEREMU_BUNDLE_ID="com.spartan0285.poweremu.r350test"
export POWEREMU_DISPLAY_NAME="PowerEmu 9800 Test"
export POWEREMU_QEMU_BINARY="$QEMU_SRC/build-r350/qemu-system-ppc64-unsigned"
export POWEREMU_QEMU_IMG="${POWEREMU_QEMU_IMG:-$QEMU_SRC/build-smp/qemu-img}"
export POWEREMU_OPENBIOS="$FIRMWARE"
export POWEREMU_HELPER_STAGE="$ROOT/build/r350/PowerEmu VM.app"
export POWEREMU_APP_OUT="${POWEREMU_APP_OUT:-$ROOT/build/PowerEmu 9800 Test.app}"
exec bash "$ROOT/scripts/build-app.sh"
