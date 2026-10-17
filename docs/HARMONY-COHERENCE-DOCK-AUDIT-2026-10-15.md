# Harmony Dock behavior audit and simplification

October 15, 2026

Harmony should present one guest application through one stable host Dock identity, whether it is running, pinned or launched while its VM is stopped. Current code has three helper modes with different launch and Quit behavior. Consolidating those modes addresses a concrete source of inconsistency; adding another shortcut utility would preserve the complexity.

## Verified Parallels behavior

These are observable contracts from official documentation. Windows Coherence is the primary reference. They do not establish Parallels private implementation or exact event timing on a current installation.

| User action or state | Documented behavior | Source and scope |
| --- | --- | --- |
| Open a guest application | Its host Dock icon appears automatically. Pinning is optional. | [Parallels beginner guide](https://www.parallels.com/blogs/getting-started-tips/), July 18, 2025. |
| Pin an application | It can remain available like a Mac app. The older manual explicitly describes Keep in Dock and dragging from Finder. | [Beginner guide](https://www.parallels.com/blogs/getting-started-tips/) and [Desktop 10 guide, page 37](https://kb.parallels.com/Attachments/kcs-35993/Parallels%20Desktop%2010%20User%27s%20Guide.pdf). |
| Click a running application | Switch to it. | [Coherence KB4670](https://kb.parallels.com/en/4670), reviewed February 9, 2023. Exact foreground-window priority is unspecified. |
| Several application windows | Dock context menu selects a window; Show All Windows is available. | [KB4670](https://kb.parallels.com/en/4670). |
| Quit or hide | The menu offers native-style Quit, Hide and related application commands. | [KB4670](https://kb.parallels.com/en/4670). |
| Launch when Windows is stopped | Windows starts automatically in Coherence before opening the application; login may be required. | [Desktop 18 guide, page 33](https://download.parallels.com/desktop/v18/docs/en_US/Parallels%20Desktop%20User%27s%20Guide.pdf). |
| Exit the app or stop its VM | Ordinary icons disappear; kept icons remain shortcuts. | Historical [Using Dock in Coherence, page 135](https://download.parallels.com/stm/docs/en/Parallels_Desktop_Users_Guide.pdf). Exact current suspend/restart transitions remain unverified. |
| Force Quit | Tools can route a host Force Quit action to a guest application. | [Desktop 20 Sharing Applications](https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/sharing-applications). |
| Browse installed applications | An optional Applications folder in the host Dock provides access without pinning everything. | [Desktop 20 Sharing Applications](https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/sharing-applications). |
| Outside Coherence | Desktop 20 offers a setting to show guest app icons only in Coherence. | [Desktop 20 Application Settings](https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/parallels-desktop-preferences-and-virtual-machine-settings/virtual-machine-settings/options/application-settings). |
| Reorder a Dock icon | Native macOS permits dragging items to different Dock positions. | [Apple Dock guide](https://support.apple.com/en-gb/guide/mac-help/mh35859/mac). This does not establish Parallels activation callbacks or automatic pinning for every transient-icon drag. |

Tools are required for Coherence, and application sharing supports Finder access. These features are distinct from an optional application-browser folder. [Parallels Coherence requirements](https://kb.parallels.com/en/4670), [application sharing](https://docs.parallels.com/landing/pdfm-ug/v20-en-us/parallels-desktop-for-mac-20-users-guide/use-windows-on-your-mac/setting-how-windows-works-with-macos/sharing-items-between-macos-and-windows/sharing-applications).

Historical OS X Coherence and modern Windows Coherence must not be conflated with current macOS Arm guests: Parallels explicitly lists Coherence as unavailable for macOS Arm VMs. Tiger remains our own integration target. [Current macOS Arm limitations](https://kb.parallels.com/en/128867), reviewed January 27, 2026.

## Concrete Harmony inconsistencies

The local audit covers GuestDock.swift, GuestAppShortcuts.swift, GuestAppLauncher.swift, helper/main.swift and the guest Agent process reports.

- Transient representatives are keyed by session and PID, selected shortcuts by session and application path, and persistent launchers by VM and application path. One app therefore has multiple potential host identities.
- Selected shortcuts keep their helper running even when the guest app is closed. macOS running presence then describes the helper rather than the guest application.
- Transient Quit sends QUITAPP and waits for guest exit. Selected and persistent helpers instead terminate themselves. The selected-shortcut keeper can relaunch the helper without quitting the guest app.
- Session directories are removed at stop. Pinning their temporary executable path cannot provide a durable cold launcher.
- Window reports and process reports both influence removal. Window-derived absence uses a 20-second grace period, and empty running snapshots are ignored. These policies complicate the distinction between app exit, no open windows and unavailable Tools.
- Changing a selected icon restarts its helper. This creates unnecessary host process transitions and an opportunity for activation side effects.

The existing guest DOCKAPPS report already enumerates foreground application processes and their bundle paths, including apps without windows. That is the better foundation for application lifecycle. Window reports should supply window lists and geometry only.

## Replacement contract for Harmony

This is the proposed implementation contract, including Tiger-specific choices rather than claims about undocumented Parallels internals.

1. Give each VM and guest application one durable launcher identity. PID, session and window IDs are runtime attributes. Preserve existing signed executable bytes and trust validation; do not repair identity by modifying signed code or bypassing Gatekeeper.
2. Separate pinning from execution. Running apps appear automatically in Harmony. A pinned closed app remains launchable without an always-running helper. Replace the selected-session shortcut mode and separate permanent-launcher creation flow.
3. Use one click route. Activate or reopen an app already running; launch an app that is closed; start or resume its correct VM first when necessary. Coalesce repeated clicks during startup, wait for a verified guest bridge, and fulfill the request once.
4. Use one graceful Quit route for every representation. Let the guest display Save or Cancel, and keep runtime state until actual exit. Do not respawn a representative merely because Quit was requested. Force Quit must target the guest app and remain a distinct explicit action.
5. Group windows under their app. Window close and minimize do not imply Tiger application exit. A window-list selection addresses the exact window without launching another app instance.
6. Derive running state from complete validated process snapshots. A valid empty snapshot and an unavailable connection are different. Tools disconnect means unknown state; it must not trigger duplicate app launch, VM restart or removal of durable launchers.
7. Let macOS own Keep in Dock, removal and ordering using the same stable launcher target. Reordering must not select another helper mode, recreate the icon or alter Harmony state.
8. VM shutdown clears runtime presence, while native pinned items remain. Resume/restart reconciles from fresh guest truth. Keep guest Dock visibility and capture scheduling separate from application identity.
9. Keep a single optional searchable Guest Applications browser. It launches apps and exposes their durable shortcuts; users need no checkbox configuration to see running apps.

## Acceptance tests before replacing the existing model

- Start an unpinned app: exactly one icon with correct artwork and running state. Close its last document: follow actual Tiger app lifecycle rather than window count.
- Keep that same icon in Dock, reorder it, quit the guest app, stop the VM and quit PowerEmu. The pinned target remains valid; reopening starts the correct VM and app once.
- Repeated clicks while starting produce one pending launch. Canceling startup cancels the pending request cleanly.
- Quit through a transient or pinned icon has identical guest behavior. An unsaved document presents Save/Cancel; Cancel leaves the app and icon running.
- Multiple documents share the app identity and have a correct window list. Minimize, restore and close act on the requested window.
- Different VMs running the same app name remain distinct and correctly routed.
- Tools reconnect, helper exit and host restart do not duplicate tiles or corrupt pin targets. Stale sessions cannot activate a new session's app.
- Icon updates do not restart or activate a helper. Dock movement cannot stop capture or prevent Harmony re-entry.
- Repeat cold-launch and pin persistence with strict signatures and the actual packaged Tools installer, preserving the earlier trust and executable-permission fixes.

Exact current Parallels suspend behavior, same-name concurrent-VM grouping, all-windows-minimized activation priority, and the precise Dock reorder callback sequence require a live Parallels installation. None was available locally. These cases remain explicit Harmony design/test choices rather than fabricated parity claims.

## Delivery at the time of the audit

Test 4.3 remains the latest signed build and the user reports it worked. This audit changes no production code, VM, Dock preference or guest installation. The next implementation should consolidate identities and lifecycle before adding more contextual-menu options.

Implementation and measured native checks are recorded in [Unified Harmony Dock](HARMONY-UNIFIED-DOCK-2026-10-15.md). Native Keep in Dock remains an explicitly unscored manual gate until the actual user action is observed.


## Post-release integration priorities — October 15 evening

User prioritized Harmony responsiveness first, then improvements to the broader Tools integration list, with audio afterward. PowerEmu targets Tiger/Leopard, so Windows-specific tray/DWM APIs are not assumed.

| Requested capability | Current PowerEmu implementation | Next useful scope |
| --- | --- | --- |
| Free-moving pointer | Absolute tablet input, Harmony coordinate routing, cursor synchronization | Recheck crossing displays, focus transitions, drag release and cursor restoration |
| Clipboard | Bidirectional UTF-8 text; periodic change detection | Measure paste latency and preserve ordering; file clipboard is separate unfinished work |
| File/folder drag-and-drop | Shared-folder/drop staging and guest drag protocol | Qualify folders, cancellation, progress and large transfers; preserve resource forks |
| Coherence-style windows | Harmony per-window capture and stable per-VM Dock apps | Reduce capture spent on fully hidden host windows; verify immediate fresh exposure |
| Dynamic resolution | Harmony screen matching, startup mode selection, host-side fit modes | Guest resolution following arbitrary VM-window resize is not established as supported |
| Tray/menu extras | Guest application menus are integrated | Tiger menu extras are not Windows tray items; no arbitrary tray mirroring claim |
| Shared folders/profile | Explicit WebDAV shares and host-change refresh | Useful folder presets, without silently replacing guest home folders |
| SmartMount | Remembered USB-device attachment and explicit external-disk lending | Automatic safe file sharing of newly mounted volumes; do not equate sharing to raw USB capture |
| Shared applications | Host Open With / file routing and guest application launchers | Broader guest-to-host routing and default-app selection need qualification |
| Shared internet apps | No verified general guest-default-browser bridge | Explicit HTTP(S) routing, avoiding system handler changes without clear user choice |
| Printing | LPD receiver and host CUPS routing | Easier printer discovery/setup; not automatic printer/driver parity |
| Time | Host clock relay and guest clock service | Timezone propagation remains separate from UTC clock synchronization |

The next capture candidate is opt-in (`POWEREMU_HARMONY_SKIP_OCCLUDED=1`), preserving first-image requests and failed-capture backoff. It uses AppKit's host-window occlusion state, not guest covering estimates, and resumes via exposure eligibility. Pure scheduler tests and an own-window AppKit covered/exposed integration check pass. One initial integration attempt did not observe the intended occlusion before its check and was unscored; the test now bounds readiness to three seconds. This is not yet a guest FPS or input-latency improvement claim. Release 0.4.2 remains unchanged.


### First capture-efficiency candidate: measured live

Same newly built host executable, default path OFF then candidate ON; isolated single-display clone, no guest Agent install. Control owned43593: in a 12.000886-second fully covered interior interval, 481 requests/481 responses, all reported hidden; visible proxy count zero. Candidate owned44023: in 11.999459 seconds under the same bounded opaque host cover, zero requests/responses/hidden requests, visible proxy count zero. Existing one-second diagnostic timer verifies that zero requests is not merely missing frame logs. Responses resumed with visible windows within the first five seconds after cover removal; sampling does not establish subsecond input-to-pixel latency. Both cover processes closed themselves after fourteen seconds.

CUA verified real Finder pixels after uncovering, Cmd-N created fresh window57 with complete home-folder contents, and Harmony exit/reentry repainted it. Coordinate double-click produced ambiguous target selection and the scroll attempt had no independent pixel-position check: neither is scored as a pointer/scroll improvement. One preflight readiness script indexed its tuple incorrectly and was unscored; corrected readiness preceded both cover controls. No builds/heavy analysis ran during scored cover intervals.

Signed separate candidate: `build/staging-hourly/PowerEmu Harmony Efficiency Test 6.app`. Includes Tools2.24, current tested host and exact live backend SHA25619ffdd80aee3bfd6042cdb27d6ecd18ef47189691b6721908bc05d8b2be5a16e. Unique candidate identity, no private-support/debug override, skip-occluded1/native-polling1/visible-cache0/AIC1. Strict nested signatures pass. Receipt and per-second data: `build/harmony-occlusion-2026-10-15/`. No general FPS/CPU-percent/active-window speed claim follows from this workload; the measured benefit is removal of wasted captures while all proxies are fully hidden.

All owned VMs stopped before their480-second guards, original private two-display configuration and prior QA frontend executable/Info restored, guest Agent untouched. Public0.4.2 unchanged. Code remains opt-in pending broader app/partial-cover/minimize/display checks; no new commit or release.

### Active-window input scheduling — bounded OFF / ON / OFF check

User next prioritized active refresh/click response, sharing, then audio, and explicitly requested lower-model subagents. Two gpt-6-luna reviewers examined capture/input and sharing. Existing active-window clicks already skip redundant FOCUSWINDOW; no guest focus-ACK bypass was added.

Implemented default-OFF `POWEREMU_HARMONY_INPUT_PRIORITY=1`: an interaction at the end of the normal six-capture foreground burst may borrow one foreground slot from an eligible ordinary background window. Background service repays it before another loan, including across focus changes. First-image/exposure, failed capture backoff and fully occluded suspension remain protected. The earlier skip-occluded Test6 behavior is retained. Pure fixtures cover default control, repeated input, repayment, focus switches, first-image repayment and hidden/failed active windows; all pass.

Added opt-in `POWEREMU_INTERACTION_TIMING=1` bounded 256-row host timing. It records input dispatch to accepted publication of a capture whose request sequence starts AFTER that input; pre-input in-flight requests and other windows cannot satisfy it. It resets across Harmony sessions, counts superseded gestures/drops, and flushes only at mode transition. This is NOT guest paint completion or physical click-to-photon timing. Button down/up and quick key gestures may supersede one another; resulting rows are not independent per-click samples. No claim of full animation FPS follows.

Same release host binary and unchanged guest Agent, isolated single-display clone, native polling/skip-occluded enabled, input-priority OFF→ON→OFF:

| Run | Owned PID | Retained timing rows | Median ms | Descriptive p95 ms | Max ms | Borrowed slots |
| --- | --- | --- | --- | --- | --- | --- |
| Control | 49845 | 30 | 69.015 | 135.387 | 175.984 | 0 |
| Candidate | 50277 | 32 | 66.438 | 111.694 | 151.054 | 6 |
| Return control | 50865 | 31 | 69.308 | 120.068 | 183.027 | 0 |

CUA used matching Finder home windows: initial Desktop selection, 12 alternating Desktop/Documents clicks, 12 alternating icon/list keyboard shortcuts, explicit list-view screenshot, icon restore/close and Harmony exit. Selection and final list contents visibly verified, no freezes. Intermediate every-click painting was not independently timestamped. All retained timing drops zero; superseded 28/26/27 and one pending final gesture per run are explicitly retained. Timing improvement is small and this short workload is insufficient to promise noticeable overall speedup. Candidate remains experimental/default-OFF; Test6 remains the latest user-facing build. No replacement build/release/commit was made. No heavy builds or analysis ran during scored actions.

Release build and strict internal signatures pass. Artifacts `build/harmony-input-2026-10-15/` include three host logs, comparison.json, fixtures and cleanup receipt. All three owned VMs stopped before480-second guards. Exact prior QA executable/Info/private two-display config restored, QA strict signature verified; guest Agent unchanged and user Test5.1 host left untouched.

Sharing review: host and guest text clipboard poll at500ms. There is no CLIPACK. Clipboard socket writes and USB keyboard input are different paths, so merely sending CLIP before Cmd-V does not guarantee guest application order. No speculative host-only ordering patch or5× polling increase was made. Next reliable paste work needs a token/session-scoped guest acknowledgement after pasteboard update, bounded pending key handling, disconnect/timeout behavior, Unicode/echo/disabled-sharing coverage and actual live ordering validation. Audio remains queued behind these priorities; no new playback result in this turn.

### Actual changed-pixel latency oracle — next focused pass

User explicitly kept active refresh/click latency ahead of all sharing/audio work. Added default-OFF `POWEREMU_PIXEL_LATENCY=1` host oracle plus a temporary own-window Tiger fixture, not a Tools install. Fixture has640×400 content; each mouseDown synchronously changes an eight-bit counter encoded in black/white bands with an alternating A6/59 magic strip. Host recognizes exact counter0 before arming a window, pairs up to64 dispatched clicks with decoded changed image counters, retains bounded rows and flushes on Harmony transition. Pure tests validate0…64 in both row orientations and reject invalid contrast. This measures dispatch to decoded pixels immediately before `setOwnImage`; it does not include prior focus-ACK wait, host compositor display latency or photons. It is not a general-app FPS benchmark.

Actual control owned53484:21 sent/21 exact changed-pixel rows, skipped0/pending0/unpaired0, median68.668ms, descriptivep95=134.431ms, max161.423ms. CUA verified counter0, first change and final21 pattern; every click's encoded value was validated by the host oracle. Source initially used newer CGFloat/formaldelegate protocols and failed10.4u compilation; corrected to float/informaldelegates/unistd and compiled successfully. Bare SSH execution exited with CFMessagePort bootstrap failure, unscored; temporary `.app` plus LaunchServices open worked. Fixture self-exits within180sec and never controls another app.

A proposed TCP_NODELAY host experiment was INVALID, not a speed comparison. Actual option readback exposed `set=-1/read=0/value=0`: GuestAgent.Connection accepts AF_UNIX, with guest TCP mediated by QEMU's guestfwd/nc. The complete21-counter run54124 is retained but no transport-change claim follows. The added GuestAgent experiment was completely removed; GuestAgent.swift matches its prior source. No repeated TCP toggle trial is justified. Its retained median72.440ms/p95=115.014ms/max217.935ms only describes another unchanged transport run.

Artifacts `build/harmony-pixel-latency-2026-10-15/`: fixture source/PPC, pure test, host logs, comparison.json and cleanup receipt. All owned VMs stopped before480-second guards; prior QA host/Info/private two-display config restored and strict signature verified. Guest Agent and public/Test6 bundles unchanged. The pixel oracle and its small fixture test remain uncommitted diagnostics; no noticeable-performance result, new user build, release or audio/sharing change is claimed. Next workload should isolate the interaction the user finds slowest (active scrolling/resizing, already-focused clicks, or app switches), and retain exact changed-source validation rather than count unchanged frame responses.

Independent lower-model oracle review confirmed the RGBA/parity decode and identified lifecycle/terminology limits. Follow-up source now binds the target to both window ID and host proxy object identity; same-ID replacement invalidates the receipt rather than accepting replacement pixels. Unpaired counter increments saturate. New fixtures cover click pairing, unchanged-frame exclusion, proxy reuse rejection and session reset. Metric renamed `hostInputDispatchToDecodedFixtureCounterMS` to distinguish decode recognition from layer publication/display. These audit changes were fixture-tested after the retained live runs; the original live logs keep their original label and are not retroactively relabeled as a rerun. Fixture source also retained at `guest/tools/pepixellatency.m`. Optional user question asks which interaction is slowest; no answer required for further independent investigation, and no sharing/audio work was started.
