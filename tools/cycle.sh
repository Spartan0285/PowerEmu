#!/bin/sh
# cycle.sh [ENV=val ...]: clean shutdown (falls back to monitor 'quit' after
# 5 min) then boot with the given env; log to /tmp/cycle.out.
{
  echo "$(date +%H:%M:%S) shutdown"
  if ! $(dirname "$0")/vmdown.sh; then
    echo "$(date +%H:%M:%S) clean shutdown did not finish in 20 min; NOT forcing (dirty journal breaks OpenBIOS boot)"
    exit 1
  fi
  echo "$(date +%H:%M:%S) boot $*"
  $(dirname "$0")/vmboot.sh "$@"
  echo "$(date +%H:%M:%S) done rc=$?"
} > /tmp/cycle.out 2>&1
