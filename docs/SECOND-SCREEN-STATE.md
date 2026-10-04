# The second screen: where it stands

A machine can be given two screens, and as of 4 October 2026 both of them
render a correct desktop at 1680x1050.  Evidence, with screenshots and the
measurements behind each step, is in
`docs/evidence/dual-display-2026-10-04/`.

## How it is built

A second screen is a **second `ppc-mac-gpu` PCI card**, the way a Power Mac
did it.  Mac OS X extends the desktop across the two by itself.  Each card
gets its own QEMU console and its own socket, picked by `poweremu-display`'s
`index`, and the app shows it in a second window (`SecondScreen.swift`).

This was chosen over a second head on one card (CRTC2): Mac OS X decides how
many screens a card has from its Open Firmware *children*, not from CRTC2.

## The three things that had to be true

Each was found by its own measurement, and all three are needed.

### 1. Both cards scan out the exact row length

`exact-scanout-pitch=on` on **both** cards.

Mac OS X's ATI driver rounds rowBytes up to 256 bytes -- that is not folklore,
it is `GETPITCH` in the shipping `ATIDriver.bundle`, `addi r0,r4,255` followed
by `rlwinm r31,r0,0,0,23`.  With one card that driver owns the screen, paints
at 6912 bytes a row at 1680 wide, and programs `CRTC_PITCH` to match, so the
card and the content agree.

With two cards neither screen is painted that way: both are driven by
`qemu_vga.ndrv`, which paints at the unrounded row length, 6720.  Meanwhile
the device still seeds and re-seeds `CRTC_PITCH` to the aligned value, so the
scan-out is 192 bytes a row wider than the picture and the screen shears into
diagonal bands.  1050 x 6720 / 6912 = 1020.8, which is why the measurement
was "1021 good rows and 29 black ones".

The write that does it is in the VBE `ENABLE` handler and assigns
`s->regs.crtc_pitch` directly rather than going through the MMIO case, which
is why instrumentation on the MMIO path saw nothing and an earlier session
concluded the guest never programmed the register.  `pitchlog(s, "vbe", ...)`
now covers it; `PPCGPU_PITCHLOG=1` prints it.

Note the trap: exact and 256-aligned pitches are **equal** whenever the width
is a multiple of 64.  At 1024, 1280 and 1920 this bug cannot appear.  Test at
1680 or 1440.

### 2. The second card reports a PCI id no ATI kext claims

`x-pci-device-id=0x5964` (Radeon 9200 SE).

`ATIRadeon8500` matches on vendor and device alone, and IOKit scopes
`IOMatchCategory` per provider -- so with two identical cards it attaches an
accelerator to both, which is legal and which it does.  On the second card it
panics the guest.  A verbose boot caught it: `com.apple.ATIRadeon8500` in the
backtrace, a data-access fault, and `IOKitWaitQuiet() timed out`
(`two-card-panic-ATIRadeon8500.png`).

With an id the accelerator does not claim, the card is left to
`IONDRVFramebuffer`, which is all a second screen needs.  It is unaccelerated,
and that is correct rather than a shortfall: nothing accelerates a second card
under Mac OS X here anyway.

### 3. The firmware has to know that id

OpenBIOS's `vga_devices[]` decides whether a display card is configured at
all.  An id that is not in the table returns NULL from `pci_find_device`, so
`vga_config_cb` never runs and the node gets no `device_type`, no
`linebytes`, no mode and no driver -- the card simply is not a display.

So `0x5964` had to be added and the firmware rebuilt.  That had been
impossible on this Mac; the reason, and the fix, are in
`docs/BUILDING-OPENBIOS.md`.

## Testing traps, kept because each one cost a day

- **1024x768 cannot fail.** Nor can 1280 or 1920. Exact and aligned pitch
  coincide at every width that is a multiple of 64.
- **The capture client can wedge the guest.** A client that encodes frames
  inline in its receive loop blocks QEMU's `pe_send()`, stalls the main loop
  and wedges Tiger's session permanently -- wallpaper up, no Dock, `damage`
  frozen.  That reads exactly like a renderer fault and is not one.  Use
  `tools/pedisplay-capture.py`, which encodes on a writer thread.
- **`-display none` with no listener is not a neutral observer.** With no
  DisplayChangeListener nothing drives `graphic_hw_update()`, and the guest
  stops submitting draws.
- **One VM on an otherwise idle host.** Host CPU contention produces the same
  wedge.

## Still open

- `About This Mac` -> Graphics/Displays has not been re-checked since any of
  this landed.
- Only 1680x1050 at 64 MB a card has been verified end to end.
- The Metal submit layer is still a process-wide singleton bound to the first
  card that attaches (`g_vram`, the hazard tables, the render-pass encoder).
  A non-owner card is now turned away from it and renders in software, which
  is correct but untested -- the two-card run never reached a 3D draw on the
  second card, so the refusal never fired.  The right end state is a per-card
  submit layer.
