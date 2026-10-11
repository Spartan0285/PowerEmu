#!/usr/bin/env python3
"""Strict complete-callback pairing of manifest-only command return hooks."""
import argparse,json,struct
from pathlib import Path
E=struct.Struct('<QQQQIIIIIIII')
def ose(v):
 v&=65535;return v-65536 if v&32768 else v

def analyze(events):
 events=sorted(events);fail=[];scope=[];edge=0;open_calls={};returns=0;orphan_returns=[]
 for e in events:
  if e[10]!=0:continue
  key=(e[2],e[3])
  if e[11] not in (0,1) or e[1] != (0x5900e0 if e[11]==0 else 0x5902e4):
   fail.append('callback PC or phase');continue
  if e[11]==0:
   if key in open_calls:fail.append('duplicate callback identity')
   open_calls[key]=e
  else:
   returns+=1;start=open_calls.pop(key,None)
   if start is None:edge+=1;orphan_returns.append(e);continue
   scope.append((start,e))
 edge+=len(open_calls);rows=[]
 for start,end in scope:
  sp=start[2]-96;inside=[e for e in events if start[0]<e[0]<end[0] and e[2]==sp and e[10] in (2,3,4)]
  group={k:[e for e in inside if (e[10],e[11])==k] for k in [(2,0),(3,1),(4,0),(4,1)]}
  if any(len(v)!=1 for v in group.values()):fail.append('missing or duplicate command boundary');continue
  a,b,c,d=[group[k][0] for k in [(2,0),(3,1),(4,0),(4,1)]]
  if not(a[0]<b[0]<c[0]<d[0]):fail.append('command chronology');continue
  if [a[1],b[1],c[1],d[1]]!=[0x5901f4,0x5901fc,0x590224,0x59022c]:fail.append('command PCs');continue
  if b[3]!=0x5901f8 or d[3]!=0x590228:fail.append('return LR');continue
  if a[5]!=sp+64 or c[5]!=sp+56 or c[6]!=1 or c[4]!=a[4]:fail.append('command arguments');continue
  rows.append(dict(callback_start_ns=start[0],callback_end_ns=end[0],sp=sp,immediate_entry_ns=a[0],immediate_return_ns=b[0],immediate_status=ose(b[4]),immediate_upper_duration_us=(b[0]-a[0])/1000,command_entry_ns=c[0],command_return_ns=d[0],command_status=ose(d[4]),command_duration_us=(d[0]-c[0])/1000))
 # Every command event must be in one complete scope or an explicitly edge scope.
 command_pcs={(2,0):0x5901f4,(3,1):0x5901fc,(4,0):0x590224,(4,1):0x59022c}
 for e in events:
  if e[10] not in (2,3,4):continue
  if command_pcs.get((e[10],e[11])) != e[1]:fail.append('command PC or phase')
  covers=sum(a[0]<e[0]<b[0] and e[2]==a[2]-96 for a,b in scope)
  if covers>1:fail.append('ambiguous callback scope')
  # A capture edge excuses only this callback's stack, never all events on
  # either side of an arbitrary orphan return/open entry. CPU may migrate.
  if covers==0 and not(any(e[0]<b[0] and e[2]==b[2]-96 for b in orphan_returns) or any(e[0]>a[0] and e[2]==a[2]-96 for a in open_calls.values())):fail.append('unscoped command event')
 return dict(valid=not fail and bool(rows),failures=sorted(set(fail)),complete_scopes=len(scope),excluded_edge_scopes=edge,paired_commands=len(rows),rows=rows,limitations=['Command return success is not timely downstream copy or presentation.','Immediate duration includes existing queue snapshot observer overhead; subtract separately measured read interval only as bounded diagnostic, not precise native latency.','Only complete callback scopes are scored; window-edge scopes explicitly excluded.'])

def main():
 p=argparse.ArgumentParser();p.add_argument('prefix');p.add_argument('--output');a=p.parse_args();f=Path(a.prefix+'.events');b=f.read_bytes();m=json.loads(Path(a.prefix+'.json').read_text());assert len(b)%E.size==0 and m['record_bytes']==E.size and m['flush_ok'] and m['word_mismatches']==0
 assert sum(c['records'] for c in m['cpu'])*E.size==len(b)
 assert all(c['drops']==0 and c['register_errors']==0 and (not c['records'] or c['supported']) for c in m['cpu'])
 r=analyze(list(E.iter_unpack(b)));s=json.dumps(r,indent=2)+'\n';print(s)
 if a.output:Path(a.output).write_text(s)
 raise SystemExit(0 if r['valid'] else 2)
if __name__=='__main__':main()
