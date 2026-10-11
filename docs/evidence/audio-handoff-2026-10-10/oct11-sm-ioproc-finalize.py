#!/usr/bin/env python3
"""Publication half of the SM observer staging.

Revalidates the staged proof against a fresh read, pauses the owned VM,
publishes the 368-byte control once with the ready word last, and resumes.
Reads nothing new after the ready word is written.  No VM launch, no audio
client, no period change.
"""
from pathlib import Path
import argparse,hashlib,importlib.util,json,os,re,struct,subprocess,sys,time

R=Path('/tmp/pe9800')
READY_WORD=0x534d5031
p=argparse.ArgumentParser()
p.add_argument('label')
p.add_argument('ready_receipt')
p.add_argument('control')
p.add_argument('--qmp',required=True,help='owned QMP endpoint, as oct10-produced-owned.py takes it')
a=p.parse_args()

staged=json.loads((R/(a.label+'.sm-prepare.json')).read_text())
ready=json.loads(Path(a.ready_receipt).read_text())
assert ready.get('cue')=='READY' and ready.get('ready_verified') is True,'no verified CUA READY cue'
assert ready.get('owned_pid')==staged['owned_pid'],'READY receipt belongs to another emulator'
age=time.clock_gettime_ns(time.CLOCK_MONOTONIC)-ready['timestamp_ns']
assert 0<=age<120_000_000_000,f'stale READY receipt ({age/1e9:.1f}s); refuse publication'

def ssh(command):
    return subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',command],timeout=18).decode()

# -- the same single Warcraft, before and after ------------------------------
def one_warcraft():
    rows=[l for l in ssh("ps -axo pid,command | grep -v grep | grep '/Applications/Warcraft III Folder/Warcraft III'").splitlines() if l.strip()]
    assert len(rows)==1,f'expected exactly one Warcraft, saw {len(rows)}'
    return int(rows[0].split()[0])
assert one_warcraft()==staged['guest_pid'],'Warcraft PID changed since prepare; restage'

# -- fresh graph; identities must not have moved -----------------------------
subprocess.run(['python3',str(R/'oct10-coreaudio-scoped-data-collect.py'),
                str(staged['owned_pid']),ready['guard'],a.label+'-final'],check=True,timeout=300)
ver=json.loads((R/(a.label+'-final.verification.json')).read_text())
assert ver.get('accepted') is True,f'fresh ownership not accepted: {ver}'
fresh=json.loads((R/(a.label+'-final.reanalysis.json')).read_text())
for key,want in (('module_base','module_base'),('record','record'),('device','device'),
                 ('hwstate','hw'),('generated_bridge','bridge')):
    got=int(str(fresh[key]),16)
    assert got==staged[want],f'{key} moved {staged[want]:#x} -> {got:#x}; restage rather than reuse'
assert fresh['device_id']==staged['device_id'],'deviceID changed'

# -- stage the read helper, pinned by MD5, exactly as the other setups do ----
HELPER='oct10-miles-read-memory'
HELPER_MD5='262e93257cb1077cb68a9a8364ed2cb5'
blob=(R/HELPER).read_bytes()
assert hashlib.md5(blob).hexdigest()==HELPER_MD5,'read helper changed; refuse to stage'
subprocess.run(['python3',str(R/'guest-ssh.py'),'2319',
                f'cat > /tmp/{HELPER} && chmod 755 /tmp/{HELPER}'],input=blob,check=True,timeout=30)
remote_md5=ssh(f'md5 -q /tmp/{HELPER}').strip()
assert remote_md5==HELPER_MD5,f'staged helper md5 {remote_md5} != {HELPER_MD5}'

def read(addr,n):
    b=subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',
                               f"/tmp/{HELPER} {staged['guest_pid']} {addr:x} {n:x}"],timeout=18)
    assert len(b)==n,f'short read at {addr:#x}: {len(b)} of {n}'
    return b

# -- fresh vmmap, and the exact mapped span containing an address ------------
vm=ssh(f"/usr/bin/vmmap {staged['guest_pid']}")
assert re.search(r'Virtual Memory Map of process '+str(staged['guest_pid'])+r'\b',vm),'vmmap is for another process'
(R/(a.label+'.sm-final.vmmap.txt')).write_text(vm)
REGION=re.compile(r'^\S.*?\s([0-9a-f]+)-([0-9a-f]+)\s',re.M)
spans=sorted({(int(lo,16),int(hi,16)) for lo,hi in REGION.findall(vm) if int(hi,16)>int(lo,16)})
def span_of(addr,n):
    hit=[z for z in spans if z[0]<=addr and addr+n<=z[1]]
    assert len(hit)==1,f'mapping for {addr:#x}+{n} is absent or ambiguous ({len(hit)})'
    return hit[0]

# -- fresh ABL (record+0xa0) and its exact mapped span -----------------------
abl_ptr=struct.unpack('>I',read(staged['record']+0xa0,4))[0]
assert abl_ptr%4==0 and abl_ptr>=4096,'ABL pointer unaligned or low'
abl_lo,abl_hi=span_of(abl_ptr,4)
assert abl_lo<=abl_ptr and abl_ptr+4<=abl_hi,'ABL outside its own mapped span'

# -- fresh Miles callback context: 16 bytes, 4 big-endian instruction words ---
# The address is the channel+8 callback the staged contract proved; it is read
# fresh here rather than carried over, and must still be mapped executable
# code in THIS process.  Sixteen bytes identify a process class, not a PID --
# the single-Warcraft inventory above is what pins the instance.
ctx_addr=staged['context_address']
assert ctx_addr%4==0 and ctx_addr>=4096,'context address not aligned'
span_of(ctx_addr,16)
ctx_bytes=read(ctx_addr,16)
words=struct.unpack('>4I',ctx_bytes)
assert list(words)==staged['context_words'],'Miles context changed since prepare; restage'

# Caller path: the Core wrapper return and the SM inner return must still be
# the pair the staged coherent stack proved.  A generic IOProc assumption is
# explicitly not acceptable here.
freshfull=json.loads((R/(a.label+'-final.receipt.json')).read_text())
core_return=freshfull['stack_helper']['core_return']
assert core_return==staged['core_return'],'Core caller return moved; restage'
assert freshfull['stack_helper']['sm_return']==staged['sm_return'],'SM inner return moved; restage'
assert core_return%4==0 and core_return>=4096,'implausible Core return'

# -- pack: the ready word stays zero until the very last write ---------------
fields=[0,1,staged['entry'],staged['exit'],staged['entry_word'],staged['exit_word'],
        staged['device_id'],staged['hw'],staged['record'],staged['device'],staged['bridge'],
        abl_ptr,abl_lo,abl_hi,len(staged['stacks']),staged['numer'],staged['denom'],
        staged['delay_sec'],staged['window_sec'],core_return,0,ctx_addr,*words]
assert len(fields)==26
nonce=int.from_bytes(os.urandom(8),'little') or 1
flat=[]
for lo,hi in staged['stacks']:flat+= [lo,hi]
flat+=[0]*(64-len(flat))
config=struct.pack('<26IQ64I',*fields,nonce,*flat)
assert len(config)==368,len(config)

ns={};src=(R/'oct10-produced-owned.py').read_text().split("if sys.argv[1]=='guard':")[0]
exec(src,ns);qmp=ns['qmp']

control=Path(a.control)
control.write_bytes(bytes(368));os.chmod(control,0o600)
qmp(a.qmp,'stop')
status=qmp(a.qmp,'query-status')
assert status['running'] is False and status['status']=='paused','owned VM did not pause; refuse to publish'
try:
    assert one_warcraft()==staged['guest_pid'],'Warcraft changed while paused'
    fd=os.open(str(control),os.O_WRONLY)
    os.pwrite(fd,config,0);os.fsync(fd)
    os.pwrite(fd,struct.pack('<I',READY_WORD),0);os.fsync(fd)
    os.close(fd)
    published=True
finally:
    qmp(a.qmp,'cont')

receipt=dict(
    label=a.label,published=published,
    fresh_ownership_verified=True,fresh_context_verified=True,fresh_sites_verified=True,
    guest_timestamp_abi_verified=True,published_while_owned_vm_paused=True,
    control=str(control),control_sha256=hashlib.sha256(control.read_bytes()).hexdigest(),
    nonce=nonce,owned_pid=staged['owned_pid'],guest_pid=staged['guest_pid'],
    entry=staged['entry'],exit=staged['exit'],core_return=core_return,
    abl=abl_ptr,abl_lo=abl_lo,abl_hi=abl_hi,
    context_address=ctx_addr,context_words=list(words),
    stack_count=len(staged['stacks']),
    delay_sec=staged['delay_sec'],window_sec=staged['window_sec'],
    ready_receipt=a.ready_receipt,ready_age_sec=age/1e9,
    prepare=str(R/(a.label+'.sm-prepare.json')),
    fresh_verification=str(R/(a.label+'-final.verification.json')),
    published_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC),
    caveat='Publication only.  Proves staging, not timely presentation or sound quality.',
)
rp=R/(a.label+'.sm-publish-receipt.json');rp.write_text(json.dumps(receipt,indent=2)+'\n')
print(json.dumps({'published':published,'control_sha256':receipt['control_sha256'],
                  'nonce':nonce,'receipt':str(rp)},indent=2))
