# Harmony: architectural route to responsive per-window rendering

October 14, 2026. Research and source inspection only; no VM launches, code changes, or new performance claims.

## Recommendation

Keep the working native host windows, masks, input, Dock and display geometry. Replace repeated complete-window screenshot requests with **versioned per-window content publication at the guest's drawing/compositor boundary**, if a bounded feasibility test establishes a correct Tiger/Leopard export path. Scheduling alone cannot turn a roughly 100 ms serial capture into 30 changing frames/sec.

Do not promise this is a small change or that Parallels' proprietary implementation is known. First separate actual copying from guest scheduling/WindowServer waits. Then prove the proposed transport on a cooperative window before touching Finder, other applications, WindowServer, or the Radeon path.

## What is documented about Coherence

Parallels documents native-looking Windows applications, hidden guest desktop/Start elements, and Dock integration; its KB also requires Parallels Tools. An official repair article ties Coherence/dynamic-resolution failures to the Parallels display driver. This establishes coordinated guest software and graphics integration, not its exact pixel acquisition algorithm. [Coherence KB](https://kb.parallels.com/en/4670), [driver repair KB](https://kb.parallels.com/en/118218).

A Parallels-assigned patent describes collecting guest window information, masking a desktop image available to the hypervisor, proxy windows, and alternative remoting arrangements. It supports the architectural idea of separating content transport from window integration. It does **not** prove that current Coherence uses a particular driver hook, per-window shared texture, or screenshot API. [US9588657B1](https://patents.google.com/patent/US9588657B1/en).

SPICE documents separate display, input and cursor channels and rendering/damage messages. QEMU's vhost-user-gpu protocol illustrates shared rendered resources with update notifications rather than a fresh image payload for every update. These are useful design patterns; neither supplies a ready Tiger per-window exporter. [SPICE protocol](https://www.spice-space.org/spice-protocol.html), [QEMU vhost-user-gpu](https://www.qemu.org/docs/master/interop/vhost-user-gpu.html).

## Current PowerEmu bottleneck and an important measurement gap

`guest/src/PEAgent.m` uses `CGContextCopyWindowCaptureContentsToRect` to populate a complete bitmap, compares all pixels, packs changes, and sends a response. That preserves covered pixels, unlike a desktop crop. `captureWorker:` already sends frames over a separate frame socket, but requests pass through the guest command handler. Host decode is not the established bottleneck.

The retained live profile measured median worker dispatch 2.86 ms, capture/packing 130.58 ms, delivery 1.55 ms, and reporting 81.72 ms. These are diagnostic measurements, not a controlled latency improvement. See [local capture profile](HARMONY-CAPTURE-PROFILE-2026-10-14.md).

Crucially, the current capture timing encloses **the private capture call, `CGContextFlush`, and graphics-state restoration**. It does not isolate each operation. Request receipt is timestamped only after the guest main-thread handler runs. Therefore neither an expensive pixel copy nor a WindowServer IPC wait has yet been proved as the sole cause. Emulated scheduling and concurrent WindowServer/reporting work can contribute.

### First bounded experiment: identify the expensive boundary

1. Add opt-in bounded timing records around transport receipt, main-thread dispatch, worker start, private capture return, context flush return, packing and send completion. Carry a request sequence throughout; do not subtract unsynchronized guest/host clocks.
2. Record wall and capture-thread CPU time separately, using APIs verified on the installed Tiger SDK/runtime. Wall time much larger than CPU suggests waiting or descheduling; it does not by itself identify which process caused it.
3. Compare one fixed-size animated test window and one Finder window, visible and fully covered. Run report-scanning on/off/on in the isolated clone, with identical binaries and no host build/profiling during measured windows. A report-off control is diagnostic, not a shipping policy.
4. Split capture and flush before trying more bitmap formats, thread pools or priority values. If request main-thread delay dominates, a capture-only receiver with immutable session state may be the smallest improvement. If WindowServer work dominates, bypassing that screenshot boundary is the architectural target.

## Prototype 1: prove push publication without private hooks

Build a test-owned guest window that draws from an application-owned canonical 32-bit bitmap. On each committed pattern change, publish the **same immutable pixels** and a monotonically increasing generation to the existing frame transport, without calling the private screenshot routine. Continue drawing that bitmap into the normal guest window. This is a controlled cooperative exporter, not a claim to have captured arbitrary application backings.

Use sequence numbers visibly encoded into the image, nonuniform row patterns, alpha corners, moving rectangles and resizing. Cover it completely with another guest window while updates continue. Compare exported pixels with the canonical source and separately with complete-window captures at stable generations. Timing comparisons run separately from expensive full-image validation.

Reuse the current host proxy renderer and accepted-base/frame validation. Add a capability-negotiated push mode for this test window only. Retain request-based full capture for every ordinary application. Bound pending frames to the newest complete generation; never let old frames form a queue behind input.

**Pass gate:** zero pixel/stride/generation errors across at least 1,000 committed frames, including covered changes and resize; at least 30 distinct source generations presented/sec for a 615×407 test window on the same clone; p95 commit-to-host receipt below 33 ms and p95 host input-to-visible update below 100 ms in a deterministic interaction fixture. These are proposed targets, not achieved results. Measure source render time and host presentation separately.

Failure means do not embark on a general backing-store hook yet. Localize transport, copying or guest production first.

## Prototype 2: establish a real third-party window export boundary

No verified public Tiger API or currently verified private ABI in this repository maps arbitrary Finder/Word complete backing pixels with damage notifications. `CGSGetWindowFlushSeed` worked for an owned fixture but Finder access failed; passing its owner's connection did not confer ownership. `CGSGetSurfaceCount` detects a complication, not access to its image. Do not invent `CGSGetWindowBackingStore`-style APIs or infer a pointer from a guessed structure.

A feasibility spike must inspect the **actual installed build's** CoreGraphics/WindowServer interfaces and identify:

- Window identity plus lifetime/generation and owning connection.
- The allocation, row stride, format, and bounds of the 2D backing storage.
- A completed flush/damage boundary and a way to acquire stable bytes while writers continue.
- Resize/destruction invalidation, accelerated-surface attachment, and required ownership/access checks.

Prefer a supported or verifiable user-space mapping if one exists. Otherwise distinguish two much larger approaches:

| Approach | What it can prove | Limitation |
|---|---|---|
| Cooperative owner-side drawing/flush export | Cheap, correct publication from a known application-owned bitmap | Does not solve unmodified Finder/Word; Carbon, Cocoa, QuickDraw, GL and QuickTime differ |
| Opt-in owner-process helper at a verified flush boundary | Potential access to that application's true backing updates | Injection and ABI/lifecycle compatibility risks; no universal hook has been verified |
| WindowServer compositor-side exporter | Central window identity, backing and attached-surface composition | Highest crash/compatibility risk; closed-source internals differ across Tiger/Leopard |
| Graphics-driver/QEMU resource bridge | Efficient transfer when resource identity and completion are known | Display damage or a raw Radeon surface alone does not identify a complete window |

Start with a read-only, bounded exporter for one 2D Finder window in the independent clone. Verify covered, moving and resized pixels against stable-generation reference captures. Require explicit pointer/format/lifetime provenance; no speculative memory scanning in production. Do not modify WindowServer or system frameworks as the first experiment. Stop a failed ABI experiment and retain the working capture fallback.

## Transport and graphics design after export is proved

Use per-window content generation, dimensions, stride/format, source generation, immutable completed buffer, and damage rectangles. Keep geometry/focus/menu/cursor independent from pixel availability. Publish into a bounded double/triple-buffer arena with explicit ready/ack ownership; resize creates a new generation and old mappings remain valid until released. Deltas require the exact host-acknowledged base; otherwise send a full frame. Coalesce older complete updates rather than queueing them.

A custom guest-visible shared-memory transport could reduce socket copies/compression later, but requires a Tiger/Leopard guest driver or validated device mapping and QEMU support. Guest addresses are not host pointers. Account for PPC byte order, cache/coherency and release/acquire semantics. A host IOSurface/Metal texture can consume the safely published copy; it cannot directly import a guest WindowServer pointer.

Apple dates IOSurface's public framework to **10.6**, beyond both supported guest systems. Modern ScreenCaptureKit and Linux virtio-gpu examples are not drop-in guest solutions. [Apple framework availability](https://developer.apple.com/library/archive/documentation/MacOSX/Conceptual/OSX_Technology_Overview/SystemFrameworks/SystemFrameworks.html), [QEMU virtio-gpu requirements](https://www.qemu.org/docs/master/system/devices/virtio/virtio-gpu.html).

Accelerated child surfaces need separate ownership, completion/fence, placement and composition handling. A primary 2D backing can omit OpenGL content. WebKit's own historical capture investigation explicitly documented this distinction and the newer Leopard capture API's composited behavior. Keep complete capture for uncertain/accelerated windows until equivalent composed export is demonstrated; fullscreen fallback remains appropriate. [WebKit capture investigation](https://bugs.webkit.org/show_bug.cgi?id=21495).

## Regression and promotion gates

- Same binary/configuration, matched baseline/candidate/return controls; report distinct changing frames and input latency, never unchanged replies as FPS.
- Covered-window content remains complete after arbitrary host/guest interleaving; no desktop pixels, stale exposure, tearing, or row/alpha corruption.
- Cross-display movement, scale/coordinate translation, attached sheets, minimize/restore and guest/host focus remain correct.
- Rapid source resize/close/reopen cannot publish into a replacement window; injected delay/drop/reconnect forces independent recovery.
- Cursor ownership is separately balanced at focus changes, Harmony enter/exit and display disconnect; cursor hide/show must not depend on frame callbacks.
- Bound CPU/memory and compare audio alongside visual load. Raising every emulation/capture thread's priority can hurt audio and input.
- Default-off prototypes, isolated cloned disk, unchanged working capture fallback. Promote only after deterministic correctness and measurable latency improvement; a successful cooperative prototype is not proof that ordinary guest applications are fixed.
