# Persistent guest-app Dock launchers — handoff

## Design

PowerEmu creates one user-owned launcher directory per VM package path and guest app path. The directory contains an unchanged copy of the signed standalone `PowerEmuGuestApp` executable, a versioned `launcher.plist`, and an optional cached guest icon. The sidecar is owner-only data; the helper checks its version, owner, file type, permissions, size, canonical VM path, guest app path, and directory identity before using it. The executable remains outside a mutable `.app` bundle. No runtime signing or quarantine/security bypass is used.

The persistent helper runs in a separate mode from transient session representatives. It has no guest PID or session identity, posts no transient activation/quit/file notifications, and does not use the transient orphan watcher. A normal cold launch validates the sidecar and opens its URL directly from `applicationDidFinishLaunching`; subsequent activation/reopen deliveries are subject to a one-second debounce. Install-only mode skips that direct open and consumes the first `applicationDidBecomeActive` callback so adding a launcher does not intentionally open the guest app. `applicationShouldHandleReopen` does not consume that flag, however, so install-only behavior still needs a lifecycle-order test if macOS delivers a reopen callback instead of (or before) the expected activation. A later Dock click opens `poweremu://guest-app` with the exact VM package path and guest app path. The generated PowerEmu app plist registers the URL scheme.

The PowerEmu Dock menu offers **Add Persistent Dock Launcher** for apps reported in the selected guest's Dock. Adding starts the helper so macOS can show its Dock tile. PowerEmu then tells the user to Control-click the tile and choose **Keep in Dock**; macOS owns that persistence choice. A cached icon is available only when the guest app has already supplied one through the running-app icon flow. Dormant apps currently use the helper's generic icon because the guest protocol has no icon-by-path request.

On URL open, PowerEmu reloads its library and matches the canonical package path exactly. It starts a stopped VM or resumes a paused VM, waits for the guest agent, and checks the app list before sending `LAUNCH`. It does not choose a VM by display name. A package outside the library cannot be opened by this route and no external security scope is acquired. The package path is stable across display-name changes, but a move or package rename makes an existing launcher stale.

## App-list freshness and duplicate clicks

The initial delay-based check could inspect an old `vm.guestApps` array. It is now gated by `VirtualMachine.guestAppsRevision`, which advances only when the existing `a.onApps` callback receives an `APPSLIST`. AppDelegate snapshots the revision before sending `APPS`, and only makes a present/missing decision after a later list arrives. If the agent connects but does not return a list, PowerEmu retries and gives up after 20 seconds without sending `LAUNCH`. If the guest agent never connects, it waits up to 180 seconds and reports that Tools did not connect.

In-flight requests are deduplicated by canonical VM package path plus guest app path. Successful launches have a two-second debounce against duplicate URL delivery. The guest protocol has no request ID, so a delayed `APPSLIST` from an earlier `APPS` request on the same connection can still advance the revision. The protocol also gives no result acknowledgement for `LAUNCH`; PowerEmu can confirm that the app path was listed immediately before the command, but cannot confirm that the guest actually opened it. A slow list response can therefore still arrive after the 20-second deadline and a prior response can satisfy a later query; these are protocol limits, not guarantees provided by the revision counter.

## Verification recorded

The focused launcher harness passed before the revision-gated lookup was added. It checks URL round-trip, exact package matching including a missing package, deterministic VM/app identity, invalid/incomplete/traversal/duplicate-query URLs, and byte-identical helper copying with a sidecar:

```sh
swiftc -parse-as-library tests/GuestAppLauncher/main.swift app/Sources/PowerEmu/GuestAppLauncher.swift -o /tmp/poweremu-guest-app-launcher-check
/tmp/poweremu-guest-app-launcher-check
```

The standalone helper typecheck, helper plist lint, build-script syntax check, and whitespace check passed:

```sh
swiftc -typecheck helper/main.swift
plutil -lint helper/Info.plist
bash -n scripts/build-app.sh
git diff --check
```

The earlier app package build stopped on errors in the concurrently edited `DiskRestore.swift`; those were subsequently corrected by the root agent and a release build was started. In a separate live cold-start check, the root agent installed the exact signed helper copy with an owner-only sidecar for the private clone Chess VM, named it `PowerEmuColdLaunchQA`, and executed it with PowerEmu and the VM stopped. The helper cold-launched the intended Preview build and a private QEMU process (observed helper PID 62543 and QEMU PID 62554 under a 480-second guard). At the time of this handoff, guest Chess opening had not yet been confirmed. This demonstrates cold helper-to-host routing, not the complete guest launch, Dock Keep persistence, behavior with multiple registered PowerEmu builds, or install-only lifecycle behavior. The earlier helper typecheck/plist/build-script checks do not cover those live paths.

The existing [Dock trust-fix record](DOCK-APPLET-TRUST-FIX-2026-10-14.md) documents the prior signed-helper runtime fixture and its limits. That fixture does not verify persistent launcher mode or a live Dock click.

## End-to-end gates

- Build and sign a release app containing both the URL handler and the versioned helper. Verify the helper copy in a persistent launcher is byte-identical and still passes strict signature verification with its original Developer ID chain.
- Complete the in-progress cold-start check by confirming the guest Chess app actually opens, and separately test a real kept Dock tile. Confirm LaunchServices starts the intended PowerEmu build, the exact VM package is found, the VM starts, and the guest app opens. If multiple PowerEmu builds register `poweremu`, verify which host build macOS selects and how a stale/mismatched library is reported.
- Exercise install-only creation under the actual Dock lifecycle callback order. Verify the initial helper activation/reopen never launches the guest, then verify a later user Dock click does. The current flag is consumed only by `applicationDidBecomeActive`, not by `applicationShouldHandleReopen`.
- Exercise a stopped VM, a paused VM, a VM already starting, and a VM whose Tools agent connects late. Confirm the bounded wait and error messages; confirm no guest app command is sent before an app-list reply from that connection.
- Test the freshness race: remove an app after a previous `APPSLIST`, delay a current `APPSLIST` close to and beyond the 20-second deadline, and click one launcher repeatedly. The APPSLIST protocol has no request ID, so verify behavior when an earlier reply arrives late.
- Test an app removed from the guest Dock but still installed, an app fully uninstalled, and a guest without PowerEmu Tools. The installed-app list, not only Dock membership, is the intended pre-launch check.
- Verify the launcher's Dock name and icon after cold start. The dormant-app generic icon limitation remains until the guest can return an icon by application path.
- Confirm normal Dock **Keep in Dock** survives helper quit and PowerEmu quit, then relaunches the correct guest app. Also test removing the pinned launcher and recreating it after a VM package move.
- Test same-named VMs at different package paths, duplicate app names at different guest paths, malformed sidecars, wrong sidecar owner/mode, symlinks, and old helper/version combinations.
