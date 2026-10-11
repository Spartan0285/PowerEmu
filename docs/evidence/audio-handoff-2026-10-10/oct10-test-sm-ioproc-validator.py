import importlib.util,json,struct,copy
from pathlib import Path
R=Path('/tmp/pe9800');s=importlib.util.spec_from_file_location('v',R/'oct10-validate-sm-ioproc.py');v=importlib.util.module_from_spec(s);s.loader.exec_module(v);p=R/'oct10-sm-validator-fixture';vals=[0x534d5031,1,0x10000,0x10004,0x7c6802a6,0x4e800020,258,0x230000,0x230100,0x230200,0x230300,0x220000,0x220000,0x221000,1,1000000000,24949183,3,60,0x10008,0,0x570000,1,2,3,4];cfg=v.C.pack(*vals,123,0x20f000,0x211000,*([0]*62));ns=5_000_000_000
m={'schema':1,'record_bytes':320,'latched':True,'records':1,'capacity':8192,'publication_observed_ns':1_000_000_000,'arm_start_ns':4_000_000_000,'arm_end_ns':64_000_000_000,'cpu':[{'id':0,'supported':True,'register_errors':0},{'id':1,'supported':True,'register_errors':0}]}
for k in ['config_errors','guard_errors','word_errors','read_errors','bounds_errors','torn_reads','context_skips','object_errors','drops','pair_errors','unmatched_exits','unfinished']:m[k]=0
now=bytearray(64);out=bytearray(64);struct.pack_into('>dQd',now,0,123,456,1);struct.pack_into('>II',now,56,7,0);struct.pack_into('>dQd',out,0,635,756,1);struct.pack_into('>II',out,56,7,0);abl=struct.pack('>4I',1,2,2048,0x240000)+bytes(84);rec=v.H.pack(ns,ns+1000,ns+2000,0x210000,0x10008,0,258,0x230000,0x20ff00,0x20ff80,0x220000,0,1,1)+now+out+abl+bytes(12);assert len(rec)==320
checks=[]
def test(name,raw=rec,meta=m,control=cfg,want=True):
 Path(str(p)+'.records').write_bytes(raw);Path(str(p)+'.config').write_bytes(control);Path(str(p)+'.json').write_text(json.dumps(meta));Path(str(p)+'.flush.json').write_text('{"all_outputs_ok":true}');r=v.validate(str(p),fixture=True);assert r['valid']==want,(name,r['failures']);checks.append({'name':name,'passed':True})
test('complete cross CPU pair')
for name,off,fmt,value in [('badLR',32,'<Q',0),('badserial',40,'<Q',1),('outsideNOWspan',56,'<I',0x210fe0),('wrongHW',52,'<I',0x230004),('unknownflags',136,'>I',0x27),('missinghostvalidity',136,'>I',1),('sampleNaN',80,'>d',float('nan')),('ratescalarNaN',96,'>d',float('nan')),('ABLcount9',208,'>I',9),('nonzeroreserved',308,'B',1)]:
 b=bytearray(rec);struct.pack_into(fmt,b,off,value);test(name,bytes(b),want=False)
b=bytearray(rec);struct.pack_into('>I',b,136,3);struct.pack_into('>d',b,96,float('nan'));test('invalidrateflag leaves rawunusedNaN unscored',bytes(b))
b=bytearray(rec);struct.pack_into('>I',b,136,2);struct.pack_into('>d',b,80,float('nan'));test('NOW hostvalid only sample ignored',bytes(b))
test('partialrecord',rec[:-1],want=False)
b=copy.deepcopy(m);b['drops']=1;test('overflowreject',meta=b,want=False)
b=copy.deepcopy(m);b['unfinished']=1;test('unfinishedreject',meta=b,want=False)
b=copy.deepcopy(m);b['arm_end_ns']=ns+1000;test('exitoutsideepoch',meta=b,want=False)
b=copy.deepcopy(m);b['object_errors']=1;test('objectidentityreject',meta=b,want=False)
b=copy.deepcopy(m);del b['object_errors'];test('missingobjectgate rejects',meta=b,want=False)
test('clean restored')
assert not v.validate(str(p),fixture=False)['valid'];checks.append({'name':'actual requires freshpublication','passed':True});o={'fixtures':len(checks),'passed':True,'checks':checks};(R/'oct10-sm-validator-fixtures.json').write_text(json.dumps(o,indent=2)+'\n');print(json.dumps(o))
