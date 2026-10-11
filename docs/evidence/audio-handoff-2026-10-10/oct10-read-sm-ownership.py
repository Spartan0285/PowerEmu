"""Fresh, bounded, read-only owned-guest SoundManager ownership discovery. No VM launch."""
from pathlib import Path
import subprocess,json,struct,hashlib,time,sys,re,importlib.util
R=Path('/tmp/pe9800');guest=int(sys.argv[1]);label=sys.argv[2];assert guest>1 and re.fullmatch(r'oct10-[A-Za-z0-9_-]+',label)
meta=json.loads((R/'oct08-depthwait-native-current.json').read_text());assert meta['status']=='running';guard=json.loads(Path(meta['produced_guard']).read_text());assert guard['owned_pid']==meta['pid'] and meta['prefix'].startswith(label+'.');command=subprocess.check_output(['ps','-p',str(meta['pid']),'-o','command='],text=True).strip();assert command==guard['owned_command']
def gate():
 assert time.clock_gettime_ns(time.CLOCK_MONOTONIC)<guard['deadline_ns']-20000000000
 assert subprocess.check_output(['ps','-p',str(meta['pid']),'-o','command='],text=True).strip()==command
 assert subprocess.run(['kill','-0',str(guard['guard_pid'])],capture_output=True).returncode==0
def ssh(cmd):gate();return subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',cmd],timeout=18)
initial=ssh(f'ps -p {guest} -o command=').decode();assert 'Warcraft' in initial
# Existing trusted helper must have been uploaded during unscored discovery. Contract is recreated this run.
gate();subprocess.run(['python3',str(R/'oct10-read-miles-contract.py'),str(guest),label+'.sm-owner'],check=True,timeout=100,stdout=subprocess.DEVNULL);gate()
contract_path=R/(label+'.sm-owner.driver-contract.json');c=json.loads(contract_path.read_text());assert c['guest_pid']==guest and c['live_code_match'] and c['stable_format'];driver=c['active_driver'];row=next(r for r in c['nodes']if r['address']==driver)
vm=ssh(f'vmmap {guest}').decode();(R/(label+'.sm-owner.vmmap.txt')).write_text(vm)
spec=importlib.util.spec_from_file_location('stack',R/'oct10-select-callback-stack.py');sm=importlib.util.module_from_spec(spec);spec.loader.exec_module(sm);regions=sm.regions(vm)
spec=importlib.util.spec_from_file_location('owner_gate',R/'oct10-sm-ownership-gates.py');owner_gate=importlib.util.module_from_spec(spec);spec.loader.exec_module(owner_gate)
def bounds(addr,n,write=False):
 if write:return owner_gate.ordinary_ram(addr,n,regions)
 assert 0<addr<2**32 and 0<n<=4096 and addr+n<=2**32
 choices=[r for r in regions if r[1]<=addr and addr+n<=r[2] and (r[3].startswith('rw') and (r[0].startswith('MALLOC')or r[0].startswith('VM_ALLOCATE')) if write else r[3].startswith('r'))]
 assert choices,'Read outside verified current RAM/mapping';return choices
reads=[]
def read(addr,n,write=False):
 regions_used=bounds(addr,n,write);b=ssh(f'/tmp/oct10-miles-read-memory {guest} {addr:x} {n:x}');assert len(b)==n;reads.append(dict(address=addr,bytes=n,sha256=hashlib.sha256(b).hexdigest(),region_lines=[x[4] for x in regions_used]));return b
copies=json.loads((R/'oct10-coreaudio-discovery.copies.json').read_text());file=(R/'oct10-guest-CarbonSound.macho').read_bytes();assert hashlib.sha256(file).hexdigest()==copies['CarbonSound']['sha256']
assert any('CarbonSound.framework' in line and '93260000-9327e000' in line and 'r-x' in line for line in vm.splitlines()),'Fresh CarbonSound executable extent differs'
# Pinned __TEXT vmaddr93260000/fileoff0. All these complete code slices must match exact copied actual guest binary.
for a,n in [(0x93262628,0x70),(0x93263c70,0x94),(0x93263d04,0x28),(0x932629b4,0xa0),(0x93262e04,0x14)]:assert read(a,n)==file[a-0x93260000:a-0x93260000+n]
# Fresh Miles callback vector was checked by contract helper; repeat it before ownership snapshot.
assert struct.unpack('>II',read(c['toc']-0x8000+0x1324,8))==(0x5900e0,c['toc'])
a=read(driver,256,True);channel=struct.unpack_from('>I',a,0x9a)[0];assert channel==row['sound_channel'];b=read(channel,12,True);private=struct.unpack_from('>I',b,4)[0];d=read(private,80,True)
# Capture only readable executable callback bytes as evidence; no opaque bridge is silently accepted.
callback=struct.unpack_from('>I',b,8)[0];exec_regions=[x for x in regions if x[1]<=callback and callback+64<=x[2] and 'x' in x[3]]
# Ordinary-RAM bytes may be retained as DATA evidence without claiming executable provenance.
callback_ram=[] if exec_regions else owner_gate.ordinary_ram(callback,64,regions)
thunk=read(callback,64,not bool(exec_regions));thunk_after=read(callback,64,not bool(exec_regions));assert thunk==thunk_after,'Callback data changed during discovery'
(R/(label+'.sm-owner.callback.bin')).write_bytes(thunk);(R/(label+'.sm-owner.callback-after.bin')).write_bytes(thunk_after)
d2=read(private,80,True);b2=read(channel,12,True);a2=read(driver,256,True);assert ssh(f'ps -p {guest} -o command=').decode()==initial;gate()
spec=importlib.util.spec_from_file_location('gate',R/'oct10-sm-ownership-gates.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);proof=m.validate(a,b,d,a2,b2,d2,channel,0x93263c70,0x5900e0)
# Even directcallback requires fresh exact callback code bytes (already required by fresh contract's wholeMiles match).
proof.update(guest_pid=guest,owned_pid=meta['pid'],driver=driver,channel=channel,private=private,sound_param=private+0x14,contract=str(contract_path),current_vmmap=str(R/(label+'.sm-owner.vmmap.txt')),clock_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC),reads=reads,callback_executable_region=[x[4]for x in exec_regions],callback_data_region=[x[4]for x in callback_ram],callback_data_stable=True,callback_data_is_execution_proof=False,callback_bytes_sha256=hashlib.sha256(thunk).hexdigest(),copied_carbon_sha256=copies['CarbonSound']['sha256'],no_observer_started=True)
for name,data in [('driver',a),('channel',b),('private',d),('driver-after',a2),('channel-after',b2),('private-after',d2)]: (R/(label+'.sm-owner.'+name+'.bin')).write_bytes(data)
out=R/(label+'.sm-owner.json');out.write_text(json.dumps(proof,indent=2)+'\n');print(out)
if not proof['observer_eligible']:raise SystemExit(2)
