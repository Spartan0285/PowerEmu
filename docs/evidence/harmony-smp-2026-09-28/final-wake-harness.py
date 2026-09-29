import pathlib,subprocess as sp,os,time,socket,json,re,hashlib
R=pathlib.Path('/Users/adam/Developer/PowerEmu');A=R/'build/PowerEmu Integration.app';E=R/'docs/evidence/harmony-smp-2026-09-28'
def qmp(path,command,args=None):
 s=socket.socket(socket.AF_UNIX);s.settimeout(120);s.connect(path);f=s.makefile('rwb',buffering=0);f.readline()
 for cmd,a in [('qmp_capabilities',{}),(command,args or {})]:
  f.write((json.dumps({'execute':cmd,'arguments':a})+'\n').encode())
  while True:
   m=json.loads(f.readline())
   if 'error' in m:raise RuntimeError(m)
   if 'return' in m:break
 f.close();s.close();return m['return']
results={'app_sha256':hashlib.sha256((A/'Contents/MacOS/PowerEmu').read_bytes()).hexdigest(),'cases':[]}
for count in [1,2]:
 root=R/'build/integration-tests'/('leopard-retry-'+str(count));disk=root/'Support/Virtual Machines/Leopard.poweremu/Disks/Macintosh HD.qcow2'
 old=json.loads((root/'result.json').read_text());marker=next(x['value'] for x in old['steps'] if x['name']=='memory_marker')
 env=dict(os.environ,POWEREMU_EXPERIMENT_SUPPORT=str(root/'Support'))
 log=open(root/'final-app.log','a');p=sp.Popen([str(A/'Contents/MacOS/PowerEmu')],env=env,stdout=log,stderr=log,start_new_session=True)
 ssh=['ssh','-p',str(24222+count),'-i',str(pathlib.Path.home()/'.ssh/poweremu_guest'),'-o','BatchMode=yes','-o','ConnectTimeout=4','-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa','-o','KexAlgorithms=+diffie-hellman-group1-sha1','-o','Ciphers=+aes128-cbc','adam@127.0.0.1']
 case={'cpu_count':count};results['cases'].append(case)
 try:
  until=time.monotonic()+100
  while True:
   r=sp.run(ssh+["/usr/sbin/sysctl hw.ncpu; python -c \"import socket;s=socket.socket();s.connect(('127.0.0.1',9911));print s.recv(256)\""],capture_output=True,text=True,timeout=12)
   if r.returncode==0:break
   if time.monotonic()>until:raise RuntimeError(r.stderr)
   time.sleep(3)
  assert marker in r.stdout and 'hw.ncpu: '+str(count) in r.stdout
  rows=sp.check_output(['ps','-axo','pid,command'],text=True).splitlines();row=next(x for x in rows if 'qemu-system' in x and str(disk) in x)
  assert '-loadvm PowerEmuSleep' in row
  path=re.search(r'-qmp unix:([^,]+)',row)[1];case.update(marker_restored=True,readback=r.stdout,vcpus=qmp(path,'query-cpus-fast'))
  assert not qmp(path,'human-monitor-command',{'command-line':'savevm PowerEmuSleep'}).strip()
  qmp(path,'stop');qmp(path,'quit');time.sleep(2);p.terminate();p.wait(timeout=10)
  r=sp.run([str(A/'Contents/Helpers/PowerEmu VM.app/Contents/MacOS/qemu-img'),'check','--output=json',str(disk)],capture_output=True,text=True);assert r.returncode==0;case['disk_check']=json.loads(r.stdout);case['status']='passed'
 except Exception as exc:
  case['status']='failed';case['error']=str(exc)
 (E/'final-bundle-wake.json').write_text(json.dumps(results,indent=2));print(case['cpu_count'],case['status'],flush=True)
 if case['status']!='passed':break
