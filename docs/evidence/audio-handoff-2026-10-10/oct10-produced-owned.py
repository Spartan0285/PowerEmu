"""Register/guard an already launched isolated VM. Never launches an emulator."""
import subprocess,json,re,socket,time,os,sys,signal
from pathlib import Path
R=Path('/tmp/pe9800')
def command(pid):return subprocess.check_output(['ps','-p',str(pid),'-o','command='],text=True).strip()
def age(pid):
 x=subprocess.check_output(['ps','-p',str(pid),'-o','etime='],text=True).strip();days=0
 if '-' in x:d,x=x.split('-');days=int(d)
 t=[int(y) for y in x.split(':')];return days*86400+sum(v*60**i for i,v in enumerate(reversed(t)))
def qmp(path,cmd):
 s=socket.socket(socket.AF_UNIX);s.settimeout(3);s.connect(path);f=s.makefile('rwb');json.loads(f.readline())
 for name in ['qmp_capabilities',cmd]:
  f.write((json.dumps({'execute':name})+'\n').encode());f.flush()
  while True:
   r=json.loads(f.readline())
   if 'error' in r:raise RuntimeError(r)
   if 'return' in r:break
 f.close();s.close();return r['return']
if sys.argv[1]=='guard':
 receipt=Path(sys.argv[2]);g=json.loads(receipt.read_text());pid=g['owned_pid'];deadline=g['deadline_ns']
 while time.clock_gettime_ns(time.CLOCK_MONOTONIC)<deadline:
  try:
   if command(pid)!=g['owned_command']:raise SystemExit(0)
  except subprocess.CalledProcessError:raise SystemExit(0)
  time.sleep(1)
 try:qmp(g['qmp'],'quit')
 except Exception as e:print('Owned stop error:',type(e).__name__,flush=True)
 time.sleep(2)
 try:
  if command(pid)==g['owned_command']:os.kill(pid,signal.SIGTERM)
 except subprocess.CalledProcessError:pass
 g['guard_expired']=True;receipt.write_text(json.dumps(g,indent=2)+'\n')
else:
 label=sys.argv[1];stage=json.loads((R/(label+'.produced-stage.json')).read_text());assert stage['status']=='staged-not-launched'
 rows=subprocess.check_output(['ps','-ax','-o','pid,command'],text=True).splitlines();owned=[]
 for row in rows:
  m=re.match(r'\s*(\d+)\s+(.*)',row)
  if m and '/Contents/MacOS/qemu-system-ppc' in m[2] and 'Depth Wait QA.app' in m[2] and 'oct08-autonomous-support' in m[2]:owned.append(int(m[1]))
 assert len(owned)==1,owned;pid=owned[0];cmd=command(pid);assert stage['control'] in cmd and stage['manifest'] in cmd and 'hostfwd=tcp:127.0.0.1:2319-:22' in cmd
 sock=re.search(r'-qmp unix:([^, ]+)',cmd).group(1);elapsed=age(pid);assert elapsed<480
 deadline=time.clock_gettime_ns(time.CLOCK_MONOTONIC)+(480-elapsed)*1000000000;receipt=R/(label+'.produced-guard.json');g=dict(owned_pid=pid,owned_command=cmd,qmp=sock,deadline_ns=deadline,strict_stop_seconds=480);receipt.write_text(json.dumps(g,indent=2)+'\n')
 log=open(R/(label+'.produced-guard.log'),'ab',buffering=0);watch=subprocess.Popen([sys.executable,__file__,'guard',str(receipt)],stdout=log,stderr=log,start_new_session=True);g['guard_pid']=watch.pid;receipt.write_text(json.dumps(g,indent=2)+'\n')
 meta=dict(pid=pid,qmp=sock,prefix=f'{label}.{pid}',status='running',keep_pace_debt=False,produced_guard=str(receipt));(R/'oct08-depthwait-native-current.json').write_text(json.dumps(meta,indent=2)+'\n');print(json.dumps(meta))
