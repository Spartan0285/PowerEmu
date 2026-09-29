# Harmony

*Rootless windows: the guest's windows on this Mac's desktop, without its desktop.*

Last updated 2026-09-27.

---

## 1. What it is meant to be

Parallels calls it Coherence, VMware calls it Unity. You turn it on and the
virtual Mac's desktop disappears; its windows stay, sitting among the host's
own windows, in the host's Dock, with the host menu bar showing the guest
application's menus. You click a guest window and it comes forward like any
other window. You drag it and it moves. You minimise it and it goes into the
host Dock.

That is the target. "EXACTLY like Coherence" is the standing bar.

---

## 2. How it is built

Three pieces:

**`guest/src/PEAgent.m` — PowerEmu Agent**, a small Cocoa app installed into
`~/Library/PowerEmu` in the guest and started as a login item. It is the only
thing that knows what the guest's windows actually *are*. It talks to the host
over a slirp `guestfwd` to `10.0.2.100:7700`, a line protocol: `WINDOWS`,
`OCCLUDE`, `FOCUSED`, `MENUS`, `MENUITEMS`, `APPICON`, `MINIMIZED` out;
`HARMONY`, `RAISE`, `RAISEHARD`, `ACTIVATE`, `MOVEWINDOW`, `MENUPICK`,
`QUITAPP`, `DROPFILES`, `RESOLUTION` in. Currently version **1.7**.

**`app/Sources/PowerEmu/HarmonyWindows.swift`** — the host side. One borderless
`NSWindow` proxy per guest window, each backed by **its own pair of
IOSurfaces**, each showing a crop of the guest framebuffer.

**`hw/display/ppc_mac_gpu.c` + `ui/poweremu-display.c`** — the emulated card
publishes the whole guest screen into one shared-memory surface. In Harmony
the parts that are not windows are made transparent.

### The shape of the problem

**There is one framebuffer.** The guest composites all of its windows into a
single screen image, and that is the only thing the card hands over. Harmony
has to take that one image apart again into per-window pictures. The guest's
window server will not hand over a window's backing store — on Tiger there is
no API for it that we can reach.

So every guest window's proxy is a **crop of the shared screen**, and a crop is
only correct if nothing is drawn on top of that window at that moment. The
whole design question for Harmony is: *which windows may be read right now?*

Everything below follows from that one constraint.

---

## 3. What works

- **Window tracking.** Frames, appearance and disappearance, at 24 Hz.
- **Per-window proxies with their own surfaces.** Adam's own proposal, adopted
  after the shared-surface approach kept flashing the desktop through gaps.
- **Focus and raising, per window, not per application.** A click raises the
  one window you clicked (`SetFrontProcessWithOptions` with
  `kSetFrontProcessFrontWindowOnly`, plus `AXRaise` inside the app).
- **Menu projection.** The focused guest application's menus appear in the host
  menu bar, including submenus, marks and dashes.
- **Minimise.** Goes into the host Dock and comes back
  (`performMiniaturize()` — `miniaturize()` is a no-op on these proxies).
- **Dock tiles with the real guest icons.** macOS gives one Dock tile per
  process, so each guest application gets a tiny host helper process
  (`helper/main.swift`, managed by `GuestDock.swift`) carrying its icon.
  Launched with `Process` directly; `NSWorkspace.openApplication` silently
  refuses the second bundle.
- **Host → guest drag and drop.**
- **Dragging a proxy moves the guest window** and no longer shows the desktop
  behind it.
- **Networking inside Harmony** (Captain Polliwog loads real pages with images
  and stylesheets).

---

## 4. The long fight: occlusion

This is where nearly all the difficulty has been, and all of the visible bugs.

### 4.1 `CGSGetWindowGlobalClipShape` — dead end

The obvious answer. The window server knows exactly what part of each window is
visible. On Tiger the call exists and **returns an empty region for every
window**. Everything looked completely covered, so nothing was ever refreshed.

### 4.2 Window-list order — wrong, and confidently so

Next attempt: take `CGSGetOnScreenWindowList`, treat it as front-to-back, and
say a window is covered by anything earlier in the list.

This was wrong, and the write-up claiming otherwise was wrong. **The list is
grouped per connection**, i.e. per application, and the order across
applications means nothing. Adam disproved it with a screenshot: Finder,
Polliwog, TextEdit, Finder — interleaved in a way no global order produces.

### 4.3 Hit testing — the right idea

`CGSFindWindowByGeometry` (found via `dlsym`) answers "which window is drawn at
this screen point?" That is a direct question about the real stack, with no
ordering assumption. This is the approach still in use.

### 4.4 …but sampled wrongly, three times

**First:** one sample at the middle of each overlapping pair, and when the
server named some *third* window, the whole pair-intersection was recorded as
covered. Windows reported 2–4% visible when they were really 45–58% visible, so
almost nothing was ever refreshed.

**Second:** record the intersection with the window that *actually* won the
point, rather than the pair being tested. Much better, and this is what shipped
for a while.

**Third — the bug behind the corruption Adam has been seeing.** When a third
window won the sample point, the pair being tested was *abandoned*. The
question "is j drawn over i?" was simply never answered. So a window really
sitting on top of another went unrecorded, the one underneath was judged clear,
and it got read out of the shared framebuffer **with its neighbour's pixels
baked into it**. Every surface ended up carrying pieces of the others.

That was made far more visible by commit `f7ea7fc`, which started copying
*every* window nothing was covering, instead of only the focused one. That
change was necessary — without it a progress bar in a background window, or a
Chess piece highlighting, never updates — but it made the copy path depend
entirely on the occlusion answer being right, and the occlusion answer had a
hole in it.

**Fixed in agent 1.7 (2026-09-27).** Each overlapping pair is now sampled at up
to nine points until the server names *one of the two*, which settles which is
on top; since the stack is a single order, that one answer holds across the
whole overlap. A pair that never settles — every sample owned by something
PowerEmu was not told about, a screensaver being the known case — is taken as
covering both ways, so the windows keep their last good copy instead of
absorbing something unknown.

### 4.5 Staleness: a raise moves nothing

A second, independent cause of the same symptom, fixed the same day.

Occlusion answers were only treated as out of date when some window's
*rectangle* changed. But **bringing a window forward changes what covers what
without moving anything at all**. Click a window, it rises, every rectangle is
identical, the host decides its occlusion data is still current — and the
windows that were just covered are read on an answer that predates the raise.
Each of them quietly keeps a piece of the window that rose over it.

The generation counter is now bumped on focus change as well, so nothing is
copied again until the guest has re-answered.

### 4.6 Settling

Separately: during a drag or resize the guest's reported geometry and the
framebuffer contents are briefly inconsistent, which showed as desktop visible
behind a dragged window. Probation used to be counted in *reports* — which
broke the moment the report rate went from 12 Hz to 24 Hz, because the same
count became half the time. It is now measured in seconds: 0.5 s after a
resize, 0.25 s after a move or a coverage change, 0.75 s after we ask the guest
to move a window.

---

## 4a. Measured, 27 September: VRAM does not hold whole windows

A review proposed that the way out of the architectural limitation is to stop
cropping the finished screen and read window content from somewhere earlier in
the pipeline. Under Quartz Extreme the compositor is *our* emulated card, so
the obvious somewhere is the source of the copies it makes onto the screen. The
device already notices those copies (`pe_window_saw_blit`), so it was a small
step to follow each one back to its source address and write the whole of that
source out: `PPCGPU_WINCAP=1`, alongside `PPCGPU_WINDOWS=2`, dumps every
tracked store to `/tmp/pewin-<addr>-<pitch>.ppm`.

Three things came out of it, and together they close the idea.

**Window backing stores really are in video memory, separate from the screen.**
Dumping one produced a legible Terminal window and two Finder windows sitting in
memory at once, nothing to do with the framebuffer. The pitch of each store
matches its window's width rounded up — a 647-wide window at pitch 2816 (704
px), a 1082-wide one at 4352 (1088 px), the screen itself at 6912 (1728 px).

**A covered window's store stops changing.** With a Terminal printing the time
once a second, completely covered by a TextEdit window, none of sixty tracked
stores changed over ten seconds. What is in video memory is a cache the
compositor fills when it draws, not a backing store the application keeps
current.

**And a partly covered window's store holds only the visible part.** This is
the one that settles it. Terminal at x=120..620 with TextEdit over everything
from x=400: its source surface came back 320 px wide, covering x=120..400
exactly, and the dump shows the left strip of the window and nothing else. The
store is always sized to the visible region.

So reading from before composition gives exactly what cropping the screen
gives. It is the same pixels by a longer route. The complete window lives in
the application's own backing store in system memory, which the card never
sees.

That leaves three honest options for covered content, and none of them is a
crop:

- Accept it. Clean and stale is what the fallback gives, and with the occlusion
  work below it is at least reliably clean.
- A guest-side component loaded into each application that can draw its own
  windows into a shared buffer — real work, and the only route that would make
  Tiger behave like Coherence.
- Leopard, where `CGWindowListCreateImage` exists (10.5+) and can capture a
  single window by ID. Untested here, and an application that stops drawing
  when hidden would still hand back a stale image.

## 4b. Solved, 27 September: the pixels and the answer now describe the same moment

The corruption that survived every occlusion fix had nothing to do with the
occlusion being wrong. Checked directly: asking the guest what is drawn at the
middle of two overlapping windows returns the right window every time.

**The guest's answer always describes a frame that has already gone.** It works
out what covers what and sends it; by the time it arrives the card has moved
on, and the frame in hand is newer than the answer supposed to authorise
reading it. In that gap a window that has just been covered still counts as
clear, so it is read -- and where it is covered, what is read is the window on
top of it. The mistake lasts one report. It is permanent anyway, because that
region stays covered afterwards and is never read again.

Measured with two windows of flat colour (`guest/tools/pecolor`, plus
`POWEREMU_HARMONY_DUMP=1` which writes each proxy's surface to
`/tmp/peproxy-<id>.bin`): **38.3% of the window underneath was its neighbour's
green**, sitting there unchanged while the window was fully visible.

The fix is to keep the frame back. When an answer arrives the screen as it
stands is put aside, and every window is read from that held frame -- pixels
and answer from the same moment, at the cost of showing the guest about a
fortieth of a second late, which nobody can see.

| | before | after | after, then raised |
|---|---|---|---|
| foreign pixels in the red window | **38.3%** | **0.0%** | **0.0%** |
| its own colour | 36.9% | 64.2% | 94.3% |

Two other faults were found by the same measurements and fixed:

- **The copy path had deadlocked.** `gen` ran permanently one ahead of
  `occlfor`, so "the answer still describes the screen" was never true again
  and nothing was copied at all -- `fps=0.0`, every window frozen. Cause: a
  focus change was invalidating the occlusion, and focus is reported *after*
  the occlusion in each report. It never needed invalidating; the guest
  hit-tests live, so its answer already contains the raise.
- **Partial copies never healed.** They re-read only what the guest has just
  drawn, so a window that stops drawing keeps whatever is in it for ever. A
  window nothing covers is now re-read whole once a second.

Still true, and not fixable this way: where a window is covered there is
nothing to read, so those parts hold whatever was last captured -- and a window
that first appears *after* Harmony is on never gets the raise-and-capture pass,
so its covered parts stay blank. That is the limit recorded in 4a, not
corruption.

## 5. Still open

**Background-window liveness (`absorb`), off by default.** The idea: a window
that is covered could still be refreshed from the parts of it that *are*
visible. It fails when something PowerEmu was never told about covers the
screen — the screensaver made every window absorb black. The 1.7 occlusion
change makes the unknown-window case detectable, so this is worth revisiting.

**Partial copies are ON by default** — corrected 27 Sep; this section
previously said they were off, naming `liveMasking`. The flag that actually
chooses partial over whole-window copying is `liveAbsorb`
(`HarmonyWindows.swift`), default **on** (`POWEREMU_HARMONY_PARTS != "0"`).
`liveMasking` is a different flag and is off. This matters because the partial
path is the one subject to the `isDesktop` mask gate. Copying only the visible
sub-rectangles instead of whole windows would be much cheaper and would let
covered windows stay live. The first attempt wrote into both buffers of the
double-buffered pair and never invalidated on a move, so windows degenerated
into collages with no intact copy left to fall back on. Whole-window copies
only, for now.

**2D compositing runs at 10–13 updates/s** against 30 for 3D content. Quartz 2D
windows feel less alive than they should.

**Guest → host drag and drop is not built.** Host → guest works. The other
direction needs the guest to notice a drag *leaving* a window, and on Tiger a
drag is not visible outside the application that started it.

**Shadows.** Aqua draws a window's shadow outside its own frame, onto whatever
is behind it. Hit testing says that region belongs to the window underneath, so
the shadow is copied into it. Subtle, but it is there.

**The menu bar and Dock are excluded** from the window list by level, so they
are also excluded from occlusion. A window sliding under them can absorb them.

**Agent restarts used to silently kill Harmony** — the guest came back not
knowing it had been in Harmony. The host now re-arms it on reconnect.

---

## 6. Performance, and two measurements worth keeping

**The "1.8 fps ceiling" was a measurement error.** It was taken against an idle
guest — Harmony drags move the *proxy*, not the guest window, so the guest had
nothing to redraw — and against AppleScript's own rate. Real figures: guest
30 fps, window updates 28–29/s.

**AltiVec is not the answer.** Measured contribution to the update path: 0.2%
for compositing, 0.3% for web rendering. The time is not in the pixel loop.

**Dirty-row damage is on**, and the earlier note here saying it was disabled
behind `PE_GPU_DIRTY=1` was wrong — stale comments in the device said so and
this document copied them. What the code actually does: rows come from two
sources unioned together, the card's own record of where it drew *and* the CPU
dirty-page log (much of Mac OS X, all the text, is drawn by the processor
writing straight into VRAM and never passes through the card's drawing paths),
and the whole screen is swept twice a second anyway to heal anything both
sources miss — the Metal renderer reaches VRAM through a shared buffer whose
pages are never marked. `PE_GPU_FULL=1` abandons all of it and sweeps every
tick; that is the first thing to try if part of the screen will not repaint.
Damage on the card's record alone did once halve the frame rate, which is where
the old claim came from.

---

## 7. Where to look

| | |
|---|---|
| Host proxies, surfaces, occlusion, input | `app/Sources/PowerEmu/HarmonyWindows.swift` |
| Menu projection | `app/Sources/PowerEmu/HarmonyMenus.swift` |
| Dock tiles | `app/Sources/PowerEmu/GuestDock.swift`, `helper/main.swift` |
| Agent, protocol, window reporting, hit testing | `guest/src/PEAgent.m` |
| Agent install | `guest/src/PEInstaller.m` → `~/Library/PowerEmu` |
| Screen transport, transparency | `ui/poweremu-display.c` (poweremu-qemu) |
| Framebuffer, damage | `hw/display/ppc_mac_gpu.c` (poweremu-qemu) |

Debug: `POWEREMU_HARMONY_DEBUG=1` writes the pointer mapping and per-click
geometry to a file. The app's own log is stdout.

Updating the agent in a running guest, without reinstalling Tools:

```bash
cd guest && ./scripts/build.sh && cd build && ditto -c "PowerEmu Agent.app" - \
  | ssh tigeremu 'cd ~/Library/PowerEmu && rm -rf n && mkdir n && ditto -x - n
      && killall "PowerEmu Agent"; rm -rf "PowerEmu Agent.app"
      && mv n/"PowerEmu Agent.app" . && open "PowerEmu Agent.app"'
```
