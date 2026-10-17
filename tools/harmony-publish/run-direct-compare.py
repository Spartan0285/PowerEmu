#!/usr/bin/env python3
"""Owned-clone-only paired control/direct/control complete-capture comparison."""
import json,pathlib,plistlib,shutil,socket,subprocess,threading,time,uuid,sys,re
root=pathlib.Path('/Users/adam/Developer/PowerEmu');label=sys.argv[1]
assert label.replace('-','').isalnum()
meta=json.loads(pathlib.Path('/tmp/pe9800/oct08-depthwait-native-current.json').read_text())
guard=json.loads(pathlib.Path(meta['produced_guard']).read_text())
assert meta['status']=='running' and time.clock_gettime_ns(time.CLOCK_MONOTONIC)+90*10**9<guard['deadline_ns']
assert subprocess.check_output(['ps','-p',str(meta['pid']),'-o','command='],text=True).strip()==guard['owned_command']
assert 'audio-tests-2026-10-14/support' in guard['owned_command']
listener=socket.socket();listener.bind(('127.0.0.1',0));listener.listen(8);listener.settimeout(1)
port=listener.getsockname()[1];sockpath='/tmp/pe-cap-'+uuid.uuid4().hex[:12]
out=root/'build'/f'{label}.json';connections=[];stop=threading.Event()
def pump(a,b):
 try:
  while True:
   data=a.recv(65536)
   if not data:break
   b.sendall(data)
 except OSError:pass
 finally:
  try:b.shutdown(socket.SHUT_WR)
  except OSError:pass

def bridge():
 while not stop.is_set():
  try:client,_=listener.accept()
  except socket.timeout:continue
  except OSError:return
  unix=socket.socket(socket.AF_UNIX)
  try:unix.connect(sockpath)
  except OSError:client.close();unix.close();continue
  connections.extend((client,unix))
  threading.Thread(target=pump,args=(client,unix),daemon=True).start();threading.Thread(target=pump,args=(unix,client),daemon=True).start()
appdir=root/'build'/'direct-request-guest'/(label+'.app')
(appdir/'Contents/MacOS').mkdir(parents=True,exist_ok=True)
shutil.copyfile(root/'build/audio-tests-2026-10-14/guest-capture/PowerEmuAgentDirect',appdir/'Contents/MacOS/Agent');(appdir/'Contents/MacOS/Agent').chmod(0o755)
(appdir/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundleExecutable='Agent',CFBundleIdentifier='com.poweremu.tests.capture.'+uuid.uuid4().hex,CFBundlePackageType='APPL',CFBundleName='Capture Comparison',LSUIElement=True,LSEnvironment=dict(PE_AGENT_HOST='10.0.2.2',PE_AGENT_PORT=str(port),PE_CAPTURE_DIRECT_RECEIVER='1'))))
proc=subprocess.Popen([str(root/'build/harmony-direct-compare'),sockpath,str(out)]+(['direct-first'] if len(sys.argv)>2 else []))
try:
 for _ in range(100):
  if pathlib.Path(sockpath).exists():break
  time.sleep(.05)
 threading.Thread(target=bridge,daemon=True).start()
 tar=subprocess.Popen(['tar','-C',str(appdir.parent),'-cf','-',appdir.name],stdout=subprocess.PIPE)
 subprocess.run(['python3','/tmp/pe9800/guest-ssh.py','2319','tar -xf - -C /tmp; open /tmp/'+appdir.name],stdin=tar.stdout,check=True,timeout=15);tar.stdout.close();assert tar.wait()==0
 print('comparison exit',proc.wait(timeout=75))
finally:
 if proc.poll() is None:proc.terminate();proc.wait(timeout=5)
 stop.set();listener.close()
 for connection in connections:connection.close()
 pathlib.Path(sockpath).unlink(missing_ok=True)
 # Kill only this harness's exact guest executable, never the installed agent.
 listing=subprocess.run(['python3','/tmp/pe9800/guest-ssh.py','2319','ps -ww -ax -o pid,command'],capture_output=True,text=True,timeout=10)
 executable='/tmp/'+appdir.name+'/Contents/MacOS/Agent'
 for row in listing.stdout.splitlines():
  m=re.match(r'\s*(\d+)\s+(.*)',row)
  if m and m[2].split(' -psn_',1)[0]==executable:
   subprocess.run(['python3','/tmp/pe9800/guest-ssh.py','2319','kill '+m[1]],check=True,timeout=10)
print(out)
