# Harmony hot-path review — October 15, 2026

Read-only audit of the live host and guest paths, following the October 14 capture, direct-request, and publication results. No source, build, or VM was changed.

## Actionable finding: focus confirmation performs blocking Accessibility queries on the guest's UI thread

`FOCUSWINDOW` is handled by the guest control loop at `guest/src/PEAgent.m:1202-1208`; it raises the target and schedules `confirmFocus:`. The implementation at `:2562-2595` runs on the agent's main run loop. Each attempt synchronously calls `PEFindAXWindow`, `AXUIElementCopyAttributeValue`, and `PECopySheets` (`:2572-2585`). On failure it schedules another attempt after 20 ms, for up to 30 retries (`:2588-2592`). Accessibility may wait on another application, so this can occupy the same main thread that services Harmony commands and the 12 Hz window report timer.

This is a direct path from a host click to visible input delay: the host queues input while `pendingFocus` is set (`app/Sources/PowerEmu/HarmonyWindows.swift:260-275`), and starts a two-second timeout (`:2378-2389`). The guest sends `FOCUSREADY` only after the synchronous AX checks finish or all retries fail. Thus a slow AX call delays both guest command processing and release of the user's queued gesture. The 20 ms retry cadence does not bound the time spent inside an individual AX call.

### Smallest testable fix

Move only the AX confirmation work (`PEFindAXWindow`, focused-window lookup, and sheet check) onto a serialized background worker. Return `{window id, sequence, attempt, result}` to the main thread, where the existing sequence check and retry/result logic can remain. Keep raise and CGS operations that require the main thread there. First instrument per-call duration and main-loop delay around this path, then compare matched focus-click latency and command/report responsiveness with one slow or unresponsive AX target. Preserve the existing host sequence checks and failure timeout.

This is a code-path finding, not a measured speedup claim. The guest's actual complete-window capture and image packing still account for much of a frame's latency (capture profile: roughly 100 ms median in the concurrent retained run), so this fix targets focus/input stalls and does not promise to accelerate ordinary frame capture.

## Secondary observation: focus reporting repeats window metadata queries

Every `reportWindows:` pass walks the on-screen list and requests each window's level and geometry (`guest/src/PEAgent.m:2052-2119`), then `reportFocused` performs another front-process list, level, and geometry scan (`:1982-2020`). At 12 reports/sec these queries repeat even when the focused window is unchanged. The recent removal of Dock/menu occluder geometry queries only removes that work in complete-capture mode; it does not remove the second focus scan. This is a plausible small recurring cost, but the AX-on-main-thread path above is the more direct input-latency defect. Any deduplication should preserve immediate focus updates after raise (`:2536-2539`) and focus acknowledgment behavior.

## Constraints from the retained evidence

The direct-request channel, persistent worker, scratch reuse, and visible cache experiments did not establish a reliable end-to-end improvement; this review proposes no promotion or retuning of those paths. Existing complete captures, session validation, and full-frame correctness remain intact. No unverified capture API or backing-store ownership assumption is needed for the finding above.
