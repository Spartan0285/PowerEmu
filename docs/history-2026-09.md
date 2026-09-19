# Overnight changes, 2026-09-18

All sources below are also copied into this folder (hw/display/, include/,
hcd-ohci.c.*, cocoa.m, excp_helper.c.*, launch-tiger-ati.sh).

## Quartz Extreme

- `hw/pci-host/uninorth.c`: opt-in AGP capability on the uni-north PCI host
  bridge (`agp-capable`), writable GART registers, internal-status ready bit.
  Apple's AppleMacRiscAGP then owns the bus, the R200 driver creates its AGP
  GART and reports AccelCaps = 1, and WindowServer enables the GL compositor.
- Guest: the ATIRadeon8500 driver set was replaced with the 10.4.0 originals
  from the install ISO (`kexts.img:/use-ati-1040.sh`); the 10.4.11 set
  crashed WindowServer against 10.4.0's OpenGL. Backup of the 1.4.18 set in
  the guest at /System/Library/Extensions.ati1418.

## Direct R200 renderer (hw/display/ppc_mac_gpu.c, ppc_mac_gpu_metal.m)

- New path `ppc_mac_gpu_r200_draw()` -> `metal_draw_r200()` for PM4 draw
  packets 0x34/0x35/0x36/0x29: AOS/inline vertex fetch via AGP/GART, TCL
  (MVP, lighting, texture matrices, fog), viewport, primitive assembly,
  scissor + auxiliary scissors, R200 texture combiners, alpha test, in-shader
  blending (framebuffer fetch), plane mask, depth/stencil, textures
  (ARGB8888, RGBA/ABGR8888, I8, AI88, RGB565, ARGB1555, ARGB4444, DXT1/3/5,
  VRAM or AGP resident). Renders straight into VRAM through linear Metal
  texture views — no shadow copies. `PPCGPU_R200_DIRECT=0` restores the old
  path.
- Batching: one command buffer; CPU 2D ops flush only when pending GPU work
  touches their VRAM rows; fences are synchronous (async available with
  `PPCGPU_ASYNC_FENCE=1`).
- TCL vector/scalar constant memory is now modelled (it was dropped before).

## Stability / host

- `hw/usb/hcd-ohci.c`: bound TDs per ED per frame, drop missed frames instead
  of replaying them — both livelocked QEMU when the host was overloaded.
- `ui/cocoa.m`: framebuffer presented as CALayer contents (no float16
  CoreGraphics resampling per refresh).
- Build: -O3, LTO, qom_cast_debug off (~15-20% more guest throughput).
- Launcher: runs a private copy of the binary; AGPBRIDGE now defaults on;
  new switches VERBOSE, TRACE_GPU, TRACE_UNIN, MEM, TABLET.
- Guest disk: a forced quit left a dirty HFS+ journal that OpenBIOS could not
  boot; replaced with a journal-replayed copy. Original kept as
  `tiger-fresh.qcow2.bak-dirtyjournal` (safe to delete once you're happy).

## Debug switches

`PPCGPU_SEQ_LOG=1` (interleaved 2D/3D/packet log, /tmp/gpu_seq.log),
`PPCGPU_DEBUG_LOG=1` (every register access), `TRACE_GPU=on`,
`PPC_FAULT_WATCH=lo-hi` (guest user-mode fault catcher, /tmp/ppc_fault.log).

## Later on 2026-09-18

- Guest updated to 10.4.11 via Software Update; the combo installed the
  matching ATI 1.4.18 set itself. `Accel caps: 00000001`, no driver swap needed.
- Launcher: `ipv6=off` on the user netdev (slirp IPv6 made Tiger stall ~75 s
  per connection; Software Update timed out).
- Chess: 2D PAINT_MULTI/BBM clip dwords parsed (GMC bits 2/3), big-endian
  fills, depth/stencil in VRAM, 24-bit depth rounding fix.
- TCL spot lights (Chess's selection spotlight lit the whole board white):
  HWVSPOT 0x48+i = direction back to the light, scalar 0x10+i exponent,
  0x18+i cos(cutoff); lit when dot(L, dir) >= cutoff.
- Debug: `PPCGPU_TEXLOG=1` logs texture units whose params/texels change;
  `PPCGPU_SPOTLOG=1` logs spot parameters.
- Spot/attenuation: ATTENUATION (0x50+i) is (quadratic, linear, constant);
  Chess's selection spotlight now matches real hardware.
- Hardware cursor: `ndrv-hwcursor/` holds a patched qemu_vga.ndrv
  (`build.py` rebuilds it from `qemu_vga.orig.ndrv`). It reports hardware
  cursor support and forwards the image and position to ppc-mac-gpu regs at
  MMIO BAR + 0xFF00, which call dpy_cursor_define / dpy_mouse_set; the cursor
  is drawn by the host (cocoa cursor layer). `hw/ppc/mac_newworld.c` honours
  `QEMU_PPC_NDRV`; the launcher sets it unless `HWCURSOR=off`.
  Fixes stale cursor-sized notches over GL windows (software cursor
  save-under going stale when the GPU redraws beneath it).
- Debug env checks are cached (no per-draw getenv).
- Host scheduling (the big one): macOS App Napped QEMU and ran it at
  priority 4 (background band, efficiency cores) whenever its window was not
  frontmost or the host was busy. `ui/cocoa.m` now holds an
  NSActivityUserInitiated|LatencyCritical activity, and the TCG vCPU threads
  (`accel/tcg/tcg-accel-ops-{rr,mttcg}.c`) set QOS_CLASS_USER_INTERACTIVE.
  Guest CPU loop 9-11 s -> 3.4 s; window moves 30-35/s -> 82-96/s.
- Guest: Chess "listen for moves" off (`defaults write com.apple.Chess
  MBCListenForMoves -bool NO`); SpeechRecognitionServer cost ~20% guest CPU.
- TCG softmmu TLB floor raised to 1024 entries (`accel/tcg/tb-internal.h`,
  CPU_TLB_DYN_MIN_BITS/DEFAULT_BITS 10). The dynamic sizing had shrunk the
  hot mmu_idx TLBs to 64 entries; ~4M loads/s then conflicted and bounced
  through the victim TLB (mmu_lookup ~37% of the vCPU thread).
- PPC lmw/stmw expanded inline (`target/ppc/translate.c`) instead of a helper
  that probe_access'es the range (~29% of the vCPU thread after the TLB fix).
- Result: guest perl loop 3.4 s -> 1.95 s (after the QoS fix; 9-11 s before
  any of it). vCPU profile now 65% translated code, 27% lookup_tb_ptr
  (indirect branches / blr), ~5% softfloat.

## Warcraft III title screen (afternoon 2026-09-18)

- 2D engine honours the destination datatype (GMC bits 11:8, shared with
  DP_DATATYPE): 8/16/32 bpp for fills, blits, BBM, PAINT_MULTI and host data
  (narrow host data packs 4/bpp pixels per dword, rows dword-padded).
- BBM header: DST_PITCH_OFFSET_CNTL else-branch restored (my clip-parse edit
  had attached it to DST_CLIPPING).
- PM4 0x32 is 3D_CLEAR_ZMASK, not an indirect buffer (the front buffer was
  being executed as commands).  Implemented as a fill of the depth buffer
  with RB3D_DEPTHCLEARVALUE, which resets to all ones (Apple never writes
  it); 0x37 CLEAR_HIZ is a no-op.  0x33 still an IB.
- TCL fog constants: vector 0x5D = (-, c, d, -), not (c, d, ...).
- 16-bit colour render targets (RB3D colour formats 3/4/15): R16Uint view,
  in-shader unpack/blend/pack (`r200_fs16`, `r200_fs16_z`); stale
  "ARGB8888 only" guard removed.
- AOS vertex arrays are one stream (interleaved arrays work).
- SE_VTE_CNTL bit 12 (VTX_ST_DENORMALIZED): texcoords in texels.
- Debug switches: PPCGPU_TRACETEX=fmt:w:h[:agp], PPCGPU_TEXDUMP=1 (with
  PPCGPU_TEXLOG=1) dumps non-32bpp/AGP textures to /tmp/texdump.
- YUV 4:2:2 textures (fmt 10/11, 2 bytes/px), converted on the CPU into a
  BGRA texture; TXOFFSET swap bits kept (`R200TexUnit.swap`).  Format 11
  carries '2vuy' (Cb Y0 Cr Y1) in CPU byte order, format 10 'yuvs'.  The
  Warcraft III Blizzard logo and intro cinematic play with correct colour.
- Guest: moved `~/Library/Preferences/Warcraft III Preferences` to
  `.bak-claude` so the intro would replay (the game recreates it).

## Warcraft III performance (evening 2026-09-18)

- PPC fast FP (`target/ppc/fpu_helper.c` helper_fastfp_ab/acb,
  `translate/fp-impl.c.inc`, `helper.h`): A-form arithmetic makes one helper
  call instead of four and runs on the host FPU when FPSCR is RN, no enables,
  no NI, and nothing is NaN (single ops only when inputs are exact singles;
  fmadds via fmaf).  FPRF kept; sticky exception bits not accumulated on the
  fast path.  PPC_STRICT_FP=1 disables.  Host/guest perl FP sums identical.
- Fence mode default is hybrid (`PPCGPU_ASYNC_FENCE`, 0 sync / 1 deferred /
  2 hybrid): submit, wait up to 1.5 ms, else defer; after a timeout skip the
  wait for 16 fences.
- Rate line counts page flips (CRTC_OFFSET changes) = game frames/s.
- Warcraft III menu: 4-5 fps -> 6-7 (fast FP) -> 17-22 (hybrid fences);
  window moves 98-111/s.
- AGP/GART page -> host pointer cache (`r200_agp_page`, 1024 entries) for
  vertex fetch and AGP texture copies; flushed when uni-north GART registers
  (0x8c-0x97) are written (`uninorth_get_agp_gart_gen()`) and at every fence.
  Window moves 114-149/s; Warcraft III menu 19-26 fps on an idle host.

## Resolution switching, widescreen modes, audio (night 2026-09-18)

- 15/16bpp scanout (games' "x16" modes) is expanded from big-endian
  ARGB1555/RGB565 into the 32bpp shadow buffer; it used to be handed to Cocoa
  raw (garbage).  Warcraft III 1280x1024x16 and 1440x932x32 verified,
  including its "Confirm Resolution Change" dialog.
- Widescreen modes: device EDID descriptor 4 is now Established Timings III
  (1440x900, 1680x1050); with `host-aspect-modes=on` also entries 34-37,
  which the patched NDRV (`ndrv-hwcursor/build.py`, table at data 0xd24)
  turns into 1440x932, 1280x828, 1152x746, 1680x1088 (the MacBook's 1.545
  aspect).  The launcher enables it together with HWCURSOR.
- Launcher replaces the QEMU binary by copy+rename: overwriting it in place
  got the next launch SIGKILLed ("Code Signature Invalid").
- Screamer audio (`hw/audio/screamer.c`): TX DMA is pulled at the sample
  rate by a 1 ms virtual-clock timer into a 186 ms ring, FRAME_CNT_REG (which
  Apple's driver polls ~15x/s for position) advances with it, and a 40 ms
  jitter buffer fronts the backend.  1 kHz test tone captured via
  `-audio driver=wav`: 0 dropouts in 4 runs (was 10-20 per 4 s).  Audio
  defaults back to coreaudio.  SCREAMER_DEBUG=1 prints per-second stats.

## Fullscreen (late night 2026-09-18)

- `ui/cocoa.m`: "Enter Fullscreen" (Cmd+F), Ctrl+Alt+F and `-full-screen`
  now use a borderless window covering the whole screen frame, including the
  notch strip (native fullscreen confined the picture to the safe area and
  hid the menu bar with no way out).  Dock hidden, menu bar auto-hides:
  Ctrl+Alt+G releases the mouse so it can be reached.  The menu item reads
  "Exit Fullscreen" while active.  Guest picture is aspect-fit; 1440x932 (or
  another 1.545 mode) fills the 2880x1864 built-in panel edge to edge.
- `QemuWindow` NSWindow subclass so the borderless window can become key.
- Cursor layer: sublayers live in the view's bounds, which `updateBounds`
  keeps in guest pixels, so the position is not scaled.  Measured aligned in
  windowed and fullscreen (arrow sits at the image's 4-5 px padding).
- Launcher: `FULLSCREEN=on` starts in fullscreen.
- Fullscreen follow-ups: the green title-bar button (`-[QemuWindow
  toggleFullScreen:]`) now uses the full-panel mode too, so native
  fullscreen can no longer stack under it.  Relative pointer motion while
  grabbed is taken in `handleEventLocked` (mouseMoved/dragged), because the
  frozen host pointer left AppKit's tracking-area delivery stalled after the
  view was reparented (clicks worked, motion didn't).  Absolute pointer uses
  `convertPoint:` (correct for a centred view).  The cursor layer has no
  autoresizing mask and its bounds/transform are re-asserted on every move;
  `QEMU_CURSOR_DEBUG=1` logs to stderr if they had drifted.
- Below-the-notch modes: NDRV entries 38-39/44-45 become 1440x904,
  1280x804, 1152x724, 1680x1056 (the 1710x1074-point safe area, 1.592);
  EDID ET III bytes e[118]=0xFC, e[119]=0x30 with host-aspect-modes=on.
  Full-panel fullscreen places the guest in the safe area whenever it fits
  there at least as large as on the whole panel (16:10 and these modes);
  1.545 modes still use the whole panel.
- Verified in the guest (2026-09-19): all eight host-aspect modes are offered;
  1440x904 fullscreen sits flush below the notch (67 px strip), full width.
- Guest: Mac OS 9.2.2 System Folder installed at "/System Folder"; Classic
  starts without further updates and runs 9.x apps (Calculator, StarCraft,
  The Oregon Trail installed via The Garden).
