#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
out=$(mktemp "${TMPDIR:-/tmp}/agent-connection.XXXXXX")
trap 'rm -f "$out"' EXIT
swiftc "$repo/app/Sources/PowerEmu/AgentConnection.swift" \
  "$repo/tests/AgentConnection/main.swift" -o "$out"
"$out"
