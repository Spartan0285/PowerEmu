# Final Cut Pro preview investigation — October 7, 2026

## Verified status at 8:40 AM

Final Cut Pro 6.0 launches in Tiger 10.4.11 with four CPUs reporting 1.67 GHz, 2 GB RAM, Radeon 9800, 256 MB VRAM, and 1680 × 1050 display. The original striped Viewer/Canvas corruption is removed in the latest candidate. Slug renders clean black; the empty Canvas is black with a narrow purple strip at its right edge. Actual video colors/playback are not yet verified. Do not call the full preview issue resolved.

Running app: `/Users/adam/Developer/PowerEmu/build/PowerEmu FCP Texture Binding Test.app`.

A three-second, 720 × 480, 30 fps MJPEG SMPTE color-bar clip has been imported into the unsaved test project. Browser item: `poweremu-fcp-colorbars`. Guest file: `/Users/adam/Desktop/poweremu-fcp-colorbars.mov`. Host copy: `/tmp/pe-fcp/poweremu-fcp-colorbars.mov`. Viewer still displays Slug, and sequence is empty. Browser was inadvertently closed by misaligned automated input at 8:47 AM; restore it with Window → Browser (Command-4) before opening the imported clip. No user project has been overwritten.

Automated guest input is currently unreliable: captured coordinate clicks do not position the guest pointer; seamless mode has alignment/timing errors. CUA typeText produced hyphens instead of the path. Asked the user to open the imported clip and drag it into the empty sequence. Avoid treating these failed inputs as failed video rendering. Use CUA for all UI; SSH/QMP only for diagnostics. Seamless mode was selected in the host VM toolbar for this test.

## Implemented fixes

All changes are in `/Users/adam/Developer/poweremu-qemu`; preserve extensive pre-existing uncommitted work in both repositories.

1. **HALF literal support:** R300 RGB selector 22 and alpha selector 18 mean 0.5. Existing abs/negate modifiers apply. FCP uses negative half. Omitting it rejected valid preview shaders.
2. **Alpha CMP opcode 6:** Select argument 0 when argument 2 >= 0, otherwise argument 1. Tests cover the zero boundary, negative HALF, and literals.
3. **Component-mask-aware temporary validation:** FCP copies r1.YZ into r0.YZ without defining r1.X. Componentwise instructions validate only active lanes; dot products still require their consumed XYZ/XYZW lanes. Inactive temporary lanes initialize to zero. A negative test with an XYZ write still rejects undefined X.
4. **Texture binding across every active fragment node:** FCP starts with an ALU-only node, then samples a texture in the second node. Both device staging and the Metal backend previously scanned only the first node and treated its absent TEX bit as absence of all textures. The compiled shader sampled an unbound texture, producing green. Shared `r300_fp_texture_mask` walks all active nodes with the hardware's first-node TEX exception. Compiler, device staging, Metal binding, resource validation, and dependency/conflict tracking use that mask. The Metal backend validates every active node's bank range before indexing, including cache hits.

Relevant files: `hw/display/ppc_mac_gpu_r300_fp.c/.h`, `hw/display/ppc_mac_gpu.c`, `hw/display/ppc_mac_gpu_r300_metal.m`, `tests/poweremu/r300-metal-test.m`.

These are generic hardware/compiler fixes, not forced-black rendering or Final Cut executable patches. FCP's packed YUV texture (`0000a60c`, 720 × 240, padded pitch) is intentionally sampled as RGBA and converted by the guest shader. Slug bytes `80 10 80 10` represent black. Do not add another YUV conversion to this path.

## Validation

- Full actual-Metal pixel/data suite passes on Apple M5.
- HALF, CMP, and partial-lane tests each validate 3,644 pixels.
- ALU-first/TEX-second test samples image unit 5; relocated-bank test finds units 3 and 5.
- Real queued Metal backend producer/consumer test now uses an ALU first node and TEX second node and verifies red output after ordered render-to-texture. This catches the independent backend binding bug.
- Both captured FCP fragment programs compile.
- Emulator build, app build/signing, deep strict signature verification, and diff whitespace checks pass.
- Live complete candidate: black previews, no stripes or green. Seven primitive assembly rejections remain; no preview shader rejection remains.
- 9200 FCP control, Chess/Warcraft regression, real video colors, and playback still pending.

## Remaining work

1. Open the imported color-bar clip in Viewer and put it in the empty sequence. Verify full image, correct colors, right/bottom edges, scrubbing, and playback. Record screenshots and fresh counters.
2. Investigate the Canvas right-edge purple strip. The captured video target is 768 × 480 with a 720 × 480 viewport; the 48-pixel padded width is a hypothesis to test, not a proven cause. Capture the final compositing draw and compare active width, padded pitch, source texture dimensions, UV/viewport/scissor bounds. Do not guess from the screenshot or mask it with black.
3. Compare the identical FCP case on the 9200. Shut down the guest cleanly before changing GPU; restore the user's 9800 choice afterward. Never run two emulators on the same writable disk.
4. Remaining primitive rejection `VF_CNTL=0x00840822` means 132 line vertices, not a zero-count no-op. Determine whether it affects borders/overlays; add supported behavior only with a real replay/pixel test.
5. Check Chess and Warcraft after generic shader/resource changes.
6. Turn off diagnostic trace flags before handing the build to the user. No commit/release was made.

## Diagnostics and evidence

Original writable disk: `/Users/adam/Library/Application Support/PowerEmu/Virtual Machines/Tiger.poweremu/Disks/tiger-fresh.qcow2`.

QMP socket for this boot: `/var/folders/w4/jybr8qmd72z_fcvht4gbndmh0000gn/T/poweremu-ef54tr.qmp`. Recheck process IDs. SSH localhost:2222; HMP localhost:4444. Helpers: `/tmp/pe-fcp/qmp.py`, `/tmp/pe9800/guest-ssh.py`.

Detailed GPU stderr: VM `Logs/qemu.log`. `gpu-trace.log` is counters, not shader details.

Opt-in runtime QOM `trace` flags:

- `POWEREMU_R350_FAILURE_TRACE`: full failure snapshots, capped at 16 distinct reasons, includes VF_CNTL/packet words.
- `POWEREMU_R350_VIDEO_TRACE`: successful long video pipelines (ALU end >= 15), capped at six distinct pipelines; includes shaders, constants, samplers, vertices. This avoids WindowServer copies exhausting the cap.

Both are default off. UI_TRACE was also used for a bounded compositor capture (32 pipelines, address-keyed). All three runtime trace flags were disabled before handing the running candidate back. Disable via QOM `trace` with the same flag prefixed by `-`. Changing a trace flag increments `pe_env_generation` and resets successful pipeline capture counters, so a new process is not required for fresh captures.

Evidence directory: `docs/evidence/fcp-preview-2026-10-07/`. Includes before/after HALF and CMP logs, full failure snapshots, masked/texture-node/backend pixel-test results, captured fragment replays, `green-video-pipeline.log`, and `black-texture-binding-pipeline.log` from the complete live candidate, and `black-preview-ui-pipelines.log` from the bounded UI capture. At 8:49 AM, 37,011 draws / 14,073 frames had only seven primitive-assembly rejections and no fragment-program rejection.

## Rebuild

```sh
cd /Users/adam/Developer/poweremu-qemu
ninja -C build-r350 qemu-system-ppc64
bash tests/poweremu/run-r300-metal-test.sh
cd /Users/adam/Developer/PowerEmu
POWEREMU_APP_OUT='/Users/adam/Developer/PowerEmu/build/PowerEmu FCP Texture Binding Test.app' bash scripts/build-r350-app.sh
```

Quit the candidate cleanly before replacing that bundle. Keep changes uncommitted until authorized; do not discard audio/SMP/other GPU work already present.
