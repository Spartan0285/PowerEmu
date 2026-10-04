# The second screen's shear, measured — 4 October 2026

The shear on guest screen 2 is a scan-out stride that is 192 bytes wider than
the row the picture is actually painted at.  This is the measurement that
shows it, and the one-line cause.

## What was run

Two `ppc-mac-gpu` cards, 1680x1050x32, Tiger 10.4.11, `-display none` with a
`poweremu-display` listener on each card (the capture path the app uses; a
bare `screendump` wedges the session — see `r350-chess-2026-10-03/README.md`).
`PPCGPU_PITCHLOG=1`.  Overlay on a read-only APFS clone of the user's disk, so
nothing writable was opened.

Harness: `scratchpad/dual/m1.sh`.

## The numbers

```
GPU MODE[gpu0]: 1680x1050 bpp=32 stride=6720 offset=0x0 pitch_reg=0xd2
GPU MODE[gpu1]: 1680x1050 bpp=32 stride=6720 offset=0x0 pitch_reg=0xd2
GPU MODE[gpu0]: 1680x1050 bpp=32 stride=6912 offset=0x0 pitch_reg=0xd8
GPU MODE[gpu1]: 1680x1050 bpp=32 stride=6912 offset=0x0 pitch_reg=0xd8
```

`pitch_reg` is in units of 8 pixels: `0xd2` = 210 -> 1680 px -> **6720 bytes**,
`0xd8` = 216 -> 1728 px -> **6912 bytes**.  Both cards start at the exact row
length and both are moved to the 256-byte-aligned one.

`1680 * 4 = 6720`, which is not a multiple of 256; rounded up it is 6912.  The
two coincide only when the width is a multiple of 64 — 1024, 1280, 1920.  That
is why every test at 1024x768 passed and could not have failed.

The listener's own damage rectangle gives the same answer independently:

```
last_damage=(0, 0, 1680, 1021)
```

`1050 * 6720 / 6912 = 1020.8`.  A full-height repaint of content laid out at
6720 covers 1021 rows of a 6912-byte scan-out, and the remaining 29 come up
black.  An earlier session measured "1021 good rows + 29 black", dismissed it,
and was wrong to.

## The cause

`hw/display/ppc_mac_gpu.c`, the VBE `ENABLE` handler:

```c
s->regs.crtc_pitch = (s->exact_scanout_pitch ? w
                      : r200_aligned_pitch_pixels(w, bpp)) / 8;
```

With `exact-scanout-pitch` off this is unconditionally the aligned pitch, and
on the second card `CRTC_PITCH` is the *only* live source of the scan-out
stride: `present-pitch-override=off` kills the blit-learned override, and
`exact-scanout-pitch` was never passed.  Meanwhile nothing accelerates the
second card, so its picture is painted by `qemu_vga.ndrv` at the unrounded row
length.  Scan-out 6912, content 6720.

This assignment is a direct store, not the MMIO `CRTC_PITCH` case, which is
the only path that was instrumented.  That is why a previous session concluded
"the guest never programs card 2's pitch" — the write was real and invisible.
`pitchlog(s, "vbe", ...)` has been added at that store.

## The fix

`exact-scanout-pitch=on` on the second card, keeping `present-pitch-override=off`
so no stray blit can re-latch a learned pitch over it.  The flag is not a
classic-Mac-OS flag; its precondition is "this frame buffer is painted by
`qemu_vga.ndrv` at an unrounded row length", which is exactly the second
card's situation under Mac OS X.

## Images

- `before-screen1-sheared-menubar.png` — screen 1, wallpaper clean, menu-bar
  strip sheared into diagonal bands.  Only the menu bar is sheared because it
  is the only region being repainted; the wallpaper was laid down while the
  stride still agreed.
- `before-screen2-black.png` — screen 2, black.

After the fix, screen 2's scanline pattern is **horizontal and evenly spaced**
rather than diagonal, which is the shear going away, and the listener's damage
rectangle covers the full 1050 rows instead of 1021.

## A harness fault that invalidates part of this, recorded rather than hidden

The first two runs used `scratchpad/dual/pdc.py`, which encodes each PNG inline
in its receive loop.  `pe_send()` in QEMU is a blocking write-all, so that
stalls QEMU's main loop and wedges the guest session — the failure already
written up in `r350-chess-2026-10-03/README.md`, which is why
`tools/pedisplay-capture.py` encodes on a writer thread.  Both runs stalled
with the wallpaper up, no Dock and no menu bar, and `damage` frozen at 43.

**So "the desktop never extended onto screen 2" is not a finding.**  It is the
wedge, and it is the same shape as the user-reported "64 MB: wallpaper only,
no Dock, no menu bar" symptom, which now also needs re-testing with a capture
client that does not block.

What does survive: every pitch number above.  Those are register-level log
lines emitted during mode set, long before the capture client has enough
frames to stall anything, and they are reproduced identically across all
three runs.

## What this does not explain

"About This Mac" hanging on Graphics/Displays, and the blue-screen hangs at
some VRAM sizes.  Those are a separate fault, and the audit of 4 October points
at the submit layer rather than at the guest's kext: `ppc_mac_gpu_submit.m`
keeps `g_vram`, the hazard tables `g_written`/`g_read`, and the render-pass
encoder as process globals bound to whichever card attached first, so the
second card reads and writes the first card's video memory.  Not yet tested.


---

# The second fault, isolated: it is the second *card*, not the VRAM size

With the stride fixed, screen 2 stopped shearing — its scanline pattern is
horizontal and evenly spaced, and the damage rectangle covers all 1050 rows.
But neither screen reached a usable desktop: wallpaper, no Dock, no menu bar,
and screen 1's menu-bar strip itself sheared.  That is the user-reported
"64 MB: wallpaper only" symptom, reproduced.

## The control

Identical harness, identical disk, identical resolution (1680x1050), identical
VRAM (64 MB), capture client that does not block — **one card instead of two**:

`control-one-card-1680-perfect.png` is a flawless Tiger desktop.  Crisp menu
bar, Finder windows, icons, Applications list, clock.  No shear anywhere.

| | screen 1 | screen 2 |
|---|---|---|
| one card | **perfect desktop** | — |
| two cards | wallpaper, sheared menu bar, no Dock | horizontal lines, no desktop |

Same binary, same disk, same resolution, same VRAM.  The only variable is the
second card.  So this is not a VRAM-size fault and not a stride fault; adding
the second card breaks the first one.

## Why — and what was changed

The Metal submit layer is a process-wide singleton.  `ppc_mac_gpu_submit.m`
keeps `g_vram`, the command buffer, the sequence counter and the hazard tables
`g_written`/`g_read` as file-scope globals, and `r200_submit_attach()` binds
them to the first card that attaches behind a `static bool attached` latch.
Every texture the layer builds is a linear view over *that* buffer.  A second
card reaching the same path therefore renders into the first card's video
memory, and `metal_range_busy_r200()` — which ignored its `opaque` argument
entirely — answered the first card's hazard questions for it.  Both cards put
their frame buffer at the same VRAM offset, so collisions are the common case,
not a corner case.

The change makes ownership explicit: `gpu_submit_vram()` exposes the bound
buffer, `r200_submit_owns()` tests it, `metal_draw_r200()` returns -1 for a
non-owner (the device's documented "backend cannot render this" fallback, so
that card renders in software), and `metal_range_busy_r200()` reports no
batched work for a card that never submits any.

This is deliberately the small version of the fix.  The right end state is a
per-card submit layer; refusing the non-owner is what makes two cards correct
without rewriting it, at the cost of the second card being unaccelerated —
which is what the second card already is under Mac OS X anyway, since nothing
binds an accelerator to it (it gets IOBootNDRV, see above).


---

# Dual displays work

Two cards, 1680x1050, 64 MB each, no mirroring, no Harmony.

- `WORKING-screen1-desktop.png` -- guest screen 1: a complete Tiger desktop.
  Menu bar, Finder windows, disk and Network icons, Applications list, clock.
  No shear.
- `WORKING-screen2-extended.png` -- guest screen 2: the extended desktop,
  1050 clean rows, no shear and no banding.
- No kernel panic. `PITCH[gpu0] vbe` and `PITCH[gpu1] vbe` both report
  6720 bytes a row with `exact-opt=on`.

Three things had to be true at once, and each was found by a separate
measurement:

1. **Both cards scan out the exact row length.**  `exact-scanout-pitch=on` on
   *both*, not just the second.  With two cards neither screen is painted by
   Mac OS X's ATI driver -- both are driven by qemu_vga.ndrv at the unrounded
   row length -- so the first card shears exactly as the second did.  That is
   visible in `screen1-sheared-when-not-exact.png`, taken with the flag on the
   second card only: screen 2 clean, screen 1 in bands.

2. **The second card reports a PCI id no ATI kext claims** --
   `x-pci-device-id=0x5964`, Radeon 9200 SE.  With two identical cards
   `ATIRadeon8500` attaches an accelerator to both, which IOKit permits
   (IOMatchCategory is scoped per provider), and on the second card it panics
   the guest: `two-card-panic-ATIRadeon8500.png` is a verbose boot with
   `com.apple.ATIRadeon8500` in the backtrace, a data-access fault and
   `IOKitWaitQuiet() timed out`.

3. **The firmware has to know that id.**  OpenBIOS's `vga_devices[]` is what
   decides whether a display card is configured at all; an id that is not in
   it gets no `device_type`, no `linebytes` and no mode.  That is why the
   firmware had to be rebuilt, and why it could not be until the arm64 host
   detection bug in `config/scripts/switch-arch` was fixed -- see
   `docs/BUILDING-OPENBIOS.md`.

## Still open

- The per-card submit-layer ownership change is in, but the two-card run never
  exercised it (the refusal never fired), so it is untested rather than
  verified.  It remains correct on inspection and harmless.
- "About This Mac" on Graphics/Displays has not been re-checked since any of
  this.
- Everything here is at 1680x1050 with 64 MB a card.  128 MB and the other
  resolutions have not been retested.


---

# Two mistakes made here, kept

**A member added to the front of a QOM device struct.** The performance
totals were moved out of a file-scope struct and onto `PPCMacGPUState`, so
that two cards would keep two sets of counters instead of adding both screens'
frames together.  The member went in at the *top* of the struct, ahead of
`PCIDevice pci`.  QOM casts an `Object *` straight to the device struct and
relies on the parent instance being at offset zero, so every cast in the
device was then wrong and the emulator segfaulted a few seconds into the boot,
right after `[VRAM_WRITE_TRAP]`.  It is deterministic, and it looks nothing
like a struct-layout bug from the outside.  The parent member stays first;
new members go after it.

**A capture client that sends `quit` to the monitor.** A helper that read the
device counters over the HMP socket ended its script with `quit`, which is
"quit the emulator", not "close this connection".  It shut down a healthy
9800 VM mid-run and the failure read as a crash.  The reader now sends only
the `qom-get` and lets the socket time out.

# One firmware for every card

The firmware ended up knowing all four ids rather than one per card:
`0x5046` (Rage 128, upstream), `0x5960` (the RV280 this project emulates),
`0x5964` (the second screen's card) and `0x4e48` (the 9800/R350).

That last one was not cosmetic.  The 9800 had been running against a firmware
that did not list it, so OpenBIOS gave it no display node and the console said
`Output device screen not found` -- no frame buffer at all, a flat screen, and
`damage` stuck at 1.  With the id in the table the 9800 composites a complete
Tiger desktop.  The note in `r350-chess-2026-10-03/README.md` that "each
firmware only knows its own card" described the state of the builds at the
time, not a constraint: one table can hold them all.


---

# Two-card boot reliability: not solved

Dual display works when it boots.  It does not always boot.

Across the night's two-card attempts, several wedged early -- verbose boot
reaching "Starting virtual memory" or thereabouts and stopping, with `damage`
frozen in the twenties or thirties.  A `sample` of one of them shows all four
MTTCG vCPU threads parked in `mttcg_cpu_thread_fn` rather than spinning in
`cpu_exec_loop`: **the guest has halted.**  The emulator is healthy; the
guest stopped.

Two caveats on those numbers, both mine:

- Several of the failed attempts were **not** on an idle host.  `kill` was
  issued against a PID taken from `pgrep -f "name DualMx"`, which matches the
  monitoring shells as readily as the emulator, so more than one VM was left
  running and contending -- three at once at the worst point, one of them at
  199% CPU for half an hour.  The project's own note that host CPU contention
  wedges a session applies squarely.  `/tmp/pedual/killvm.sh` now matches the
  binary path as well as the name.
- So the honest count of clean single-VM two-card boots is small, and the
  wedge rate is not yet characterised.

## Bisected

The suspicion that the night's later changes caused the wedge is **ruled out**.
Two experiments, each with one VM on an otherwise idle host:

| configuration, current binary | result |
|---|---|
| **one** card, 1680x1050 | full desktop on the first snapshot, 1,080,817 bytes |
| **two** cards, same binary, same disk | wedged at `damage=32`, eight identical frames |

So the binary is healthy and the wedge belongs to the two-card configuration
itself.  Reverting the `CRTC_H_DISP` mask widening made no difference either,
so that was not it; the widening is correct per AMD's register spec (the field
is nine bits) but has been left reverted, because it fixes only a latent fault
at widths above 2048 and there is no reason to carry an unverified change into
a build that is about to be tested.

What the wedge looks like: verbose boot reaches roughly "Starting virtual
memory" and stops, `damage` frozen, and a `sample` shows all four MTTCG vCPU
threads parked in `mttcg_cpu_thread_fn` rather than running `cpu_exec_loop`.
The guest has halted; the emulator is fine.

The best-grounded suspect remains the one the 4 October audit named: the Metal
submit layer is a process-wide singleton (`g_vram`, the hazard tables, the
render-pass encoder) bound to whichever card attaches first.  Turning the
non-owner away stops it rendering into the other card's memory, but the
layer is still shared.  A per-card submit layer is the next piece of work.


## What has been ruled out

| tried | result |
|---|---|
| `CRTC_H_DISP` mask widened to nine bits | not the cause; reverted anyway |
| one vCPU, single-threaded TCG, two cards | **worse** -- 12 minutes at 100% CPU, console stops at `of_startup returned!`, frame buffer all zeros |
| one card, same binary | boots to a full desktop immediately |

So it is not a regression from the night's changes and not simply a race
between MTTCG vCPUs: two cards is unstable with one CPU as well, and fails
even earlier.  The failure moves *earlier* with less concurrency, which argues
against a data race between vCPUs and for something structural about having
two cards present at all -- firmware-side configuration of the second card,
or the single global `video_info` in OpenBIOS's `libopenbios/video_common.c`
that `setup_video()` re-initialises per VGA device, so `frame-buffer-adr` and
`/chosen display` end up describing whichever card was configured last while
the console was installed on the first.  That is the next thing to measure.


## Narrowing it further: the wedge tracks the second *display node*

Two more experiments, each one VM on an idle host.

**Card 2 given an id OpenBIOS does not know (`0x5961`).**  `pci_find_device`
returns NULL, so the card gets no `device_type`, no geometry and no config
callback -- it is a bare PCI node, not a display.  Screen 1 booted to a **full
desktop** (1,080,585 bytes).  Screen 2 was blank, as it must be.

**Card 2 known, but not allowed to become the console.**  A gate was added to
`vga_config_cb` so only the first display card runs `setup_video()` and the
FCode, with the second getting `address`/`width`/`height`/`depth`/`linebytes`
set directly in C instead -- the five properties `IOBootNDRV` requires.  This
**did not** fix the wedge: screen 1 stopped at `damage=27` again.

So the wedge follows the *existence of a second display node* that Mac OS X
will bring a framebuffer up on, rather than the firmware console being
clobbered by the second `setup_video()`.

**The gate has been reverted** and is not shipped.  It is unproven, and the
`address` it sets is the raw PCI BAR rather than the address the FCode's
`map-fb` would hand back; if those differ, the second framebuffer would be
pointed somewhere wrong, which is a plausible way to make things worse rather
than better.  The rebuilt firmware hashes identically to the shipped one
(`ef674543…`), so the revert is clean and the build is reproducible.

**Do not read these as a reliability measurement.**  m6 and m7 booted two
fully configured cards to two good desktops, and the screenshots above are
from that; m8 and m12 did not.  That is a handful of runs either way, with no
bisect between them, so the honest statement is that two-card boots sometimes
wedge during early kernel start and the rate is unmeasured.
