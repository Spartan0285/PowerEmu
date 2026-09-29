import subprocess,pathlib,json,time,socket,os
root=pathlib.Path('/Users/adam/Developer/PowerEmu-SMP/r350-probe-20260929')
old='/Users/adam/Developer/PowerEmu-SMP/vram-investigation-219'
args=json.loads(pathlib.Path(old+'/128-production/argv.json').read_text())
args=[x.replace(old+'/PowerEmu.app',str(root/'Probe.app')).replace(old+'/128-production',str(root/'boot1')).replace('ppc-mac-gpu,id=gpu0','ppc-mac-r350-probe,id=gpu0').replace('25465','25398').replace('VRAM diagnostic 128','R350 diagnostic') for x in args]
args[args.index('-smp')+1]='1';args[args.index('-accel')+1]='tcg,thread=single,tb-size=512'
d=root/'boot1';d.mkdir(exist_ok=True);(d/'argv.json').write_text(json.dumps(args,indent=2))
ssh=['ssh','-p','25398','-i','/Users/adam/.ssh/poweremu_guest','-o','BatchMode=yes','-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR','-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa','adam@127.0.0.1']
log=open(d/'backend.log','wb');p=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT);log.close();(d/'pid').write_text(str(p.pid));start=time.monotonic();print('PID',p.pid,flush=True)
try:
 while p.poll() is None and time.monotonic()-start<120:
  try:
   r=subprocess.run(ssh+['sw_vers; kextstat | grep -i ATI; ioreg -r -c ATIRadeon9700 -l -w 0; system_profiler SPDisplaysDataType; ps -axww | grep -E "[F]inder.app|[W]indowServer"'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=12)
   if r.returncode==0:
    (d/'guest.txt').write_bytes(r.stdout);print('SSH reached after',round(time.monotonic()-start),'seconds',flush=True);print(r.stdout.decode(errors='replace')[:8000],flush=True);time.sleep(12);break
  except subprocess.TimeoutExpired:pass
  time.sleep(4)
 if p.poll() is None:
  s=socket.socket(socket.AF_UNIX);s.settimeout(4);s.connect(str(d/'qmp'));f=s.makefile('rwb',buffering=0);f.readline()
  def call(name,arg=None):
   req={'execute':name}
   if arg:req['arguments']=arg
   f.write((json.dumps(req)+'\n').encode())
   while True:
    val=json.loads(f.readline())
    if 'return' in val or 'error' in val:return val
  call('qmp_capabilities');state={}
  for cmd in ['info pci','info registers','info qtree']:
   state[cmd]=call('human-monitor-command',{'command-line':cmd})
  call('screendump',{'filename':str(d/'screen.ppm')});(d/'state.json').write_text(json.dumps(state,indent=2));f.close();s.close()
 print('emulator exit before cleanup:',p.poll(),flush=True)
finally:
 if p.poll() is None:p.terminate()
 try:p.wait(timeout=10)
 except subprocess.TimeoutExpired:p.kill();p.wait()
 print('probe stopped; snapshot discarded',flush=True)
