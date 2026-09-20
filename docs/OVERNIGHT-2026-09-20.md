# Overnight, 19-20 September 2026

## The headline

Tiger's OpenGL now loads a renderer we wrote, and **builds a full GL context
on it**, with no kernel extension and nothing installed in the guest.

    gldInitializeLibrary -> gldGetVersion -> gldChoosePixelFormat ->
    gldDestroyPixelFormat -> gldCreateShared -> gldCreateContext ->
    gldCreateTexture x32 -> gldCreatePipelineProgram x2 ->
    gldCreateVertexArray

That is OpenGL allocating a context's texture units, program objects and
vertex array through our code, on the real 10.4.11 guest.

## And the finding that should govern what happens next

`PPCGPU_TRAFFIC=1` during Warcraft III:

    4050 mmio-writes/s   715 mmio-reads/s   1008252 type0-regs/s   6585 draws/s

**Over 99.5% of the guest's GPU register traffic never traps.** Apple's ATI
driver batches nearly everything into PM4 command buffers in ordinary
memory. The argument I made for paravirtualisation -- that every register
write leaves translated code through the software MMU and takes the big lock
-- was wrong, and it was mine, made before measuring.

What paravirtualisation still buys: our own decode (~3.7% device model,
~3.0% Metal encode), some of the guest driver's own work, and a cleaner
architecture that can express things the R200 cannot. What it does not
touch: the ~42% of emulator time spent on address translation and block
lookup, which is where the frame rate actually is.

**Worth deciding deliberately**, on architecture rather than on the speed
claim.

## What exists now

| piece | state |
|---|---|
| host device `poweremu-gpu` | ring, doorbell, fences, validation, wired to Metal; 23-check self-test passes |
| guest renderer `guest/gld/` | 63 entry points, loaded and enumerated by Tiger, context created on it |
| guest ring encoder | native unit test passes, cross-compiles for PowerPC |
| guest kext `guest/gpu/` | **compiles** on the PowerBook (gcc-4.0, 10.4u SDK); not loaded |
| recovered ABI | `guest/gld/abi/` -- prototypes with evidence, plus reference binaries |

## Two techniques worth keeping

- **`PEGLD_PROBE=1`** fills each word of an unknown struct with its own
  index; reading it back through `CGLDescribeRenderer` maps the fields.
  This is how the renderer-info layout was recovered.
- **`PEGLD_PROXY=<real GLD>`** loads Apple's driver alongside ours and
  forwards calls, dumping what it returns. This corrected a wrong model of
  the pixel format in one step, after several rebuilds of guessing: entries
  describe **one concrete configuration** and are chained, they do not
  advertise capability masks. A format claiming everything is silently
  dropped by CGL.

## Performance work, measured

Paired A/B on the Mac Studio (alternating builds, medians, so drift cancels):
the night's emulator changes measured **+5.9%** over the build in the app
(50.9 -> 53.9 fps at the Warcraft menu). Those changes: exploit-hardening
compiler flags off, JIT write-protect state cached, bring-up diagnostics
gated behind `PPCGPU_DIAG` (including a per-draw CRC32 that ran forever), a
display surface no longer rebuilt on every page flip, and the register-name
lookup no longer evaluated twice per MMIO access for loggers that are off.

**The Mac Studio runs the same scene at ~51 fps against ~26 on the MacBook
Air.** The Air has been the limiting factor throughout.

## Things I got wrong, and what fixed them

- **Three "regressions" that were not real.** An unchanged build measured 27
  fps early in the session and 15 fps hours later: a fanless Air, thermally
  throttled. Every comparison against an older number was meaningless.
  Fixed by `scripts/abtest.sh`, which alternates builds and reports a ratio.
- **A stale VM held the guest's SSH port for two hours**, so the harness
  measured the wrong guest while stealing a core. `smoketest.sh` now refuses
  to start when the port is taken.
- **`nc -z` on a forwarded port was a false positive** -- slirp accepts
  connections whether or not the guest listens. Boot detection now waits for
  the guest's own console output.
- **Two measurement loops killed each other's VMs**, and later I replaced
  `measure.sh` while a run was using it. `measure.sh` now takes a lock.
- **A `static __thread` in a header** gave every translation unit its own
  copy of the JIT write-protect state, so one file's idea of it let another
  skip a switch it needed. That one did not boot at all.

The pattern in all of these: the emulator was fine and the measurement was
not. Every one was caught by a control run rather than by reasoning.

## Next

1. Capture a real GL trace through the shim (`PEGLD_PROXY`) from an actual
   application, to see which entry points matter before implementing
   `gldInitDispatch` -- it writes 17 function pointers and two mask sets,
   and a wrong guess there crashes rather than warns.
2. Then route those calls into the ring, which already exists on both sides.
3. The kext only when hardware-class acceleration or Quartz Extreme is
   wanted; it needs admin in the guest, which is yours to type.
4. Independently of all of this: the million type-0 register writes a second
   are decoded through the full MMIO switch. That is a contained
   optimisation needing no guest driver at all.
