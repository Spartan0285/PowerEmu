import argparse,subprocess,struct,json,time
from pathlib import Path
P=argparse.ArgumentParser();P.add_argument('pid',type=int);P.add_argument('label');A=P.parse_args();R=Path('/tmp/pe9800')
def read(addr,n):
 b=subprocess.check_output(['python3',str(R/'guest-ssh.py'),'2319',f'/tmp/oct10-miles-read-memory {A.pid} {addr:x} {n:x}'],timeout=25)
 if len(b)!=n:raise RuntimeError('Incomplete read')
 return b
def u32(b,o=0):return struct.unpack_from('>I',b,o)[0]
vec=read(0x39b324,8);assert struct.unpack('>II',vec)==(0x5900e0,0x3a2000)
pef=(R/'oct10-guest-Miles-Carbon-Library.pef').read_bytes();live=read(0x5900e0,0xdf4);assert live==pef[0x200e0:0x20ed4]
toc=u32(vec,4);head=u32(read(toc-0x1474,4));maximum=u32(read(toc-0x12c4,4));assert 0<maximum<=128
nodes=[];seen=set();ptr=head
while ptr:
 assert ptr not in seen and len(seen)<8 and ptr%4==0;seen.add(ptr);b=read(ptr,256)
 (R/(A.label+f'.guest{A.pid}.driver{ptr:x}.bin')).write_bytes(b)
 row=dict(address=ptr,requested_rate=u32(b,0x14),channels=u32(b,0x20),bytes_per_sample=u32(b,0x24),frames_per_chunk=u32(b,0x2c),active=u32(b,0x30),sample_count=u32(b,0x34),sample_array=u32(b,0x40),next=u32(b,0x48),header_pointer=u32(b,0x58),header_channels=u32(b,0x5c),rate_fixed=u32(b,0x60),encode=b[0x6c],queued_frames=u32(b,0x6e),sample_bits=struct.unpack_from('>H',b,0x88)[0],sound_channel=u32(b,0x9a),buffer_bases=[u32(b,0xa2),u32(b,0xa6)],filled_chunks=[u32(b,0xaa),u32(b,0xae)],fill_index=u32(b,0xb2),play_index=u32(b,0xb6),chunk_bytes=u32(b,0xe6))
 row['rate']=row['rate_fixed']/65536;row['queued_ms']=1000*row['queued_frames']/row['rate'] if row['rate'] else None
 nodes.append(row);ptr=row['next']
assert u32(read(toc-0x1474,4))==head
active=[x for x in nodes if x['active'] and x['sound_channel']];assert len(active)==1
x=active[0];b2=read(x['address'],256)
for off,size in [(0x14,4),(0x20,4),(0x24,4),(0x2c,4),(0x5c,4),(0x60,4),(0x6c,1),(0x88,2),(0xe6,4)]:
 original=(R/(A.label+f'.guest{A.pid}.driver{x["address"]:x}.bin')).read_bytes();assert original[off:off+size]==b2[off:off+size]
assert u32(read(toc-0x1474,4))==head and u32(read(toc-0x12c4,4))==maximum
assert x['encode']==255, 'Standard header requires separate duration decoding; no extended inference'
assert x['channels']>0 and x['bytes_per_sample']>0 and x['frames_per_chunk']>0 and x['chunk_bytes']>0
assert x['header_channels']==x['channels'] and x['sample_bits']==x['bytes_per_sample']*8
assert x['rate']>0 and x['requested_rate']==x['rate']
assert x['chunk_bytes']==x['frames_per_chunk']*x['channels']*x['bytes_per_sample']
x['maximum_batch_frames']=maximum*x['frames_per_chunk'];x['maximum_batch_ms']=1000*x['maximum_batch_frames']/x['rate']
out=dict(guest_pid=A.pid,toc=toc,head=head,maximum_chunks=maximum,active_driver=x['address'],nodes=nodes,clock_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC),live_code_match=True,stable_format=True)
(R/(A.label+'.driver-contract.json')).write_text(json.dumps(out,indent=2));print(json.dumps(out))
