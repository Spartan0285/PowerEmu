#!/bin/sh
set -eu
repo=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
receipt="$repo/build/harmony-stall-2026-10-15/guest-agent-integration"
mkdir -p "$receipt"
log="$receipt/run.log"
out=$(mktemp "${TMPDIR:-/tmp}/guest-agent-transport.XXXXXX")
trap 'rm -f "$out"' EXIT
if swiftc "$repo/app/Sources/PowerEmu/AgentConnection.swift" \
  "$repo/app/Sources/PowerEmu/GuestAgent.swift" \
  "$repo/tests/GuestAgentTransportIntegration/main.swift" -o "$out" >"$log" 2>&1; then
  if "$out" >>"$log" 2>&1; then
    cat "$log"
  else
    status=$?
    cat "$log"
    exit "$status"
  fi
else
  status=$?
  cat "$log"
  exit "$status"
fi
