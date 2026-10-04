# Chess as a 9800 control experiment — 3 October 2026

The method asked for: render something 3D on the **9200**, where the driver
stack is known to work, keep that image as the control, then run the identical
setup on the **9800** and compare.  Chess.app is a good subject: it is on every
Tiger install, it is OpenGL, and a wrong frame is obvious to the eye.

## The control — `control-9200-chess.png`

Tiger 10.4.11, one CPU, `-device ppc-mac-gpu,vgamem_mb=128`, firmware
`openbios-smp`, 1680x1050 (the guest's remembered mode; the harness asks for
1280x1024 and Tiger overrides it).  Chess launched over ssh with `open -a
Chess`, captured with the HMP monitor's `screendump`.

It is correct in every respect that matters: wood-grain board in proper
perspective, 3D pieces shaded and casting shadows, rank and file labels
legible, menu bar and Dock composited.  Quartz Extreme and OpenGL are both
working.

## The 9800 — `9800-stale-scanout.png`

Identical harness, `-device ppc-mac-r350-probe,vgamem_mb=128,
x-r350-bridge-aic=on,x-r350-linear-render=on`, firmware `openbios-r350`
(each firmware only knows its own card -- a 9200 on the R350 firmware, or a
9800 on the SMP one, logs `Output device screen not found` and never gets a
frame buffer at all).

A flat blue backdrop with a few scanline fragments.  No menu bar, no icons, no
window.  **Three screendumps minutes apart were byte-identical** (md5
`183bf6c4432676e3b7160b17a9ed5d1a`), so the scanout is not merely wrong, it is
frozen.

## Why that image is not evidence of a 9800 rendering bug

Everything else says the guest is healthy and drawing:

| | |
|---|---|
| guest | ssh responsive, `WindowServer`=2, `Finder`=1 |
| driver | `ATIRadeon9700` bound, matched and active |
| device counters | `r350_draws=217`, `r350_rejected=0`, `pm4_35=217`, `frames=51`, `texture_bytes=101543824` |

Nothing is being rejected, a hundred megabytes of texture has been uploaded,
and the frame counter is advancing.  And the same device under the real
PowerEmu app, on another machine, shows a working desktop whose windows can be
dragged.

The difference is how the frame is collected.  The app runs the GPU with
`-object poweremu-display` and reads frames off that socket into its own Metal
renderer; this harness runs `-display none` and asks the console for a
screendump.  `x-r350-direct-vram=on` was tried and changed nothing.

**So the measurement is the thing that is broken here, not necessarily the
9800.**  Comparing Chess frames needs a capture path equivalent to the app's.
Until that exists, no screenshot taken this way should be read as evidence
about the renderer -- which is the same trap as the reference capture in
`RADEON-9200-RETROSPECTIVE.md`, where a reading from the wrong source
manufactured plausible work.

## Reproducing

`/tmp/chess.sh` on the Studio takes `<tag> <gpu-device-args> <fwdir>
<monitor-port> <ssh-port>` and boots an overlay on `tiger-base.qcow2`.

---

# Second session, same night: the measurement is fixed, and Chess now has numbers

## The harness was the whole of the "blue screen"

With `-display none` and no `-object poweremu-display`, QEMU registers no
DisplayChangeListener, so nothing drives `graphic_hw_update()` at refresh rate.
`screendump` calls it once, which is not enough for the R350 path.  The effect
is worse than a bad screenshot: **the guest itself stops submitting draws.**

| | frames | r350_draws |
|---|---|---|
| `-display none`, no listener | 45 | 200 |
| same device args, listener attached | 11429 | 24359 |

`-vnc` with no client attached fails the same way.  With a listener attached,
the plain HMP `screendump` works again too.

`tools/pedisplay-capture.py` is a stand-in for the app on the
`poweremu-display` socket: it takes the shm fd over `SCM_RIGHTS`, tracks
damage, and writes PNGs.  Verified against the 9200, where its frame and a
simultaneous `screendump` differ in **0 of 1,764,000 pixels**.

**The 9800 composites a correct Tiger desktop** through it -- menu bar, Dock,
Finder windows, icons, wallpaper, clock advancing.  Every "9800 is broken"
screenshot above this line was an artefact of how it was captured.

## What Chess actually needs, measured

Chess launches on the 9800 and runs, and the screen then **freezes**: identical
raw pixels across six snapshots, `damage` stuck at 11343, and the last damage
rectangle `(0, 14, 1680, 16)` -- the menu-bar clock strip.  Meanwhile the device
keeps working: `frames=11429`, `r350_draws=24359`, `r350_scanout_draws=11481`.

The draws are being refused.  `r350_rejected` went from 0 before Chess to
**828** after, and the census says why:

| reason | count |
|---|---|
| `r350_reject_primitive_assembly` | **597** |
| `r350_reject_interpolator_routing` | **229** |
| `r350_reject_depth_stencil_alpha_logic_cull_fog_state` | 2 |

and names the two interpolator routes it could not handle:

```
route0=00000007:00000004:00040104:00000001:00d10000:00024008/212
route1=00000003:00000004:00040084:00000000:00d10000:00024008/17
```

212 + 17 = 229, exactly the interpolator rejections.  This is the first
measurement of what Chess asks the 9800 for and does not get, and it is a
better starting point than any screenshot: two concrete routes, and a larger
primitive-assembly gap behind them.

## `x-r350-decode-rs=on` is not the quick win

That flag exists to decode interpolator routing instead of matching it against
a whitelist, so it looks like the answer to the 229.  Turned on, the desktop
**never composited at all**: `damage=58` after thirteen minutes, no
WindowServer, the blue backdrop again -- worse than leaving it off, which at
least gives a working desktop.

**That reading was wrong, and is withdrawn.**  `damage=58`, no WindowServer,
flat blue backdrop: that is the exact signature of the session wedge described
at the end of this file, which was not understood at the time.  The run proved
nothing about `decode-rs`; it proved the VM had wedged before Chess could draw.
The flag is still an open candidate and deserves a clean test, which matters
rather more now that interpolator routing is the gate everything fails at.

The caution stands for a different reason: `primitive_assembly` was the larger
count, and no interpolator change addresses it.

---

# The census, and what it pointed at

Measured twice, on independent VMs, with Chess confirmed rendering on a
composited desktop.  Identical both times:

| counter | run A | run B |
|---|---|---|
| `r350_rejected` | 829 | 828 |
| `r350_reject_prim_1` | 1 | 1 |
| `r350_reject_prim_14` | **596** | **596** |
| `r350_reject_primitive_assembly` | 597 | 597 |
| `r350_reject_interpolator_routing` | 229 | 229 |
| `r350_reject_depth_stencil_alpha_logic_cull_fog_state` | 2 | 2 |

596 + 1 = 597, so the census accounts for every primitive-assembly rejection
and nothing is hiding.  **Only two primitive types are refused at all**: 14 and
1.  No lines, no rect-list, no polygon -- the speculation about those was
wrong, which is exactly why it was measured instead of guessed.

Read on the composited desktop *before* Chess launched: `r350_rejected=1` and
**no `reject_prim_*` at all**.  So all 597 belong to Chess.

Type 14 is QUAD_STRIP (`R200_PRIM_QUAD_STRIP 0xE`), and at 596 it is 72% of
everything the device throws away.  `r300_triangle_indices()` handled 4, 5, 6
and 13 and refused it.  It now assembles it, with the winding
`ppc_mac_gpu.c`'s other index builder already uses, so the two agree.

Type 1 is left alone: one rejection in 828, and points are not triangles.

**Not yet verified:** whether assembling QUAD_STRIP makes Chess's board
actually render.  The draws stop being discarded; whether what they draw is
correct is a separate question, and the answer is not in these numbers.

## The wedge that was corrupting all of this

Several runs produced a flat blue backdrop with scanline slivers, Finder never
starting, `damage` stuck near 54-58 and `draws` near 200, while the guest
stayed ssh-responsive.  It reads as a renderer fault.  It was the capture
client: it encoded each PNG inline in its receive loop, and QEMU's `pe_send()`
is a blocking write-all, so QEMU's main loop blocked and the VM stalled hard
enough to wedge Tiger's session permanently.  Host CPU contention from
concurrent TCG VMs does the same thing.

The client now encodes on a writer thread.  The rule that still holds: **one
VM on an otherwise idle host**, and judge "is the session up" from a captured
frame, never from `ps` -- `grep -c "[W]indowServer"` reports 0 while Finder is
plainly running, because `ps` truncates the path.

---

# Walking the gates: where Chess actually stops

Each fix admits the draws one gate further and exposes the next.  Measured, in
order, all with Chess running on a composited desktop:

| gate | baseline | +QUAD_STRIP | +decode-rs |
|---|---|---|---|
| `primitive_assembly` | 597 | 1 | 1 |
| `interpolator_routing` | 229 | 825 | **0** |
| `blend_equation_or_factors` | -- | -- | **824** |
| **`r350_rejected`** | **828** | **828** | **828** |

The total does not move, because nothing is being drawn differently yet -- the
same draws are failing later each time.  That is progress, but it is worth
being plain that no pixel changed at any step.

`x-r350-decode-rs=on` works.  It takes interpolator routing to zero.  An
earlier note in this file said otherwise and has been withdrawn: that run had
wedged before Chess drew anything.

## The blend gate, and what Chess asks for

The gate accepts exactly one configuration:

```c
if (RG(0x4e04)&1) {
    REQUIRE(RG(0x4e04)==0x27210007 && RG(0x4e08)==0x27210000,
            "blend equation or factors");
    draw.premultiplied_over=true;
}
```

The census says Chess sends one state, 824 times:

```
blend0=2726000f:27260000/824
```

Decoded with the shifts in `ppc_mac_gpu_3d_regs.h` (SRC at [21:16], DST at
[29:24]):

| | SRC factor | DST factor |
|---|---|---|
| accepted `0x27210007` | `0x21` ONE | `0x27` ONE_MINUS_SRC_ALPHA |
| Chess `0x2726000f` | `0x26` **SRC_ALPHA** | `0x27` ONE_MINUS_SRC_ALPHA |

So the accepted state is **premultiplied** over and Chess is doing **ordinary,
non-premultiplied** alpha blending.  The alpha register differs the same way
(`0x27260000` against `0x27210000`), and the low nibble differs, `0xf` against
`0x7`, which is not yet decoded.

## What a fix has to touch, and why it was not done tonight

It is not a one-line widening of the whitelist.  The source factor is
hard-coded all the way down:

```objc
if (d->premultiplied_over && !d->guest_target) {
    pd.colorAttachments[0].sourceRGBBlendFactor = MTLBlendFactorOne;
    pd.colorAttachments[0].sourceAlphaBlendFactor = MTLBlendFactorOne;
```

and there is a second, separate mechanism: when `guest_target` is set the
blend is done *inside the fragment shader* by framebuffer fetch
(`ppc_mac_gpu_r300_fp.c:302`, `:413`), also assuming premultiplied.  Both
paths need the real factors, which means carrying them on `R300MetalDraw`
rather than a single bool.

That is a real renderer change, and tonight it could not be verified at a
reasonable cost: healthy boots are roughly one in seven (see the wedge note
below), so a wrong guess costs a long retry loop to discover.  Adding one more
accepted literal would be the wrong shape anyway -- it is exactly the
whitelist pattern `decode-rs` exists to undo, and this file already records
what that costs.

**Next step, concretely:** carry SRC/DST blend factors through
`R300MetalDraw` and the fragment path instead of `premultiplied_over`, map
them onto `MTLBlendFactor`, and check Chess's board against
`control-9200-chess.png`.


---

# 4 October: the firmware, and the blend gate

## The 9800 had no display node at all

Every "the 9800 renders nothing" reading before this had a simpler cause than
the renderer: the console said

```
Output device screen not found.
```

OpenBIOS's `vga_devices[]` did not list `0x1002:0x4e48`, so the card got no
`device_type`, no `linebytes` and no mode -- not a frame buffer with the wrong
contents, but no frame buffer.  `damage` stuck at 1 and a flat screen follow
from that and say nothing about 3D.

The note above that "each firmware only knows its own card" described how the
builds happened to be made, not a constraint.  One table holds them all, and
the firmware now lists four: `0x5046`, `0x5960`, `0x5964` and `0x4e48`.  With
the id present the 9800 composites a complete Tiger desktop -- menu bar, Dock,
Finder windows, desktop icons.

This was only fixable once OpenBIOS could be built at all; see
`docs/BUILDING-OPENBIOS.md`.

## The blend gate now decodes instead of matching a literal

`RB3D_CBLEND`/`ABLEND` are decoded into SRC/DST factors carried on the draw,
mapped to `MTLBlendFactor` for the pipeline path and emitted as an MSL
expression for the guest-order path, replacing a `premultiplied_over` bool
that hard-coded ONE / ONE_MINUS_SRC_ALPHA.  A census records every blend state
asked for, accepted or refused.

**Validated, as far as it goes:** the 9800's desktop composites through the
rewritten path -- `blend0=27210007:27210000` is the premultiplied state, and
it now reaches Metal as decoded factors rather than as a matched literal.  The
desktop is correct, so the ONE / ONE_MINUS_SRC_ALPHA case is right.

**Not yet validated:** Chess's own state, `2726000f:27260000` (ordinary
non-premultiplied alpha), never appeared in the census.  Its draws are still
refused earlier, at primitive assembly (597) and interpolator routing (229),
so they never reach the blend gate.  Both of those have fixes available --
QUAD_STRIP assembly and `x-r350-decode-rs=on` -- and with both on the census
showed `r350_rejected=0`, but the guest session wedged before Chess drew
enough to prove anything.  The blend work is therefore a gate that has been
opened, not a gate that has been shown to matter yet.


## The Warcraft III control

`control-9200-warcraft3-mainmenu.png` -- Warcraft III: Reign of Chaos, main
menu, on the **9200**, launched from the No-CD build on the guest's desktop
(`~/Desktop/Warcraft III ROC [NoCD].app`) and captured after the opening
cinematic.

It is correct in every respect worth comparing: the logo, the lit 3D scene
behind the menu (banner, grass, water, falling rain, the wrecked siege
engine), and the whole menu panel with its six buttons.  That is the picture
the 9800 has to match.

Method, so the comparison is a comparison and not two different experiments:
`/tmp/wc3.sh 9200|9800` on the Studio takes the same disk, the same firmware
(`/tmp/fwall`, the one that knows every card), the same 1024x768x32 mode, one
CPU, and the same `poweremu-display` capture client.  Only the `-device`
differs.


## The 9800 with Warcraft III: where it actually stops

`9800-warcraft3-wedged-on-launch.png`, same harness, only the card changed.

The game does not reach its menu.  The screen is a blue field with horizontal
banding and a smeared dialog strip, and it stops there.  What the counters say
at that moment matters more than the picture:

```
r350_draws=173   r350_rejected=0   blend0=27210007:27210000/54
```

**Nothing is being refused.**  173 draws is barely more than the desktop had
before the game started, so the game has hardly drawn at all -- this is not a
case of draws being thrown away by a gate.

The launch itself hangs: `open ~/Desktop/Warcraft III ROC [NoCD].app` over ssh
never returns on the 9800, and the same command on the 9200 returns at once
and the game runs to its menu.  Chess behaved identically -- the desktop
composites, then `open -a Chess` hangs and the session stops updating.

So the next thing to find is not a missing 3D feature.  It is why launching an
accelerated application wedges the guest session on this card, while the same
guest, disk and firmware are fine on the 9200.  Until that is understood, a
Chess or Warcraft frame from the 9800 cannot be compared with the control,
because the application never gets to draw one.
