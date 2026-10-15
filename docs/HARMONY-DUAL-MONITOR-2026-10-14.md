# Harmony dual-monitor investigation — October 14, 2026

Preserved the existing uncommitted display-mode, host-screen and dual-screen changes.

Confirmed defect: Harmony filtered all guest windows against screen1's vertical range, even when the guest reported a second screen above/below it or a taller second screen. Those windows were removed from the shown/capture list. The menu-bar filter additionally treated any shallow window at a negative Y as a primary menu-bar fragment.

Added `HarmonyGuestDesktop` to test visibility against the union of the two actual guest screen rectangles. Primary menu-bar filtering now requires its actual top edge and primary horizontal range. A window spanning staggered displays whose centre falls in a gap is assigned by greater visible intersection. Single-host-screen folding remains on its existing path.

Checks: geometry regressions cover left/right/above/below, a taller second display, off-desktop rectangles, shallow secondary windows and staggered-display ownership. Existing HarmonyCoordinates round trips also pass. Swift debug and release builds pass. Signed test app: `/Users/adam/Developer/PowerEmu/build/PowerEmu Harmony Test.app` (strict deep verification passed). It includes the rebuilt emulator with default-off audio lock diagnostics; it is not an audio improvement build.

Live validation remains required. At investigation start this Mac reported only its built-in display, while the user's Tiger VM config had two guest screens (second1680×1050). A second host monitor must be connected to verify entering/exiting Harmony, window capture and focus on both screens, dragging across the boundary, and resolution restoration. These fixes are concrete code defects, not a claim that every dual-monitor failure has been reproduced or solved.

## Reproduced entry failure and repair

The reported resize overlay was reproduced with the connected AirPlay display. Tiger had made physical guest graphics card 1 its main display. The guest acknowledged the requested 1728×1074 Harmony mode and reported that primary desktop size, but the host kept checking card 0's 1680×1050 surface. The host therefore timed out despite a successful guest resize.

The host now uses the guest SCREENS primary desktop geometry for preparation, timeout diagnostics and native-window layout. It requests SCREENS during preparation and routes primary/secondary capture surfaces according to the guest's current main card. Distinct surface sizes identify the card; ambiguous equal sizes preserve the prior mapping. Geometry fixtures cover the swapped-main case and ambiguity.

Live result: the signed test build entered Harmony and displayed a clean native Finder proxy without the resize overlay. The guest screen report and capture log are retained in `docs/evidence/harmony-dual-2026-10-14/fixed-run.log`.

Cross-screen validation is incomplete. AirPlay disconnected during the first drag, leaving only one host screen; the observed folding therefore does not establish a cross-screen positioning defect. The user reconnected it, but a subsequent macOS screen query still reported only the built-in display. Await a stable extended second desktop before scoring cross-screen drag, clicks, refresh and resolution restoration.

Also added Harmony teardown when the VM window closes, to remove stale proxies after guest termination. This final cleanup is being rebuilt and requires live verification. Tests use an independent APFS-cloned Tiger base and private writable overlay; the user's original disk is not opened writable by these tests.

## Stable Sidecar live validation

The replacement device stayed connected: built-in desktop 1710×1107, Sidecar extended desktop at (1710,0), 1600×1200. The signed rebuilt host entered Harmony after Tiger tools finished starting. A premature request during guest startup timed out without acknowledgment; retry after SCREENS/tool availability succeeded.

CUA dragged Finder proxy 34 from guest (532,131) to (2145,342) on the secondary desktop; MOVEWINDOW returned ax=0. Its surface remained clean, mouse selection updated and keyboard navigation opened Macintosh HD as proxy70. CUA then dragged proxy70 from (2260,136) back to (816,75) on the primary display; ax=0. Mouse selection visibly updated there too. No surface corruption was observed in these interactions. This is functional validation, not a refresh-latency benchmark or full modal/dock regression.

Exiting Harmony removed proxies and returned to the ordinary VM window; secondary mode restored from1680×1088 to1680×1050. Both host screens remained connected at exit. The owned isolated VM was stopped afterward. Evidence: `docs/evidence/harmony-dual-2026-10-14/sidecar-run.log`. The final cleanup patch was included in this build; shutdown while Harmony is still active remains a separate unchecked case.
