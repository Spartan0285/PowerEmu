# Harmony fullscreen handoff and refresh candidate

September 28, 2026. Candidate: `build/Harmony Fullscreen Refresh/PowerEmu.app`, with guest Tools **2.11**. The running Dock Restore Fix session is left in place. The user has confirmed the minimize/restore fix; that state machine is preserved.

## Changes

- Decode complete window images on a dedicated serial worker instead of the main UI thread. Keep the single request outstanding until publication, so no decoded-frame backlog forms. Recheck active state, sequence, proxy identity, dimensions and unchanged-frame base before publishing. Exit/re-entry discards stale work. This removes decompression from the input/window-management thread; it does not speed up the guest capture API or establish a new measured frame rate.
- The guest observes `CGDisplayIsCaptured(CGMainDisplayID())` while Harmony is active. A capture lasting at least 150 ms emits one `FULLSCREEN captured` control message. Transient captures reset the debounce. Ordinary maximized windows, hidden menus and desktop geometry are not triggers.
- On this message, the host exits Harmony and presents its normal full-guest display window. It deliberately discards the saved pre-Harmony resolution instead of forcing that resolution over the game's mode. It does not automatically enter a host macOS fullscreen Space or automatically return to Harmony.
- The guest postpones Finder/Dock restoration while the game owns the display, then restores preferences after release. Restarting those processes in the middle of game launch could steal focus.
- Attempting Harmony preparation while the guest display is already captured produces the same handoff without changing the guest resolution.

## Verification

The fullscreen debounce regression covers an uncaptured desktop, short-lived captures, sustained capture, duplicate suppression and release/re-entry. The transport regression verifies that only recognized reports on the control connection reach the fullscreen callback. Existing title-click/restore regressions and geometry/frame decoding regressions (including 600 PowerPC pixel-packet fixtures) pass. Tools compile against the 10.4 SDK on the PowerBook; source hashes there match the local source. The production app build and deep/strict signature verification pass.

Warcraft III launch, its actual display-capture behavior, the visual handoff and return from the game have **not** been tested live. Borderless apps that never capture the display are not covered by this detector. Do not replace this with a window-size-only heuristic, which would misclassify ordinary maximized windows. Multi-display capture is not covered.

## Live acceptance checks

1. Open this candidate after finishing the current VM session. Install its Tools 2.11 in the guest, and ensure the new agent is running.
2. Enter Harmony. Drag, click between windows, minimize and restore repeatedly; confirm the previously fixed behavior and intact surfaces.
3. Launch Warcraft III fullscreen. Expect the ordinary full-guest display to appear once, without a forced desktop resolution change or Finder/Dock interruption. Test keyboard and mouse input.
4. Quit the game. Confirm the guest desktop/Dock return. Re-enter Harmony explicitly and verify alignment, refresh and Dock restore again.
5. Maximize a normal guest window. It must remain in Harmony. If Warcraft III does not trigger an exit, capture the display-ownership and window-layer evidence before extending detection.

For refresh comparisons, compare identical guest workloads and collect capture round-trip timings separately from host decode time. Prior detailed frames required around 12 ms of host decode work; this candidate moves that work off the main thread but makes no new throughput claim.
