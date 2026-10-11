"""Unscored setup only: trusted upload/read/current SP discovery; publish while paused. No VM launch."""
from pathlib import Path
import subprocess,sys,json,re,struct,time,hashlib,importlib.util
R=Path('/tmp/pe9800');spec=importlib.util.spec_from_file_location('admission_sites',R/'oct10-admission-sites.py');admission=importlib.util.module_from_spec(spec);spec.loader.exec_module(admission)
label=sys.argv[1];guest=int(sys.argv[2]);assert guest>1
stage=json.loads((R/(label+'.produced-stage.json')).read_text());meta=json.loads((R/'oct08-depthwait-native-current.json').read_text());g=json.loads(Path(meta['produced_guard']).read_text());assert meta['status']=='running' and meta['pid']==g['owned_pid'] and meta['prefix'].startswith(label+'.')
def age():
 x=subprocess.check_output(['ps','-p',str(meta['pid']),'-o','etime='],text=True).strip();assert '-' not in x;t=[int(i) for i in x.split(':')];return sum(v*60**i for i,v in enumerate(reversed(t)))
def gate():
 assert age()<stage['delay']-12,'Insufficient pre-arm setup margin; abort owned setup'
 assert time.clock_gettime_ns(time.CLOCK_MONOTONIC)<g['deadline_ns']-80000000000,'Insufficient480sec guard margin'
 assert subprocess.run(['kill','-0',str(g['guard_pid'])],capture_output=True).returncode==0,'Strict stop guard absent'
 assert subprocess.check_output(['ps','-p',str(meta['pid']),'-o','command='],text=True).strip()==g['owned_command']
def ssh(command,input=None):gate();return subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',command],input=input,timeout=18)
def read(addr,n):
 b=ssh(f'/tmp/oct10-miles-read-memory {guest} {addr:x} {n:x}');assert len(b)==n;return b
initial=ssh(f'ps -p {guest} -o command=').decode();assert 'Warcraft' in initial
for name in ['oct10-miles-read-memory','oct10-miles-thread-stack']:
 b=(R/name).read_bytes();ssh(f'cat > /tmp/{name} && chmod 755 /tmp/{name}',b)
vm=ssh(f'vmmap {guest}').decode();(R/(label+'.produced.vmmap.txt')).write_text(vm)
m=re.findall(r'^PEF binary\s+([0-9a-f]+)-([0-9a-f]+).*?/Applications/Warcraft III Folder/Miles Carbon Library',vm,re.M);assert len(m)==1;base=int(m[0][0],16)
pef=(R/'oct10-guest-Miles-Carbon-Library.pef').read_bytes();assert hashlib.sha256(pef).hexdigest()=='7a9dbeefbef77537097e8cec822014fe6bb40073b5d11de256cdd3cc426f3e41'
# Tentative sites were parsed at plugin install; different current mapping requires fresh stage/reboot, never silent reuse.
assert base==0x570000,'Runtime map differs from staged tentative site addresses'
manifest_text=Path(stage['manifest']).read_text();assert hashlib.sha256(manifest_text.encode()).hexdigest()==stage['manifest_sha256'],'Staged manifest changed'
live=read(base+0x200e0,0xdf4);admission_proof=admission.verify(manifest_text,base,live,pef);(R/(label+'.produced.admission-site-proof.json')).write_text(json.dumps(admission_proof,indent=2)+'\n');assert live==pef[0x200e0:0x20ed4];assert struct.unpack_from('>I',live,0x114)[0]==0x4800011d;livepath=R/(label+'.produced.live.bin');livepath.write_bytes(live)
code_lo=base+0x4600;code_hi=code_lo+459660
execution=json.loads(ssh(f'/tmp/oct10-miles-thread-stack {guest} {code_lo:x} {code_hi:x}'));ep=R/(label+'.produced.thread-stack.json');ep.write_text(json.dumps(execution,indent=2)+'\n');assert execution['pid']==guest and execution['errors']==execution['drops']==0
active=[r for r in execution['records'] if code_lo<=r['pc']<code_hi];assert active,'No verified active Miles PC; retry fresh setup, not blind arm'
for r in active:assert r['word_ok']==1 and r['word']==struct.unpack_from('>I',pef,r['pc']-base)[0]
subprocess.run(['python3',str(R/'oct10-miles-pef-sites.py'),'--base',hex(base),'--live',str(livepath),'--execution-json',str(ep),'--pid',str(guest),'--out',str(R/(label+'.produced.live-sites.result'))],check=True,stdout=subprocess.DEVNULL,timeout=15)
assert (R/(label+'.produced.live-sites.manifest.txt')).read_text().splitlines()[:5]==Path(stage['manifest']).read_text().splitlines()[:5],'Fresh callback/fill sites differ'
gate();subprocess.run(['python3',str(R/'oct10-read-miles-contract.py'),str(guest),label+'.produced'],check=True,stdout=subprocess.DEVNULL,timeout=100);gate()
c=json.loads((R/(label+'.produced.driver-contract.json')).read_text());assert c['guest_pid']==guest and c['live_code_match'] and c['stable_format'];driver=c['active_driver'];row=next(x for x in c['nodes'] if x['address']==driver)
assert row['chunk_bytes']==1024 and row['frames_per_chunk']==256 and row['channels']==2 and row['bytes_per_sample']==2 and row['rate']==44100 and row['maximum_batch_frames']==2048
regions=[]
for line in vm.splitlines():
 m=re.match(r'^(.+?)\s+([0-9a-f]+)-([0-9a-f]+)\s+\[.*?\]\s+(r[w-][x-])/[^ ]+',line)
 if m:regions.append((m[1].strip(),int(m[2],16),int(m[3],16),m[4]))
stacks=[x for x in regions if x[0]=='Stack' and x[3].startswith('rw')]
pcs=[r for r in active if base+0x200e0<=r['pc']<=base+0x20488 and r['toc']==c['toc']];assert pcs,'No fresh callback/fill active-PC SP sampled'
ss={(lo,hi) for r in pcs for name,lo,hi,perm in stacks if lo<=r['sp']<hi};assert len(ss)==1,'Absent/ambiguous callback stack range';stacklo,stackhi=next(iter(ss))
lo=min(row['buffer_bases']);hi=max(row['buffer_bases'])+8192
# Require every intervening byte be actual writable ordinaryRAM; no min/max across holes.
ram=sorted({(a,b) for n,a,b,p in regions if p.startswith('rw') and (n.startswith('MALLOC') or n.startswith('VM_ALLOCATE'))});cursor=lo
for a,b in ram:
 if a<=cursor<b:cursor=b
 if cursor>=hi:break
assert cursor>=hi,'Destination span has an unreadable/nonRAM gap; do not widen guesses'
b=read(driver,256);assert struct.unpack_from('>I',b,0xe6)[0]==1024 and [struct.unpack_from('>I',b,o)[0] for o in (0xa2,0xa6)]==row['buffer_bases'],'Driver destination identity changed'
assert ssh(f'ps -p {guest} -o command=').decode()==initial,'Process changed during setup';gate()
# Import only qmp helper definitions, not registrar side effects.
ns={};source=(R/'oct10-produced-owned.py').read_text().split("if sys.argv[1]=='guard':")[0];exec(source,ns);qmp=ns['qmp'];qmp(g['qmp'],'stop');status=qmp(g['qmp'],'query-status');assert status['running'] is False and status['status']=='paused'
try:
 assert Path(stage['manifest']).read_text()==manifest_text,'Manifest changed after runtime verification'
 config=dict(admission_sites_verified=True,admission_site_proof=str(R/(label+'.produced.admission-site-proof.json')),manifest_sha256=stage['manifest_sha256'],queue_site_verified=True,owned_vm_paused=True,same_run_identity_verified=True,live_code_match=True,stable_format=True,owned_pid=meta['pid'],guest_pid=guest,toc=c['toc'],driver=driver,dest_lo=lo,dest_hi=hi,stack_lo=stacklo,stack_hi=stackhi,base0=row['buffer_bases'][0],base1=row['buffer_bases'][1],buffer_bytes=8192,contract=str(R/(label+'.produced.driver-contract.json')),live_sites=str(R/(label+'.produced.live-sites.json')),vmmap=str(R/(label+'.produced.vmmap.txt')),thread_snapshot=str(ep))
 cp=R/(label+'.produced.publication-config.json');cp.write_text(json.dumps(config,indent=2)+'\n');subprocess.run(['python3',str(R/'oct10-queued-control.py'),'publish',stage['control'],'--config',str(cp)],check=True)
finally:qmp(g['qmp'],'cont')
print(json.dumps({'published':True,'guest_pid':guest,'age_seconds':age(),'capture_delay':stage['delay'],'capture_window':60,'note':'Actual native reference windows must fall wholly inside captured epoch; no quality claim from setup'}))
