#!/usr/bin/env python3
"""Offline exercise of oct11-sm-ioproc-finalize.py.

Touches no emulator, no guest, no QMP socket.  The "fresh capture" fixture is
the REAL accepted pair the 2026-10-11 run left behind
(oct10-smtrace-final.{receipt,verification}.json), so the identity gates are
tested against the values the machine actually produced -- including the
per-channel record that moved.
"""
import hashlib,json,os,shutil,struct,subprocess,sys,time
from pathlib import Path

R=Path('/tmp/pe9800')
LAB='oct11-offline'
FL='oct10-offline-final'
SRC='oct10-smtrace-final'          # the real accepted capture
ABL_PTR=0x17a00100   # aligned, inside the record's own mapped span in the real vmmap
GUARD={'owned_pid':4242,'qmp':'/tmp/stub.qmp'}
FAILS=[]

def check(name,ok,detail=''):
    print(('  PASS  ' if ok else '  FAIL  ')+name+(f'   {detail}' if detail else ''))
    if not ok: FAILS.append(name)

def write_fixtures(ready_age_ns=0,owned_pid=None,cue='READY'):
    (R/(LAB+'.produced-guard.json')).write_text(json.dumps(GUARD))
    (R/(LAB+'.ready.json')).write_text(json.dumps(dict(
        label=LAB,guest_pid=STAGED['guest_pid'],
        owned_pid=GUARD['owned_pid'] if owned_pid is None else owned_pid,
        ready_verified=True,cue=cue,
        timestamp_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC)-ready_age_ns)))

STAGED=json.loads((R/(LAB+'.sm-prepare.json')).read_text())
REAL_VMMAP=json.loads((R/(SRC+'.receipt.json')).read_text())['vmmap_before']

# ---- fakes -----------------------------------------------------------------
class Env:
    def __init__(self):
        self.qmp_calls=[]; self.paused=False; self.warcrafts=1
        self.collect_label=None; self.ctx=list(STAGED['context_words'])
        self.pause_ok=True
    def ssh(self,argv,**kw):
        # A stopped VM is not executing: SSH to the guest CANNOT answer.
        # The harness used to answer anyway, which is why finalize shipped
        # with a guest check after the pause that could never succeed.
        if self.paused:
            raise subprocess.CalledProcessError(255,argv,b'',b'Connection timed out')
        cmd=argv[-1]
        if cmd.startswith('md5 -q'): return b'262e93257cb1077cb68a9a8364ed2cb5\n'
        if 'vmmap' in cmd: return REAL_VMMAP.encode()
        if cmd.startswith('ps -axo'):
            return ''.join(f"  {STAGED['guest_pid']} /Applications/Warcraft III Folder/Warcraft III\n"
                           for _ in range(self.warcrafts)).encode()
        if '/tmp/oct10-miles-read-memory' in cmd:
            pr=cmd.split(); addr=int(pr[-2],16); n=int(pr[-1],16)
            if addr==RECORD+0xa0: return struct.pack('>I',ABL_PTR)
            if addr==STAGED['context_address']: return struct.pack('>4I',*self.ctx)[:n]
            return bytes(n)
        return b''
    def collect(self):
        self.collect_label=FL
        for suf in ('.receipt.json','.verification.json'):
            shutil.copy(R/(SRC+suf),R/(FL+suf))   # no .reanalysis: exercise the fallback
    def qmp(self,sock,cmd,*a,**k):
        self.qmp_calls.append(cmd)
        if cmd=='stop': self.paused=self.pause_ok
        if cmd=='cont': self.paused=False
        if cmd=='query-status':
            return {'running':not self.paused,'status':'paused' if self.paused else 'running'}
        return {}

RECORD=int(str(json.loads((R/(SRC+'.verification.json')).read_text())['record']),16)

SRC_TEXT=(R/'oct11-sm-ioproc-finalize.py').read_text()
def instrumented():
    s=SRC_TEXT
    reps=[
("subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',command],timeout=18).decode()",
 "E.ssh(['x',command]).decode()"),
("""    b=subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',
                               f"/tmp/{HELPER} {staged['guest_pid']} {addr:x} {n:x}"],timeout=18)""",
 "    b=E.ssh(['x',f\"/tmp/{HELPER} {staged['guest_pid']} {addr:x} {n:x}\"])"),
("""subprocess.run(['python3',str(R/'guest-ssh.py'),'2319',
                f'cat > /tmp/{HELPER} && chmod 755 /tmp/{HELPER}'],input=blob,check=True,timeout=30)""",
 "pass"),
("""    subprocess.run(['python3',str(R/'oct10-coreaudio-scoped-data-collect.py'),
                    str(staged['guest_pid']),str(R/(a.label+'.produced-guard.json')),FL],
                   capture_output=True,timeout=300)""",
 "    E.collect()"),
("FL='oct10-'+a.label.split('-',1)[1]+'-final'", f"FL={FL!r}"),
("""ns={};src=(R/'oct10-produced-owned.py').read_text().split("if sys.argv[1]=='guard':")[0]
exec(src,ns);qmp=ns['qmp']""","qmp=E.qmp"),
    ]
    for o,n in reps:
        assert s.count(o)==1,f'harness no longer matches finalize source:\n{o[:90]}'
        s=s.replace(o,n)
    return s

def run(env):
    sys.argv=['finalize',LAB,str(R/(LAB+'.ready.json')),str(R/(LAB+'.control')),'--qmp',GUARD['qmp']]
    g={'__name__':'__main__','E':env}
    out=None
    try:
        exec(compile(instrumented(),'finalize','exec'),g)
    except BaseException as e:
        out=f'{type(e).__name__}: {e}'
    return out

def clean():
    for f in (LAB+'.control',LAB+'.sm-publish-receipt.json',LAB+'.sm-final.vmmap.txt',
              FL+'.receipt.json',FL+'.verification.json',FL+'.reanalysis.json'):
        (R/f).unlink(missing_ok=True)

RETAINED=[R/('oct10-sm-scoped-retained'+s) for s in
          ('.receipt.json','.verification.json','.reanalysis.json')]
retained_before={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in RETAINED if p.exists()}

print('== 1. happy path (real accepted capture, record moved) ==')
clean();write_fixtures();E=Env();err=run(E)
check('completes without error',err is None,err or '')
if err is None:
    ctrl=(R/(LAB+'.control')).read_bytes()
    rc=json.loads((R/(LAB+'.sm-publish-receipt.json')).read_text())
    check('control is 368 bytes',len(ctrl)==368,str(len(ctrl)))
    check('ready word present',struct.unpack('<I',ctrl[:4])[0]==0x534d5031,hex(struct.unpack('<I',ctrl[:4])[0]))
    check('receipt hash matches control',rc['control_sha256']==hashlib.sha256(ctrl).hexdigest())
    check('nonce nonzero',rc['nonce']!=0)
    check('five flags true',all(rc[k] is True for k in
        ('fresh_ownership_verified','fresh_context_verified','fresh_sites_verified',
         'guest_timestamp_abi_verified','published_while_owned_vm_paused')))
    check('published true',rc['published'] is True)
    check('qmp stop,query,cont exactly once',E.qmp_calls==['stop','query-status','cont'],str(E.qmp_calls))
    check('VM resumed',E.paused is False)
    check('control mode 0600',oct(os.stat(R/(LAB+'.control')).st_mode)[-3:]=='600')
    check('fresh record adopted',rc['record']==RECORD and rc['record_refreshed'] is True,
          f"{rc['record']:#x} (staged {rc['staged_record']:#x})")
    check('ABL read from fresh record',rc['abl']==ABL_PTR,hex(rc['abl']))
    check('ABL inside its mapped span',rc['abl_lo']<=rc['abl']<rc['abl_hi'],
          f"{rc['abl_lo']:#x}..{rc['abl_hi']:#x}")
    check('core_return pinned',rc['core_return']==STAGED['core_return'],hex(rc['core_return']))
    check('owned_pid from guard',rc['owned_pid']==GUARD['owned_pid'])
    check('reanalysis fallback used (no .reanalysis.json)',
          not (R/(FL+'.reanalysis.json')).exists())
    # unpacked control agrees with the receipt
    f=struct.unpack('<26IQ64I',ctrl)
    check('packed record == receipt record',f[8]==rc['record'],hex(f[8]))
    check('packed abl/lo/hi',(f[11],f[12],f[13])==(rc['abl'],rc['abl_lo'],rc['abl_hi']))
    check('packed nonce',f[26]==rc['nonce'])
    check('packed entry/exit',(f[2],f[3])==(STAGED['entry'],STAGED['exit']))
    check('packed stack count',f[14]==len(STAGED['stacks']))
    check('reserved word 20 zero',f[20]==0)

def refuses(name,setup,needle):
    clean();E=Env();setup(E);err=run(E)
    check(name,err is not None and needle in err,err or 'no error raised')
    nr=not (R/(LAB+'.sm-publish-receipt.json')).exists()
    check(name+' -> nothing published',nr,'receipt was written' if not nr else '')

print('\n== 2. refusal paths ==')
refuses('stale READY receipt (127s)',lambda E:write_fixtures(ready_age_ns=127_000_000_000),'stale READY receipt')
refuses('READY for another emulator',lambda E:write_fixtures(owned_pid=9999),'another emulator')
refuses('unverified cue',lambda E:write_fixtures(cue='MAYBE'),'READY cue')
def two_wc(E):
    write_fixtures();E.warcrafts=2
refuses('two Warcrafts',two_wc,'expected exactly one Warcraft')
def ctx_moved(E):
    write_fixtures();E.ctx=[9,9,9,9]
refuses('Miles context changed',ctx_moved,'Miles context changed')
def no_pause(E):
    write_fixtures();E.pause_ok=False
clean();E=Env();no_pause(E);err=run(E)
check('unpaused VM refused',err is not None and 'did not pause' in (err or ''),err or '')
_c=R/(LAB+'.control')
check('unpaused VM -> control left all zero',
      _c.exists() and _c.read_bytes()==bytes(368),
      'control absent' if not _c.exists() else '')
check('unpaused VM -> VM resumed anyway','cont' in E.qmp_calls,str(E.qmp_calls))

print('\n== 2b. no guest question may be asked while paused ==')
clean();write_fixtures();E=Env();err=run(E)
check('publishes with SSH dead while paused',err is None,err or '')
check('  and the VM is resumed',E.paused is False)
check('  stop,query,cont exactly once',E.qmp_calls==['stop','query-status','cont'],str(E.qmp_calls))

print('\n== 3. evidence-destruction guard ==')
clean()
s=instrumented().replace(f"FL={FL!r}","FL='oct10-sm-scoped-retained'")
write_fixtures();E=Env()
sys.argv=['finalize',LAB,str(R/(LAB+'.ready.json')),str(R/(LAB+'.control')),'--qmp',GUARD['qmp']]
err=None
try: exec(compile(s,'finalize','exec'),{'__name__':'__main__','E':E})
except BaseException as e: err=f'{type(e).__name__}: {e}'
check('refuses a label outside the -final namespace',
      err is not None and 'refusing to clear files' in err,err or 'no error')
after={p:hashlib.sha256(p.read_bytes()).hexdigest() for p in RETAINED if p.exists()}
check('retained evidence byte-identical',after==retained_before,
      f'{len(after)}/{len(retained_before)} files')

clean()
print('\n'+('ALL PASS' if not FAILS else f'{len(FAILS)} FAILED: '+', '.join(FAILS)))
sys.exit(1 if FAILS else 0)
