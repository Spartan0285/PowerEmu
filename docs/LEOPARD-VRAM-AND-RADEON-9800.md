# Leopard VRAM startup and Radeon 9800 investigation

29 September 2026. These are separate compatibility issues.

## Leopard startup: confirmed firmware range mismatch

The shipped emulator maps the UniNorth PCI memory aperture from `0x80000000` through `0xbfffffff` (1 GiB). The bundled SMP OpenBIOS still advertises only `0x80000000` through `0x8fffffff` (256 MiB) in the PCI node's `ranges` property. Increasing VRAM changes PCI BAR allocation:

| VRAM | Framebuffer | GPU registers | Ethernet registers |
| --- | --- | --- | --- |
| 64 MiB | 0x84000000–0x87ffffff | 0x88000000 | 0x88200000 |
| 128 MiB | 0x88000000–0x8fffffff | 0x90000000 | 0x90200000 |
| 256 MiB | 0x90000000–0x9fffffff | 0xa0000000 | 0xa0200000 |

At 128/256 MiB, device registers are outside the firmware-advertised range. Leopard loads its kernel and starts services but cannot finish normal desktop startup; a verbose screenshot reports no network interfaces. This is not a guest system-RAM shortage.

Earlier work widened the emulator's aperture, and the launcher also capped installer VRAM at 64 MiB. The matching firmware declaration was still missing from the SMP path. The old launch comment claiming installed guests worked at full VRAM was insufficient evidence for Leopard.

### Fix

`VMRunner.swift` now sets the PCI `ranges` property to match the emulator's 1 GiB aperture before boot, preserving the existing 8 MiB I/O range. This works with the validated SMP firmware without rebuilding or replacing that firmware. The firmware VRAM property now also uses the effective device size when the installer cap applies. Installer capping remains conservative until separately retested.

For a future firmware release, move the PCI memory range correction into the mac99 OpenBIOS platform description and verify its allocation limits/`available` property as well. Do not widen unrelated machine families. Keep the launcher compatibility override until all supported bundled firmware versions agree.

### Controlled tests

Mac Studio, latest packaged emulator, identical inactive Leopard 10.5.8 base disk, temporary snapshot writes only, 2 GiB system RAM, two guest CPUs, same firmware and devices. Existing user/test guests were not stopped or modified.

- Original firmware declaration: 64 MiB reached Finder and SSH in 23 seconds. 128 and 256 MiB did not offer SSH within the 210-second test window; QEMU remained running. PCI BARs, memory map and verbose screen were captured.
- Expanded firmware range: both larger sizes regained graphics and networking. A repeat requiring Finder to be running passed at 128 MiB (21 seconds) and 256 MiB (24 seconds).
- Final repetition using the exact `boot-command` generated from the modified Swift launcher: 64/128/256 MiB all reached Finder and SSH (27/28/29 seconds). The new app built successfully and passed strict deep signature verification.
- System Profiler reported the selected VRAM sizes, AGP, Quartz Extreme supported, and **Core Image: Software**. VRAM capacity does not add shader features.

These are boot/driver-attachment checks, not sustained GPU-memory stress, suspend/resume, or Final Cut compatibility tests. Evidence and reproduction scripts are in `docs/evidence/leopard-vram-2026-09-29/`.

## Radeon 9800 Pro: diagnostic bring-up underway

The earlier review is `/Users/adam/QEMU Project/RADEON_9800_FEASIBILITY.md`. Current hardware identifies as ATI 0x1002:0x5960 and implements the Radeon 9200/R200-family path. Its Metal renderer is not an R300/R350 shader implementation. Changing the PCI ID alone would select a driver whose register and rendering requirements are not implemented.

For Final Cut Studio 2, Apple requires an AGP/PCIe Quartz Extreme card. Motion 3 explicitly supports the Radeon 9800 family and requires at least 128 MB VRAM for 16/32-bit rendering. Color lists newer supported graphics configurations, so a 9800 model does not establish support for the entire suite. [Apple's specifications](https://support.apple.com/en-asia/112603).

### Concrete implementation order

1. Preserve the existing 9200 as the working default. Add a separately selected experimental 9800 model, initially one guest CPU to simplify driver debugging.
2. Implement and trace R350 device discovery, firmware/NDRV properties, MMIO initialization, command submission, fences and interrupts until the stock guest ATI driver attaches. A displayed desktop is only the first gate.
3. Build deterministic rendering tests: clear, triangle, texture, blending and depth; then translate R300-family vertex/fragment programs to cached Metal shaders. Share allocation/presentation infrastructure where semantics match, keeping generation-specific decoding separate.
4. Verify offscreen rendering, texture formats, floating-point targets, CPU/GPU synchronization and readback. Run Core Image tests and verify actual accelerated rendering, not only an advertised capability.
5. Test the chosen Final Cut Studio version with legitimate installation media: installation and launch, SD timeline playback, effect rendering and exported-frame correctness. Validate Motion separately; do not promise Color support from the 9800 target.
6. Repeat on Tiger and Leopard, then two CPUs and Harmony, including higher-VRAM allocation pressure. Optimize only after output correctness is demonstrated.

The exact Studio version remains to be confirmed. A subsequent isolated prototype now attaches the stock Radeon 9700 driver and resolves its initial completion stall using an experimental bridge/AIC translation. R300 rendering remains unimplemented, and Final Cut is untested. See [Radeon 9800 bring-up](RADEON-9800-BRINGUP.md) for code changes, evidence, reproduction, and implementation gates.

## Build for user testing

`build/PowerEmu VRAM Fix/PowerEmu.app` includes the previous Harmony changes and Tools 2.19. The VRAM fix is host-side; it requires a full VM stop/start so firmware runs again. Resuming a saved machine or reconnecting to its running backend does not apply the new boot command.
