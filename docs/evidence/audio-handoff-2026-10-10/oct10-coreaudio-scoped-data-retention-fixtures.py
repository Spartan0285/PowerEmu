import ast,copy,importlib.util,json,types
from pathlib import Path
R=Path('/tmp/pe9800');source=R/'oct10-coreaudio-scoped-data-collect.py';tree=ast.parse(source.read_text());fn=next(n for n in ast.walk(tree) if isinstance(n,ast.FunctionDef) and n.name=='read');code=compile(ast.Module(body=[fn],type_ignores=[]),'read-fixture','exec')
spec=importlib.util.spec_from_file_location('dv',R/'oct10-coreaudio-scoped-data-verify.py');D=importlib.util.module_from_spec(spec);spec.loader.exec_module(D);V=D.V
base=json.loads((R/'oct10-coreaudio-scoped-data-synthetic-receipt.json').read_text());qr=base['scoped_data_queries'][0]['before_query'];rs=V.regions(base['vmmap_before'])
def run(query_status,q,payload_status=0,payload=None):
 receipt={'scoped_data_queries':[],'blobs':{}};label='oct10-scoped-retention-synthetic';calls=[]
 def response(cmd):
  calls.append(cmd)
  return (query_status,json.dumps(q).encode(),b'query diagnostic') if 'region-query' in cmd else (payload_status,bytes(0xa4) if payload is None else payload,b'payload diagnostic')
 env=dict(V=V,DV=D,R=R,a=types.SimpleNamespace(pid=999,label=label),rs=rs,q={'record':0x10000000,'hwstate':0x10002000,'device':0x10001000},receipt=receipt,scoped={},ssh_evidence=response,save=lambda:None,json=json,hashlib=__import__('hashlib'))
 exec(code,env)
 try:b=env['read']('record_before',0x10000000,0xa4,'ram');ok=True
 except V.Reject:ok=False
 assert len(receipt['scoped_data_raw_queries'])==1
 row=receipt['scoped_data_raw_queries'][0];assert Path(row['path']).read_bytes()==json.dumps(q).encode() and row['parsed']==q and row['exit_status']==query_status
 return ok,receipt,calls
bad=copy.deepcopy(qr);bad['errors']=1
ok,m,calls=run(4,bad);assert not ok and len(calls)==1
bad=copy.deepcopy(qr);bad['regions'][0]['before']['protection']=1
ok,m,calls=run(0,bad);assert not ok and m['scoped_data_raw_queries'][0]['parsed']['regions'][0]['before']['protection']==1 and len(calls)==1
for status in (0,4):
 ok,m,calls=run(0,qr,status,bytes(0xa3));assert not ok and m['blobs']['record_before']['actual_bytes']==0xa3 and m['blobs']['record_before']['exit_status']==status and len(Path(m['blobs']['record_before']['path']).read_bytes())==0xa3
observed=copy.deepcopy(qr)
for phase in ('before','after'):observed['regions'][0][phase].update(shared=1,reserved=1,share_mode=6)
ok,m,calls=run(0,observed);assert ok and len(calls)==2
out=dict(synthetic_only=True,tests=dict(nonzero_query_raw_stdout_stderr_retained_before_status_gate=True,rejected_query_exact_field_retained_before_predicate=True,nonzero_partial_payload_retained_before_status_gate=True,zero_exit_partial_payload_retained_before_length_gate=True,observed_shared_reserved_sharemode_not_DATA_permission_predicate=True));(R/'oct10-coreaudio-scoped-data-retention-fixtures.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
