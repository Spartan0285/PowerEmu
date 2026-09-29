import subprocess as sp, pathlib, plistlib, json, os, time, socket, re, signal, sys, base64
ROOT=pathlib.Path('/Users/adam/Developer/PowerEmu'); APP=ROOT/'build/PowerEmu Integration.app'; IMG=APP/'Contents/Helpers/PowerEmu VM.app/Contents/MacOS/qemu-img'
SOURCE=pathlib.Path.home()/'Library/Application Support/PowerEmu/Virtual Machines/Leopard.poweremu'
TEST=ROOT/'build/integration-tests'; TEST.mkdir(exist_ok=True)
class QMP:
 def __init__(self,path):
  self.s=socket.socket(socket.AF_UNIX);self.s.settimeout(180);self.s.connect(path);self.f=self.s.makefile('rwb',buffering=0);self.f.readline();self.call('qmp_capabilities')
 def call(self,cmd,args=None):
  self.f.write((json.dumps({'execute':cmd,'arguments':args or {}})+'\n').encode())
  while True:
   x=json.loads(self.f.readline())
   if 'error' in x:raise RuntimeError(x)
   if 'return' in x:return x['return']
 def close(self):self.f.close();self.s.close()
def procs():return sp.check_output(['ps','-axo','pid,command'],text=True)
assert str(SOURCE/'Disks') not in '\n'.join(x for x in procs().splitlines() if 'qemu-system' in x), 'Source disk is running'
# Preserve the running Tiger VM; only replace its frontend during this isolated test.
for line in procs().splitlines():
 if '/build/PowerEmu.app/Contents/MacOS/PowerEmu' in line and 'qemu-system' not in line and len(line.split())==2:os.kill(int(line.split()[0]),signal.SIGTERM)
for cpus in [2]:
 root=TEST/('leopard-retry-'+str(cpus));root.mkdir(exist_ok=False)
 vm=root/'Support/Virtual Machines/Leopard.poweremu';(vm/'Disks').mkdir(parents=True)
 config=plistlib.loads((SOURCE/'config.plist').read_bytes());config.update(name='Combined Leopard '+str(cpus),cpuCount=cpus,sshPort=24222+cpus,monitorPort=0,autoStart=True,shareOnNetwork=False,startFullscreen=False,bootFromDisc=False,gamepad=False)
 config['discs']=[];config.pop('insertedDisc',None);config['sharedFolders']=[]
 (vm/'config.plist').write_bytes(plistlib.dumps(config))
 for d in config['disks']:sp.run(['cp','-c',str(SOURCE/'Disks'/d['file']),str(vm/'Disks'/d['file'])],check=True)
 disk=vm/'Disks'/config['disks'][0]['file'];result={'cpus':cpus,'steps':[],'status':'running'}
 def record(name,value):
  result['steps'].append({'name':name,'value':value,'time':time.time()});(root/'result.json').write_text(json.dumps(result,indent=2));print(cpus,name,str(value)[:160],flush=True)
 ssh=['ssh','-p',str(config['sshPort']),'-i',str(pathlib.Path.home()/'.ssh/poweremu_guest'),'-o','BatchMode=yes','-o','ConnectTimeout=4','-o','StrictHostKeyChecking=accept-new','-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa','-o','KexAlgorithms=+diffie-hellman-group1-sha1','-o','Ciphers=+aes128-cbc','adam@127.0.0.1']
 def guest(cmd,timeout=20):
  p=sp.run(ssh+[cmd],capture_output=True,text=True,timeout=timeout)
  if p.returncode:raise RuntimeError(p.stderr[-800:])
  return p.stdout.strip()
 def backend():
  return next((x for x in procs().splitlines() if 'qemu-system' in x and str(disk) in x),None)
 def launch():
  env=dict(os.environ,POWEREMU_EXPERIMENT_SUPPORT=str(root/'Support'))
  log=open(root/'app.log','a');p=sp.Popen([str(APP/'Contents/MacOS/PowerEmu')],env=env,stdout=log,stderr=log,start_new_session=True)
  deadline=time.monotonic()+240
  while time.monotonic()<deadline:
   if p.poll() is not None:raise RuntimeError('Frontend exited')
   try:
    out=guest('/usr/sbin/sysctl hw.ncpu; /usr/sbin/sysctl kern.boottime',timeout=8)
    return p,out
   except Exception:time.sleep(4)
  raise RuntimeError('Guest readiness timed out')
 frontend=None
 try:
  record('offline_precheck',sp.check_output([str(IMG),'check','--output=json',str(disk)],text=True))
  frontend,boot=launch();record('cold_boot',boot);assert 'hw.ncpu: '+str(cpus) in boot
  row=backend();assert row;record('command',row);qpath=re.search(r'-qmp unix:([^,]+)',row)[1]
  q=QMP(qpath);record('vcpus',q.call('query-cpus-fast'));assert len(q.call('query-cpus-fast'))==cpus
  q.call('screendump',{'filename':str(root/'desktop.png'),'format':'png'});q.close()
  marker='combined-memory-'+str(time.time_ns())
  code="import socket\ns=socket.socket();s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);s.bind(('127.0.0.1',9911));s.listen(5)\nwhile True:\n c,a=s.accept();c.sendall('"+marker+"');c.close()\n"
  encoded=base64.b64encode(code.encode()).decode()
  guest("python -c \"import base64;open('/tmp/combined-memory.py','w').write(base64.b64decode('"+encoded+"'))\"; python -c \"import os;pid=os.fork();pid and os._exit(0);os.setsid();execfile('/tmp/combined-memory.py')\" >/tmp/combined-memory.log 2>&1 </dev/null")
  read="python -c \"import socket;s=socket.socket();s.connect(('127.0.0.1',9911));print s.recv(256)\""
  time.sleep(1);assert guest(read)==marker;record('memory_marker',marker)
  q=QMP(qpath);reply=q.call('human-monitor-command',{'command-line':'savevm PowerEmuSleep'});record('save_reply',reply);assert not reply.strip();q.call('stop');q.call('quit');q.close()
  time.sleep(3);assert backend() is None;frontend.terminate();frontend.wait(timeout=10)
  frontend,restored=launch();record('restored_boot',restored);assert 'hw.ncpu: '+str(cpus) in restored;assert '-loadvm PowerEmuSleep' in backend();assert guest(read)==marker;record('memory_restored',True)
  qpath=re.search(r'-qmp unix:([^,]+)',backend())[1];q=QMP(qpath);record('restored_vcpus',q.call('query-cpus-fast'))
  reply=q.call('human-monitor-command',{'command-line':'savevm PowerEmuSleep'});assert not reply.strip();q.call('stop');q.call('quit');q.close();time.sleep(3)
  frontend.terminate();frontend.wait(timeout=10);frontend=None
  record('offline_postcheck',sp.check_output([str(IMG),'check','--output=json',str(disk)],text=True));result['status']='passed'
 except Exception as e:
  result['status']='failed';result['error']=str(e);print('FAILED',cpus,str(e),flush=True)
  # Preserve a running failed guest for diagnosis. Never kill its backend.
 finally:
  (root/'result.json').write_text(json.dumps(result,indent=2));print('RESULT',cpus,result['status'],flush=True)
 if result['status']!='passed':break
