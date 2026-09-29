# Harmony drag and minimize candidate

September 28, 2026. Latest build: `build/Harmony Dock Restore Fix/PowerEmu.app`. Previous candidate: `build/Harmony Interaction Fix/PowerEmu.app`. Host-only change; bundled guest Tools remain 2.10. The user's running session was not replaced.

## Reports and changes

The user reported a window disappearing/closing after a drag followed by clicking a different window, and a minimize animation that immediately restored the window on the first attempt.

- Move minimize bookkeeping and the guest minimize request from `windowDidMiniaturize` to `windowWillMiniaturize`. A geometry report during animation must already see host minimize intent. Cancel queued focus input and held input when minimization begins, and suppress unsolicited raises for that window. Explicit Dock/Show Window restoration remains allowed.
- Scope queued pointer/button operations to their originating window. Drop events aimed at another pending focus target, and recheck the destination after focus acknowledgment.
- Do not inject pointer/button events while that window's move awaits a guest geometry report. Guest coordinates may already have changed while the host's cached rectangle still describes the pre-drag position.
- Require title-bar releases to match the pressed control and remain within click slop. A missing drag event or a window moving underneath the pointer must not turn a title press into Close.
- Cancel unfinished left-button/title gestures on key-window loss, and ignore orphan mouse releases. Commit an interrupted native title drag's final position without synthesizing a guest title click.

## Verification and limits

The production app build and deep/strict signature verification pass. New title-click regressions cover normal close/minimize/title clicks, changed control identity, a moved window beneath a stationary pointer, missing drag events, release outside the title band, and click slop. Existing frame, pixel packet, geometry, and transport checks also pass.

The minimize notification ordering and stale-position paths were identified in code. The exact user-reported disappearance has not been reproduced live; it may represent a guest close or a temporarily hidden proxy. Do not present these guards as a confirmed diagnosis of that symptom.

Live follow-up: drag a window and immediately select a different guest window; verify both remain open. Minimize on the first click, wait several seconds, and confirm it stays in the Dock. Restore through the application tile/Show Window and verify the next minimize also remains stable. Also check intentional Close and title-bar double-click behavior. No new guest installation is required if Tools 2.10 is already installed.


## Restore bounce follow-up

The user confirmed minimizing now stays in the Dock, but restoring immediately minimized the window again. The restore callback cleared `minimizedPid` and the baseline before the guest reported visibility. An absent WINDOWS report with a still-present minimized entry could then bind it as a new minimize.

The host now retains the minimized binding and an explicit restore phase until guest visibility is acknowledged. Deminiaturization starts that phase before the native animation; the completion callback is idempotent. Absent/minimized reports preserve the host window while restore is pending, and binding a late minimized entry sends exactly one unminimize request instead of performing another native minimize. A stale visible report cannot acknowledge a restore that is still waiting for its first binding. A newer explicit minimize cancels restore intent.

Regression checks cover repeated stale reports, duplicate native callbacks, early restore before guest minimize completes, one-time binding, visibility acknowledgment, and a new minimize superseding restore. These state-machine and build checks passed. The user subsequently confirmed that minimizing and restoring now work. Guest Tools remain 2.10 and do not require reinstalling for this host-only change.
