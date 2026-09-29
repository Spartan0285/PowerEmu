# Tiger refresh-notification experiment

September 28, 2026. **Result: screen refresh notifications are useful positive hints, but their absence cannot safely replace complete-window capture.** No production capture or scheduling changes were made for this experiment. Harmony Adaptive Refresh remains the latest candidate.

## What was tested

`guest/tools/perefreshcheck.m` is a standalone Cocoa test compiled on the PowerBook using gcc-4.0 and the 10.4u SDK, then run inside the isolated Tiger 10.4.11 clone. It creates and cleans up its own two test windows. It does not control the user's applications or modify the installed guest agent.

A 256 × 160 test view alternates between two solid colors. Each sample pumps the application event loop, captures the window's complete backing-store pixels using the same private capture API as Harmony, and compares those pixels exactly with the previous sample. It counts screen-refresh callbacks whose reported rectangles intersect the test window. A larger opaque window at a higher level provides the covered case. A stationary visible phase checks for idle noise.

| Workload | Actual pixel changes | Changes without a matching notification | Samples with a matching notification |
| --- | ---: | ---: | ---: |
| Visible, changing | 29 | 0 | 30 |
| Fully covered, changing | 29 | 29 | 0 |
| Visible, stationary | 0 | 0 | 0 |

Each phase has 30 samples; its first image establishes the comparison baseline, leaving 29 change comparisons. Pixel changes while covered were verified through the complete capture itself, not inferred from drawing requests. Timing is observational; this experiment is not an FPS benchmark or comprehensive notification-reliability test.

Raw results, source/binary hashes and SDK header provenance are in `docs/evidence/harmony-refresh-notifications-2026-09-28/`. The isolated test backend was paused afterward.

## Why this matters for Harmony

A window hidden behind another guest window can still be independently visible on the host. Using screen-refresh silence to declare that window unchanged would miss its updates. Periodic capture would eventually repair the stale image, but introduces deliberate latency and does not make the notification a reliable per-window damage signal.

Apple documents the callback as reporting changes to the display. It also notes that the registration return code is undefined on 10.4 and earlier, so this test validates actual callback delivery rather than treating the return value as success/failure. The local 10.4 header confirms that callbacks require event processing and that screen-move operations are converted into refresh callbacks when no separate move callback is registered.

References: [screen refresh callback](https://developer.apple.com/documentation/coregraphics/cgscreenrefreshcallback), [registration and Tiger return-code caveat](https://developer.apple.com/documentation/coregraphics/cgregisterscreenrefreshcallback(_:_:)).

## Decision and next experiment

Do not ship a blanket “no screen notification means unchanged window” optimization. Do not synthesize accepted unchanged-frame responses from notification silence. Preserve the current complete-image and sequence-validation path.

Positive notifications could wake a backed-off window earlier, while retaining all existing polling. That would help background response latency, but this experiment does not establish an overall capture-cost reduction.

To reduce transfer and host decoding cost without relying on these notifications, investigate changed-tile packets derived from exact comparisons of freshly captured complete images. Require an acknowledged base sequence, exact dimensions, immutable host reconstruction, and a full-frame fallback for missing bases or resizes. Measure comparison overhead before enabling it. This would still pay the guest capture cost; it must not be described as eliminating that bottleneck.

## Reproduce

Compile the probe on the PowerBook with the same SDK/framework flags used by the guest tools:

```sh
gcc-4.0 -arch ppc -isysroot /Developer/SDKs/MacOSX10.4u.sdk \
  -mmacosx-version-min=10.4 -Os -Wall perefreshcheck.m \
  -framework Cocoa -framework ApplicationServices -o perefreshcheck
```

Run it in a logged-in, isolated Tiger graphical session. It requires the active Cocoa event loop and the complete-window private capture function. Do not run against a user's working desktop when an isolated guest is available.
