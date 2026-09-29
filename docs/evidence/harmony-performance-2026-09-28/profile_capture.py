import socket,subprocess,json,time,uuid,pathlib,statistics,struct,zlib,os,sys,hashlib
root=pathlib.Path(__file__).resolve().parent
ssh=json.loads((root/'ssh.json').read_text())
listen=socket.socket();listen.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,1);listen.bind(('127.0.0.1',17700));listen.listen();listen.settimeout(20)
label=sys.argv[2] if len(sys.argv)>2 else 'profile'
log=open(root/(label+'-stages.log'),'w')
flags=('PE_CAPTURE_RLE=1 ' if os.getenv('PE_CAPTURE_RLE') else '')+('PE_CAPTURE_REUSE='+os.environ['PE_CAPTURE_REUSE']+' ' if os.getenv('PE_CAPTURE_REUSE') in ['0','1'] else '')+('PE_CAPTURE_RAW=1 ' if os.getenv('PE_CAPTURE_RAW') else '')
proc=subprocess.Popen(ssh+[flags+'PE_AGENT_HOST=10.0.2.2 PE_AGENT_PORT=17700 POWEREMU_CAPTURE_PROFILE=1 /tmp/pe-profile-agent'],stdout=log,stderr=log)
def recv(f):
 h=f.readline().split(); assert len(h)==2,h
 n=int(h[1]);b=f.read(n);assert len(b)==n
 return h[0],b
def send(c,verb,data):
 b=data.encode();c.sendall(verb.encode()+b' '+str(len(b)).encode()+b'\n'+b)
try:
 c,_=listen.accept();c.settimeout(15);f=c.makefile('rb');v,b=recv(f);assert v==b'HELLO'
 send(c,'HELLO','2.8 profile '+str(uuid.uuid4()))
 window=int(__import__('sys').argv[1]);rows=[];base=0;last=None
 for seq in range(1,81):
  accepted=0 if os.getenv('PE_PROFILE_PATTERN')=='full' else (base if os.getenv('PE_PROFILE_PATTERN')=='idle' else (0 if seq%2 else base))
  start=time.monotonic();send(c,'WINDOWFRAME',f'{window} {seq} {accepted}')
  if seq==1:
   image,_=listen.accept();image.settimeout(15);im=image.makefile('rb');assert recv(im)[0]==b'FRAMEHELLO'
  verb,data=recv(im);assert verb==b'WINDOWFRAME'
  head,pixels=data.split(b'\n',1);wid,w,h,encoding,response=map(int,head.split());assert wid==window and response==seq and w>0
  if encoding==2:assert accepted==base and last is not None and not pixels
  else:
   raw=zlib.decompress(pixels) if encoding==1 else pixels
   assert len(raw)==w*h*4
   if last is not None: assert raw==last, "stationary window pixels changed"
   last=raw
  base=seq;rows.append(dict(seq=seq,encoding=encoding,bytes=len(data),pixelSHA256=hashlib.sha256(last).hexdigest(),roundTripMS=(time.monotonic()-start)*1000))
 print(json.dumps(rows,indent=2));(root/(label+'-requests.json')).write_text(json.dumps(rows,indent=2))
finally:
 # Kill only this diagnostic process, not the installed guest tools.
 r=subprocess.run(ssh+['/bin/ps axww'],capture_output=True,text=True)
 for line in r.stdout.splitlines():
  if line.strip().endswith('/tmp/pe-profile-agent'):
   subprocess.run(ssh+['kill '+str(int(line.split()[0]))],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
 proc.wait(timeout=15);listen.close();log.close()
