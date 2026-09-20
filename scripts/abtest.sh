#!/bin/bash
# abtest.sh "label A" BIN_A "label B" BIN_B [rounds]
#
# Compare two emulator builds by frame rate, honestly.
#
# Absolute fps on this host is not stable: a fanless Mac running emulator
# benchmarks for an hour throttles, and a number measured earlier in the
# session is not comparable to one measured later.  Tonight that cost hours
# -- an unchanged build measured 27 fps early and 15 fps late, which looked
# exactly like a regression in whatever was being tested.
#
# So: run A and B alternately, back to back, and report the ratio of their
# medians. Drift affects both arms equally and divides out.
set -u
S="$(cd "$(dirname "$0")" && pwd)"
W="${PE_BENCH_DIR:-$TMPDIR/poweremu-bench}"; mkdir -p "$W"
LA="$1"; BA="$2"; LB="$3"; BB="$4"; ROUNDS="${5:-2}"

run_one() {   # run_one BIN -> prints fps values, one per line
    "$S/measure.sh" "$1" QEMU_BIN="$2" 2>/dev/null |
        awk '/window/ { print $3 }'
}

A_ALL=""; B_ALL=""
for r in $(seq "$ROUNDS"); do
    echo "--- round $r: $LA"
    a=$(run_one "$LA r$r" "$BA"); echo "$a" | tr '\n' ' '; echo
    echo "--- round $r: $LB"
    b=$(run_one "$LB r$r" "$BB"); echo "$b" | tr '\n' ' '; echo
    A_ALL="$A_ALL $a"; B_ALL="$B_ALL $b"
done

python3 - "$LA" "$LB" "$A_ALL" "$B_ALL" <<'PY'
import sys, statistics
la, lb = sys.argv[1], sys.argv[2]
a = [float(x) for x in sys.argv[3].split()]
b = [float(x) for x in sys.argv[4].split()]
if not a or not b:
    print("no samples"); raise SystemExit(1)
ma, mb = statistics.median(a), statistics.median(b)
print()
print("%-40s median %5.1f fps  (n=%d, %.1f-%.1f)" % (la, ma, len(a), min(a), max(a)))
print("%-40s median %5.1f fps  (n=%d, %.1f-%.1f)" % (lb, mb, len(b), min(b), max(b)))
print()
print("B/A = %.3f  (%+.1f%%)" % (mb / ma, (mb / ma - 1) * 100))
spread = (max(a) - min(a)) / ma
if spread > 0.15:
    print("WARNING: arm A spread is %.0f%% of its median -- the host is not "
          "stable enough to trust a small difference." % (spread * 100))
PY
