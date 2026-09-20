# PowerEmuGPU.kext — guest-side driver for the paravirtual GPU

Mac OS X 10.4 (Darwin 8), PowerPC only. Written 2026-09-20.

**Nothing in this directory has ever been compiled or loaded.** It is written
against the 10.4 IOKit interfaces as documented and as used by Apple's own
drivers, and every one of those interfaces is described below under
"What is untested" with how confident it is worth being about it.

## What this is

The device (`hw/display/poweremu-gpu.c` in poweremu-qemu) does all the
drawing. The renderer plugin writes packets into shared memory and rings a
doorbell. This kext exists for two reasons and does nothing else:

1. **It gives Apple's OpenGL something to read `IOGLBundleName` from.** That
   is the property that makes OpenGL load a renderer plugin out of
   `/System/Library/Extensions/`. We publish
   `IOGLBundleName = "PowerEmuGPUGLDriver"`, so OpenGL should load
   `/System/Library/Extensions/PowerEmuGPUGLDriver.bundle`, the same way
   `ATIRadeon8500.kext` gets `ATIRadeon8500GLDriver.bundle` loaded.
2. **It maps the BAR into the plugin's address space.** Two mappings, via
   `IOConnectMapMemory`:

   | type | `kPEGpuMemory…` | contents | size |
   |---|---|---|---|
   | 0 | `Control` | the trapping control page | 4 KB |
   | 1 | `Shared` | the packet ring, then the data area | 33 MB |

   Offset zero of mapping 1 is offset zero of the protocol: every offset a
   packet carries is relative to the ring base, so the plugin can use the
   values from `poweremu_gpu_ring.h` unmodified. There is no whole-BAR
   mapping on purpose, because that would add a silent 0x1000 bias.

It implements no acceleration, parses no packets, and follows no
guest-supplied offset. The host validates all of that already.

## What it publishes

On the matched `IOPCIDevice` nub, under an `IOService` named
`PEGpuAccelerator`:

- `IOGLBundleName` = `PowerEmuGPUGLDriver` — the whole point.
- `IOUserClientClass` = `PEGpuUserClient` — so `IOServiceOpen` works.
- `PEGpuFeatures` — the device's `PE_GPU_REG_FEATURES` word, for debugging.

The plugin can find it with `IOServiceMatching("PEGpuAccelerator")`
regardless of whether OpenGL ever binds it by `IOGLBundleName`. That is
worth knowing: **the mapping path and the renderer-selection path are
independent**, so the transport can be proven end to end from a plain
command-line test program before OpenGL is involved at all.

After it attaches you should see, in `ioreg -l` under the PCI device:

    +-o PEGpuAccelerator  <class PEGpuAccelerator, ...>
        "IOGLBundleName" = "PowerEmuGPUGLDriver"

and in `dmesg` / `/var/log/system.log`:

    PEGpu: attached, features 00000007, GL bundle PowerEmuGPUGLDriver

## Building

On a modern Mac, with the PowerPC Mac reachable over SSH as `pbg4`:

    /Users/adam/Developer/PowerEmu/guest/gpu/scripts/build.sh

(or `scripts/build.sh somehost` for a different machine). The script ships
`Makefile`, `src` and `Resources` over with `ditto`, runs `make` there, and
brings `build/PowerEmuGPU.kext` back. It never touches the guest.

This cannot be cross-built. GCC 6.5 in the `ppcbuild` VM does not compile
Apple's 10.4 kernel headers, and a 10.4 kext needs Apple gcc 4.0's C++ ABI
or its vtables will not resolve at load time. The GL plugin *can* be
cross-built; only the kext is stuck on the G4.

## Installing and loading, in the guest

`kextload` on 10.4 refuses a bundle that is not owned by `root:wheel` with
sane permissions, and `ditto` brought it back owned by you, so this is not
optional:

    sudo chown -R root:wheel PowerEmuGPU.kext
    sudo find PowerEmuGPU.kext -type d -exec chmod 0755 {} \;
    sudo find PowerEmuGPU.kext -type f -exec chmod 0644 {} \;

The Mach-O inside `Contents/MacOS/` is 0644 too — a kext executable is never
marked executable. Then:

    sudo kextload -t -v 6 PowerEmuGPU.kext    # validate, do not load
    sudo kextload -v PowerEmuGPU.kext         # load
    kextstat | grep poweremu
    sudo kextunload -b com.spartan0285.poweremu.gpu

To have it load at boot, put it in `/System/Library/Extensions` and rebuild
the cache:

    sudo cp -R PowerEmuGPU.kext /System/Library/Extensions/
    sudo touch /System/Library/Extensions
    sudo kextcache -k /System/Library/Extensions

### Security caveats, such as they are on 10.4

There is no SIP, no kext signing, no notarisation, no staging and no user
approval on 10.4 — the entire gate is "are you root and is the bundle owned
by root". That cuts both ways:

- **Loading is trivially easy**, which is why the permission fix above is
  the only ceremony there is.
- **A bug here panics the guest.** There is no containment. If the guest
  will not boot after installing this, boot single-user (hold Cmd-S), then
  `mount -uw /` and `rm -rf /System/Library/Extensions/PowerEmuGPU.kext`
  and `rm /System/Library/Extensions.mkext`, then `reboot`.
- **The user client is unprivileged on purpose.** Requiring admin would
  exclude every ordinary GL application, which is most of the point. Build
  with `-DPEGPU_REQUIRE_ADMIN=1` to change that; the threat model that makes
  it acceptable is at the top of `src/PEGpuUserClient.cpp` and is worth
  reading before deciding either way.
- **One client at a time.** The ring, the tail pointer and the 64-entry
  texture table are singletons in the protocol, so the second `IOServiceOpen`
  is refused in the kernel. If Quartz Extreme's WindowServer takes it, no
  application can, and vice versa. Multiplexing is a protocol change, not a
  kext change.

## Design notes

### The doorbell is a store, not a method

The plugin rings the doorbell by storing the new ring head to the mapped
control page. It does not call into the kernel.

- A store to mapped device memory is **one QEMU MMIO exit**. An external
  method is a Mach trap — hundreds of emulated guest instructions through
  the trap vector and IOUserClient's dispatch — that ends in *the same
  store*. The device exists to take the guest kernel out of the submission
  path; putting it back for the one remaining trap gives away part of the
  win.
- The kernel adds no safety the host does not already provide. The host
  range-checks the head and every offset in every packet before it
  dereferences anything, and latches an error instead of clamping.
- It matches what Apple's stack does. `ATIRadeon8500GLDriver.bundle`'s only
  IOKit calls are `IOServiceOpen`, `IOConnectAddClient`, `IOConnectMapMemory`
  and `IOServiceClose` — no method-call verb at all, so whatever it submits
  through, it submits through a mapping. Writing a plugin whose IOKit
  vocabulary is the same as Apple's is the cheapest way to stay on paths
  that are known to work on 10.4.
- It keeps the kext small, and the kext is the piece we can least afford to
  debug.

`kPEGpuMethodDoorbell` exists anyway as an escape hatch. If user-space
stores to device memory misbehave on 10.4 PPC, the fallback is already in
the binary instead of being another round trip to the G4.

### The PCI ID — recommend changing the device ID

**Keep vendor `0x1b36`.** It is Red Hat's, it is the vendor QEMU-invented
devices are supposed to use, and inventing one risks colliding with a real
manufacturer.

**Change the device ID away from `0x1050`**, for two reasons:

1. `0x1050` is the modern-virtio device ID for **virtio-gpu** (`0x1040 +
   16`) under vendor `0x1af4`. Same number, adjacent vendor, same job: every
   `lspci` dump, every bug report and every grep through this tree will
   invite the confusion, and one day someone will "fix" a driver against the
   wrong device.
2. `0x1b36:0x1050` is unclaimed upstream today, but upstream allocates 1b36
   device IDs from the low end and documents them in
   `docs/specs/pci-ids.rst`. Picking a number in the range upstream is
   walking through means a future rebase can collide.

Something clearly outside both — say `0x1b36:0x5047` ('PG' in ASCII, which
is at least self-documenting next to the `'PEGP'` magic) — costs one line in
`pe_gpu_class_init()` and one string in `Info.plist` and nothing else.
Worth doing now, while nothing is installed anywhere.

Two related suggestions:

- **Set subsystem vendor/device as well.** The device sets neither, so the
  subsystem register reads as zero. Giving it a PowerEmu-specific subsystem
  ID costs nothing and leaves room to tighten matching later with
  `IOPCISecondaryMatch` without disturbing `IOPCIMatch`.
- **Keep the class at `DISPLAY_OTHER`.** Not `DISPLAY_VGA`. The emulated
  R200 must stay the boot display — Quartz Extreme gates on recognising it,
  and it is the fallback for everything that does not go through the plugin.
  A second VGA-class device is an invitation for Open Firmware to make a
  choice we do not want it to make.

## What is untested

All of it. To be specific about which parts are which:

**Confident.** These are ordinary 10.4 IOKit, used the way Apple's samples
and drivers use them:

- `IOPCIMatch` as `device << 16 | vendor`; the verified
  `ATIRadeon8500.kext` value `0x59601002` has exactly this shape.
- `IOUserClient::clientMemoryForType` returning a retained
  `IOMemoryDescriptor` that the family releases, and `IOConnectMapMemory`
  mapping it into the task.
- `IODeviceMemory::withSubRange` for carving the control page and the shared
  area out of BAR 0, and `setMemoryEnable(true)` being required before the
  BAR decodes at all under QEMU.
- Big-endian: the guest is PowerPC and the protocol is big-endian, so plain
  `volatile UInt32` accesses to the control page are already correct. There
  are no swaps in this code and none are missing.
- The `root:wheel` / 0644 requirement and the absence of any signing gate.

**Guesswork, in rough order of how likely it is to bite.**

1. **Whether OpenGL will bind a renderer to a service with no framebuffer.**
   This is the big one. On 10.4, renderer selection goes through the
   accelerator associated with a *display* — `CGLQueryRendererInfo` takes a
   display mask, and the plumbing under it finds an accelerator from an
   `IOFramebuffer`. Our device deliberately has no framebuffer, because the
   emulated R200 has to stay the boot display. It is entirely possible that
   `IOGLBundleName` is read but never reached, and that making OpenGL
   consider us requires attaching to the R200's framebuffer instead of to
   our own PCI nub, or conforming to `IOAccelerator` in a way an `IOService`
   subclass cannot. **Prove the transport with a direct
   `IOServiceMatching("PEGpuAccelerator")` test program first** — that path
   does not depend on any of this — and only then find out what OpenGL
   wants.
2. **Whether an `IOService` subclass is enough.** The guest's real stack
   instantiates `IOATIR200Accelerator`, `ATIR200GLContext`,
   `ATIR2002DContext`, `ATIR200Surface` and has an `IOAccelerator` in the
   registry. We subclass plain `IOService` because `IOAccelerator` is not in
   10.4's public kernel headers. If OpenGL requires an `IOAccelerator`-shaped
   provider, or requires the plugin to be handed a surface object, this kext
   grows considerably. Properties worth trying, in the personality, if
   binding fails: `IOAccelRevision`, `IOAccelIndex`, `IOAccelTypes`,
   `IOAccelerator` as a match category. All of those are guesses — none was
   read off a live system.
3. **`connectClient`.** Returning `kIOReturnSuccess` is a deliberate stub so
   that a plugin calling `IOConnectAddClient` does not get
   `kIOReturnUnsupported` and give up. What Apple's drivers actually *do*
   there — associate a 3D context with a 2D one — has no analogue here yet.
4. **The build glue.** The `kmod_info` generation, `-lkmodc++ -lcc_kext
   -lkmod` in that order, and `-fapple-kext` are reconstructed from Xcode
   2.x's kext template rather than copied from a working build. If anything
   in this directory fails on the first attempt it will be here, and the
   symptom will be either an unresolved `_start`/`_kmod_info` at link time
   or an unresolved vtable at `kextload` time. `-mlong-branch` may draw a
   deprecation warning or an error from gcc 4.0; it is isolated in
   `PPCFLAGS` for that reason.
5. **`OSBundleLibraries` versions.** Declared as the Darwin 8 floors.
   `com.apple.kpi.*` is available to PPC kexts on 10.4, but if the loader
   objects, `kextlibs -xml PowerEmuGPU.kext` on the build machine prints
   what it actually wants.
6. **Mapping 33 MB of device memory into a user task.** Should be
   unremarkable — real video cards map larger apertures — but it has not
   been done here.
7. **`IOExternalMethod` with a `UInt32` parameter.** Correct on 32-bit PPC
   and nowhere else. This kext has no other target, so that is fine, but it
   is not portable code and should not be copied as if it were.

## Layout

    Makefile              builds the bundle on the PPC Mac
    scripts/build.sh      ships source there, brings the bundle back
    Resources/Info.plist  CFBundle keys and the IOKitPersonalities
    src/PEGpuShared.h     the kext/plugin ABI; mapping types, registers
    src/PEGpuAccelerator.{h,cpp}   the IOService that owns the BAR
    src/PEGpuUserClient.{h,cpp}    the connection, and the threat model
