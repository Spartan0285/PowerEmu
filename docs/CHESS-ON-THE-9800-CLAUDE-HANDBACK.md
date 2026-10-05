# Radeon 9800 handback to Codex — 5 October 2026

Picks up from `CHESS-ON-THE-9800-CODEX-HANDOFF.md`. Everything below happened
after that checkpoint.

**Net result: one regression of mine found and disabled, one new diagnostic
that earned its keep, one recommendation to close a checkpoint item, and three
of the user's four reported symptoms still unexplained.** Nothing here is
finished.

## Repository state

- QEMU `/Users/adam/Developer/poweremu-qemu`, branch `release-0.3.3-rc`
- HEAD unchanged: `5dff14f1ca7`
- **All work still uncommitted**, yours and mine together: 11 files, +532/−53.
  `git diff --check` is clean; graphics tests
  (`tests/poweremu/run-r300-metal-test.sh`) pass on the current build.
- Two docs committed in the PowerEmu repo: `R300-FOG-REFERENCE.md` and this
  file.

## 1. Checkpoint step 1 (point size) — recommend closing, not fixing

Those 330 `invalid programmable point size` rejections are **degenerate
no-ops**, the possibility your checkpoint flagged. Measured, not argued:

| `GA_POINT_SIZE` | size | state | verdict |
|---|---|---|---|
| `1b001464` | 576x435 = exactly half of 1152x870 | depth off, `mask=0` | accepted, writes nothing |
| `1b000000` | 576x**0** | depth test+write on, z=1.0, `mask=0` | rejected — the 330 |

Both have **colour writes masked off entirely**, so neither can paint. Every
write to `GA_POINT_SIZE` is a full 32-bit write (`POWEREMU_R350_POINT=1` logs
them with their access size), so we are not sampling a half-updated register.
The desktop compositor uses the same idiom: full-screen size, one point draw,
reset to a 0.5px minimum. And `3D_CLEAR_ZMASK` (PM4 0x32) is already
implemented and clears depth properly.

I briefly believed these were a lost depth clear and that it explained the
accumulated rain. The `mask=0` finding killed that. Do not force the zero to
one.

## 2. Fog — implemented, correct in the maths, **disabled by default**

### What is right, and measured

`POWEREMU_R350_FOG=1` logs the state. Warcraft's menu gives:

```
GB_SELECT=00000001  fog_select=1        -> C1A, vertex colour 1's alpha
GA_FOG_SCALE  = bf800000 (-1.0)
GA_FOG_OFFSET = 3f800000 (+1.0)
FG_FOG_BLEND  = 00000001  fn=0 (LINEAR)
FG_FOG_COLOR  = 02c,050,02c
```

So `f = saturate(C1A * -1 + 1) = 1 - C1A`. Three things we had wrong, now
documented in `R300-FOG-REFERENCE.md`:

- **`f = 1` means NO fog.** Opposite of the obvious reading. Alpha is never
  fogged.
- **The factor does not come through RS at all.** Finding no fog state in
  `RS_COUNT` proves nothing; `GB_SELECT` (0x401C) names the source and
  `GA_FOG_SCALE`/`GA_FOG_OFFSET` (0x4294/0x4298, IEEE floats) map it.
- **`FG_FOG_FACTOR` (0x4BC4) applies only to the CONSTANT function.** Reading
  zero from it on a LINEAR draw is meaningless. It cost me time.

The colours are 10-bit (÷1024), so `02c,050,02c` = RGB (0.043, 0.078, 0.043) —
the dark green stormy sky the 9200 shows.

Both Mesa drivers disable the fixed-function FG block and lower fog into the
fragment program; ours does the same, emitting the blend after the shader
output and before the alpha test, which is where FG sits in the pipeline.

### Why it is off

With fog on, Warcraft's **menu panel, frame and logo render as solid black
rectangles** with only the text surviving. That is what `f = 0` against a black
fog colour paints. Those draws take their factor from colour 1's alpha, and for
a UI quad that alpha is an ordinary opaque `1.0`, so the blend reads "fully
fogged" and flattens them.

**The open problem is telling a fog source from an ordinary colour.** The
hardware's FG block gets its fog value on a path that bypasses RS; we only have
the vertex colour. Until that is resolved, fog costs more than it gives.

`POWEREMU_R350_FOG=1` turns it back on for continued work. Everything else
about it is in place and tested.

### Five failed attempts, because the constraints are not obvious

Each was caught only by the **per-reason** rejection census. A single bundled
counter would have hidden all five.

| attempt | failure | cost |
|---|---|---|
| `REQUIRE` the fog colour be rasterised | it usually is not | 237,134 draws |
| claim a spare fragment input index | an input is pre-loaded into a *declared temporary* | 369,975 draws |
| set `vp->varying_mask` only | the Metal backend requires `fp->input_mask == vp->varying_mask` **exactly** (`ppc_mac_gpu_r300_metal.m:299`) | 94,061 draws |
| dedicated `vfog` varying, `%.9g` literals | `%.9g` drops the decimal point, so a scale of exactly −1.0 emitted `-1f`, not a float literal | shader compile failure |
| fog applied to UI draws | the factor is wrong there | black rectangles |

**The fog source cannot live in the `v0..vN` register file at all.** It now
rides in a dedicated `vfog` varying declared in both shader structs, outside
both masks. If the vertex program does not define that output it comes through
as zero, which reads as "no fog".

The rule that is now structural rather than remembered: **there is no `REQUIRE`
anywhere in the fog path.** An unreachable source silently disables fog for
that draw. A draw without its fog is wrong; a draw that never happens is worse.

## 3. New diagnostic: texture inventory (both cards)

```
qom-get /machine/peripheral/gpu0 x-tex-inventory
```

Every distinct surface sampled — address, dimensions, pitch, format, VRAM/AGP,
and the number of draws that used it. Keyed on the surface, not the draw, so it
stays small. **Both the 9200 and the 9800 fill it**, which makes the working
card a reference instead of a screenshot.

This is what the checkpoint was missing: success on the 9200 had only ever been
judged by eye and by a draw count.

Reference captured at the Warcraft menu, saved at `/tmp/pe9800/inv-9200.txt`:

```
9200: 242 surfaces, 769,723 draws   (229 fmt=6, 13 fmt=0)
9800: 229 surfaces,  40,193 draws   (216 a60c/aa0c, 13 124000)
```

**It immediately disproved "textures are missing".** Normalising for the 9800
having run 19x fewer draws, both cards sample the same surface shapes in the
same proportions — 256x32 busiest, then 256x256, 512x128, 128x128. That is what
redirected me to my own fog regression.

Two traps when reading it:

- The **9200 composites the desktop with 2D blits**, so its windows never enter
  the inventory. The 9800 composites in 3D, so they do. Diffing raw lists shows
  phantom "9800-only" surfaces (1147x608 etc.) that are just desktop windows. I
  mis-diffed on this first.
- Draw counts need normalising by total draws before comparing.

## 4. Still open — three of the user's four symptoms

Tested by the user on a build with fog off:

1. **Very slow, and the UI stops responding** (Cmd-Q and force-quit both fail;
   QEMU sits at ~400% CPU and starves the app's event loop — not a crash).
   **Concrete lead, untested:** there is an in-place texture path
   (`guest_source` → `gpu_view`, `ppc_mac_gpu.c:8720`) gated on
   **`x-r350-direct-vram`**, which neither the harness nor the app passes.
   Without it every draw does a `g_malloc`, a full texel read and a per-texel
   four-channel conversion — for a 256x256 surface sampled 10,464 times. The
   9200 inventory shows it sampling almost everything from `vram` in place. I
   started a run with `x-r350-direct-vram=on` but **never got a number**; it was
   still loading. The flag is experimental and may trade correctness for speed,
   so check its census and image, not just the frame rate.
2. **Bands at the bottom of the screen** — desktop content repeated
   horizontally below the game's output. This is a **scan-out pitch** problem,
   the same shape as the Chess striping, not a missing texture.
3. **Scene mostly black** with the logo and version number correct.

The logo rendering correctly is the one confirmed improvement: it is what the
fog-off build fixed.

## 5. Chess — untouched

Still black behind the board. Your `POWEREMU_R350_RESOLVE_TEX=1` diagnostic
remains **unexercised**. Your own dump already narrows it: background bytes
`00 00 00 00` and a board sample `bf b8 97 65` — alpha `0xbf`, not opaque — so
the surface carries real alpha and the question is how WindowServer composites
it, not the resolve and not another channel permutation.

## 6. Environment notes that will bite

- **The harness leaks a ~200 MB qcow2 overlay per run and never reaps them.** I
  cleared 108 of them, 22 GB, after `/tmp` hit 90% full. Keep
  `base-tiger.qcow2` (38.8 GB) and `base-kexts.img`.
- **Warcraft's load is CPU-bound for several minutes with a flat draw counter.**
  That looks exactly like a stall and is not one — check process CPU before
  concluding anything. I read it as a freeze and built an A/B to chase a
  non-existent regression.
- **Reaching the menu is slow and variable**: same build, same arguments, 2,843
  draws one run and 129,457 the next. Poll the draw count; do not use a fixed
  wait.
- Background waiters cap at 30 minutes, shorter than a cold boot plus the load.
- `app-qmp.sh` is flaky at launching: one run sat on the Finder's Applications
  list and produced 427 draws.

## 7. Switches added since the checkpoint

| Switch | Purpose |
|---|---|
| `POWEREMU_R350_FOG=1` | enable the fog blend (off by default) and log the fog state |
| `POWEREMU_R350_POINT=1` | point-size draws, their full state, and every `GA_POINT_SIZE` write with its access size |
| `POWEREMU_R350_SHADER_ON_ERROR=1` | dump the generated MSL once when Metal rejects it |
| `x-tex-inventory` (qom property) | the texture inventory, both cards |

`POWEREMU_R350_SHADER_ON_ERROR` deserves a note: four fog attempts failed
against a compiler that had been reporting an exact line and column in a source
nobody had printed. Ten lines of dump resolved it on first look. Build the
diagnostic before the second attempt, not the fifth.
