import AppKit

/*
 * The guest's applications in this Mac's Dock.
 *
 * This Mac gives one Dock tile to one running process, so a guest application
 * cannot have a tile of its own unless something of its own is running here to
 * hold it.  Each one therefore gets a small application built for it on the
 * spot -- its name, its icon, and nothing else -- which does no more than sit
 * in the Dock and say when it has been clicked.  Clicking it brings the real
 * application forward in the guest; quitting it quits the real one.
 *
 * The bundles are built in this Mac's caches, keyed by the application's name,
 * and the executable inside each is the same small helper copied from
 * PowerEmu's own bundle.  They are torn down when the guest application quits
 * and when Harmony is switched off.
 */
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
        var bundle: URL
        var process: NSRunningApplication?
        /// The helper itself, when it was started directly.
        var child: Process?
        var hasIcon = false
    }
    private var tiles: [Int: Tile] = [:]
    /// When each tile was last asked to start, so a refusal is retried but a
    /// slow start is not trampled on.
    private var lastLaunch: [Int: Date] = [:]
    private var keeper: Timer?
    private var observers: [Any] = []
    private(set) var running = false

    private static let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("PowerEmu/GuestApps", isDirectory: true)

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
        observeFileDrops()
        reapStrays()
        /*
         * Keep the tiles standing.  Starting one is not reliably a single
         * event -- LaunchServices refuses a bundle it has only just been
         * handed while it is busy with the last one -- and the guest's list of
         * applications does not arrive often enough to lean on for retries.
         */
        keeper = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.ensureRunning() }
        }
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
        let root = Self.root.standardizedFileURL.path
        var found = 0
        for app in NSWorkspace.shared.runningApplications {
            guard let u = app.bundleURL?.standardizedFileURL.path,
                  u.hasPrefix(root + "/") else { continue }
            app.forceTerminate()
            found += 1
        }
        if found > 0 { harmonyDebug("PEDOCK reaped \(found) tile(s) from a previous run") }
        // Their bundles are named after guest process ids, which mean nothing
        // once that virtual Mac has restarted.
        try? FileManager.default.removeItem(at: Self.root)
    }

    func stop() {
        running = false
        keeper?.invalidate(); keeper = nil
        for o in observers { DistributedNotificationCenter.default().removeObserver(o) }
        observers = []
        for (pid, _) in tiles { remove(pid) }
        tiles = [:]
    }

    /// The guest's running applications, as the tools report them.
    func setApps(_ apps: [(pid: Int, name: String)]) {
        guard running else { return }
        guard Self.helperBinary != nil else {
            harmonyDebug("PEDOCK no helper binary in the bundle")
            return
        }
        harmonyDebug("PEDOCK apps=\(apps.map { $0.name }.joined(separator: ",")) tiles=\(tiles.count)")
        let live = Set(apps.map { $0.pid })
        for pid in tiles.keys where !live.contains(pid) { remove(pid) }
        for a in apps where tiles[a.pid] == nil {
            // PowerEmu itself is already in the Dock, and the guest's own
            // helpers have no windows to come back to.
            guard !a.name.hasPrefix("PowerEmu") else { continue }
            add(pid: a.pid, name: a.name)
        }
    }

    /// The icon came back from the guest.
    func setIcon(pid: Int, png: Data) {
        harmonyDebug("PEDOCK icon for \(pid): \(png.count) bytes")
        guard var t = tiles[pid], !t.hasIcon else { return }
        let icons = t.bundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try? FileManager.default.createDirectory(at: icons, withIntermediateDirectories: true)
        guard let img = NSImage(data: png), let icns = Self.icns(from: img) else { return }
        try? icns.write(to: icons.appendingPathComponent("app.icns"))
        t.hasIcon = true
        tiles[pid] = t
        // The Dock reads the icon when the application starts, so it is only
        // launched once the icon is there to read.
        launch(pid)
    }

    /// Every tile that has an icon should have a helper holding it.
    private func ensureRunning() {
        guard running else { return }
        harmonyDebug("PEDOCK keep: " + tiles.map {
            "\($0.value.name)[icon=\($0.value.hasIcon ? 1 : 0),run=\($0.value.child?.isRunning == true ? 1 : 0)]"
        }.joined(separator: " "))
        for (pid, t) in tiles where t.hasIcon {
            if (t.child?.isRunning ?? false) { continue }
            if t.process == nil || t.process?.isTerminated == true {
                var again = t
                again.process = nil
                tiles[pid] = again
                launch(pid)
            }
        }
    }

    // MARK: building one

    private func add(pid: Int, name: String) {
        let safe = name.replacingOccurrences(of: "/", with: "-")
        let bundle = Self.root.appendingPathComponent("\(safe).app", isDirectory: true)
        guard let helper = Self.helperBinary else { return }
        let macos = bundle.appendingPathComponent("Contents/MacOS", isDirectory: true)
        let fm = FileManager.default
        try? fm.createDirectory(at: macos, withIntermediateDirectories: true)
        /*
         * The executable is named after the application it stands for.  With
         * every bundle carrying an identically named unsigned binary, this Mac
         * took the second one for the first already running: it reported no
         * error, started nothing, and only one application ever got a tile.
         */
        let exeName = "PowerEmuGuestApp-\(safe)"
        let exe = macos.appendingPathComponent(exeName)
        if !fm.fileExists(atPath: exe.path) {
            try? fm.copyItem(at: helper, to: exe)
        }
        let plist: [String: Any] = [
            "CFBundleExecutable": exeName,
            "CFBundleIdentifier": "com.spartan0285.poweremu.guestapp.\(abs(safe.hashValue))",
            "CFBundleName": name,
            "CFBundleDisplayName": name,
            "CFBundlePackageType": "APPL",
            "CFBundleIconFile": "app",
            "CFBundleShortVersionString": "1.0",
            "LSMinimumSystemVersion": "12.0",
            // The pid is how the helper says which guest application it stands for.
            "PEGuestPID": String(pid),
            "PESession": session,
            "CFBundleDocumentTypes": [["CFBundleTypeName": "Files", "CFBundleTypeRole": "Viewer", "LSItemContentTypes": ["public.item"], "CFBundleTypeExtensions": ["*"]]],
        ]
        if let data = try? PropertyListSerialization.data(fromPropertyList: plist,
                                                          format: .xml, options: 0) {
            try? data.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        }
        tiles[pid] = Tile(pid: pid, name: name, bundle: bundle)
        harmonyDebug("PEDOCK built \(name) at \(bundle.path)")
        wantIcon?(pid)          // launched once its icon has arrived
    }

    private func launch(_ pid: Int) {
        guard let t = tiles[pid], t.process == nil else { return }
        if let when = lastLaunch[pid], Date().timeIntervalSince(when) < 3 { return }
        lastLaunch[pid] = Date()
        harmonyDebug("PEDOCK starting \(t.name)")
        /*
         * Run the helper itself rather than asking this Mac to open the bundle.
         *
         * Asking it to open them started the first and quietly did nothing for
         * the rest -- no error, nothing running -- however distinct their
         * identifiers and executables were made; it had decided they were all
         * the same application.  A binary inside a bundle still takes its name
         * and icon from that bundle when it runs, so it gets its Dock tile
         * either way, and starting it directly leaves no room for that
         * argument.
         */
        let exe = t.bundle.appendingPathComponent("Contents/MacOS")
            .appendingPathComponent(t.bundle.deletingPathExtension().lastPathComponent
                                    .replacingOccurrences(of: " ", with: " "))
        let real = (try? FileManager.default.contentsOfDirectory(
            at: t.bundle.appendingPathComponent("Contents/MacOS"),
            includingPropertiesForKeys: nil).first) ?? exe
        let p = Process()
        p.executableURL = real
        do {
            try p.run()
        } catch {
            harmonyDebug("PEDOCK \(t.name) would not start: \(error.localizedDescription)")
            return
        }
        var have = t
        have.child = p
        tiles[pid] = have
    }

    private func remove(_ pid: Int) {
        guard let t = tiles[pid] else { return }
        // This tears down only our representative after the guest exits (or
        // Harmony ends); asking it to Quit would send another guest request.
        t.process?.forceTerminate()
        t.child?.terminate()
        tiles[pid] = nil
        lastLaunch[pid] = nil
    }

    /// An .icns holding the one size the Dock needs.
    private static func icns(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        var out = Data("icns".utf8)
        var body = Data("ic07".utf8)            // 128x128 PNG
        var len = UInt32(png.count + 8).bigEndian
        withUnsafeBytes(of: &len) { body.append(contentsOf: $0) }
        body.append(png)
        var total = UInt32(body.count + 8).bigEndian
        withUnsafeBytes(of: &total) { out.append(contentsOf: $0) }
        out.append(body)
        return out
    }
}
