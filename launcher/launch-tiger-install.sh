#!/bin/bash
# Install Mac OS X Tiger onto tiger-fresh.qcow2, with ppc-mac-gpu attached.
# Boots the installer ISO; the new disk is empty and appears in Disk Utility.
#
# Once installed, switch to launch-tiger-ati.sh (point DISK at tiger-fresh.qcow2)
# to boot from the disk instead.
set -e
QEMU="/tmp/utm-qemu/build/qemu-system-ppc-unsigned"
FIRMWARE="/tmp/utm-qemu/pc-bios"
PROJECT="/Users/adam/QEMU Project"
DISK="$PROJECT/tiger-fresh.qcow2"
ISO="$PROJECT/Mac_OS_X_tiger.iso"
TRACELOG="/tmp/gpu_trace.log"
rm -f "$TRACELOG" /tmp/qemu_stderr.log /tmp/guest_console.log

BOOT_CMD='boot-command=" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['"'"'] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then boot'

# Teach the shipped OpenBIOS blob about ATI 1002:5960 (Radeon 9200 / RV280).
python3 - <<'PY'
from pathlib import Path
firmware = Path("/tmp/utm-qemu/pc-bios/openbios-ppc")
backup = firmware.with_name("openbios-ppc.pre-rv280-patch")
offset = 0x30678
old = bytes.fromhex("12341111")
new = bytes.fromhex("10025960")
if firmware.exists():
    data = bytearray(firmware.read_bytes())
    if data[offset:offset + 4] == old:
        if not backup.exists():
            backup.write_bytes(data)
        data[offset:offset + 4] = new
        firmware.write_bytes(data)
        print("Patched OpenBIOS VGA table for ATI 1002:5960")
    else:
        print("OpenBIOS already patched")
PY

echo "=== Installing Tiger to $DISK ==="
echo "In the installer: Utilities > Disk Utility, erase the 32 GB disk as"
echo "Mac OS Extended, quit Disk Utility, then continue the install."

exec "$QEMU" \
    -L "$FIRMWARE" -nodefaults -vga none -display cocoa 2>/tmp/qemu_stderr.log \
    -smp cpus=1,sockets=1,cores=1,threads=1 -machine mac99,via=pmu \
    -accel tcg,tb-size=512 -g 1024x768x32 \
    -device loader,addr=0x4000000,file="$FIRMWARE/ppc-ndrvloader" \
    -prom-env "$BOOT_CMD" \
    -m 2048 -audio none \
    -device ppc-mac-gpu,vgamem_mb=64,romfile="$PROJECT/ati_ndrv_joy.rom",biosrom="$PROJECT/ati_ret_9200_201_pciagp_full.rom" \
    -nic none -usb -device usb-mouse,bus=usb-bus.0 -device usb-kbd,bus=usb-bus.0 \
    -drive if=none,media=disk,id=drive0,file="$DISK",discard=unmap,detect-zeroes=unmap \
    -device ide-hd,bus=ide.0,unit=0,drive=drive0 \
    -drive if=none,media=cdrom,id=cd0,file="$ISO",readonly=on \
    -device ide-cd,bus=ide.1,unit=0,drive=cd0,bootindex=0 \
    -serial file:/tmp/guest_console.log \
    -monitor telnet:127.0.0.1:4444,server,nowait \
    -trace 'ppc_mac_gpu_*' \
    -D "$TRACELOG"
