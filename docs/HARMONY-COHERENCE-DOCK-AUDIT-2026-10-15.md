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
