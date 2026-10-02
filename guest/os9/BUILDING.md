# Building the Mac OS 9 guest code

Retro68 does this on the Mac you are reading this on -- no period hardware
and no CodeWarrior.  The official `build-toolchain.bash` does not finish on
macOS 26 / Apple Silicon, so the working recipe is below.

## Toolchain, once

Dependencies are all in Homebrew: `boost cmake gmp mpfr libmpc bison texinfo`.

    git clone --recursive https://github.com/autc04/Retro68 ~/Developer/Retro68
    mkdir ~/Developer/Retro68-build && cd ~/Developer/Retro68-build
    ~/Developer/Retro68/build-toolchain.bash --no-68k --no-carbon

That builds binutils and GCC and then **fails** linking `LaunchAPPL` with
`_hfs_vsetattr` undefined.  LaunchAPPL launches built apps in Mini vMac; we
have our own emulator and do not need it.  The failure aborts the script
before the Mac interfaces are installed, so finish by hand:

    cd ~/Developer/Retro68-build/build-host
    for t in Rez MakePEF ConvertObj ResourceFiles; do make $t; done
    cp Rez/Rez ConvertObj/ConvertObj Elf2Mac/Elf2Mac PEFTools/MakePEF \
       PEFTools/MakeImport ResourceFiles/ResInfo ../toolchain/bin/

    cd ~/Developer/Retro68
    bash -c 'SRC=$(pwd); PREFIX=~/Developer/Retro68-build/toolchain
      export PATH=$PREFIX/bin:$PATH
      (cd multiversal && ruby make-multiverse.rb -G CIncludes -o "$PREFIX/multiversal")
      mkdir -p "$PREFIX/multiversal/libppc"
      cp ImportLibraries/*.a "$PREFIX/multiversal/libppc/"
      BUILD_68K=false BUILD_PPC=true
      INTERFACES_DIR="$SRC/InterfacesAndLibraries"
      source interfaces-and-libraries.sh
      linkInterfacesAndLibraries multiversal'

`Rez` as built is a Debug build and segfaults on the `--cc` disk-image
outputs (the same libhfs that broke LaunchAPPL).  Build it Release:

    cd ~/Developer/Retro68-build && mkdir -p build-host-rel && cd build-host-rel
    cmake ~/Developer/Retro68 -DCMAKE_BUILD_TYPE=Release && make Rez
    cp Rez/Rez ../toolchain/bin/Rez && cp Rez/Rez ../build-host/Rez/Rez

Then the target runtime:

    cd ~/Developer/Retro68-build && mkdir -p build-target-ppc && cd build-target-ppc
    cmake ~/Developer/Retro68 \
      -DCMAKE_TOOLCHAIN_FILE=../build-host/cmake/intreeppc.toolchain.cmake \
      -DCMAKE_BUILD_TYPE=Release -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY
    cmake --build . --target install

It stops again on the `ConsoleTest` sample for the same `--cc` reason, after
building `libRetroConsole.a` and `libretrocrt.a`, which is all we need.

## Building a program

Do not use Retro68's `add_application`; it goes through the `--cc` outputs
that crash.  Drive the tools:

    T=~/Developer/Retro68-build/toolchain
    B=~/Developer/Retro68-build/build-target-ppc

    # compile as C, link as C++ -- RetroConsole is C++
    $T/bin/powerpc-apple-macos-gcc -O2 -c -o probe.o PEAudioProbe.c
    $T/bin/powerpc-apple-macos-g++ -O2 -o probe.xcoff probe.o \
        -L$B/Console -L$B/libretro -lRetroConsole -lNameRegistryLib
    $T/bin/MakePEF probe.xcoff -o probe.pef
    $T/bin/Rez ~/Developer/Retro68/libretro/RetroPPCAPPL.r \
        -I~/Developer/Retro68/libretro:$T/powerpc-apple-macos/RIncludes \
        -DCFRAG_NAME='"PEAudioProbe"' -o PEAudioProbe.bin \
        --data probe.pef -t APPL -c '????'

## Getting it into the guest

hfsutils comes with the toolchain, so this Mac can write an HFS volume even
though it can no longer mount one:

    python3 -c "open('probe.img','wb').truncate(8*1024*1024)"
    $T/bin/hformat -l PEProbe probe.img
    $T/bin/hmount probe.img
    $T/bin/hcopy -m PEAudioProbe.bin :PEAudioProbe     # -m unpacks MacBinary
    $T/bin/humount

Attach `probe.img` to the virtual Mac as a CD and it mounts.

## Headers

The multiversal interfaces that ship with Retro68 do not cover everything:
there is no `NameRegistry.h`, and nothing of the Component Manager beyond a
few typedefs.  The import libraries do have the symbols, so declare what you
use locally, against Apple's Universal Interfaces 3.4.1 layouts -- which is
what Retro68's own NDRV sample does.  UI 3.4.1 is at
github.com/elliotnunn/UniversalInterfaces if you want the real headers.

## Building an NDRV

Needs Apple's Universal Interfaces 3.4.1 (`github.com/elliotnunn/UniversalInterfaces`)
for `DriverServices.h` and `DriverFamilyMatching.h`, and the linker script and
export list from `github.com/elliotnunn/classicvirtio`:

    T=~/Developer/Retro68-build/toolchain
    U=~/Developer/UniversalInterfaces/3.4.1/Universal/Interfaces/CIncludes
    C=~/Developer/classicvirtio

    $T/bin/powerpc-apple-macos-gcc -o peaudio.so -std=gnu99 -I"$U" \
        -Os -ffunction-sections -fdata-sections \
        -nostartfiles -nodefaultlibs \
        -T $C/ndrv.lds -Wl,-bE:$C/ndrv.exp \
        -Wl,--gc-sections -Wl,--gc-keep-exported \
        PEAudioNDRV.c -lDriverServicesLib
    $T/bin/MakePEF peaudio.so -o PEAudio.ndrv
    python3 fixndrvmain.py PEAudio.ndrv

Three things that are not obvious:

  - `-std=gnu99`.  GCC 16 defaults to C23, where `false` is a keyword, and
    Apple's `MacTypes.h` declares it as an enumeration constant.
  - `-nostartfiles -nodefaultlibs`.  A driver wants neither Retro68's
    startup nor its C runtime, and the default spec pulls in `retrocrt`,
    which does not exist for this target.
  - The result is a bare PEF -- `Joy!peffpwpc` in the first twelve bytes --
    with no resource fork and no Rez step.

## What stops an NDRV running, and how to tell

Four things went wrong here in a row, and none of them reports an error --
the driver is simply never called.  In order of how much time they cost:

  - **Only ROM libraries exist when the driver is prepared.**  A driver
    flagged `kDriverIsLoadedUponDiscovery` is prepared during PCI
    enumeration, before the file system is up, so CFM can connect it only
    to libraries in ROM.  `DriverServicesLib` is one.  `NameRegistryLib`
    and `PCILib` are disk-based and are not: import either and CFM declines
    the fragment.  The node still gets a `driver-ptr` property, because the
    code was read, but never a `driver-ref`, and `DoDriverIO` never runs.
    This is why the BAR address is patched into the image by the loader
    rather than looked up with `RegistryPropertyGet`.

  - **An immediate command must not go through `IOCommandIsComplete`.**
    Mac OS 9 issues `kInitializeCommand` with kind `kImmediateIOCommandKind`
    -- measured, not assumed.  Completing it through `IOCommandIsComplete`
    makes Initialize look like it failed, and Mac OS finalizes the driver
    instead of opening it.

  - **`MakePEF` writes a bogus main descriptor.**  `MakePEF.cc` always sets
    `mainSection = 1` and `mainOffset` to the XCOFF entry; an NDRV is linked
    `-nostartfiles` and has no entry, so the offset comes out `0xffffffff`.
    Apple's own NDRVs ship `mainSection = -1`.  `fixndrvmain.py` writes that.

  - **`nameInfoStr` must equal the node's `name` exactly**, Pascal length
    byte included -- `"\x0cpci1b36,5045"` for a device OpenBIOS names
    `pci1b36,5045`.  The loader also finds the driver in its blob by this
    string, so a wrong one means the driver is not installed at all, and
    the loader prints an empty name to say so.

`PEDriverProbe` answers all of these from inside the guest: it prints every
property Mac OS has on the node, decodes `driver-descriptor` (which is Mac
OS's own parse of your `TheDriverDescription`, so it shows what Mac OS
believes rather than what you wrote), and drives `GetDriverForDevice`,
`InstallDriverForDevice` and `OpenInstalledDriver` by hand -- those return
error codes where the boot path returns nothing.

A working driver looks like this:

    driver,AAPL,MacOS,PowerPC   present, 4642 bytes
    driver-ref                  present (0xFFCF0000) -- the driver was opened
    OpenDriver(".PEAudio")      OPENED, refNum -49

and, with `PEAU_TRACE=1` in the emulator's environment, the host sees the
whole of Initialize:

    PEAU RD 0x00 = 0x50454155      <- ID, 'PEAU'
    PEAU RD 0x04 = 0x00000001      <- VERSION
    PEAU RD 0x08 = 0x00100001      <- CAPS
    PEAU WR 0x24 = 0x0DEFACED      <- we got here
    PEAU RD 0x00 = 0x50454155

## Building the loader

    T=~/Developer/Retro68-build/toolchain
    $T/bin/powerpc-apple-macos-gcc -DTYPE_BOOL -Dbool=_Bool -Dtrue=1 -Dfalse=0 \
        -Wno-scalar-storage-order -Os -e entrytvec \
        -L ~/Developer/Retro68-build/build-target-ppc/libretro \
        -Wl,--section-start=.data=0x100000 -Wl,--section-start=.text=0x200000 \
        -o build/ndrv/ndrvloader ndrvloader.s ndrvloader.c

`ndrvloader.c` `.incbin`s `build/ndrv/allndrv`, so copy the built
`PEAudio.ndrv` there first.  Run it with

    -device loader,addr=0x4000000,file=.../ndrvloader
    -prom-env "boot-command=init-program go"
