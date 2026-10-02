#!/usr/bin/env python3
"""Clear the bogus 'main' descriptor MakePEF writes into an NDRV.

MakePEF.cc always sets mainSection=1 / mainOffset=<XCOFF entry>.  An NDRV is
linked -nostartfiles, so there is no entry and the offset comes out 0xffffffff.
CFM rejects a fragment whose main is out of range, so the driver is installed
but never prepared and DoDriverIO is never reached.  Apple's own NDRVs ship
with mainSection = -1; this writes that.
"""
import struct, sys

def fix(path):
    d = bytearray(open(path, 'rb').read())
    if bytes(d[0:8]) != b'Joy!peff' or bytes(d[8:12]) != b'pwpc':
        sys.exit("%s: not a PowerPC PEF" % path)
    nsec = struct.unpack_from('>H', d, 32)[0]
    base = 40                      # container header is 40 bytes
    loader = None
    for i in range(nsec):
        off = base + i * 28
        kind = d[off + 24]
        if kind == 4:              # kPEFLoaderSection
            loader = struct.unpack_from(">I", d, off + 20)[0]
            break
    if loader is None:
        sys.exit("%s: no loader section" % path)
    main_sec, main_off = struct.unpack_from('>iI', d, loader)
    if main_sec == -1:
        print("%s: already clean" % path); return
    struct.pack_into('>iI', d, loader, -1, 0)
    open(path, 'wb').write(d)
    print("%s: mainSection %d -> -1, mainOffset 0x%08x -> 0" % (path, main_sec, main_off))

for p in sys.argv[1:]:
    fix(p)
