import Foundation
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
            agent = a
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

    /// Restart through PowerEmu Tools (there is no key for it otherwise).
    func requestRestart() {
        guard state == .running, let agent, agent.connected else { return }
        agent.send("RESTART")
    }

    var toolsConnected: Bool { agent?.connected ?? false }

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
