"""Bounded host protocol checks; only creates this prototype's own window."""
from pathlib import Path
import json,socket,subprocess,sys,tempfile,time
binary=Path(sys.argv[1]).resolve()
def packet(seq):
    w,h=(615,407) if seq<=160 else (512,320)
    # Independently generate repeat-pixel packets, not a copy of the C packer.
    out=bytearray()
    for y in range(h):
        for x in range(0,w,32):
            n=min(32,w-x)
            out.extend([0x80|(n-1),((x//32+seq)&1)*255,((y//32+seq//2)&1)*255,((x//64+y//64+seq//3)&1)*255,255])
    return f'1 {w} {h} 3 {seq}\n'.encode()+out
with tempfile.TemporaryDirectory(prefix='pe-publish-protocol-') as tmp:
    for case in ['valid','wrong-nonce','oversize','duplicate','corrupt']:
        target=Path(tmp)/(case+'.json')
        p=subprocess.Popen([str(binary),str(target)],stdout=subprocess.DEVNULL,stderr=subprocess.PIPE)
        try:
            config=target.with_suffix('.json.config')
            deadline=time.monotonic()+8
            while not config.exists() and p.poll() is None and time.monotonic()<deadline:time.sleep(.05)
            port,nonce=config.read_text().split()
            with socket.create_connection(('127.0.0.1',int(port)),timeout=5) as s:
                s.sendall(f'PUBLISHHELLO {nonce if case!="wrong-nonce" else "0"*32}\n'.encode())
                f=s.makefile('rb')
                if case=='oversize':s.sendall(b'FRAME 4000001\n')
                elif case!='wrong-nonce':
                    for seq in ([1,80,81,160,161,240] if case=='valid' else [1,1] if case=='duplicate' else [1]):
                        data=packet(seq)
                        if case=='corrupt':data=data[:-1]+bytes([data[-1]^255])
                        s.sendall(f'FRAME {len(data)}\n'.encode()+data)
                        ack=f.readline()
                        if case=='duplicate' and seq==1 and not ack:break
                        if case!='corrupt':assert ack==f'ACK {seq}\n'.encode(),ack
                f.close()
            p.wait(timeout=8)
            result=json.loads(target.read_text())
            assert (result['error'] is None)==(case=='valid'),result
            assert (p.returncode==0)==(case=='valid'),p.returncode
            if case=='valid':assert result['published']==6
            print('PASS',case)
        finally:
            if p.poll() is None:p.kill();p.wait()
