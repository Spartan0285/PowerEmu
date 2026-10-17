#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/harmony-menu-refresh.XXXXXX")
trap 'rm -f "$out"' EXIT
swiftc "$repo/app/Sources/PowerEmu/HarmonyMenus.swift" \
  "$repo/tests/HarmonyMenuRefresh/main.swift" -o "$out"
"$out"
