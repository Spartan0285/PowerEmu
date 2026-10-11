"""Independent existing-client capture ABI/timestamp gates; no guest operations."""
import argparse,hashlib,json,math,struct
from pathlib import Path
C=struct.Struct('<26IQ64I');H=struct.Struct('<6Q8I');SIZE=320
NAMES=['ready','version','entry','exit','entry_word','exit_word','device_id','hw','record','device','bridge','abl','abl_lo','abl_hi','stack_count','numer','denom','delay_sec','window_sec','core_return','reserved','context_address','context0','context1','context2','context3']
def validate(prefix,publication=None,fixture=False):
 p=Path(prefix);m=json.loads(Path(str(p)+'.json').read_text());raw=Path(str(p)+'.records').read_bytes();cb=Path(str(p)+'.config').read_bytes();f=[];rows=[]
 def need(ok,name):
  if not ok:f.append(name)
 need(len(cb)==C.size,'control ABI368')
 if len(cb)!=C.size:return {'valid':False,'failures':f}
 packed=C.unpack(cb);c=dict(zip(NAMES,packed[:26]));c['nonce']=packed[26];stacks=list(zip(packed[27::2],packed[28::2]));count=c['stack_count']
 need(c['ready']==0x534d5031 and c['version']==1 and c['reserved']==0 and c['nonce']>0,'control identity')
 need(1<=count<=32,'stack count')
 for i,(lo,hi) in enumerate(stacks):
  need((lo>=4096 and lo%4096==0 and hi%4096==0 and hi>lo and hi-lo<=64*1024*1024) if i<count else lo==hi==0,'stack extent')
 need(all(not (a<d and b>cc) for i,(a,b) in enumerate(stacks[:count]) for cc,d in stacks[:i]),'overlapping stack extents')
 need(c['numer']>0 and c['denom']>0 and c['delay_sec']<=10 and 1<=c['window_sec']<=60,'timebase/window')
 need(c['entry']!=c['exit'] and all(c[k]>=4096 and c[k]%4==0 for k in ['entry','exit','core_return','hw','record','device','bridge','context_address']),'address alignment')
 need(c['context_address']+16<=0xffffffff and c['abl_lo']<=c['abl'] and c['abl']+4<=c['abl_hi'],'context/ABL span')
 need(m.get('schema')==1 and m.get('record_bytes')==SIZE and m.get('latched') is True,'record metadata ABI/latch')
 need(len(raw)%SIZE==0 and len(raw)//SIZE==m.get('records') and 0<m.get('records',0)<=m.get('capacity',0),'complete nonempty records')
 for k in ['config_errors','guard_errors','word_errors','read_errors','bounds_errors','torn_reads','context_skips','object_errors','drops','pair_errors','unmatched_exits','unfinished']:need(m.get(k)==0,k)
 need(all(x.get('register_errors')==0 for x in m.get('cpu',[])),'register errors')
 need(json.loads(Path(str(p)+'.flush.json').read_text()).get('all_outputs_ok') is True,'stopped final flush')
 start,end=m.get('arm_start_ns',0),m.get('arm_end_ns',0);need(start==m.get('publication_observed_ns',0)+c['delay_sec']*10**9 and end==start+c['window_sec']*10**9,'publication relative epoch')
 if not fixture:
  need(publication is not None,'fresh publication receipt required')
  if publication:
   pr=json.loads(Path(publication).read_text());need(pr.get('control_sha256')==hashlib.sha256(cb).hexdigest() and pr.get('nonce')==c['nonce'],'exact published control identity')
   for k in ['fresh_ownership_verified','fresh_context_verified','fresh_sites_verified','guest_timestamp_abi_verified','published_while_owned_vm_paused']:need(pr.get(k) is True,k)
   need(pr.get('owned_pid',0)>1 and pr.get('guest_pid',0)>1,'owned/guest PID')
 def in_stack(a,n):return any(lo<=a and a+n<=hi for lo,hi in stacks[:count])
 def timestamp(b,role):
  sample,host,rate=struct.unpack_from('>dQd',b);flags,reserved=struct.unpack_from('>II',b,56)
  # NOW requires host time for lead; NOW sampleTime may legitimately be
  # invalid. OUT requires both domains for output cadence and lead.
  required=2 if role=='NOW' else 3
  need(flags&~31==0,role+' unsupported timestamp flags');need(flags&required==required,role+' required timestamp validity')
  need(not(flags&1) or math.isfinite(sample),role+' finite valid sampleTime')
  need(not(flags&4) or (math.isfinite(rate) and rate>0),role+' finite positive valid rateScalar')
  return {'sample_time':sample if flags&1 and math.isfinite(sample) else None,'guest_host_time':host if flags&2 else None,'rate_scalar':rate if flags&4 and math.isfinite(rate) else None,'flags':flags,'reserved':reserved}
 cpus={x['id']:x for x in m.get('cpu',[])}
 for i in range(len(raw)//SIZE):
  at=i*SIZE;h=H.unpack_from(raw,at);ns,readend,ex,sp,lr,serial,dev,hw,nowptr,outptr,ablptr,ec,xc,buffers=h
  need(serial==i,'record serial/order');need(start<=ns<=readend<=ex<end,'entry/read/exit coverage')
  need(sp<=0xffffffff and in_stack(sp,16) and lr==c['core_return'],'paired original SP/LR')
  need(dev==c['device_id'] and hw==c['hw'] and ablptr==c['abl'],'published client/ABL identity')
  need(ec in cpus and xc in cpus and cpus.get(ec,{}).get('supported') and cpus.get(xc,{}).get('supported'),'entry/exit CPU support')
  need(nowptr%4==outptr%4==0 and in_stack(nowptr,64) and in_stack(outptr,64),'timestamp pointer full span')
  n=timestamp(raw[at+80:at+144],'NOW');o=timestamp(raw[at+144:at+208],'OUT')
  abl=raw[at+208:at+308];actual=struct.unpack_from('>I',abl)[0];need(actual==buffers and 1<=buffers<=8,'bounded nonempty ABL scalars');extent=4+12*buffers
  need(c['abl_lo']<=ablptr and ablptr+extent<=c['abl_hi'],'exact ABL scalar span');need(abl[extent:]==bytes(max(0,100-extent)) and raw[at+308:at+320]==bytes(12),'record zero padding')
  bs=[dict(zip(['channels','data_bytes','data_pointer'],struct.unpack_from('>III',abl,4+12*j))) for j in range(min(buffers,8))]
  rows.append({'serial':serial,'entry_ns':ns,'read_end_ns':readend,'exit_ns':ex,'entry_cpu':ec,'exit_cpu':xc,'NOW':n,'OUT':o,'ABL_scalars':bs,'guest_output_minus_now_ticks':o['guest_host_time']-n['guest_host_time'] if o['guest_host_time'] is not None and n['guest_host_time'] is not None else None})
 return {'valid':not f,'failures':sorted(set(f)),'records':len(rows),'fixture_mode':fixture,'control':c,'rows':rows,'limitations':['Guest hostTime is not host CLOCK_MONOTONIC; no cross-domain subtraction.','ABL bytes are not frame counts without current HAL format.','Entry/exit status does not prove kernel DMA fill or sound quality.','Fresh publication booleans must be backed by retained same-run identity/code/ABI receipts.']}
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('prefix');a.add_argument('--publication');a.add_argument('--fixture',action='store_true');a.add_argument('--output');v=a.parse_args();r=validate(v.prefix,v.publication,v.fixture);s=json.dumps(r,indent=2,allow_nan=False)+'\n'
 if v.output:Path(v.output).write_text(s)
 print(s);raise SystemExit(0 if r['valid'] else 2)
