# Guest Dock representatives: trusted executable fix

## Confirmed failure

The user saw macOS “Word is damaged and can’t be opened.” This refers to the host representative, not guest Word. macOS amfid records for Finder, System Preferences, The Garden, Microsoft AutoUpdate and Word report error -423: “The file is adhoc signed or signed by an unknown certificate chain.” syspolicyd also recorded the Word denial prompt.

The old generator copied a Developer ID–signed helper into a newly branded .app and then ad-hoc re-signed it. Although the result passed structural codesign verification, it discarded the trusted certificate chain. Simply retaining the old signature inside the generated .app also fails strict verification: “code has no resources but signature indicates they must be present.” Do not restore either design or remove quarantine/provenance/security protections as a workaround.

## Implementation

- GuestDock copies the signed standalone helper **byte for byte** into a session/guest-PID directory, outside a mutable .app bundle. It never invokes runtime codesign or rewrites signed metadata.
- Guest PID, session, display name and icon path are supplied as environment data. The helper preserves notification routing, guest quit cancellation and file-open forwarding. Legacy Info.plist fallback remains for old callers.
- AppKit sets the running application icon. An optional, dynamically resolved LaunchServices display-name setter supplies the process name; executable names also reflect guest names. The private naming SPI is a compatibility risk, not part of the trust fix. Reference implementation/provenance: [Chromium mac_util.mm](https://chromium.googlesource.com/chromium/chromium/+/refs/heads/main/base/mac/mac_util.mm).
- File document-type declarations are embedded in the helper’s Mach-O during compilation, then covered by its build-time signature. The build script includes helper/Info.plist with the linker’s __TEXT/__info_plist section.
- Session ownership markers protect other live VMs from cache reaping; per-PID directories avoid same-name executable collisions. Old generated .app representatives are retired when the new Dock manager starts.
- Failed process launches or nonzero helper exits are marked failed until a new representative/session is created. The three-second keeper cannot repeatedly trigger an error dialog.

## Validation

Production release build passes. New signed test app passes codesign --verify --deep --strict. Helper retains Developer ID team 7B2D3VV69V and hardened runtime.

Actual GuestDock runtime fixture tests two simultaneous sessions using the same guest PID, distinct process names, intact icon data, byte-identical executable copies and successful strict verification. Stopping one leaves the other alive; stopping both clears their helpers. A separate trusted fixture exiting with status 1 produces exactly one failure diagnostic and no repeated launch. All pass. The NSRunningApplication.icon getter reflects a cached disk icon, so it was not used as proof of the running Dock artwork; visual artwork and Dock drop acceptance still require integration testing.

Run the fixture with a Developer ID–signed helper and a trusted signed executable compiled from tests/GuestDockRuntime/exit.c:

```sh
xcrun swiftc tests/GuestDockRuntime/main.swift app/Sources/PowerEmu/GuestDock.swift -o /tmp/guest-dock-runtime-test
/tmp/guest-dock-runtime-test /absolute/path/to/PowerEmuGuestApp /absolute/path/to/exit-fixture
```

The signed PowerEmu Harmony Test.app was updated after confirming the user VM was stopped and quitting the frontend. It was reopened; its configured test VM starts normally. Previous bundle retained under build/staging-dock/Previous Harmony Test.app. No commit or release.

Remaining user verification: enter Harmony; open Word/System Preferences and other guest apps; confirm no damaged-app alerts, separate names/icons, activation, Quit routing and Dock file drops. No claim of a complete live Word/Dock interaction pass from the isolated runtime fixture alone.

Live integration after replacement: entered Harmony successfully and started the new Finder representative from its session/179/Finder path. It remains running, passes strict signature verification, and retains Developer ID team 7B2D3VV69V plus hardened runtime. No amfid/syspolicyd error records for that fresh session were returned by the targeted check. The test VM is left running in Harmony for the user; no automated stop guard was installed on this user-verification run.
