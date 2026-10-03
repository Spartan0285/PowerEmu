# Leopard does boot. It cannot put a pixel on the screen.

State as of 3 October 2026.  This corrects two earlier readings of the same
symptom, both of which were wrong, and records what was actually measured.

## What it looks like, and why that is misleading

A Leopard guest reaches the grey Apple logo with the spinner and appears to
stop.  The vCPU settles at 2-8% host CPU.  Nothing further is drawn, ever.

It is natural to read that as a hang, and twice it was read that way here --
first as "Leopard stalls with 4 CPUs", then, after the CPU count was ruled out,
as "Leopard will not boot on this emulator".  Both are wrong.

**Leopard boots.**  It reaches a full Aqua session in about 17 seconds.  From
a process list captured inside a guest that had been "stalling" for an hour:

```
 41 Ss  loginwindow console
 66 Ss  .../CoreGraphics.framework/Resources/WindowServer -daemon
 90 S   Spotlight
 92 S   Dock -psn_0_24582
 95 S   SystemUIServer
 96 S   Finder -psn_0_32776
107/108 SNs mdworker MDSImportWorker
```

and from the same guest's log buffer, read 66 minutes later:

```
01:16:58 Finder[87]: _CFGetHostUUIDString: ...
01:17:03 loginwindow[34]: ODUEthernetAddress(): ...
01:46:57 PubSubAgent[136]: ...
02:16:48 backupd-helper[138]: ...
02:17:05 iCal Helper[141]: ...
```

Boot finished at 01:17:03 and Time Machine, iCal and Spotlight helpers have
been firing on schedule ever since.  The 2-8% CPU is an idle desktop; the
qcow2 overlay growing 38 MB to 75 MB is `mdworker` indexing.  There is no
panic, no driver timeout, no "still waiting".

## What is actually broken

`pmemsave` of the whole 128 MB VRAM aperture on a running guest: **every
megabyte still holds the BootX grey-Apple logo.**  The guest never writes a
pixel to the card.

On this device the thing that puts pixels on the scanout is the ATI R200
accelerator path.  Tiger, on an identical harness, logs

```
ppc-mac-gpu r200: direct renderer ready
[PRESENT_BLIT] MMIO_NOSRT: src=0x300000+4096 dst=0x0+4096 ... 1024x768
ppc-mac-gpu r200: 14000 draws, 13367 passes, 12695 flushes
```

Leopard logs only OpenBIOS's initial mode line and nothing else.  With IOKit
match logging the sequence is:

```
IONDRVFramebuffer::start(QEMU,VGA) <1>            <- succeeds
ATIRadeon8500::start(QEMU,VGA) <1>
ATIRadeon8500::detach(QEMU,VGA)
ATIRadeon8500::start(QEMU,VGA) <1> failed
```

So the dumb `qemu_vga.ndrv` framebuffer attaches, Leopard's R200 driver tries
to take over and fails, and `ioreg` then shows an `IONDRVFramebuffer` with
**no `display0` / `IODisplayConnect` / `AppleDisplay` child at all**.
WindowServer has no online display, so it renders nowhere.

Two details worth keeping:

* This install has had a working display before: its stored WindowServer
  preferences name
  `.../QEMU,VGA@E/.Display_Video_QemuVGA/display0/AppleDisplay-756e6b6e-...`,
  and `756e6b6e` is `"unkn"`.  So that NDRV path once produced a `display0`.
* OpenBIOS has no entry for `1002:5960` in `drivers/pci_database.c`, so the
  card is published as generic QEMU VGA and never gets an `ATY,...` name or
  compatible property.

## Ruled out, with evidence

| | |
|---|---|
| CPU count | identical at 1 and at 4 |
| firmware | identical on the SMP and the stock OpenBIOS |
| AGP | identical with `uni-north-pci.agp-capable` on and off (`AppleMacRiscPCI` either way) |
| resolution | identical at 1024x768x32 and 1680x1088x32 |
| the display listener | attaching `-object poweremu-display` + a capture client changes nothing -- this is **not** the `-display none` problem that was fooling the 9800 work the same night |

That last row matters: a separate finding that night was that without a
display listener QEMU drives no display updates and an R350 guest stops
submitting draws.  It is a real effect and it is **not** what is happening
here; Leopard was tested with a listener attached and behaves identically.

## The 9800 is a different failure, not a fix

On `ppc-mac-r350-probe` with its own firmware, Leopard's `ATIRadeon9700`
**does** bind -- and then panics:

```
panic(cpu 0 caller 0xFFFF0003): 0x300 - Data access
PC=0x0080D5F0; DAR=0x00004018; DSISR=0x42000000
com.apple.ATIRadeon9700(5.4.8)
```

`DAR=0x4018` is a register offset added to a base of zero: the kext writing
MMIO through a mapping it never obtained.  Leopard's ATI kexts will bind when
the PCI ID matches something they support; the emulated device is then not
complete enough for them.

## Not determined

* Why `ATIRadeon8500` 5.4.8 returns false from `start()`.  That is inside
  Apple's closed kext and needs disassembly.  Tiger ships a different
  generation of the same driver and succeeds.
* Why the `IONDRVFramebuffer` that does start never gets an `IODisplayConnect`
  -- only that it does not, and that this install once had one.

## Where to look next

1. Make `ppc-mac-gpu` complete enough for Leopard's ATI kexts.  The R350 panic
   gives a concrete first target: find which mapping `ATIRadeon9700` 5.4.8
   reads at `+0x265F0` into the kext and returns zero for.
2. Restore OpenBIOS's VGA FCode driver so a plain `-device VGA` +
   `qemu_vga.ndrv` path exists as a fallback.  The stored `display0` pref
   suggests that path worked for this install once.  Today all three OpenBIOS
   images in the tree print `cannot manage 'VGA controller' PCI device` and
   `Output device screen not found`, so there is no second display path.
