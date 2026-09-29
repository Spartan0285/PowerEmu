# Leopard Harmony focus and movement — Tools 2.20

## Confirmed cause in the user's Leopard guest

The local host log showed window 56 failing focus and MOVEWINDOW, then reverting after the host's 1.5-second movement timeout. Another window accepted movement. Guest Accessibility was globally enabled, but a read-only GUI probe against the running Finder (PID 83) returned `windowsError=-25211`, while `AXAPIEnabled()` returned true. Apple defines this as [kAXErrorAPIDisabled](https://developer.apple.com/documentation/applicationservices/axerror/kaxerrorapidisabled).

The Tools installers create `/var/db/.AccessibilityAPIEnabled`, but already-running Leopard applications can retain a cached disabled state. This breaks window enumeration, activation, movement, and confirmed-focus click delivery. A visually frozen/unresponsive focused window therefore need not be a capture-scheduling failure.

Posting the distributed `com.apple.accessibility.api` notification in the guest GUI session changed the same Finder's AX query to success without restarting Finder, the guest, or its agent. The local host then logged `RAISE 56 ax=0 pid=83`. A preliminary Darwin `notifyutil -p` notification did not help; the required mechanism is the distributed CFNotificationCenter, not Darwin notify.

## Implementation

`guest/src/PEAccessibility.h` checks that access is already enabled, then announces that setting using `CFNotificationCenterPostNotification(CFNotificationCenterGetDistributedCenter(), ...)`.

- Agent startup refreshes existing applications' cached state.
- New Harmony sessions refresh it again.
- The GUI installer announces the change after successful authorization.
- The package installation path announces it after switching to the console user.
- Tools version is 2.20; the helper header is a build dependency for agent and installer.

The helper does not grant new access, create the enablement file, terminate applications, or change window state. No refresh-rate or movement-timeout increase was used to conceal the failed commands.

## Validation

- Live user Leopard 10.5.8: before notification `AX enabled=1 windowsError=-25211`; afterward `windowsError=0`, matching Finder window rectangle `(137,74,750,436)`. Successful host activation followed. Only the existing enabled setting was announced; the user's app/agent was not replaced.
- Isolated Mac Studio Leopard with compiled Tools 2.20: raise Finder window 145, request movement from `(4,26)` to `(220,180)`, then inspect reports beyond the old timeout. AX raise/move both returned 0, reports retained the requested location and `focus=1`.
- While focused, add a disposable file to that Finder folder. Before/after host snapshots changed from an empty folder to the correctly rendered new file; both were visually inspected. The file was removed and the original window position restored afterward.
- Guest tools built against the 10.4 SDK; full host app build and strict/deep signature verification passed. This does not constitute a new full Tiger regression, physical-drag test, or Leopard frame-rate benchmark.

Evidence: `docs/evidence/leopard-harmony-accessibility-2026-09-29/`.

## Candidate

`build/PowerEmu Leopard Harmony/PowerEmu.app`

Includes Tools 2.20, the VRAM firmware-range correction, Finder preservation, and previous drag/drop and sheet changes. Exit Harmony before installing the bundled tools, then enter again. Applying the separate VRAM boot correction requires a full guest shutdown/start.
