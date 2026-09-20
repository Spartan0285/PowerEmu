# A paravirtual GPU for the Tiger guest

Status: **design, not started.** Written 2026-09-20 after auditing where the
frame time actually goes and after looking at how ClassicMac's GXMetal does
the same thing for Mac OS 9.

## Why consider it

The emulated R200 is faithful: the guest's own ATI driver builds real PM4
command streams and pokes real registers, and we decode them. That fidelity
costs, and the costs land in places a profile does not attribute to "the
GPU":

- **Guest CPU.** Apple's ATI driver is emulated instruction by instruction:
  building command buffers, managing GART mappings, converting textures.
  Measured 2026-09-19: only ~19% of the emulator's time runs *any* guest
  code, and a large part of that is the driver rather than the game.
- **Trapping register access.** Every guest write to a GPU register leaves
  translated code through the software-MMU slow path and takes the big QEMU
  lock. See "Sizing the prize" -- this is the number that decides the whole
  question.
- **Our own decode.** ~3.7% of busy time in the device model plus ~3.0%
  encoding Metal, per the same profile.

A paravirtual device replaces all three with: guest driver writes commands
into shared memory, rings a doorbell once per batch, host executes them in
Metal.

## Sizing the prize first

`PPCGPU_TRAFFIC=1` makes the device print, once a second:

    [TRAFFIC] N mmio-writes/s N mmio-reads/s N ring-dwords/s N type0-regs/s N draws/s

- **mmio-writes / mmio-reads** are guest traps -- each one a slow-path exit
  plus the BQL. These are what paravirtualisation deletes.
- **type0-regs** are register writes replayed out of the PM4 ring. They
  reach the same handler but cost nothing extra: the guest wrote them into
  ordinary memory. Do not count these as a win.
- **ring-dwords** is how much command data already flows through memory
  rather than traps.

If mmio-writes/s is small next to ring-dwords/s, most of the command stream
is already taking the cheap path, and paravirtualisation buys far less than
it appears to. **Measure before committing weeks.**

## What it would look like

Three pieces, in the order they have to exist:

### 1. The transport (QEMU side, host)

A PCI device with a BAR of shared memory holding a ring of command packets,
a doorbell register, and a fence word the guest can poll. The host validates
packet metadata (never trusting guest offsets) and executes batches on the
existing Metal renderer, which already knows how to draw R200-shaped work.

This half can be built and tested without any guest driver, by driving the
ring from a unit test.

### 2. The guest OpenGL renderer (guest, userspace)

On Tiger, OpenGL loads a renderer bundle that pairs with an IOKit
accelerator. This is where the geometry and texture state can be captured
whole, rather than reconstructed from register writes. Quartz Extreme
composites through OpenGL, so this also accelerates the desktop.

**Buildable here.** The `ppcbuild` Lima VM has a `powerpc-apple-darwin9`
GCC 6.5 cross toolchain and both the 10.4u and 10.5 SDKs. Userspace PPC
binaries link correctly against the **10.5** SDK with
`-mmacosx-version-min=10.4`:

    /opt/ppc/bin/powerpc-apple-darwin9-gcc \
        -isysroot /opt/ppc/SDKs/MacOSX10.5.sdk -mmacosx-version-min=10.4 \
        -Wl,-syslibroot,/opt/ppc/SDKs/MacOSX10.5.sdk -o out in.c

The 10.4u SDK's `crt1.o` is too old for this ld64 and fails to link.

### 3. The accelerator kext (guest, kernel)

Needed for OpenGL to bind a hardware renderer at all, and to map the shared
ring into the guest.

**Not buildable in the cross VM.** GCC 6.5 cannot compile Apple's 10.4
kernel headers (`IOService.h` fails), and 10.4 kexts need Apple's gcc 4.0/4.2
C++ ABI to load. This piece has to be built on the G4 with Xcode 2.5, the
way `guest/scripts/build.sh` already builds the Tools apps. Installing it
needs admin in the guest, which is the user's to do.

## Honest risks

- **The interfaces are undocumented.** ClassicMac had it easier: Mac OS 9's
  RAVE is a published plug-in point with a documented engine contract. Tiger's
  OpenGL renderer plugin and IOAccelerator family are not.
- **It does not make the CPU faster.** ~42% of our time is address
  translation and block lookup. Paravirtualisation does not touch that, and
  it is the larger share.
- **Fidelity is lost.** The emulated R200 is what makes the *guest's own*
  ATI driver work, including Quartz Extreme's gating on a recognised card.
  A paravirtual path has to keep the emulated card present for anything that
  does not go through the new driver.

## Recommended order

1. Run `PPCGPU_TRAFFIC=1` during a match. Read the mmio vs ring split.
2. Only if guest traps are a large share: build the transport and drive it
   from a test.
3. Then the userspace renderer, cross-built here.
4. Then the kext, on the G4.

Stop after step 1 if the numbers do not justify steps 2-4.

---

# Measured 2026-09-20: the prize is much smaller than assumed

`PPCGPU_TRAFFIC=1` during Warcraft III gameplay, on the Mac Studio:

    [TRAFFIC] 4050 mmio-writes/s 715 mmio-reads/s 0 ring-dwords/s
              1008252 type0-regs/s 6585 draws/s

**Over 99.5% of the guest's GPU register traffic never traps.** Apple's ATI
driver batches almost everything into PM4 command buffers in ordinary
memory; only ~4,700 accesses a second are real trapping MMIO out of ~4.7
million register operations a second.

This kills the main argument for paravirtualisation as *I* framed it. The
claim was that every register write leaves translated code through the
software MMU and takes the BQL, so a shared-memory ring would delete a large
hidden cost. That cost is not there. What paravirtualisation would still
remove is our own decode (~3.7% device model, ~3.0% Metal encode) and some
of the guest driver's own work -- real, but a fraction of what was pitched,
and none of it touches the ~42% of emulator time spent on address
translation and block lookup for guest code in general.

**What the number redirects attention to:** those million type-0 register
writes a second are ours to make cheaper without any guest driver. Each one
currently goes through the full MMIO write switch, including a ~200-case
`ppc_mac_gpu_reg_name()` lookup evaluated twice per access for loggers that
are disabled. A fast path for the 3D shadow range is a contained change with
no new driver, no new kext, and no new protocol.

Decide the paravirtual work on its remaining merits (a cleaner architecture,
removing our decode, a path to features the R200 cannot express), not on the
performance claim I made before measuring.

---

# Guest-side progress, 2026-09-20

**The load path is proven on the real 10.4.11 guest, with no kernel code.**

- GLEngine in *this* guest contains both `IOGLBundleName` and `GL_RESOURCES`.
- It requires exactly **63** `gld*` entry points, in a fixed order, recorded
  in `guest/gld/entrypoints.txt` (extracted from the guest's own GLEngine).
- `guest/gld/pegld.c` exports all 63, cross-builds to a PowerPC bundle in
  seconds (see below), and **Tiger loads it, calls it, and lists it as a
  third renderer** alongside the emulated R200 and the software renderer.
- Observed call order: `gldInitializeLibrary` -> `gldGetVersion` ->
  `gldGetRendererInfo`.
- GLEngine validates the renderer ID from `gldGetVersion`: IDs colliding
  with the live ATI renderer (0x1601/0x1602) are rejected and the module is
  unlinked; 0x2000, 0x0600 and 0x1800 are accepted.

Cross-build (no G4 needed for the userspace half):

    limactl start ppcbuild
    limactl copy guest/gld/pegld.c ppcbuild:/tmp/pegld.c
    limactl shell ppcbuild bash -lc 'P=/opt/ppc/bin/powerpc-apple-darwin9; \
      SDK=/opt/ppc/SDKs/MacOSX10.5.sdk; cd /tmp && \
      $P-gcc -isysroot $SDK -mmacosx-version-min=10.4 \
      -Wl,-syslibroot,$SDK -bundle -o GLDriverPE pegld.c'

Install as a *flat* bundle (no Contents/) and point GL_RESOURCES at its
directory; copy Apple's GLDriver.bundle in beside it or the software
fallback disappears:

    /tmp/pegl/GLDriverPE.bundle/GLDriverPE
    GL_RESOURCES=/tmp/pegl/ ./yourglapp

`guest/gld/abi/` holds the recovered ABI: `gld_abi.h` (prototypes tagged
CONFIRMED / INFERRED / UNKNOWN with evidence addresses), `NOTES.md`, and the
two reference binaries pulled from the guest. Highlights: `gldCreateContext`
takes 7 arguments; `gldInitDispatch(ctx, table, mask)` fills a GLD-private
~33-slot table, *not* the public `GLIFunctionDispatch`; sync funnels through
a byte-reversed read of `SCRATCH_REG0`; `GL_REJECT_HW` disables the hardware
path in Apple's own driver.

`guest/gpu/` holds an untested kext skeleton for the hardware path (needs
the PowerBook to build, and admin in the guest to load). Note the open
question recorded there: our device has no framebuffer, and 10.4 selects a
renderer via the accelerator attached to a *display*, so `IOGLBundleName`
may never be consulted for it. Prove the transport with a plain command-line
program before involving OpenGL.

## The transport works, end to end, 20 September 2026

The kext is loaded in the real 10.4.11 guest and the renderer's own test
talks to the device through it:

    PEGpu: attached, features 00000007, GL bundle PowerEmuGPUGLDriver

    $ /tmp/petest
    open: ok
    features: 00000007  ctrl 0x5000  shared 0x2008000
    fence 1 reached, error 0
    PASS: 16384 pixels written by the host and read back by the guest

Every layer is exercised and each is separately attested:

| layer | what proves it |
|---|---|
| kext matches and attaches | `PEGpuAccelerator` registered, publishes `IOGLBundleName` |
| BAR mapped into user space | `open: ok` -- both regions mapped, magic and version read |
| guest encoder builds a legal batch | no `PE_GPU_ERR_PACKET` |
| doorbell reaches the host | fence advances |
| host executes the work | the pixels changed, and to the right value |
| result visible to the guest | read back through the same mapping |

The target is poisoned with 0xA5 first, so "the host did nothing" and "the
host filled with black" cannot be confused.

**One bug stood between compiling and loading**, and only a real kextload
could have found it: `OSDynamicCast(IODeviceMemory, ...)` needs
`IODeviceMemory::metaClass`, which `com.apple.kpi.iokit` does not export --
only the legacy `com.apple.kernel.iokit` does, and a kext cannot depend on
both. The cast was redundant; `getDeviceMemoryWithRegister()` already
returns the right type.

**What is left is now only the GL side**: translating GL state into
PEGpuState and GL primitives into PEGpuDraw. The pipe they travel down is
built and measured.
