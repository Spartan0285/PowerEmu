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
        PEAudioNDRV.c -lDriverServicesLib -lNameRegistryLib -lInterfaceLib
    $T/bin/MakePEF peaudio.so -o PEAudio.ndrv

Three things that are not obvious:

  - `-std=gnu99`.  GCC 16 defaults to C23, where `false` is a keyword, and
    Apple's `MacTypes.h` declares it as an enumeration constant.
  - `-nostartfiles -nodefaultlibs`.  A driver wants neither Retro68's
    startup nor its C runtime, and the default spec pulls in `retrocrt`,
    which does not exist for this target.
  - The result is a bare PEF -- `Joy!peffpwpc` in the first twelve bytes --
    with no resource fork and no Rez step.
