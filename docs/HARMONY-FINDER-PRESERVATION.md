# Harmony Finder preservation — Tools 2.19

## Root cause

Tools 2.18 restarted Finder on entry and exit to change `CreateDesktop`. Finder then reopened its own saved windows, which can have older folders or positions. The previous `PE_HARMONY_KEEP_FINDER` experiment was not enabled in production. Its test also left capture mode enabled on exit, unlike the real host, which sends `CAPTUREMODE 0` before `HARMONY 0`. Merely enabling that experiment would therefore still restart Finder on exit.

## Fix

Normal Harmony uses complete per-window backing-store capture, which already filters desktop windows. Tools 2.19 leaves Finder and its desktop preference untouched in this mode. It latches whether Finder preferences were changed at session entry and uses that decision on exit, independently of subsequent capture-mode commands. The legacy framebuffer masking mode retains its desktop-hiding behavior.

Successful exit clears remembered session preferences, so the next entry snapshots current settings. Repeated on/off commands remain idempotent, and deferred fullscreen exits retain session state until they finish. No Finder windows are closed, reconstructed, or matched by title.

## Validation

- Isolated Leopard 10.5.8 on Mac Studio: three guest-side cycles with the production command order, duplicate-title windows, a folder target changed between sessions, and repeated state commands. All Finder window IDs, folder URLs, bounds and collapsed-state values survived entry and exit; Finder PID stayed 982. Desktop windows were excluded from WINDOWS reports.
- Isolated Tiger 10.4.11 on MacBook Air: same three-cycle test passed; Finder PID stayed 1605. The initial test harness used an AppleScript window-reference form unsupported by Tiger; changing it to indexed Finder windows fixed the harness. The isolated guest was returned to its original paused state.
- Actual Mac Studio host frontend with the updated guest agent: off/on/off/on preserved Finder PID 982 and window IDs 97, 66, 27. Host logs confirmed every transition and populated complete-capture proxies afterward, including the existing attached sheet. Evidence: `docs/evidence/harmony-finder-preservation-2026-09-29/leopard-host-cycles.log`.
- Signed app build and strict deep signature validation passed. Guest installer package reports Tools 2.19.

The regression harness is `guest/tools/pekeepfinder.m`, which compiles against the production agent source. Tests do not claim to validate every physical drag, display resize, or minimized-window transition. Existing windows already restored incorrectly by older tools cannot be reconstructed automatically. Arrange them as desired before retesting with 2.19.

## Test build

`build/PowerEmu Finder Preservation/PowerEmu.app`

Exit Harmony using the old tools first, install bundled Tools 2.19, and then reenter Harmony. Updating while an old agent has already hidden the desktop may preserve that old preference; the new agent deliberately does not overwrite user desktop preferences. The user's active Tiger app was not replaced or restarted during this investigation.
