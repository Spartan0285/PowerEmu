#!/bin/sh
# cursorcheck.sh : compare the host-drawn arrow (window capture vs guest
# framebuffer diff) with the guest's hardware cursor registers
SP=$(cd "$(dirname "$0")" && pwd)
W=$($SP/winid | awk '{print $1}')
screencapture -x -o -l $W /tmp/cc_a.png; $SP/shot.sh cc_g >/dev/null
GW=$(sips -g pixelWidth $SP/cc_g.png | awk '/pixelWidth/{print $2}'); GH=$(sips -g pixelHeight $SP/cc_g.png | awk '/pixelHeight/{print $2}')
CW=$(sips -g pixelWidth /tmp/cc_a.png | awk '/pixelWidth/{print $2}'); CH=$(sips -g pixelHeight /tmp/cc_a.png | awk '/pixelHeight/{print $2}')
TB=$((CH - GH * CW / GW))   # windowed: capture includes the title bar
sips -s format bmp /tmp/cc_a.png --out /tmp/a.bmp >/dev/null 2>&1; sips -s format bmp $SP/cc_g.png --out /tmp/b.bmp >/dev/null 2>&1
REG=$($SP/hmp.sh 'xp /2wx 0x8800ff0c' | tail -1)
python3 - "$REG" $TB <<'PY'
import struct, collections, sys
r=sys.argv[1].split()
x=struct.unpack('<I',struct.pack('>I',int(r[1],16)))[0]; y=struct.unpack('<I',struct.pack('>I',int(r[2],16)))[0]
def load(p):
    d=open(p,'rb').read(); off=struct.unpack_from('<I',d,10)[0]; w,h=struct.unpack_from('<ii',d,18); bpp=struct.unpack_from('<H',d,28)[0]
    return d,off,w,abs(h),bpp,((w*bpp//8+3)//4)*4,h>0
A=load('/tmp/a.bmp'); B=load('/tmp/b.bmp'); TB=int(sys.argv[2]); SC=A[2]/B[2]
def px(I,x,y):
    d,off,w,h,bpp,rs,bu=I; yy=h-1-y if bu else y; o=off+yy*rs+x*(bpp//8); return d[o+2]+d[o+1]+d[o]
cnt=collections.Counter(); pts=collections.defaultdict(list)
for yy in range(4,B[3]-4):
    for xx in range(4,B[2]-4):
        if px(A,int(xx*SC+SC/2),int(yy*SC+SC/2)+TB)<120 and px(B,xx,yy)>330:
            k=(xx//16,yy//16); cnt[k]+=1; pts[k].append((xx,yy))
k=cnt.most_common(1)[0][0] if cnt else None
if k: print('guest hw cursor image top-left (%d,%d); host arrow dark pixels start (%d,%d)' % (x,y,min(q[0] for q in pts[k]),min(q[1] for q in pts[k])))
else: print('no arrow found; guest cursor', x, y)
PY
