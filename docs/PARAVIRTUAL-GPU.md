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
