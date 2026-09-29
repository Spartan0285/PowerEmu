# Tools packaging and window-menu handoff

September 28, 2026. Tools **2.16** removes automatic Finder-window cleanup from Harmony transitions. The 2.15 nil-snapshot/session guards did not make title matching safe: the live trace still showed real windows being closed. Harmony no longer compares Finder window names or schedules delayed close commands. Finder may restore an old window when restarted; preserving user windows takes priority over suppressing those restorations.

## Tools disc

The disc now contains separate **Install PowerEmu Tools.pkg** and **Uninstall PowerEmu Tools.pkg**, built with PackageMaker's 10.4 target. These open in the native Mac OS X Installer, with branded welcome pages. Classic PowerEmu icon elements generated on the PowerBook support Tiger; modern host-only icon formats are not used for this disc.

Installation has no removal button. The separate removal package states which features stop working and requires the normal Installer confirmation/authorization flow. The embedded standalone installer also hides and rejects removal; the embedded uninstaller explicitly confirms removal if opened directly.

Both packages require administrator authorization. Installation enables guest Accessibility window control and installs the clock service. The helper drops root privileges to the logged-in console user before changing that user's agent/login items. It stages the new agent before stopping/replacing the existing one. Uninstall removes that account's agent/login item and the named clock service files; it deliberately leaves the shared system Accessibility setting enabled. Packages target the running guest's root volume and require a logged-in desktop user.

The hard-coded “Tools 2.8” Harmony preparation message now displays the actual bundled Tools version. Host installation guidance names the .pkg.

## Guest Window menu

Periodic guest focus reports cannot reorder host windows indiscriminately, because that would break mixed host/guest stacking. An explicit menu command now carries a unique token. After the guest performs it, it resolves the focused Accessibility window to its guest window ID and returns a token-bound MENUFOCUS reply. The host raises only that proxy.

Superseded, duplicate, expired and cancelled replies are ignored. Leaving Harmony or changing host key-window focus cancels the pending action. Replies do not restore windows currently minimizing or awaiting restore. This preserves the existing minimize/restore state machine.

## Drag and drop status

Tools 2.16 includes the targeted transfers introduced in 2.14. A host file dropped on a guest Finder window is copied into that window's folder. A host file dropped on another guest application window, or on that application's host Dock tile, is copied into `~/Documents/PowerEmu Imports` and delivered to the application with the classic Open Documents Apple event. A Finder item dragged out of a guest window becomes a native host file promise, so it can be dropped on the host Desktop, Finder windows, and host applications that accept files.

Files travel through a private per-VM WebDAV share rather than the display/control stream. Each file or folder is wrapped with `ditto` ZIP transport to preserve folders, resource forks, and Finder metadata. Transfers run at utility priority and exports are serialized, leaving the capture path responsive. Host applications that supply promised files are supported as inbound drag sources.

The target is resolved when the drop begins; navigation during a large copy cannot silently redirect it. Existing files are never replaced. Tiger chooses `name (2).ext`, `name (3).ext`, and so on. Failures are reported on the host, disconnects complete outstanding promises with errors, and host-to-guest copies show a progress panel.

The initial alpha deliberately rejects symbolic links, special files, malformed ZIP paths, encrypted/ZIP64 archives, more than 256 items, and individual items over 4 GB. Guest-to-host dragging originates in Finder; arbitrary guest applications do not yet expose document drags. These cases fail visibly instead of copying partial or unsafe content.

## Verification and limits

- The production build and deep/strict signature verification pass. The bundled disc was mounted and checked for the two packages, Tools 2.15, root authorization, script syntax and matching binaries.
- Both native packages are recognized by Tiger's `installer -pkginfo`.
- In the isolated Tiger clone, package helpers successfully installed, removed and reinstalled the agent; file presence/absence was checked.
- A two-process Tiger test verified the actual guest Accessibility-to-window-ID resolver against a known test window. Its Cocoa UI completes normal startup before answering Accessibility queries.
- Host regressions cover menu token supersession, duplicates, expiration and cancellation; transport checks reject malformed/untrusted-channel replies. Existing minimize/restore interaction checks pass.
- The isolated Tiger integration test copied a Unicode-named folder host-to-guest twice, verified collision naming, verified the data and resource forks, then exported it back through the production agent and WebDAV implementation. Invalid targets and a traversal archive were rejected. A document drop was delivered to TextEdit through Open Documents. Host tests cover native file promises, serialized multi-file exports, disconnect completion, promised-file inputs, Unicode/newline names, resource forks, collisions, symbolic links, and malformed archives.
- The PowerEmu icon was visually inspected. Native Installer's complete administrative authorization/clock-service flow has not been exercised end-to-end in Tiger; helper testing ran as the logged-in user.
- Selecting a real guest application window through the host menu and observing its host stacking still needs an interactive pass. The code path and guest resolver are tested; this is not a claim that the user's exact stacking sequence was reproduced.

Build with `guest/scripts/build.sh` on the PowerBook, then `scripts/build-smp-app.sh` with the candidate output path. Package creation is part of the guest build; disc creation includes only the two packages and Read Me at its root.
