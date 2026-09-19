#!/bin/sh
# shot.sh <name> : screendump the guest to scratchpad/<name>.png
SP=$(cd "$(dirname "$0")" && pwd)
(echo "screendump /tmp/_shot.ppm"; sleep 1) | nc 127.0.0.1 4444 >/dev/null
sips -s format png /tmp/_shot.ppm --out "$SP/$1.png" >/dev/null 2>&1 && echo "$SP/$1.png"
