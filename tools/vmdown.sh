#!/bin/sh
# Clean guest shutdown over SSH; waits for QEMU to exit.
pgrep -f qemu-run/qemu-system-ppc >/dev/null || exit 0
$(dirname "$0")/gssh.sh "sync; sync" >/dev/null 2>&1; sleep 2
$(dirname "$0")/gssh.sh "osascript -e 'tell application \"System Events\" to shut down'" >/dev/null 2>&1
for i in $(seq 1 600); do pgrep -f qemu-run/qemu-system-ppc >/dev/null || exit 0; sleep 2; done
echo "clean shutdown timed out" >&2; exit 1
