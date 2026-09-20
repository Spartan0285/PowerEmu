#!/bin/bash
# mmubench.sh LABEL QEMU_BIN=... : time a large random-access walk in the guest.
# Touching many pages in an unpredictable order is what makes the emulator's
# address-translation cache miss, so this isolates TLB sizing from everything
# else a game does.
S="$(cd "$(dirname "$0")" && pwd)"
W="${PE_BENCH_DIR:-$TMPDIR/poweremu-bench}"; mkdir -p "$W"
LABEL="$1"; shift
pkill -f TigerTest 2>/dev/null; sleep 3
rm -f "$W/tigertest.qcow2"
"${PE_HELPER:-$HOME/Developer/PowerEmu/build/PowerEmu.app/Contents/Helpers/PowerEmu VM.app}/Contents/MacOS/qemu-img" \
    create -f qcow2 -F qcow2 \
    -b "${PE_DISK:-$HOME/Library/Application Support/PowerEmu/Virtual Machines/Tiger.poweremu/Disks/tiger-fresh.qcow2}" \
    "$W/tigertest.qcow2" >/dev/null
env "$@" "$S/smoketest.sh" >/dev/null 2>&1 &
for i in $(seq 60); do sleep 4; nc -z -G 2 127.0.0.1 2299 >/dev/null 2>&1 && break; done
sleep 25
echo "== $LABEL"
"$S/gsh.sh" 'perl -e "
  use Time::HiRes qw(time);
  my \$n = 8_000_000;                 # 32 MB of indices over a 64 MB buffer
  my \$buf = q{ } x (64*1024*1024);
  my \$best = 1e9;
  for my \$r (1..4) {
    my \$t = time; my \$x = 12345; my \$s = 0;
    for (1..\$n) {
      \$x = (\$x * 1103515245 + 12345) & 0x3ffffff;    # scattered offsets
      \$s += vec(\$buf, \$x, 8);
    }
    my \$e = time - \$t; \$best = \$e if \$e < \$best;
  }
  printf qq{  random walk   best %.2fs\n}, \$best;
"' 2>&1 | grep -v Warning
pkill -f TigerTest
