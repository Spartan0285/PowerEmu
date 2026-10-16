import AppKit

/// One durable launcher identity per VM/application. Running presence comes
/// only from complete guest process reports; pinning and ordering belong to
/// macOS. A document closing never changes the application's identity.
@MainActor
final class GuestDock {
    var activate: ((Int) -> Void)?
    var quit: ((Int) -> Void)?
    var openFiles: (([URL], Int) -> Bool)?
    var refreshApplications: (() -> Void)?
    var launchApplication: ((String) -> Void)?
    var wantIcon: ((Int) -> Void)?
    var wantApplicationPathIcon: ((String) -> Void)?

    private struct Application {
        let request: GuestAppLaunchRequest
        let executable: URL
        let application: URL
        var receipt: GuestLauncherTrust.Receipt
        var iconWaitUntil: Date?
        var pids = Set<Int>()
        var launchToken: UUID?
        var suppressed = false
        var quitRequested = false
        var iconRequested = false
    }
    private var applications: [String: Application] = [:]
    private var installedPaths = Set<String>()
    private var knownProcesses: [(path: String, name: String, pid: Int)] = []
    private var snapshotKnown = false
    private var vmPackageURL: URL?
    private let session = UUID().uuidString
    private let root: URL
    private let suppliedHelper: URL?
    private let hostApplicationURL: URL
    private let hostBundleIdentifier: String
    private var observers: [Any] = []
    private var workspaceObserver: Any?
    private var poll: Timer?
    private(set) var running = false

    init(storageRoot: URL? = nil, helperBinary: URL? = nil,
         hostApplicationURL: URL? = nil, hostBundleIdentifier: String? = nil) {
        root = storageRoot ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
        suppliedHelper = helperBinary
        self.hostApplicationURL = hostApplicationURL ?? Bundle.main.bundleURL
        self.hostBundleIdentifier = hostBundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
    }
    private var helper: URL? {
        suppliedHelper ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/GuestApplication.app/Contents/MacOS/PowerEmuGuestApp")
    }

    func configure(vmPackageURL: URL) {
        let canonical = vmPackageURL.standardizedFileURL.resolvingSymlinksInPath()
        if let previous = self.vmPackageURL, previous != canonical { stop(); applications.removeAll() }
        self.vmPackageURL = canonical
        migrateExistingLaunchers()
    }

    /// Upgrade only our existing durable targets, preserving their URLs.
    /// Former session-cache icons are not copied into the new model.
    private func migrateExistingLaunchers() {
        guard let package = vmPackageURL,
              let directories = try? FileManager.default.contentsOfDirectory(at: root,
                  includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
        for directory in directories.prefix(4096) {
            let config = directory.appendingPathComponent("launcher.plist")
            guard directory.lastPathComponent.count == 32,
                  directory.resolvingSymlinksInPath().path == directory.path,
                  let attrs = try? FileManager.default.attributesOfItem(atPath: config.path),
                  attrs[.type] as? FileAttributeType == .typeRegular,
                  (attrs[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
                  (attrs[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024,
                  let data = try? Data(contentsOf: config),
                  let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
                  values["VMPackagePath"] as? String == package.path,
                  let path = values["GuestApplicationPath"] as? String,
                  let name = values["DisplayName"] as? String,
                  let request = try? GuestAppLaunchRequest(vmPackageURL: package, guestApplicationPath: path),
                  request.stableIdentifier == directory.lastPathComponent else { continue }
            do { _ = try prepareApplication(path: path, name: name) }
            catch { harmonyDebug("PEDOCK existing launcher upgrade deferred: \(error.localizedDescription)") }
        }
    }

    func start() {
        guard !running, vmPackageURL != nil else { return }
        running = true
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(forName: .init("com.spartan0285.poweremu.guestapp.action"),
                                            object: nil, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.receive(note) }
        })
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, let process = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                          let executable = process.executableURL?.standardizedFileURL.resolvingSymlinksInPath() else { return }
                    for path in Array(self.applications.keys) where self.applications[path]?.executable == executable {
                        // Never restart a killed representative repeatedly. A
                        // new guest process or explicit launcher click can retry.
                        if self.applications[path]?.launchToken != nil { continue }
                        if NSWorkspace.shared.runningApplications.contains(where: {
                            !$0.isTerminated && $0.processIdentifier != process.processIdentifier &&
                            $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == executable
                        }) { continue }
                        self.applications[path]?.launchToken = nil
                        self.applications[path]?.suppressed = true
                        try? self.refreshClosedArtwork(path)
                    }
                }
            }
        let timer = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshApplications?() }
        }
        poll = timer
        RunLoop.main.add(timer, forMode: .common)
        refreshApplications?()
    }

    func stop() {
        guard running else { return }
        running = false
        poll?.invalidate(); poll = nil
        for path in Array(applications.keys) { publish(path, state: "stopped") }
        for observer in observers { DistributedNotificationCenter.default().removeObserver(observer) }
        observers.removeAll()
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        workspaceObserver = nil
        for path in Array(applications.keys) {
            applications[path]?.launchToken = nil
            applications[path]?.pids = []
        }
        knownProcesses = []; snapshotKnown = false
        // Launchers and artwork remain at their stable URLs for native pins.
    }

    func guestToolsDisconnected() {
        snapshotKnown = false
        for path in applications.keys { publish(path, state: "unknown") }
    }

    func guestToolsReconnected() {
        installedPaths.removeAll()
        snapshotKnown = false
        for path in applications.keys { applications[path]?.iconRequested = false }
        if !running { start() }
        for path in applications.keys { publish(path, state: "unknown") }
        refreshApplications?()
    }

    func setInstalledApplicationPaths(_ paths: Set<String>) {
        installedPaths = paths
        for path in applications.keys { requestIcon(path) }
    }

    /// Called only for a fully parsed DOCKAPPS snapshot, including valid empty
    /// snapshots. Lost or malformed reports must never call this method.
    func setRunningGuestApps(_ apps: [(path: String, name: String, pid: Int)]) {
        guard vmPackageURL != nil else { return }
        if !running { start() }
        snapshotKnown = true
        knownProcesses = apps
        let live = Dictionary(grouping: apps.filter { $0.pid > 0 && !$0.name.hasPrefix("PowerEmu") }, by: \.path)
        for (path, values) in live {
            do { _ = try prepareApplication(path: path, name: values[0].name) }
            catch { harmonyDebug("PEDOCK launcher unavailable: \(error.localizedDescription)"); continue }
            guard var app = applications[path] else { continue }
            let pids = Set(values.map(\.pid))
            if pids != app.pids { app.suppressed = false; app.quitRequested = false }
            app.pids = pids
            applications[path] = app
            publish(path, state: "running")
            requestIcon(path)
            ensureRepresentative(path)
        }
        for path in Array(applications.keys) where live[path] == nil && !applications[path]!.pids.isEmpty {
            publish(path, state: "stopped")
            applications[path]?.pids = []
            applications[path]?.launchToken = nil
            applications[path]?.quitRequested = false
            applications[path]?.suppressed = false
        }
    }

    /// Browsing a closed app can reveal its durable launcher without starting
    /// a representative or opening the app. Native Keep in Dock is the pin UI.
    @discardableResult
    func prepareApplication(path: String, name: String) throws -> URL {
        if let app = applications[path] { return app.application }
        guard suppliedHelper != nil || (Bundle.main.object(forInfoDictionaryKey: "PEGuestLauncherVersion") as? NSNumber)?.intValue == 3 else {
            throw GuestAppLaunchRequest.InstallError.unsupportedHelper
        }
        guard let vmPackageURL, let helper else { throw GuestAppLaunchRequest.InstallError.missingHelper }
        let request = try GuestAppLaunchRequest(vmPackageURL: vmPackageURL, guestApplicationPath: path)
        let application = try request.install(helperBinary: helper, displayName: name,
            applicationsDirectory: root, hostApplicationURL: hostApplicationURL,
            hostBundleIdentifier: hostBundleIdentifier).standardizedFileURL.resolvingSymlinksInPath()
        guard let executable = Bundle(url: application)?.executableURL else { throw GuestAppLaunchRequest.InstallError.missingHelper }
        let template = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceCDHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: hostApplicationURL)
        let receipt = try GuestLauncherTrust.loadReceipt(from: application.deletingLastPathComponent(), applicationURL: application,
            stableIdentifier: request.stableIdentifier, sourceCDHash: sourceCDHash)
        applications[path] = Application(request: request, executable: executable, application: application, receipt: receipt)
        requestIcon(path)
        return application
    }

    func setApplicationPathIcon(path: String, png: Data) {
        guard let app = applications[path], Self.validIcon(png) else { return }
        let icon = app.application.deletingLastPathComponent().appendingPathComponent("icon.png")
        do {
            if (try? Data(contentsOf: icon)) == png { return }
            try png.write(to: icon, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: icon.path)
            if !representativeIsPresent(app) { try refreshClosedArtwork(path) }
            if running, !app.pids.isEmpty {
                publish(path, state: snapshotKnown ? "running" : "unknown")
                ensureRepresentative(path)
            }
        } catch { harmonyDebug("PEDOCK icon update failed: \(error.localizedDescription)") }
    }

    func setIcon(pid: Int, png: Data) {
        guard let path = knownProcesses.first(where: { $0.pid == pid })?.path else { return }
        setApplicationPathIcon(path: path, png: png)
    }

    private func representativeIsPresent(_ app: Application) -> Bool {
        NSWorkspace.shared.runningApplications.contains {
            !$0.isTerminated && $0.executableURL?.standardizedFileURL.resolvingSymlinksInPath() == app.executable
        }
    }

    private func refreshClosedArtwork(_ path: String) throws {
        guard var app = applications[path], !representativeIsPresent(app), let helper else { return }
        _ = try app.request.install(helperBinary: helper, displayName: Bundle(url: app.application)?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? app.application.deletingPathExtension().lastPathComponent,
            applicationsDirectory: root, hostApplicationURL: hostApplicationURL, hostBundleIdentifier: hostBundleIdentifier)
        let template = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceCDHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: hostApplicationURL)
        app.receipt = try GuestLauncherTrust.loadReceipt(from: app.application.deletingLastPathComponent(), applicationURL: app.application,
            stableIdentifier: app.request.stableIdentifier, sourceCDHash: sourceCDHash)
        applications[path] = app
    }

    private func requestIcon(_ path: String) {
        guard running, var app = applications[path], !app.iconRequested else { return }
        if installedPaths.contains(path) {
            app.iconRequested = true; applications[path] = app
            wantApplicationPathIcon?(path)
        } else if let pid = app.pids.sorted().first {
            app.iconRequested = true; applications[path] = app
            wantIcon?(pid)
        }
    }

    private func publish(_ path: String, state: String) {
        guard let app = applications[path] else { return }
        let directory = app.application.deletingLastPathComponent()
        let runtime = directory.appendingPathComponent("runtime.plist")
        // Do not steal another live frontend's ownership of the same VM/app.
        if let data = try? Data(contentsOf: runtime),
           let prior = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
           let owner = prior["OwnerPID"] as? Int, owner > 0, owner <= Int(Int32.max), owner != Int(getpid()),
           prior["VMPackagePath"] as? String == app.request.vmPackagePath,
           prior["GuestApplicationPath"] as? String == path,
           Darwin.kill(pid_t(owner), 0) == 0,
           NSRunningApplication(processIdentifier: pid_t(owner))?.bundleIdentifier == hostBundleIdentifier { return }
        let values: [String: Any] = ["Version": 1, "StableIdentifier": app.request.stableIdentifier,
            "VMPackagePath": app.request.vmPackagePath, "GuestApplicationPath": path,
            "OwnerPID": Int(getpid()), "Session": session, "State": state,
            "ProcessIDs": app.pids.sorted()]
        do {
            let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
            if (try? Data(contentsOf: runtime)) != data {
                try data.write(to: runtime, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtime.path)
            }
            DistributedNotificationCenter.default().postNotificationName(
                .init("com.spartan0285.poweremu.guestapp.state"), object: app.request.stableIdentifier,
                userInfo: ["session": session, "owner": String(getpid()),
                           "vm": app.request.vmPackagePath, "app": path, "state": state], deliverImmediately: true)
        } catch { harmonyDebug("PEDOCK state publication failed: \(error.localizedDescription)") }
    }

    private func ensureRepresentative(_ path: String) {
        guard var app = applications[path], !app.suppressed, !app.pids.isEmpty else { return }
        let runtimeURL = app.application.deletingLastPathComponent().appendingPathComponent("runtime.plist")
        guard let data = try? Data(contentsOf: runtimeURL),
              let state = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              state["OwnerPID"] as? Int == Int(getpid()), state["Session"] as? String == session else { return }
        if !FileManager.default.fileExists(atPath: app.application.deletingLastPathComponent().appendingPathComponent("icon.png").path) {
            if app.iconWaitUntil == nil {
                app.iconWaitUntil = Date().addingTimeInterval(2)
                applications[path] = app
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    guard let self, self.running else { return }
                    self.ensureRepresentative(path)
                }
                return
            }
            if let until = app.iconWaitUntil, until > Date() { return }
        }
        guard app.launchToken == nil else { return }
        if NSWorkspace.shared.runningApplications.contains(where: {
            !$0.isTerminated && GuestLauncherTrust.validates(process: $0, receipt: app.receipt)
        }) { return } // Adopt the same icon that cold-launched PowerEmu.
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("PE_DOCK_") { environment.removeValue(forKey: key) }
        environment["PE_DOCK_RUNTIME"] = "1"
        configuration.environment = environment
        let token = UUID()
        app.launchToken = token
        applications[path] = app
        // LaunchServices must register the actual application URL. Launching
        // just its executable can make later Dock/document opens start a
        // second process instead of delivering the event to this one.
        NSWorkspace.shared.openApplication(at: app.application, configuration: configuration) { [weak self] process, error in
            Task { @MainActor in
                guard let self, self.applications[path]?.launchToken == token else { return }
                self.applications[path]?.launchToken = nil
                if let error {
                    self.applications[path]?.suppressed = true
                    harmonyDebug("PEDOCK representative could not start: \(error.localizedDescription)")
                } else if process.map({ GuestLauncherTrust.validates(process: $0, receipt: self.applications[path]!.receipt) }) != true {
                    self.applications[path]?.suppressed = true
                }
            }
        }
    }

    private func receive(_ note: Notification) {
        guard running, let path = note.userInfo?["app"] as? String,
              let app = applications[path], note.object as? String == app.request.stableIdentifier,
              note.userInfo?["owner"] as? String == String(getpid()),
              note.userInfo?["session"] as? String == session,
              note.userInfo?["vm"] as? String == app.request.vmPackagePath,
              let action = note.userInfo?["action"] as? String,
              NSWorkspace.shared.runningApplications.contains(where: {
                  GuestLauncherTrust.validates(process: $0, receipt: app.receipt)
              }) else { return }
        switch action {
        case "ready":
            applications[path]?.suppressed = false
            publish(path, state: snapshotKnown && !app.pids.isEmpty ? "running" : "unknown")
        case "activate":
            if snapshotKnown, let pid = app.pids.sorted().first { activate?(pid) }
            else { launchApplication?(path) }
        case "quit":
            guard snapshotKnown, !app.pids.isEmpty, !app.quitRequested else { return }
            applications[path]?.quitRequested = true
            for pid in app.pids.sorted() { quit?(pid) }
            // Guest Save/Cancel owns the outcome. Do not kill or respawn the
            // host representative while the guest remains running.
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                self?.applications[path]?.quitRequested = false
            }
        case "open":
            guard snapshotKnown, let pid = app.pids.sorted().first,
                  let paths = note.userInfo?["paths"] as? [String], paths.count <= 64,
                  paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return }
            _ = openFiles?(paths.map { URL(fileURLWithPath: $0) }, pid)
        default: break
        }
    }

    private static func validIcon(_ data: Data) -> Bool {
        guard data.count >= 24, data.count <= 4 * 1024 * 1024,
              data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
        let b = Array(data.prefix(24))
        func dimension(_ n: Int) -> UInt32 {
            UInt32(b[n]) << 24 | UInt32(b[n + 1]) << 16 | UInt32(b[n + 2]) << 8 | UInt32(b[n + 3])
        }
        return (1...512).contains(dimension(16)) && (1...512).contains(dimension(20)) && NSImage(data: data)?.isValid == true
    }
}
