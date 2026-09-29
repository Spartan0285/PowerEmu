# Radeon 9800 Pro bring-up

29 September 2026. Target: a real R350 rendering path for PowerEmu, ultimately usable by Final Cut and Motion. **Current status: the isolated prototype boots a coherent 1680×1050 Leopard desktop through the stock R350 driver, with Quartz Extreme and Core Image active and more than 2,000 accepted Metal draws. Some compositor sequences remain gated, the menu-bar output is incomplete, and Final Cut Studio is not validated.**

## What is implemented

The emulator has a separate `ppc-mac-r350-probe` QOM device with ATI PCI ID `1002:4e48`. The default `ppc-mac-gpu` remains `1002:5960`. The probe logs register accesses with bounded sampling, rejects 3D draws before they reach the incompatible R200 renderer, and disables migration. It is not exposed as a supported GPU in the app.

An opt-in `x-r350-bridge-aic=on` experiment translates the driver's AIC aperture using the UniNorth AGP page table when the local AIC table base is zero. It is restricted to the probe. This is an empirically successful compatibility experiment, not a completed model of R350 address translation.

Changes are in `poweremu-qemu/hw/display/ppc_mac_gpu.c` and `poweremu-qemu/include/hw/display/ppc_mac_gpu.h`. The isolated patch against the source at the start of this investigation is [r350-probe.patch](evidence/r350-bringup-2026-09-29/r350-probe.patch); it excludes unrelated existing worktree changes.

## Rendering foundation added in the follow-up

The restricted R300 fragment compiler in `poweremu-qemu/hw/display/ppc_mac_gpu_r300_fp.c` now translates one texture-free, constant-source MAD instruction into Metal. It supports separate RGB/alpha source banks, verified operand selections, swizzles, absolute value/negation, and explicit saturation. Unsupported state is rejected with a reason. Guest float24 constant decoding is not yet connected; tests supply float32 constants.

`tests/poweremu/run-r300-metal-test.sh` passed on the local Apple M5 and Mac Studio Apple M4 Max. Five cases each compare 3,644 non-edge pixels against independently specified colors and triangle coverage. Rendering uses a private floating-point target, a GPU readback blit, and completed-command synchronization. Negative cases cover unsupported shader state and output-buffer limits. See [test results](evidence/r350-bringup-2026-09-29/shader-tests.txt).

This is a **fragment-decoder test with a fixed host vertex shader**, not a guest-rendered R300 triangle or a functioning desktop. Guest 3D draws remain rejected.

The device now preserves R300 indexed vertex program/parameter uploads at `0x2200`/`0x2208`, including all four words per vector, instead of interpreting them as R200 TCL ports. Invalid indices cannot wrap into the bank. R300 draws are rejected before the R200 asynchronous worker queue. Probe-only state is allocated separately, keeping large diagnostic arrays out of every normal R200 draw-state copy.

Opt-in `x-r350-shader-snapshots=on` logs the first eight draw-time shader/register snapshots, including uploaded vertex words. These are shader-state captures only: geometry and referenced guest memory are not captured, so they are not yet replayable draws.

The final rebuilt probe reached Finder and produced exactly eight bounded snapshots, including the expected four upload words at vertex-program slot `0xfe`. The rebuilt default 9200 also reached Finder with ATIRadeon8500 and PCI ID `5960`. Evidence is in `boot5-shaders-final/` and `boot6-9200-control/`.

The first Leopard capture uses a texture instruction (`PFS_CNTL_0=8`) and ALU offset 2. The restricted constant-only decoder correctly rejects it. This provides the next concrete target: texture input plus the selected ALU slot, followed by the captured vertex program and render-target layout. Do not relax validation just to make this program appear supported.

## Confirmed startup blocker

The stock Leopard 10.5.8 `ATIRadeon9700` driver explicitly matches `0x4e481002`. With the probe it attaches and creates R300 context objects, but initially stalls before Finder starts:

- AIC aperture: `0x07c00000`–`0x0fbfffff`; local `AIC_PT_BASE` is not programmed.
- Bridge AGP aperture: `0x10000000`–`0x17ffffff`; UniNorth has a valid GART table.
- Scratch completion address: `0x07c24000`.
- Existing address handling writes completion stamps into VRAM at that offset instead of the guest RAM expected by the driver.
- The driver stays at `submitStamp=3`, `lastReadStamp=0` even after the extended observation period.

With the bridge-table experiment enabled, scratch writes reach guest RAM, completion stamps advance into the hundreds, WindowServer and Finder start, and the driver submits sustained R300 shader programming and thousands of draws. This establishes that the first startup failure was address translation/completion visibility, not simply a missing PCI identity.

## Test results and limits

Tests used an isolated Mac Studio app, one 7400 CPU, 2 GiB system RAM, 128 MiB VRAM, and temporary snapshot writes against an inactive Leopard base disk. The production app, firmware, and user guest disks were not replaced.

| Test | Result |
| --- | --- |
| Build modified emulator | Passed |
| QMP PCI identity: default and probe | `5960` and `4e48`, respectively |
| Probe without AIC experiment | ATI driver attaches; completion stalls; Finder absent |
| Probe with AIC experiment | Completion advances; WindowServer and Finder run; display online at 1680×1050 |
| Visual output of probe | Coherent 1680×1050 wallpaper, menu text, desktop icon and Dock; incomplete menu-bar composition remains |
| Default 9200 with rebuilt backend | Finder/WindowServer start; ATIRadeon8500 active; 128 MiB display online |

Leopard advertises “Core Image: Hardware Accelerated” and “Quartz Extreme: Supported” with the 9700 driver. These are **driver capability declarations**, not rendering verification. The prototype intentionally rejects unsupported draws. Advancing a command fence is not evidence that its pixels were rendered. Final Cut installation, launch, playback, Motion, and exported output have not been validated.

## Reproduction

Evidence and scripts: [r350-bringup-2026-09-29](evidence/r350-bringup-2026-09-29/). Mac Studio test root: `/Users/adam/Developer/PowerEmu-SMP/r350-probe-20260929`.

- `boot-probe.py`: initial driver attachment.
- `boot-probe-trace.py`: extended failing completion trace.
- `boot-probe-aic.py`: successful completion/desktop-process startup experiment.
- `boot-control.py`: default 9200 control with the same rebuilt emulator.
- `boot3/argv.json`: exact successful probe launch arguments.
- `boot3/gpu-access.log.gz`: detailed register/PM4/completion trace.
- `boot3/screen.png`: actual incomplete rendering output.
- `boot-9200-control/guest.txt`: default-driver regression check.

The isolated OpenBIOS copy had one PCI VGA database occurrence changed from `10025960` to `10024e48` to recognize the new device. This is a bring-up shortcut only. The launch also includes the validated 1 GiB PCI `ranges` override described in [the VRAM investigation](LEOPARD-VRAM-AND-RADEON-9800.md). Do not run the probe against an active writable guest disk or treat these machine-specific scripts as a general installer.

## Next implementation gates, in order

1. **Capture complete state at a draw boundary.** Add generation-specific R300 register state, including indexed vertex program uploads, constants, fragment instructions, render targets, textures, vertex/index buffers, and draw parameters. Capture referenced memory with bounds checks. Current sampled logs and upload traces are useful diagnostics but are not a complete replayable draw fixture.
2. **Prove memory translation independently.** Cover the bridge aperture and AIC alias, page boundaries, invalid entries, nonzero local table bases, scratch/fence writeback, and indirect command buffers. Check that invalid translation cannot silently become a VRAM write. Keep the working 9200 behavior as a control. Replace the probe-only fallback with defined R350 semantics before calling the device supported.
3. **Render one deterministic R300 triangle.** Separate R300 decoding from the R200 renderer. Start with known vertex data, a minimal vertex program, constant-color fragment output, viewport/scissor, and an offscreen target. Compare readback pixels with explicit expected values. Retain explicit rejection for unsupported operations.
4. **Implement the WindowServer path captured here.** Add texture sampling, blend/depth state, formats, pitch/tiling and write masks needed by actual startup draws. Translate R300 vertex/fragment programs to cached Metal functions. Cache by complete shader/state dependencies; never reuse R200 shader interpretation for R300 words. Verify clears, copies, and readback as well as drawing.
5. **Tie completions to finished rendering.** Guest-visible fences must follow required host GPU work and memory visibility. Test render-to-texture followed by sampling, CPU readback, and repeated surface reuse. Only then use a clean desktop plus independent Core Image/OpenGL pixel tests as the acceleration gate.
6. **Validate applications before optimizing.** Confirm the user's Final Cut Studio version; install from legitimate media and test timeline playback, effects and exported frames. Test Motion separately. Repeat on Tiger, then SMP and Harmony. Do not infer full-suite compatibility from installation success or a card name.

A useful primary register reference is the Linux Radeon [R300 register definitions](https://github.com/torvalds/linux/blob/master/drivers/gpu/drm/radeon/r300_reg.h). In particular, R300 fragment program control begins at `0x4600`; the texture and ALU instruction banks differ fundamentally from the current R200 path. Consult the source license before incorporating implementation code.

## Shipping boundary

Keep the 9200 as the shipping default. Do not add a “Radeon 9800 Pro supported” selection, bypass application GPU checks, or present the driver's advertised capabilities as acceleration until deterministic rendering, synchronization and application validation pass. The host fragment-decoder triangle test now passes. The next milestone is a triangle driven by guest vertex and fragment state, followed by a correctly composited Leopard desktop.


## Overnight continuation: real shader and draw replay

An active Codex goal now tracks continued work toward Final Cut Studio confidence. The installer version/media location has been requested asynchronously; graphics work continues independently.

Implemented since the initial fragment test:

- Fragment program bank addressing, single-node texture sampling (TEX/TXP), temporary register dataflow, paired RGB/alpha read-before-write semantics, partial write masks, and relocated instruction ranges.
- Vertex shader translation for DOT/MUL/ADD/MAD, indexed program/constant ranges, input/output linkage validation, and OpenGL-to-Metal clip-depth conversion. Branching and unsupported operations are rejected.
- S16E7 normal/zero constant decoding and immediate vertex-stream decoding, including float attributes, unsigned packed colors, lane swizzles and bounds checks.
- A standalone synchronous Metal renderer that uploads existing destination contents, renders, waits for completion, and reads back before changing host destination memory. Its bounded pipeline cache includes shader code and color-write state; constants and textures remain per-draw inputs.

The first Leopard vertex and fragment programs now pass pixel tests together on Apple M5 and M4 Max with synthetic geometry. The new `boot7-geometry` run captured the real first quad (49 packet words), its uploaded programs, and VRAM. The local replay fixture is `/Users/adam/Developer/PowerEmu/build/r350-replay/` (`draw1.json`, `texture0.bin`). The full VRAM capture stays in the isolated Mac Studio test directory.

`tests/poweremu/run-r300-replay-test.sh <fixture-directory>` passes on the local M5. Six checks each cover all 786,432 pixels of a 1024×768 target: the captured quad/texture/programs; changed constants with a cached pipeline; changed texture with a cached pipeline; scissor preservation; channel-mask preservation; and no destination modification after unsupported-shader rejection. This is an **offline linear-target replay**, not yet an in-guest render or a validation of guest tiling/scanout.

AMD's [R3xx register guide](https://www.x.org/docs/AMD/old/R3xx_3D_Registers.pdf) and current Mesa [register definitions](https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/gallium/drivers/r300/r300_reg.h) exposed incorrect guesses in the older Linux reference: texture-code offset starts at bit 13, node sizes are count-minus-one, and vertex constant limits are inclusive. The decoder/tests were corrected accordingly. These sources supersede the older reference when they disagree.

The decoder/backend is now connected to an explicitly selected R350 rendering experiment, with strict state/resource checks. The existing emulator uses linear VRAM for its 2D path; the interaction with R350 tiled render-target declarations must be tested explicitly before claiming correctness. Blending, more shader operations, other primitives, formats, render-to-texture, depth/stencil and application validation remain outstanding.


### Live rendering checkpoint

`boot9-alpha` on the Mac Studio successfully rendered the initial textured Leopard draws. The full screenshot still shows severe corruption. Unsupported draws include point-based copies, vertex-processing bypass clears, other interpolator routes, blending, shifted viewports and indexed geometry. System Profiler reports hardware acceleration because the stock driver attached; this is not proof of working acceleration.

`boot10-failures` captures the first occurrence of distinct rejected states, with bounded shader and packet snapshots. Its window-compositing state uses premultiplied-over blending (`CBLEND=27210007`, `ABLEND=27210000`) and nonzero viewport origins. Those paths have now been implemented and pass whole-target pixel comparisons, including blend state changes and untouched destination pixels. Triangle lists, fans, strips and independent quads have checked index expansion. A fresh isolated guest run is in progress.

All guest runs use disposable snapshots of the inactive diagnostic Leopard disk. Production VMs and the default 9200 path have not been switched to the experimental renderer. No Final Cut Studio installer has been found in project assets; installation and application rendering remain untested.

### Coherent desktop and expanded compositor checkpoint

The critical full-screen corruption was a presentation-stride error. Leopard renders the visible 1680-pixel desktop into a 1728-pixel physical row (6912 bytes), while scanout previously advanced by 6720 bytes. The R350-only experiment now retains the render target's physical pitch when it presents that buffer. `boot21-stride-inference` was the first coherent desktop; later `boot34-multi-route`, `boot36-octa-route`, and `boot39-scalar-math` retained that result.

The live path now handles target endian modes used by Leopard, premultiplied blending, non-square point expansion, multiple fragment nodes, four- and eight-input rasterizer routes, RS-generated constants, and Apple's partially written vertex temporaries. Fragment support now includes presubtract sources, output scaling, paired DP3/DP4, compare/min/max/fraction operations, and scalar fraction/exponent/logarithm/reciprocal/reciprocal-square-root operations. Pixel tests run through Metal and cover DP4, logarithm, reciprocal and component compare in addition to the earlier shader cases.

Two paths remain deliberately gated because live evidence showed visible regressions:

- The dual-texture draw produces a correct Dock shelf in isolated before/after capture, but committing the full live sequence removes the Dock. This points to render-target lifetime, ordering or synchronization around the sequence rather than basic sampling.
- A compact four-input RS route is correct when `US_PIXSIZE` exposes all four registers. The otherwise identical low-limit variant removes the Dock and remains rejected until its preceding sequence and live-register contract are understood.

The current clean evidence image is `/tmp/pe-r350-boot39-screen.png` on the development Mac. It has no full-screen smearing or wallpaper distortion; the small uncomposited area at the upper right and faint menu bar show that this is still a bring-up build. Final Cut Studio should not be installed into the diagnostic guest until those compositor gates and render-to-texture synchronization tests pass.

### Tiger 10.4.11 checkpoint

The same backend was booted against a verified Mac OS X 10.4.11 disk in snapshot mode. Tiger loaded `ATIRadeon9700` 4.1.8 for PCI ID `1002:4e48`, exposed 128 MB VRAM at 1680×1050, and reported Quartz Extreme and Core Image support. The desktop is not visually correct: large Finder window regions are stale or misplaced. Of the first 470 submitted draws, 463 rendered and seven were rejected for an interpolator route that differs from the Leopard startup stream. The captured [screen](evidence/r350-bringup-2026-09-29/tiger-104/screen.png), [guest state](evidence/r350-bringup-2026-09-29/tiger-104/guest.txt), and [render summary](evidence/r350-bringup-2026-09-29/tiger-104/render-summary.txt) establish this as a Tiger-specific implementation gap rather than a driver-attachment failure.

`scripts/build-r350-app.sh` now produces a separately identified `build/PowerEmu 9800 Test.app`. Its bundle marker selects the R350 device and validated bridge/linear-render switches without changing VM configuration files or exposing the unfinished card in normal PowerEmu. The standard app remains on the Radeon 9200.
