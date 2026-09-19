#!/bin/sh
# hmp.sh "cmd1" "cmd2" ... : send HMP commands to the QEMU monitor
{ for c in "$@"; do echo "$c"; sleep 0.15; done; sleep 0.3; } | nc 127.0.0.1 4444 | tr -d '\r' | grep -av "^(qemu)\|QEMU [0-9]" | grep -a . 
exit 0
