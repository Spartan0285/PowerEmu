#!/usr/bin/env python3
"""
A/B the two R350 routes the previous session gated on live visual regressions.
Both were judged while the texture fetch had red/green exchanged and blue
replaced by alpha, so the judgement is worth repeating now that is fixed.

  gate-ab.py <on|off> <run-name> <port>
"""
import subprocess, pathlib, json, time, socket, os, sys

GATED, RUN, PORT = sys.argv[1], sys.argv[2], sys.argv[3]
ROOT = pathlib.Path('/Users/adam/Developer/PowerEmu-SMP/r350-probe-20260929')
OLD  = '/Users/adam/Developer/PowerEmu-SMP/vram-investigation-219'
args = json.loads(pathlib.Path(OLD + '/128-production/argv.json').read_text())
args = [x.replace(OLD + '/PowerEmu.app', str(ROOT / 'Probe.app'))
         .replace(OLD + '/128-production', str(ROOT / RUN))
         .replace('ppc-mac-gpu,id=gpu0',
                  'ppc-mac-r350-probe,id=gpu0,x-r350-bridge-aic=on,'
                  'x-r350-linear-render=on,x-r350-shader-snapshots=on,'
                  'x-r350-gated-routes=' + GATED)
         .replace('25465', PORT)
         .replace('VRAM diagnostic 128', 'gate ' + GATED) for x in args]
args[args.index('-smp') + 1] = '1'
args[args.index('-accel') + 1] = 'tcg,thread=single,tb-size=512'
d = ROOT / RUN; d.mkdir(exist_ok=True)
(d / 'argv.json').write_text(json.dumps(args, indent=2))
assert 'snapshot=on' in [a for a in args if a.startswith('if=none,id=d0')][0]

ssh = ['ssh','-p',PORT,'-i','/Users/adam/.ssh/poweremu_guest','-o','BatchMode=yes',
       '-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no',
       '-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR',
       '-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa',
       'adam@127.0.0.1']
log = open(d / 'backend.log', 'wb')
p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ))
log.close(); start = time.monotonic(); print('gated-routes=%s PID %d' % (GATED, p.pid), flush=True)
try:
    while p.poll() is None and time.monotonic() - start < 300:
        try:
            if subprocess.run(ssh + ['true'], stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT, timeout=10).returncode == 0:
                print('up after %ds' % round(time.monotonic()-start), flush=True); break
        except subprocess.TimeoutExpired: pass
        time.sleep(4)
    if p.poll() is not None: print('exited early', p.poll(), flush=True); sys.exit(1)
    time.sleep(60)
    s = socket.socket(socket.AF_UNIX); s.settimeout(60); s.connect(str(d / 'qmp'))
    f = s.makefile('rwb', buffering=0); f.readline()
    def call(n, a=None):
        q = {'execute': n}
        if a: q['arguments'] = a
        f.write((json.dumps(q)+'\n').encode())
        while True:
            v = json.loads(f.readline())
            if 'return' in v or 'error' in v: return v
    call('qmp_capabilities')
    call('screendump', {'filename': str(d / 'desktop.ppm')})
    r = call('qom-get', {'path': '/machine/peripheral/gpu0', 'property': 'perf'})
    (d / 'perf.txt').write_text(r.get('return', json.dumps(r)))
    print(r.get('return', '')[:2000], flush=True)
    f.close(); s.close()
    print('gate A/B complete', flush=True)
finally:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    print('stopped; snapshot discarded', flush=True)
