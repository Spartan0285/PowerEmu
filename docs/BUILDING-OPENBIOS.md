# Building the patched OpenBIOS firmware

The firmware had been taken as a prebuilt artifact ("obtained from the
validated Studio handoff and hash-checked, not rebuilt on this Mac"), because
building it on Apple Silicon failed.  It builds now.  This is the recipe and
the one-line reason it did not.

## Why it failed

`make` died in the host-side Forth bootstrap, before any target code:

```
  GEN   bootstrap.dict
panic: segmentation violation at 0x290061c
dict=0xc02900000 here=0xc02900628(dict+0x628) pc=0x0(dict+0xfd700000)
```

A 64-bit dictionary pointer truncated into a 32-bit cell.  The cause is in
`config/scripts/switch-arch`:

```sh
HOSTARCH=`uname -m | sed -e s/i.86/x86/ ... -e s/arm.*/arm/ ...`
```

`s/arm.*/arm/` rewrites **arm64 to arm**.  `longbits()` then reports the host
as 32-bit, `crosscflags` compares it against a 32-bit ppc target, finds them
equal and defines `NATIVE_BITWIDTH_EQUALS_HOST_BITWIDTH` -- which tells the
bootstrap it may keep host pointers in target cells.  On a 64-bit host that is
false, and the first dictionary pointer it stores is truncated.

The tree already carried a fix adding `aarch64`/`arm64` to `longbits()`, but
it could never fire: `archname()` had already collapsed the name before
`longbits()` saw it.  The patch now fixes the normalisation as well:

```sh
-e s/aarch64/arm64/ -e s/armv[0-9].*/arm/ -e s/sa110/arm/ -e s/x86_64/amd64/
```

With that, configure reports `Configuring OpenBIOS on arm64 for ppc`,
`config.mak` gets `HOSTARCH?=arm64`, and the correct
`NATIVE_BITWIDTH_SMALLER_THAN_HOST_BITWIDTH` is defined.

## The toolchain

A `powerpc-elf` cross toolchain and the fcode utilities, once:

```sh
PREFIX=$HOME/Developer/cross/powerpc-elf
# binutils: no makeinfo on a stock Mac, and doc/bfd.info stops the build
make MAKEINFO=true && make MAKEINFO=true install
# gcc: stage 1 only, --without-headers --with-system-zlib
```

Three things that cost time:

  - **binutils must be installed before GCC is built or used.**  Without
    `$PREFIX/powerpc-elf/bin/as`, GCC silently falls back to the host
    assembler and every compile dies with `clang: error: unknown argument
    '-mppc'`.  The earlier failure was binutils' `make` stopping on
    `doc/bfd.info` with Error 127 -- no `makeinfo` -- so it never installed.
  - **Build GCC with a real GCC**, not Apple clang 21: that combination
    produced a `cc1` that segfaulted.  `brew install gcc` and `CC=gcc-16`.
  - **fcode-utils** uses `-Werror` and does not survive a modern clang:
    `CFLAGS="-Wno-error -Wno-unused-but-set-variable -Wno-uninitialized"`.

## Building

```sh
export PATH=$HOME/Developer/cross/powerpc-elf/bin:/opt/homebrew/bin:$PATH
cd roms/openbios
git apply ../../../PowerEmu/scripts/smp/openbios-poweremu.patch   # if not applied
rm -rf obj-ppc
./config/scripts/switch-arch ppc
make -j12
# -> obj-ppc/openbios-qemu.elf
```

Check the configure line says **arm64**, not arm:

```
Configuring OpenBIOS on arm64 for ppc
```

## Checking the result

The binary is stripped, so confirm the device table from the object file
rather than the ELF:

```sh
powerpc-elf-objdump -s obj-ppc/target/drivers/pci_database.o | grep -E '10025046|10025960|10025964'
```

Three entries are expected: `0x5046` Rage 128 (upstream), `0x5960` the RV280
this project emulates, and `0x5964` for a second card (see the second-screen
notes -- an id no ATI kext claims, so the accelerator does not attach to it).

Install it as `openbios-ppc` in the VM app's `Resources/firmware`.
