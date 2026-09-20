# Overnight, 19-20 September 2026

## The headline

**The paravirtual GPU is live in a real Tiger guest.** 10.4.11 boots to
userspace with the device on the bus and enumerates it:

    pci1b36,5047@F  <class IOPCIDevice, registered, matched, active>
    compatible = "pci1af4,1100", "pci1b36,5047", "pciclass,038000"

The kext's IOPCIMatch (0x50471b36) is exactly what that node matches, so
the kernel half has something real to bind to the moment it is loaded.

And the emulator got faster: a paired A/B on the Mac Studio, repeated
independently, measured **+5.7%** (52.0 -> 55.0 fps) for the night's
changes over the build that was in your app. **That build is now in your
app** -- I quit it, restaged QEMU, and reopened it as you left it.

## Two bugs this night's testing found

Both were found by making something *actually run* rather than by reading
code, and both would have stopped you dead this morning.

- **The device could never have been instantiated.** Putting it on a PCI
  bus tripped `assert(is_power_of_2(size))` in `pci_register_bar()`:
  control page plus ring plus data is 0x2101000, and a BAR's size must be a
  power of two. The self-test and the replay harness both drive the ring
  directly and never reach `realize()`, so neither had ever noticed. The
  BAR is now 64 MB with the tail unmapped; `PE_GPU_SHARED_BYTES`
  deliberately did *not* follow the rounding, because that is what the host
  validates guest offsets against and widening it would have the host
  accept offsets past the end of the memory it allocated.
- **The guest encoder could not emit a legal batch.** The host rejects any
  draw that no state packet precedes, and `pering.c` had no way to send
  one -- so every batch it could build was invalid by construction. Caught
  by replaying a capture from the guest encoder through the real device
  model, which accepted exactly one packet per batch and rejected the rest.

The replay harness (`POWEREMU_GPU_REPLAY=<file>`) is what caught the
second, on its first run. It is worth keeping for that reason: the
self-test proves the device against packets the device's own test code
built, which is a weaker claim than it looks.

## Where the paravirtual work stands

| piece | state |
|---|---|
| host device `poweremu-gpu` | ring, doorbell, fences, validation, Metal; **enumerates in Tiger** |
| guest ring encoder | state/draw/present/fence; native test passes, replays clean through the host |
| guest connector `peconn.c` | finds the service, maps both regions, checks magic/version, hands the mapping to the ring |
| guest renderer `guest/gld/` | 63 entry points, loaded by Tiger, context created on it; reports the device at init |
| guest kext `guest/gpu/` | compiles; **not loaded** -- needs your admin password |

End-to-end, guest encoder through the real device:

    replayed 3 batches: 21 packets, 12 draws, 36 vertices,
                        3 presents, 0 rejected, fence 3, error 0

## What needs you

1. **Loading the kext** is the one thing I cannot do: it needs admin in the
   guest, and that password is yours to type. Until it is loaded the
   renderer has no way to reach the ring -- userspace cannot map a PCI BAR
   without it -- so this is the gate on everything that follows.
2. The device is opt-in in the app (`POWEREMU_PARAVIRT_GPU=1`) so the
   build you are running cannot be affected by a device nothing is asking
   for yet.

## And the finding that should govern what happens next

`PPCGPU_TRAFFIC=1` during Warcraft III:

    4050 mmio-writes/s   715 mmio-reads/s   1008252 type0-regs/s   6585 draws/s

**Over 99.5% of the guest's GPU register traffic never traps.** Apple's ATI
driver batches nearly everything into PM4 command buffers in ordinary
memory. The argument I made for paravirtualisation -- that every register
write leaves translated code through the software MMU and takes the big lock
-- was wrong, and it was mine, made before measuring.

What paravirtualisation still buys: our own decode (~3.7% device model,
~3.0% Metal encode), some of the guest driver's own work, and a cleaner
architecture that can express things the R200 cannot. What it does not
touch: the ~42% of emulator time spent on address translation and block
lookup, which is where the frame rate actually is.

**Worth deciding deliberately**, on architecture rather than on the speed
claim.

## What exists now

| piece | state |
|---|---|
| host device `poweremu-gpu` | ring, doorbell, fences, validation, wired to Metal; 23-check self-test passes |
| guest renderer `guest/gld/` | 63 entry points, loaded and enumerated by Tiger, context created on it |
| guest ring encoder | native unit test passes, cross-compiles for PowerPC |
| guest kext `guest/gpu/` | **compiles** on the PowerBook (gcc-4.0, 10.4u SDK); not loaded |
| recovered ABI | `guest/gld/abi/` -- prototypes with evidence, plus reference binaries |

## Two techniques worth keeping

- **`PEGLD_PROBE=1`** fills each word of an unknown struct with its own
  index; reading it back through `CGLDescribeRenderer` maps the fields.
  This is how the renderer-info layout was recovered.
- **`PEGLD_PROXY=<real GLD>`** loads Apple's driver alongside ours and
  forwards calls, dumping what it returns. This corrected a wrong model of
  the pixel format in one step, after several rebuilds of guessing: entries
  describe **one concrete configuration** and are chained, they do not
  advertise capability masks. A format claiming everything is silently
  dropped by CGL.

## Performance work, measured

Paired A/B on the Mac Studio (alternating builds, medians, so drift cancels):
the night's emulator changes measured **+5.9%** over the build in the app
(50.9 -> 53.9 fps at the Warcraft menu). Those changes: exploit-hardening
compiler flags off, JIT write-protect state cached, bring-up diagnostics
gated behind `PPCGPU_DIAG` (including a per-draw CRC32 that ran forever), a
display surface no longer rebuilt on every page flip, and the register-name
lookup no longer evaluated twice per MMIO access for loggers that are off.

**The Mac Studio runs the same scene at ~51 fps against ~26 on the MacBook
Air.** The Air has been the limiting factor throughout.

## Things I got wrong, and what fixed them

- **Three "regressions" that were not real.** An unchanged build measured 27
  fps early in the session and 15 fps hours later: a fanless Air, thermally
  throttled. Every comparison against an older number was meaningless.
  Fixed by `scripts/abtest.sh`, which alternates builds and reports a ratio.
- **A stale VM held the guest's SSH port for two hours**, so the harness
  measured the wrong guest while stealing a core. `smoketest.sh` now refuses
  to start when the port is taken.
- **`nc -z` on a forwarded port was a false positive** -- slirp accepts
  connections whether or not the guest listens. Boot detection now waits for
  the guest's own console output.
- **Two measurement loops killed each other's VMs**, and later I replaced
  `measure.sh` while a run was using it. `measure.sh` now takes a lock.
- **A `static __thread` in a header** gave every translation unit its own
  copy of the JIT write-protect state, so one file's idea of it let another
  skip a switch it needed. That one did not boot at all.

The pattern in all of these: the emulator was fine and the measurement was
not. Every one was caught by a control run rather than by reasoning.

## The first thing to run in the morning

Start the VM with the device present:

    POWEREMU_PARAVIRT_GPU=1 open build/PowerEmu.app

Then push the kext and the transport test in (both are built and staged,
`guest/gpu/build/` and `guest/gld/build/`):

    scripts/push-guest-gpu.sh

and in the guest, load it and run the test. The `sudo` lines are yours to
type -- I do not run sudo in the guest and do not want your password.

    sudo chown -R root:wheel /tmp/PowerEmuGPU.kext
    sudo kextload -t -v 6 /tmp/PowerEmuGPU.kext     # validate only
    sudo kextload -v /tmp/PowerEmuGPU.kext          # load
    /tmp/petest

`petest` prints one of a small number of things, and each points somewhere
different:

| it says | it means |
|---|---|
| `open: no PEGpuAccelerator service` | the kext did not attach -- check `dmesg` for `PEGpu:` |
| `open: the device's memory could not be mapped` | it attached but `clientMemoryForType` did not work |
| `open: the device speaks a protocol...` | the BAR is not ours; the app is not running with the device |
| `FAIL: fence N never reached` | the doorbell did not reach the host: kext or mapping |
| `FAIL: ... pixels are not 11223344` | the host got the batch and did not execute it: device |
| `PASS: 16384 pixels written by the host...` | **the whole transport works** |

## Next

1. **Load the kext** (yours to do -- admin in the guest). Then
   `gldInitializeLibrary` will log either `device: ok` with the host's
   feature bits, or exactly why it could not attach.
2. Capture a real GL trace through the shim (`PEGLD_PROXY`) from an actual
   application, to see which entry points matter before implementing
   `gldInitDispatch` -- it writes 17 function pointers and two mask sets,
   and a wrong guess there crashes rather than warns.
3. Then route those calls into the ring. Both halves of the transport now
   exist and agree; what is missing is the translation from GL state to
   PEGpuState and from GL primitives to PEGpuDraw.
4. Independently of all of this: the million type-0 register writes a second
   are decoded through the full MMIO switch. That is a contained
   optimisation needing no guest driver at all, and given that 99.5% of GPU
   register traffic never traps, it is where the remaining emulator win is.
