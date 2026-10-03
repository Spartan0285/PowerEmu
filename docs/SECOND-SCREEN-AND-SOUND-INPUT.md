# A second screen, and a microphone

Two features that both looked like emulator work and turned out to need
nothing of the kind in one case and a missing host backend in the other.

## The second screen is a second card

The obvious reading of "multiple displays" is CRTC2: the Radeon has a
second CRTC, our model treats its registers as stubs that "accept writes
silently", so implement them.  That is the expensive route and it is not
the one that works.

What decides how many screens Mac OS X sees is **not** the card's
registers.  `IONDRVFramebuffer::start()` walks the graphics device's
Open Firmware children and makes one framebuffer per child whose
`device_type` is `display` (Apple's own IOGraphics source, 179.2 =
Tiger).  No child node, no second head, whatever CRTC2 does.  Publishing
those children means changing OpenBIOS *and* the NDRV, and the NDRV here
is produced by binary patching.

Worse, the closed ATI kext is not the display driver at all.
`ATIRadeon8500.kext` matches `IOMatchCategory = IOAccelerator` on the PCI
ID; mode setting lives in `IONDRVFramebuffer` plus an NDRV.  Apple's own
ATI NDRVs bind to `IONameMatch "ATY,*"`, and OpenBIOS names our node
`pci1002,5960`, so they never load.  Nothing in Mac OS X reads CRTC2 on
this device today, and implementing it would change nothing until the
whole naming and FCode story changed with it.

So: give the machine **two cards**.  A Power Mac did exactly this -- one
AGP card and graphics cards in the PCI slots -- and Mac OS X extends the
desktop across them with no help from anyone.  Measured here on Tiger:
both cards get their own console, both get a mode set, the first carries
the menu bar and the second carries the windows that run off its right
edge.  Evidence in `docs/evidence/dual-display-2026-10-03/`.

Each card needs its own listener, so `poweremu-display` grew an `index`.
`VMRunner` adds the second card and the second object; `SecondScreen.swift`
opens the second window.

### What this cost in the device

A second instance of `ppc-mac-gpu` is a second instance of a device that
has file-scope mutable state.  The one that mattered was the asynchronous
fence bottom half: built once, from whichever card realized first, and
then used to drain that card's queue whatever card the completion came
from.  It is per-instance now.  Others remain (`g_blit_stats`, the
Harmony window table, the debug log) -- they are logging and heuristics,
and Harmony is a one-screen idea in any case.

### The mouse, which is a real limit

The guest's pointer is a USB tablet: it reports where it is, not how far
it moved, and QEMU scales those absolute positions into a fixed range
that Mac OS X maps onto its **main display**.  While the tablet is
driving it the pointer cannot reach the second screen at all.  A machine
with two screens therefore uses the relative mouse, and both windows
capture; Control-Option-G gives it back.

### Two addresses that were wrong

`R200_CRTC2_PITCH` was 0x023C and `R200_FP2_GEN_CNTL` was 0x033C, against
0x032C and 0x0288 in the X.Org radeon driver.  Both were only used as
"accept writes silently" stubs, so for years they swallowed writes meant
for whatever really lives at those two addresses while the real registers
fell through to the unimplemented path.

## The microphone needed a host backend that did not exist

The emulated Screamer has had an input DMA channel all along.  What it
did with it was clear RUN and end the descriptor, with a comment blaming
Mac OS 9.  That is worse than doing nothing: Mac OS X checks the input
channel's ACTIVE bit on every *output* interrupt and restarts the whole
audio engine when it finds it stopped.

But the blocker was below that.  QEMU's CoreAudio backend declared
`max_voices_in = 0` and had no capture code at all, so on the only host
this emulator runs on `AUD_open_in` could never succeed -- and
`AUD_read(NULL, ...)` returns the requested size without touching the
buffer, so a naive implementation would have DMAed uninitialised host
memory into the guest.  Capture is implemented now, mirroring the
playback half: an IOProc on the default input device fills the ring the
generic layer would have filled, and `read` drains it.

### What the guest needs to see

- **Codec register 0** carries the whole of input: multiplexer bits 11:9
  (which jack each one means is machine-specific -- Apple, Linux and
  NetBSD disagree on the names, so any source counts as listening) and
  the two gain nibbles.
- **The sound control register's input subframe** (bits 3:0) must be set;
  Apple writes it once at initialisation.
- **The sense nibble** of the status register is how Mac OS X decides an
  input exists at all.  It polls it once a second and builds its list of
  input devices from it.
- **The frame counter** is the audio clock, and the driver zeroes it at
  every engine start.  That write used to be dropped.
- **Pacing**: both streams are one `IOAudioEngine` whose clock is the
  frame counter the *output* path advances, timestamped on the output
  interrupt.  Input therefore takes its frames from the same timer and
  the same per-tick budget.  Short of real sound it is given silence
  rather than being stalled -- a stalled input clock reads as a broken
  stream, and the application recording from it hangs rather than
  recording quiet.

### Permission

Opening the capture voice is what asks this Mac to listen, so it is not
done when the machine is built -- on a Mac that has not answered that
question the request need not come back, and the emulator would hang
before the guest had drawn anything.  It is opened the first time the
guest selects an input.  This Mac grants the microphone to the
application *responsible* for the request, which is PowerEmu rather than
the emulator it starts, so the usage string is in both bundles and the
emulator carries `com.apple.security.device.audio-input` (the hardened
runtime requires it whatever the owner has agreed to).  A refusal is not
remembered: the guest arms its input again every time it records.

## Still open

- Nothing drives a second head on **one** card, and nothing needs to.
  The cheap version of that -- two `device_type = "display"` children in
  OpenBIOS, the second with `address`/`width`/`height`/`depth`/`linebytes`
  so `IOBootNDRV` gives it a fixed-mode framebuffer -- would be the
  experiment if one card ever had to do it.
- `dbdma_control_write` never copies the guest's DEVSTAT bits, so Apple's
  clean-stop protocol (set S0, let the ring branch to a STOP descriptor)
  cannot fire and the driver waits out its own timeout instead.  Benign,
  but it is a divergence.
- Mac OS 9 input is untested.  The device defaults to no input, and a
  classic guest is not offered one.
