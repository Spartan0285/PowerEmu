#!/usr/bin/env python3
"""
Recover the GLD dispatch-table layout from Apple's driver.

gldInitDispatch(ctx, table, out) does not describe itself: it loads function
pointers out of __data and stores them into the table at fixed offsets.  The
offsets are the ABI -- get one wrong and GLEngine calls the wrong function
with the wrong arguments, which crashes rather than warns.  Reading them out
of the binary is the only way to know them, and doing it by eye across a
hundred instructions is how a transcription error gets in.

So: simulate the handful of PowerPC instructions involved (the PIC base from
the bcl trick, addis/lwz pairs that form a data address, and stores to the
table register) and print slot -> target.

Usage: dispatch-map.py <binary> <disassembly> <nm output> [func]
where the disassembly is `otool -tV -p _gldInitDispatch <binary>`.

Copyright (c) 2026 Spartan0285
SPDX-License-Identifier: GPL-2.0-or-later
"""

import re
import struct
import sys


def macho_sections(path):
    """[(vmaddr, size, fileoff)] for a 32-bit big-endian PPC Mach-O."""
    data = open(path, 'rb').read()
    magic, = struct.unpack_from('>I', data, 0)
    if magic != 0xFEEDFACE:
        raise SystemExit('not a 32-bit big-endian Mach-O: %08x' % magic)
    ncmds, = struct.unpack_from('>I', data, 16)
    off, secs = 28, []
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack_from('>II', data, off)
        if cmd == 0x1:                                  # LC_SEGMENT
            nsects, = struct.unpack_from('>I', data, off + 48)
            s = off + 56
            for _ in range(nsects):
                vmaddr, size, fileoff = struct.unpack_from('>III', data, s + 32)
                secs.append((vmaddr, size, fileoff))
                s += 68
        off += cmdsize
    return data, secs


def read32(data, secs, addr):
    for vmaddr, size, fileoff in secs:
        if vmaddr <= addr < vmaddr + size:
            o = fileoff + (addr - vmaddr)
            return struct.unpack_from('>I', data, o)[0]
    return None


def load_symbols(path):
    syms = []
    for line in open(path):
        f = line.split()
        if len(f) >= 3 and re.fullmatch(r'[0-9a-f]{8}', f[0]):
            syms.append((int(f[0], 16), f[2]))
    syms.sort()
    return syms


def nearest(syms, addr):
    """Name + offset of the symbol containing addr, when there is one."""
    best = None
    for a, n in syms:
        if a <= addr:
            best = (a, n)
        else:
            break
    if not best:
        return None
    a, n = best
    return n if a == addr else '%s+0x%x' % (n, addr - a)


def signed16(v):
    return v - 0x10000 if v & 0x8000 else v


def analyse(binary, dis_path, nm_path, func=None):
    data, secs = macho_sections(binary)
    syms = load_symbols(nm_path)

    lines = open(dis_path).read().splitlines()
    # Split the dump into functions, so one run can report each separately.
    funcs, cur = {}, None
    for line in lines:
        m = re.match(r'^(_\w+):', line)
        if m:
            cur = m.group(1)
            funcs[cur] = []
        elif cur and re.match(r'^[0-9a-f]{8}\t', line):
            funcs[cur].append(line)

    names = [func] if func else list(funcs)
    for name in names:
        body = funcs.get(name)
        if not body:
            print('%s: not in the disassembly' % name)
            continue

        regs = {}            # register -> known integer value
        srcs = {}            # register -> where its value came from
        table_regs = {'r4'}  # the table argument, plus whatever it is copied to
        pic = None
        slots = {}

        for line in body:
            addr = int(line.split('\t')[0], 16)
            rest = line.split('\t', 1)[1]
            op = rest.split('\t')[0].strip()
            args = rest.split('\t')[1].strip() if '\t' in rest else ''
            a = [x.strip() for x in args.split(',')]

            # The PIC base: `bcl 20,31,$+4` then `mfspr rN,lr`.
            if op == 'bcl':
                pic = addr + 4
                continue
            if op == 'mfspr' and len(a) > 1 and a[1] == 'lr' and pic:
                regs[a[0]] = pic
                continue

            # `or rX,rY,rY` is the PowerPC register move.
            if op == 'or' and len(a) == 3 and a[1] == a[2]:
                if a[1] in table_regs:
                    table_regs.add(a[0])
                if a[1] in regs:
                    regs[a[0]] = regs[a[1]]
                else:
                    regs.pop(a[0], None)
                continue

            if op == 'addis' and len(a) == 3:
                base = regs.get(a[1])
                if base is not None:
                    regs[a[0]] = (base + (int(a[2], 16) << 16)) & 0xFFFFFFFF
                else:
                    regs.pop(a[0], None)
                continue

            if op == 'addi' and len(a) == 3:
                base = regs.get(a[1])
                if base is not None:
                    regs[a[0]] = (base + signed16(int(a[2], 16))) & 0xFFFFFFFF
                else:
                    regs.pop(a[0], None)
                continue

            if op == 'lwz' and len(a) == 2:
                m = re.match(r'(0x[0-9a-f]+)\((\w+)\)', a[1])
                if not m:
                    regs.pop(a[0], None)
                    continue
                disp, rb = signed16(int(m.group(1), 16)), m.group(2)
                base = regs.get(rb)
                if base is None:
                    regs.pop(a[0], None)
                    srcs[a[0]] = ('ctx+0x%x' % disp) if rb in ('r3',) else None
                    continue
                at = (base + disp) & 0xFFFFFFFF
                val = read32(data, secs, at)
                if val is None:
                    regs.pop(a[0], None)
                else:
                    regs[a[0]] = val
                    srcs[a[0]] = 'data 0x%06x' % at
                continue

            if op == 'stw' and len(a) == 2:
                m = re.match(r'(0x[0-9a-f]+)\((\w+)\)', a[1])
                if not m:
                    continue
                disp, rb = signed16(int(m.group(1), 16)), m.group(2)
                if rb not in table_regs:
                    continue
                val = regs.get(a[0])
                if val is None:
                    slots[disp] = ('<%s>' % (srcs.get(a[0]) or a[0]), None)
                else:
                    slots[disp] = ('0x%08x' % val, nearest(syms, val))
                continue

        print('\n%s: %d table slots' % (name, len(slots)))
        print('  slot   index  target      symbol')
        for off in sorted(slots):
            val, sym = slots[off]
            print('  +0x%02x  [%2d]   %-11s %s'
                  % (off, off // 4, val, sym or ''))


if __name__ == '__main__':
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    analyse(sys.argv[1], sys.argv[2], sys.argv[3],
            sys.argv[4] if len(sys.argv) > 4 else None)
