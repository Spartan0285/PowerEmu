from pathlib import Path
import plistlib,json,hashlib,subprocess,sys,re,time,os,signal
r=Path('/tmp/pe9800');mode,label=sys.argv[1:];assert re.fullmatch(r'oct1[01]-[a-z0-9-]+',label)
info=Path('/Users/adam/Developer/PowerEmu/build/PowerEmu Depth Wait QA.app/Contents/Info.plist');cfg=Path('/tmp/pe9800/oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/config.plist');stage=r/(label+'.stage.json');app=str(info.parents[1])
def sign():
 subprocess.run(['codesign','--force','--sign','Developer ID Application: Adam Cipoletti (7B2D3VV69V)','--timestamp=none','--options','runtime','--entitlements','/Users/adam/Developer/PowerEmu/app/Resources/PowerEmu.entitlements',app],check=True)
 subprocess.run(['codesign','--verify','--deep','--strict',app],check=True)
def rows():return subprocess.check_output(['ps','-ax','-o','pid,command'],text=True).splitlines()
def no_emulator():
 # Match the EXECUTABLE field, not the command line.  `ps -o command=` returns
 # whole command lines, so grepping those for the emulator path also matches
 # this very process -- the shell and python invocations carry the string in
 # their own arguments.  That false positive made `restore` refuse and left
 # the QA app staged and signed.
 comms=subprocess.check_output(['ps','-ax','-o','comm='],text=True).splitlines()
 live=[c for c in comms if c.rstrip().endswith(('/qemu-system-ppc','/qemu-system-ppc64'))]
 assert not live,f'an emulator is running; refuse: {live}'
def no_app():
 # The app reads config.plist once, at launch, and keeps it in memory, so
 # staging underneath a running app yields a VM without the staged settings
 # however correct the file on disk looks.
 live=[l for l in rows() if 'Depth Wait QA.app/Contents/MacOS/' in l]
 assert not live,'the QA app is running; it would re-read config.plist from memory'
if mode=='stage':
 no_emulator();no_app();assert not stage.exists();assert not plistlib.loads(cfg.read_bytes()).get('extraQEMUArgs')
 before=r/(label+'.Info.plist.before');before.write_bytes(info.read_bytes());p=plistlib.loads(info.read_bytes());p['LSEnvironment']={k:v for k,v in p.get('LSEnvironment',{}).items()if k=='POWEREMU_EXPERIMENT_SUPPORT'};p['LSEnvironment'].update(POWEREMU_AUDIO_KEEP_PACE_DEBT='0',POWEREMU_SCREAMER_LIFECYCLE_FIX='0',POWEREMU_SCREAMER_SLICE_PACING='0');info.write_bytes(plistlib.dumps(p));stage.write_text(json.dumps(dict(info=str(info),before=str(before),staged_sha=hashlib.sha256(info.read_bytes()).hexdigest(),cfg_sha=hashlib.sha256(cfg.read_bytes()).hexdigest(),status='staged')));sign();subprocess.run(['open',app],check=True)
elif mode=='register':
 owned=[]
 for row in rows():
  m=re.match(r'\s*(\d+)\s+(.*)',row)
  if m and '/Contents/MacOS/qemu-system-ppc' in m[2] and 'Depth Wait QA.app' in m[2] and 'oct08-autonomous-support' in m[2]:owned.append((int(m[1]),m[2]))
 assert len(owned)==1,owned;pid,cmd=owned[0];assert 'hostfwd=tcp:127.0.0.1:2319-:22' in cmd;assert '-plugin' not in cmd;sock=re.search(r'-qmp unix:([^, ]+)',cmd).group(1);et=subprocess.check_output(['ps','-p',str(pid),'-o','etime='],text=True).strip();t=[int(x)for x in et.split(':')];age=sum(v*60**i for i,v in enumerate(reversed(t)));assert age<480
 g=dict(owned_pid=pid,owned_command=cmd,qmp=sock,deadline_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC)+(480-age)*10**9,strict_stop_seconds=480);path=r/(label+'.produced-guard.json');path.write_text(json.dumps(g));log=open(r/(label+'.produced-guard.log'),'ab',buffering=0);w=subprocess.Popen([sys.executable,str(r/'oct10-produced-owned.py'),'guard',str(path)],stdout=log,stderr=log,start_new_session=True);g['guard_pid']=w.pid;path.write_text(json.dumps(g));meta=dict(pid=pid,qmp=sock,prefix=f'{label}.{pid}',status='running',keep_pace_debt=False,produced_guard=str(path));(r/'oct08-depthwait-native-current.json').write_text(json.dumps(meta));print(json.dumps(meta))
elif mode=='restore':
 no_emulator();s=json.loads(stage.read_text());assert hashlib.sha256(info.read_bytes()).hexdigest()==s['staged_sha'];assert hashlib.sha256(cfg.read_bytes()).hexdigest()==s['cfg_sha']
 for row in rows():
  m=re.match(r'\s*(\d+)\s+(.*)',row)
  if m and m[2]==app+'/Contents/MacOS/PowerEmu':os.kill(int(m[1]),signal.SIGTERM)
 info.write_bytes(Path(s['before']).read_bytes());sign();s['status']='restored';stage.write_text(json.dumps(s))
else:raise SystemExit('Unknown operation')
