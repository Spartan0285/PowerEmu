#!/usr/bin/env python3
"""
Same-workload comparison of the Radeon 9200 and the R350 experiment, reading
the very counters PowerEmu's performance overlay reads: the GPU device's
"perf" property, sampled once a second, exactly as the overlay samples it.

  bench.py <9200|9800> <run-name> <port>
"""
import subprocess, pathlib, json, time, socket, os, sys, re

CARD, RUN, PORT = sys.argv[1], sys.argv[2], sys.argv[3]
ROOT = pathlib.Path('/Users/adam/Developer/PowerEmu-SMP/r350-probe-20260929')
OLD  = '/Users/adam/Developer/PowerEmu-SMP/vram-investigation-219'

args = json.loads(pathlib.Path(OLD + '/128-production/argv.json').read_text())
repl = ('ppc-mac-r350-probe,id=gpu0,x-r350-bridge-aic=on,x-r350-linear-render=on'
        if CARD == '9800' else 'ppc-mac-gpu,id=gpu0')
args = [x.replace(OLD + '/PowerEmu.app', str(ROOT / 'Probe.app'))
         .replace(OLD + '/128-production', str(ROOT / RUN))
         .replace('ppc-mac-gpu,id=gpu0', repl)
         .replace('25465', PORT)
         .replace('VRAM diagnostic 128', CARD + ' bench') for x in args]
if CARD == '9200':
    args[args.index('-L') + 1] = (OLD + '/PowerEmu.app/Contents/Helpers/'
                                  'PowerEmu VM.app/Contents/Resources/firmware')
args[args.index('-smp') + 1] = '1'
args[args.index('-accel') + 1] = 'tcg,thread=single,tb-size=512'

d = ROOT / RUN; d.mkdir(exist_ok=True)
(d / 'argv.json').write_text(json.dumps(args, indent=2))
drive = [a for a in args if a.startswith('if=none,id=d0')][0]
assert 'snapshot=on' in drive, drive

ssh = ['ssh','-p',PORT,'-i','/Users/adam/.ssh/poweremu_guest','-o','BatchMode=yes',
       '-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no',
       '-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR',
       '-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa',
       'adam@127.0.0.1']

log = open(d / 'backend.log', 'wb')
p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ))
log.close()
start = time.monotonic()
print('%s PID %d' % (CARD, p.pid), flush=True)

def guest(cmd, timeout=30):
    return subprocess.run(ssh + [cmd], stdout=subprocess.PIPE,
                          stderr=subprocess.STDOUT, timeout=timeout)

try:
    while p.poll() is None and time.monotonic() - start < 240:
        try:
            if guest('true', 10).returncode == 0:
                print('desktop up after %ds' % round(time.monotonic() - start), flush=True)
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(4)
    if p.poll() is not None:
        print('exited early', p.poll(), flush=True); sys.exit(1)

    time.sleep(40)                      # let the desktop finish composing

    s = socket.socket(socket.AF_UNIX); s.settimeout(60)
    s.connect(str(d / 'qmp')); f = s.makefile('rwb', buffering=0); f.readline()
    def call(name, arg=None):
        req = {'execute': name}
        if arg: req['arguments'] = arg
        f.write((json.dumps(req) + '\n').encode())
        while True:
            v = json.loads(f.readline())
            if 'return' in v or 'error' in v: return v
    call('qmp_capabilities')

    def perf():
        r = call('qom-get', {'path': '/machine/peripheral/gpu0', 'property': 'perf'})
        if 'error' in r: return None
        out = {}
        for kv in r['return'].split():
            k, _, val = kv.partition('=')
            try: out[k] = int(val)
            except ValueError: pass
        return out

    samples = []
    def sample(phase):
        v = perf()
        if v: v['t'] = time.monotonic(); v['phase'] = phase; samples.append(v)

    # Phase 1: an idle desktop -- the compositor's own traffic, nothing else.
    for _ in range(12):
        sample('idle'); time.sleep(1)

    # Phase 2: Chess.app, the OpenGL 3D application that ships with the OS.
    guest('open /Applications/Chess.app', 60)
    for _ in range(35):
        sample('chess'); time.sleep(1)
    call('screendump', {'filename': str(d / 'chess.ppm')})
    (d / 'guest.txt').write_bytes(
        guest('ps -axww | grep -E "[C]hess"; '
              'system_profiler SPDisplaysDataType | head -30', 60).stdout)

    (d / 'samples.json').write_text(json.dumps(samples, indent=2))

    # Report deltas across each phase, the way the overlay reports per-second rates.
    def phase_rate(name):
        pts = [x for x in samples if x['phase'] == name]
        if len(pts) < 2: return None
        a, b = pts[0], pts[-1]
        dt = b['t'] - a['t']
        out = {'seconds': round(dt, 1)}
        for k in ('frames', 'draws', 'tex_vram', 'tex_agp',
                  'r350_draws', 'r350_rejected'):
            if k not in b and k not in a:
                continue
            out[k + '/s'] = round((b.get(k, 0) - a.get(k, 0)) / dt, 1)
        out['agp_MB/s'] = round((b.get('agp_bytes', 0) - a.get('agp_bytes', 0)) / dt / 1048576, 2)
        if 'r350_draw_ns' in b:
            ns = b['r350_draw_ns'] - a.get('r350_draw_ns', 0)
            out['r350_metal_%_of_wall'] = round(100 * ns / 1e9 / dt, 1)
            n = b.get('r350_draws', 0) - a.get('r350_draws', 0)
            out['r350_ms_per_draw'] = round(ns / 1e6 / n, 2) if n else None
            for key, label in (('r350_target_bytes', 'r350_target_MB/s'),
                               ('r350_texture_bytes', 'r350_texture_MB/s')):
                out[label] = round((b.get(key, 0) - a.get(key, 0)) / dt / 1048576, 1)
        out['vram_high_MB'] = round(b.get('vram_high', 0) / 1048576, 1)
        # only the per-vCPU thread times; cpu_sample_ns is a clock, not CPU time
        cpu = [k for k in b if re.fullmatch(r'cpu\d+_ns', k)]
        if cpu:
            ns = sum(b[k] - a.get(k, 0) for k in cpu)
            out['guest_cpu_%_of_one_host_core'] = round(100 * ns / 1e9 / dt, 1)
        return out

    report = {'card': CARD, 'idle': phase_rate('idle'), 'chess': phase_rate('chess')}
    (d / 'report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2), flush=True)
    f.close(); s.close()
    print('bench complete', flush=True)
finally:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    print('stopped; snapshot discarded', flush=True)
