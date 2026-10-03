# Radeon 9800: the blue cast on Leopard — settled

29 September 2026. **Resolved.** The R350 probe now boots Leopard to a
correctly coloured 1680×1050 desktop. This document records what the fault
turned out to be, the measurements that established it, and what the original
hypothesis got wrong. Read [RADEON-9800-BRINGUP.md](RADEON-9800-BRINGUP.md)
for the surrounding bring-up.

Evidence: [blue-cast](evidence/r350-bringup-2026-09-29/blue-cast/) —
[before](evidence/r350-bringup-2026-09-29/blue-cast/screen-before.png),
[after](evidence/r350-bringup-2026-09-29/blue-cast/screen-after.png), the boot
harnesses, the register captures, the channel diagnostics either side of the
change, and the patch.

## What it was

Not the scan-out decode. The R350 **texture fetch** read each texel's
components straight out of VRAM, and this emulator's VRAM does not hold what
the guest's declarations describe.

Every other consumer of VRAM agrees on one layout: `[A][R][G][B]`, the
big-endian ARGB word a PowerPC guest writes. The CPU through the PCI aperture,
the inherited 2D engine, and the CRTC scan-out (`PIXMAN_BE_x8r8g8b8`) all use
it, and the Radeon 9200 guest, whose driver leaves `SURFACE_CNTL` at zero,
agrees.

The Leopard `ATIRadeon9700` driver does not. It sets `SURFACE_CNTL`
`NONSURF_AP0_SWP_32BPP` — measured `0x00200001`, against `0` for the 9200 on
the same disk. On real hardware that byte-swaps 32-bit CPU accesses through the
aperture, so physical VRAM holds the little-endian word, and every per-resource
byte order the driver then declares — the swap in the low bits of `TX_OFFSET`,
the swap field of `RB3D_COLORPITCH` — is stated relative to that.

This device does not model the aperture swap, so VRAM stays big-endian for
everyone. A GPU-side access has to compose the missing reversal itself: the
guest's component *i* is byte `3 - i` here. The render-target path already did
this, in its `DWORD_SWAP` branch. The texture path did not.

So a texel stored `ff 42 6b ad` (A=255, R=0x42, G=0x6b, B=0xad — the Dock's
blue) was fetched as `6b 42 ff ff`: red and green exchanged, and **blue taking
the alpha byte**, which is always `0xff`. That is the cast.

Red and green looked right on most of the screen because the compositor draws
the desktop in two stages — render to an offscreen target, then composite that
target as a texture — and the exchange applied twice cancels. The blue damage
does not cancel: alpha is `0xff` at both stages.

## Where the original hypothesis went wrong

The handoff's reasoning from two images was close but not right:

- It predicted **one** `0xff` byte per pixel. The dump has **two** — `ff` in
  byte 0 (real alpha) and `ff` in byte 3 (blue destroyed). That alone ruled out
  a plain channel rotation of the final framebuffer.
- It predicted the magenta rays would stay magenta under a rotation. They do
  not; a rotation makes them cyan. The rays stayed magenta because red and
  green were being exchanged twice, not left alone.
- It pointed at `ppc_mac_gpu.c:1601-1635`, the 32 bpp scan-out decode. That
  code is correct and is now confirmed correct by two independent controls.

The instruction to measure before changing code was right, and it is what
found this. The specific place it said to look was not where the fault was.

## The measurements

Each is reproducible from the harnesses in the evidence directory. All run on
the Mac Studio against a disposable snapshot of the inactive diagnostic Leopard
disk on its external drive.

**1. The framebuffer, not a screenshot.** `boot40-fbdump.py` boots the probe,
waits for the desktop, then over the *same* QMP connection reads the format
registers and `pmemsave`s the scan-out buffer. Registers read back byte-swapped
through the monitor's `xp`, which is expected: the device is little-endian and
`xp` dispatches with target endianness. Un-swapped they decode cleanly —
32 bpp, 1680×1050, render target `ARGB8888`, pitch 1728, swap mode 2.

Result: every pixel is `ff XX YY ff`. Byte 3 is `0xff` for 99.997% of
1.76M pixels; byte 0 is `0xff` for 99.11% with a short tail from blended UI.

**2. A Radeon 9200 control on the same disk.** `boot41-9200-fbdump.py`, stock
firmware, default device. Its framebuffer is `[ff][R][G][B]` with all three
colour bytes carrying real data: `ff f8 f8 f8` for the menu bar, `ff 42 6b ad`
for the Dock, `ff 08 09 0d` for the dark wallpaper. This fixes the VRAM
contract and confirms the scan-out decode.

**3. A bisect with the renderer disabled.** `boot42-norender.py` runs the probe
with `x-r350-linear-render=off`, so no 3D draw reaches VRAM. Most of the screen
is black, and every pixel the 2D path *does* write is correct — `ff 42 6b ad`,
blue `0xad`, not `0xff`. This exonerates the scan-out, the 2D engine and the
CPU path, and localises the fault to the Metal render path.

**4. The captured fixture.** `build/r350-replay/texture0.bin`, captured in an
earlier session, holds `ff 42 6b ad` — the source texture is already in the
`[A][R][G][B]` contract before any draw touches it.

**5. Instrumentation, before and after.** A bounded diagnostic behind
`x-r350-shader-snapshots=on` reports each distinct (texture format, swap, role)
combination once, with the raw VRAM bytes and the RGBA the fetch produced:

```
before:  RAW ff 42 6b ad  ->  RGBA 6b 42 ff ff   (written back as ff 6b 42 ff)
after:   RAW ff 42 6b ad  ->  RGBA 42 6b ad ff
```

Reporting once per combination rather than for the first N draws matters: the
desktop-sized draws are in the hundreds, well past any first-N window.

## The change

`hw/display/ppc_mac_gpu.c`, R350 experiment only:

- `r350_vram_component_byte()` names the correction and carries the reasoning.
  The texture fetch composes it onto the declared swap permutation.
- The render-target conversion uses one byte order for both swap modes the
  driver uses, instead of a raw `memcpy` for `NO_SWAP`. The storage order is
  fixed by the CPU/2D/scan-out contract, not by the guest's declaration; the
  `REQUIRE` still rejects any third mode.

The default 9200 path is untouched — the change is inside the R350 draw path.

## Verification

- Framebuffer after the fix: byte 0 is `0xff` for **all** 1,764,000 pixels, and
  bytes 1–3 each span all 256 values with matched saturation rates
  (0.096% / 0.091% / 0.096%). Before, byte 3 was `0xff` for 99.997%.
- The capture shows the Leopard Aurora wallpaper as it should be: black
  background, magenta rays, white core, teal at the lower left.
- `tests/poweremu/run-r300-metal-test.sh`: 20 cases pass on the Apple M5.
- `tests/poweremu/run-r300-replay-test.sh`: 11 cases pass, 786,432 pixels each.

## What this does not fix

The colour fault was independent of the 3D work and fixing it does not advance
shader support. The bring-up document's next concrete 3D target is unchanged.
Still outstanding and still gated: the faint menu bar, the dual-texture draw
that removes the Dock when committed live, and the compact four-input
rasterizer route.

## A separate defect found along the way

The **Radeon 9200** — the shipping default — renders this Leopard desktop
**sheared** on this disk. Its framebuffer content is laid out at a 1728-pixel
row while `CRTC_PITCH` reports 1680, so every row drifts 48 pixels: see
[the rendered control framebuffer](evidence/r350-bringup-2026-09-29/blue-cast/9200-control-framebuffer.png).

This is the same presentation-stride problem the R350 experiment solves for
itself with `r200_set_present_pitch()`, which is gated on the R350 path. It is
**pre-existing, not caused by this work**: the same shear is in
`boot6-9200-control/screen.ppm` from the earlier session. The bring-up table's
"Default 9200 with rebuilt backend: Finder/WindowServer start" row is accurate
as written but says nothing about visual correctness, and should not be read as
covering it. This needs its own investigation, including whether it reproduces
in the shipping app and on the ordinary user disks rather than only on this
diagnostic one.

## Testing on the Studio

`ssh studio` (`Apples-Mac-Studio.local`, macOS 26.7, arm64). Guest images live
on its external drive: `~/Developer/PowerEmu-SMP` is a symlink to
`/Volumes/Studio External/PowerEmu-SMP`, and the read-only bases are in
`vms/` — the internal disk has only ~41 GiB free, so keep them there. Every run
opens them with `snapshot=on`; the harnesses assert that before launching.

Work root: `~/Developer/PowerEmu-SMP/r350-probe-20260929`. Build the app with
`scripts/build-r350-app.sh` — a bare binary copy will not run, because the
bundle rewrites dylib load paths, and an unbundled binary dies on
`libgnutls.30.dylib`.

**The rsync trap, still live.** Staging with

```sh
APP=$(ls -dt build/*9800*.app build/*R350*.app | head -1)
rsync -a --delete "$APP/" studio:~/pe-bench/r350-VM.app/
```

is dangerous: if the glob matches nothing, `$APP` is empty, `"$APP/"` becomes
`/`, and rsync copies the entire local filesystem to the Studio. Always guard:

```sh
[ -n "$APP" ] && [ -d "$APP" ] || { echo "no app built" >&2; exit 1; }
```

One QMP client at a time — a second one wedges both. The harnesses here do the
screenshot and the memory dump over the connection they already hold.

## State left on the Studio

`~/Developer/PowerEmu-SMP/r350-probe-20260929/Probe.app` has been replaced with
the fixed build (`scripts/build-r350-app.sh`, binary sha256 `33703dc1…`), so
the existing `boot-probe-*.py` harnesses pick it up. The pre-fix behaviour is
preserved in the evidence directory, not in a second app bundle. The 7 MiB
framebuffer dumps were deleted after analysis; the register captures, guest
state, screenshots and channel diagnostics were kept.

## The 9200 shear: found and fixed

The shear described above is fixed, and it was not a 9200 defect so much as a
**measurement defect that made every headless capture wrong**.

The presentation-stride override exists and is called from all four 2D blit
paths. It was gated on `s->disp.bpp == 32`. `s->disp` is filled in by the
console refresh, so with `-display none` it stays zero until somebody asks for
a screendump — and the override could therefore never activate at all. The
first refresh in a headless run *is* the screendump, by which time the blits
that would have set the pitch have long since happened.

Measured before changing anything, with a bounded probe at each override site:

```
[PRESENT_PITCH_PROBE] site=MMIO_NOSRT dst=0x0 crtc=0x0 src_pitch=6912
    dst_pitch=6912 bpp=4 disp_bpp=0 disp_stride=0 1680x1050
    size_ok=yes disp_bpp_ok=no
```

`dst_pitch` is 6912 and the rectangle is large enough; only `disp_bpp` fails.

Whether a blit is 32 bpp is a fact about the blit, so all four sites now test
the blit's own `bpp`, which is already in scope and already used for the dirty
calculation. Two further places had the same dependency and are fixed with it:
`r200_set_present_pitch()` computed its "narrower than a scanline" floor from
`s->disp.width`, so headless the floor was zero and the guard silently did
nothing; and the frame counter behind the performance overlay tested a scanout
extent of `s->disp.stride * s->disp.height`, which headless is zero, so no
write could ever overlap it and the counter stayed at zero. Both now fall back
to the CRTC registers, which are programmed whether or not anybody is watching.

After the change the same run logs

```
[STRIDE_CHANGE] MMIO_NOSRT: override activate 0 -> 4096
[STRIDE_CHANGE] MMIO_NOSRT: override update 4096 -> 6912
[STRIDE_CHANGE] update_display_mode: CRTC gives 6720, override forces 6912
```

and the capture is coherent: mean row-to-row delta 1.93 against 13.78 before,
with the full menu bar, clock and Dock.

**What this means for the earlier evidence.** Every headless screenshot in this
project was taken through the broken path. The R350 experiment was unaffected
because it sets its presentation pitch through `r200_set_present_pitch()` from
its own draw path, with a guard that does not consult `s->disp.bpp` — which is
why the R350 desktop looked right in captures while the 9200 control did not.
A displayed session refreshes the console continuously, so `s->disp` is
populated there and the shipping app was most likely never affected; that has
not been confirmed on a real display, and should be before the finding is
described as headless-only.
