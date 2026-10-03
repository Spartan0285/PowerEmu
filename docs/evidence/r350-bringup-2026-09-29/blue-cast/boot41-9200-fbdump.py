import subprocess,pathlib,json,time,socket,os,sys

ROOT = pathlib.Path('/Users/adam/Developer/PowerEmu-SMP/r350-probe-20260929')
OLD  = '/Users/adam/Developer/PowerEmu-SMP/vram-investigation-219'
RUN  = 'boot41-9200-fbdump'
PORT = '25400'

args = json.loads(pathlib.Path(OLD + '/128-production/argv.json').read_text())
args = [x.replace(OLD + '/PowerEmu.app', str(ROOT / 'Probe.app'))
         .replace(OLD + '/128-production', str(ROOT / RUN))
         .replace('25465', PORT)
         .replace('VRAM diagnostic 128', '9200 control fbdump') for x in args]
args[args.index('-L') + 1] = (OLD +
    '/PowerEmu.app/Contents/Helpers/PowerEmu VM.app/Contents/Resources/firmware')
args[args.index('-smp') + 1] = '1'
args[args.index('-accel') + 1] = 'tcg,thread=single,tb-size=512'

d = ROOT / RUN
d.mkdir(exist_ok=True)
(d / 'argv.json').write_text(json.dumps(args, indent=2))

# the base disk is read-only and opened with snapshot=on; assert both
drive = [a for a in args if a.startswith('if=none,id=d0')][0]
assert 'snapshot=on' in drive, drive
print('drive:', drive, flush=True)

ssh = ['ssh','-p',PORT,'-i','/Users/adam/.ssh/poweremu_guest','-o','BatchMode=yes',
       '-o','ConnectTimeout=3','-o','StrictHostKeyChecking=no',
       '-o','UserKnownHostsFile=/dev/null','-o','LogLevel=ERROR',
       '-o','HostKeyAlgorithms=+ssh-rsa','-o','PubkeyAcceptedAlgorithms=+ssh-rsa',
       'adam@127.0.0.1']

log = open(d / 'backend.log', 'wb')
p = subprocess.Popen(args, stdout=log, stderr=subprocess.STDOUT, env=dict(os.environ))
log.close()
(d / 'pid').write_text(str(p.pid))
start = time.monotonic()
print('PID', p.pid, flush=True)

reached = False
try:
    while p.poll() is None and time.monotonic() - start < 180:
        try:
            r = subprocess.run(ssh + ['system_profiler SPDisplaysDataType; '
                                      'ps -axww | grep -E "[F]inder.app|[W]indowServer"'],
                               stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=12)
            if r.returncode == 0:
                (d / 'guest.txt').write_bytes(r.stdout)
                print('SSH reached after', round(time.monotonic() - start), 's', flush=True)
                reached = True
                # let the desktop settle so the compositor has painted
                time.sleep(45)
                # ground truth: the actual wallpaper file from inside the guest
                w = subprocess.run(ssh + ['cat "/Library/Desktop Pictures/Aurora.jpg" | '
                                          'openssl base64 -A'],
                                   stdout=subprocess.PIPE, timeout=120)
                if w.returncode == 0 and len(w.stdout) > 1000:
                    import base64
                    (d / 'Aurora.jpg').write_bytes(base64.b64decode(w.stdout))
                    print('pulled wallpaper', (d / 'Aurora.jpg').stat().st_size, flush=True)
                else:
                    print('wallpaper pull failed rc=%s len=%d' % (w.returncode, len(w.stdout)),
                          flush=True)
                break
        except subprocess.TimeoutExpired:
            pass
        time.sleep(4)

    if p.poll() is not None:
        print('emulator exited early:', p.poll(), flush=True)
        sys.exit(1)

    s = socket.socket(socket.AF_UNIX); s.settimeout(30)
    s.connect(str(d / 'qmp'))
    f = s.makefile('rwb', buffering=0); f.readline()

    def call(name, arg=None):
        req = {'execute': name}
        if arg: req['arguments'] = arg
        f.write((json.dumps(req) + '\n').encode())
        while True:
            val = json.loads(f.readline())
            if 'return' in val or 'error' in val:
                return val

    def hmp(cmd):
        return call('human-monitor-command', {'command-line': cmd}).get('return', '')

    call('qmp_capabilities')

    state = {'info pci': hmp('info pci'), 'info qtree': hmp('info qtree')}

    MMIO = 0x90000000
    regs = {
        'CRTC_GEN_CNTL':    0x0050,
        'CRTC_EXT_CNTL':    0x0054,
        'DAC_CNTL':         0x0058,
        'CRTC_H_TOTAL_DISP':0x0200,
        'CRTC_V_TOTAL_DISP':0x0208,
        'CRTC_OFFSET':      0x0224,
        'CRTC_OFFSET_CNTL': 0x0228,
        'CRTC_PITCH':       0x022c,
        'SURFACE_CNTL':     0x0b00,
        'SURFACE0_INFO':    0x0b0c,
        'SURFACE0_LOWER':   0x0b04,
        'SURFACE0_UPPER':   0x0b08,
        'RB3D_COLOROFFSET0':0x4e28,
        'RB3D_COLORPITCH0': 0x4e38,
    }
    reg_out = {}
    for name, off in regs.items():
        reg_out[name] = hmp('xp /1xw 0x%08x' % (MMIO + off)).strip()
    state['regs'] = reg_out
    print(json.dumps(reg_out, indent=2), flush=True)

    call('screendump', {'filename': str(d / 'screen.ppm')})

    # scanout base: BAR0 + CRTC_OFFSET.  Parse the offset out of the xp output.
    def word(txt):
        try:
            return int(txt.split(':')[-1].strip(), 16)
        except Exception:
            return None

    crtc_offset = word(reg_out['CRTC_OFFSET']) or 0
    BAR0 = 0x88000000
    STRIDE = 1680 * 4       # 9200 control: plain CRTC pitch, no override
    HEIGHT = 1050
    size = STRIDE * HEIGHT
    base = BAR0 + crtc_offset
    print('crtc_offset=0x%x base=0x%x size=%d' % (crtc_offset, base, size), flush=True)
    state['pmemsave'] = hmp('pmemsave 0x%x 0x%x "%s"' % (base, size, d / 'fb.bin'))

    # second dump a beat later, to show the buffer is stable and not mid-flip
    time.sleep(3)
    state['pmemsave2'] = hmp('pmemsave 0x%x 0x%x "%s"' % (base, size, d / 'fb2.bin'))
    call('screendump', {'filename': str(d / 'screen2.ppm')})

    (d / 'state.json').write_text(json.dumps(state, indent=2))
    f.close(); s.close()
    print('measurement complete', flush=True)
finally:
    if p.poll() is None:
        p.terminate()
        try: p.wait(timeout=15)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    print('probe stopped; snapshot discarded', flush=True)
