"""Strict offline capture validation only: no waveform fit or invented presentation clock."""
import argparse,struct,json
from pathlib import Path
EVENT=struct.Struct('<QQQQIIIIIIII');HEADER=struct.Struct('<QQQQIIIIQQ');SIZE=1088

def validate(prefix, require_control=True, control_version=1):
 p=Path(prefix);cm=json.loads(Path(str(p)+'.chunks.json').read_text());em=json.loads(Path(str(p)+'.json').read_text());blob=Path(str(p)+'.chunks').read_bytes();evblob=Path(str(p)+'.events').read_bytes();fail=[]
 def gate(ok,msg):
  if not ok:fail.append(msg)
 gate(cm.get('record_bytes')==SIZE,'chunk ABI');gate(em.get('record_bytes')==EVENT.size,'event ABI');gate(len(blob)%SIZE==0,'chunk file size');gate(len(evblob)%EVENT.size==0,'event file size')

 configpath=Path(str(p)+'.config.json');receiptpath=Path(str(p)+'.produced-flush.json')
 config=json.loads(configpath.read_text()) if configpath.exists() else {};receipt=json.loads(receiptpath.read_text()) if receiptpath.exists() else {}
 gate(receipt.get('all_outputs_ok') is True,'final stopped flush receipt')
 gate(config.get('latched') is True,'configuration latch');gate(config.get('version')==control_version,'configuration version')
 gate(config.get('config_skips')==0 and config.get('config_errors')==0,'configuration coverage')
 if require_control:gate(config.get('control_mode') is True,'actual game requires published control')
 gate(config.get('driver')==cm.get('driver'),'config driver agreement');gate(config.get('toc')==em.get('required_toc'),'config TOC agreement')
 for field in ['dest_lo','dest_hi','stack_lo','stack_hi']:gate(config.get(field)==cm.get(field) and config.get(field) is not None,'config '+field+' agreement')
 for k in ['drops','read_errors','pair_failures','unfinished']:gate(cm.get(k)==0,'chunk '+k)
 gate(cm.get('flush_ok') is True,'chunk flush');gate(em.get('flush_ok') is True,'event flush');gate(em.get('word_mismatches')==0,'instruction mismatch')
 for cpu in em.get('cpu',[]):
  gate(cpu.get('drops')==0,'CPU drops');gate(cpu.get('register_errors')==0,'register errors')
  if cpu.get('records'):gate(cpu.get('supported') is True,'unsupported active CPU')
 if len(blob)%SIZE or len(evblob)%EVENT.size:return {'valid':False,'failures':fail}
 events=list(EVENT.iter_unpack(evblob));entries=[e for e in events if e[10]==1 and e[11]==0];returns=[e for e in events if e[10]==1 and e[11]==1]
 chunks=[HEADER.unpack_from(blob,i) for i in range(0,len(blob),SIZE)];serials=[c[8] for c in chunks]
 gate(len(chunks)>0,'empty capture');gate(len(chunks)==cm.get('records'),'metadata count');gate(len(chunks)==len(entries)==len(returns),'complete fill entry/return count');gate(len(set(serials))==len(serials),'duplicate serial');gate(sorted(serials)==list(range(len(chunks))),'missing serial')
 entrymap={(e[0],e[2],e[3]):e for e in entries};returnmap={(e[0],e[2],e[3]):e for e in returns};gate(len(entrymap)==len(entries),'duplicate entry identity');gate(len(returnmap)==len(returns),'duplicate return identity')
 for c in chunks:
  ns,ens,sp,lr,driver,dest,cpu,ecpu,serial,endns=c;entry=entrymap.get((ens,sp,lr));ret=returnmap.get((ns,sp,lr));gate(entry is not None and ret is not None,'unpaired chunk')
  gate(ens<=ns<=endns and ens>0,'snapshot timestamps');gate(driver==cm.get('driver'),'driver identity');gate(dest>=4096 and dest<=0xffffffff-1024,'destination arithmetic')
  if entry:gate(entry[4]==driver and entry[5]==dest and entry[9]==ecpu,'entry arguments')
  if ret:gate(ret[9]==cpu,'return CPU')
  if 'dest_lo' in cm:gate(cm['dest_lo']<=dest<=cm['dest_hi']-1024,'verified destination range')
  if 'stack_lo' in cm:gate(cm['stack_lo']<=sp<cm['stack_hi'],'verified stack range')
 ordered=sorted(chunks,key=lambda c:c[8]);overlap=sum(b[1]<a[0] for a,b in zip(ordered,ordered[1:]));gate(overlap==0,'overlapping fill invocations require explicit queue-order proof')
 return {'valid':not fail,'failures':sorted(set(fail)),'chunks':len(chunks),'captured_payload_bytes':len(chunks)*1024,'serial_range':[min(serials,default=0),max(serials,default=0)],'call_overlap_count':overlap,'coverage_ns':[min((c[1] for c in chunks),default=0),max((c[9] for c in chunks),default=0)],'limitations':['Output bytes only; no source handle/cursor recorded.','Destination virtual addresses are not raw-DMA physical addresses.','Serial order is call order, not proven queue/presentation order.','No byteorder/sample-format assumed; independently verify same-run output contract before waveform decoding.','No concatenated waveform, local alignment, timewarp or fidelity/loss score produced.']}
if __name__=='__main__':
 a=argparse.ArgumentParser();a.add_argument('prefix');a.add_argument('--output');a.add_argument('--static-fixture',action='store_true');a.add_argument('--control-version',type=int,choices=[1,2],default=1);v=a.parse_args();r=validate(v.prefix,not v.static_fixture,v.control_version);s=json.dumps(r,indent=2)+'\n';print(s)
 if v.output:Path(v.output).write_text(s)
 raise SystemExit(0 if r['valid'] else 2)
