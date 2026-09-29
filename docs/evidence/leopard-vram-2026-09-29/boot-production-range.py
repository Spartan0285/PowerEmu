"""Run on Studio; only temporary snapshots of the inactive Leopard base are written."""
import subprocess, pathlib, time, json, socket
root=pathlib.Path('/Users/adam/Developer/PowerEmu-SMP/vram-investigation-219')
app=root/'PowerEmu.app/Contents/Helpers/PowerEmu VM.app/Contents'
fw=app/'Resources/firmware'
base='/Users/adam/Developer/PowerEmu-SMP/vms/leopard-base.qcow2'
ssh=['ssh','-i','/Users/adam/.ssh/poweremu_guest','-o','BatchMode=yes','-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no','-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR','-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa']
procs=[]; outcomes={}; start=time.monotonic()
try:
 for size,port in [(64,25464),(128,25465),(256,25466)]:
  d=root/(str(size)+'-production'); d.mkdir(exist_ok=True)
  prom='boot-command=" /cpus/PowerPC,G4@0" find-device d# 1420000000 encode-int " clock-frequency" property device-end " /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/QEMU,VGA@e" [\'] find-device catch 0= if h# '+format(size*1024*1024,'x')+' encode-int " VRAM,totalsize" property device-end then boot'
  prom=prom[:-4]+'" /pci@f2000000" find-device h# 1000000 encode-int h# 0 encode-int encode+ h# 0 encode-int encode+ h# f2000000 encode-int encode+ h# 0 encode-int encode+ h# 800000 encode-int encode+ h# 2000000 encode-int encode+ h# 0 encode-int encode+ h# 80000000 encode-int encode+ h# 80000000 encode-int encode+ h# 0 encode-int encode+ h# 40000000 encode-int encode+ " ranges" property device-end '+'boot'
  prom=json.loads((root/'production-prom.json').read_text())[str(size)]
  args=[str(app/'MacOS/qemu-system-ppc'),'-name','VRAM diagnostic '+str(size),'-L',str(fw),'-nodefaults','-vga','none','-machine','mac99,via=pmu','-g','1024x768x32','-device','loader,addr=0x4000000,file='+str(fw/'ppc-ndrvloader'),'-prom-env',prom,'-prom-env','boot-args=-v','-m','2048','-cpu','7400','-smp','2,sockets=2,cores=1,threads=1','-accel','tcg,thread=multi,tb-size=512','-audio','none','-display','none','-device','ppc-mac-gpu,id=gpu0,vgamem_mb='+str(size),'-global','uni-north-pci.agp-capable=on','-netdev',f'user,id=n0,ipv6=off,hostfwd=tcp:127.0.0.1:{port}-:22','-device','sungem,netdev=n0','-usb','-device','usb-kbd','-device','usb-tablet','-drive','if=none,id=d0,file='+base+',format=qcow2,snapshot=on','-device','ide-hd,bus=ide.0,unit=0,drive=d0,bootindex=0','-serial','file:'+str(d/'console.log'),'-qmp','unix:'+str(d/'qmp')+',server=on,wait=off','-D',str(d/'trace.log'),'-trace','ppc_mac_gpu_realize']
  (d/'argv.json').write_text(json.dumps(args,indent=2))
  log=open(d/'backend.log','wb');p=subprocess.Popen(args,stdout=log,stderr=subprocess.STDOUT);log.close();procs.append((size,port,d,p));print('Started',size,'PID',p.pid,flush=True)
 while time.monotonic()-start<210 and len(outcomes)<len(procs):
  for size,port,d,p in procs:
   if size in outcomes: continue
   if p.poll() is not None: outcomes[size]={'exit':p.returncode};print(size,outcomes[size],flush=True);continue
   query='sw_vers; ps -axww | grep -E "[W]indowServer|[F]inder.app|[l]oginwindow"; system_profiler SPDisplaysDataType'
   try:r=subprocess.run(ssh+['-p',str(port),'adam@127.0.0.1',query],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=15)
   except subprocess.TimeoutExpired:continue
   if r.returncode==0 and b'CoreServices/Finder.app' in r.stdout:
    (d/'guest-status.txt').write_bytes(r.stdout)
    outcomes[size]={'ssh':True,'finder':b'CoreServices/Finder.app' in r.stdout,'elapsed':round(time.monotonic()-start)}
    print(size,outcomes[size],r.stdout.decode(errors='replace'),flush=True)
  time.sleep(5)
 for size,port,d,p in procs:
  if size not in outcomes:outcomes[size]={'ssh':False,'timeout':210}
  if p.poll() is None:
   try:
    s=socket.socket(socket.AF_UNIX);s.settimeout(3);s.connect(str(d/'qmp'));f=s.makefile('rwb',buffering=0);f.readline()
    def command(name,args=None):
     obj={'execute':name};
     if args:obj['arguments']=args
     f.write((json.dumps(obj)+'\n').encode())
     while True:
      val=json.loads(f.readline())
      if 'return' in val or 'error' in val:return val
    command('qmp_capabilities');outcomes[size]['status']=command('query-status');command('screendump',{'filename':str(d/'screen.ppm')});s.close()
   except Exception as e:outcomes[size]['qmp_error']=str(e)
 (root/'production-results.json').write_text(json.dumps(outcomes,indent=2));print(json.dumps(outcomes,indent=2),flush=True)
finally:
 for size,port,d,p in procs:
  if p.poll() is None:p.terminate()
 for size,port,d,p in procs:
  try:p.wait(timeout=10)
  except subprocess.TimeoutExpired:p.kill();p.wait()
