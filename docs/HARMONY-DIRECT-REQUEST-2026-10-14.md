# Capture request channel experiment — October 14, 2026

## Result: retain default OFF

Implemented a separate capture-only request socket to avoid waiting for the guest agent's main-run-loop window scans. It retains the existing complete-window capture/codec/response path and does not change backing acquisition, pixels, window ordering, graphics, or audio. The proposed contention was plausible from code inspection, but three live control/return trials did not establish a consistent responsiveness improvement. **Do not enable in the user build.**

All three trials retained60 independently decoded full615×407 Finder frames, byte-identical to their respective first reference across all phases. Accepted base0 forces full captures, not cached/unchanged replies. Two warmup samples per20-frame phase excluded from statistics:

| Trial | Phase1 median / p95 | Phase2 median / p95 | Phase3 median / p95 |
|---|---:|---:|---:|
| Control→Direct→Control |84.90 /170.46ms|81.11 /106.87ms|94.47 /152.05ms|
| Control→Direct→Control repeat |72.29 /101.89ms|82.61 /99.32ms|80.55 /99.57ms|
| Direct→Control→Direct |60.94 /79.69ms|86.29 /137.95ms|84.77 /130.74ms|

These are stationary-window host-local request→frame-handler round trips, not click-to-visible, changing-image FPS, or scanout. Rendering/WindowServer scheduling varies substantially. The return trial's apparent advantage did not reproduce in the repeat. No guest report-rate/priority/cache changes promoted.

## Implementation and checks

- Guest opt-in `PE_CAPTURE_DIRECT_RECEIVER=1` opens one immutable-session `CAPTUREHELLO` request link. Host must also opt in `POWEREMU_DIRECT_CAPTURE=1`; unsupported hosts close it and retain ordinary control requests. Production defaults create no new guest receiver thread or socket.
- Receiver directly executes the existing serialized capture worker on its background thread. No general command dispatch, AppKit/AX handler execution, or mutable session-string access from that thread.
- `guest/src/PECaptureRequest.h` accepts bounded `WINDOWFRAME` only, payload≤256, three valid bounded integers, exact codec/fresh fields; rejects other verbs, NUL, invalid/truncated/overflowing headers and payloads.
- Existing frame response connection authenticates the session separately. Control replacement closes request and response links. Unknown/stale session rejected; closed request link falls back to ordinary control requests.
- `tests/HarmonyDirectCapture/parser.c` passes native ASan/UBSan malformed-input tests. `guest/tools/pecapturedirectcheck.m` executes actual receiver on PowerPC with recording worker: two valid captures, rejects RUN, no main run loop serviced. Test main-thread check uses pthread identity for Tiger compatibility.
- `tests/HarmonyDirectCapture/host.swift` compiles actual GuestAgent and passes valid routing, wrong token rejection, stale-session teardown/rejection and control fallback.
- Backend tools compiled with actual10.4u SDK/gcc4.0. Only existing method-declaration warning in agent; no new production compile error.

## Live run ownership and limitations

Private independent Tiger base/overlay only. Owned PID57044, labeloct14-direct-request,480second guard; stopped after retention. Original installed agent untouched: fixture agent used separate10.0.2.2 TCP→Unix bridge and unique session. Existing normal agent remained constant in all phases. No host compilation/heavy analysis during each scored60-frame interval.

First comparison process ended normally but remained as a disconnected retrying fixture agent. Repeat setup initially reused that path; it was stopped by its exact guest PID219 and relaunched before any repeat requests. The complete retained repeat contains only the subsequent successful fixture. Harness now uses a unique per-label `.app` path and cleans only its exact owned executable. No original agent was killed. Temporary binaries/bundles stay underbuild and guest/tmp.

`tools/harmony-publish/run-direct-compare.py LABEL [direct-first]` validates owned process/guard margin, runs bridge and bounded comparison, retains JSON and kills only its fixture process. Verify inventory first. Host receiver defaults remain OFF; no tools installation/release or production GPU/SMP/audio change.

Remaining gate before any future promotion: actual changing content and input latency; delayed/dropped connection fallback under live load; resize/coverage correctness; different apps and accelerated surfaces; repeatable improvement rather than one favorable median. Current evidence does not justify further channel tuning. Main priority returns to the expensive actual capture/rendering boundary and verified real-app backing ownership.
