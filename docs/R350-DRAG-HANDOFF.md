# Radeon 9800: window drags distort — RESOLVED 2 Oct 2026

> **The lead in this document is closed.**  Opcode `0x1b` is decoded and
> executing; a human drag on a 9800 guest no longer distorts.  The rest of the
> document is kept as written because its ruled-out table and its method are
> still the record for anyone working on this device.
>
> ## What it was
>
> `0x1b` is the **compact three-dword form of the same blit** as `0x9b`
> (`PACKET3_BITBLT_MULTI`).  Nothing executed it, so, exactly as the comment in
> `ppc_mac_gpu.c` predicted, the packets were "refused by nobody and counted by
> nothing" and the pixels they would have drawn stayed as they were.  It is now
> handled at `hw/display/ppc_mac_gpu.c:8422` (`opcode == 0x1b && body_dw >= 3`,
> `bool compact = (opcode == 0x1b)`).
>
> ## The measurement that closed it
>
> A human dragged windows in a Tiger guest on `ppc-mac-r350-probe`, four CPUs,
> MTTCG, with `R350_UNDEC=1` set.  `qom-get /machine/peripheral/gpu0 perf`
> through the HMP monitor afterwards:
>
> ```
> pm4_35=14162  pm4_10=6632  pm4_1b=230  pm4_9b=159  pm4_34=83
> pm4undec_10=6632        <- NOP, deliberately excluded from the probe print
> ```
>
> `pm4_1b=230` **executed**, and nothing undecoded but NOP.  The probe printed
> no `R350_UNDEC op=` lines because there was nothing left undecoded to print —
> absence of probe output plus a non-zero execution count, not absence alone.
> The person driving confirmed the windows looked right.
>
> ## Two things to know before using this document again
>
> * The probe's output does **not** reach the terminal that launches the app.
>   The VM helper's stdout and stderr are redirected to
>   `<VM>.poweremu/Logs/qemu.log` however the app is started, so read it there.
>   The `R350_UNDEC=1 "...MacOS/PowerEmu"` recipe below is correct about the
>   gate and wrong about where the output lands.
> * Leopard's translucent menu bar was the second symptom and is **not** covered
>   by this measurement.  It is now superseded by something worse, below.
>
> ## Leopard kernel panics on the 9800 (new, 2 Oct 2026)
>
> Leopard never reaches a desktop on `ppc-mac-r350-probe`: it panics, showing
> the multilingual "You need to restart your computer" screen.  The panic text
> renders crisply, so the display path itself is sound -- this is the kernel
> dying, not the renderer.  The serial console does not capture it (Leopard
> does not route the panic there), so the reason is still unknown.
>
> Control, same disk and same emulator binary, one overlay each:
>
> | guest | GPU | firmware | result |
> |---|---|---|---|
> | Leopard | `ppc-mac-r350-probe` | `openbios-r350` | **kernel panic** |
> | Leopard | `ppc-mac-gpu` | `openbios-smp` | clean Apple logo and spinner |
> | Tiger | `ppc-mac-r350-probe` | `openbios-r350` | desktop, drags correct |
>
> The firmware differs between the first two rows because **each firmware only
> knows its own card**: a 9200 on `openbios-r350`, or a 9800 on `openbios-smp`,
> logs `Output device screen not found` and shows a black screen with no
> framebuffer at all.  So this is not a single-variable control; it is the
> comparison of each device as it must actually be run.  Getting a true control
> needs one OpenBIOS carrying both patch sets, which no machine here can build
> -- there is no OpenBIOS source tree on this Mac, and both images came from the
> Studio handoff hash-checked rather than rebuilt.
>
> ### The panic, read out of guest memory
>
> `ATIRadeon9700` faults on a write to a near-null address.  From the panic
> buffer, recovered with `pmemsave` and a string search:
>
> ```
> panic(cpu 0 caller 0xFFFF0003): 0x300 - Data access
> PC=0x450C55F0; MSR=0x00009030; DAR=0x00004018; DSISR=0x42000000;
> LR=0x450C4630; R1=0x45077C30; XCP=0x0000000C (0x300 - Data access)
> Backtrace: 0x450C4630 0x00348ED8 0x0034A02C 0x0034BEDC 0x0034AFFC 0x000B1DD4
> com.apple.ATIRadeon9700(5.4.8)@0x4509f000->0x450fbfff
>   dependency: IONDRVSupport(1.7.3), IOPCIFamily(2.6), IOGraphicsFamily(1.7.3)
> ```
>
> * `0x300` is the PowerPC Data Storage Interrupt, and `DSISR=0x42000000` is
>   page-not-present (0x40000000) on a **store** (0x02000000).
> * `DAR=0x00004018` is the address written.  That is not a pointer; it is a
>   **register offset added to a base of zero** -- 0x4018 sits inside the 64 KB
>   MMIO aperture.  The driver is writing a register through a mapping it never
>   got.
> * `PC - kext base = 0x450C55F0 - 0x4509F000 =` **`+0x265F0` inside
>   `ATIRadeon9700` 5.4.8**, which is the exact offset to disassemble.
>
> The device presents (`info pci`, PCI id `1002:4e48`):
>
> | BAR | | |
> |---|---|---|
> | BAR0 | 0x88000000 | 128 MB, 32-bit prefetchable -- the framebuffer |
> | BAR1 | 0x1000 | 256 bytes I/O |
> | BAR2 | 0x90000000 | 64 KB 32-bit memory -- MMIO |
>
> which is the layout a real 9800 Pro presents, so no BAR is simply missing.
> Something the driver needs in order to *establish* the MMIO mapping is what
> comes back empty; no video BIOS is supplied to the device in the shipped
> configuration (`romfile` is not set on `ppc-mac-r350-probe`), which is the
> first thing to rule in or out.
>
> Tiger is unaffected: it runs an older `ATIRadeon9700` that reaches the desktop
> on the same device.  So this is specific to the 5.4.8 kext in Leopard.
>
> Next step: disassemble `ATIRadeon9700` 5.4.8 at `+0x265F0`, find which mapping
> the base register comes from, and see what the emulated device returns for it.
> `docs/RADEON-9200-RETROSPECTIVE.md` says disassembling Apple's kexts is what
> produced the breakthroughs both previous times; this gives it an exact offset
> to start from.
>
> How this was recovered, since none of the ordinary routes worked: Leopard does
> not route panics to the serial console (`serial=1` produced nothing), and the
> non-verbose boot shows only the multilingual restart screen.  Booting with
> `-prom-env 'boot-args=-v debug=0x144'` leaves the machine spinning at `b .`
> with the vCPU at 99%, which looks like a hang and is really the post-panic
> halt.  The text is still in memory: `pmemsave 0x0 0x6000000 "<file>"` through
> the HMP monitor, then search the dump for `panic(cpu`.

---

# Original handoff — state as of 30 Sep 2026, 19:45

Handoff for a session running **on the Mac Studio**, which can see and drive
that machine's screen.  This session could not: an ssh session has no
screen-recording right, so `screencapture` returns "could not create image
from display", and every attempt to reproduce the fault synthetically failed.

## The symptom

Radeon 9800 (`ppc-mac-r350-probe`) only.  Tiger: dragging a window distorts it
immediately; everything else looks right.  Leopard: same, plus the translucent
menu bar does not render.  The 9200 (`ppc-mac-gpu`) is clean.

## The one measurement that matters

A **real** window drag emits PM4 opcodes that **no scripted drag ever did**:

```
pm4_9b=85     PACKET3_BITBLT_MULTI  (0x9B is the R300 number; R200 uses 0x92)
pm4_1b=170    undecoded -- nothing in the emulator executes it
pm4_35=4010   3D_DRAW_IMMD_2
r350_rejected=0
```

Taken through the HMP monitor while a human dragged a window.  Seven scripted
drags (QMP `input-send-event`, up to 600 continuous motions) produced **only**
`0x35`, `0x34` and `0x10`.  A synthetic pointer drag and a human drag make
Tiger's compositor take different paths; that is why nothing reproduced.

* `0x9B` **is** handled (`ppc_mac_gpu.c`, `if (opcode == 0x9b ...)`) and
  already carries the 9200's `DEFAULT_PITCH_OFFSET` fix.
* `0x1B` is **not decoded anywhere**, 170 packets per drag.  It is in no R300
  header in the tree.  The emulator's own comment describes this exact failure:
  an undecoded packet "is refused by nobody and counted by nothing -- it simply
  does not happen, and the pixels underneath it stay as they were."

**This is the live lead.**

## How to get the payload (probe is already built and deployed)

`~/Applications/PowerEmu 9800 Fix.app` on the Studio contains a probe that
prints the first four packets of each undecoded opcode, gated on `R350_UNDEC`:

```sh
R350_UNDEC=1 "$HOME/Applications/PowerEmu 9800 Fix.app/Contents/MacOS/PowerEmu" \
    >/tmp/poweremu-undec.log 2>&1 &
# drag a guest window, then:
grep R350_UNDEC /tmp/poweremu-undec.log
```

Lines read `R350_UNDEC op=0x1b dw=<n> : <body dwords>`.  Identify the opcode
from its operands (a blit carries source/destination offsets and an extent;
a state packet carries register-like values), then implement it.

## Running the VM without touching the GUI

* `Tiger 9800.poweremu` has `autoStart` true, so launching the app boots it.
  1680x1050, 128 MB, 2 CPUs, disk is a COW overlay on the read-only
  `/Volumes/Studio External/PowerEmu-SMP/vms/tiger-base.qcow2`.
* HMP monitor on `telnet:127.0.0.1:4444` is **separate from the QMP channel the
  app holds**, so it can be used while the app runs:

```sh
printf "qom-get /machine/peripheral/gpu0 perf\nquit\n" | nc -w 6 127.0.0.1 4444
printf "screendump /tmp/vram.ppm\nquit\n"              | nc -w 6 127.0.0.1 4444
```

That last one is the paired capture worth taking: a VRAM screendump at the
moment the window is visibly distorted.  If VRAM is clean while the window is
not, the fault is host-side, not in the renderer.

## Ruled out today, with evidence — do not re-open without new data

| | |
|---|---|
| VRAM during a drag | clean; streak 3.08-3.09 and 5.76-5.80 across two machines |
| The delivered buffer | matches VRAM at boot **and** desktop (4.16/4.16) — read via a stand-in client on the `poweremu-display` socket |
| qemu configuration | GPU device string and `-g -m -accel -cpu -machine -bios -global -vga` are character-identical between the app (corrupts) and the harness (clean) |
| VRAM size, resolution, CPU count, host-native size | all matched to the corrupting config; still clean |
| Today's three decode changes | `R350_LEGACY_DECODE=1` produces byte-identical frames |
| SMP | inconclusive (both runs hung), but a matched 2-CPU run was clean |
| Macro-tiling | the corruption has a regular 16-row period (autocorrelation 0.993) which matches the macro-tile height, but `RADEON-9200-RETROSPECTIVE.md` establishes linear storage is self-consistent, and the theory cannot explain why write-then-read linear does not cancel.  Demoted. |
| Pitch disagreement | no surface was written at one pitch and read at another, across a full drag |

## Fixed today (verified, unrelated to the drag bug)

1. **Bypass draws were clipped to a stale viewport.**  In VAP bypass the
   hardware applies no viewport transform (`VTE_CNTL`=0) and `SC_CLIP_RULE`
   0xffff disables the clip rectangles, but the emulator sized and clipped the
   destination from both -- so every composite was cut to the size of whichever
   window was drawn last.  Windows now render their full content.
2. **The display stride ignored 256-byte row alignment.**  Every Radeon-era Mac
   driver rounds rowBytes up to 256; the emulator seeded `CRTC_PITCH` from the
   visible width.  The 9200 hid it because its 2D engine reports the real pitch
   through `r200_set_present_pitch()`; the 9800 never uses the 2D engine for
   that, so the whole screen sheared at 1680x1050 (`stride=6720` where the 9200
   got `6912`).  Fixed with `r200_aligned_pitch_pixels()`.
3. Three decode corrections read out of `ATIRadeon9700GA.plugin`: the
   `US_OUT_FMT_0` component select, `SHORT_2`/`SHORT_4` vertices, and a bypass
   texture route decoded rather than whitelisted.  None is exercised by the
   guest under test; all revert together with `R350_LEGACY_DECODE=1`.

## Read first

`docs/RADEON-9200-RETROSPECTIVE.md`.  The 9200 had a drag bug with the same
outward shape, fixed by honouring `DEFAULT_PITCH_OFFSET` (0x16E0).  Its closing
section on method is worth following literally -- disassembling Apple's kexts
and reading PM4 sequence logs produced the breakthroughs both times, including
today's.

## Also open, untouched

* Desktop icons missing in the user's Tiger guest (the Studio's shows them, so
  it is guest-specific, not the emulator).
* Harmony Dock tiles exit and are relaunched every 3s by `GuestDock`'s keeper;
  `poweremu-netd` helpers survive as root-owned orphans for days.
* Warcraft III: resolution change distorts, and quitting leaves the screen
  black.  Warcraft III is installed on the Studio's Tiger image.
* 9800 performance tuning.
