# Radeon 9800 Chess handoff: resolve fixed, texture tiling next

**Date:** 4 October 2026  
**QEMU repository:** `/Users/adam/Developer/poweremu-qemu`  
**QEMU branch:** `release-0.3.3-rc`  
**QEMU HEAD before the uncommitted work:** `f770e144438ffe80f5fed3f67ac9bc11157a8067`  
**Primary source file:** `hw/display/ppc_mac_gpu.c`

This is the current handoff for Claude Code. It supersedes the diagnosis in
`CHESS-ON-THE-9800.md` where that document says the rendered Chess scene was
already correct in VRAM and only its transfer to the window was broken. New
instrumentation proved there were **two independent bugs**:

1. the R350 antialias resolve into the window backing surface never completed;
2. Chess's macro- and micro-tiled textures were read as linear rows, with the
   wrong byte interpretation for that upload path.

The first bug is fixed and validated. The second is partly fixed: the board and
pieces now render with plausible colors and geometry, but the exact R350 macro
page layout still needs one correction for narrow 32x32 glyph textures.

Do not discard the current QEMU working tree. It contains uncommitted work from
more than one active investigation. Start with `git diff --check` and inspect
the complete diff before editing.

## What is proven

### 1. `RB3D_AARESOLVE` was the missing scene-to-window operation

The Apple driver renders Chess into a padded color target and performs one
R350 resolve into the IOSurface used by WindowServer:

```text
source       0x017f5000, pitch 2816 bytes = 704 pixels
destination  0x00c3e000, pitch 2560 bytes = 640 pixels
rectangle    0,0 + 640x583
control      0x00000003
```

The previous `r350_resolve_copy()` rejected this because the scissor described
the 704-pixel source while the destination row was only 640 pixels wide. Real
hardware clips at the destination row boundary. The current implementation
clips the right edge to `MIN(src_pitch, dst_pitch) / 4` before copying.

`x-r350-aa-resolve` now defaults to `true`. A successful run logs:

```text
R350_RESOLVE copied src=017f5000/2816 dst=00c3e000/2560 rect=0,0+640x583 ctl=00000003
```

and reports:

```text
r350_rejected=0
r350_aaresolve=1
r350_resolved=1
```

This removed the desktop/wallpaper strides from the Chess window and made the
board surface appear. See
`docs/evidence/r350-2026-10-04/chess-after-resolve-before-detile.png`.

### 2. The remaining corruption is present before the resolve

The resolved destination is a byte-for-byte copy of the source region, and a
VRAM dump showed the same bad colors in the 704-pixel source target. Do not add
a color permutation to `r350_resolve_copy()`. The resolve is no longer the
color or texture problem.

### 3. Chess textures are combined macro- and micro-tiled

The important texture register value is:

```text
TX_OFFSET = ...000c
```

Bit 2 enables macro tiling and bit 3 enables ordinary micro tiling. The scene
uses `TX_FORMAT1 = 0x0008860c`, an identity RGBA component selection. Examples
captured from the live guest:

```text
128x128 wood: raw a4 73 38 ff
32x32 sprite: raw ff ff ff 00
```

Those are naturally RGBA: brown wood with alpha 255, and transparent white in
the sprite background. The former staging code applied
`r350_vram_component_byte()` and turned them into `ff 38 73 a4` and
`00 ff ff ff`. That explains the magenta board, cyan labels, opaque sprite
backgrounds, and incorrect piece colors.

For this combined-tile upload path, detile first and use the byte selected by
the texture component directly. Keep the existing reversal for WindowServer's
linear/ARGB resources; its measured `ff 42 6b ad` wallpaper texel is correctly
staged as `42 6b ad ff` by the old path. A global channel-order change will
regress the desktop.

### 4. A first detile is a major improvement, but its page shape is incomplete

The current code adds `r350_texture_macro_micro_offset()` and detects the
combined layout as `r350_rgba_tiled`. This changes Chess from the missing/blue
striped surface into a recognizable, correctly colored board with pieces:

- row-major experiment:
  `docs/evidence/r350-2026-10-04/chess-first-detile-row-major.png`
- Morton experiment:
  `docs/evidence/r350-2026-10-04/chess-detile-morton.png`
- empirical bit-permutation experiment currently in the source:
  `docs/evidence/r350-2026-10-04/chess-detile-permutation.png`

These are experiments, not the final address formula. The coordinate labels
remain doubled/garbled and some wood patterns retain a tile cadence.

## The next correction

The current helper assumes a 32x16-pixel, 2 KiB macro page. That assumption is
wrong for the narrow textures used by the board labels.

Sixteen consecutive 32x32 textures were observed at addresses such as:

```text
0x00d17000
0x00d19000
0x00d1b000
0x00d1d000
...
```

The stride between allocations is **0x2000 (8 KiB)**. A 32x32 RGBA image is
only 4 KiB, so the extra 4 KiB is layout padding, not image data. AMD's
R3xx/R5xx layout guide gives a 32-bit macro block as **64x8 pixels = 2 KiB**.
At a 32-pixel pitch, each 8-row band still occupies one 2 KiB macro page:

```text
ceil(32 / 64) * ceil(32 / 8) * 2048 = 8192 bytes
```

That exactly matches the observed allocations. This is stronger evidence than
the visual ranking of the earlier 32x16 candidates.

### Implement this next

1. Change combined-tile page geometry to:

   ```text
   macro width   64 pixels
   macro height   8 pixels
   macro bytes 2048
   micro width    4 pixels
   micro height   2 pixels
   micro grid    16 x 4 per macro page
   ```

2. Change the source read size to include macro padding:

   ```c
   bytes = DIV_ROUND_UP(tp, 64) * DIV_ROUND_UP(th, 8) * 2048;
   ```

   The present `DIV_ROUND_UP(tp, 32) * DIV_ROUND_UP(th, 16) * 2048`
   truncates every 32x32 texture at 4 KiB and reads only half its allocation.

3. Start with this page selection:

   ```text
   macro_x = x / 64
   macro_y = y / 8
   macros_per_row = ceil(pitch / 64)
   macro_offset = (macro_y * macros_per_row + macro_x) * 2048
   ```

4. Derive the 16x4 micro-tile ordering from the full 8 KiB resources. Do not
   keep the current `y2,y0,y1` permutation merely because it reduced total
   variation in a truncated 4 KiB capture. That optimization was performed on
   incomplete textures.

5. A useful first candidate is row-major micro-tile order within the 64x8 page,
   followed by the documented 4x2 micro-tile pixel order. If it is still
   scrambled, search permutations using all 16 glyph alpha planes together.
   The correct mapping must produce one coherent `a`-`h` or `1`-`8` glyph per
   32x32 image, not two repeated partial glyphs.

The full VRAM dump from the last isolated run is currently at:

```text
/tmp/pe9800/codex-permute-vram.bin
```

It is 128 MiB and intentionally was not copied into Git. Verify texture base
addresses for that exact run before slicing it. If the temporary file is gone,
repeat the dump through the monitor:

```text
qom-set /machine/peripheral/gpu0 x-vram-dump /tmp/r350-vram.bin
```

## Relevant source locations

Line numbers will move; search these names in
`/Users/adam/Developer/poweremu-qemu/hw/display/ppc_mac_gpu.c`:

| Symbol or text | Purpose | Status |
|---|---|---|
| `r350_resolve_copy` | Clips and copies the 704-pixel target into the 640-pixel IOSurface | Proven fix |
| `x-r350-aa-resolve` | Enables the resolve path; currently defaults on | Proven for Chess |
| `r350_texture_macro_micro_offset` | Experimental combined-tile address calculation | Replace 32x16 with 64x8 |
| `r350_rgba_tiled` | Selects the Chess combined-tile RGBA path | Keep, then broaden only with evidence |
| `r350_scene_texture_once` | Bounded capture helper | Diagnostic; remove before final cleanup |
| `POWEREMU_R350_SCENE_CAPTURE` | Enables Chess texture captures | Diagnostic |
| `R350_SCENE_TEXTURE` | Prints raw and staged first texel | Diagnostic |

The working tree also contains extensive earlier instrumentation from the
existing Radeon investigation. Preserve it until the final image is verified.

## Reproduction and validation

The normal meaningful R350 device arguments include:

```text
ppc-mac-r350-probe,id=gpu0,vgamem_mb=128,
x-r350-bridge-aic=on,
x-r350-linear-render=on,
x-r350-decode-rs=on
```

`x-r350-decode-rs=on` is required. Omitting it produces hundreds of rejected
Chess draws and invalidates the test.

The test scripts used during this investigation live under `/tmp/pe9800` and
are disposable. `app-codex.sh` uses an isolated binary, monitor port 4934, SSH
port 2298, and display socket `sock-codex` so another local Radeon test does not
kill or replace its VM. Recreate that isolation if concurrent work is still
running.

After each change:

1. Build with:

   ```text
   ninja -C /Users/adam/Developer/poweremu-qemu/build-r350 qemu-system-ppc64
   ```

2. Boot Tiger with the arguments above and launch `/Applications/Chess`.
3. Confirm the log contains exactly one successful `R350_RESOLVE copied` line.
4. Confirm performance reports `r350_rejected=0` and `r350_resolved=1`.
5. Compare against:
   `docs/evidence/r350-2026-10-04/chess-reference-9200.png`.
6. Require all of the following before calling the texture fix complete:
   - smooth, correctly colored light and dark board squares;
   - correctly colored light and dark pieces;
   - transparent sprite backgrounds;
   - one legible coordinate glyph at each board position;
   - no desktop or Finder pixels in the Chess surface;
   - no row wrapping at the right edge;
   - zero rejected Chess draws.

## Cleanup after the image matches the 9200 control

1. Remove or gate the unconditional `R350_RESOLVE` `fprintf()` calls. Keep
   bounded failure diagnostics if they remain useful.
2. Remove `r350_scene_texture_once`, `POWEREMU_R350_SCENE_CAPTURE`, raw texture
   dumps, and `R350_SCENE_TEXTURE` logging.
3. Keep comments that explain the 704-to-640 resolve clipping and the final
   proven tile geometry. Remove comments describing abandoned permutations.
4. Run `git diff --check` and rebuild.
5. Run a Tiger desktop/Finder smoke test to prove the existing linear ARGB
   texture path did not regress.
6. Run the 9200 Chess control. The new code is inside the R350 path, but this
   is still the quickest regression check.
7. Then test Leopard and one additional OpenGL application before treating the
   address formula as general R350 behavior.

## Primary references

- AMD, *Radeon R3xx 3D Register Reference*, especially `TX_FORMAT1`,
  `TX_OFFSET`, and `RB3D_AARESOLVE_*`:
  https://www.x.org/docs/AMD/old/R3xx_3D_Registers.pdf
- AMD, *R5xx Acceleration Guide v1.5*, sections 2 and 4 for micro- and
  macro-block dimensions and texture memory layout:
  https://www.x.org/docs/AMD/old/R5xx_Acceleration_v1.5.pdf

The register reference confirms `TX_OFFSET` bit 2 is macro tiling, bits 4:3 are
micro tiling, and bits 1:0 are endian control. The acceleration guide defines a
32-byte 32-bit micro block as 4x2 pixels and a 2 KiB 32-bit macro block as
64x8 pixels.

---

# Resolution (5 October 2026)

**Chess renders correctly on the 9800.** All six acceptance criteria below are
met: `docs/evidence/r350-2026-10-04/chess-9800-complete.png`.

The handoff's first diagnosis was right and is kept: `RB3D_AARESOLVE` was the
missing scene-to-window step, and clipping it to the destination row is what
put the board in the window. Independently confirmed here — every striped run
has zero `R350_RESOLVE copied` lines and every correct run has exactly one.

**The second diagnosis was half right, and the half that was wrong is the
interesting part.** `r350_rgba_tiled` decided two things at once:

1. the byte order — read these texels straight rather than reversing them;
2. the address — detile them.

The first is correct and stays. The second is not: **these surfaces are
linear**, whatever `TX_OFFSET` bits 2 and 3 say.

The handoff proposed replacing the 32x16 macro page with 64x8. That was done
and the result was better — correct wood colour, correct pieces — which is why
it looked like progress. It is not the answer. Three page geometries were
tried (32x16, 64x8, and one whose micro rows follow the surface pitch) and
every one of them produced the same doubled glyph, because the page shape was
never what was wrong.

Reading the texels straight out of a VRAM dump settles it without another
build, and both tests point the same way:

- a 32x32 label glyph is a legible numeral read linearly, and two half-width
  copies under any of the detilings:
  `docs/evidence/r350-2026-10-04/glyph-detile-candidates.png`
- the 128x128 wood is clean grain read linearly, and carries a cross-hatch
  tile cadence when detiled:
  `docs/evidence/r350-2026-10-04/wood-linear-vs-detiled.png`

That cadence is the "some wood patterns retain a tile cadence" the handoff
noted as unexplained, and the doubling is its "two repeated partial glyphs".
Both were the detiling itself.

The 8 KiB stride behind each 32x32 glyph is real, and the handoff's arithmetic
for it is right — but it is the allocation granularity, not the pixel layout.
Nothing needs to read the padding.

### What changed

| Change | Status |
|---|---|
| `r350_resolve_copy` clipped to the destination row | Codex's, kept |
| `x-r350-aa-resolve` defaults on | Codex's, kept |
| `r350_rgba_tiled` selects the straight byte order | Codex's, kept |
| `r350_rgba_tiled` also detiled the address | **Removed** — linear |
| `bytes` rounded up to whole macro pages | **Removed** — rows |
| `r350_texture_macro_micro_offset`, `r350_micro_order` | **Deleted**, nothing calls them |

The byte order half has independent support: adding the
`r350_vram_component_byte()` reversal back to this path
(`POWEREMU_R350_TILEDSWAP=1`, kept and defaulted off) destroys the wood grain
and adds banding, exactly as the handoff predicts a global channel change
would.

### Verified

- Smooth, correctly coloured light and dark board squares.
- Correctly coloured light and dark pieces.
- Transparent sprite backgrounds — the opaque white blocks are gone.
- One legible glyph per board position, `a`-`h` and `1`-`8`:
  `chess-9800-glyphs-legible.png`.
- No desktop or Finder pixels in the Chess surface; no row wrapping.
- `r350_rejected=0`, one `R350_RESOLVE copied`.
- Tiger desktop, Finder and wallpaper unchanged — the linear ARGB path did not
  regress.
- 9200 Chess control re-run and unchanged.

### Still open

- The window surround is black on the 9800 where the 9200 shows the grey
  window background. The board is identical; this is the area around it.
- Warcraft III on the 9800.
- Leopard, and a second OpenGL application, before treating any of this as
  general R350 behaviour.
