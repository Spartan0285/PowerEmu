# Harmony: status, and everything tried on 27 September 2026

**Harmony is not working.** This is an account of a full day's work on it, what
was measured, what was fixed, and what is still broken. It is written so that
someone picking it up does not repeat any of it.

---

## 1. The symptoms, as they stand

From the last screenshots, with the overlay up:

```
Guest 0 fps    Window 0 fps    Draws 0/s    Emulator 25% of a core
windows 3   copies 3/s   frames 2.6/s   oldest 37.8s   2 over 2s
held back:  covered 0   nothing drawn 6   settling 0   stale pass 0   too new 0
            pointer 16/s (7 dropped)   clicks 28
```

1. **Surface contamination.** Windows show pixels that belong to other windows,
   or holes where a neighbour overlaps them.
2. **Two windows both showing a blue selection.** Only the focused window
   should; a background window's selection is grey. The back window is showing
   a picture of itself from when it *was* focused, and has not been re-read
   since — `oldest 37.8s`.
3. **The focused window takes 10 seconds or more to update.** Clicking an icon
   and waiting ten seconds to see it highlight. Sometimes it never updates
   until something else disturbs the screen.
4. **Losing and regaining focus is worse.** Clicking away and back can take
   15 seconds before the window is live again.

None of these is fixed.

---

## 2. Why this is hard at all

The emulated card hands over **one screen image**. The guest composites all of
its windows into it, and that is the only thing PowerEmu gets. Every guest
window shown on this Mac is therefore a **crop of that one image**, and a crop
is only correct if nothing is drawn on top of that window at that moment.

Two consequences follow, and most of the day was spent discovering how far they
reach:

- **A covered region cannot be read**, because the pixels are not there. Not
  "hard to read" — absent.
- **Whether a window may be read at all** depends on the guest's answer about
  what covers what, and that answer arrives over a separate channel, later than
  the pixels it describes.

---

## 3. What was measured and ruled out

Each of these cost hours and none of them is the problem. They are recorded so
nobody looks again.

| Suspected | Measurement | Verdict |
|---|---|---|
| The occlusion hit test is wrong | Asked the guest directly what is drawn at the middle of two overlapping windows | **Correct every time** |
| The pointer is mis-mapped | Overlay: `off -0,+0` | **Exact** |
| Clicks are not arriving | Added a counter: 28 presses counted | **Arriving** |
| The display pipeline is slow | Guest window flipping colour 10x/sec → host `fps=10.0` | **Tracks exactly** |
| The dirty-page log misses writes | `PE_GPU_FULL=1` compares the whole screen every tick | **No change** |
| The QEMU refresh is not running | Instrumented: `calls=61 in 2s` | **30 Hz, correct** |
| The agent is saturated | Instrumented: 5–17 ms per pass against a 42 ms budget | **Not saturated** |
| VRAM holds whole windows we could read instead | Dumped the compositor's source surfaces | **No — see §5** |

---

## 4. What was fixed, with numbers

These are real fixes and they are in. They did not add up to a working feature.

| Fix | Before | After |
|---|---|---|
| **Dock tiles reported as windows.** The Dock's *icons* are separate windows at level **21**; the agent only filtered level 20. Eighteen 64x64 phantom windows, each given a proxy, raised and hit-tested. | guest had 3 windows, agent reported **21**, host held **18** proxies | **3 / 3 / 3**, and occlusion cost fell from 16.6 ms to 5.7 ms |
| **Pixels and occlusion described different moments.** The answer authorising a read arrives after the frame being read, so a just-covered window still counted as clear. Now the frame is held back and read against the answer that describes it. | **38.3%** of a covered window was its neighbour's colour | **0.0%** |
| **The copy path had deadlocked.** A focus change invalidated the occlusion, and focus is reported *after* it, so `gen` ran permanently one ahead and nothing was ever copied. | `fps=0.0`, every window frozen | in sync |
| **Windows abandoned for ever.** Three failed capture attempts and a window never got a complete picture again — so any overlapped part stayed a hole permanently. | permanent | retried every 30 s |
| **Partial copies never healed.** Only redrawn regions were re-read, so a window that stopped drawing kept whatever was in it. | permanent | clear windows re-read whole once a second |
| **Occlusion recomputed when nothing moved.** Dozens of window-server round trips per report to re-derive an identical answer. | **12.5%** of the guest's CPU | recomputed only on a change |
| **Unthrottled pointer events.** Every host mouse-move became a USB tablet report; a click queued behind them. | 60–120/s | coalesced to 60 Hz, presses jump the queue |
| **Stale Dock icons.** Tile helpers survive an unclean exit and keep their icons for ever; bundles accumulate. | **11** stale bundles | cleared at startup |
| **A false alarm that cost hours.** `<< STARVED: something else has the CPU` fires whenever the emulator uses under 70% of a core — i.e. whenever the guest is *idle*. It was on screen constantly and was quoted as evidence more than once. | always on | requires the host to be busy too |

---

## 5. The hard finding: VRAM does not hold whole windows

The obvious escape from cropping the finished screen is to read window content
from earlier in the pipeline — under Quartz Extreme the compositor is our own
emulated card, so its source surfaces should be the windows themselves.

Measured with `PPCGPU_WINDOWS=2 PPCGPU_WINCAP=1`, which follows every copy back
to its source and writes the whole of it out:

- Window backing stores **do** exist in VRAM, separate from the screen, with
  pitch matching each window's width rounded up.
- A **fully covered** window's store **stops changing** — sixty stores, none
  changed in ten seconds while a Terminal printing the time sat under a
  TextEdit window.
- A **partly covered** window's store holds **only the visible part**. Terminal
  at x=120..620 under a window starting at x=400 produced a store 320 px wide,
  covering x=120..400 exactly.

**So reading before composition returns the same pixels as cropping the screen.**
The complete window lives in the application's own backing store in system
memory, which the card never sees. This route is closed.

---

## 6. CORRECTED 27 Sep, evening — section 6 below was wrong

Working through `HARMONY-IMPLEMENTATION-PLAN.md` Phase 1 with a proper
instrument overturned the conclusion recorded below. **Read this first; §6 is
kept only so the mistake is not repeated.**

The instrument was the fault. A test window drew a frame number in pixels so
content progression could be read back — but the blocks were drawn along the
window's **top edge**, which spent the whole run underneath another window. The
measurement was reading a covered strip, saw nothing move, and I concluded the
card was not noticing the guest's drawing. Moving the blocks to the bottom edge
changed the answer completely.

### What is actually true (measured)

| Case | Result |
|---|---|
| Window redrawing 10x/sec, focused | host tracks at **~8.5–10 frames/sec** |
| Same, `PEREFRESH found` | **20–21 per 2s** — matches the guest exactly |
| Window changing once per **5 seconds** | tracked, every tick, no lag |
| **Background** window behind another, both animating | **both track at ~10.2/sec** |
| Keystroke to visible change (`sendkey` → pixels in the copied surface) | **median 44 ms, p95 146 ms**, 0 misses in 25 |

So the display pipeline, the damage path, the copy path and the input path are
all sound in every case that could be synthesised — including the two that were
blamed hardest, background windows and rarely-changing content.

**The claim in §6 that "sweeping the whole screen thirty times a second finds
nothing" was an artifact of the broken instrument.** With `PPCGPU_SCANOUT=1`
the scanout reports thousands of changed rows per second while a window
animates.

### What is still not reproduced

The reported 10–15 second stall on a real Finder window has **not** been
reproduced. An attempt to measure it with arrow keys was invalid: a guest-side
`screencapture` taken before and after was **byte-identical**, so the guest
never responded to those keys and the "misses" measured key delivery, not
display. Any figure from that run is void.

The open question is therefore narrow and specific: **what does a real
application window do that a synthetic one does not?** That is where to look
next, not at the display path.

### Phase 1 findings against the plan

- **Finding B (conditional flush before scanout) — not supported so far.**
  `PPCGPU_FLUSH_ALWAYS=1` makes the drain unconditional; with a valid
  instrument, synthetic windows track correctly either way. The condition does
  skip constantly (`flush(cond=0 skip=60)`), so it may still matter for cases
  not yet reproduced, but it is not the cause of anything measured.
- **Finding A (the trusted frame is not synchronized) — stands.** It copies
  whatever screen is current when a report arrives; nothing establishes they
  describe the same guest composition. The 38.3%→0% result is real but is not a
  proof of correctness.

## 6b. Phase 1 result: the cause is Harmony's own mask gate, not the card

A source review (file:line evidence, independent of my measurements) plus the
measurements above locate it.

### The display path cannot be the cause — there is a hard 500 ms ceiling

`ppc_mac_gpu.c:2171-2173` counts refreshes and resets at 15, and `:2241` takes
the cheap incremental branch only when that counter is non-zero. So **one
refresh in fifteen — twice a second at 30 Hz — unconditionally byte-swaps the
whole framebuffer and calls `dpy_gfx_update_full()`** (`:2281-2290`). There is
no flag or early return in between. If a pixel is in VRAM at `disp.offset`, the
host hears about it within ~500 ms no matter what the dirty tracking does.
**Any multi-second stall is therefore either the guest not drawing, or
downstream in Harmony's own gating.** §7 below is retired as a theory, not just
as a measurement.

### Quartz Extreme does not composite through the 3D pipe here

From the project's own `/tmp/gpu_blit_paths.log` for a Harmony run:
`SEP=533 MMIO=471 BBM=0 PAINT=0 HD=0`. All 493 parsed MMIO blits target
`dst off=0x0 pitch=6912` — the scanout. Zero PM4 BITBLT, zero HOSTDATA. Tiger's
compositor presents **only** through the MMIO 2D BLT engine, which runs on the
CPU into VRAM and calls `ppc_mac_gpu_dirty()` (`:3963`). That path is covered.
Also `r200_direct_enabled()` defaults **on** (`:4730`), so every shadow
render-target site is `!r200_direct_enabled()` dead code in production.

### The actual gate

`HarmonyWindows.swift:1167`:

```swift
if regions != nil, isDesktop(sb, sbpr, sw, sh, gx + px, gy + py, pw, ph) { continue }
```

`isDesktop` samples the alpha published by `pe_harmony_alpha()`
(`poweremu-display.c:224-249`), which is `0xff` only where the GPU's tile grid
says `PE_AREA_WINDOW`. Alpha 0 means the region is **skipped**, `wrote` stays
false, and `snapshot()` returns the *previous* copy. The window keeps what it
had.

That gate applies **only when `regions != nil`** — the partial/damage path. A
**fully uncovered** window takes the once-a-second whole-window re-read, which
passes `regions: nil` and bypasses it entirely. Hence:

- fully uncovered → tracks perfectly ✔ (every synthetic test above)
- **partly covered → subject to the gate → can stay stale indefinitely** ✔ (the
  reported symptom, and the overlapping windows in the screenshots)

### Two producer bugs behind it — both now fixed

1. **The tile classifier matched the desktop surface by address alone**
   (`ppc_mac_gpu.c:702-717`). One address serves several stores at different
   pitches — the file says so itself where it dumps them, and keys the filename
   on both — so in one captured run **166 window copies** shared the
   wallpaper's base at pitches 256/512/768/1024 and were all reclassified as
   desktop. A desktop tile publishes transparent; a window on transparent tiles
   is one whose pixels are never read. **Fixed:** the classifier now requires
   address *and* pitch to match.
2. **Mask-only changes were never published** (`poweremu-display.c:199`). The
   colour comparison returned before `pe_harmony_alpha()`, so a tile that had
   just become a window was never published as one while the pixels under it
   happened not to change. **Fixed:** a change in the mask generation now
   publishes on its own account; counted as `maskonly=` in `PEREFRESH`.

### Not yet proven

The fixes build and run. **They are not yet shown to change the symptom.**
`maskonly=0` so far, meaning the new path has not fired in testing, and an
attempt to reproduce the stall on a partly covered window gave 10/10 misses but
is **invalid**: a guest-side screen capture showed Cmd-Tab returned focus to the
Finder, so the window never actually defocused. That number is void.

**The next step is a valid reproduction of the covered-window case.** Without
one there is no way to tell whether the two fixes above matter.

## 6c. The symptom was not a delay at all — windows were being drawn transparent

The overlay settled this, and it was not what anyone was looking for. During a
reported "10-20 second delay on the focused window", every counter read clean:

```
windows 3   copies 9/s   worst 0 frames behind   oldest 0.0s   0 over 2s
held back: covered 0  nothing drawn 1  settling 0  stale pass 0
           too new 0   mask-refused 0
```

Nothing was held back by anything. The pixels were current, copied every frame,
nought frames behind — and the windows on screen were **see-through**, the host
desktop legible through a Finder window's body.

Measured directly, from the windows' own copied surfaces:

| surface | opaque | transparent |
|---|---|---|
| test window, before | **18.5%** | **81.5%** |
| test window, after | **96.9%** | 3.1% |

**Cause.** The alpha published with the guest's screen marks which parts of it
are a window, so that Harmony can leave the desktop out. That alpha was being
carried along by the per-window copy, so a window whose tiles the card had
misjudged was drawn transparent. A window that is invisible is indistinguishable
from a window that never updates — which is what it was reported as, for most
of a day, while every timing measurement came back healthy and nobody believed
them.

**Fix.** A proxy surface is already cropped to a rectangle the guest has told us
is a window. Inside that rectangle the mask has nothing to add, so the copy now
asserts what is already known and writes alpha opaque. The mask still does its
job where it is needed — deciding what of the whole screen is desktop.

Focused-window input-to-visible after the change: **median 77 ms, p95 151 ms,
0 misses in 25.**

**Lesson for the next person.** Three separate times a measurement was thrown
out because the instrument, not the system, was at fault: a frame counter drawn
under another window; a 6.6-second "latency" that was the test harness's own
socket drain; an arrow-key test where a guest-side screen capture proved the
guest never responded. Check the instrument first, and keep a control that does
not share the path being measured.

## 6d. Phase 1 completion report (format required by the implementation plan)

**1. Hypothesis tested.** That a boundary between guest drawing and host
presentation was dropping or delaying completed images — the plan's Finding B
naming the conditional `r200_flush_at()` before scanout as the suspect.

**2. Source / build / configuration.** App and emulator both from
`~/Developer/PowerEmu` and `~/Developer/poweremu-qemu`, uncommitted working
trees (both carry the day's changes; nothing was reset). Guest: Mac OS X
10.4.11, agent 2.6. Diagnostics added for this phase: `PPCGPU_REFRESH`,
`PPCGPU_SCANOUT`, `PPCGPU_FLUSH_ALWAYS`, `POWEREMU_HARMONY_DUMP=all`,
`POWEREMU_HARMONY_AUTO=<seconds>`, and a frame-number mode in `pecolor`.

**3. Experiments.** Traced guest draw → scanout → `dpy_gfx_update` →
`pe_gfx_update` → transport → host copy, reading an actual frame number out of
the pixels at the host end rather than counting callbacks.

**4. Measurements.**

| | |
|---|---|
| Ordinary desktop (Harmony off), guest drawing 10/s | `found=20 per 2s` — **exact** |
| Display refresh rate | 30 Hz (`calls=60 per 2s`) |
| Harmony, window drawing 10/s | tracked ~10/s |
| Harmony, window changing once per 5 s | tracked, every tick |
| Harmony, background window behind another | tracked ~10.2/s |
| Focused window, input to visible | median 77 ms, **p95 151 ms**, 0 misses / 25 |
| Foreign pixels, two flat-colour windows | 38.3% → **0.0%** |
| Window surface opacity | 18.5% → **96.9%** opaque |

**5. Acceptance criteria.**

| Criterion | Target | Result |
|---|---|---|
| Completed frame → host presentation | p95 ≤33 ms | **not measured separately** — the figure below includes guest execution, which the plan requires be reported apart |
| Controlled click → visible | p95 <100 ms | **FAIL** — 151 ms (77 ms median) |
| Foreign pixels in opaque interiors | zero over 10,000 ops | **partial** — zero in the scenario tested, nothing like 10,000 operations |
| Torn / mixed-generation frames | zero | **not proven** — the frame-number decoder rejects malformed patterns and never saw one, which is weak evidence |
| Animation pause >100 ms | none | **fail/unclear** — p95 151 ms implies occasional pauses over budget |
| Static content not recaptured merely for age | required | **FAIL — and it is my code that breaks it** (below) |
| Mask-only changes published | required | **implemented, not observed** — `maskonly=0` so far |
| Lifecycle: resize, destroy, reconnect, ID reuse | no stale generations | **untested** |

**6. Remaining uncertainty, and the next decision.**

Two of my own changes conflict with the plan and should be reconsidered rather
than defended:

- The **once-a-second whole-window re-read** of any uncovered window is exactly
  the "forced recapture solely because the image is old" the plan forbids. It
  was added to heal contamination that the trusted frame and the opacity fix
  have since addressed at their source. It is probably now unnecessary, and it
  is certainly the wrong shape.
- `worstAge` in the overlay measures **time since last copy**, which the plan
  says explicitly is not freshness: an unchanged static image is not stale
  because it is old. `worst N frames behind` (content sequence) is the honest
  number and is now shown beside it; the age figure should go once nobody is
  relying on it.

The p95 of 151 ms is over the 100 ms budget, but the measurement cannot yet
separate guest execution from added display latency, so it is not yet known
whether the emulator or the display path owns the overage. That separation is
the next measurement, and it is a prerequisite for any tuning.

### Where the latency goes — measured separately, as the brief requires

The app can now checksum the whole guest screen as it arrives, before Harmony
cuts it into windows, so a keystroke can be timed against both boundaries:

| | median |
|---|---|
| key → guest screen arrives at the host (guest + card + transport) | **91 ms** |
| key → window visible (the same, plus Harmony's copy) | **93 ms** |
| **Harmony's own share** | **2 ms** |

**Harmony is not what makes the virtual Mac feel slow.** It adds about two
milliseconds. The click-to-visible budget of 100 ms is missed in the emulator,
drawing the thing in the first place, and no amount of work on the copy path,
the occlusion, the masks or the transport will recover it. That is a separate
project — the emulator's own speed — and it should be named as such rather than
pursued through Harmony.

(The figure above carries the checksum's own cost; without the instrument the
same measurement is median 45 ms, p95 146 ms. The *split* is the point, not the
absolute.)

### Later measurements, same session

| | |
|---|---|
| Window surface opacity, all windows | **100%** (was 18.5% on the test window) |
| Focused window, input to visible | median 45 ms, p95 146 ms, 0 misses / 25 |
| Eight window moves | **8/8** followed exactly, stayed fully opaque |
| Ordinary desktop (Harmony off), guest at 10/s | `found=20 per 2s` — exact |

Two changes made after the Phase 1 report, both to satisfy the brief rather
than to chase a symptom:

- **New surfaces start opaque.** A fresh surface is all zeroes and zero alpha
  is see-through, so the covered parts of a newly appeared or resized window —
  which can never be read, there being nothing on screen to read — showed the
  host's desktop through the middle of a guest window.
- **The whole-window re-read is driven by evidence, not a clock.** It used to
  fire once a second regardless, which is exactly the forced recapture the
  brief forbids. It now fires when the window's circumstances actually changed
  (the geometry generation moved) and the parts that could not be read before
  can be read now.

### Corrections to the implementation plan, verified against source

- The `dpy_gfx_update` sites cited for Phase 1 task 6 are at **1865, 1885,
  2277, 2290, 10963**, not 1833/1853/2202/2215/10888. (Those line numbers came
  from this document and were wrong.) 1865 and 1885 are non-32bpp paths and are
  unreachable at 32 bpp.
- **Finding B is closed.** `g_r200_written` survives commit and is cleared only
  after `waitUntilCompleted` (`ppc_mac_gpu_metal.m:6703`), and every 2D blit
  flushes on overlap first, so nothing outstanding remains at refresh time.
  Combined with the unconditional full sweep every 15th refresh
  (`ppc_mac_gpu.c:2171/2281`), **no escape from that condition can produce a
  multi-second stall.** Phase 1 tasks 7 and 8 are answered and can be struck.
- The shadow-render-target machinery the plan discusses around
  `metal_flush_r200()` is **dead code in production**: `r200_direct_enabled()`
  defaults on (`ppc_mac_gpu.c:4730`) and every SRT site is guarded on its
  negation.
- Plan line 103 (`pe_gfx_update()` can return before applying the alpha mask)
  is accurate but **belongs in Phase 1, not Phase 2**: the alpha it fails to
  publish is what gates per-window pixel absorption, so it was a live
  correctness bug in the current path, not a masked-desktop concern.
- The tile-classification producer the plan refers to without naming is
  `pe_area_of` / `pe_area_of_copy` / `pe_harmony_mark`, `ppc_mac_gpu.c:643-845`,
  fed from the single call site `pe_window_saw_blit()` at `:3988`.

## 7. Superseded — where the 10-second delay was thought to be

This is the most important unfinished thread.

With a Finder selection changing **once a second**, and the QEMU display
refresh confirmed running at **30 Hz**:

```
PEREFRESH calls=61 found=0 in 2s
PEREFRESH calls=61 found=1 in 2s
PEREFRESH calls=61 found=0 in 2s
```

`found` is how often the refresh saw any change. Zero or one, against two
actual changes. And with `PE_GPU_FULL=1`, which compares **the entire screen on
every one of those 61 ticks**:

```
PEREFRESH calls=58 found=0 in 2s   (x6)
```

Sweeping the whole screen thirty times a second finds **nothing**. That rules
out the sweep interval and the dirty-page log together, and leaves one
explanation: **the guest's drawing is not in the VRAM being compared.** The
renderer holds it in its own Metal surface, and the display path only notices
when something else happens to force that surface back to VRAM. That is what
takes seconds.

The device's own comment says as much, and was read past repeatedly:

> *it cannot be turned on until every path that writes VRAM marks what it wrote*

**Caveat, stated honestly:** frames still trickle through at 1–5 fps, so damage
reaches the host by some path the counter above does not capture. The mechanism
is identified; the full picture is not. The `dpy_gfx_update` call sites in
`ppc_mac_gpu.c` (lines 1833, 1853, 2202, 2215, 10888) need tracing before
writing the fix.

---

## 7. What to do next, in order

1. **Make the renderer announce what it drew.** It knows the exact rectangle at
   the moment it draws it, which is strictly better than comparing memory
   afterwards, and free. Until this is done, nothing else about responsiveness
   matters — the host cannot show a change it is never told about. This is in
   `ppc_mac_gpu.c` / `ppc_mac_gpu_metal.m`, **not** in Harmony.
2. **Give every window a complete picture.** A window that first appears after
   Harmony starts never gets the raise-and-capture pass, so its covered parts
   are blank rather than stale-but-correct. That is the visible "contamination"
   in most screenshots.
3. **Then, and only then**, revisit the staleness of background windows. A
   background window showing its own older picture is correct behaviour given
   §2; a background window showing a *blue* selection is that older picture
   being too old.

---

## 8. Measurement tools built today — keep them

- **`PEGATE`** in the log and in the performance overlay, once a second:
  `copies/s`, `frames/s`, `oldest`, and which of five gates is holding a copy
  back, plus `pointer sent/dropped` and `clicks`. A screenshot of the overlay
  is enough to tell most of these failures apart.
- **`guest/tools/pecolor R G B X Y W H Name [flip_ms]`** — a window of one flat
  colour, optionally flipping. Contamination becomes a count: every pixel that
  is not that window's colour came from somewhere else.
- **`POWEREMU_HARMONY_DUMP=1`** — writes each proxy's surface to
  `/tmp/peproxy-<id>.bin` (header `w h bpr guestx guesty`, then BGRA).
- **`PPCGPU_REFRESH=1`** — how often the display refresh runs and how often it
  finds anything.
- **`PPCGPU_WINDOWS=2 PPCGPU_WINCAP=1`** — the compositor's source surfaces,
  written out whole.
- **`~/pw/pewindows`** — every on-screen window with level, alpha, rect; with
  two arguments, hit-tests a point.
- **`POWEREMU_HARMONY_AUTO=<seconds>`** — turns Harmony on by itself, so any of
  this can be scripted.

## 9. A note on method

Most of the day was spent changing things on a hypothesis and asking whether
they felt better. That found some real bugs by accident and introduced at least
two (the copy-path deadlock, and partial copies that never healed). Every
genuine advance came from a measurement: the phantom Dock windows, the 38.3%
contamination figure, the 30 Hz refresh finding nothing. The overlay exists so
that the next round starts from a number.
