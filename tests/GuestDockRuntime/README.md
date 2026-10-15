# Guest Dock runtime regression

Compile helper/main.swift with the same linker flags as scripts/build-app.sh and sign it with the existing development Developer ID. Compile exit.c as a separate executable and sign it with that identity. This avoids deliberately copying and launching a platform-restricted system executable.

Compile main.swift alongside app/Sources/PowerEmu/GuestDock.swift and pass both trusted executable paths. The test launches only its own temporary Dock representatives, using injected storage/helper paths; it does not touch the user's GuestApps cache or VM. It takes about eleven seconds and verifies unchanged code/signatures, runtime names, icon data, concurrent session isolation, cleanup and failure suppression.
