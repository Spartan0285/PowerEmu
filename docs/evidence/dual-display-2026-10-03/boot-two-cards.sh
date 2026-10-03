#!/bin/sh
# Tiger on two ppc-mac-gpu cards, each with a capture harness standing in for
# the app, so both screens have a DisplayChangeListener and the GPU models
# are actually driven.  -snapshot: the user's disk is never written.
set -e
D=/private/tmp/claude-501/-Users-adam-PB-Firmware/d8fb27b8-cca0-4a78-8e8d-7082c2c105ce/scratchpad/dual
Q="/Users/adam/Developer/poweremu-qemu/build-smp/qemu-system-ppc64-unsigned"
FW="/Users/adam/Developer/PowerEmu/build/PowerEmu RC.app/Contents/Helpers/PowerEmu VM.app/Contents/Resources/firmware"
VM="$HOME/Library/Application Support/PowerEmu/Virtual Machines/Tiger.poweremu"
DISK="$VM/Disks/tiger-fresh.qcow2"
OUT=$D/run; rm -rf "$OUT"; mkdir -p "$OUT/s0" "$OUT/s1"
rm -f /tmp/pedual/d0.sock /tmp/pedual/d1.sock; mkdir -p /tmp/pedual

python3 $D/pdc.py /tmp/pedual/d0.sock --out "$OUT/s0" --interval 20 > "$OUT/cap0.log" 2>&1 &
python3 $D/pdc.py /tmp/pedual/d1.sock --out "$OUT/s1" --interval 20 > "$OUT/cap1.log" 2>&1 &
sleep 2

"$Q" -name DualTest -L "$FW" -nodefaults -vga none \
    -machine mac99,via=pmu -g 1024x768x32 \
    -device loader,addr=0x4000000,file="$FW/ppc-ndrvloader" \
    -m 1536 -snapshot -audio none \
    -smp 1 -accel tcg,thread=multi,tb-size=512 -cpu 7400 \
    -prom-env output-device=ttya -display none \
    -object poweremu-display,id=pd0,path=/tmp/pedual/d0.sock \
    -object poweremu-display,id=pd1,index=1,path=/tmp/pedual/d1.sock \
    -device ppc-mac-gpu,id=gpu0,vgamem_mb=64 \
    -device ppc-mac-gpu,id=gpu1,vgamem_mb=64 \
    -drive if=none,id=drive0,file.filename="$DISK",format=qcow2,media=disk \
    -device ide-hd,bus=ide.0,unit=0,drive=drive0,bootindex=0 \
    -serial "file:$OUT/console.log" \
    -qmp unix:/tmp/pedual/t.qmp,server=on,wait=off \
    > "$OUT/qemu.log" 2>&1
