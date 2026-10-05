# Chess on the Radeon 9800 — what was adopted, and everything tried

Status as of 4 October 2026. The 9200 (`ppc-mac-gpu`) renders Chess correctly and
is the control. On the 9800 (`ppc-mac-r350-probe`) the board, pieces and labels
now reach the window; what remains is texture tiling and colour.

**Read `CHESS-ON-THE-9800-CODEX-HANDOFF.md` first** — it supersedes this
document wherever the two disagree, and it carries the current next step. This
file is the record of what was tried and ruled out from the other side of the
same investigation.

This records what was taken from cat7's work, what has been fixed, what has been
ruled out *by measurement* rather than by reasoning, and what is still open — so
that none of it has to be rediscovered.

---

## 1. What was adopted from cat7

Source: `https://github.com/cat7/qemu` (remote `cat7up`), `mac99` branch. cat7
has a working 20,045-line `ati-radeon9800` device with its own 2D/3D engines and
a GL backend. Credit for the shader decoders below is theirs.

### Taken

Six files, 2,618 lines, copied in unmodified and built into `ppc-mac-gpu` via
`hw/display/meson.build`:

| File | What it is |
|---|---|
| `hw/display/ati_r350_pvs.{c,h}` | R300/R350 vertex-shader (PVS) instruction decoder |
| `hw/display/ati_r350_pvs_glsl.c` | PVS → GLSL translator |
| `hw/display/ati_r350_us.{c,h}` | Fragment-shader (US) decoder |
| `hw/display/ati_r350_us_glsl.c` | US → GLSL translator |

These were chosen because they have **zero coupling to cat7's device**: they take
a register dump and produce a shader, so they drop into our tree without the ROM,
the PCI model, or the GL backend coming with them.

**They are currently a cross-check only.** Our vertex translator calls
`r300_pvs_analyse` and compares its own decode against cat7's; disagreements are
reported. Nothing consumes cat7's output yet. Switching our decoders out for
theirs is a live option but has not been done — see §6.

### Not taken

cat7's `ati-radeon9800` device itself. It needs a real card ROM we do not have,
and it replaces rather than extends the card the rest of PowerEmu is built on
(Harmony, the performance overlay, the two-card setup, the 9200 path). The
decoders were the part that could be lifted without acquiring a ROM — which was
the explicit question asked, and the answer turned out to be yes for the shader
translators and no for the device.

---

## 2. Bugs found and fixed

Draw rejections went from **828 to 1** over this work. Every one of these was our
check being stricter than the hardware, not the guest doing something odd.

1. **Sampler addressing** — only one address mode was accepted. Decoded properly:
   `0 = Repeat`, `2 = ClampToEdge`, `6 = ClampToZero` (`r300_address_mode`).
2. **Vertex array stride 0** — rejected as malformed. A non-advancing array is
   legal (every vertex reads the same element). Now accepted:
   `array_stride[a] == 0 || array_stride[a] >= array_count[a]`.
3. **Three PVS field widths**, all wrong against AMD's *R5xx Acceleration* v1.5:
   source type is bits `1:0` (we read 5 bits), destination type bits `11:8`,
   destination offset bits `19:13` — bits 18 and 19 had been treated as reserved.
4. **Dual-math instructions** — `PVS_DST_DUAL_MATH_OP` (bit 28) means the
   instruction replaces `PVS_SRC_OPERAND_2` with a second math op. This was first
   waved through on the reasoning that the bit looked inert; the next gate
   (`PVS_SRC_REG_ALT_TEMPORARY` = 3) proved it was not. Reverted and implemented
   from the spec, including `ME_RECIP_SQRT_FF` (zero maps to zero, not infinity)
   and `ME_LIGHT_COEFF_DX`.
5. **Blend factors** — the whitelist accepted exactly one pair, `ONE /
   ONE_MINUS_SRC_ALPHA` (premultiplied over). Chess asks for `SRC_ALPHA /
   ONE_MINUS_SRC_ALPHA`, so **every blended draw in Chess was being thrown away**.
   The factors are now decoded.
6. **Interpolator routing** — was a whitelist of literal register patterns.
   `x-r350-decode-rs=on` enables a general decoder. Without it, Chess still loses
   825 draws to `interpolator_routing`; this flag is **required** for any valid
   9800 test run (see §5, "ways to get this wrong").
7. **Depth and stencil** — depth texture cache with LRU, `r300_dss` depth/stencil
   state, stencil attachment, and the **pipeline cache key extended to include the
   attachment set** (without it, two draws with different attachments collided on
   one cached pipeline).

---

## 2a. Chess now renders — the striping is gone

**Superseded in part by `CHESS-ON-THE-9800-CODEX-HANDOFF.md`; read that for the
cause.** The board, all 32 pieces, the labels, shadows and bevelled frame now
draw in the right places in the right window. What remains is texture tiling
and colour.

**What the striping was: a missing `RB3D_AARESOLVE`.** Chess renders into a
padded 704-pixel-pitch target and the driver issues one R350 resolve into the
640-pixel IOSurface WindowServer uses. `r350_resolve_copy()` rejected it
because the scissor described the 704-pixel source while the destination row
was only 640 wide; real hardware clips at the destination row. With that
clipped, the scene reaches the window.

**A correlation I drew and had wrong.** I had recorded that striping tracked a
single `"primitive assembly"` rejection — `r350_rejected=1` striped,
`0` correct, six runs for six. It does correlate, but not causally: the resolve
fix landed in this shared working tree between those runs, so the rejection
count was a before/after marker for someone else's change. Checking the runs
for `R350_RESOLVE copied` separates them cleanly — 0 resolves in every striped
run, 1 in every correct one. Two investigations sharing one tree need a
discriminator that is not just "it got better".

**Measurements from this side that still stand**, each ruling something out:

- The scene is written to guest VRAM correctly and completely. Measured inside
  the device (`POWEREMU_R350_VRAM=1`): staging and VRAM non-zero counts are
  equal on every draw. This also settled the contradiction below — the earlier
  0%-non-zero reading was a bad address.
- Chess's window backing store contains the **complete, correct window** when
  read at its true pitch, so the guest's surface flush works.
- Texture pitches are honoured: every texture has `pitch_en=1` and used pitch
  equal to declared pitch.
- Chess's draws use `US_OUT_FMT=0x1b01` with the **identity** output swizzle,
  so the output permutation at `ppc_mac_gpu.c:7966` is not the colour bug.
- Adding the `r350_vram_component_byte()` reversal to the tiled texture path
  (`POWEREMU_R350_TILEDSWAP=1`) destroys the wood grain and adds banding —
  independent agreement with the handoff that this path takes its bytes
  straight, and that the reversal must stay for WindowServer's linear
  resources.

**Three dead ends, all the same mistake** — a probe that never ran, read as
evidence of absence:

1. `POWEREMU_R350_WIN` sat inside `if (getenv("POWEREMU_R350_OUT"))`. Run
   without `R350_OUT` it logged nothing, briefly taken to mean "no draw covers
   the Chess window". The compositor draws it.
2. That probe's `scene_started` flag was itself set inside another log's env
   gate, silencing everything again.
3. Log caps filled with boot-time wallpaper twice (the desktop composites from
   boot). Address-range filters caught the tiles too; gating on "the
   application has started drawing" is the filter that works.

A probe that prints nothing is not a result until you have seen it print
something.

**Switches added, all off unless set:** `POWEREMU_R350_VRAM`,
`POWEREMU_R350_WIN=x,y`, `POWEREMU_R350_PITCH`, `POWEREMU_R350_TEXFMT`,
`POWEREMU_R350_SYNC`, `POWEREMU_R350_WAITSYNC`, `POWEREMU_R350_TILEDSWAP`, and
`qom-set /machine/peripheral/gpu0 x-vram-dump <path>`.

That last one is the one to reach for first. Every trigger tied to the device's
own activity fired at the wrong moment — Chess finishes drawing before its
window is ever composited, so a dump on a draw caught the desktop with no
window, three runs running. Having the harness ask for the dump at the same
instant as the screenshot is what made the right pixels and the wrong ones
comparable.

## 3. What is proven to work

- **The scene renders correctly.** The chess board was dumped straight out of
  guest VRAM and is correct — geometry, texture, lighting:
  `docs/evidence/r350-2026-10-04/chess-scene-in-vram.png`.
- **The compositor works.** It samples window backing stores and paints them onto
  the framebuffer, and that path is observable and correct.
- 9200 control data for comparison:
  `docs/evidence/r350-2026-10-04/chess-reference-9200.png`, and Warcraft III at
  44 fps / 1.2M draws.

So the renderer is not the problem. The problem is the step between "scene is in
VRAM" and "window shows the scene".

---

## 4. Ruled out — by measurement, not by argument

Each of these was a plausible theory that a built probe killed. They are listed
so nobody pays for them twice.

| Theory | How it was killed |
|---|---|
| Scan-out / present pitch rewrite | `POWEREMU_R350_NOPITCH` disables it. Image unchanged. |
| Missing or dropped command packets | Packet census: only NOPs are skipped. |
| One of the blit paths mishandling the copy | All five instrumented; none runs for Chess. |
| The compositor itself is broken | It is not — it demonstrably samples backing stores onto the framebuffer. |
| **Batch coherency** (newest) | `POWEREMU_R350_SYNC=1` flushes the Metal command buffer after **every single draw**. Image pixel-identical. See below. |

### The coherency theory, and why it is dead

It was a good theory. The device used to render synchronously, so "the engine is
idle" was always true and `WAIT_UNTIL` / `RBBM_STATUS` could answer without doing
anything — there is a comment in the source still saying exactly that. The Metal
path batches: a draw sits in an uncommitted command buffer, so VRAM does not hold
the pixels yet. A guest that waits for idle and then reads the surface with the
CPU — which is what a surface flush does when the driver does not use the blitter
— would read stale memory, and nothing in the device would see that read.

It explained the striping, it explained why the 9200 is fine (its surface flush
is 377 MMIO blits, which go through the device and order correctly), and it
explained why nothing reads the scene buffer.

It is still wrong. Flushing after every draw changes nothing. Two switches were
added and kept, since they are cheap and the question recurs:

- `POWEREMU_R350_SYNC=1` — flush after every draw (sledgehammer).
- `POWEREMU_R350_WAITSYNC=1` — flush where the guest asks the engine to be idle
  (the honest version, if it is ever needed).

---

## 5. Where it actually stands

Two measurements, both from today, that any next step has to fit:

1. **No 3D draw samples the scene surface.** Filtering every draw by texture
   offset `0x17f5000` returns nothing. On the 9200 the equivalent step is 377
   MMIO blits; the 9800 issues none.
2. **No 3D draw covers the Chess window at all.** `POWEREMU_R350_WIN=780,400`
   logs every draw whose scissor contains a point inside the Chess window.
   Zero hits.

Together these say the Chess window's pixels are **not painted by any device
operation we can see**. The guest is compositing that region with the CPU. If so,
the only thing that matters is whether guest VRAM holds the right pixels when the
CPU reads it — and the renderer does write back:
`ppc_mac_gpu.c:8512` copies the staging buffer into VRAM at `offset` (with the
byte-order swizzle) on every non-direct draw.

### The open contradiction — resolved

The device's own census says a Chess scene draw wrote **1,045,528 non-zero bytes**
to `0x17f5000`, and the write-back above should put them in VRAM. But a
`pmemsave` of `0x88000000 + 0x17f5000` during a live run read **0% non-zero**,
while an earlier run at the same address read 64% non-zero and contained the
complete board.

Do not build on either reading until this is settled. Specifically: **verify the
VRAM BAR base for that run before trusting the dump.** A stale address has
already caused one wrong conclusion in this work — an all-zero dump was reported
as proof that a write-back was lost, when the buffer had simply moved, and the
staging buffer is seeded from the same VRAM, so all-zero cannot by itself tell
"lost write-back" apart from "rendered nothing".

### Ways to get a 9800 test run wrong

- Omitting `x-r350-decode-rs=on` from the card arguments. Rejections jump from 1
  to 826 and the run is meaningless. One run was wasted this way today.
- Reading results from a build that failed — check the build output first.
- Log caps filling with boot-time draws before the interesting phase. Tighten the
  filter rather than raising the cap.

---

## 6. Still open

1. **Texture tiling** — see the handoff: the combined macro/micro tile page is
   64x8 pixels / 2 KiB, not the 32x16 currently assumed.
2. **Colour.** The wood is pink where it should be brown, the labels cyan.
   Measured so far: Chess's scene draws use `US_OUT_FMT=0x1b01` with the
   **identity** output swizzle, so §6's old suspicion of the output
   permutation at `ppc_mac_gpu.c:7966` is wrong — ruled out. Its textures are
   128x128, `swz=0,1,2,3`, and take the tiled path, whose byte order is also
   confirmed right. The desktop composited in the same frame is correct, so
   whatever it is, it is specific to these textures or to the shader that
   samples them.
3. **Warcraft III on the 9800** — badly corrupted. 9200 reference captured.
4. **Whether to switch to cat7's decoders** as the real consumer rather than a
   cross-check (§1).

Not for the public release: per standing instruction, neither the 9800 nor the
9200 work ships in the release build.
