# Guest capture profiling — October 14, 2026

Measurements use the independent cloned Tiger base/private overlay and a freshly compiled PowerPC probe that includes the production `captureWindow` implementation. They do not modify the user's original VM or installed tools.

## What the measurements establish

For a stationary 615×407 Finder window, the private complete-window capture call commonly costs about50–75ms. Independent zlib full-frame compression costs another roughly40–60ms. The live host requests the existing pixel-run/tile codecs; the probe with those same flags returned encoding3 and90023-byte independent frames. Earlier zlib-only probe totals must not be mistaken for live-codec totals.

Fresh bitmap allocation versus the existing safe scratch reuse was inconsistent across return controls. Native ARGB capture converted back to RGBA matched all1001220 bytes, including alpha, but did not consistently speed the capture call. Neither change was promoted.

Thread-per-frame versus persistent-worker dispatch,28 warmed observations per condition:

| Condition | Median dispatch overhead | p95 | Unchanged-frame total median |
|---|---:|---:|---:|
| Thread |6.319ms|11.273ms|82.350ms|
| Persistent |5.465ms|11.252ms|81.047ms|
| Thread return |5.618ms|10.858ms|89.620ms|

These controls do not establish a worthwhile latency improvement. The persistent-worker candidate therefore remains **default off**, enabled only with `PE_CAPTURE_PERSISTENT_WORKER`. Its one-pending-job queue replaces superseded requests, retains the executing job, uses per-request autorelease pools and preserves the original capture/session/reset code. A physical PPC bounded-queue fixture passed; frame sequence/unchanged-response checks passed in both dispatch modes on Tiger. It is not an updated installed tools release.

## Next discriminator

A standalone owned-window fixture compares actual captured pixels against `CGSGetWindowFlushSeed` across visible changes, covered changes and visible idle. Screen-refresh hints alone are insufficient for covered windows. Do not ship a seed-only cache shortcut without complete-window/GL/resize/session validation and an appropriate fallback: stale backing images are unacceptable.

Raw logs are retained in docs/evidence/harmony-capture-2026-10-14. Production host input-priority and duplicate-pointer fixes remain in the signed Harmony test build. No major guest capture speedup is claimed from the experiments above.

## Cross-process result and viable visible-window fast path

Tiger rejects CGSGetWindowFlushSeed reads on Finder-owned windows (including when using the owning connection). The seed shortcut only worked for the probe's own windows, and is not the normal Harmony optimization. It remains diagnostic-only/default off.

A second opt-in path uses screen-refresh epochs **only while the entire window is inside a guest screen, uncovered by every window above it, and has zero accelerated surfaces**. Covered/uncertain/accelerated windows retain full capture. The prior full image must also have been observable; a window coming forward from coverage first gets an independent full check. Source epochs must match before and after the visibility checks. The shortcut expires100ms after the last full capture; the next request then requires full verification. If observable pixels change without an epoch change, disable shortcuts for that window. Dimensions, accepted sequence, immutable cache and session-reset checks remain intact.

The fixture passed180 complete pixel comparisons, visible-changing/covered-changing/idle phases, with60 cache hits and zero pixel failures. Covered changes still took full captures. Finder20-request off/on/off/on controls (first2 excluded,9 unchanged samples per condition): unchanged medians62.10/8.75/60.08/17.27ms. Independent changed/full frames still cost roughly64–119ms across these runs; the last repeat had general timing variability. This measures unchanged response savings, not a claimed click-latency percentage.

Host integration sends separate CAPTUREHINTS visible32 only in the opt-in test build; old tools ignore the new verb without changing their CAPTUREMODE. Pointer/button/key/scroll interactions mark the next selected capture fresh, bypassing shortcuts. Fast unchanged responses are paced at30Hz maximum instead of forming a busy completion loop; input bypasses that idle pacing and changing images remain completion-driven. Updated scheduling fixtures pass.

The first deployment attempt did not install the agent because Tiger process-list headers invalidated the PID check. The corrected bounded install script subsequently verified exact binary hashes in the isolated overlay; original backup is ~/Library/PowerEmu/oct14-agent.before-cache inside that clone. No tools disc, original-VM modification, commit or release has occurred.

## Final promotion decision

Live integrated cache activation was confirmed (`CAPTUREHINTS visible=1`) and clicks/navigation/cross-screen movement rendered correctly, but round trips remained roughly150ms or higher in unmatched interactive logs. Tiger's list is grouped by connection, so the original prefix-based visibility test was replaced with conservative rejection of every intersecting same/higher-level window. The stricter candidate passed complete pixels and fresh-input validation, but Finder no longer qualified for shortcuts in the observed overlapping layout. Its timing run also overlapped a host build and is unscored for comparative performance. **Visible caching remains disabled in the user-facing test app.** Do not describe the prototype9–17ms as its shipped end-to-end speed.

The test build instead enables an opt-in native-complete-window reporting policy:12 geometry scans/sec rather than24; masked-desktop behavior stays24. Sheet checks use3 rather than6 ticks and app/Dock scans15 rather than30, preserving nominal250ms/1.25sec cadence. Window moves ask for a geometry report after10ms rather than waiting solely for the periodic timer. Guest actual timer logs WINDOWREPORT hz=12. This reduces recurring scan work by half; it is not a measured50% click-latency claim. Complete bitmap capture, focus checks, menu/report handling and GPU/SMP paths remain unchanged.

Final signed test app enables native polling12, visible cache0, persistent worker defaultOFF. Guest installation hash verified; WINDOWREPORT hz=12 and CAPTUREHINTS visible=0 confirmed in the live log. CUA clicked a disk, observed selection and keyboard navigation to the disk window, and exited Harmony cleanly. Sidecar disconnected during the drag, so that cross-screen attempt is unscored; earlier dual-screen entry/drag fixes remain intact. Live capture response means were still around100–130ms in this unmatched run. Do not claim a measured click-speedup or that the private50–75ms capture call has been accelerated. User-facing build uses the isolated Tiger overlay with its updated agent; original VM/tools untouched.

Final guest binary SHA256: 92ded69163a82b29bbb7603c3448a756cde6af654c8217c2949ffee642aaf519

## Follow-up: live pipeline and unused native occluder queries

Added opt-in `POWEREMU_CAPTURE_PROFILE` pipeline timings. Request timestamp is taken when the main-thread command handler creates its job, so `queueMS` measures worker dispatch **after command handling**, not time waiting for that handler. Local elapsed measurements require no guest/host clock agreement. Existing two-field test jobs remain supported. Production profiling stays off.

The retained live dual-display run (`pipeline-profile.log`, 248 captures) measured median dispatch 2.86 ms, capture/packing 130.58 ms, and delivery 1.55 ms. Window reporting median was 81.72 ms; geometry/focus alone was 76.84 ms. Full capture-call median was 99.36 ms in this concurrent workload, higher than the earlier standalone tests. These measurements include diagnostic logging and do not establish a new end-to-end speedup. The initial agent restart/entry attempt failed; a clean boot supplied the actual scored diagnostic run.

Native complete-window mode now skips Dock/menu-family occluder rectangle queries. Those rectangles are only consumed by masked-desktop `reportOcclusion`; masked mode retains every query. Reported window rectangles, visibility fields, dragging classification, focus, menu and modal paths are unchanged. Diagnostic opt-out `PE_CAPTURE_REPORT_OCCLUDERS=1` reinstates the old work for matched controls.

Read-only PPC fixture `guest/tools/pereportcheck.m` executes old/new/old controls and compares actual serialized WINDOWS and FOCUSED outputs. Both active-capture and idle controls passed with zero metadata mismatches. After discarding the first two of each 24 samples:

| Workload | Old median | New median | Old return median |
|---|---:|---:|---:|
| Concurrent Harmony capture |64.45 ms|68.00 ms|110.03 ms|
| Capture stopped |50.53 ms|28.37 ms|34.54 ms|

The idle control supports reduced scan work; concurrent variability does **not** support a click-latency percentage. Retain complete backing-store capture and cache-off policy. Do not promote a new request channel or more aggressive idle cache from these results alone. Separate capture-request transport is a possible next experiment because the current receipt timestamp cannot measure time spent waiting on the guest main thread.

The host test app remains signed and strict verification passes. Updated guest candidate (profiling off) MD5 `a48b78f5f35a2a9ff707f7ad6d77a0f4`. It is installed only in the isolated test overlay; no tools-disc release, original VM change, commit or push.

Final nonprofiling agent installation verified MD5 above. Live CUA re-entered Harmony, observed a clean complete Computer window, and verified mouse selection changing to Macintosh HD. Exited Harmony cleanly before owned stop. Keyboard Cmd-Down and double-click attempts did not visibly complete navigation in the observation window; do not label those checks passed. The query removal does not modify input code, but rapid input/navigation deserves a focused follow-up. Scheduler fixture passes; app strict signature remains valid. Owned VM stopped, profiler removed from the installed agent. Active live timing remains variable, so the idle-scan reduction is the only measured performance result of this follow-up.

## Cooperative publication follow-up

See [publication prototype](HARMONY-PUBLICATION-PROTOTYPE-2026-10-14.md). Three complete240-frame known-source runs isolate private capture from context flush: capture tens of milliseconds, flush generally fractions of a millisecond. Cooperative pixels transfer/decode/publish quickly on the host, but guest source generation/drawing and commit→ACK remain slow; performance gate failed. No ordinary-app capture replacement or new user-facing speedup was promoted.
