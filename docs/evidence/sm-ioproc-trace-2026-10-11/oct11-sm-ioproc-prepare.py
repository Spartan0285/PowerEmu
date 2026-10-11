#!/usr/bin/env python3
"""Discovery half of the SM observer staging.  Read-only; no VM launch, no
publication, no audio client.

Runs while the guest is still at menu/loading, so that nothing expensive is
left to do after CUA reports READY -- doing all discovery after READY is the
strategy that failed before, as is a fixed absolute arm.  It writes a staged
proof; oct11-sm-ioproc-finalize.py revalidates it against a fresh read while
the owned VM is paused, and only then publishes.
"""
from pathlib import Path
import argparse,hashlib,json,struct,subprocess,sys,time

R=Path('/tmp/pe9800')
p=argparse.ArgumentParser()
p.add_argument('pid',type=int,help='owned emulator PID')
p.add_argument('guard',help='owned guard token/file, as the collector expects')
p.add_argument('label')
p.add_argument('--delay-sec',type=int,default=3)
p.add_argument('--window-sec',type=int,default=60)
a=p.parse_args()
assert 0<=a.delay_sec<=10,'delay must be 0..10'
assert 1<=a.window_sec<=60,'window must be 1..60'

def sh(*cmd,timeout=120):
    return subprocess.run(cmd,capture_output=True,text=True,timeout=timeout,check=True).stdout

def ssh(command):
    return subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',command],timeout=18).decode()

# -- one and only one Warcraft, named by the supported Tiger form -------------
ps=ssh("ps -axo pid,command | grep -v grep | grep '/Applications/Warcraft III Folder/Warcraft III'")
rows=[l for l in ps.splitlines() if l.strip()]
assert len(rows)==1,f'expected exactly one Warcraft process, saw {len(rows)}'
guest=int(rows[0].split()[0])

# -- typed object graph, stacks, code bodies ---------------------------------
CL='oct10-'+a.label.split('-',1)[1]      # collector demands an oct10- basename

# The collector's saved-stack pair is SAMPLED: it catches the IOProc on a
# thread stack only when it happens to be there, and otherwise rejects with
# 'no coherent validated saved-stack pair'.  finalize already retries; prepare
# did not, so one unlucky sample cost a whole owned window on 2026-10-11.
# Each attempt costs ~20s.
ARCHIVE=Path('/Users/adam/Developer/PowerEmu/docs/evidence/audio-handoff-2026-10-10')
def names_retained_evidence(label):
    if not ARCHIVE.is_dir(): return True          # cannot prove it is safe
    return any(f.name.startswith(label+'.') for f in ARCHIVE.iterdir())
assert not names_retained_evidence(CL),f'{CL} names retained evidence; refusing to clear it'

SUF=('.receipt.json','.verification.json','.reanalysis.json')
# first argument is the GUEST Warcraft pid, not the owned emulator pid
for _attempt in range(1,5):
    for _s in SUF: (R/(CL+_s)).unlink(missing_ok=True)
    subprocess.run(['python3',str(R/'oct10-coreaudio-scoped-data-collect.py'),
                    str(guest),a.guard,CL],capture_output=True,text=True,timeout=300)
    try:
        if json.loads((R/(CL+'.verification.json')).read_text()).get('accepted') is True:
            print(f'collector accepted on attempt {_attempt}',file=sys.stderr);break
    except Exception: pass
    try: _why=json.loads((R/(CL+'.verification.json')).read_text()).get('error')
    except Exception: _why='no verification written'
    print(f'attempt {_attempt}: {_why}',file=sys.stderr)
else:
    raise SystemExit('collector never produced an accepted capture in 4 attempts')
ver=json.loads((R/(CL+'.verification.json')).read_text())
assert ver.get('accepted') is True,f'ownership verification not accepted: {ver}'
rec=json.loads((R/(CL+'.reanalysis.json')).read_text()) if (R/(CL+'.reanalysis.json')).exists() else ver
full=json.loads((R/(CL+'.receipt.json')).read_text())
core_return=full['stack_helper']['core_return']
sm_return=full['stack_helper']['sm_return']
assert core_return%4==0 and core_return>=4096,f'implausible core return {core_return:#x}'
cand=full['snapshot']['candidates'][0]
assert cand['wrapper_return']==core_return and cand['inner_return']==sm_return,\
    'stack helper and coherent candidate disagree on the caller pair'
assert rec['pid']==guest,f"graph pid {rec['pid']} != live Warcraft {guest}"

base=int(str(rec['module_base']),16)
entry=base+0x5794
exit_=base+0x57e4
assert int(str(rec['bridge_target']),16)==entry,'bridge target is not SM base+0x5794'

# -- stack extents: page aligned, nonoverlapping, <=64 MiB each --------------
stacks=[]
for line in (R/(CL+'.stack-extents.txt')).read_text().split('\n'):
    if not line.strip():continue
    lo,hi=(int(x,16) for x in line.split())
    assert lo%4096==0 and hi%4096==0 and 0<hi-lo<=64*1024*1024,f'bad stack extent {lo:x}-{hi:x}'
    stacks.append((lo,hi))
stacks.sort()
for (l0,h0),(l1,_) in zip(stacks,stacks[1:]):
    assert h0<=l1,'overlapping stack extents'
assert 1<=len(stacks)<=32,f'{len(stacks)} stack extents; control holds 32'

# -- Miles callback context: channel+8, per the proven CarbonSound chain -----
# PrepSoundParamBlock derives private state from channel+4 and SoundComplete
# calls back through channel+8; the driver contract names the sound channel.
# Sixteen bytes of that callback identify a process class, not a PID, so it is
# recorded alongside -- never instead of -- the single-Warcraft inventory.
HELPER='oct10-miles-read-memory'
HELPER_MD5='262e93257cb1077cb68a9a8364ed2cb5'
blob=(R/HELPER).read_bytes()
assert hashlib.md5(blob).hexdigest()==HELPER_MD5,'read helper changed; refuse to stage'
subprocess.run(['python3',str(R/'guest-ssh.py'),'2319',
                f'cat > /tmp/{HELPER} && chmod 755 /tmp/{HELPER}'],input=blob,check=True,timeout=30)
assert ssh(f'md5 -q /tmp/{HELPER}').strip()==HELPER_MD5,'staged helper md5 mismatch'

def read(addr,n):
    b=subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',
                               f'/tmp/{HELPER} {guest} {addr:x} {n:x}'],timeout=18)
    assert len(b)==n,f'short read at {addr:#x}'
    return b

sh('python3',str(R/'oct10-read-miles-contract.py'),str(guest),a.label,timeout=120)
contract=json.loads((R/(a.label+'.driver-contract.json')).read_text())
assert contract['guest_pid']==guest and contract['live_code_match'] and contract['stable_format']
driver=next(x for x in contract['nodes'] if x['address']==contract['active_driver'])
channel=driver['sound_channel']
assert channel%4==0 and channel>=4096,f'implausible sound channel {channel:#x}'
ctx_addr=struct.unpack('>I',read(channel+8,4))[0]
assert ctx_addr%4==0 and ctx_addr>=4096,f'implausible channel+8 callback {ctx_addr:#x}'
ctx_words=list(struct.unpack('>4I',read(ctx_addr,16)))

# -- guest timestamp ABI and timebase ----------------------------------------
abi=json.loads((R/'oct10-sm-live-ownership.guest-abi.json').read_text())
assert abi['AudioTimeStamp_size']==64 and abi['hostTime_offset']==8 and abi['flags_offset']==56,'unexpected AudioTimeStamp ABI'
assert abi['timebase_numer']>0 and abi['timebase_denom']>0,'no guest timebase'

staged=dict(
    label=a.label,guest_pid=guest,owned_pid=a.pid,
    module_base=base,entry=entry,exit=exit_,
    entry_word=0x7c6802a6,exit_word=0x4e800020,
    device_id=rec['device_id'],
    hw=int(str(rec['hwstate']),16),
    record=int(str(rec['record']),16),
    device=int(str(rec['device']),16),
    bridge=int(str(rec['generated_bridge']),16),
    stacks=stacks,
    numer=abi['timebase_numer'],denom=abi['timebase_denom'],
    core_return=core_return,sm_return=sm_return,
    sound_channel=channel,context_address=ctx_addr,context_words=ctx_words,
    driver_contract=str(R/(a.label+'.driver-contract.json')),
    delay_sec=a.delay_sec,window_sec=a.window_sec,
    collector_label=CL,
    verification=str(R/(CL+'.verification.json')),
    stack_extents=str(R/(CL+'.stack-extents.txt')),
    receipt=str(R/(CL+'.receipt.json')),
    receipt_sha256=hashlib.sha256((R/(CL+'.receipt.json')).read_bytes()).hexdigest(),
    prepared_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC),
    note='Staged proof only.  ABL, core_return and Miles context are read fresh '
         'while paused in finalize; nothing here is a publication.',
)
out=R/(a.label+'.sm-prepare.json')
out.write_text(json.dumps(staged,indent=2)+'\n')
print(json.dumps({'prepared':True,'guest_pid':guest,'entry':hex(entry),'exit':hex(exit_),
                  'stack_extents':len(stacks),'context_address':hex(ctx_addr),'staged':str(out)},indent=2))
