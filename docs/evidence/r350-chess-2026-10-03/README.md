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
