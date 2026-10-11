#!/usr/bin/env python3
"""Observer-staged owned window, driven interactively.

Same shape as oct11-drive.py, but staged through oct11-sm-stage-observer.py
so the VM actually carries the SM IOProc plugin -- the trace cannot run on an
observer-free VM.  Launches via the NoCD applet on the guest Desktop (the only
route that gets past the CD check), waits for the game to render, then hands
control over so Adam can click through to the Prologue while this keeps the
clock and runs prepare on command.

Commands in /tmp/pe9800/oct11-trace.cmd:
  shot NAME | click X Y | key QCODE | wait N | prepare | done
"""
import json,re,socket,subprocess,time
from pathlib import Path

R=Path('/tmp/pe9800');LABEL='oct11-trace7'
SM_BASE='0x162ab000'
NOCD='/Users/adam/Desktop/Warcraft III ROC [NoCD].app'
CMD=R/'oct11-trace7.cmd';STATE=R/'oct11-trace7.state'
SCREEN=(1680,1050);SOFT_DEADLINE=445.0
T0=time.monotonic();LOG=[]

def say(*a):
    line=f'[{time.monotonic()-T0:6.1f}s] '+' '.join(str(x) for x in a)
    print(line,flush=True);LOG.append(line)
def left(): return SOFT_DEADLINE-(time.monotonic()-T0)
def ssh(cmd,timeout=30):
    p=subprocess.run(['python3',str(R/'guest-ssh.py'),'2319',cmd],capture_output=True,timeout=timeout)
    return p.returncode,p.stdout.decode('utf-8','replace'),p.stderr.decode('utf-8','replace')
class QMP:
    def __init__(self,path):
        self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(20);self.s.connect(path)
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
QSOCK=None
def with_qmp(fn):
    """Open, act, close.  The QMP unix socket is server=on,wait=off, i.e.
    ONE client at a time: holding it open made finalize's connect fail with
    ECONNREFUSED and cost an owned window."""
    q=QMP(QSOCK)
    try: return fn(q)
    finally: q.close()

def _ax(v,span): return max(0,min(32767,int(v*32767/span)))
def click(q,x,y):
    q.x('input-send-event',{'events':[
        {'type':'abs','data':{'axis':'x','value':_ax(x,SCREEN[0])}},
        {'type':'abs','data':{'axis':'y','value':_ax(y,SCREEN[1])}}]})
    time.sleep(0.3)
    q.x('input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':True}}]})
    time.sleep(0.12)
    q.x('input-send-event',{'events':[{'type':'btn','data':{'button':'left','down':False}}]})
def key(q,code):
    for d in (True,False):
        q.x('input-send-event',{'events':[{'type':'key','data':{'down':d,
             'key':{'type':'qcode','data':code}}}]});time.sleep(0.06)
def emulator():
    hit=[]
    for row in subprocess.check_output(['ps','-ax','-o','pid,command'],text=True).splitlines():
        m=re.match(r'\s*(\d+)\s+(.*)',row)
        if m and '/Contents/MacOS/qemu-system-ppc' in m[2] and 'Depth Wait QA.app' in m[2] \
           and 'oct08-autonomous-support' in m[2]: hit.append((int(m[1]),m[2]))
    return hit
def game():
    _,out,_=ssh("ps -axww -o pid,%cpu,command | grep -v grep | grep -i warcraft | grep -v osascript")
    return [l for l in out.splitlines() if l.strip()]
def gpid():
    rows=game()
    return int(rows[0].split()[0]) if rows else None
def cpu():
    rows=game()
    if not rows: return None
    try: return float(rows[0].split()[1])
    except Exception: return None
def publish(status,note=''):
    STATE.write_text(json.dumps({'status':status,'budget_left':round(left(),1),
                                 'cpu':cpu() if status not in ('down','starting') else None,
                                 'guest_pid':gpid() if status not in ('down','starting') else None,
                                 'note':note})+'\n')

_PRESTAGED=(R/(LABEL+'.sm-stage.json')).exists() and \
    json.loads((R/(LABEL+'.sm-stage.json')).read_text()).get('status')=='staged'
if not _PRESTAGED:
    # A previous owned run's emulator can still be shutting down.
    _w=time.monotonic()
    while emulator():
        assert time.monotonic()-_w<60,'an owned emulator is still running after 60s'
        time.sleep(2)
CMD.write_text('');publish('starting')
OWNED=None
try:
    _sf=R/(LABEL+'.sm-stage.json')
    if _sf.exists() and json.loads(_sf.read_text()).get('status')=='staged':
        say('already staged by hand; attaching to the VM it launched')
    else:
        subprocess.run(['python3',str(R/'oct11-sm-stage-observer.py'),'stage',LABEL,
                        '--sm-base',SM_BASE],check=True,timeout=180)
        say('observer staged')
    try:
        boot=time.monotonic()
        while not emulator():
            assert time.monotonic()-boot<90,'no VM in 90s'
            time.sleep(1)
        meta=json.loads(subprocess.check_output(
            ['python3',str(R/'oct11-sm-stage-observer.py'),'register',LABEL],text=True,timeout=60))
        OWNED=meta['pid'];say('guard registered:',OWNED,'seconds_left',meta.get('seconds_left'))
        while True:
            assert left()>60
            rc,out,_=ssh('echo up',timeout=12)
            if rc==0 and 'up' in out: break
            time.sleep(3)
        for _ in range(20):
            rc,out,_=ssh("ps -axo command | grep -v grep | grep -c 'Dock.app/Contents/MacOS/Dock'",timeout=20)
            if out.strip().isdigit() and int(out.strip())>=1: break
            time.sleep(3)
        say('desktop ready at',f'{time.monotonic()-T0:.0f}s')

        # The collector VERIFIES these three helpers in the guest's /tmp; it
        # never uploads them, and a fresh boot has an empty /tmp.  Missing
        # them reads as 'remote helper differs', which cost a window.
        import hashlib
        for _n in ('oct10-coreaudio-stack-snapshot','oct10-miles-read-memory',
                   'oct10-task-region-query'):
            _b=(R/_n).read_bytes()
            subprocess.run(['python3',str(R/'guest-ssh.py'),'2319',
                            f'cat > /tmp/{_n} && chmod 755 /tmp/{_n}'],
                           input=_b,check=True,timeout=60)
            _rc,_o,_=ssh(f'/sbin/md5 -q /tmp/{_n}',timeout=25)
            assert hashlib.md5(_b).hexdigest() in _o,f'helper {_n} did not stage'
        say('three guest helpers staged and hash-matched')

        QSOCK=meta['qmp']
        ssh(f'open -a "{NOCD}" 2>&1 | cat',timeout=45)
        for _ in range(20):
            time.sleep(4)
            if game(): break
        assert game(),'the NoCD applet never produced a game process'
        while left()>150:
            c=cpu()
            if c and c>40: break
            time.sleep(4)
        say('rendering at cpu',cpu(),'guest pid',gpid())
        with_qmp(lambda q: q.x('screendump',{'filename':str(R/f'{LABEL}.menu.ppm')}))
        publish('click-now','main menu is up; Single Player > Campaign > Exodus of the Horde > Chapter One > Play')
        say('MENU UP -- waiting for navigation')
        # Two windows were lost waiting to be TOLD the cinematic had started.
        # Give the navigation a generous slot, then go anyway: tracing menu
        # music is a worse outcome than tracing nothing, but only slightly,
        # and an explicit command still fires immediately.
        AUTO_AT=time.monotonic()+150
        fired=False

        while left()>70:
            lines=[l.strip() for l in CMD.read_text().splitlines() if l.strip()]
            if not lines and not fired and time.monotonic()>AUTO_AT and left()>200:
                say('no command after 150s; starting the trace anyway')
                lines=['shot ingame','prepare','finalize']
            if not lines: time.sleep(1.5);continue
            if any(l.startswith(('prepare','finalize','run')) for l in lines): fired=True
            CMD.write_text('');stop=False
            for line in lines:
                p=line.split()
                try:
                    if p[0]=='click':
                        with_qmp(lambda q: click(q,int(p[1]),int(p[2])));say(f'click {p[1]},{p[2]}')
                    elif p[0]=='key': with_qmp(lambda q: key(q,p[1]));say(f'key {p[1]}')
                    elif p[0]=='wait': time.sleep(min(float(p[1]),max(0,left()-80)));say(f'wait {p[1]}')
                    elif p[0]=='shot':
                        f=R/f'{LABEL}.{p[1]}.ppm'
                        with_qmp(lambda q: q.x('screendump',{'filename':str(f)}))
                        say(f'shot {p[1]} cpu={cpu()}')
                    elif p[0]=='prepare':
                        gp=R/(LABEL+'.produced-guard.json')
                        say(f'prepare: owned {OWNED} guard {gp}')
                        r=subprocess.run(['python3',str(R/'oct11-sm-ioproc-prepare.py'),
                                          str(OWNED),str(gp),LABEL],
                                         capture_output=True,text=True,
                                         timeout=max(30,int(left()-80)))
                        (R/(LABEL+'.prepare.out')).write_text((r.stdout or '')+'\n--- stderr ---\n'+(r.stderr or ''))
                        say('prepare rc',r.returncode,'->',LABEL+'.prepare.out')
                    elif p[0]=='finalize':
                        if left()<150:
                            say(f'refusing finalize: only {left():.0f}s left, '
                                f'needs ~70s to publish plus a 63s window');continue
                        g=json.loads((R/(LABEL+'.produced-guard.json')).read_text())
                        ready=R/(LABEL+'.ready.json')
                        # ready_verified means a human confirmed the guest is in
                        # the traced state.  Adam said so in chat and a screendump
                        # is retained; ready_method records exactly that, rather
                        # than letting the flag imply a CUA cue it did not come from.
                        ready.write_text(json.dumps(dict(
                            label=LABEL,cue='READY',ready_verified=True,
                            ready_method='user confirmed in chat that the Prologue '
                                         'cinematic is running; screendump retained',
                            owned_pid=g['owned_pid'],guest_pid=gpid(),
                            timestamp_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC)))+'\n')
                        say('finalize: publishing')
                        r=subprocess.run(['python3',str(R/'oct11-sm-ioproc-finalize.py'),
                                          LABEL,str(ready),str(R/(LABEL+'.control')),
                                          '--qmp',QSOCK],
                                         capture_output=True,text=True,
                                         timeout=max(60,int(left()-80)))
                        (R/(LABEL+'.finalize.out')).write_text((r.stdout or '')+'\n--- stderr ---\n'+(r.stderr or ''))
                        say('finalize rc',r.returncode,'->',LABEL+'.finalize.out')
                        if r.returncode==0:
                            # plugin arms at publication+3s and records for 60s
                            w=min(75,max(0,left()-60));say(f'armed; holding {w:.0f}s for the window')
                            time.sleep(w)
                            say('window elapsed; cpu',cpu())
                    elif p[0]=='run':
                        CMD.write_text('prepare\nfinalize\n')
                        say('run: queued prepare then finalize')
                    elif p[0]=='done': stop=True;say('done requested');break
                    else: say('unknown command:',line)
                except Exception as e:
                    say('command failed:',line,type(e).__name__,e)
            publish('ready' if not stop else 'finishing')
            if stop: break
        say('exiting; budget left',round(left(),1))
    finally:
        say('--- stopping the identified owned VM ---')
        if QSOCK:
            try: with_qmp(lambda q: q.x('quit'));say('QMP quit sent')
            except Exception as e: say('quit error:',type(e).__name__,e)
        time.sleep(3)
        for _ in range(12):
            if not emulator(): break
            time.sleep(1)
        say('emulator gone' if not emulator() else 'EMULATOR STILL PRESENT')
        try:
            subprocess.run(['python3',str(R/'oct11-sm-stage-observer.py'),'restore',LABEL],
                           check=True,timeout=180)
            say('app restored and re-signed')
        except Exception as e: say('restore failed:',type(e).__name__,e)
finally:
    publish('down')
    (R/(LABEL+'.probe.log')).write_text('\n'.join(LOG)+'\n')
