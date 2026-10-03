#!/usr/bin/env python3
"""
pedisplay-capture.py -- a stand-in for the PowerEmu app on the
`poweremu-display` unix socket, for headless screen capture.

QEMU's `-object poweremu-display,id=pd0,path=SOCK` *connects* to SOCK at
startup (and exits if nobody is listening), so this must be started first.
It then speaks the protocol documented at the top of
poweremu-qemu/ui/poweremu-display.c:

    QEMU -> client
      1 SURFACE  u32 width, height, stride   (+ shm fd via SCM_RIGHTS)
      2 DAMAGE   u32 x, y, w, h
      3 CURSOR   u32 w, h, hot_x, hot_y, then w*h BGRA
      4 MOUSE    i32 x, y, u32 visible

Registering a DisplayChangeListener is the point: the GPU model is then
driven at ~30 Hz and composites into the shared frame, which this tool
writes out as PNG.  The pixels handed over are premultiplied BGRA.

Usage:
    pedisplay-capture.py SOCK --out DIR [--interval S] [--count N]
                              [--duration S] [--quiet]

  --interval S   write a snapshot every S seconds (default 5)
  --count N      stop after N snapshots (default: run until killed)
  --duration S   stop after S seconds
  SIGUSR1        write a snapshot immediately

Writes DIR/frame-NNNN.png and DIR/latest.png, and prints one line per
snapshot: index, path, size, md5, and the running message counters.
"""
import argparse, hashlib, mmap, os, signal, socket, struct, sys, time, zlib
import queue, threading

PE_SURFACE, PE_DAMAGE, PE_CURSOR, PE_MOUSE = 1, 2, 3, 4


def write_png(path, width, height, stride, buf):
    """BGRA (premultiplied, alpha ignored) -> 8-bit RGB PNG."""
    raw = bytearray()
    for y in range(height):
        row = buf[y * stride: y * stride + width * 4]
        px = bytearray(width * 3)
        px[0::3] = row[2::4]        # R
        px[1::3] = row[1::4]        # G
        px[2::3] = row[0::4]        # B
        raw.append(0)               # PNG filter type 0 for this scanline
        raw += px

    def chunk(tag, data):
        return (struct.pack('>I', len(data)) + tag + data
                + struct.pack('>I', zlib.crc32(tag + data) & 0xffffffff))

    ihdr = struct.pack('>IIBBBBB', width, height, 8, 2, 0, 0, 0)
    png = (b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', ihdr)
           + chunk(b'IDAT', zlib.compress(bytes(raw), 6))
           + chunk(b'IEND', b''))
    tmp = path + '.part'
    with open(tmp, 'wb') as f:
        f.write(png)
    os.replace(tmp, path)
    return len(png), hashlib.md5(png).hexdigest()


class Capture:
    def __init__(self, outdir):
        self._q = queue.Queue()
        threading.Thread(target=self._writer, daemon=True).start()
        self.outdir = outdir
        self.shm = None
        self.w = self.h = self.stride = 0
        self.n_surface = self.n_damage = self.n_cursor = self.n_mouse = 0
        self.last_damage = None
        self.index = 0

    def surface(self, fd, w, h, stride):
        if self.shm:
            self.shm.close()
            self.shm = None
        length = stride * h
        try:
            self.shm = mmap.mmap(fd, length, flags=mmap.MAP_SHARED,
                                 prot=mmap.PROT_READ)
        except Exception as e:
            print('mmap failed: %s' % e, file=sys.stderr, flush=True)
            self.shm = None
        os.close(fd)
        self.w, self.h, self.stride = w, h, stride
        self.n_surface += 1
        print('SURFACE %dx%d stride=%d (announce #%d)'
              % (w, h, stride, self.n_surface), flush=True)

    def _writer(self):
        """Encode and write queued frames, off the receive path."""
        while True:
            job = self._q.get()
            if job is None:
                return
            self._write_one(*job)

    def snapshot(self):
        """Copy the frame and hand it to the writer thread.

        This must not encode inline.  QEMU's pe_send() is a blocking
        write-all, so every millisecond spent here not draining the socket
        is a millisecond QEMU's main loop is blocked -- and a pure-Python
        PNG encode of a 1680x1050 frame is far more than a millisecond.
        Encoding inline stalled the VM hard enough to wedge Tiger's login
        session permanently: WindowServer and Dock would start, Finder
        never would, and draws froze at about 200.  The copy below is a
        memcpy; everything after it happens on the thread.
        """
        if not self.shm or not self.w:
            print('snapshot: no surface yet', flush=True)
            return None
        self.index += 1
        buf = bytes(self.shm[0:self.stride * self.h])
        path = os.path.join(self.outdir, 'frame-%04d.png' % self.index)
        self._q.put((path, buf, self.index, self.w, self.h, self.stride,
                     self.n_surface, self.n_damage, self.n_cursor,
                     self.n_mouse, self.last_damage))
        return path

    def _write_one(self, path, buf, index, w, h, stride,
                   n_surface, n_damage, n_cursor, n_mouse, last_damage):
        size, md5 = write_png(path, w, h, stride, buf)
        # a cheap content fingerprint of the raw pixels too, so two
        # byte-identical frames are obvious even if PNG encoding differs
        rawmd5 = hashlib.md5(buf).hexdigest()
        latest = os.path.join(self.outdir, 'latest.png')
        try:
            with open(path, 'rb') as a, open(latest + '.part', 'wb') as b:
                b.write(a.read())
            os.replace(latest + '.part', latest)
        except OSError:
            pass
        print('SNAP %d %s %dx%d bytes=%d png_md5=%s raw_md5=%s '
              'surfaces=%d damage=%d cursor=%d mouse=%d last_damage=%s'
              % (index, path, w, h, size, md5, rawmd5,
                 n_surface, n_damage, n_cursor, n_mouse,
                 last_damage), flush=True)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('sock')
    ap.add_argument('--out', required=True)
    ap.add_argument('--interval', type=float, default=5.0)
    ap.add_argument('--count', type=int, default=0)
    ap.add_argument('--duration', type=float, default=0)
    args = ap.parse_args()

    os.makedirs(args.out, exist_ok=True)
    try:
        os.unlink(args.sock)
    except OSError:
        pass

    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(args.sock)
    srv.listen(1)
    print('listening on %s' % args.sock, flush=True)

    conn, _ = srv.accept()
    srv.close()
    print('QEMU connected', flush=True)

    cap = Capture(args.out)
    # The handler only raises a flag: snapshotting from inside it could
    # interrupt a snapshot already in progress and reuse its number.
    want = {'snap': False}
    signal.signal(signal.SIGUSR1, lambda *a: want.__setitem__('snap', True))

    buf = bytearray()
    fds = []
    started = time.time()
    next_snap = started + args.interval
    conn.settimeout(0.25)

    while True:
        now = time.time()
        if args.duration and now - started >= args.duration:
            break
        if want['snap'] or (args.interval and now >= next_snap):
            if args.interval:
                next_snap = now + args.interval
            want['snap'] = False
            cap.snapshot()
            if args.count and cap.index >= args.count:
                break
        try:
            data, got, _flags, _addr = socket.recv_fds(conn, 1 << 16, 4)
        except socket.timeout:
            continue
        except InterruptedError:
            continue
        except OSError as e:
            print('recv: %s' % e, flush=True)
            break
        fds.extend(got)
        if not data:
            print('QEMU closed the connection', flush=True)
            break
        buf += data
        while len(buf) >= 8:
            mtype, mlen = struct.unpack_from('<II', buf, 0)
            if len(buf) < 8 + mlen:
                break
            payload = bytes(buf[8:8 + mlen])
            del buf[:8 + mlen]
            if mtype == PE_SURFACE and mlen >= 12 and fds:
                w, h, stride = struct.unpack_from('<III', payload, 0)
                cap.surface(fds.pop(0), w, h, stride)
            elif mtype == PE_DAMAGE and mlen >= 16:
                cap.n_damage += 1
                cap.last_damage = struct.unpack_from('<IIII', payload, 0)
            elif mtype == PE_CURSOR:
                cap.n_cursor += 1
            elif mtype == PE_MOUSE:
                cap.n_mouse += 1

    print('done: surfaces=%d damage=%d cursor=%d mouse=%d snaps=%d'
          % (cap.n_surface, cap.n_damage, cap.n_cursor, cap.n_mouse,
             cap.index), flush=True)


if __name__ == '__main__':
    main()
