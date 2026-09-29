# Harmony 2.8 implementation checkpoint

For the newer Tools 2.10 performance candidate, see [Harmony Performance](HARMONY-PERFORMANCE.md). This checkpoint retains the earlier interaction and SMP evidence.

September 28, 2026. Supersedes the rendering defaults and pending implementation list in HARMONY-SMP-INTEGRATION.md. This is a development candidate, not a claim of finished Coherence or zero-lag rendering.

## Candidate and exact limits

Build: `build/Harmony Test/PowerEmu.app`. It includes the integrated experimental SMP backend. Fully shut down a guest before moving from the legacy PPC32 backend to this PPC64 backend; do not transfer a sleep snapshot between them. Two CPUs remain experimental.

The G4 is available again. The candidate now includes freshly compiled Tools 2.8 with unchanged-frame suppression, bounded image caching, control-write timeouts, stale read-notification rejection, and periodic menu-title refresh. These are no longer source-only changes.

Testing uses the isolated Tiger clone under `build/harmony-next-test/Support`; the original source disk remains untouched. See the G4 follow-up below for the latest runtime results and performance limits.

## Implemented

- Independent native host windows now display complete guest backing-store images by default. Desktop crops and wallpaper are not their image source. `POWEREMU_HARMONY_MASKED=1` selects the legacy masked fallback for comparison.
- Moving a host proxy retains its complete image and commits the absolute guest position on release. It no longer depends on a moving crop matching an asynchronously updated desktop frame.
- The guest exposes an additional display mode through a private patched copy of the bundled NDRV. The signed original is untouched. QEMU advertises that mode; it is not made the normal boot preference.
- Entering Harmony saves the current guest resolution, requests the matching mode, and waits for both the guest acknowledgment and the matching framebuffer. Unsupported or unavailable modes fail visibly instead of silently stretching. Exit restores the saved resolution. Temporary Harmony dimensions are not persisted as normal boot dimensions.
- One guest pixel maps to one logical host point. Width is rounded up to a 64-pixel boundary required by the current driver/framebuffer contract. Extra columns lie beyond the host screen. Guest height is reduced by the difference between the host menu bar and the assumed 22-pixel guest menu bar; the origin is shifted down by that difference. The host resolution is unchanged.
- On this Mac: host 1710 × 1107 logical points, host menu bar 34 points, guest 1728 × 1095, top offset 12 points, scale 1.0. This is logical-point alignment, not Retina physical-pixel equivalence.
- Input uses the actual event and proxy content coordinates. Direct guest pointer injection avoids a second USB-tablet scaling transform. The host displays the guest cursor; the extra guest cursor layer is hidden in this path.
- Guest focus must be acknowledged before queued content clicks/keys are delivered. Losing a proxy's key status releases held input. Empty menu reports no longer erase a valid menu. New host code restores PowerEmu menus when a PowerEmu library window is key and reinstalls guest menus for a guest proxy.
- Dock representatives are enabled independently of rendering mode and include Finder. Window-to-application mappings route activation to a native proxy. Quit requests leave a representative alive until the guest application actually exits. System Force Quit of a representative is still incomplete.
- Capture/compression runs off the guest control loop. Images use a separate persistent connection authenticated to the current control session. Only one capture is outstanding; request sequences and proxy identity reject late responses. Received images own immutable bytes.
- New source adds exact pixel comparison for unchanged windows, sequence acknowledgment, and slower refresh of unchanged covered windows. Resized windows cannot accept unchanged-image acknowledgments for their old dimensions. The guest-side optimization is compiled and its cache behavior has passed the read-only integration check described below.

## Verified versus pending

Automated checks passed for display calculations, coordinate round trips, private NDRV patch validation, rounded masks, empty geometry, immutable surface ownership/stride, complete-frame decoding, persistent image transport, simultaneous control traffic, and rejection of a foreign image session.

Live Tiger checks on the isolated clone established the custom 1728 × 1095 mode and 1.0 scale; complete images of covered guest windows; a correctly selected Finder disk icon; opening a second Finder window; and a native title drag whose 100 × 50 logical-point move was acknowledged at the same guest destination with an intact image. Exiting Harmony restored the normal guest display during earlier checks. These are specific observed cases, not an exhaustive interaction matrix.

Reusing the image connection reduced the observed capture round-trip average from roughly 300 ms in the connection-per-frame experiment to approximately 73 ms during interactive checks. The later cumulative average reached about 63 ms, including idle/locked time. Neither figure is an animation frame-rate measurement or meets a 16/33 ms budget. A smooth native title drag does not prove smooth animated guest content.

Follow-up live checks and fixes:

- Explicit activation was added to left/right guest-window clicks. Native WindowServer ordering recorded `guest:66 > guest:221 > host:Finder > host:Finder > guest:220 > guest:214`, proving that guest and host windows can interleave. See `activation-stacking-and-minimize.txt`.
- A title drag preserved the complete image. The guest's absolute move was acknowledged. No wallpaper remnants were observed in this test.
- Show Window routed to a guest proxy. Guest Finder and The Garden menus appeared for their selected windows. Choosing File → New Finder Window opened a new guest proxy and it gained focus.
- Exiting Harmony restored 1680 × 1088, verified from the guest display report.
- A minimize race discarded a proxy before the AX minimized report arrived. The host now initiates yellow-button minimization, keeps the image/identity while waiting for the report, binds a unique newly minimized entry only from the owning guest application, and supports a restore request that arrives before binding. A Finder minimize was acknowledged with AX success; its proxy remained retained. Restoring through the guest Window menu returned the same intact window. A physical click on its host Dock thumbnail remains untested.
- One earlier rapid frontend replacement left the guest tools disconnected. Restarting only the tools service restored the connection. The extended host transport test passes control replacement and stale close-callback checks. The two-second guest write timeout and rejection of read completions from retired connections are now compiled; the G4 follow-up below records successful reconnection, but does not establish a definitive diagnosis of the earlier failure.
- Normal test-clone shutdown completed; the frontend shows Start and editable settings.

Still pending: physical click-through at gaps/corners, held-input release across apps, physical host Dock thumbnail activation, representative Quit/Force Quit, and the broader guest/version/CPU matrix. Live checks were performed across two successive host candidates; do not treat this as an exhaustive final-package qualification.

Additional limitations: the custom mode is generated for the main display at cold boot; secondary-display selection and display changes need explicit support. Guest menu height is currently assumed to be 22 pixels. Transient popup ownership, bidirectional drag-and-drop with target destinations, full Dock Force Quit, guest-agent crash preference recovery, and the Tiger/Leopard one/two-CPU interaction matrix remain unfinished. Earlier SMP saved-state results are documented separately and do not substitute for re-testing this graphics revision.

## G4 follow-up: compiled and measured

- Fresh guest builds passed on the G4. The deployed agent hash matched the compiled binary. Host transport regressions, including replacement control connections, passed again.
- `guest/tools/pecapturecheck.m` exercises the actual capture implementation against a stationary guest window without sending input or changing focus. A 615 × 407 window produced a 41,731-byte compressed full response, then a 15-byte unchanged acknowledgment. Missing and stale accepted-frame sequences both forced full images; an invalid window returned a sequenced failure. All assertions passed. See `capture-cache-check.txt`.
- Cache eviction now removes the least recently used entry instead of clearing every window. It retains at most eight entries of at most 8 MB each and resets when the image-session identity changes.
- Live idle batches sent only 480–570 bytes for 30 responses. A content selection produced fresh full frames and visibly updated correctly. Separate full/unchanged timing logs are in `cache-runtime.txt`.
- **Latency remains unresolved:** live unchanged round trips commonly measured roughly 60–100 ms; a content-change batch averaged about 140 ms for full responses. These are capture request timings, not end-to-end input latency or animation FPS. The concurrent capture checker was slower still because it competed with the live renderer.
- To isolate the capture API, Harmony was exited and `pewindowcapture` ran 20 consecutive captures per sample. RGBA averaged 33.8 and 40.6 ms per capture; ARGB averaged 37.0 and 45.7 ms. ARGB was not adopted. See `capture-pixel-layout-isolated.txt`; the earlier competing-workload comparison is retained separately. This demonstrates that transport savings alone cannot produce 60 FPS with the current capture API.
- With the new guest binary, replacing the frontend reconnected automatically and re-entered Harmony without restarting the tools. This is a successful live case, not exhaustive disconnect testing.
- A minimized sole Finder window was restored through its host application representative. `PEUNMIN` recorded the bound guest PID/index and the same complete window returned. The computer-use adapter timed out reading the windowless representative, but the activation callback and visible restoration succeeded. A direct physical click on the Dock thumbnail remains a separate manual check.
- The yellow minimize button then minimized that restored window correctly. Show Window was also updated to find retained minimized proxies when the on-screen guest order is empty.
- Finder briefly exposed an incomplete menu bar during relaunch. The guest now refreshes menu titles every two seconds even if the front PID is unchanged; the host compares both titles and their action indices. This prevents a transient menu snapshot from remaining indefinitely cached. Focus changes still request menus immediately.

The final Tools ISO was mounted read-only and its embedded agent SHA-256 matched the compiled agent exactly; the deployed guest agent matched too. Deep/strict bundle signature verification passed. The final build displayed the complete Finder menu bar and passed sole-window yellow-button minimization followed by Show Window restoration. Evidence: `packaged-tools.json`, `final-g4-runtime.txt`, and `final-guest-display-and-binary.txt`.

The final test session exited Harmony, restored 1680 × 1088, and shut down the clone normally. The library showed Start and the backend exited. The isolated test frontend was then quit.

## Remaining work

1. Reduce the cost/frequency of WindowServer image capture. Profile allocation, capture, comparison, compression, and main-thread AX polling separately. Investigate guest damage notifications and buffer reuse before making another FPS claim. Preserve complete-window images and exact frame identity; do not reintroduce desktop crops as an unproven shortcut.
2. Finish physical Dock-thumbnail, Quit/Force Quit, click-through corner/gap, and held-input tests. Minimized-window identity still uses guest PID plus AX window index; multiple simultaneous minimizes need stronger guest window identity.
3. Implement transient-window ownership, target-aware bidirectional drag-and-drop, multi-display mode negotiation, and persistent guest-preference recovery after a tools crash.
4. Repeat Tiger/Leopard, one/two-CPU, and toolbar Sleep/Wake checks on the final combined package. Existing SMP evidence is not a substitute for this matrix.
5. Install the Tools disc from this exact build before user testing, even if an earlier development agent also identifies itself as 2.8. Fully shut down before switching backend families or loading the new display driver.

Build command:

```sh
POWEREMU_APP_OUT="$PWD/build/Harmony Test/PowerEmu.app" bash scripts/build-smp-app.sh
```

Regression commands:

```sh
xcrun swiftc app/Sources/PowerEmu/HarmonyDisplayMode.swift app/Sources/PowerEmu/HarmonyCoordinates.swift app/Sources/PowerEmu/HarmonyDesktopGeometry.swift app/Sources/PowerEmu/HarmonySurfaceSnapshot.swift app/Sources/PowerEmu/HarmonyWindowFrame.swift app/Tests/Harmony/Regression.swift -o /tmp/pe-harmony-next-regression
/tmp/pe-harmony-next-regression ndrv/qemu_vga_hwc.ndrv
xcrun swiftc app/Sources/PowerEmu/GuestAgent.swift app/Sources/PowerEmu/HarmonyMenus.swift app/Tests/Harmony/Transport.swift -o /tmp/pe-harmony-transport-test
/tmp/pe-harmony-transport-test
```
