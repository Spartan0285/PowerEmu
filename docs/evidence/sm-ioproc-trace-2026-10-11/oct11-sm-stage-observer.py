#!/usr/bin/env python3
"""Stage / register / restore an owned QA run that CARRIES the SM observer.

oct11-stage-ownership.py deliberately stages an observer-free VM: it asserts
extraQEMUArgs is empty and that `-plugin` is absent.  This is its plugin-
bearing sibling.  It adds nothing to the guest, changes no audio setting, and
leaves the production app restored outside the owned test.

  stage    LABEL --sm-base 0x162ab000
  register LABEL
  restore  LABEL
"""
from pathlib import Path
import argparse,hashlib,json,plistlib,re,subprocess,sys,time

R=Path('/tmp/pe9800')
APP=Path('/Users/adam/Developer/PowerEmu/build/PowerEmu Depth Wait QA.app')
INFO=APP/'Contents/Info.plist'
CFG=Path('/tmp/pe9800/oct08-autonomous-support/Virtual Machines/Tiger Audio Test.poweremu/config.plist')
DYLIB=R/'oct10-sm-ioproc-plugin.dylib'
DYLIB_SHA='8edd085c3a5aedc1f7c5374b3b1fccbad29fbf1f50cfb351ff66d8c5929bbe68'
PLUGIN_SRC=R/'oct10-sm-ioproc-plugin.c'
SIGNER='Developer ID Application: Adam Cipoletti (7B2D3VV69V)'
ENTS='/Users/adam/Developer/PowerEmu/app/Resources/PowerEmu.entitlements'

p=argparse.ArgumentParser()
p.add_argument('mode',choices=['stage','register','restore'])
p.add_argument('label')
p.add_argument('--sm-base',help='anticipated SoundManagerComponents base, e.g. 0x162ab000')
a=p.parse_args()
assert re.fullmatch(r'oct1[01]-[a-z0-9-]+',a.label),'label must look like oct11-...'

stage=R/(a.label+'.sm-stage.json')
prefix=R/a.label
control=R/(a.label+'.control')
sites=R/(a.label+'.sites')

def rows():return subprocess.check_output(['ps','-ax','-o','pid,command'],text=True).splitlines()
def no_emulator():
    """Match the executable field, never the command line.

    `ps -o command=` returns whole command lines, so grepping them for the
    emulator path also matches this very process -- the shell and python
    invocations that carry the string in their own arguments.  A false
    positive here makes restore refuse and leaves the app staged and signed
    with extraQEMUArgs set, which is the one state not to leave behind.
    `comm` is the executable alone and cannot self-match.
    """
    comms=subprocess.check_output(['ps','-ax','-o','comm='],text=True).splitlines()
    live=[c for c in comms if c.rstrip().endswith(('/qemu-system-ppc','/qemu-system-ppc64'))]
    assert not live,f'an emulator is running; refuse: {live}'
def sign():
    subprocess.run(['codesign','--force','--sign',SIGNER,'--timestamp=none','--options','runtime',
                    '--entitlements',ENTS,str(APP)],check=True)
    subprocess.run(['codesign','--verify','--deep','--strict',str(APP)],check=True)

def no_app():
    """The app must not be running when config.plist is written.

    It holds the VM configuration in memory and only reads the file at
    launch, so staging under a running app silently produces a VM WITHOUT
    the plugin -- the file on disk is right and the command line is not.
    That cost a full boot to discover.
    """
    live=[l for l in rows() if 'Depth Wait QA.app/Contents/MacOS/' in l]
    assert not live,'the QA app is running; quit it so it re-reads config.plist'

if a.mode=='stage':
    no_emulator();no_app()
    assert not stage.exists(),'already staged; restore first'
    assert a.sm_base,'--sm-base is required: the plugin needs site hints at install'
    base=int(a.sm_base,16)
    assert base%4096==0,'module base must be page aligned'
    assert hashlib.sha256(DYLIB.read_bytes()).hexdigest()==DYLIB_SHA,'observer dylib changed'
    subprocess.run(['codesign','--verify','--strict',str(DYLIB)],check=True)

    # Two sites only: PRE entry and the true return.  The source hash comment
    # ties the file to the plugin it was written for.
    src_sha=hashlib.sha256(PLUGIN_SRC.read_bytes()).hexdigest()
    sites.write_text(f'# verified-source-sha256={src_sha}\n'
                     f'{base+0x5794:#x} 0x7c6802a6 0\n'
                     f'{base+0x57e4:#x} 0x4e800020 1\n')
    # Owner-only control, ready word zero; finalize publishes into it.
    control.write_bytes(bytes(368));control.chmod(0o600)
    for suff in ('.records','.config','.json','.flush.json'):
        Path(str(prefix)+suff).unlink(missing_ok=True)

    cfgd=plistlib.loads(CFG.read_bytes())
    prior=cfgd.get('extraQEMUArgs')
    assert not prior,f'extraQEMUArgs already set ({prior!r}); restore first'
    cfgd['extraQEMUArgs']=['-plugin',
        f'{DYLIB},enabled=1,sites={sites},out={prefix},control={control}']
    cfg_before=R/(a.label+'.config.plist.before');cfg_before.write_bytes(CFG.read_bytes())
    CFG.write_bytes(plistlib.dumps(cfgd))

    info_before=R/(a.label+'.Info.plist.before');info_before.write_bytes(INFO.read_bytes())
    pl=plistlib.loads(INFO.read_bytes())
    pl['LSEnvironment']={k:v for k,v in pl.get('LSEnvironment',{}).items() if k=='POWEREMU_EXPERIMENT_SUPPORT'}
    # Leave the two rejected experiments off, exactly as the observer-free path does.
    pl['LSEnvironment'].update(POWEREMU_AUDIO_KEEP_PACE_DEBT='0',
                               POWEREMU_SCREAMER_LIFECYCLE_FIX='0',
                               POWEREMU_SCREAMER_SLICE_PACING='0')
    INFO.write_bytes(plistlib.dumps(pl))

    stage.write_text(json.dumps(dict(
        label=a.label,info=str(INFO),info_before=str(info_before),
        cfg=str(CFG),cfg_before=str(cfg_before),
        staged_info_sha=hashlib.sha256(INFO.read_bytes()).hexdigest(),
        staged_cfg_sha=hashlib.sha256(CFG.read_bytes()).hexdigest(),
        sm_base=base,entry=base+0x5794,exit=base+0x57e4,
        sites=str(sites),control=str(control),prefix=str(prefix),
        plugin_source_sha256=src_sha,dylib_sha256=DYLIB_SHA,
        status='staged'),indent=2)+'\n')
    sign();subprocess.run(['open',str(APP)],check=True)
    print(json.dumps({'staged':True,'sm_base':hex(base),'entry':hex(base+0x5794),
                      'sites':str(sites),'control':str(control),
                      'note':'If the fresh SM mapping differs, restore and restage; never reuse addresses.'},indent=2))

elif a.mode=='register':
    s=json.loads(stage.read_text());assert s['status']=='staged'
    owned=[]
    for row in rows():
        m=re.match(r'\s*(\d+)\s+(.*)',row)
        if m and '/Contents/MacOS/qemu-system-ppc' in m[2] and 'Depth Wait QA.app' in m[2] and 'oct08-autonomous-support' in m[2]:
            owned.append((int(m[1]),m[2]))
    assert len(owned)==1,owned
    pid,cmd=owned[0]
    assert 'hostfwd=tcp:127.0.0.1:2319-:22' in cmd,'owned SSH forward absent'
    # The plugin MUST be present here -- that is the whole difference.
    assert str(DYLIB) in cmd and f'control={control}' in cmd,'owned VM is not carrying this observer'
    sock=re.search(r'-qmp unix:([^, ]+)',cmd).group(1)
    et=subprocess.check_output(['ps','-p',str(pid),'-o','etime='],text=True).strip()
    t=[int(x) for x in et.split(':')];age=sum(v*60**i for i,v in enumerate(reversed(t)))
    assert age<480,f'owned VM is already {age}s old; strict stop is 480s'
    g=dict(owned_pid=pid,owned_command=cmd,qmp=sock,
           deadline_ns=time.clock_gettime_ns(time.CLOCK_MONOTONIC)+(480-age)*10**9,
           strict_stop_seconds=480)
    gp=R/(a.label+'.produced-guard.json');gp.write_text(json.dumps(g))
    log=open(R/(a.label+'.produced-guard.log'),'ab',buffering=0)
    w=subprocess.Popen([sys.executable,str(R/'oct10-produced-owned.py'),'guard',str(gp)],
                       stdout=log,stderr=log,start_new_session=True)
    g['guard_pid']=w.pid;gp.write_text(json.dumps(g))
    meta=dict(pid=pid,qmp=sock,prefix=f'{a.label}.{pid}',status='running',
              keep_pace_debt=False,produced_guard=str(gp))
    (R/'oct08-depthwait-native-current.json').write_text(json.dumps(meta))
    print(json.dumps({**meta,'seconds_left':480-age},indent=2))

else:  # restore
    no_emulator()
    s=json.loads(stage.read_text())
    assert hashlib.sha256(INFO.read_bytes()).hexdigest()==s['staged_info_sha'],'Info.plist changed under us'
    assert hashlib.sha256(CFG.read_bytes()).hexdigest()==s['staged_cfg_sha'],'config.plist changed under us'
    INFO.write_bytes(Path(s['info_before']).read_bytes())
    CFG.write_bytes(Path(s['cfg_before']).read_bytes())
    assert not plistlib.loads(CFG.read_bytes()).get('extraQEMUArgs'),'extraQEMUArgs not cleared'
    sign()
    s['status']='restored';stage.write_text(json.dumps(s,indent=2)+'\n')
    print(json.dumps({'restored':True,'app':str(APP)},indent=2))
