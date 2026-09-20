#!/bin/bash
# measure.sh LABEL QEMU_BIN=... : boot, start Warcraft, report menu fps.
S="$(cd "$(dirname "$0")" && pwd)"
W="${PE_BENCH_DIR:-$TMPDIR/poweremu-bench}"; mkdir -p "$W"
LABEL="$1"; shift

# Only one measurement at a time, per machine.  Three times in one session a
# result was quietly wrong because something else was running: a leftover VM
# holding the guest's SSH port, a compile competing for the CPU, and two
# measurement loops killing each other's VMs.  A stale lock is ignored only
# when its process is gone.
LOCK="$W/measure.lock"
if [ -e "$LOCK" ] && kill -0 "$(cat "$LOCK" 2>/dev/null)" 2>/dev/null; then
    echo "measure: another run is live (pid $(cat "$LOCK")) -- refusing" >&2
    exit 1
fi
echo $$ > "$LOCK"
trap 'rm -f "$LOCK"' EXIT
pkill -f TigerTest 2>/dev/null; sleep 3
rm -f "$W/tigertest.qcow2"
"${PE_HELPER:-$HOME/Developer/PowerEmu/build/PowerEmu.app/Contents/Helpers/PowerEmu VM.app}/Contents/MacOS/qemu-img" \
    create -f qcow2 -F qcow2 \
    -b "${PE_DISK:-$HOME/Library/Application Support/PowerEmu/Virtual Machines/Tiger.poweremu/Disks/tiger-fresh.qcow2}" \
    "$W/tigertest.qcow2" >/dev/null
env "$@" "$S/smoketest.sh" >/dev/null 2>&1 &
echo "[$LABEL] booting"
for i in $(seq 60); do sleep 4; nc -z -G 2 127.0.0.1 2299 >/dev/null 2>&1 && break; done
echo "[$LABEL] sshd up, waiting for the desktop"
for i in $(seq 60); do
    "$S/gsh.sh" "ps -axo command | grep -v grep | grep -q MacOS/Finder && echo yes" 2>/dev/null | grep -q yes && break
    sleep 5
done
echo "[$LABEL] desktop up, starting Warcraft"
for try in 1 2 3; do
    "$S/gsh.sh" "open '/Users/adam/Desktop/Warcraft III ROC [NoCD].app'" >/dev/null 2>&1
    for i in $(seq 24); do
        "$S/gsh.sh" "ps -axo command | grep -v grep | grep -q 'Warcraft III Folder' && echo yes" 2>/dev/null | grep -q yes && break 2
        sleep 5
    done
    echo "[$LABEL] launch attempt $try did not take"
done
"$S/gsh.sh" "ps -axo command | grep -v grep | grep -q 'Warcraft III Folder' && echo yes" 2>/dev/null | grep -q yes || {
    echo "[$LABEL] game never started"; pkill -f TigerTest; exit 1; }
echo "[$LABEL] running, settling"
python3 -u - "$LABEL" <<'PY'
import socket, json, os, sys, time
s = socket.socket(socket.AF_UNIX); s.connect(os.path.expandvars("$TMPDIR/pe-test.qmp"))
f = s.makefile('rwb'); f.readline()
def cmd(c):
    f.write((json.dumps(c) + "\n").encode()); f.flush()
    while True:
        r = json.loads(f.readline())
        if 'return' in r or 'error' in r: return r
cmd({"execute": "qmp_capabilities"})
def perf():
    r = cmd({"execute": "qom-get", "arguments": {
        "path": "/machine/peripheral/gpu0", "property": "perf"}})
    return dict(kv.split('=') for kv in r['return'].split())
time.sleep(60)
print("== %s" % sys.argv[1])
p0, t0 = perf(), time.time()
for i in range(4):
    time.sleep(15)
    p1, t1 = perf(), time.time()
    fr = int(p1['frames']) - int(p0['frames'])
    print("  window %d: %.1f fps  (%.0f draws/frame)" % (
        i + 1, fr / (t1 - t0), (int(p1['draws']) - int(p0['draws'])) / max(fr, 1)))
    p0, t0 = p1, t1
PY
pkill -f TigerTest
