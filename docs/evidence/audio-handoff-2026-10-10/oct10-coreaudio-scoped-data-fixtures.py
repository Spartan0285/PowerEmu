import copy,importlib.util,json
from pathlib import Path
R=Path('/tmp/pe9800');spec=importlib.util.spec_from_file_location('data_verify',R/'oct10-coreaudio-scoped-data-verify.py');D=importlib.util.module_from_spec(spec);spec.loader.exec_module(D);V=D.V
m=json.loads((R/'oct10-coreaudio-stack-synthetic-receipt.json').read_text())
m['vmmap_before']=m['vmmap_before'].replace('MALLOC 10000000-10010000','PEF binary 10000000-10010000').replace('rw-/rwx SM=PRV\nVM_ALLOCATE','rw-/rwx SM=PRV CFMPriv_fixture\nVM_ALLOCATE');m['vmmap_after']=m['vmmap_before']
# Exact typed graph spans only. Includes queried vector header; no inline-vector payload read.
meta=dict(basic_status=0,extended_status=0,basic_count=8,extended_count=8,region_low=0x10000000,region_size=0x10000,protection=3,max_protection=7,shared=0,reserved=0,object_offset=0,inheritance=1,extended_protection=3,user_tag=18,external_pager=1,share_mode=2,shadow_depth=1)
def query(a,n):return dict(schema=1,pid=999,fixture=False,payload_reads=0,vm_mutations=0,errors=0,regions=[dict(address=a,bytes=n,covered_stable=True,before=copy.deepcopy(meta),after=copy.deepcopy(meta))])
m['scoped_data_queries']=[]
for role,a,n in [('record',0x10000000,0xa4),('hw',0x10002000,0x2c),('device',0x10001000,0x6c),('list',0x10003000,12)]:m['scoped_data_queries'].append(dict(role=role,address=a,bytes=n,before_query=query(a,n),after_query=query(a,n)))
out=D.analyze(m);assert out['accepted'] and out['anonymous_backing_proven'] is False and out['bridge_current_execute_permission_proven'] is False
assert out['scoped_DATA_queries']==4;tests={'valid_file_backed_private_PEF_DATA_no_anonymous_or_x_claim':True}
observed=copy.deepcopy(m)
for row in observed['scoped_data_queries']:
 for side in ('before_query','after_query'):
  for phase in ('before','after'):row[side]['regions'][0][phase].update(shared=1,reserved=1,share_mode=6)
assert D.analyze(observed)['accepted'];tests['shared_reserved_sharemode_retained_not_DATA_permission_predicates']=True
relabelled=copy.deepcopy(m)
relabelled['vmmap_after']=relabelled['vmmap_after'].replace('PEF binary 10000000-10010000','MALLOC_TINY 10000000-10010000').replace('SM=PRV CFMPriv_fixture','SM=COW DefaultMallocZone_fixture')
assert D.analyze(relabelled)['accepted'];tests['stable_kernel_metadata_PEF_to_existing_ordinary_RAM_endpoint']=True
cases={
 'unsupported_after_kind':lambda x:x.update(vmmap_after=x['vmmap_after'].replace('PEF binary 10000000-10010000','mapped file 10000000-10010000')),
 'readonly_after_endpoint':lambda x:x.update(vmmap_after=x['vmmap_after'].replace('rw-/rwx SM=PRV CFMPriv_fixture','r--/rwx SM=PRV CFMPriv_fixture')),
 'untyped_PEF_span':lambda x:x['scoped_data_queries'].pop(0),
 'wrong_coherent_address':lambda x:x['scoped_data_queries'][0].update(address=0x100000a4),
 'arbitrary_role':lambda x:x['scoped_data_queries'][0].update(role='scan'),
 'oversized_span':lambda x:x['scoped_data_queries'][0].update(bytes=256),
 'readonly_PEF':lambda x:x.update(vmmap_before=x['vmmap_before'].replace('rw-/rwx SM=PRV CFMPriv_fixture','r--/rwx SM=PRV CFMPriv_fixture')),
 'shared_metadata_changed':lambda x:x['scoped_data_queries'][0]['before_query']['regions'][0]['before'].update(shared=1),
 'reserved_metadata_changed':lambda x:x['scoped_data_queries'][0]['before_query']['regions'][0]['before'].update(reserved=1),
 'metadata_changed':lambda x:x['scoped_data_queries'][0]['after_query']['regions'][0]['before'].update(user_tag=99),
 'missing_exact_query':lambda x:x['scoped_data_queries'][0]['before_query']['regions'][0].update(address=0x10000004),
 'kernel_lacks_write':lambda x:x['scoped_data_queries'][0]['before_query']['regions'][0]['before'].update(protection=1),
 'unsupported_ABI':lambda x:x['scoped_data_queries'][0]['before_query']['regions'][0]['before'].update(extended_count=7),
 'payload_read_query':lambda x:x['scoped_data_queries'][0]['before_query'].update(payload_reads=1),
 'graph_disagrees_with_stack':lambda x:x['blobs'].update(record_before='00'*0xa4),
 'stale_sampling_epoch':lambda x:x.update(capture_id_after='other'),
}
for name,mutate in cases.items():
 x=copy.deepcopy(m);mutate(x)
 try:D.analyze(x)
 except (V.Reject,KeyError,ValueError):tests[name]=True
 else:raise AssertionError('failed '+name)
(R/'oct10-coreaudio-scoped-data-fixtures.json').write_text(json.dumps(dict(synthetic_only=True,tests=tests),indent=2)+'\n');print(json.dumps(tests,indent=2))
(R/'oct10-coreaudio-scoped-data-synthetic-receipt.json').write_text(json.dumps(m,indent=2)+'\n')
