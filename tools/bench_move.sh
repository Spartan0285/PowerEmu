#!/bin/sh
# bench_move.sh [N] : time N AppleScript moves of the front Finder window
# (each a compositor update) minus a 0-move baseline; prints moves/sec.
N=${1:-30}
run() {
  $(dirname "$0")/gssh.sh "osascript -e 'tell application \"Finder\"
    if (count of Finder windows) = 0 then make new Finder window
    set w to Finder window 1
    set p to position of w
    repeat with i from 1 to $1
      set position of w to {(item 1 of p) + (i mod 20) * 10, (item 2 of p) + (i mod 10) * 8}
    end repeat
    set position of w to p
  end tell'" >/dev/null 2>&1
}
t0=$(python3 -c 'import time;print(time.time())'); run 0; t1=$(python3 -c 'import time;print(time.time())')
run $N; t2=$(python3 -c 'import time;print(time.time())')
python3 -c "b=$t1-$t0; m=$t2-$t1; print(f'baseline {b:.2f}s, {$N} moves {m:.2f}s -> {$N/max(m-b,0.01):.2f} moves/s')"
