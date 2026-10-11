#!/usr/bin/env python3
"""Inject real mouse/keyboard input into the owned guest, via QEMU.

This is the piece that unblocks unattended runs.  "Warcraft ignores synthetic
background clicks" was true of every host-side route we had tried, and it is
also true of the guest's own accessibility API: System Events reports
`click button "Cancel"` as succeeding while the Carbon dialog sits there
unmoved.  QEMU's `input-send-event` is a different thing entirely -- it posts
to the guest's USB tablet, so the guest cannot tell it from the user's hand.
Verified on 2026-10-11: the same Cancel button that ignored four
accessibility clicks was dismissed by the first injected one.

Coordinates are guest screen pixels (the VM boots 1680x1050) and are scaled
into the tablet's 0..32767 absolute range.  For anything the accessibility
API can see, ask it for the coordinates rather than reading pixels:

    osascript -e 'tell application "System Events" to tell process "X" \\
                  to get position of button "Cancel" of window 1'

Only one QMP client may be connected at a time, so this opens, acts, closes.

  oct11-guest-input.py <qmp-socket> click X Y
  oct11-guest-input.py <qmp-socket> move  X Y
  oct11-guest-input.py <qmp-socket> key   <qcode> [qcode ...]
"""
import json,socket,sys,time

SCREEN=(1680,1050)

class QMP:
    def __init__(self,path):
        self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(15);self.s.connect(path)
        self.f=self.s.makefile('rwb');json.loads(self.f.readline());self.x('qmp_capabilities')
    def x(self,cmd,args=None):
        self.f.write((json.dumps({'execute':cmd,**({'arguments':args} if args else {})})+'\n').encode())
        self.f.flush()
        while True:
            r=json.loads(self.f.readline())
            if 'error' in r: raise RuntimeError(r['error'])
            if 'return' in r: return r['return']
    def close(self):
        try: self.f.close();self.s.close()
        except Exception: pass

def _axis(v,span): return max(0,min(32767,int(v*32767/span)))

def move(q,x,y):
    q.x('input-send-event',{'events':[
        {'type':'abs','data':{'axis':'x','value':_axis(x,SCREEN[0])}},
        {'type':'abs','data':{'axis':'y','value':_axis(y,SCREEN[1])}}]})

def click(q,x,y,button='left'):
    move(q,x,y);time.sleep(0.25)
    q.x('input-send-event',{'events':[{'type':'btn','data':{'button':button,'down':True}}]})
    time.sleep(0.12)
    q.x('input-send-event',{'events':[{'type':'btn','data':{'button':button,'down':False}}]})

def key(q,*qcodes):
    for c in qcodes:
        q.x('input-send-event',{'events':[{'type':'key','data':{'down':True,
             'key':{'type':'qcode','data':c}}}]})
        time.sleep(0.05)
        q.x('input-send-event',{'events':[{'type':'key','data':{'down':False,
             'key':{'type':'qcode','data':c}}}]})
        time.sleep(0.05)

def main(argv):
    if len(argv)<3: raise SystemExit(__doc__)
    sock,verb=argv[1],argv[2]
    q=QMP(sock)
    try:
        if verb in ('click','move'):
            x,y=int(argv[3]),int(argv[4])
            assert 0<=x<SCREEN[0] and 0<=y<SCREEN[1],f'{x},{y} is off the {SCREEN} screen'
            (click if verb=='click' else move)(q,x,y);print(f'{verb} {x},{y}')
        elif verb=='key':
            key(q,*argv[3:]);print('key '+' '.join(argv[3:]))
        else: raise SystemExit(__doc__)
    finally: q.close()
    return 0

if __name__=='__main__': sys.exit(main(sys.argv))
