#!/bin/sh
# keepawake.sh [seconds] : tap Shift in the guest every 20 s (Tiger sleeps after 10 min idle)
SP=$(dirname "$0"); end=$(( $(date +%s) + ${1:-900} ))
while [ $(date +%s) -lt $end ] && pgrep -x qemu-system-ppc-unsigned >/dev/null; do
  $SP/hmp.sh 'sendkey shift' >/dev/null 2>&1; sleep 20
done
