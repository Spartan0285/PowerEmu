import subprocess,struct,sys
# cursorshape.py capture.png gx gy : ASCII of the host-drawn cursor, 1 char per guest px
f,gx,gy=sys.argv[1],int(sys.argv[2]),int(sys.argv[3])
subprocess.run(['sips','-s','format','bmp',f,'--out','/tmp/cs.bmp'],capture_output=True)
d=open('/tmp/cs.bmp','rb').read(); off=struct.unpack_from('<I',d,10)[0]; w,h=struct.unpack_from('<ii',d,18); bpp=struct.unpack_from('<H',d,28)[0]; rs=((w*bpp//8+3)//4)*4
gw=1440; sc=w/gw; tb=abs(h)-round(932*sc)
def px(x,y):
    yy=h-1-y if h>0 else y; o=off+yy*rs+x*(bpp//8); return d[o]+d[o+1]+d[o+2]
rows=[]
for gyy in range(gy,gy+30):
    rows.append(''.join('#' if px(int((gxx+.5)*sc),int((gyy+.5)*sc)+tb)<150 else '.' for gxx in range(gx,gx+20)))
dark=[i for i,r in enumerate(rows) if '#' in r]
print('\n'.join(rows)); print('arrow height (guest px):', dark[-1]-dark[0]+1 if dark else 0)
