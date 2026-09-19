#!/bin/sh
# vmboot.sh [ENV=val ...] : boot Tiger (AGP bridge on), retrying if OpenBIOS
# hangs in its USB driver (seen under heavy host load); waits for the desktop.
L="$(cd "$(dirname "$0")/../launcher" && pwd)/launch-tiger-ati.sh"
for attempt in 1 2 3 4; do
  pkill -9 -x qemu-system-ppc-unsigned 2>/dev/null; sleep 1
  rm -f /tmp/gpu_seq.log
  (env AGPBRIDGE=on "$@" nohup "$L" > /tmp/qemu_run.log 2>&1 &)
  ok=0
  for i in $(seq 1 450); do
    sleep 2
    if grep -aq "switching to new context" /tmp/guest_console.log 2>/dev/null; then ok=1; break; fi
  done
  if [ $ok = 0 ]; then echo "attempt $attempt: OpenBIOS hang, retrying" >&2; continue; fi
  for i in $(seq 1 400); do
    $(dirname "$0")/gssh.sh 'ps -axc | grep -q Dock && echo up' 2>/dev/null | grep -q up && { echo "desktop up (attempt $attempt, $((i*3))s after kernel)"; exit 0; }
    pgrep -x qemu-system-ppc-unsigned >/dev/null || break
    sleep 3
  done
  echo "attempt $attempt: kernel started but no desktop; leaving it running" >&2
  exit 1     # never kill a guest past OpenBIOS: it leaves the journal dirty
done
exit 1
