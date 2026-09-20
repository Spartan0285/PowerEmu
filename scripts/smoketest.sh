#!/bin/bash
# Boot the Tiger overlay headless with the current build and see how far it gets.
S="$(cd "$(dirname "$0")" && pwd)"
W="${PE_BENCH_DIR:-$TMPDIR/poweremu-bench}"; mkdir -p "$W"
H="$HOME/Developer/PowerEmu/build/PowerEmu.app/Contents/Helpers/PowerEmu VM.app/Contents"
R="$HOME/Library/Application Support/PowerEmu/Virtual Machines/Tiger.poweremu/ROMs"
rm -f "$W/testconsole.log" "$S/test.qmp"
"${QEMU_BIN:-$H/MacOS/qemu-system-ppc}" -name TigerTest -L "$H/Resources/firmware" -nodefaults -vga none -audio none \
  -smp 1 -machine mac99,via=pmu -accel tcg,tb-size=512 -g 1024x768x32 -m 2048 \
  -device loader,addr=0x4000000,file="$H/Resources/firmware/ppc-ndrvloader" \
  -prom-env 'boot-command=" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['"'"'] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then boot' \
  -prom-env output-device=ttya \
  -display none \
  -device ppc-mac-gpu,id=gpu0,vgamem_mb=128,romfile="$R/ati_ndrv_joy.rom",biosrom="$R/ati_ret_9200_201_pciagp_full.rom" \
  -global uni-north-pci.agp-capable=on -global ppc-mac-gpu.host-aspect-modes=on \
  -netdev user,id=net0,ipv6=off,hostfwd=tcp:127.0.0.1:2299-:22 -device sungem,netdev=net0 \
  -drive if=none,id=d0,file.filename="$W/tigertest.qcow2",format=qcow2,media=disk \
  -device ide-hd,bus=ide.0,unit=0,drive=d0,bootindex=0 \
  -serial "file:$W/testconsole.log" -qmp "unix:$TMPDIR/pe-test.qmp,server=on,wait=off" \
  > "$W/testqemu.log" 2>&1
