"""Select exact current stack RAM extent from live Miles or CarbonSound call evidence."""
import re,struct
class NoEvidence(AssertionError):pass

def regions(vm):
 out=[]
 for line in vm.splitlines():
  m=re.match(r'^(.+?)\s+([0-9a-f]+)-([0-9a-f]+)\s+\[.*?\]\s+(r[w-][x-])/[^ ]+.*',line)
  if m:out.append((m[1].strip(),int(m[2],16),int(m[3],16),m[4],line))
 return out

def select(execution,vm,base,toc,live):
 assert base==0x570000 and len(live)==0xdf4
 assert execution['errors']==execution['drops']==0 and execution['pid']>1
 # Exact caller/call-return proof inside same freshly verified whole Miles code.
 for pc,word in [(0x5901f4,0x4800011d),(0x5901f8,0x80410014),(0x590224,0x48000105),(0x590228,0x80410014)]:
  assert struct.unpack_from('>I',live,pc-base-0x200e0)[0]==word
 rs=regions(vm);stacks=[r for r in rs if r[0]=='Stack' and r[3]=='rw-']
 carbon=[r for r in rs if r[0]=='__TEXT' and r[3]=='r-x' and 'CarbonSound.framework/' in r[4] and r[4].rstrip().endswith('/CarbonSound')]
 evidence=[];choices=set()
 for r in execution['records']:
  pc,lr,sp=r['pc'],r['lr'],r['sp'];kind=None;region=None
  if base+0x200e0<=pc<=base+0x20488 and r['toc']==toc:
   assert r['word_ok']==1 and r['word']==struct.unpack_from('>I',live,pc-base-0x200e0)[0]
   kind='actual verified Miles callback/fill PC'
  elif lr in (0x5901f8,0x590228):
   maps=[x for x in carbon if x[1]<=pc<x[2]]
   if len(maps)==1:kind='actual CarbonSound PC with exact verified Miles call return LR';region=maps[0][4]
  if kind:
   matches=[x for x in stacks if x[1]<=sp<x[2]]
   assert len(matches)==1,'Relevant current SP has absent/ambiguous actual stack mapping'
   stack=matches[0];choices.add((stack[1],stack[2]));evidence.append(dict(kind=kind,thread=r['thread'],pc=pc,lr=lr,sp=sp,toc=r['toc'],stack_lo=stack[1],stack_hi=stack[2],framework_mapping=region))
 if not choices:raise NoEvidence('No actual callback/fill PC or exact current CarbonSound call-return stack evidence')
 assert len(choices)==1,'Distinct actual callback stack extents; do not widen or choose blindly'
 lo,hi=next(iter(choices));return dict(stack_lo=lo,stack_hi=hi,evidence=evidence,limitations='Callee SP discovers participating stack RAM extent, not callback body SP or future command status. Only current process mappings and exact verified call sites qualify.')
