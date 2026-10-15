import AppKit

/// Each guest app gets an unchanged signed executable in its own session/pid
/// directory. Runtime names and icons brand the Dock tile without invalidating
/// the helper's signature or requiring a signing identity on the user's Mac.
@MainActor
final class GuestDock {
    /// Bring a guest application to the front, or quit it.
    var activate: ((Int) -> Void)?
    var openFiles: (([URL], Int) -> Bool)?
    private let session = UUID().uuidString
    var quit: ((Int) -> Void)?
    /// Ask the guest for an application's icon.
    var wantIcon: ((Int) -> Void)?

    private struct Tile {
        let pid: Int
        let name: String
        let directory: URL
        /// The helper itself, when it was started directly.
        var child: Process?
        var hasIcon = false
        var launchFailed = false
    }
    private var tiles: [Int: Tile] = [:]
    /*
     * When each application was last reported.
     *
     * The list this is fed from is the guest's *windows*, not its running
     * applications: an application with nothing open does not appear in it.
     * Taking a tile down the moment its owner stops being mentioned therefore
     * killed the helper whenever the last window was minimized or closed, and
     * the keeper below started it again a few seconds later -- a Dock icon
     * that quit and came back, over and over, for as long as Harmony was on.
     *
     * So absence has to persist before it means anything.
     */
    private var lastSeen: [Int: Date] = [:]
    /// How long an application must go unmentioned before its tile goes.
    private static let graceBeforeRemoval: TimeInterval = 20
    /// When each tile was last asked to start, so a refusal is retried but a
    /// slow start is not trampled on.
    private var lastLaunch: [Int: Date] = [:]
    private var keeper: Timer?
    private var observers: [Any] = []
    private(set) var running = false

    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PowerEmu/GuestApps", isDirectory: true)

    private let storageRoot: URL
    private let suppliedHelper: URL?
    init(storageRoot: URL? = nil, helperBinary: URL? = nil) {
        self.storageRoot = storageRoot ?? Self.root
        self.suppliedHelper = helperBinary
    }
    private var helper: URL? { suppliedHelper ?? Self.helperBinary }
    private var sessionRoot: URL { storageRoot.appendingPathComponent(session, isDirectory: true) }

    /// The helper that holds a tile, inside PowerEmu's own bundle.
    private static var helperBinary: URL? {
        // Contents/Helpers, which is not where Bundle looks for a resource.
        let u = Bundle.main.bundleURL
            .appendingPathComponent("Contents/Helpers/PowerEmuGuestApp")
        return FileManager.default.isExecutableFile(atPath: u.path) ? u : nil
    }

    // MARK: coming and going

    func start() {
        guard !running else { return }
        running = true
        reapStrays()
        do {
            try FileManager.default.createDirectory(at: sessionRoot, withIntermediateDirectories: true)
            try Data(String(ProcessInfo.processInfo.processIdentifier).utf8)
                .write(to: sessionRoot.appendingPathComponent("owner-pid"), options: .atomic)
        } catch {
            running = false
            harmonyDebug("PEDOCK could not create session storage: \(error.localizedDescription)")
            return
        }
        // Observe exits without repeatedly launching an app macOS rejected.
        keeper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
        observeFileDrops()
        let c = DistributedNotificationCenter.default()
        observers.append(c.addObserver(forName: .init("com.spartan0285.poweremu.guestapp.clicked"),
                                       object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard n.userInfo?["session"] as? String == self?.session, let pid = Int((n.userInfo?["pid"] as? String) ?? "") else { return }
                self?.activate?(pid)
            }
        })
        observers.append(c.addObserver(forName: .init("com.spartan0285.poweremu.guestapp.quit"),
                                       object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard n.userInfo?["session"] as? String == self?.session, let pid = Int((n.userInfo?["pid"] as? String) ?? "") else { return }
                self?.quit?(pid)
            }
        })
    }

    private func observeFileDrops() {
        observers.append(DistributedNotificationCenter.default().addObserver(forName: .init("com.spartan0285.poweremu.guestapp.open"), object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated {
                guard let self, n.userInfo?["session"] as? String == self.session,
                      let value = n.userInfo?["pid"] as? String, let pid = Int(value), self.tiles[pid] != nil,
                      let paths = n.userInfo?["paths"] as? [String] else { return }
                _ = self.openFiles?(paths.map { URL(fileURLWithPath: $0) }, pid)
            }
        })
    }

    /*
     * Tiles left over from a PowerEmu that is no longer here.
     *
     * A tile is held by a small application of its own, and it is only taken
     * down when Harmony is switched off tidily.  If PowerEmu goes without
     * doing that -- it crashed, it was force quit, it was killed while being
     * worked on -- every one of those helpers carries on running, and its
     * icon sits in the Dock for a guest application that stopped existing with
     * the virtual Mac it belonged to.  The next run adds its own on top, so
     * they pile up.  Nothing else can tidy them: they are ordinary
     * applications as far as this Mac is concerned.
     *
     * So each run clears out whatever the last one left behind.  Only helpers
     * are touched -- applications living inside PowerEmu's own cache folder,
     * which nothing else has any reason to put there.
     */
    private func reapStrays() {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: storageRoot, includingPropertiesForKeys: nil)) ?? []
        for entry in entries {
            let marker = entry.appendingPathComponent("owner-pid")
            if let data = try? Data(contentsOf: marker),
               let text = String(data: data, encoding: .utf8), let owner = Int32(text), owner > 0 {
                // Other running VMs own their own representatives. Never reap
                // them or their files when another Harmony session starts.
                if Darwin.kill(owner, 0) == 0 || errno != ESRCH { continue }
            } else if entry.pathExtension != "app" {
                continue // Unknown cache contents are not ours to remove.
            }
            for app in NSWorkspace.shared.runningApplications {
                let path = app.executableURL?.standardizedFileURL.path ?? app.bundleURL?.standardizedFileURL.path ?? ""
                if path.hasPrefix(entry.standardizedFileURL.path + "/") { app.forceTerminate() }
            }
            try? fm.removeItem(at: entry)
        }
    }

    func stop() {
        running = false
        keeper?.invalidate(); keeper = nil
        for o in observers { DistributedNotificationCenter.default().removeObserver(o) }
        observers = []
        for (pid, _) in tiles { remove(pid) }
        tiles = [:]
        try? FileManager.default.removeItem(at: sessionRoot)
    }

    /// The guest's running applications, as the tools report them.
    func setApps(_ apps: [(pid: Int, name: String)]) {
        guard running else { return }
        guard helper != nil else {
            harmonyDebug("PEDOCK no helper binary in the bundle")
            return
        }
        harmonyDebug("PEDOCK apps=\(apps.map { $0.name }.joined(separator: ",")) tiles=\(tiles.count)")
        let live = Set(apps.map { $0.pid })
        let now = Date()
        for pid in live { lastSeen[pid] = now }
        /*
         * An empty report says the guest has no windows open, which is a
         * normal thing for it to say and never a reason to tear every tile
         * down.  Anything else only retires a tile once it has been missing
         * for long enough that the application really has gone.
         */
        if !apps.isEmpty {
            for pid in tiles.keys where !live.contains(pid) {
                guard let seen = lastSeen[pid] else { lastSeen[pid] = now; continue }
                if now.timeIntervalSince(seen) >= Self.graceBeforeRemoval {
                    remove(pid)
                }
            }
        }
        for a in apps where tiles[a.pid] == nil {
            // PowerEmu itself is already in the Dock, and the guest's own
            // helpers have no windows to come back to.
            guard !a.name.hasPrefix("PowerEmu") else { continue }
            add(pid: a.pid, name: a.name)
        }
    }

    /*
     * The guest's actual process list, which is a stronger statement than the
     * window report above.
     *
     * setApps() is fed from the guest's *windows*, so it cannot tell an
     * application that quit from one that merely closed its last window, and
     * has to wait out graceBeforeRemoval before believing either.  DOCKAPPS is
     * built from the running processes themselves, so a tile missing from it
     * has genuinely gone and the icon can come off the Dock at once rather
     * than lingering for twenty seconds after the application quit.
     *
     * An empty report is ignored, the same as above: it is what arrives before
     * the first real one, and it is never a reason to tear every tile down.
     */
    func setRunningApplications(_ pids: Set<Int>) {
        guard running, !pids.isEmpty else { return }
        for pid in tiles.keys where !pids.contains(pid) {
            harmonyDebug("PEDOCK \(pid) is no longer running in the guest; removing its tile")
            remove(pid)
        }
    }

    /// The icon came back from the guest.
    func setIcon(pid: Int, png: Data) {
        harmonyDebug("PEDOCK icon for \(pid): \(png.count) bytes")
        guard var t = tiles[pid], !t.hasIcon else { return }
        guard let image = NSImage(data: png), image.isValid else { return }
        do { try png.write(to: t.directory.appendingPathComponent("icon.png"), options: .atomic) }
        catch { harmonyDebug("PEDOCK icon write failed: \(error.localizedDescription)"); return }
        t.hasIcon = true
        tiles[pid] = t
        // Only data changes. The Developer ID–signed executable stays intact.

        launch(pid)
    }

    /// Add a durable Dock-capable copy of the trusted helper. The executable
    /// remains byte-for-byte identical; its adjacent launcher plist and icon
    /// are ordinary user data, never part of a signed bundle.
    func installPersistentLauncher(vmPackageURL: URL, appPath: String, name: String,
                                   runningGuestPID: Int) throws -> URL {
        guard (Bundle.main.object(forInfoDictionaryKey: "PEGuestLauncherVersion") as? NSNumber)?.intValue == 1 else {
            throw GuestAppLaunchRequest.InstallError.unsupportedHelper
        }
        guard let helper else { throw GuestAppLaunchRequest.InstallError.missingHelper }
        let request = try GuestAppLaunchRequest(vmPackageURL: vmPackageURL,
                                               guestApplicationPath: appPath)
        let iconURL = tiles[runningGuestPID]?.directory.appendingPathComponent("icon.png")
        let iconData = iconURL.flatMap { try? Data(contentsOf: $0) }
        let executable = try request.install(helperBinary: helper, displayName: name, iconData: iconData)
        let process = Process()
        process.executableURL = executable
        var environment = ProcessInfo.processInfo.environment
        for key in ["PE_DOCK_GUEST_PID", "PE_DOCK_SESSION", "PE_DOCK_NAME", "PE_DOCK_ICON",
                    "PEGuestPID", "PESession"] { environment.removeValue(forKey: key) }
        environment["PE_DOCK_INSTALL_ONLY"] = "1"
        process.environment = environment
        try process.run()
        return executable
    }

    /// Every tile that has an icon should have a helper holding it.
    private func ensureRunning() {
        guard running else { return }
        harmonyDebug("PEDOCK keep: " + tiles.map {
            "\($0.value.name)[icon=\($0.value.hasIcon ? 1 : 0),run=\($0.value.child?.isRunning == true ? 1 : 0)]"
        }.joined(separator: " "))
        for (pid, t) in tiles where t.hasIcon && !t.launchFailed {
            if let child = t.child, !child.isRunning, child.terminationStatus != 0 {
                var failed = t; failed.launchFailed = true; tiles[pid] = failed
                harmonyDebug("PEDOCK \(t.name) exited with status \(child.terminationStatus); automatic relaunch disabled")
                continue
            }
            if (t.child?.isRunning ?? false) { continue }
            launch(pid)
        }
    }

    // MARK: building one

    private func add(pid: Int, name: String) {
        guard let helper = helper else { return }
        let directory = sessionRoot.appendingPathComponent(String(pid), isDirectory: true)
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let executableName = safe.isEmpty || safe == "." || safe == ".." ? "Guest Application" : safe
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // This is a standalone executable, never a mutable .app bundle.
            // Keep its original signature, including Developer ID and runtime
            // protections. Names/icons/session routing are runtime data.
            try FileManager.default.copyItem(at: helper, to: directory.appendingPathComponent(executableName))
        } catch {
            harmonyDebug("PEDOCK could not prepare \(name): \(error.localizedDescription)")
            return
        }
        tiles[pid] = Tile(pid: pid, name: name, directory: directory)
        harmonyDebug("PEDOCK built trusted representative \(name) at \(directory.path)")
        wantIcon?(pid)
    }

    private func launch(_ pid: Int) {
        guard let t = tiles[pid], !t.launchFailed else { return }
        if let when = lastLaunch[pid], Date().timeIntervalSince(when) < 3 { return }
        lastLaunch[pid] = Date()
        let p = Process()
        let safe = t.name.replacingOccurrences(of: "/", with: "-")
        let executableName = safe.isEmpty || safe == "." || safe == ".." ? "Guest Application" : safe
        p.executableURL = t.directory.appendingPathComponent(executableName)
        p.environment = ProcessInfo.processInfo.environment.merging([
            "PE_DOCK_GUEST_PID": String(pid), "PE_DOCK_SESSION": session,
            "PE_DOCK_NAME": t.name, "PE_DOCK_ICON": t.directory.appendingPathComponent("icon.png").path
        ]) { _, new in new }
        do { try p.run() }
        catch {
            var failed = t; failed.launchFailed = true; tiles[pid] = failed
            harmonyDebug("PEDOCK \(t.name) would not start; automatic relaunch disabled: \(error.localizedDescription)")
            return
        }
        var have = t; have.child = p; tiles[pid] = have
    }

    private func remove(_ pid: Int) {
        guard let t = tiles[pid] else { return }
        // This tears down only our representative after the guest exits (or
        // Harmony ends); asking it to Quit would send another guest request.
        t.child?.terminate()
        try? FileManager.default.removeItem(at: t.directory)
        tiles[pid] = nil
        lastLaunch[pid] = nil
        lastSeen[pid] = nil
    }

}
