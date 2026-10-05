# Warcraft III on the Radeon 9800 — status, 5 October 2026

**Not finished.** Warcraft III does not reach its main menu on the 9800. It
does launch, load, switch the display to 1152x870 and render its intro
cinematic. Three separate faults were found and fixed; one remains.

The 9200 control reaches the full menu in about 420 seconds —
`docs/evidence/r350-2026-10-04/wc3-9200-menu-control.png` — so the harness,
the disc image and the timing reference are all known good.

## Getting it to run at all

It wants its CD. `/Users/adam/Downloads/Warcraft III.toast` is a raw
Apple-partitioned image and attaches directly:

```
PE_CD="/Users/adam/Downloads/Warcraft III.toast" ./app.sh "x-r350-decode-rs=on" \
    <tag> "/Applications/Warcraft III Folder" warcraft r350
```

Without it the game opens a "Please insert the Warcraft III CD" dialog and
nothing else happens. There is also a No-CD pack at
`/Users/adam/Downloads/Warcraft_III_NoCD_Pack.dmg`, unused so far.

## Fixed

### 1. Fog was refused, and it was most of the game

`FG_FOG_BLEND` enabled meant the draw was thrown away. That was **587,607 of
Warcraft III's draws — more than every other rejection reason put together**.
Refusing a fogged draw does not leave the fog out, it leaves the geometry out.
It asks for linear fog with a black or dark green colour `(0x2c,0x50,0x2c)`,
which is the menu's atmosphere. Now accepted; the fog function is still
checked so an unseen mode still stops a draw. The blend itself is not applied
yet, so the scene will be less atmospheric than the control until it is.

### 2. Indirect buffers were being dropped, and each one was a lost fence

`MC_AGP_LOCATION` is written in parts. While it holds a start with no end yet
it decodes to an aperture whose end is *below* its start, which rejects every
address. A buffer that cannot be read is dropped — and the driver ends each
buffer with a scratch-register write and then waits in memory for that stamp.
So a dropped buffer is not a missing frame, it is a wait that never ends.

**317 buffers went that way.** Keeping the last aperture that made sense, and
using it while the register is part-written, brings that to 60.

### 3. The spin was the report of the hang, not the hang

The guest read `CP_CSQ_STAT` (0x07F8) about 200,000 times every 45 seconds at
100% of a core. That register is not on any submission path.

A research pass disassembled Apple's `ATIRadeon9700` kext. In the whole 500 KB
binary the constant `0x07F8` appears four times, all inside
`DumpASICHangState()` and `dump_registers()`. `DumpASICHangState()` samples the
register once, then re-reads it **100,001 times at 100 µs**, and if it never
changes declares the ASIC hung and walks the entire command queue a dword at a
time with a 10 ms sleep between each. That is ~21 seconds of doing nothing per
failed wait, and it exactly accounts for the observed counts: 100,003 reads of
0x07F8 and 1,024 reads of 0x07F4 per call, two calls per cycle.

So the spin was a *diagnostic* that only runs once the driver has already given
up. The real wait is `waitForTimeStampNoLock()`, which polls a word in **guest
memory** — the scratch writeback at `SCRATCH_ADDR + n` — 50,001 times at 100 µs,
five seconds, before returning failure.

Two other things were wrong with that register. Its layout is three **10-bit**
fields (`RPTR_PRIMARY 9:0`, `WPTR_PRIMARY 19:10`, `RPTR_INDIRECT 29:20`), not
the four 8-bit fields in `radeon_reg.h` — that is the R100/R200 layout, and it
is dead code in Linux, which is why the stale definition was never caught. The
remaining pointers live in `CP_CSQ2_STAT` at 0x07FC, which did not exist here.

Reads per 45 seconds: **200,006 → 26.**

## What is left

One fence that never arrives. Nothing is being dropped any more — `ib_lost`
stops growing — and the game stalls quietly on the timestamp wait instead of
noisily. State at the stall: `ib_done≈7500`, `ib_lost=60`, `fence_written≈2500`,
`draws≈2200`, and no register being hammered.

Three things ruled out along the way, each by measurement:

- **The fence is not mis-addressed.** `SCRATCH_ADDR = 0x07c24000` is inside the
  card's GART aperture (`0x07c00000–0x0fbfffff`), the page table really is at
  `0xa16f000`, the PTEs are sane, and the writeback lands at a correct physical
  address with monotonically rising stamps:
  `SCRATCH_WB reg0=0x3 -> GART[0x7c24000] phys=0xa333000`.
- **Not byte order.** The kext reads that word with `lwbrx`, byte-reversed, so
  little-endian is correct. `POWEREMU_WB_BE=1` kills it outright (frames=0).
- **Not a mis-decoded packet.** The stream contains no opcode 0x33, so the
  INDX_BUFFER/INDIRECT_BUFFER confusion noted in the audit is not being hit
  here. `pm4_10` is NOP and benign.

Where I would look next: which scratch register the driver's timestamp actually
uses, and whether the one IB that carries the awaited stamp is among the 60
still being lost. The writeback is also still capped at registers 0–5 where the
hardware has 0–7.

### Two mistakes worth not repeating

- I read register writes with `sort -u | tail`, which orders them
  lexicographically, and concluded `AIC_PT_BASE` was `0x00ffffff` garbage. In
  chronological order it is written once, and the debug log shows the table is
  really at `0xa16f000` and working. A fix built on that reading made things
  strictly worse (`fence_gart` 3950 → 0) and was reverted.
- The probe log prints only the first eight writes to a register and then
  powers of two, so "the values a register was written with" is not what
  grepping it gives you.

## Switches

`POWEREMU_R350_REGCENSUS=1` (which register a stuck guest is reading — this is
the one that cracked it), `POWEREMU_R350_IBLOST=1` (buffers that could not be
read, with the aperture at the time), `POWEREMU_R350_RT=1` (distinct render
targets), `POWEREMU_R350_FOG=1`, `PPCGPU_DEBUG_LOG=1` (per-access log to
`/tmp/gpu_all_access.log`, where the GART translations and scratch writebacks
are), and `ib_*` / `fence_*` counters on the `perf` property.
