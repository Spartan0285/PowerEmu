#!/usr/bin/env python3
"""Offline coherent saved-stack provenance. No guest operations."""
import argparse,copy,importlib.util,json,struct
from pathlib import Path
R=Path('/tmp/pe9800');spec=importlib.util.spec_from_file_location('record_verify',R/'oct10-coreaudio-record-verify.py');V=importlib.util.module_from_spec(spec);spec.loader.exec_module(V)
def module_base(rs):
 hits=[r for r in rs if r['kind']=='__TEXT' and 'SoundManagerComponents' in r['tail']]
 V.require(len(hits)==1,'current SM module ambiguous');return hits[0]['lo']
def verify_helper(h,pid):
 V.require(h['schema']==2 and V.num(h['pid'])==pid and h['provenance']=='coherent-suspended-stack','wrong helper schema/PID/provenance')
 V.require(not h.get('fixture',False) and not h.get('stop_requested',False),'fixture/stopped helper cannot prove live epoch')
 for k in ('suspend_successes','resume_successes','resume_errors'):V.require(type(h[k]) is int and h[k]>=0,'invalid cleanup counter type')
 V.require(type(h['records']) is list,'invalid cleanup records type')
 for x in h['records']:
  for k in ('suspend_ok','resume_ok'):V.require(type(x[k]) is int and x[k] in (0,1),'invalid cleanup flag')
  V.require(type(x['resume_status']) is int and x['resume_status']>=0,'invalid resume status')
  V.require(x['resume_ok']==int(x['suspend_ok']==1 and x['resume_status']==0),'inconsistent resume status/flag')
 V.require(sum(x['suspend_ok'] for x in h['records'])==h['suspend_successes'] and sum(x['resume_ok'] for x in h['records'])==h['resume_successes'],'cleanup counters not backed by actualrecords')
 for f in ('errors','drops','resume_errors'): V.require(V.num(h[f])==0,'helper '+f)
 V.require(V.num(h['suspend_successes'])>0 and V.num(h['suspend_successes'])==V.num(h['resume_successes']),'incomplete suspension cleanup')
 V.require(0<=V.num(h['total_stack_bytes'])<=1024*1024,'stack capture total byte budget')
def verify_snapshot(s,pid,rs,sm):
 pc,sp=V.num(s['pc']),V.num(s['sp']);V.require(pc%4==0 and sp%16==0,'PC/SP alignment')
 V.require(V.num(s['thread'])>0 and V.num(s['resume_status'])==0 and V.num(s['suspend_ok'])==1 and V.num(s['resume_ok'])==1 and V.num(s['capture_error'])==0,'snapshot identity/capture/resume failure')
 V.require(V.num(s['capture_begin_ticks'])<=V.num(s['capture_end_ticks']) and V.num(s['capture_begin_ticks'])>0,'invalid sample epoch')
 stack=V.region(rs,sp,16,'ram');V.require(stack['kind']=='Stack','snapshot SP not Stack')
 V.require(V.num(s['stack_lo'])==stack['lo'] and V.num(s['stack_hi'])==stack['hi'],'actual captured stack extent mismatch')
 cr=V.region(rs,pc,4,'code');V.require(V.num(s['word_ok'])==1,'no actual PC word')
 if 'SoundManagerComponents' in cr['tail']: expected=V.pinned_bytes('SoundManagerComponents',pc-sm,4)
 elif 'CoreAudio.framework' in cr['tail']: expected=V.pinned_bytes('CoreAudio',pc,4)
 else: raise V.Reject('sampled PC not pinned CoreAudio/SM code')
 V.require(V.num(s['word'])==V.u32(expected),'sampled actual PC word mismatch')
 reads=s['reads'];V.require(1<=len(reads)<=80,'bounded addressed read count')
 for rd in reads:
  a,n=V.num(rd['address']),V.num(rd['bytes']);raw=bytes.fromhex(rd['bytes_hex']);V.require(1<=n<=16 and len(raw)==n,'partial addressed read')
  if a==pc and n==4: V.require(raw==expected,'actual PC raw bytes mismatch')
  else: V.require(V.region(rs,a,n,'ram')==stack,'addressed read outside same Stack')
 def captured(a,n):
  xs=[bytes.fromhex(rd['bytes_hex'])[a-V.num(rd['address']):a-V.num(rd['address'])+n] for rd in reads if V.num(rd['address'])<=a and a+n<=V.num(rd['address'])+V.num(rd['bytes'])]
  V.require(xs and all(x==xs[0] for x in xs),'missing/conflicting addressed bytes');return xs[0]
 frames=s['frames'];V.require(1<=len(frames)<=32,'frame count bound')
 seen=set(); byaddr={}
 for i,f in enumerate(frames):
  a,b,lraddr=V.num(f['frame']),V.num(f['backchain']),V.num(f['lr_address'])
  V.require(a not in seen and a%16==0 and b%16==0 and b>a and b-a<=4096 and b-sp<=65536 and lraddr==b+8,'malformed/backward/overflow frame chain')
  if i==0: V.require(a==sp,'chain does not start at actualSP')
  else: V.require(a==V.num(frames[i-1]['backchain']),'disconnected frame chain')
  V.require(V.region(rs,a,16,'ram')==stack and V.region(rs,b,12,'ram')==stack,'chain outside same Stack')
  raw=captured(a,16);V.require(V.u32(raw)==b and V.u32(captured(lraddr,4))==V.num(f['lr']),'raw backchain/return disagreement')
  seen.add(a);byaddr[a]=f
 V.require(V.u32(captured(V.num(frames[-1]['backchain']),16))==0,'missing zero terminal frame; incomplete chain')
 cs=s['candidates'];V.require(len(cs)==1,'missing/ambiguous adjacent frame candidate')
 c=cs[0];I,W,S=map(V.num,(c['inner_frame'],c['wrapper_frame'],c['caller_frame']))
 V.require(I in byaddr and W in byaddr and W==I+0x90 and S==W+0x50,'wrong adjacent frame sizes')
 V.require(V.num(byaddr[I]['backchain'])==W and V.num(byaddr[W]['backchain'])==S,'pair not part of captured chain')
 V.require(V.num(byaddr[I]['lr'])==sm+0x57b4 and V.num(byaddr[W]['lr'])==0x9146ac0c,'actual return chain wrong')
 V.require(V.num(c['inner_return'])==sm+0x57b4 and V.num(c['wrapper_return'])==0x9146ac0c,'candidate return mismatch')
 # Exact bytes in order: I+84 record,I+88 HWstate,W+48 device,W+8 innerReturn,S+8 wrapperReturn.
 rawslots=bytes.fromhex(c['rawslotshex']);V.require(len(rawslots)==20,'partial saved-slot payload')
 record,hw,device,ir,wr=struct.unpack('>IIIII',rawslots)
 V.require((record,hw,device,ir,wr)==tuple(map(V.num,(c['record'],c['hw'],c['device'],c['inner_return'],c['wrapper_return']))),'raw saved slots disagree with scalar fields')
 for addr,n in ((I+0x84,8),(W+0x48,4),(W+8,4),(S+8,4)): V.require(V.region(rs,addr,n,'ram')==stack,'saved slot out of Stack')
 V.require(len({record,hw,device})==3 and all(x>0 and x%4==0 for x in (record,hw,device)),'null/aliased/unaligned saved object')
 V.require(captured(I+0x84,8)+captured(W+0x48,4)+captured(W+8,4)+captured(S+8,4)==rawslots,'saved slots not backed by addressed reads')
 V.require(V.u32(captured(S+8,4))==wr and V.u32(captured(W+8,4))==ir,'addressed raw return mismatch')
 return dict(pid=pid,thread=V.num(s['thread']),pc=pc,record=record,device=device,hwstate=hw,inner_frame=I,wrapper_frame=W,caller_frame=S,sm_base=sm,snapshot_resume_success=True)
def proof(m):
 V.require(m['schema']==2,'not explicit saved-stack schema')
 pid=V.num(m['pid']);rs=V.regions(m['vmmap_before']);ra=V.regions(m['vmmap_after']);sm=module_base(rs)
 V.require(module_base(ra)==sm,'SM base changed');h=m['stack_helper'];verify_helper(h,pid)
 V.require(V.num(h['range_low'])==sm and V.num(h['range_high'])==sm+0x3a000 and V.num(h['sm_return'])==sm+0x57b4 and V.num(h['core_return'])==0x9146ac0c,'helper live code/return configuration mismatch')
 s=m['snapshot'];V.require(s in h['records'],'selected snapshot not retained helper record')
 q=verify_snapshot(s,pid,rs,sm);verify_snapshot(s,pid,ra,sm)
 # Verify fresh exact prologues and dispatch callsite, not just historical symbols/returns.
 for stem,name,addr,size in [('sm_prologues','SoundManagerComponents',0x5794,0x88),('core_callsite','CoreAudio',0x9146ac04,12)]:
  b=V.data(m['blobs'][stem+'_before']);b2=V.data(m['blobs'][stem+'_after'])
  V.require(len(b)==size and b==b2==V.pinned_bytes(name,addr,size),'fresh whole '+stem+' mismatch')
 return q
def analyze(m):
 q=proof(m);out=V.analyze(m,stackproof=q);out['saved_stack_proof']=q;out['bridge_current_execute_permission_proven']=False
 out['limitations'].append('Stack call-chain provenance does not assert current bridge mapping execute permission; bridge bytes read as ordinary RAM data')
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('receipt');p.add_argument('--out');a=p.parse_args()
 try: out=analyze(json.loads(Path(a.receipt).read_text()))
 except (V.Reject,KeyError,ValueError,struct.error) as e: out=dict(accepted=False,error=str(e))
 s=json.dumps(out,indent=2);print(s)
 if a.out:Path(a.out).write_text(s+'\n')
 if not out.get('accepted'): raise SystemExit(1)
