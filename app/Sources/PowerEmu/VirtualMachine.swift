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
    private var aliveCheck: Timer?
    private var missedAlive = 0

    enum RunState: Equatable {
        case stopped, starting, running, paused, sleeping, stopping
    }

    nonisolated var id: URL { url }

    var disksURL: URL { url.appendingPathComponent("Disks", isDirectory: true) }
    var logsURL: URL { url.appendingPathComponent("Logs", isDirectory: true) }
    var configURL: URL { url.appendingPathComponent("config.plist") }

    private var runner: VMRunner?

    /// The emulator's pid while it is running, for the overlay's host-side
    /// figures. Deliberately the only thing exposed about the runner.
    var qemuPID: pid_t? { runner?.qemuPID }
    /// PowerEmu Tools in the guest, while running.
    @Published private(set) var agent: GuestAgent?
    private var dav: WebDAVServer?
    private var shareWatcher: SharedFolderWatcher?
    /// This Mac's game controller, given to the guest as a USB gamepad.
    private(set) var gamepad: GamepadServer?
    /// The machine as other Macs on the network see it.
    let share = NetworkShare()
    /// The helper that puts the machine straight on to the network.
    let bridge = NetBridge()
    /// The address the network gave the bridge, for the guest's own card.
    private var pendingBridgeMAC: String?
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
        /*
         * A bridged machine needs the helper running first: the emulator
         * looks for it the moment it starts, and the address the network
         * hands the bridge becomes the guest's own, so the network sees one
         * machine rather than two.
         */
        guard let interface = config.bridgedInterface, state == .stopped else {
            start(adopting: false)
            return
        }
        let r = VMRunner(vm: self)
        state = .starting
        bridge.start(interface: interface, helperSocket: r.bridgeHelperPath,
                     emulatorSocket: r.bridgeEmulatorPath) { [weak self] problem in
            guard let self else { return }
            self.state = .stopped              // start(adopting:) insists on it
            if let problem {
                self.lastError = problem
                return
            }
            self.pendingBridgeMAC = self.bridge.macAddress
            self.start(adopting: false)
        }
    }

    /// PowerEmu quit unexpectedly while this virtual Mac was running, and
    /// the emulator carried on: take it back, rather than leave a machine
    /// nobody can see or shut down.  The guest's screen and PowerEmu Tools
    /// reconnect by themselves once these sockets are listening again.
    func adoptIfLeftRunning() {
        guard state == .stopped else { return }
        start(adopting: true)
    }

    private func start(adopting: Bool) {
        guard state == .stopped else { return }
        let r = VMRunner(vm: self)
        if adopting && !r.isLeftRunning() { return }
        lastError = nil
        if config.shareOnNetwork {
            r.sharedPorts = share.choosePorts(avoiding: Set([config.sshPort, config.monitorPort].compactMap { $0 }))
        }
        r.bridgeMAC = pendingBridgeMAC
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
            let w = SharedFolderWatcher { [weak a] changed in
                if a?.connected == true { a?.send("CHANGED", changed) }
            }
            w.watch(config.sharedFolders)
            shareWatcher = w
            let ck = ClockServer(socketPath: r.clockPath)
            try? ck.start()
            clock = ck
            if config.gamepad {
                let g = GamepadServer(socketPath: r.gamepadPath)
                try? g.start()
                gamepad = g
            }
            if config.shareOnNetwork { share.advertise(machineNamed: config.name) }
            if config.embeddedDisplay {
                let ch = DisplayChannel(socketPath: r.displayPath)
                try ch.start()
                display = ch
                let w = VMWindowController.show(self, channel: ch)
                if asleep {
                    // Nothing will be drawn until the machine's memory has
                    // been read back, which is the longest silence PowerEmu
                    // ever shows; say so rather than showing a black window.
                    w.display.expectRestoredFrame()
                    w.display.showStatus("Waking \u{201C}\(config.name)\u{201D}\u{2026}",
                                         "Reading its memory back from the startup disk.",
                                         untilFirstFrame: true)
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                    MainActor.assumeIsolated { w.display.showPerformanceForTesting() }
                }
                if config.startFullscreen { DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { w.window?.toggleFullScreen(nil) } }
            }
            // Views watch the machine; pass the agent's changes on.
            agentWatch = a.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
            r.wake = asleep
            if config.bootChime && !adopting && !asleep { Chime.play(config.chimeSound, file: config.chimeFile) }
            if adopting {
                r.adopt { [weak self] status in
                    Task { @MainActor in self?.processEnded(status: status) }
                }
                r.askIfPaused { [weak self] paused in
                    Task { @MainActor in
                        guard let self, paused, self.state == .running else { return }
                        self.state = .paused
                    }
                }
            } else {
                try r.launch { [weak self] status in
                    Task { @MainActor in self?.processEnded(status: status) }
                }
            }
            state = .running
            if asleep {
                /*
                 * The saved copy is thrown away once the machine is back on
                 * its feet: keeping it would let a later start restore
                 * memory that no longer matches what is on the disk.
                 */
                asleep = false
                DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
                    MainActor.assumeIsolated { self?.runner?.forgetSleep() }
                }
            }
            sshPortInUse = r.sshPort
            monitorPortInUse = r.monitorPort
            startDiscPolling()
            startAliveChecking()
        } catch {
            agent?.stop()
            agent = nil
            dav?.stop()
            dav = nil
            shareWatcher?.stop()
            shareWatcher = nil
            gamepad?.stop()
            gamepad = nil
            share.stop()
            bridge.stop(helperSocket: r.bridgeHelperPath)
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

    /*
     * Pausing.  The emulator stops the guest's processor: no instruction
     * runs, the screen keeps its last frame, and the guest's own clock
     * stops with it -- PowerEmu Tools' clock puts the time right again
     * once it starts, so a long pause doesn't leave Mac OS X in the past.
     * Disks and memory are untouched, so this is not a way to save a
     * machine for later: quitting while paused still ends it.
     */
    /*
     * Sleep, as a real Mac does: everything the machine is doing goes into
     * its startup disk and the emulator quits.  Starting it again puts it
     * back exactly where it was, with the same programs open.
     *
     * Unlike pausing, this survives quitting PowerEmu and restarting this
     * Mac.  It costs disk space (the machine's memory) and a little time,
     * and the disk must not be touched in between: waking a machine whose
     * disk has changed underneath it would corrupt it.
     */
    func sleep() {
        guard state == .running || state == .paused, let runner else { return }
        state = .sleeping
        lastError = nil
        VMWindowController.open[url]?.display.showStatus(
            "Putting \u{201C}\(config.name)\u{201D} to sleep\u{2026}",
            "Saving its memory to the startup disk.")
        runner.sleep { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err {
                    self.lastError = "The virtual Mac could not be put to sleep. \(err)"
                    self.state = .running
                    VMWindowController.open[self.url]?.display.clearStatus()
                    return
                }
                self.asleep = true
                runner.terminate()          // processEnded() tidies the rest
            }
        }
    }

    /// Whether this machine was put to sleep and is waiting to be woken.
    @Published private(set) var asleep = false

    /// Ask the disk, when PowerEmu opens: a machine may have been left
    /// asleep in an earlier run.
    func checkForSleep() {
        guard state == .stopped, let disk = startupDiskURL,
              let img = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else { return }
        // Off the main thread: this asks qemu-img, and a tool that waits on
        // a disk must never be able to hold up the window.
        DispatchQueue.global(qos: .utility).async {
            let found = VMRunner.hasSleep(disk: disk, qemuImg: img)
            Task { @MainActor [weak self] in
                guard let self, self.state == .stopped, found != self.asleep else { return }
                self.asleep = found
            }
        }
    }

    var startupDiskURL: URL? {
        config.startupDiskConfig.map { disksURL.appendingPathComponent($0.file) }
    }

    /// Throw the saved machine away without waking it: the next start boots
    /// Mac OS X from the beginning, as if it had been powered off.
    func discardSleep() {
        guard asleep, state == .stopped, let disk = startupDiskURL,
              let img = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else { return }
        asleep = false
        VMRunner.forgetSleep(disk: disk, qemuImg: img) {}
    }

    func pause() {
        guard state == .running, let runner else { return }
        runner.pause { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.lastError = err } else { self.state = .paused }
            }
        }
    }

    func resume() {
        guard state == .paused, let runner else { return }
        runner.resume { [weak self] err in
            Task { @MainActor in
                guard let self else { return }
                if let err { self.lastError = err } else { self.state = .running }
            }
        }
    }

    /// Bring the virtual Mac's window forward (it only hides when closed).
    func showWindow() {
        guard let display, state == .running || state == .paused else { return }
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
        shareWatcher?.watch(config.sharedFolders)
        agent?.send("MOUNT", "\(Self.guestURL(f))\t\(f.name)")
    }

    func removeSharedFolder(_ f: SharedFolder) {
        agent?.send("UNMOUNT", f.name)
        config.sharedFolders.removeAll { $0.id == f.id }
        try? save()
        dav?.setShares(config.sharedFolders)
        shareWatcher?.watch(config.sharedFolders)
    }

    func setSharedFolderReadOnly(_ f: SharedFolder, _ ro: Bool) {
        guard let i = config.sharedFolders.firstIndex(where: { $0.id == f.id }) else { return }
        config.sharedFolders[i].readOnly = ro
        try? save()
        dav?.setShares(config.sharedFolders)
        shareWatcher?.watch(config.sharedFolders)
    }

    func setShareClipboard(_ on: Bool) {
        config.shareClipboard = on
        agent?.shareClipboard = on
        try? save()
    }

    /// Pull the plug.  Mac OS X's disk may need repair afterwards.
    func forcePowerOff() {
        guard state == .running || state == .paused || state == .stopping else { return }
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
        if config.insertedDisc == path && state == .stopped { config.insertedDisc = nil }
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
    /*
     * Notice a machine that has gone without saying so.
     *
     * PowerEmu learns that an emulator it started has finished from the
     * process itself, and that an adopted one has finished by watching its
     * socket -- but neither covers a machine killed from outside, and the
     * page then offers Shut Down and Force Power Off for something that is
     * no longer there.  This asks, twice over, whether the machine still
     * answers, and lets go when it doesn't.
     */
    private func startAliveChecking() {
        aliveCheck?.invalidate()
        missedAlive = 0
        aliveCheck = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.state != .stopped, let runner = self.runner else { return }
                if runner.isAlive() {
                    self.missedAlive = 0
                    return
                }
                self.missedAlive += 1
                if self.missedAlive >= 2 {
                    self.processEnded(status: 0)
                }
            }
        }
    }

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
        aliveCheck?.invalidate()
        aliveCheck = nil
        agent?.stop()
        agent = nil
        agentWatch = nil
        dav?.stop()
        dav = nil
        shareWatcher?.stop()
        shareWatcher = nil
        gamepad?.stop()
        gamepad = nil
        share.stop()
        if let r = runner { bridge.stop(helperSocket: r.bridgeHelperPath) }
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
