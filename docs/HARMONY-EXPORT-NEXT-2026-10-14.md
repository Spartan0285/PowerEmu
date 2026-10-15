# Harmony next capture experiment — October 14, 2026

## Finding

The next safe, actionable experiment is to measure **main-run-loop delay around complete-window requests and report scans**, then test whether reducing that contention improves host-observed request latency. Do not attempt another backing-store API search based on guessed private names.

In `guest/src/PEAgent.m`, the control socket is registered with `NSFileHandle` background notification. `received:`, `processInbox`, and `handle:` parse and dispatch commands on the app's run loop. A `WINDOWFRAME` command only starts a capture worker after that dispatch. Meanwhile the repeating `windowTimer` invokes `reportWindows:` on the same run loop; that method walks windows and makes multiple CGS queries. Thus an 80 ms report scan can delay receipt/dispatch of an incoming capture request even though the pixel capture itself runs on a worker. Existing `queueMS` begins with a timestamp added inside `handle:` and therefore excludes time waiting for the notification callback to run.

There is already evidence this is worth measuring, but not yet evidence it improves clicks: retained report profiling gives geometry/focus median 76.84 ms and total report median 81.72 ms during capture. The idle matched control's report median fell from 50.53 ms to 28.37 ms after skipping unused occluder queries, while the concurrent-capture old/new medians were 64.45/68.00 ms and inconclusive. The policy is already 12 reports/sec in the isolated user-facing test build. Lowering it further without a matched interaction result is not justified.

## Verified Tiger measurement tools

The cooperative publication fixture `guest/tools/pewindowpublish.m` already calls `mach_absolute_time`/`mach_timebase_info` for monotonic elapsed times and obtains current-thread CPU time with `thread_info(..., THREAD_BASIC_INFO, ...)`, deallocating the `mach_thread_self()` port afterward. Its Tiger runs produced the retained 240-frame publication logs. These APIs and this safe current-thread usage are therefore grounded in an actual Tiger PPC fixture, not guessed Tiger compatibility. The publication study found private capture around 56–114 ms while context flush stayed below 0.4 ms, which rules out prioritizing flush tuning.

The available host does not contain the Tiger 10.4u SDK (`guest/Makefile` points to `/Developer/SDKs/MacOSX10.4u.sdk`, which is absent). The installed PPC agent binary is inspectable and links `CGContextFlush`; the window capture entry point is deliberately resolved with `dlsym`. Current host SDK export lists show modern CoreGraphics symbols, but they cannot establish Tiger ABI or ownership. The evidence reviewed here identifies no safe exported Tiger API that returns arbitrary Finder backing bytes, stride, lifetime, and damage. Preserve complete capture for covered, accelerated, or uncertain windows.

## Smallest bounded next experiment

Run only in the disposable Tiger clone, with one fixed-size Finder window and the same signed host/guest binaries across matched baseline and candidate runs. Add default-off diagnostic timing only; do not change capture behavior. Carry the existing request sequence through these boundaries:

1. `received:` callback entry, complete `WINDOWFRAME` parse, and `handle:` entry, using guest monotonic timestamps. Log lengths/sequence, not window titles or pixels.
2. `captureWorker:` start, private capture call return, `CGContextFlush` return, packing completion, and frame-socket write completion. Split the existing combined capture/flush interval.
3. `reportWindows:` total wall time and current-thread CPU time, with window count and capture sequence range overlapping the scan. Use the same Mach clock/CPU approach as the already-run fixture.
4. Host monotonic time immediately before the complete control request write and on frame arrival, with the same request sequence. Report host round-trip separately from guest local durations; do not subtract absolute timestamps from different machines.

Collect 30 requests per condition after warmup, in alternating baseline/candidate/baseline order: current 12 Hz reporting versus a diagnostic report-scan pause while the one Finder window is stationary. Restore the normal report setting immediately after each bounded condition and before moving or interacting with any window. Keep Harmony enabled and capture behavior, image size, codec, VM CPU/RAM, and host load fixed. This pause is a diagnostic control only; it is not a shipping policy because geometry/focus can become stale.

Interpret the result narrowly. If host round-trip falls while capture/flush/pack/write times stay stable and the callback-to-handler interval contracts, report/run-loop contention is implicated. If callback-to-handler stays small and capture wall time remains dominant with low capture-thread CPU, focus the next investigation on the private capture IPC/scheduling boundary. If wall and CPU capture times rise together, guest CPU contention is more likely. These outcomes select the next experiment; none alone proves a general click-latency gain.

## Promotion gate

Only consider a scheduling change after matched return controls show a repeatable improvement in input-to-visible response, with no stale focus/geometry, covered-pixel, cursor, or audio regression under real interaction. Require unchanged and changing frame cases, then repeat while moving a window to test restoration of timely reports. Otherwise retain the established 12 Hz policy and complete-window capture path.

No source changes, VM launch, speculative memory inspection, injection, or API claim were made for this research note.
