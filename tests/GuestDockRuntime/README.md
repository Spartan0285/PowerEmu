# Unified guest Dock regression

The distributed `GuestApplication.app` template and test host must be Developer-ID signed by PowerEmu's Team ID. Per-app native launchers are generated locally with their unique VM/app identifier, sealed ICNS artwork, and an ad-hoc signature. Owner-only receipts bind their source and generated CodeDirectory hashes. Neither the distributed template nor running generated apps are modified.

Compile `main.swift` with `GuestDock.swift`, `GuestAppLauncher.swift` and `GuestLauncherTrust.swift` into a small Developer-ID-signed test application. Pass the absolute template `Contents/MacOS/PowerEmuGuestApp` path. The fixture uses two unique temporary VM identities and only their own launcher directories under `~/Applications/PowerEmu Guest Apps`, then removes those directories.

Coverage: one representative per VM/app, multiple guest processes, stale action rejection, graceful Quit/Cancel, live icon updates without bundle rewrite/restart, duplicate coalescing, disconnect versus valid empty snapshots, durable targets across restart, and two-VM isolation. It verifies generated signatures/receipts and live process identity. `tests/GuestLauncherTrust/run.sh` covers source integrity and receipt/hash/permission failures. `app/Tests/Harmony/GuestDockOpen.swift` verifies native document routing.

These fixtures do not establish native Keep in Dock or drag/reorder behavior. Exercise those through macOS UI; retain the pinned URL across guest/VM/host shutdown, inspect its dormant icon, then click that exact pin to launch the correct Tiger VM/app in Harmony. Do not manufacture a passing pin by editing Dock preferences.
