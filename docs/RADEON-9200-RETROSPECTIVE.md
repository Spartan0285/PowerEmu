# Getting the Radeon 9200 working: what actually broke, and what fixed it

A retrospective on bringing Mac OS X's own ATI driver up on PowerEmu's emulated
Radeon 9200 (`ppc-mac-gpu`, PCI `1002:5960`, an RV280/R200 part), from "the
kext loads but the desktop is frozen" to accelerated Quartz Extreme, OpenGL
games and a 10.5 desktop.

Written 30 September 2026, mainly as a reference for the Radeon 9800/R350
bring-up, which is repeating some of the same shapes of mistake.

---

## The single most expensive error: the wrong driver

**Symptom.** Window frames and drop shadows moved when you dragged a window,
but the window *body* stayed frozen. The desktop drew once and never refreshed.

**What was believed.** That the device needed R300 register stubs "to let the
kext load", and that acceleration objects like `IOATIR300Accelerator` were
missing.

**What was true.** `1002:5960` is an **R200** part, and stock
`ATIRadeon8500.kext` already matches it — its `IOPCIMatch` contains
`0x59601002` alongside `0x59611002`, `0x59621002`, `0x5C631002`. Earlier work
had instead added `0x59601002` to `ATIRadeon9700.kext`, an **R300-family**
driver. Every "missing R300 register" was a symptom of forcing the wrong
driver onto the part.

**Why it produced exactly that symptom.** From disassembling the GA plugins:
CoreGraphics reaches the hardware through `IOFBBlitSurfaceCopy` →
the GA plugin's `radeonCopyRegion`.

| plugin | how it implements `radeonCopyRegion` |
|---|---|
| `ATIRadeon8500GA.plugin` | the **2D engine** — the blit path the device already emulated |
| `ATIRadeon9700GA.plugin` | four calls to `radeon3DCopySetup` + `radeonCopyUnscaled2D` — **through the 3D pipe**, which the device captured but never executed |

So the window body was being copied by a 3D path that went nowhere, while the
frame and shadows took a different route and worked. The bug was not in the
emulation at all.

### The compounding error: the reference capture was of a different GPU

`ioreg_ati.txt`, used throughout as "what a real Mac looks like", was captured
from an `ATY,M12` — a **Mobility Radeon 9550**, an RV350/R300-family part. It
legitimately shows `IOATIR300Accelerator` / `IOATIR300Surface`, so matching a
9200 against it sent the work hunting for objects that should never appear.

The correct targets are `IOATIR200Accelerator` / `ATIR200Surface` /
`ATIR2002DContext` — and a guest capture from March already showed all three
present. The real gaps in that same file were `IOAccelerationUserClient = 0`
and `IOFramebufferSharedUserClient = 0`, which nobody had read because the
class names above them looked wrong.

> **Lesson, and it is the one worth carrying to the 9800:** check the
> provenance of your reference capture before trusting a single line of it. A
> reference from the wrong chip generation is worse than no reference, because
> it manufactures plausible work.

---

## Quartz Extreme: two gates, one of them invisible

**Symptom.** Zero 3D draws, ever. The guest reported `AppleMacRiscPCI`.

**Gate one — software, in CoreGraphics.** QE only engages when the GPU's IOKit
class appears in `GLCompositorRequiredClasses`, which defaults to
`IOAGPDevice`:

```
CoreGraphics.framework/.../Resources/Configuration.plist
```

Changing it to `IOPCIDevice` is the long-standing "PCI Extreme!" edit used to
run QE on PCI Radeons in G3/G4 Macs.

**Gate two — the driver's own AGP requirement, found by disassembly.**
The plist edit is necessary but **not sufficient**:

1. `ATIRadeon8500::start()` sets `AccelCaps = getAccelCapsBits() = (flags@0x98 >> 1) & 1`
2. That bit is set only inside `IOATIR200Accelerator::configureAGP()`

The guest showed `AccelCaps = 0`; a real R300 iBook shows 3. So the driver
itself refuses to advertise acceleration unless it has completed AGP
configuration. The fix was to give the card a working AGP bridge
(`AGPBRIDGE=on`), which is how `Accel caps 1` was finally obtained.

**A dead end recorded so nobody retries it:** moving the card onto the real
uni-north AGP bus does *not* work. OpenBIOS does not enumerate a display
there — the console logs `Output device screen not found.`, the NDRV never
attaches, and the screen stays black with zero CRTC writes. Making that work
means building a custom OpenBIOS, and the prebuilt blob in the tree is not it.

---

## The window-drag corruption: `DEFAULT_PITCH_OFFSET`

Probably the most satisfying find, because the register involved was being
**deliberately thrown away**.

**Symptom.** Dragging a window corrupted its contents — but only on the first
frame of a drag, which made it look intermittent and timing-related.

**Root cause.** `DP_GUI_MASTER_CNTL` bits 0 and 1
(`GMC_SRC/DST_PITCH_OFFSET_CNTL`) choose, per side, between an **explicit**
pitch-offset and **`DEFAULT_PITCH_OFFSET` (0x16E0)**. A *clear* bit does **not**
mean "use the `SRC_/DST_PITCH_OFFSET` register" — it means "use the default
register". Two mistakes compounded:

1. The write handler for `DEFAULT_PITCH_OFFSET` **discarded it** with the
   comment "not display timing". Apple's R200 driver programs the compositor's
   staging buffer there **every frame**.
2. The packet header path fell back to `DST_PITCH_OFFSET` when bit 1 was clear.

**Why only frame one.** Apple's window *saves* are `BITBLT_MULTI` with GMC
`0x52cc36f1` (bit 1 clear → destination = DEFAULT). Its *restores* are register
blits with GMC `0x52cc36fb` (both bits set → explicit), which is why restores
always worked. On the first drag frame `DST_PITCH_OFFSET` still held the
previous menu-bar item's staging pitch (512) while `DEFAULT_PITCH_OFFSET` held
3328: the save wrote the window at 512, the restore read it at 3328. From frame
two the guest happens to leave the two equal, so steady state looked fine.

**Verified both ways** — no tearing across slow and fast drags, and the
sequence log showed the first save of every frame landing at pitch 3328, 15
frames out of 15, where it had previously landed at 512.

---

## Leopard's red Dock: the vertex array beats the format register

**Symptom.** Under Quartz Extreme on 10.5, the Dock drew as a solid red slab
while every 2D-drawn part of the screen was perfect. Tiger, running the same
driver family (1.4.18 vs 1.5.16, built one day apart), was fine.

**Root cause.** `SE_VTX_FMT_0` says what *kind* of thing each vertex attribute
is; each vertex array's own `count` says how many dwords the vertex actually
carries. Leopard's compositor declares its colour as `FP_RGBA` — four floats —
and then streams **one dword of packed bytes**. Read as four floats, that dword
became an impossible colour *and* swallowed the two texture coordinates behind
it.

**The rule that fell out: when the two disagree, the array is right.** It
describes what was actually written. Attributes are now narrowed to their
array's width, and a colour arriving as a single dword is read as packed
`0xAARRGGBB`.

**The giveaway** was in the data: the offending values were `0xffffffff` and
`0xcccccccc` — opaque white and translucent grey, perfectly ordinary Dock
colours. As floats they are ±10²⁵ and saturate red. Green and blue looked
correct throughout, which is why it read as "a red bug" rather than "a parsing
bug".

---

## The clip bits that wiped VRAM

**Symptom.** Chess went black.

**Root cause.** The GMC clip bits were mis-defined. Bit 2 is `SRC_CLIPPING`
(one extra dword) and bit 3 is `DST_CLIPPING` (TL + BR dwords); **bit 28 is
`CLR_CMP_CNTL_DIS`, not a clip bit**. `PAINT_MULTI` ignored bit 3, so it read
the clip TL as the fill colour and turned the clip BR into a giant rectangle
that wiped VRAM.

Still open: `HOSTDATA_BLT` (0x9c) does not parse the clip dwords.

---

## Things measured and deliberately closed

These cost real time and are recorded so they are never reopened without new
evidence.

**Tiling: storing VRAM linearly is correct.** Established from AMD's *R5xx
Acceleration v1.5* (whose 2D chapters apply unchanged to R100/R200), Mesa and
the Linux radeon driver: the blit engine, the CRTC **and** the CPU aperture all
perform tiling translation in hardware, so the swizzle is unobservable to the
guest provided emulation is self-consistent. Confirmed along the way:
`DST_PITCH_OFFSET` bit 30 = macro tile, bit 31 = micro tile; pitch = bits 29:22
in 64-byte units; offset = bits 21:0 in 1 KB units; hardware **cannot** blit
from a micro-tiled source; and `RADEON_PITCH_SHIFT 21` in `radeon_reg.h` is
stale — the real shift is 22.

**Endianness: our model is inverted from hardware and equivalent.** Real
hardware holds VRAM little-endian (32 bpp = bytes B,G,R,A) with the swapper
between the PCI aperture and VRAM, so a big-endian CPU storing `0xAARRGGBB`
lands correct BGRA bytes. We model VRAM as big-endian ARGB with a `bswap` at
scanout, which produces identical pixels and is simpler — **keep it**.

> **Where that equivalence breaks, and it matters for the 9800:** anything that
> reads or writes VRAM *without* passing through the CPU aperture sees
> little-endian on real hardware but big-endian in our model. Plain blits are
> byte-order agnostic and fine. Solid fills via `DP_BRUSH_FRGD_CLR` /
> `DP_BRUSH_BKGD_CLR` are not.

**The ATI ROMs are optional.** Measured on the Studio: with **no** `romfile`
and **no** `biosrom`, Tiger boots to a full 1680×1050 desktop,
`com.apple.ATIRadeon8500 (4.1.8)` loads (the kext binds on the PCI ID),
`system_profiler` reports *Quartz Extreme: Supported*, and Warcraft III runs at
**68.7 fps / 10,717 draws per second** — matching the ROM-equipped build. The
only difference is cosmetic: the chipset reports as "QEMU VGA", because the
marketing name comes from the ROM.

---

## Two hangs that were not graphics bugs at all

Both cost days because the symptom pointed at the GPU.

**The Tiger installer hangs with 128 MB of VRAM.** 64 MB reaches the Language
Chooser; 128 MB hangs, with or without the AGP bridge, with or without ROMs.
The hang *reads* like a crash but isn't: the kernel boots completely, the last
line is `Launching Crash Reporter` — a normal Tiger StartupItem — and the
machine then sits at 1–3% CPU **waiting**, just before the first thing that
needs WindowServer.

**The grey-Apple hang on the second boot** was blamed on warm restarts for a
long time. It is OpenBIOS: `ob_ide_wait_stat` polls BSY 5000 × `udelay(1000)` =
**5 seconds**, measured on the timebase, which follows *host* time. QEMU
completes PIO sector reads asynchronously, so a single host read stalling past
5 s makes OpenBIOS give up while the drive is still busy, and BootX then spins
forever on a failed read. It reproduces on a cold boot; a restart merely makes
it likely, because the host is still flushing and a cacheless BootX does
thousands of reads.

---

## What the methods were

The things that actually produced breakthroughs, as opposed to activity:

1. **Disassembling Apple's kexts and GA plugins.** This produced the two
   biggest findings — the 2D-versus-3D copy path, and the `AccelCaps` bit that
   only `configureAGP()` sets. Neither was discoverable by staring at the
   emulator.
2. **Primary hardware documentation.** The AMD R5xx acceleration guide settled
   tiling and endianness permanently, closing two lines of investigation that
   had been reopened repeatedly on intuition.
3. **Reading the data, not the symptom.** `0xffffffff` and `0xcccccccc` in a
   vertex stream are obviously colours the moment you look at them as bytes;
   the "red Dock" framing actively hid that.
4. **Sequence logs of PM4 traffic**, which made the drag bug visible as
   "pitch 512 on frame 1, 3328 thereafter" rather than as intermittent
   corruption.
5. **A/B measurement on the Studio** rather than impressions — that is how the
   ROMs were shown to be unnecessary, with frame rates rather than "looks the
   same".
6. **Checking provenance.** The single highest-leverage question asked in the
   whole effort was "what chip was `ioreg_ati.txt` actually captured from?"

---

## Still open on the 9200

- `HOSTDATA_BLT` (0x9c) does not parse the clip dwords.
- Halo renders and then freezes; see the retired-stamp thread in the
  vertex-program notes.
- 2D compositing runs at roughly 10–13 updates/s against 30 for 3D content.
