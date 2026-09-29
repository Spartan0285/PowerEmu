# Harmony and SMP implementation checkpoint

> Historical checkpoint. For the newer Tools 2.8 implementation, default rendering path, current build, and remaining validation, see [HARMONY-2.8-CHECKPOINT.md](HARMONY-2.8-CHECKPOINT.md).

September 27–28, 2026. This records actual coding and testing on Adam's Mac, and supersedes the capture assumptions in the earlier Harmony plan.

## Result and limits

**Full, low-latency Coherence is not finished.** Two rendering paths now exist:

- Default Harmony uses Claude's masked desktop with corrected click-through geometry, gesture ownership, normal host window level, a single alpha mask, and immutable frame publication. Guest windows remain one stacking group. Independent geometry and framebuffer delivery can still disagree transiently.
- `POWEREMU_HARMONY_CAPTURE=1` enables an experimental complete-window capture source. Each guest window is a separate host window with its own complete image, including portions covered in the guest. It avoids copying neighboring windows into each other. Capture round trips averaged approximately **85 ms per window** in this local Tiger run; a fair rotation across several windows is not a 30 fps desktop. This is a correctness foundation, not a no-lag claim.

SMP changes are integrated in source and in **`build/PowerEmu Integration.app`**. One CPU remains the default; two CPUs are explicitly experimental. The normal `build/PowerEmu.app` retains the original helper so the already-running Tiger VM is not silently switched between incompatible emulator/saved-state formats. Shut down existing guests normally before moving to the SMP candidate; do not try to carry a sleep snapshot between the legacy PPC32 and experimental PPC64 backends.

The host locked during UI testing. Further host click-through, physical dragging, interleaved stacking, Dock, and toolbar Sleep/Wake validation require unlocking the Mac. No bypass was attempted. Bidirectional drag-and-drop and complete Dock force-quit semantics remain unfinished.

## What changed

### Masked desktop and frame ownership

`VMDisplay.swift`, `HarmonyDesktopGeometry.swift`, and `HarmonySurfaceSnapshot.swift`:

1. Rendering and click-through share the same rounded shape and actual layer transform, including letterboxing.
2. Empty window reports produce an empty mask instead of exposing wallpaper.
3. Global/local pointer observation plus a common-run-loop timer updates click-through. A press latches its owner until release, including host-origin drags across a guest window.
4. Masked mode requests an opaque emulator framebuffer. Applying both GPU tile alpha and the window mask had created stale transparent holes during motion.
5. The masked host window uses normal window level.
6. Published IOSurfaces are immutable copies. Reusing a surface while Core Animation may still read it was an avoidable corruption race. This costs an extra allocation/copy per frame. It does not make the QEMU shared-memory producer or guest geometry protocol atomic.
7. Surface generations reject queued presentations from an old display configuration.

### A usable Tiger backing-store capture API

The standalone probe is `guest/tools/pewindowcapture.m`. The important experimental result:

- `CGContextCopyWindowContentsToRect` captured the probe's own window but returned zero pixels for another application's window.
- **`CGContextCopyWindowCaptureContentsToRect`**, using the caller's connection and a local source rectangle, captured the *entire covered Applications window* correctly on Tiger 10.4.11. Passing the foreign owner's connection returned an empty result.
- The inspected image contained the Applications list behind overlapping Finder windows. No focus cycling was required.

PowerEmu Tools 2.7 adds a request/response `WINDOWFRAME` verb. A response contains window ID, dimensions, encoding, and RGBA pixels; encoding 1 is zlib level 1, encoding 0 is raw. The host validates dimensions and decompressed byte count and owns immutable image data. Capture requests are serialized: one outstanding request, no accumulating frame queue. Resizes that change during capture are rejected. Closed or resized proxies reject incompatible images.

The existing proxy manager's screen-crop, occlusion, and focus-cycling refresh logic is bypassed in this mode. Existing host stacking is retained. A captured image remains valid while its host window moves. The final guest move uses absolute coordinates; the guest now accepts the existing three-field MOVEWINDOW contract as well as the legacy five-field delta request.

Proxy input now derives screen coordinates from the actual NSEvent, rather than sampling a potentially different global pointer position. Right-button events are forwarded. These changes compiled but their final physical interaction behavior awaits unlock.

### Dock lifecycle

The representative helper requests guest quit but stays running until the guest process actually disappears. A guest Save dialog or canceled quit therefore should not remove and then recreate the tile. Host teardown terminates the representative directly. This is not complete Force Quit integration; the system Force Quit action can kill a representative without running its delegate. Do not interpret helper death as proof that the guest app quit.

### SMP integration

Applied focused changes, preserving the pre-existing dirty graphics, disk, and Harmony work:

- Persistent CPU selection with legacy configurations decoding as one CPU.
- Two CPUs labeled experimental; CPU settings locked while running or saved asleep.
- Matching backend/firmware SHA-256 capability record, verified at launch.
- Experimental PPC64 backend running G4 7400 CPUs, dual-CPU wiring/timebase/counters, activity handling, and the handoff's audio changes. Audio remains a known limitation; no audio reliability claim is added.
- Per-vCPU host execution telemetry and HUD rows.
- Launch waits for saved-state detection before choosing cold start or wake.
- Optional isolated application-support directory for test VMs.
- Packaging supports a separate output/staging location and generates capability hashes after signing the nested helper.

The emulator patch range was `cbf06622af306583a97ab0ced0b8733e3ec6f810..8a2e7afd9209a87ecea30d3706e9ac51dbeeaa01` from the Studio experiment, applied to the existing local working tree. This combined local binary is therefore **not byte-identical** to the Studio benchmark binary.

OpenBIOS handoff commit: `77d6155e075d19fc03b5791160a314e074d45ea4`.
Firmware SHA-256: `8f01bb0c217d692f1ae228f57508417cdbd100f422d626a2cfe6a422cdbe747b`.
The artifact is at `build/smp/openbios-smp.elf`. `scripts/smp/openbios-poweremu.patch` preserves the focused firmware source changes relative to upstream `c3a19c1e54977a53027d6232050e1e3e39a98a1b`. Firmware was obtained from the validated Studio handoff and hash-checked, not rebuilt on this Mac.

## Validation and retained failures

- Debug and release Swift builds and the PPC64 emulator build passed.
- Combined bundle deep/strict code-signature verification passed; this is not notarization.
- Regression checks passed for mask holes, corners, overlapping shapes, scaling/letterboxing, empty geometry, immutable surface ownership/stride, and complete-window frame decoding.
- CPU tests passed for legacy config, persistence, invalid counts, one/two-CPU arguments, capability mismatches, and telemetry resets/missing/shared counters.
- Tiger 10.4.11: complete covered-window capture inspected successfully; host proxies displayed the complete Applications image. A first synthetic drag did not establish correct dragging. Input coordinate fixes were made, but the host locked before their final UI retest.
- Leopard 10.5.8: separate APFS copies of the stopped original disk booted using the combined backend with **one and two CPUs**. Original Leopard disk was not booted or modified.
- Saved-state testing created a unique in-memory socket server, saved `PowerEmuSleep`, exited the backend, and relaunched the actual app. `-loadvm PowerEmuSleep`, restored marker, and CPU-count readbacks verified memory restoration. Both configurations passed offline QCOW2 checks afterward.
- The first harness failed because Leopard's `nohup` could not detach in that SSH session. Replaced the harness's launch with fork/setsid; retained the failure.
- The one-CPU retry failed an overly strict exact `kern.boottime` assertion: the reported boot time shifted five seconds. Follow-up verified the unchanged unique in-memory marker and loadvm argument. The initial failure remains recorded. The dual-CPU harness records boot time but uses the actual in-memory marker as the restoration criterion.
- These tests use QMP save/load, not the toolbar's Sleep/Wake interaction. Test guests ended saved/stopped; this does not claim clean guest OS shutdown, audio continuity, physical keyboard/mouse, or a new performance benchmark.

Small reports and the harness are under `docs/evidence/harmony-smp-2026-09-28/`. Larger logs, saved test disks, and guest screenshots are under `build/integration-tests/`. Working logs are in `/tmp/poweremu-harmony-codex/`. Failed attempts were retained, not relabeled as successful runs.

## Build and run

The merged local QEMU source is `/Users/adam/Developer/poweremu-qemu`. The experimental build uses `ppc64-softmmu`, not `ppc-softmmu`:

```sh
mkdir -p /Users/adam/Developer/poweremu-qemu/build-smp
cd /Users/adam/Developer/poweremu-qemu/build-smp
../configure --python=/Users/adam/.poweremu-buildenv/bin/python3 \
  --target-list=ppc64-softmmu --disable-docs --enable-plugins \
  --disable-sdl -Dqom_cast_debug=false -Doptimization=3 -Db_lto=true
ninja -j6
cd /Users/adam/Developer/PowerEmu
bash scripts/build-smp-app.sh
```

`build-smp-app.sh` checks the known firmware hash and builds the separate integration bundle. `scripts/build-app.sh` without overrides builds the normal bundle using its original helper defaults.

Complete-window capture is a developer experiment requiring Tools 2.7:

```sh
POWEREMU_HARMONY_CAPTURE=1 \
  "build/PowerEmu Integration.app/Contents/MacOS/PowerEmu"
```

Then enter Harmony from the app. Default Harmony uses the repaired mask path; `POWEREMU_HARMONY_MASKED=0` without capture selects the old crop implementation only for regression comparison.

## Next work for Claude Code or Codex

1. **Unlock and test the actual interactions.** First-click host holes, guest title drags over host windows, host drags over guest windows, rounded corners, host–guest–host stacking, focus, resize, minimize/restore. Record outcomes and capture timing; do not infer them from screenshots of static windows.
2. **Prove capture performance before enabling it by default.** Measure guest capture, compression, transfer, host decode, and presentation separately. Current ~85 ms round trips across several windows miss the target. Reuse guest bitmap allocations, suppress unchanged captures, prioritize the focused window, and investigate direct backing-store/GPU export for the sustained path. Do not reintroduce screen crops or focus cycling as a shortcut.
3. **Move bulk frames off the control stream.** A bounded separate frame channel prevents large captures blocking menus, focus, and input commands. Add session/window generations, frame IDs, explicit capability negotiation and failure recovery, cancellation, and independent per-window pacing. One in-flight request presently avoids backlog but serializes unrelated windows.
4. **Make focus authoritative.** A frontmost capture window is not necessarily the keyboard-focused document. Use guest accessibility focus notifications, carry application/window identity, and acknowledge activation before delivering a content click to a previously covered guest window. Confirm guest accessibility support before promising move/minimize/menu behavior.
5. **Finish host application ownership.** Representatives currently own Dock icons, while PowerEmu owns all windows. Validate Cmd-Tab, Hide, Quit, Force Quit, and minimizing with this split. Do not treat killing a representative as successful guest force quit.
6. **Implement real drag sessions.** Existing host drops copy to the guest Desktop and ignore the target window. Window-specific destinations, guest-to-host file promises, desktop drops, cancellation, and multiple windows remain separate protocol work. Do not call clipboard or Desktop copying bidirectional drag-and-drop.
7. **Repeat the combined runtime matrix after changes.** Both Tiger and Leopard, one/two CPUs, toolbar Sleep/Wake, physical pointer mapping, and supported rendering modes. Keep audio explicitly limited, and keep the benchmark claims tied to the earlier Studio binaries/workload.

A complete backing store now has a demonstrated path on Tiger. The remaining issue is delivering it quickly with correct window/input/application lifecycle—not guessing which pixels in the finished desktop belong to a window.

### Reconnection follow-up

Tools 2.7 treats repeated Harmony state requests as idempotent: reconnecting no longer restarts Finder just to repeat the same mode. The host reconciles an off state only with 2.7+ agents; older agents retain their previous behavior. Guest preference restoration across a *guest agent process crash* still needs persistent state—its previous in-memory preference snapshot cannot be reconstructed after the process is gone.

### Final bundle check

After the final source/packaging changes, both saved Leopard test copies were reopened using the **exact final integration executable**. One and two CPUs each restored their original unique in-memory marker, used `-loadvm PowerEmuSleep`, and passed another offline QCOW2 check after saving/stopping. See `final-bundle-wake.json`, whose executable hash matches `final-bundle-hashes.json`. Both test VMs are stopped; their snapshots remain available. Both final app bundles pass deep/strict signature verification. The normal release frontend was restored to the original running Tiger VM; no SMP backend was substituted underneath it.
