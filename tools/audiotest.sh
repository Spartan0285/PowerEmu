#!/bin/sh
# audiotest.sh : play tone.wav in the guest (QEMU must run with -audio wav to
# /tmp/screamer.wav) and analyse the capture
SP=$(cd "$(dirname "$0")" && pwd)
S0=$(stat -f %z /tmp/screamer.wav)
$SP/gssh.sh 'osascript -e "set volume 5"; osascript -e "tell application \"QuickTime Player\"" -e "open POSIX file \"/Users/adam/Desktop/tone.wav\"" -e "play document 1" -e "end tell" >/dev/null 2>&1'
sleep 10
$SP/gssh.sh 'osascript -e "tell application \"QuickTime Player\" to quit" >/dev/null 2>&1'
python3 - "$S0" <<'PY'
import struct, sys, collections
s0=max(int(sys.argv[1]),44)
d=open('/tmp/screamer.wav','rb').read()[s0:]
n=len(d)//4
L=[struct.unpack_from('<h',d,4*i)[0] for i in range(n)]
act=[i for i,v in enumerate(L) if abs(v)>500]
if not act: print('no signal'); sys.exit()
seg=L[act[0]:act[-1]]
zc=[i for i in range(1,len(seg)) if seg[i-1]<0<=seg[i]]
per=[zc[i+1]-zc[i] for i in range(len(zc)-1)]
runs=[];r=0
for v in seg:
    if abs(v)<200: r+=1
    else:
        if r>20: runs.append(r)
        r=0
print('tone %.2fs, cycles %d, periods %s, dropouts %d %s' % (len(seg)/44100, len(zc), collections.Counter(per).most_common(3), len(runs), runs[:8]))
PY
