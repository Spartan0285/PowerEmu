import Foundation
import AppKit
import Darwin
import Combine

/// One .poweremu package on disk:
///
///     Name.poweremu/
///         config.plist
///         Disks/     hard disks and disc images
///         ROMs/      ATI option ROMs (user supplied)
///         Logs/      console, QEMU output, GPU trace
///
@MainActor
final class VirtualMachine: ObservableObject, Identifiable {
    let url: URL
    @Published var config: VMConfig
    @Published private(set) var state: RunState = .stopped
    @Published private(set) var lastError: String?
    /// A host drive (not an image) is in the virtual CD/DVD drive.
    @Published private(set) var hostDiscName: String?
    /// Host ports of the running machine (they move when taken).
    @Published private(set) var sshPortInUse: Int?
    @Published private(set) var monitorPortInUse: Int?
    private var discPoll: Timer?

    enum RunState: Equatable {
        case stopped, starting, running, stopping
    }

    nonisolated var id: URL { url }

    var disksURL: URL { url.appendingPathComponent("Disks", isDirectory: true) }
    var romsURL: URL { url.appendingPathComponent("ROMs", isDirectory: true) }
    var logsURL: URL { url.appendingPathComponent("Logs", isDirectory: true) }
    var configURL: URL { url.appendingPathComponent("config.plist") }

    private var runner: VMRunner?
    /// PowerEmu Tools in the guest, while running.
    @Published private(set) var agent: GuestAgent?
    private var dav: WebDAVServer?
    private var clock: ClockServer?
    private var display: DisplayChannel?
    private var agentWatch: AnyCancellable?

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        config = try PropertyListDecoder().decode(VMConfig.self, from: data)
    }

    init(url: URL, config: VMConfig) {
        self.url = url
        self.config = config
    }

    func save() throws {
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        try enc.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: running

    func start() {
        guard state == .stopped else { return }
        lastError = nil
        let r = VMRunner(vm: self)
        runner = r
        state = .starting
        do {
            let a = GuestAgent(socketPath: r.agentPath)
            a.shareClipboard = config.shareClipboard
            try? a.start()
            a.onConnect = { [weak self] in self?.mountSharedFolders() }
            agent = a
            let d = WebDAVServer(socketPath: r.davPath)
            d.setShares(config.sharedFolders)
            try? d.start()
            dav = d
            let ck = ClockServer(socketPath: r.clockPath)
            try? ck.start()
            clock = ck
            if config.embeddedDisplay {
                let ch = DisplayChannel(socketPath: r.displayPath)
                try ch.start()
                display = ch
                let w = VMWindowController.show(self, channel: ch)
                if config.startFullscreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.window?.toggleFullScreen(nil) } }
            }
            // Views watch the machine; pass the agent's changes on.
            agentWatch = a.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            if config.bootChime { Chime.play() }
            try r.launch { [weak self] status in
                Task { @MainActor in self?.processEnded(status: status) }
            }
            state = .running
            sshPortInUse = r.sshPort
            monitorPortInUse = r.monitorPort
            startDiscPolling()
        } catch {
            agent?.stop()
            agent = nil
            dav?.stop()
            dav = nil
            clock?.stop()
            clock = nil
            display?.stop()
            display = nil
            VMWindowController.close(self)
            state = .stopped
            runner = nil
            lastError = error.localizedDescription
        }
    }

    /// Like pressing a real Mac's power key: the guest asks whether to shut
    /// down, restart or sleep.  (Fully automatic shutdown comes with the
    /// guest tools.)
    func requestShutDown() {
        guard state == .running else { return }
        if let agent, agent.connected {
            agent.send("SHUTDOWN")
        } else {
            runner?.pressPowerKey()
        }
    }

    /// Bring the virtual Mac's window forward (it only hides when closed).
    func showWindow() {
        guard let display, state == .running else { return }
        _ = VMWindowController.show(self, channel: display)
        NSApp.activate(ignoringOtherApps: true)
    }

    var hasWindow: Bool { display != nil }

    /// USB devices of this Mac given to the guest (id → name).
    @Published private(set) var attachedUSB: [String: String] = [:]

    func pressPowerKey() { runner?.pressPowerKey() }

    func toggleUSB(_ d: HostUSBDevice) {
        guard let runner, state == .running else { return }
        lastError = nil
        if attachedUSB[d.id] != nil {
            runner.detachUSB(d.id) { err in
                Task { @MainActor in
                    if let err { self.lastError = err } else { self.attachedUSB[d.id] = nil }
                }
            }
        } else {
            runner.attachUSB(d) { err in
                Task { @MainActor in
                    if let err {
                        self.lastError = "\(d.name) could not be connected: \(err). macOS may be using it (keyboards, mice and disks stay with the Mac)."
                    } else {
                        self.attachedUSB[d.id] = d.name
                    }
                }
            }
        }
    }

    func queryPerf(done: @escaping @Sendable (String?) -> Void) {
        guard let runner, state == .running else { done(nil); return }
        runner.queryPerf(done: done)
    }

    /// Restart through PowerEmu Tools (there is no key for it otherwise).
    func requestRestart() {
        guard state == .running, let agent, agent.connected else { return }
        agent.send("RESTART")
    }

    var toolsConnected: Bool { agent?.connected ?? false }

    // MARK: shared folders

    /// The URL a shared folder has inside the guest, as Mac OS X's mount
    /// volume wants it: not percent-encoded (webdavfs encodes it itself).
    static func guestURL(_ f: SharedFolder) -> String { "http://10.0.2.100/\(f.name)/" }

    private func mountSharedFolders() {
        for f in config.sharedFolders { agent?.send("MOUNT", "\(Self.guestURL(f))\t\(f.name)") }
    }

    func addSharedFolder(_ url: URL) {
        var name = url.lastPathComponent.replacingOccurrences(of: "/", with: "-")
        let taken = Set(config.sharedFolders.map(\.name))
        if taken.contains(name) {
            var i = 2
            while taken.contains("\(name) \(i)") { i += 1 }
            name = "\(name) \(i)"
        }
        let f = SharedFolder(path: url.path, name: name)
        config.sharedFolders.append(f)
        try? save()
        dav?.setShares(config.sharedFolders)
        agent?.send("MOUNT", "\(Self.guestURL(f))\t\(f.name)")
    }

    func removeSharedFolder(_ f: SharedFolder) {
        agent?.send("UNMOUNT", f.name)
        config.sharedFolders.removeAll { $0.id == f.id }
        try? save()
        dav?.setShares(config.sharedFolders)
    }

    func setSharedFolderReadOnly(_ f: SharedFolder, _ ro: Bool) {
        guard let i = config.sharedFolders.firstIndex(where: { $0.id == f.id }) else { return }
        config.sharedFolders[i].readOnly = ro
        try? save()
        dav?.setShares(config.sharedFolders)
    }

    func setShareClipboard(_ on: Bool) {
        config.shareClipboard = on
        agent?.shareClipboard = on
        try? save()
    }

    /// Pull the plug.  Mac OS X's disk may need repair afterwards.
    func forcePowerOff() {
        guard state == .running || state == .stopping else { return }
        state = .stopping
        runner?.terminate()
    }

    // MARK: discs

    /// Put a disc image in the CD/DVD drive: now if running, else at startup.
    /// The PowerEmu Tools disc inside the app (or the repository's build
    /// folder when running from source).
    static var toolsDiscURL: URL? {
        let fm = FileManager.default
        if let u = Bundle.main.url(forResource: "PowerEmu Tools", withExtension: "iso") { return u }
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/PowerEmu.app/Contents/Resources/PowerEmu Tools.iso")
        return fm.fileExists(atPath: dev.path) ? dev : nil
    }

    func insertToolsDisc() {
        guard let u = Self.toolsDiscURL else { return }
        insertDisc(u, remember: false)
    }

    func insertDisc(_ url: URL, remember: Bool = true) {
        let path = url.path
        if remember && !config.discs.contains(path) { config.discs.insert(path, at: 0) }
        lastError = nil
        ejectRefused = false
        if state == .running, let runner {
            ejecting = true
            runner.insertDisc(path) { err in
                Task { @MainActor in
                    self.ejecting = false
                    if let err {
                        // Went in after all (the reply was lost): the drive
                        // poll will show it; only report real failures.
                        runner.queryDisc { file in
                            Task { @MainActor in
                                guard file != path else { self.config.insertedDisc = path; try? self.save(); return }
                                self.lastError = err
                                self.ejectRefused = err == VMRunner.discInUse
                            }
                        }
                    } else {
                        self.config.insertedDisc = path
                        self.hostDiscName = nil
                        try? self.save()
                    }
                }
            }
        } else {
            config.insertedDisc = path
            try? save()
        }
    }

    /// Asks Mac OS X to give the disc up (it unmounts it); `force` takes it
    /// out regardless.  While the guest decides, `ejecting` is true.
    @Published private(set) var ejecting = false
    @Published private(set) var ejectRefused = false

    func ejectDisc(force: Bool = false) {
        guard state == .running, let runner else {
            config.insertedDisc = nil
            if config.bootFromDisc { config.bootFromDisc = false }
            try? save()
            return
        }
        ejecting = true
        ejectRefused = false
        lastError = nil
        runner.ejectDisc(force: force) { err in
            Task { @MainActor in
                self.ejecting = false
                if let err {
                    self.lastError = err
                    self.ejectRefused = err == VMRunner.discInUse
                } else {
                    self.config.insertedDisc = nil
                    self.hostDiscName = nil
                    if self.config.bootFromDisc { self.config.bootFromDisc = false }
                    try? self.save()
                }
            }
        }
    }

    func forgetDisc(_ path: String) {
        config.discs.removeAll { $0 == path }
        if config.insertedDisc == path && state != .running { config.insertedDisc = nil }
        try? save()
    }

    /// Put one of this Mac's drives (DVD, CD, floppy) in the virtual drive.
    func insertHostDrive(_ drive: HostDrive) {
        guard state == .running, let runner else { return }
        lastError = nil
        ejectRefused = false
        HostDrive.open(drive) { fd, err in
            Task { @MainActor in
                guard fd >= 0 else { self.lastError = err; return }
                self.ejecting = true
                runner.insertDevice(fd: fd) { err in
                    close(fd)
                    Task { @MainActor in
                        self.ejecting = false
                        if let err { self.lastError = err; self.ejectRefused = err == VMRunner.discInUse } else {
                            self.hostDiscName = drive.name
                            self.config.insertedDisc = nil
                            try? self.save()
                        }
                    }
                }
            }
        }
    }

    /// Keep the drive's state in step with the guest, which can eject too.
    private func startDiscPolling() {
        discPoll?.invalidate()
        discPoll = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state == .running, let runner = self.runner else { return }
                runner.queryDisc { file in
                    Task { @MainActor in
                        if file == nil {
                            if self.config.insertedDisc != nil || self.hostDiscName != nil {
                                self.config.insertedDisc = nil
                                self.hostDiscName = nil
                                try? self.save()
                            }
                        } else if let f = file, !f.isEmpty, f != self.config.insertedDisc {
                            self.config.insertedDisc = f
                            try? self.save()
                        }
                    }
                }
            }
        }
    }

    private func processEnded(status: Int32) {
        discPoll?.invalidate()
        discPoll = nil
        agent?.stop()
        agent = nil
        agentWatch = nil
        dav?.stop()
        dav = nil
        clock?.stop()
        clock = nil
        display?.stop()
        display = nil
        VMWindowController.close(self)
        attachedUSB = [:]
        hostDiscName = nil
        sshPortInUse = nil
        monitorPortInUse = nil
        state = .stopped
        runner = nil
        if status != 0 {
            let log = (try? String(contentsOf: logsURL.appendingPathComponent("qemu.log"), encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n")
            lastError = "The virtual Mac stopped unexpectedly (status \(status)).\(tail.isEmpty ? "" : "\n" + tail)"
        }
    }
}

enum PackageError: LocalizedError {
    case exists(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .exists(let n): return "A virtual Mac named “\(n)” already exists."
        case .missing(let what): return "\(what) could not be found."
        }
    }
}

/// Copy a file as an APFS clone when possible: instant, and no extra space
/// until either copy changes.
func cloneOrCopy(_ src: URL, to dst: URL) throws {
    if clonefile(src.path, dst.path, 0) == 0 { return }
    try FileManager.default.copyItem(at: src, to: dst)
}
