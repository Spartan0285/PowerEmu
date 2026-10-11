import ast,json,subprocess,types,sys
from pathlib import Path
R=Path('/tmp/pe9800');source=Path(sys.argv[1]) if len(sys.argv)>1 else R/'oct10-coreaudio-stack-collect.py';src=source.read_text();tree=ast.parse(src)
fn=next(n for n in tree.body if isinstance(n,ast.FunctionDef) and n.name=='suspended_helper');mod=ast.Module(body=[fn],type_ignores=[])
class Reject(ValueError):pass
class Fake:
 def __init__(self,out,code=0,timeout=False):self.out=out;self.returncode=code;self.timeout=timeout;self.calls=0
 def communicate(self,timeout=None):
  self.calls+=1
  if self.timeout and self.calls==1:raise subprocess.TimeoutExpired('fake',20)
  return self.out,b''
 def kill(self):events.append('ssh_kill')
def req(b,s):
 if not b:raise Reject(s)
def run(out,code=0,timeout=False):
 global events;events=[];fake=Fake(out,code,timeout)
 env=dict(R=R,a=types.SimpleNamespace(label='oct10-stack-collector-synthetic'),receipt={},gate=lambda:None,save=lambda:None,stop_owned_before_ssh_kill=lambda:events.append('backend_stopped'),subprocess=types.SimpleNamespace(Popen=lambda *x,**k:fake,PIPE=subprocess.PIPE,TimeoutExpired=subprocess.TimeoutExpired),V=types.SimpleNamespace(require=req,Reject=Reject),json=json)
 exec(compile(mod,'fixture','exec'),env)
 try:r=env['suspended_helper']('fake');return True,list(events)
 except Reject:return False,list(events)
valid=dict(schema=2,provenance='coherent-suspended-stack',resume_errors=0,suspend_successes=1,resume_successes=1,records=[dict(suspend_ok=1,resume_ok=1,resume_status=0)])
assert run(json.dumps(valid).encode())==(True,[])
assert run(json.dumps(valid).encode(),code=4)==(False,[])
bad=dict(valid,resume_successes=0);assert run(json.dumps(bad).encode())==(False,['backend_stopped'])
for field in ('schema','provenance','suspend_successes','resume_successes','resume_errors','records'):
 missing=dict(valid);del missing[field];assert run(json.dumps(missing).encode())==(False,['backend_stopped'])
for value in (-1,'1',True,None):
 bad=dict(valid,suspend_successes=value);assert run(json.dumps(bad).encode())==(False,['backend_stopped'])
for field in ('suspend_ok','resume_ok','resume_status'):
 bad=dict(valid,records=[dict(valid['records'][0])]);del bad['records'][0][field];assert run(json.dumps(bad).encode())==(False,['backend_stopped'])
assert run(b'not json')==(False,['backend_stopped'])
assert run(b'',timeout=True)==(False,['backend_stopped','ssh_kill'])
assert 'time.monotonic_ns' not in src
out=dict(synthetic_only=True,collector_source=str(source),tests=dict(clean_balanced_return=True,nonzero_exit_balanced_no_suspension_claim=True,incomplete_cleanup_stops_backend=True,malformed_cleanup_stops_backend=True,timeout_backend_stop_before_ssh_kill=True,explicit_CLOCK_MONOTONIC_only=True,missing_cleanup_fields_stop_backend=True,invalid_counter_types_stop_backend=True,missing_record_flags_stop_backend=True));(R/('oct10-coreaudio-scoped-data-collector-fixtures.json' if 'scoped-data' in source.name else 'oct10-coreaudio-stack-collector-fixtures.json')).write_text(json.dumps(out,indent=2)+'\n');print(json.dumps(out,indent=2))
