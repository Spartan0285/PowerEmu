"""Explicit staging/restore only. Does not launch a VM or replace backend."""
from pathlib import Path
import argparse,subprocess,plistlib,json,hashlib
R=Path('/tmp/pe9800');app=Path('/Users/adam/Developer/PowerEmu/build/PowerEmu Depth Wait QA.app');cfg=R/'oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/config.plist'
p=argparse.ArgumentParser();p.add_argument('mode',choices=['stage','restore']);p.add_argument('label');p.add_argument('--delay',type=int,default=390);a=p.parse_args();assert a.label.startswith('oct10-') and all(c.isalnum() or c in '-_' for c in a.label);assert 0<=a.delay<=410
if subprocess.run(['pgrep','-fl','qemu-system'],capture_output=True).returncode==0:raise SystemExit('Active emulator; no staging')
receipt=R/(a.label+'.produced-stage.json');info=app/'Contents/Info.plist';backend=app/'Contents/Helpers/PowerEmu VM.app/Contents/MacOS/qemu-system-ppc';sha=lambda f:hashlib.sha256(f.read_bytes()).hexdigest()
if a.mode=='stage':
 assert not receipt.exists(),'Fresh label required';cp=R/(a.label+'.produced.control');subprocess.run(['python3',str(R/'oct10-produced-control.py'),'create',str(cp)],check=True)
 plugin=R/'oct10-miles-produced-plugin.dylib';subprocess.run(['codesign','--verify','--strict',str(plugin)],check=True)
 # Tentative trusted-code addresses only. Runtime fullcode/TVector/actual-PC validation must match before publication.
 mf=R/(a.label+'.produced.manifest.txt');mf.write_bytes((R/'oct10-miles-boundary-only.manifest.txt').read_bytes());assert len([x for x in mf.read_text().splitlines() if not x.startswith('#')])==4
 ib=R/(a.label+'.Info.plist.before');cb=R/(a.label+'.config.plist.before');ib.write_bytes(info.read_bytes());cb.write_bytes(cfg.read_bytes());d=plistlib.loads(info.read_bytes());c=plistlib.loads(cfg.read_bytes());assert not c.get('extraQEMUArgs',[]),'Existing extraargs require explicit reconciliation'
 env=d.setdefault('LSEnvironment',{});env['POWEREMU_COREAUDIO_CAPTURE']=str(R/a.label);env['POWEREMU_COREAUDIO_CAPTURE_SECONDS']='600';env['POWEREMU_SCREAMER_PCM_CAPTURE']=str(R/a.label);env['POWEREMU_AUDIO_TIMING']='0'
 for k in ['POWEREMU_SCREAMER_TRACE','POWEREMU_SCREAMER_IRQ_TRACE','POWEREMU_SCREAMER_SLOT_CAPTURE','POWEREMU_SCREAMER_SLOT_LEARN_RING','POWEREMU_AUDIO_IRQ_TIMING','POWEREMU_DMA_FLIGHT']:env.pop(k,None)
 env['POWEREMU_AUDIO_KEEP_PACE_DEBT']='0';env['POWEREMU_SCREAMER_LIFECYCLE_FIX']='0';env['POWEREMU_SCREAMER_SLICE_PACING']='0'
 out=R/(a.label+'.produced');arg=f'{plugin},enabled=1,produced-chunks=1,control={cp},sites={mf},out={out},arm-after-sec={a.delay},window-sec=60';c['extraQEMUArgs']=['-plugin',arg]
 info.write_bytes(plistlib.dumps(d));cfg.write_bytes(plistlib.dumps(c));r=dict(label=a.label,app=str(app),config=str(cfg),control=str(cp),manifest=str(mf),output=str(out),delay=a.delay,window=60,strict_stop=480,backend_sha256=sha(backend),plugin_sha256=sha(plugin),before_info=str(ib),before_config=str(cb),staged_config_sha256=sha(cfg),staged_info_sha256=sha(info),status='staged-not-launched');receipt.write_text(json.dumps(r,indent=2)+'\n')
else:
 r=json.loads(receipt.read_text());assert sha(cfg)==r['staged_config_sha256'],'Config changed; refuse overwrite';assert sha(info)==r['staged_info_sha256'],'Info changed; refuse overwrite';assert sha(backend)==r['backend_sha256'],'Backend changed; refuse restore';info.write_bytes(Path(r['before_info']).read_bytes());cfg.write_bytes(Path(r['before_config']).read_bytes());r['status']='restored';receipt.write_text(json.dumps(r,indent=2)+'\n')
subprocess.run(['codesign','--force','--sign','Developer ID Application: Adam Cipoletti (7B2D3VV69V)','--timestamp=none','--options','runtime','--entitlements','/Users/adam/Developer/PowerEmu/app/Resources/PowerEmu.entitlements',str(app)],check=True)
subprocess.run(['codesign','--verify','--deep','--strict',str(app)],check=True)
assert sha(backend)==r['backend_sha256'],'Stager must not replace backend';print(receipt)
