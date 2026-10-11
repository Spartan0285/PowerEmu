import copy,importlib.util,json,struct
from pathlib import Path
R=Path('/tmp/pe9800');spec=importlib.util.spec_from_file_location('stack_verify',R/'oct10-coreaudio-stack-verify.py');S=importlib.util.module_from_spec(spec);spec.loader.exec_module(S);V=S.V
m=V.fixture(True);m['schema']=2
I=0xf0386900;W=I+0x90;F=W+0x50;sm=0x162ab000
frames=[]
for frame,backchain,lr,ownlr in [(I,W,sm+0x57b4,0),(W,F,0x9146ac0c,sm+0x57b4),(F,F+0xa0,0x9146a8ac,0x9146ac0c)]:
 frames.append(dict(frame=frame,backchain=backchain,lr_address=backchain+8,lr=lr,raw_frame16hex=struct.pack('>IIII',backchain,0,ownlr,0).hex()))
c=dict(inner_frame=I,wrapper_frame=W,caller_frame=F,record=0x10000000,hw=0x10002000,device=0x10001000,inner_return=sm+0x57b4,wrapper_return=0x9146ac0c,rawslotshex=struct.pack('>IIIII',0x10000000,0x10002000,0x10001000,sm+0x57b4,0x9146ac0c).hex())
s=dict(pid=999,thread=17,pc=sm+0x5818,sp=I,word=V.u32(V.pinned_bytes('SoundManagerComponents',0x5818,4)),word_ok=1,capture_begin_ticks=100,capture_end_ticks=110,capture_error=0,suspend_ok=1,resume_ok=1,resume_status=0,stack_lo=0xf0307000,stack_hi=0xf0387000,frames=frames,candidates=[c])
reads=[dict(address=s['pc'],bytes=4,bytes_hex=struct.pack('>I',s['word']).hex())]
for f in frames:
 reads.append(dict(address=f['frame'],bytes=16,bytes_hex=f.pop('raw_frame16hex')))
 reads.append(dict(address=f['lr_address'],bytes=4,bytes_hex=struct.pack('>I',f['lr']).hex()))
T=frames[-1]['backchain'];reads.append(dict(address=T,bytes=16,bytes_hex=struct.pack('>IIII',0,0,frames[-1]['lr'],0).hex()))
for address,b in [(I+0x84,struct.pack('>II',c['record'],c['hw'])),(W+0x48,struct.pack('>I',c['device']))]:reads.append(dict(address=address,bytes=len(b),bytes_hex=b.hex()))
s['reads']=reads
m['snapshot']=s;m['stack_helper']=dict(schema=2,provenance='coherent-suspended-stack',pid=999,range_low=sm,range_high=sm+0x3a000,sm_return=sm+0x57b4,core_return=0x9146ac0c,fixture=False,stop_requested=False,errors=0,drops=0,suspend_successes=1,resume_successes=1,resume_errors=0,total_stack_bytes=100,records=[s])
for stem,name,addr,n in [('sm_prologues','SoundManagerComponents',0x5794,0x88),('core_callsite','CoreAudio',0x9146ac04,12)]:
 m['blobs'][stem+'_before']=m['blobs'][stem+'_after']=V.pinned_bytes(name,addr,n).hex()
# Explicitly RW data bridge: no execute-permission claim. Call-chain provenance required.
m['vmmap_before']=m['vmmap_before'].replace('rwx/rwx SM=PRV','rw-/rwx SM=PRV');m['vmmap_after']=m['vmmap_before']
assert S.analyze(m)['accepted'] and not S.analyze(m)['bridge_current_execute_permission_proven'];tests={'valid_stack_RW_data_bridge_no_executeclaim':True}
def snapshot(x): return x['snapshot'] # deepcopy retains shared snapshot object identity
cases={
 'wrong_backchain':lambda x:snapshot(x)['frames'][0].update(backchain=W+16),
 'backward_chain':lambda x:snapshot(x)['frames'][0].update(backchain=I-16),
 'overflow':lambda x:snapshot(x)['frames'][0].update(backchain=0x100000000),
 'wrong_return':lambda x:snapshot(x)['frames'][0].update(lr=sm+0x57b8),
 'partial_slots':lambda x:snapshot(x)['candidates'][0].update(rawslotshex='00'*12),
 'partial_cleanup':lambda x:x['stack_helper'].update(resume_successes=0),
 'resume_error':lambda x:snapshot(x).update(resume_status=5),
 'epoch_reverse':lambda x:snapshot(x).update(capture_begin_ticks=111),
 'wrong_stack_extent':lambda x:snapshot(x).update(stack_lo=0xf0306000),
 'saved_record_mismatch':lambda x:snapshot(x)['candidates'][0].update(record=0x100000a4),
 'ambiguous_pairs':lambda x:snapshot(x)['candidates'].append(copy.deepcopy(c)),
 'changed_prologue':lambda x:x['blobs'].update(sm_prologues_after='00'*0x88),
 'changed_callsite':lambda x:x['blobs'].update(core_callsite_after='00'*12),
 'wrong_sample_opcode':lambda x:snapshot(x).update(word=0),
 'changed_capture_epoch':lambda x:x.update(capture_id_after='other'),
 'changed_object':lambda x:x['blobs'].update(record_after='00'*0xa4),
}
for name,mutate in cases.items():
 x=copy.deepcopy(m);mutate(x)
 try:S.analyze(x)
 except (V.Reject,KeyError,ValueError,struct.error):tests[name]=True
 else:raise AssertionError('Failed rejection '+name)
out=dict(synthetic_only=True,tests=tests);(R/'oct10-coreaudio-stack-fixtures.json').write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
(R/'oct10-coreaudio-stack-synthetic-receipt.json').write_text(json.dumps(m,indent=2)+'\n')
