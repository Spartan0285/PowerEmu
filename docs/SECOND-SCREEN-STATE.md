# The second screen: where it stands

A machine can be given two screens, and Mac OS X genuinely believes it has
two: System Preferences -> Displays shows the Arrangement tab with both,
and Mirror Displays works.  The first screen renders correctly.  **The
second does not**, and the machine sometimes does not finish booting at
all.  It is off by default and should stay off until the work below lands.

## How it is built

A second screen is a **second `ppc-mac-gpu` PCI card**, the way a Power Mac
did it -- one AGP card and graphics cards in the PCI slots.  Mac OS X binds
its drivers to both and extends the desktop across them with no help from
us.  Each card gets its own QEMU console and its own socket, picked by
`poweremu-display`'s `index`, and the app shows it in a second window
(`SecondScreen.swift`).

This was chosen over a second head on one card (CRTC2).  Mac OS X decides
how many screens a card has from its Open Firmware *children*, not from
CRTC2, and nothing in the guest reads CRTC2 on this device today.  A second
head would need the full CRTC2 block, a second console, and -- the part
that kills it -- an NDRV that publishes two framebuffers.  Two cards needed
none of that and produced an extended desktop the same afternoon.

## What is wrong

### The shear

The second screen's picture slants.  Measured: with the card scanning
6912 bytes a row, the desktop occupied 1021 rows with 29 black rows under
it, and `1050 x 6720 / 6912 = 1020.8`.  The content is laid out at 6720
(1680 x 4, exactly) and read back at 6912 (1728 x 4, rounded up to a
256-byte boundary, which is what every Radeon-era Mac driver rounds to).

Where 6912 comes from, per card, from `PPCGPU_PITCHLOG=1`:

- **The first card**: Mac OS X's accelerated driver owns it and draws at
  the rounded length.  Our VBE handler also synthesises the rounded length
  into CRTC_PITCH.  They agree.  Correct.
- **The second card**: nothing accelerates it, so its picture is painted at
  the length its frame buffer really has, and its pitch register agrees.
  Then `r200_set_present_pitch()` adopts the pitch of *any* 2D blit of at
  least 256x256 to the visible frame buffer and keeps it until the mode
  changes -- and one stray blit at 6912 is enough to force the scan-out
  there for good.  `present-pitch-override=off` is now passed for the
  second card for exactly this reason.

**Mirroring looks right because mirroring hands the second card to the
accelerated driver**, which draws at the rounded length like the first.
Any explanation that does not account for that is wrong.

### The instability

Two cards boots to the desktop *sometimes*.  Otherwise it stops at the grey
Apple logo or at the blue screen before the desktop, and older builds
panicked outright with `com.apple.ATIRadeon8500` and
`com.apple.driver.AppleMacRiscPCI` on the stack.  A one-card control on the
same disk and the same command line reaches the desktop.

### The root cause they probably share

`ATIRadeon8500.kext` matches on **vendor and device id** with
`IOMatchCategory = IOAccelerator`, so it instantiates on *both* cards and
half-attaches to the one whose frame buffer is not what it expects.  That
accounts for the panics, for About This Mac hanging on Graphics/Displays,
and -- because no accelerator then owns the second card -- for the painter
being the unaccelerated path.  One fault, three faces.

**The fix** is to give the second card a PCI id no ATI kext lists.  It is
prepared in `scripts/smp/openbios-poweremu.patch` (0x5964, a real Radeon
9200 SE id, checked against both kexts' `IOPCIMatch`) together with the
device's `x-pci-device-id` property.  It is **untested**: the firmware is
built on the Studio, not on this Mac.

## Things that cost a day, so that they do not cost another one

- **Test at a width that can show the fault.** Exact and rounded pitch are
  identical whenever the width is a multiple of 64 -- 1024, 1280, 1920.
  The shear is invisible at those.  Test at **1680** or 1440.  Several
  early "two cards works" results were taken at 1024x768 and could not
  have failed.
- **The GPU is only driven when something is listening.** With no display
  listener attached the model does nothing and the guest appears to stall.
  Headless tests need a listener on *each* console.
- **Do not infer the row length from a screenshot.** It was read backwards
  twice, in opposite directions, and two fixes were built on it.  Log both
  ends instead (`PPCGPU_PITCHLOG=1`), or dump video memory with
  `pmemsave <base> <size> "<file>"` -- the filename must be quoted -- and
  find the length that minimises row-to-row difference.
- **A capture is raw memory order only when the scan-out stride equals
  width x 4.** When it does, the pixel stream can be re-wrapped at another
  length to see which one makes the picture coherent.  When it does not,
  that trick silently lies.
- **Both cards write to the same logs.** Mode sets, stride changes and the
  rate-limit counters were all shared and unattributed; they are tagged per
  card now, and several of them are capped by counters that one card can
  exhaust before the other prints once.

## What was tried and did not work

| Attempt | Why it failed |
|---|---|
| Publish an aligned `linebytes` for the second card | At boot the card is deliberately seeded with the *exact* pitch so the Apple logo does not shear; a longer row sheared the boot screen |
| Pin the card to PCI slot 0x12 for a stable node name | Brought back the ATIRadeon8500 panic |
| Make `exact-scanout-pitch` apply on the CRTC path, then after the override | Flipped the shear to the other direction |
| Seed the second card with the aligned pitch (`boot-display=off`) | Tiger hung at the blue screen instead of reaching the desktop |
| Give the card PCI id 0x5961 | 0x5961 is itself in ATIRadeon8500's match list, and an id absent from OpenBIOS's `vga_devices[]` gets no mode, no properties and no driver -- black screen |

The pattern worth remembering: **every change that made the second card
look more like a real accelerated card made things worse.**  The
unaligned pitch it starts with is not the bug; it appears to be what keeps
the accelerator from attaching far enough to hang.
