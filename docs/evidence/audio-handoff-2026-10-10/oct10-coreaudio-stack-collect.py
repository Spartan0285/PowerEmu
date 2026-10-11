#!/usr/bin/env python3
"""Explicit owned-VM read-only collector. No VM launch, no remote write, no audio client."""
import argparse, hashlib, importlib.util, json, os, re, signal, subprocess, sys, time
from pathlib import Path
R=Path('/tmp/pe9800'); spec=importlib.util.spec_from_file_location('verify',R/'oct10-coreaudio-record-verify.py'); V=importlib.util.module_from_spec(spec);spec.loader.exec_module(V)
ss=importlib.util.spec_from_file_location('stack_verify',R/'oct10-coreaudio-stack-verify.py');SV=importlib.util.module_from_spec(ss);ss.loader.exec_module(SV)
p=argparse.ArgumentParser();p.add_argument('pid',type=int);p.add_argument('guard');p.add_argument('label');a=p.parse_args()
if not re.fullmatch(r'oct10-[A-Za-z0-9_-]+',a.label): raise SystemExit('Label must be a simple oct10- basename')
g=json.loads(Path(a.guard).read_text()); started=time.clock_gettime_ns(time.CLOCK_MONOTONIC); limit=started+90_000_000_000
receipt=dict(schema=2,pid=a.pid,capture_id=a.label,pid_after=None,capture_id_after=None,blobs={},collection_started_ns=started,guard_path=str(Path(a.guard).resolve()),helper_receipts={})
def save(): (R/(a.label+'.receipt.json')).write_text(json.dumps(receipt,indent=2)+'\n')
def gate():
 V.require(time.clock_gettime_ns(time.CLOCK_MONOTONIC)<limit,'90-second collection budget expired')
 meta=json.loads((R/'oct08-depthwait-native-current.json').read_text())
 V.require(meta.get('status')=='running' and int(meta['pid'])==int(g['owned_pid']),'owned backend mismatch')
 cmd=subprocess.check_output(['ps','-p',str(g['owned_pid']),'-o','command='],text=True).strip()
 V.require(cmd==g['owned_command'].strip() and 'oct08-autonomous-support' in cmd and 'hostfwd=tcp:127.0.0.1:2319-:22' in cmd,'owned command/forwarding mismatch')
 V.require(time.clock_gettime_ns(time.CLOCK_MONOTONIC)+20_000_000_000<int(g['deadline_ns']),'insufficient strict guard deadline margin')
 V.require(int(g['guard_pid'])>0 and subprocess.run(['kill','-0',str(g['guard_pid'])],capture_output=True).returncode==0,'strict guard is not alive')
def stop_owned_before_ssh_kill():
 cmd=subprocess.check_output(['ps','-p',str(g['owned_pid']),'-o','command='],text=True).strip()
 V.require(cmd==g['owned_command'].strip(),'fatal: cannot stop changed backend identity')
 try:os.kill(int(g['owned_pid']),signal.SIGTERM)
 except ProcessLookupError:receipt['backend_stopped_for_cleanup']=True;return
 end=time.clock_gettime_ns(time.CLOCK_MONOTONIC)+2_000_000_000
 while time.clock_gettime_ns(time.CLOCK_MONOTONIC)<end:
  if subprocess.run(['kill','-0',str(g['owned_pid'])],capture_output=True).returncode: receipt['backend_stopped_for_cleanup']=True;return
  time.sleep(0.02)
 try:os.kill(int(g['owned_pid']),signal.SIGKILL)
 except ProcessLookupError:receipt['backend_stopped_for_cleanup']=True;return
 end=time.clock_gettime_ns(time.CLOCK_MONOTONIC)+2_000_000_000
 while time.clock_gettime_ns(time.CLOCK_MONOTONIC)<end:
  if subprocess.run(['kill','-0',str(g['owned_pid'])],capture_output=True).returncode: receipt['backend_stopped_for_cleanup']=True;return
  time.sleep(0.02)
 raise V.Reject('fatal: owned backend stop not confirmed; do not kill suspended-helper SSH')
def suspended_helper(command):
 gate();proc=subprocess.Popen(['python3',str(R/'guest-ssh.py'),'2319',command],stdout=subprocess.PIPE,stderr=subprocess.PIPE)
 try:
  out,err=proc.communicate(timeout=20)
 except subprocess.TimeoutExpired:
  # Never kill SSH first: guest task may remain suspended. Destroy owned backend first.
  stop_owned_before_ssh_kill();proc.kill();proc.communicate();raise V.Reject('coherent helper exceeded20sec: owned backend stopped before SSH killed')
 (R/(a.label+'.stack-helper.stdout')).write_bytes(out);(R/(a.label+'.stack-helper.stderr')).write_bytes(err)
 try:h=json.loads(out)
 except Exception:
  stop_owned_before_ssh_kill();raise V.Reject('invalid helper cleanup receipt; owned backend stopped')
 receipt['stack_helper']=h;save()
 try:
  V.require(type(h) is dict and h['schema']==2 and h['provenance']=='coherent-suspended-stack','cleanup schema/provenance absent or wrong')
  for k in ('suspend_successes','resume_successes','resume_errors'):V.require(type(h[k]) is int and h[k]>=0,'cleanup counter absent/noninteger/negative')
  V.require(type(h['records']) is list,'cleanup records absent/not list')
  for x in h['records']:
   V.require(type(x) is dict,'cleanup record not object')
   for k in ('suspend_ok','resume_ok'):V.require(type(x[k]) is int and x[k] in (0,1),'cleanup flag absent/invalid')
   V.require(type(x['resume_status']) is int and x['resume_status']>=0,'resume status absent/invalid')
   V.require(x['resume_ok']==int(x['suspend_ok']==1 and x['resume_status']==0),'inconsistent resume status/flag')
  V.require(sum(x['suspend_ok'] for x in h['records'])==h['suspend_successes'] and sum(x['resume_ok'] for x in h['records'])==h['resume_successes'],'cleanup counters not backed by records')
  V.require(h['resume_errors']==0 and h['suspend_successes']==h['resume_successes'] and all(not x['suspend_ok'] or x['resume_ok'] for x in h['records']),'incomplete helper resume cleanup')
 except Exception:
  stop_owned_before_ssh_kill();raise V.Reject('malformed/incomplete helper cleanup receipt; owned backend stopped')
 V.require(proc.returncode==0,'coherent helper failed with balanced resumes: '+err.decode(errors='replace')[:300]);return out
def ssh(command):
 gate(); left=max(1,min(15,(limit-time.clock_gettime_ns(time.CLOCK_MONOTONIC))/1e9))
 return subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',command],timeout=left)
def identity():
 b=ssh(f'/bin/ps -p {a.pid} -o pid,command');lines=b.decode().splitlines()
 V.require(len(lines)==2 and re.fullmatch(r'\s*PID\s+COMMAND\s*',lines[0]),'unexpected Tiger ps header/body count')
 s=lines[1].strip();V.require(re.match(r'^'+str(a.pid)+r'\s',s) and 'Warcraft III' in s,'guest process identity mismatch');return s
def vmmap():
 s=ssh(f'/usr/bin/vmmap {a.pid}').decode(); V.require(re.search(r'Virtual Memory Map of process '+str(a.pid)+r'\b',s),'fresh vmmap wrong PID');return s
try:
 gate(); V.require(int(g['deadline_ns'])-started>120_000_000_000,'need >=120 seconds remaining guard margin')
 receipt['identity_fields']='Tiger-supported pid,command header plus exact one bodyline (no lstart/process birth-time claim)';receipt['process_before']=identity();receipt['vmmap_before']=vmmap();rs=V.regions(receipt['vmmap_before'])
 for name in ('oct10-coreaudio-stack-snapshot','oct10-miles-read-memory'):
  local=R/name;V.require(local.exists(),'missing local helper '+name)
  expected=hashlib.md5(local.read_bytes()).hexdigest()
  remote=ssh('/sbin/md5 -q /tmp/'+name).decode().strip();V.require(remote==expected,'remote helper differs: '+name)
  receipt['helper_receipts'][name]=dict(md5=expected,remote_verified=True)
 # Module mapping is fresh; verify both prologues/callsite before asking helper to suspend.
 smmaps=[z for z in rs if z['kind']=='__TEXT' and 'SoundManagerComponents' in z['tail']];V.require(len(smmaps)==1,'current SM module ambiguous');smbase=smmaps[0]['lo']
 def read(name,address,n,kind):
  V.region(rs,address,n,kind)
  b=ssh(f'/tmp/oct10-miles-read-memory {a.pid} {address:x} {n:x}')
  V.require(len(b)==n,'partial task read '+name)
  path=R/(a.label+'.'+name+'.bin');path.write_bytes(b)
  receipt['blobs'][name]=dict(path=str(path),address=address,bytes=n,sha256=hashlib.sha256(b).hexdigest());save();return b
 spr=read('sm_prologues_before',smbase+0x5794,0x88,'code');V.require(spr==V.pinned_bytes('SoundManagerComponents',0x5794,0x88),'actual SM prologues mismatch')
 cs=read('core_callsite_before',0x9146ac04,12,'code');V.require(cs==V.pinned_bytes('CoreAudio',0x9146ac04,12),'actual CoreAudio callsite mismatch')
 stacks=[z for z in rs if z['kind']=='Stack' and 'r' in z['perm'] and 'w' in z['perm']];V.require(1<=len(stacks)<=32,'bounded current Stack extents missing')
 stacktext=''.join(f'{z["lo"]:x} {z["hi"]:x}\n' for z in stacks);(R/(a.label+'.stack-extents.txt')).write_text(stacktext)
 # Numeric-only printf feeds /dev/stdin: no remote configfile writes or historical Stackfile.
 cmd="printf '"+stacktext+"' | "+f'/tmp/oct10-coreaudio-stack-snapshot {a.pid} {smbase:x} {smbase+0x3a000:x} /dev/stdin {smbase+0x57b4:x} 9146ac0c'
 snapjson=json.loads(suspended_helper(cmd));receipt['stack_helper']=snapjson;save()
 if int(snapjson.get('resume_errors',0)) or int(snapjson.get('suspend_successes',0))!=int(snapjson.get('resume_successes',0)):
  stop_owned_before_ssh_kill();raise V.Reject('fatal helper suspension cleanup incomplete; owned backend stopped')
 SV.verify_helper(snapjson,a.pid)
 proofs=[]
 for x in snapjson['records']:
  if not x['candidates']:continue
  try:q=SV.verify_snapshot(x,a.pid,rs,smbase)
  except V.Reject as e:raise V.Reject('captured candidate invalid: '+str(e))
  proofs.append((x,q))
 V.require(bool(proofs),'no coherent validated saved-stack pair')
 V.require(len({(q['record'],q['device'],q['hwstate']) for x,q in proofs})==1,'ambiguous current saved object identities')
 x,q=proofs[0];receipt['snapshot']=dict(x,pid=a.pid);receipt['stack_helper']['records'][receipt['stack_helper']['records'].index(x)]=receipt['snapshot'];receipt['snapshot_errors']=snapjson['errors'];receipt['snapshot_drops']=snapjson['drops']
 record=q['record'];V.require(record%4==0,'unaligned saved-stack record')
 cb=read('core_call_before',0x9146b778,0x100,'code');V.require(cb==V.pinned_bytes('CoreAudio',0x9146b778,0x100),'actual whole CoreAudio Call mismatch')
 r=read('record_before',record,0xa4,'ram');device,bridge,hw=V.struct.unpack_from('>III',r);V.require(device==q['device'] and hw==q['hwstate'],'coherent saved objects != current record')
 V.require(all(v and v%4==0 for v in (device,bridge,hw)),'invalid object pointers')
 d=read('device_before',device,0x6c,'ram');lst=V.u32(d,0x68)
 l=read('list_before',lst,12,'ram');begin,end=V.u32(l,4),V.u32(l,8)
 V.require(begin<=record and record+0xa4<=end and end>begin and (end-begin)%0xa4==0 and (record-begin)%0xa4==0 and (end-begin)//0xa4<=256,'actual list member gate failed');V.region(rs,begin,end-begin,'ram')
 h=read('hw_before',hw,0x2c,'ram');V.require(V.u32(h,0x28)==bridge and V.u32(h,0xc)==V.u32(d,4),'live HWstate function/device agreement failed')
 bb=read('bridge_before',bridge,16,'ram');w=V.struct.unpack('>IIII',bb)
 V.require(w[0]&0xffff0000==0x3d600000 and w[1]&0xffff0000==0x616b0000 and w[2:]==(0x7d6903a6,0x4e800420),'actual bridge grammar failed')
 target=((w[0]&65535)<<16)|(w[1]&65535)
 maps=[z for z in rs if z['kind']=='__TEXT' and 'SoundManagerComponents' in z['tail']];V.require(len(maps)==1 and target==maps[0]['lo']+0x5794,'actual bridge module/target failed')
 sm=read('sm_callback_before',target,0x54,'code');V.require(sm==V.pinned_bytes('SoundManagerComponents',0x5794,0x54),'actual whole SMcallback mismatch')
 # Reverse-order second reads detect changes in the exact pointer identities, not volatile counters.
 for name,address,n,kind in [('sm_callback',target,0x54,'code'),('bridge',bridge,16,'ram'),('hw',hw,0x2c,'ram'),('list',lst,12,'ram'),('device',device,0x6c,'ram'),('record',record,0xa4,'ram'),('core_call',0x9146b778,0x100,'code'),('sm_prologues',smbase+0x5794,0x88,'code'),('core_callsite',0x9146ac04,12,'code')]: read(name+'_after',address,n,kind)
 receipt['vmmap_after']=vmmap();receipt['process_after']=identity();V.require(receipt['process_before']==receipt['process_after'],'guest process epoch changed')
 receipt['pid_after']=a.pid;receipt['capture_id_after']=a.label;receipt['collection_finished_ns']=time.clock_gettime_ns(time.CLOCK_MONOTONIC);save()
 result=SV.analyze(receipt);(R/(a.label+'.verification.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2))
except Exception as e:
 receipt['collection_error']=str(e);receipt['collection_finished_ns']=time.clock_gettime_ns(time.CLOCK_MONOTONIC);save()
 result=dict(accepted=False,error=str(e),partial_receipt=str(R/(a.label+'.receipt.json')))
 (R/(a.label+'.verification.json')).write_text(json.dumps(result,indent=2)+'\n');print(json.dumps(result,indent=2));sys.exit(1)
