# Harmony performance: Tools 2.10

September 28, 2026. The user reports clean window surfaces with no desktop leakage in Harmony Test. The latest candidate is `build/Harmony Fast Refresh/PowerEmu.app`, containing Tools 2.10. The previous adaptive-buffer candidate remains at `build/Harmony Refresh/PowerEmu.app`. The running Harmony Test app was not replaced or restarted.

## Constraints

Keep independent native NSWindows and complete, immutable guest window images. Keep one capture in flight, accepted-sequence checks, session identity, and resize validation. Never replace covered pixels with desktop crops. Host title dragging must continue to move the retained image without waiting for guest capture.

## Evidence and priorities

The isolated Tiger capture probe measured 33.8–40.6 ms per 615 × 407 RGBA capture. Live request round trips commonly measured 60–100 ms; changed-frame batches were slower. These are not input-to-display latency or FPS measurements. The current host uses CALayer contents and Core Animation. A Metal presenter alone cannot remove the preceding guest capture cost.

1. **Measure stages independently.** Guest `POWEREMU_CAPTURE_PROFILE=1` now writes setup, capture/flush/validation, exact comparison, cache maintenance, compression, packet assembly, and socket delivery timings to stderr. Delivery includes connection setup when needed and local socket writes; it does not prove the host displayed the image. Collect changed/unchanged samples at small and large window sizes, with one and several windows. Correlate request sequences with host response timings. Add host decode/presentation measurements and Instruments traces before attributing residual time to the GPU.
2. **Reduce guest allocation and capture overhead.** Experiment with bounded reusable bitmap contexts and scratch storage. Clear reused storage before capture until full overwrite behavior is proven; otherwise stale pixels could reappear. Never mutate retained comparison images or published host images. Compare against the existing allocation-per-capture implementation. Explore reliable guest damage notifications, retaining bounded polling as recovery for missed notifications.
3. **Schedule by interaction and visibility.** Give newly exposed windows and recent pointer/key interaction priority. Back off unchanged windows, especially fully covered ones, without starving visible background animation. The current foreground bypasses idle backoff; changing this needs explicit wake-up on input, focus, and exposure. Measure both idle load and first-change latency.
4. **Reduce work after capture.** Compare compression cost against bytes saved. The next guest build sends raw RGBA when zlib is larger than the original image. Consider changed rectangles only with explicit base sequence, dimension checks, and complete-frame recovery after any mismatch. Do not silently apply patches to an obsolete base.
5. **Use Apple GPU APIs where measurements justify them.** Profile the existing Core Animation path with Instruments. If decode/upload or host presentation is significant, evaluate off-main-thread decoding and a bounded IOSurface/Metal texture pool. Published surfaces must remain immutable until the compositor/GPU has finished using them. This is a host optimization; Tiger's capture API remains a separate bottleneck. A direct emulated-GPU surface export is a longer-term experiment requiring proof of complete per-window pixels and lifetime synchronization.

## Acceptance checks

- Compare median and p95 capture and input-to-visible-change latency, not just average throughput.
- Repeat typing, scrolling, resize, title dragging, window exposure, minimize/restore, focus changes, and animated background content.
- Verify no wallpaper, stale edges, wrong-window images, delayed-frame resurrection, or unbounded memory growth.
- Compare idle host/guest CPU and memory against the current candidate.
- Exercise Tiger and Leopard with one and two CPUs before promoting the replacement build.

## This pass

Added opt-in guest stage timings and a raw-frame fallback when compression increases payload size. These changes do not alter capture geometry, image ownership, masks, or native window ordering. They are preparation for measured optimization, not evidence of a frame-rate improvement. The user's running Harmony Test app has not been replaced or restarted.

Apple reference: [Analyzing the performance of your Metal app](https://developer.apple.com/documentation/xcode/analyzing-the-performance-of-your-metal-app/).


## Measured follow-up

The isolated Tiger clone completed 80 requests against a stationary 615 × 407 Finder window. Requests alternated forced complete frames and acknowledged unchanged frames. Excluding the first four requests gives 38 samples of each type:

| Stage | Full-frame median | Unchanged median |
|---|---:|---:|
| Setup | 9.17 ms | 9.40 ms |
| Capture/flush/validation | 30.85 ms | 31.63 ms |
| Exact comparison | 0.13 ms | 1.19 ms |
| Cache maintenance | 3.82 ms | 3.96 ms |
| Compression | 28.84 ms | 0 ms |
| Total guest processing | 73.46 ms | 46.45 ms |

These measurements came from the already compiled diagnostic agent. The host collected frames through an SSH reverse tunnel, not the production guestfwd bridge. The user VM remained running, so host contention is included. Forced complete frames are not a scrolling or animation benchmark. Local socket-write duration was generally under 1 ms; this does not establish total transport or presentation latency. Raw logs, p95 values, and the binary hash are in `evidence/harmony-performance-2026-09-28/`.

## G4 follow-up and selected implementation

The PowerBook returned and compiled the experiments successfully. Direct guest-to-host test traffic now traverses QEMU user networking to 10.0.2.2; it does not use the earlier SSH reverse tunnel. It still omits the production Unix-socket relay, host decode/presentation, and live window-management polling, so request timings are not animation FPS or end-to-end interaction latency.

Experiments rejected as defaults:

- Raw transport reduced compression time but increased total delivery time (about 88 ms median full-frame round trip in the initial mixed test).
- RLE zlib produced a larger payload and did not reduce compression time in this workload.
- Always reusing scratch with a snapshot copy improved idle work but penalized repeated full frames. Explicit byte copies and store-by-store copies were tested; neither justified enabling that design.

Tools 2.9 instead uses **adaptive buffer reuse**. A changed capture becomes the retained cache image, and that storage is never overwritten. The next capture allocates fresh storage. If that next image is unchanged, the cache retains its separate previous image; only then may the scratch context be reused. Reused pixels are cleared before every capture. A size change recreates the context, and an image-session change releases scratch and cached state. This removes repeated allocation/context setup for stable windows without requiring an extra snapshot copy for changed frames. `PE_CAPTURE_REUSE=0` retains the allocation-per-capture comparison path. Raw and RLE remain opt-in diagnostic flags, not shipping defaults.

The guest integration probe passes complete frames, unchanged responses, missing/stale accepted bases, invalid windows, poisoning scratch without changing cached pixels, clearing poisoned scratch, and switching capture dimensions. Host geometry/frame and transport regressions pass. The final app passes deep/strict signature verification; its ISO embeds the exact compiled Tools 2.9 binary. No visual corruption-free claim is made for an exhaustive live interaction matrix on this new candidate.

Final measurements and package hashes are recorded below and in `evidence/harmony-performance-2026-09-28/`. Install Tools 2.9 from the new candidate to use the improvement. Full-frame capture/compression remains the limiting cost for scrolling and animation; this pass does not establish a scrolling FPS gain.

### Final repeated comparison

80 requests per run; first four excluded. Host compilation had finished, but the user VM remained running. The stationary Finder window was 615 × 407.

| Pattern | Reuse disabled median / p95 | Adaptive default median / p95 |
|---|---:|---:|
| Unchanged | 46.34 / 51.20 ms | 34.48 / 35.99 ms |
| Forced full frame | 82.03 / 134.70 ms | 80.52 / 83.08 ms |

All four runs produced the same pixel SHA-256 for every complete frame; unchanged replies retained that exact image. The approximately 26% reduction concerns unchanged request latency in this controlled workload. Full-frame timings remain in the same broad range; this does not demonstrate smoother scrolling. The diagnostic agent was stopped and the isolated backend is paused at `build/harmony-next-test/profile.qmp`; its PID is in `profile.pid`. The user app and original VM remain running unchanged.


## Tools 2.10: faster complete-frame encoding

The guest now offers a lossless pixel-run encoding for simple UI surfaces. Each packet contains a complete independent RGBA image, not a delta or desktop crop. One control byte describes up to 128 repeated or literal four-byte pixels. Alpha and byte order are preserved exactly.

The host requests this format with a fourth `WINDOWFRAME` argument, `rle32`. Older tools ignore the extra argument and continue sending zlib/raw frames. New tools only send encoding 3 when requested; older hosts continue receiving the existing formats. The host decoder checks every run, requires exactly the expected pixel count, and rejects truncated or trailing payload data before publishing an image.

A cheap sample rejects detailed images before attempting the encoder. Even after passing the sample, an attempt must fit within one quarter of the raw byte count; otherwise the guest falls back to zlib. The sample is deliberately conservative. False positives only cost an attempted encoding; false negatives use the existing zlib path. Neither affects image correctness. Memory-level tuning and byte-level zlib RLE were slower in these tests and are not enabled by default.

Validation includes 600 fixtures generated on the PowerBook and decoded by the actual Swift frame decoder; another 600 native fixtures under AddressSanitizer/UndefinedBehaviorSanitizer; bounded output guards; missing/truncated/oversized/trailing packets; full RGBA equality; and existing geometry and transport regressions. Live read-only captures covered three ordinary windows and a 1680 × 1088 detailed surface, exercising both encoding 3 and zlib fallback. This does not constitute a complete interactive scrolling/resize test of the new app.

The first final comparison on a stationary 615 × 407 Finder window measured 81.75 ms median / 83.99 ms p95 with zlib and 54.96 ms / 58.61 ms with pixel packets. Guest packing fell from approximately 30 ms to 4 ms. The encoded payload grew from about 33.5 KB to 67.9 KB, but the CPU savings outweighed the extra transport cost. Actual host decoding measured about 0.16 ms median for the pixel packet versus 0.23 ms for zlib. Larger detailed zlib frames still cost more to decode; no blanket GPU bottleneck claim follows from the small-window measurement.

These are request timings over direct QEMU user networking, with no SSH data tunnel. They exclude the production Unix-socket relay, live window-management polling, and presentation latency. The user VM remained active; host contention is uncontrolled. Forced full captures of static pixels are not scrolling FPS. No lossy rendering, frame interpolation, or Metal presenter was introduced.

The final package and follow-up verification are recorded in `evidence/harmony-pixelpack-2026-09-28/`. Use the app and install its Tools 2.10 together to activate the negotiated encoding. The user's current session was not restarted or upgraded.

### Final packaged-agent verification

With the final conservative preflight, 40 requests per run (first four excluded) measured **175.46 ms median / 225.80 ms p95** using zlib and **87.67 ms / 100.39 ms** using pixel packets: an arithmetic difference of about 50% in that pair of runs. Absolute timings drifted substantially from the earlier 82/55 ms comparison, and host load was uncontrolled; do not treat 50% as an isolated optimization effect or combine these runs into one benchmark. Both runs produced the same full-image SHA-256. The detailed 785 × 443 window still used encoding 1 and matched its zlib-only image exactly.

The final ISO's embedded agent and the deployed diagnostic agent match the compiled binary; deep/strict app signature verification passed. The diagnostic process was stopped and the isolated backend is paused. No installation or restart was performed in the user's current VM.
