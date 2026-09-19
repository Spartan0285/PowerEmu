import re,sys,collections
L=open(sys.argv[1]).read().split('\n')
pat=re.compile(r'^([ +!:|]*)(\d+) (.+?)  \(in (.+?)\)')
blocks=[];cur=None
for i,l in enumerate(L):
    if re.match(r'^\s+\d+ Thread_',l): cur=[i];blocks.append(cur)
    elif cur is not None: cur.append(i)
vb=[b for b in blocks if 'cpu_thread_fn' in '\n'.join(L[j] for j in b[:60])][0]
entries=[]
for j in vb[1:]:
    m=pat.match(L[j])
    if m: entries.append((len(m.group(1)),int(m.group(2)),m.group(3).strip(),m.group(4)))
self_t=collections.Counter()
for k,(d,c,n,lib) in enumerate(entries):
    kids=[];mind=None
    for d2,c2,n2,l2 in entries[k+1:]:
        if d2<=d: break
        if mind is None: mind=d2
        if d2==mind: kids.append(c2)
    self_t['JIT code' if lib=='<unknown binary>' else n]+=c-sum(kids)
tot=sum(self_t.values())
for n,c in self_t.most_common(int(sys.argv[2]) if len(sys.argv)>2 else 18): print('%5d %5.1f%%  %s'%(c,100*c/tot,n))
