# A paravirtual sound device for classic Mac OS

Status: **design, not started.** Written 2026-10-01, after the emulated
AWACS was taken as far as evidence could take it.

## Why

Mac OS 9.2.2 bombs in "Apple Audio Extension" on roughly one boot in six
with the sound node present.  Three real defects in the emulated Screamer
were found and fixed along the way -- read-back returning data at the wrong
bit position with the valid bit cleared, the manufacturer ID selecting
Apple's 750 ms recalibration delays, and the host audio voice being torn
down and rebuilt inside a guest MMIO store -- and they took it from 0 boots
in 4 to 12 in 12 on the iteration backend.  It is still 5 in 6 on the
backend PowerEmu ships, and the remaining fault is timing-sensitive.

This is not a local oversight.  Mark Cave-Ayland, who wrote the screamer
device, said on qemu-devel in 2020 that it "can cause random hangs for
MacOS on startup", which is why it was never submitted upstream, and in
March 2025 that the remaining work is "underflow/overflow management of the
DBDMA stream, and also to figure out why MacOS 9 is liable to hang on
startup with screamer".  UTM and ClassicMac carry open issues with the same
"Apple Audio Extension / illegal instruction".

So the emulated-hardware path is a five-year-old open problem in somebody
else's code, being chased through a driver nobody has source for.

## The idea

Do for sound what `ppc-ndrvloader` already does for video: stop emulating a
period chip faithfully, and give the guest a driver of ours that talks to a
device designed to be easy.

Everything that breaks is protocol:

  - the codec serial command link and its busy handshake,
  - Screamer read-back, which only Mac OS 9 and Mac OS X use and which no
    other driver exercises,
  - recalibration and attenuation ramps with manufacturer-dependent delays,
  - DBDMA channel programs, their device-status bits, residual write-back
    and completion interrupts,
  - an input channel whose stop protocol depends on a channel program's
    conditional branch reaching STOP.

A ring buffer and a write pointer have none of it.

## The device

`poweremu-audio`, one page of MMIO, little-endian:

    0x00  ID          r   'PEAU'
    0x04  VERSION     r   1
    0x08  CAPS        r   channels, formats, maximum ring bytes
    0x10  RING_BASE   rw  guest physical address of the ring
    0x14  RING_SIZE   rw  bytes, a power of two
    0x18  RATE        rw  frames a second
    0x1c  FORMAT      rw  16-bit signed stereo to begin with
    0x20  CONTROL     rw  bit 0 run, bit 1 flush
    0x24  WRITE_PTR   rw  guest's producer index, in frames
    0x28  READ_PTR    r   device's consumer index, in frames
    0x2c  STATUS      r   running, underrun sticky

The guest writes frames into the ring and advances WRITE_PTR.  The device
drains at the rate, publishes READ_PTR, and hands frames to QEMU's audio
backend -- the same CoreAudio path the Screamer already uses.  No
interrupts in version 1: the driver polls READ_PTR, which is what a Sound
Manager double-buffer callback wants anyway.  If an interrupt is wanted
later it is one line and a macio IRQ.

Underrun is a sticky status bit and silence, never a stall.  The whole
point is that nothing the guest does can leave the device waiting on it.

## The guest driver -- and the open question

This is the part that decides whether any of it is worth doing.

Classic Mac OS reaches sound hardware through the Sound Manager, which
loads a *sound output device component* -- a Component Manager component of
type `sdev`.

An earlier draft of this document said the device tree names which one, and
that `AAPL,sndhw-plugin-id`, `AAPL,output-component`, `AAPL,input-component`
and `AAPL,port-handler-component` were a hook already waiting for us.  That
is wrong.  Those four properties exist only on Old World machines, next to
`driver-ptr` and `driver-ref`, and their values are Old World ROM addresses
-- they name code inside the ROM, not an extension anyone can supply.  A
New World machine does not have them at all, which our own device tree
confirms: the `sound` node carries `sound-objects`, `#-detects`,
`#-features` and no `AAPL,*-component` of any kind.

What a New World Mac OS 9 actually uses is an `sdev` living in the Mac OS
ROM, and it is 68k code -- SheepShaver finds that `thng` by scanning the
ROM for type `sdev` subtype `sing`, and splices 68k glue into it.

So a component of ours would have to be registered the ordinary way: a file
of type `thng` in System Folder:Extensions, which the Component Manager
scans at startup.  That is a documented, supported path -- Inside Macintosh
is explicit that third parties may write sound output device components --
but it is a later registration competing with the ROM's, not a slot the
firmware points at.

What is not here is a way to build the component:

  - It is PowerPC CFM/PEF code against the Universal Interfaces, not
    Mach-O.  The G4 builder that compiles PowerEmu Tools runs Xcode 2.5
    with the 10.4u SDK, which builds Mach-O for Mac OS X.  It cannot build
    this.
  - The period tools are CodeWarrior Pro or MPW.  Neither is installed.
  - Retro68 is a modern GCC cross-toolchain that does emit PPC CFM for
    classic Mac OS, and is the only candidate that could be installed from
    nothing.  Whether it can build a Component Manager `sdev` component, as
    opposed to an application or a code resource, is **unverified and is
    the first thing to find out.**

A G3 PowerBook (Pismo) running Mac OS 9 is available, which changes this.
CodeWarrior Pro runs natively there, and it is the toolchain classic Mac OS
components were actually written with -- Apple's own Sound Manager sample
code assumes it, as do the Universal Interfaces.  That turns the question
from "can a modern cross-compiler be made to emit something nobody has
tried" into "can period tools be installed on period hardware", which is a
different kind of risk.  It is the same arrangement the project already
uses for PowerEmu Tools, which can only be built on the G4 because Xcode
2.5 is the only thing that produces 10.4 binaries; a Pismo for CFM is that,
one generation further back.

Better still, it may not need the Pismo.  CodeWarrior is an ordinary Mac
OS 9 application and runs under Classic -- compiling needs nothing Classic
withholds; only its debugger does, and we do not need that.  The Tiger
guest already has a Mac OS 9.2.2 System Folder and runs 9.x apps under
Classic, and PowerEmu Tools already moves files both ways, onto HFS+ this
Mac can read.  That removes the period hardware and the HFS wall together.

What Classic cannot be is the test environment: a sound output component
talks to hardware, and Classic virtualises sound through Mac OS X rather
than exposing the device.  So build in Classic -- in the Tiger guest or on
the Pismo -- and test in the Mac OS 9 guest, which is a native boot.

Against it: this is emulated PowerPC running Tiger running Classic running
CodeWarrior, so compiles will take minutes.  Tolerable for one component,
tiresome if it needs much iteration, and the Pismo booting Mac OS 9
natively is the fallback rather than the plan.

What any of it costs is file movement.  Mac OS 9 has no ssh, so source goes over
AppleShare, an FTP server, or a disc; and the built component has to come
back the same way.  Building inside the Mac OS 9 guest instead would avoid
depending on the hardware, and getting source in is easy -- the Tools disc
is already minted as an ISO -- but getting the result out is awkward,
because this Mac cannot mount HFS and would have to read the guest's disk
with a parser of ours or over the network.

And once built it has to get into the guest, into System Folder:Extensions.
Mac OS X guests have PowerEmu Tools for that; a classic guest has no agent,
so that is a second thing to build -- or, for a first cut, a disc image the
reader drags from.

## Order of work

1. Settle the toolchain question.  Build a trivial `sdev` component and
   get Mac OS 9 to load it and report itself in the Sound control panel.
   CodeWarrior on the Pismo is the likely answer; Retro68 is worth
   checking first only because it needs no period hardware.  If neither
   can do it, the plan stops here and the answer is to keep chasing the
   emulated Screamer.
2. Build `poweremu-audio` in QEMU with a host-side test that drives the
   ring without a guest.  Self-contained, and worth having either way.
3. Publish its node, so Open Firmware maps the page and a driver can find
   it.  This can be done from the Open Firmware boot-command, the way the
   sound node is already edited today, without rebuilding OpenBIOS.  It
   cannot be pointed at from `AAPL,sndhw-plugin-id`; see above.
4. Write the component against the register interface above.
5. Keep the emulated AWACS.  Boot-time sound comes from the Mac OS ROM
   before any extension loads, and a guest without our component installed
   has to keep working.

Step 1 is the whole risk.  Steps 2 and 3 are ordinary work.

## What this does not fix

Mac OS X guests.  They drive the emulated Radeon and the emulated Screamer
with Apple's own drivers and both work; nothing here should touch them.

The crash itself.  A classic guest with our component installed would not
load Apple Audio Extension's AWACS path, so it would not bomb -- but the
emulated Screamer stays as broken as it is for anyone who does not install
it.  Fixing that properly still means finding what Cave-Ayland has not.
