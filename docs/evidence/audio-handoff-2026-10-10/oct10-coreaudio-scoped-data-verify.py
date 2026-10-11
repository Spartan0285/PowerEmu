#!/usr/bin/env python3
"""Scoped task DATA acquisition; no anonymous backing or code-execution claim."""
import argparse,importlib.util,json,struct
from pathlib import Path
R=Path('/tmp/pe9800');spec=importlib.util.spec_from_file_location('stack_verify',R/'oct10-coreaudio-stack-verify.py');S=importlib.util.module_from_spec(spec);spec.loader.exec_module(S);V=S.V
FIELDS=('region_low','region_size','protection','max_protection','shared','reserved','object_offset','inheritance','extended_protection','user_tag','external_pager','share_mode','shadow_depth')
def query_info(q,pid,a,n):
 for f,expected in (('schema',1),('pid',pid),('fixture',False),('payload_reads',0),('vm_mutations',0),('errors',0)):
  V.require(q[f]==expected,'query '+f+' expected='+str(expected)+' actual='+str(q[f]))
 V.require(len(q['regions'])==1,'query not exact one scalar span');r=q['regions'][0]
 V.require(V.num(r['address'])==a,'query requested address differs: expected='+hex(a)+' actual='+str(r['address']))
 V.require(V.num(r['bytes'])==n,'query requested size differs: expected='+str(n)+' actual='+str(r['bytes']))
 b,t=r['before'],r['after']
 for x in (b,t):
  for f in FIELDS:V.require(type(x[f]) is int and x[f]>=0,'region '+f+' expected=nonnegative integer actual='+str(x[f]))
  for f,expected in (('basic_status',0),('extended_status',0),('basic_count',8),('extended_count',8)):
   V.require(x[f]==expected,'query '+f+' expected='+str(expected)+' actual='+str(x[f]))
  V.require(x['region_low']<=a and a+n<=x['region_low']+x['region_size']<=0x100000000,'query coverage expected='+hex(a)+'..'+hex(a+n)+' actual='+hex(x['region_low'])+'..'+hex(x['region_low']+x['region_size']))
  V.require(x['protection']&3==3,'kernel basic protection lacks read/write: actual='+str(x['protection']))
  V.require(x['extended_protection']&3==3,'kernel extended protection lacks read/write: actual='+str(x['extended_protection']))
 return {f:b[f] for f in FIELDS}
def qualifications(m,q):
 spans={};pid=V.num(m['pid']);rs=V.regions(m['vmmap_before']);ra=V.regions(m['vmmap_after'])
 rec=V.data(m['blobs']['record_before']);dev=V.data(m['blobs']['device_before'])
 V.require(len(rec)==0xa4 and len(dev)==0x6c,'missing exact parents for DATA graph')
 record,hw,device=q['record'],q['hwstate'],q['device'];V.require(V.u32(rec)==device and V.u32(rec,8)==hw,'coherent pointers != current record fields')
 roles={'record':(record,0xa4),'hw':(hw,0x2c),'device':(device,0x6c),'list':(V.u32(dev,0x68),12),'bridge':(V.u32(rec,4),16)}
 rows=m['scoped_data_queries'];V.require(0<=len(rows)<=5,'scoped DATA query count')
 for row in rows:
  role=row['role'];V.require(role in roles,'untyped arbitrary DATA role');a,n=roles[role]
  V.require(V.num(row['address'])==a and V.num(row['bytes'])==n,'DATA pointer/size not from current typed parent')
  key=(role,a,n);V.require(key not in spans,'duplicate DATA role')
  b=query_info(row['before_query'],pid,a,n);t=query_info(row['after_query'],pid,a,n)
  for qr in (row['before_query'],row['after_query']):
   before,after=qr['regions'][0]['before'],qr['regions'][0]['after'];V.require(all(before[f]==after[f] for f in FIELDS),'structural verdict: region metadata changed inside query')
  V.require(b==t,'structural verdict: region metadata changed across payload capture')
  for rset in (rs,ra):
   matches=[z for z in rset if z['lo']<=a and a+n<=z['hi']];V.require(len(matches)==1,'DATA current mapping ambiguous');z=matches[0]
   try:V.region(rset,a,n,'ram')
   except V.Reject:
    V.require(z['kind']=='PEF binary' and z['perm']=='rw-' and 'SM=PRV' in z['tail'] and 'IOKit' not in z['tail'],'DATA endpoint neither existing ordinary RAM nor exact private writable PEF span')
   # vmmap's inferred kind/aggregation can change; identical kernel metadata above
   # must still fit each endpoint's approved mapping and exact typed payload.
   V.require(z['lo']<=b['region_low'] and b['region_low']+b['region_size']<=z['hi'],'actual query region outside current typed mapping')
  spans[key]=b
 return spans
def analyze(m):
 q=S.proof(m);spans=qualifications(m,q);out=V.analyze(m,stackproof=q,data_spans=spans)
 out.update(saved_stack_proof=q,scoped_DATA_queries=len(spans),anonymous_backing_proven=False,bridge_current_execute_permission_proven=False)
 out['limitations']+=['Private file-backed DATA is permitted only at exact freshly typed spans; external_pager is retained, not an anonymous-RAM criterion','No general PEF scan or global RAM allowlist change; shared/reserved/share_mode are observed metadata, not anonymous-backing or execution predicates','Inline vector mapping is an arithmetic membership view, not authorization to read its entire payload']
 return out
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('receipt');p.add_argument('--out');a=p.parse_args()
 try:out=analyze(json.loads(Path(a.receipt).read_text()))
 except (V.Reject,KeyError,ValueError,struct.error) as e:out=dict(accepted=False,error=str(e))
 s=json.dumps(out,indent=2);print(s)
 if a.out:Path(a.out).write_text(s+'\n')
 if not out.get('accepted'):raise SystemExit(1)
