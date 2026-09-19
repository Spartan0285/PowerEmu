#!/bin/bash
set -e
# Locations (override with the environment):
#   POWEREMU_QEMU    QEMU checkout with a build/ directory (poweremu-qemu)
#   POWEREMU_VM_DIR  folder holding the guest disk, kexts.img and ATI ROM dumps
HERE="$(cd "$(dirname "$0")" && pwd)"
QEMU_SRC="${POWEREMU_QEMU:-$HOME/Developer/poweremu-qemu}"
[ -x "$QEMU_SRC/build/qemu-system-ppc-unsigned" ] || QEMU_SRC=/tmp/utm-qemu
VM_DIR="${POWEREMU_VM_DIR:-/Users/adam/QEMU Project}"
QEMU_BUILD="$QEMU_SRC/build/qemu-system-ppc-unsigned"
# Run a private copy: rebuilding in place under a running VM (with the host
# paging code back in from the file) can corrupt or crash the running QEMU.
mkdir -p /tmp/qemu-run
# Copy to a new file and rename it into place: overwriting the executable in
# place (same inode) leaves macOS with a stale cached code signature and the
# next launch is killed with "Code Signature Invalid".
cp -f "$QEMU_BUILD" /tmp/qemu-run/qemu-system-ppc-unsigned.new &&
    mv -f /tmp/qemu-run/qemu-system-ppc-unsigned.new /tmp/qemu-run/qemu-system-ppc-unsigned
QEMU="/tmp/qemu-run/qemu-system-ppc-unsigned"
FIRMWARE="$QEMU_SRC/pc-bios"
DISK="${DISK:-$VM_DIR/tiger-fresh.qcow2}"
# HFS+ scratch volume carrying the patched ATI kexts into the guest.
PROJECT_KEXTS="$VM_DIR/kexts.img"

# Networking. Set NET=off to boot with no NIC at all — useful for isolating
# boot hangs, since a new interface changes what Tiger does at login.
# IPv6 is off in the NAT: the host has no IPv6 route, and Tiger tries IPv6
# first, stalling every connection ~75 s before falling back to IPv4 (Software
# Update then fails with "timed out (-1001)").
if [ "${NET:-on}" = "off" ]; then
    NETARGS="-nic none"
else
    NETARGS="-netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2222-:22 -device sungem,netdev=net0"
fi
TRACELOG="/tmp/gpu_trace.log"
OPENBIOS="$FIRMWARE/openbios-ppc"
rm -f "$TRACELOG"
echo "=== Launching Tiger with AGP bridge on main PCI bus ==="

# Set compatible="uni-north" on PCI bridge so AppleMacRiscAGP matches,
# and set IOAGPFlags on GPU so it gets IOAGPDevice nub.
# Note: The ATI FCode ROM fails with "Cannot manage" in OpenBIOS — this is
# normal. The ndrvloader still attaches qemu_vga.ndrv to drive the display
# via the VBE DISPI interface. The ATY,Adagio@e path may or may not exist
# depending on whether FCode partially sets the device name.
BOOT_CMD='boot-command=" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['"'"'] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then " /pci@f2000000/QEMU,VGA@e" ['"'"'] find-device catch 0= if h# 4000000 encode-int " VRAM,totalsize" property device-end then boot'

# GPU placement.
#   AGP=off (default): card on the plain PCI bus (pci.2, 0xf2000000) next to
#     USB and mac-io. The guest sees AppleMacRiscPCI, so Quartz Extreme —
#     which Apple limits to AGP Radeons — does not engage. The BOOT_CMD above
#     tries to fake AGP by renaming this bridge; it never took effect.
#   AGP=on: card on the real uni-north AGP bus (pci.0) at slot 0x10, where a
#     real G4 puts it. The fake-AGP rename must NOT run here, or the PCI bus
#     would impersonate a second AGP bridge.
# AGP bridge emulation.
#   AGPBRIDGE (default on; =off for the old non-QE mode): present the uni-north PCI host bridge (the one this card
#     sits behind, alongside the boot disk and USB) as AGP-capable. Apple's
#     AppleMacRiscAGP then drives the bus instead of AppleMacRiscPCI, so the
#     GPU becomes an IOAGPDevice — which the R200 driver requires before it
#     will create an AGP GART and report AccelCaps (Quartz Extreme). On by
#     default since 2026-09-18; it also changes how the boot disk's bus is
#     driven, so AGPBRIDGE=off is the fallback if a boot misbehaves.
# HWCURSOR (default on; =off for the stock driver): boot with the patched QEMU
#   VGA NDRV in ndrv-hwcursor/, which gives Mac OS X a hardware cursor that
#   QEMU draws on the host. Without it the kernel draws a software cursor
#   whose saved background goes stale under GL windows (cursor-sized notches
#   in Chess).
#   The patched driver also carries display modes at this Mac's panel aspect
#   ratio (1440x932, 1280x828, 1152x746, 1680x1088); the GPU's EDID offers
#   them only with it.
if [ "${HWCURSOR:-on}" = "on" ]; then
    NDRV="$HERE/../ndrv/qemu_vga_hwc.ndrv"
    [ -f "$NDRV" ] || NDRV="$HERE/ndrv-hwcursor/qemu_vga_hwc.ndrv"
    export QEMU_PPC_NDRV="$NDRV"
    MODEARGS="-global ppc-mac-gpu.host-aspect-modes=on"
else
    unset QEMU_PPC_NDRV
    MODEARGS=""
fi
# AUDIO (default coreaudio; =none for silence): host backend for the emulated
#   Screamer sound chip, which Tiger drives with AppleScreamerAudio.
# FULLSCREEN=on starts in full-panel fullscreen (the whole display, no
#   bars at the guest's aspect ratio; Ctrl+Alt+F toggles, Ctrl+Alt+G frees
#   the mouse so the auto-hidden menu bar can be reached).
if [ "${FULLSCREEN:-off}" = "on" ]; then FSARGS="-full-screen"; else FSARGS=""; fi
# TABLET=on adds a USB tablet (absolute pointer) so the QEMU monitor's
# mouse_move can place the cursor exactly — used for scripted testing.
if [ "${TABLET:-off}" = "on" ]; then TABLETARGS="-device usb-tablet,bus=usb-bus.0"; else TABLETARGS=""; fi

# TRACE_GPU=on traces every GPU register access (hundreds of MB per hour and
# a real slowdown).  Off by default; one cheap event keeps the -D log file
# open so renderer warnings and timing lines still land in it.
if [ "${TRACE_GPU:-off}" = "on" ]; then GPUTRACE="-trace ppc_mac_gpu_*"; else GPUTRACE="-trace ppc_mac_gpu_realize"; fi

# TRACE_UNIN=on traces every uni-north PCI config access. Off by default: a
# guest spinning on a config register grew the trace to 9 GB in ~60 s.
if [ "${TRACE_UNIN:-off}" = "on" ]; then UNINTRACE="-trace unin_*"; else UNINTRACE=""; fi

# VERBOSE=on boots Tiger with -v, printing kernel and kext messages (and any
# panic) on screen instead of the grey Apple.
if [ "${VERBOSE:-off}" = "on" ]; then VERBOSEARGS="-prom-env boot-args=-v"; else VERBOSEARGS=""; fi

if [ "${AGPBRIDGE:-on}" = "on" ]; then
    BRIDGEARGS="-global uni-north-pci.agp-capable=on"
else
    BRIDGEARGS=""
fi

if [ "${AGP:-off}" = "on" ]; then
    GPU_BUS="bus=pci.0,addr=0x10,"
    BOOT_CMD='boot-command=boot'
else
    GPU_BUS=""
fi

# The shipped OpenBIOS blob in this tree predates the local source change that
# teaches the VGA PCI database about ATI 1002:5960 (Radeon 9200 / RV280).
# When that stale blob boots, OpenBIOS logs "Cannot manage 'VGA controller'...
# 1002 5960" and never creates the "screen" output device. Patch the one PCI
# table entry in-place on launch so firmware can enumerate the Radeon.
FIRMWARE="$FIRMWARE" python3 - <<'PY'
import os
from pathlib import Path

firmware = Path(os.environ["FIRMWARE"]) / "openbios-ppc"
backup = firmware.with_name("openbios-ppc.pre-rv280-patch")
offset = 0x30678
old = bytes.fromhex("12341111")  # QEMU VGA entry in the stale blob
new = bytes.fromhex("10025960")  # ATI Radeon 9200 / RV280

if firmware.exists():
    data = bytearray(firmware.read_bytes())
    if data[offset:offset + 4] == old:
        if not backup.exists():
            backup.write_bytes(data)
        data[offset:offset + 4] = new
        firmware.write_bytes(data)
        print("Patched OpenBIOS VGA table for ATI 1002:5960")
PY

exec "$QEMU" \
    -L "$FIRMWARE" -nodefaults -vga none -display cocoa 2>/tmp/qemu_stderr.log \
    -smp cpus=1,sockets=1,cores=1,threads=1 -machine mac99,via=pmu \
    -accel tcg,tb-size=512 -g 1024x768x32 \
    -device loader,addr=0x4000000,file="$FIRMWARE/ppc-ndrvloader" \
    -prom-env "$BOOT_CMD" \
    -m ${MEM:-2048} -audio ${AUDIO:-coreaudio} $MODEARGS $FSARGS \
    -device ppc-mac-gpu,${GPU_BUS}vgamem_mb=64,romfile="$VM_DIR/ati_ndrv_joy.rom",biosrom="$VM_DIR/ati_ret_9200_201_pciagp_full.rom" \
    $NETARGS \
    $BRIDGEARGS \
    $VERBOSEARGS \
    -usb -device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0 $TABLETARGS \
    -device ide-hd,bus=ide.0,unit=0,drive=drive0,bootindex=0 \
    -drive if=none,media=disk,id=drive0,file.filename="$DISK",discard=unmap,detect-zeroes=unmap \
    -drive if=none,media=disk,id=drive1,file="$PROJECT_KEXTS",format=raw \
    -device ide-hd,bus=ide.1,unit=0,drive=drive1 \
    -serial file:/tmp/guest_console.log \
    -monitor telnet:127.0.0.1:4444,server,nowait \
    $GPUTRACE \
    $UNINTRACE \
    -D "$TRACELOG"
