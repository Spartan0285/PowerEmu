import subprocess,json,socket,time,shutil
from pathlib import Path
r=Path('/tmp/pe9800');meta=r/'oct08-depthwait-native-current.json';d=json.loads(meta.read_text());pid=d['pid']
cmd=subprocess.run(['ps','-p',str(pid),'-o','command='],capture_output=True,text=True).stdout
if cmd:
 if 'oct08-autonomous-support' not in cmd or 'PowerEmu Depth Wait QA.app' not in cmd:raise RuntimeError('Not owned isolated QA')
 c=socket.socket(socket.AF_UNIX);c.settimeout(5);c.connect(d['qmp']);f=c.makefile('r');f.readline();c.sendall(b'{"execute":"qmp_capabilities"}\n')
 while 'return' not in f.readline():pass
 c.sendall(b'{"execute":"quit"}\n');c.close()
 for i in range(50):
  if not subprocess.run(['ps','-p',str(pid)],stdout=subprocess.DEVNULL).returncode:time.sleep(.1)
  else:break
 else:raise RuntimeError('Backend still running')
logs=r/'oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/Logs';dest=r/('oct08-depthwait-native-'+str(pid)+'-logs')
if not dest.exists():shutil.copytree(logs,dest)
d['status']='stopped';meta.write_text(json.dumps(d,indent=2));print('Owned QA stopped and logs archived',pid)
