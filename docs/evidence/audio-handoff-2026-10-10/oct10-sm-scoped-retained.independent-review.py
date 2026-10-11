import json,importlib.util
from pathlib import Path
R=Path('/tmp/pe9800');s=importlib.util.spec_from_file_location('dv',R/'oct10-coreaudio-scoped-data-verify.py');D=importlib.util.module_from_spec(s);s.loader.exec_module(D);V=D.V;m=json.loads((R/'oct10-sm-scoped-retained.receipt.json').read_text());q=D.S.proof(m);spans={};epochs=[]
for row in m['scoped_data_queries']:
 a,n=row['address'],row['bytes'];b=D.query_info(row['before_query'],m['pid'],a,n);t=D.query_info(row['after_query'],m['pid'],a,n);assert b==t
 for qr in [row['before_query'],row['after_query']]:assert all(qr['regions'][0]['before'][k]==qr['regions'][0]['after'][k] for k in D.FIELDS)
 for epoch in ['before','after']:
  rs=V.regions(m['vmmap_'+epoch]);hits=[z for z in rs if z['lo']<=a and a+n<=z['hi']];assert len(hits)==1;z=hits[0]
  try:V.region(rs,a,n,'ram');kind='existing ordinaryRAM'
  except V.Reject:
   assert z['kind']=='PEF binary' and z['perm']=='rw-' and 'SM=PRV' in z['tail'] and 'IOKit' not in z['tail'];kind='exactscopedPEF DATA'
  assert z['lo']<=b['region_low'] and b['region_low']+b['region_size']<=z['hi'];epochs.append({'role':row['role'],'epoch':epoch,'classification':z,'gate':kind})
 spans[(row['role'],a,n)]=b
out=V.analyze(m,stackproof=q,data_spans=spans);out.update(independent_per_epoch_mapping_checks=epochs,kernel_query_metadata_stable=True,anonymous_backing_proven=False,diagnostic_only=True)
(R/'oct10-sm-scoped-retained.independent-review.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps({k:v for k,v in out.items() if k!='independent_per_epoch_mapping_checks'},indent=2))
