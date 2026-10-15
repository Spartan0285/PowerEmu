# Harmony cursor disappearance investigation

User reports cursor disappears while PowerEmu is focused in native Harmony. Exact gesture/reproduction has not been established; these are fixes for concrete unsafe paths found in source, not proof that the intermittent report is reproduced.

## Changes

- Native Harmony explicitly cannot use the normal VM view's blank cursor policy or capture/grab the host pointer.
- Harmony entry invalidates the old VM cursor rectangles and selects a visible arrow; leaving an ungrabbed VM view also restores the arrow.
- Native proxy views install active-app tracking areas and reassert their cursor on entry, movement and cursor updates. Exit restores the arrow so a guest shape is not left selected over the host.
- Fully transparent, missing or oversized guest cursor images fall back to an arrow. Valid cursor hotspots are bounded to their image. Guest desktop hardware cursor visibility is unchanged; native Harmony uses a host cursor.
- No unconditional NSCursor.unhide calls: the existing grab/ungrab hide-count pairing stays intact.

## Validation/status

CoreGraphics fixture passes transparent, opaque, translucent and no-alpha shapes. Scheduler regressions pass. No VM or guest tools changes are needed. Release/signed build status is recorded when staging finishes. The user's running VM is not terminated or replaced while testing.

The separate Coherence research document is docs/COHERENCE-ARCHITECTURE-RESEARCH-2026-10-14.md. Scheduling did not resolve the reported slow content refresh; no new FPS claim accompanies this cursor change.

## Follow-up from user clarification

The cursor disappeared everywhere while PowerEmu was focused, not just inside guest content. A concrete capture-ownership gap exists on the second display: SecondScreenController configured captured mouse mode but had no windowDidResignKey release, and hideForHarmony did not explicitly release before ordering out/leaving fullscreen. The combined-screen pane also hid without releasing, and its parent window's resign handler released only the primary view. All these paths now call the owning view's releaseAll, which balances ungrab only if that view actually grabbed. This is stronger source evidence for the app-wide symptom than a transparent guest shape alone, but the exact user gesture has not been reproduced.

Final release build and strict deep signature verification pass. Process inventory confirmed the user had already closed the frontend/VM; no running guest was interrupted. Installed at build/PowerEmu Harmony Test.app; previous active-scheduling build retained at build/staging-cursor/Previous Active Scheduling Test.app. Exact intermittent cursor disappearance still requires live user verification, particularly capture on the second display followed by Harmony entry or a switch to a host window.
