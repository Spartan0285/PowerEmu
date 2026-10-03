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
    /// Option B: bridges an in-guest burn to a physical drive while running.
    @Published private(set) var physicalBurn: PhysicalBurn?
    @Published private(set) var state: RunState = .stopped
    @Published private(set) var lastError: String?
    /// For the runner to surface a non-fatal note (e.g. a lent external disk
    /// that was unplugged, so the machine started without it).
    func note(_ message: String) { lastError = message }
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
        guard state == .stopped else { return }
        guard let disk = startupDiskURL,
              let img = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else {
            startAfterSleepCheck()
            return
        }
        // A launch must wait for the disk's saved-state check. In particular,
        // auto-start can run before the library's background check finishes.
        // Reserve the start while checking so repeated clicks cannot launch twice.
        state = .starting
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let found = VMRunner.hasSleep(disk: disk, qemuImg: img)
            Task { @MainActor [weak self] in
                guard let self, self.state == .starting else { return }
                self.asleep = found
                self.state = .stopped
                self.startAfterSleepCheck()
            }
        }
    }

    private func startAfterSleepCheck() {
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
        // Option B: always listen for the guest to start a burn.  When one
        // begins, PowerEmu looks up the guest's blank-disc image and a real
        // optical drive with blank media, and streams the burn to it.  If
        // either is absent the guest just burns its own emulated disc.  The
        // listener is armed at boot so no restart is needed to burn later.
        let pb = PhysicalBurn(backing: { [weak self] in self?.config.insertedDisc })
        if pb.startListening() {
            r.burnStreamSocket = pb.socketPath
            physicalBurn = pb
        }
        runner = r
        state = .starting
        do {
            let a = GuestAgent(socketPath: r.agentPath)
            a.shareClipboard = config.clipboardShared
            try? a.start()
            a.onConnect = { [weak self] in
                self?.mountSharedFolders()
                // Reconnection must restore either state. A frontend restart
                // must not leave the guest's menu bar and Dock hidden when
                // this display is back in ordinary desktop mode.
                if let self {
                    if self.harmonyWanted { self.harmony(true) }
                    else if let version = self.agent?.info?.version,
                            version.compare("2.7", options: .numeric) != .orderedAscending {
                        // Older agents restart Finder even when already off.
                        self.agent?.send("HARMONY", "0")
                    }
                }
                // The tools have just said which version they are: the Devices
                // badge depends on it.
                self?.onToolsChanged?()
                self?.runOnConnectCommandIfAsked()
            }
            a.onWindows = { [weak self] rects in self?.display?.deliverWindows(rects) }
            a.onDragWindows = { [weak self] ids in self?.display?.onDragWindows?(ids) }
            a.onSheets = { [weak self] parents in self?.display?.onSheets?(parents) }
            a.onWindowApps = { [weak self] apps in self?.display?.deliverWindowApps(apps) }
            a.onDockApps = { [weak self] items in self?.display?.deliverDockApps(items) }
            a.onMinimized = { [weak self] m in self?.display?.deliverMinimized(m) }
            a.onFocused = { [weak self] id in self?.display?.deliverFocused(id) }
            a.onOcclusion = { [weak self] o in self?.display?.deliverOcclusion(o) }
            a.onAppIcon = { [weak self] pid, png in self?.display?.deliverAppIcon(pid, png) }
            a.onWindowFrame = { [weak self] data in self?.display?.onWindowFrame?(data) }
            a.onFocusReady = { [weak self] id, sequence, ok in self?.display?.onFocusReady?(id, sequence, ok) }
            a.onMenuFocus = { [weak self] token, id in self?.display?.onMenuFocus?(token, id) }
            a.onGuestFullscreen = { [weak self] in self?.display?.onGuestFullscreen?() }
            a.onHarmonyReady = { [weak self] token, size, ok in self?.display?.onHarmonyReady?(token, size, ok) }
            a.onMenuBar = { [weak self] pid, app, tops in self?.display?.deliverMenuBar(pid, app, tops) }
            a.onMenuItems = { [weak self] pid, path, items in self?.display?.deliverMenuItems(pid, path, items) }
            agent = a
            fileTransfer.agent = a
            a.onFileTransfer = { [weak self] reply in self?.fileTransfer.receive(reply) }
            a.onDisconnect = { [weak self] in self?.fileTransfer.disconnected(); self?.display?.onSheets?([:]); self?.display?.onDragWindows?([]) }
            let d = WebDAVServer(socketPath: r.davPath)
            d.setShares(config.activeSharedFolders + (config.isolated ? [] : [dropShare]))
            try? d.start()
            dav = d
            let w = SharedFolderWatcher { [weak a] changed in
                if a?.connected == true { a?.send("CHANGED", changed) }
            }
            w.watch(config.activeSharedFolders)
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
                // Menu picks and requests for a menu's contents go back the
                // same way they came.
                ch.sendToAgent = { [weak self] verb, text in self?.agent?.send(verb, text) }
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
            waking = asleep
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
            /*
             * Take the remembered USB devices now the machine can accept
             * them.  A moment's grace first: the emulator has only just
             * started and the guest has not finished looking at its bus.
             */
            if !config.autoConnectUSB.isEmpty {
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    MainActor.assumeIsolated { self?.connectRememberedUSB() }
                }
            }
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
            // The guest's Dock tiles stand for applications in a machine
            // that has just stopped; nothing else would clear them while
            // PowerEmu keeps running.
            VMDisplayView.harmonized?.stopGuestDock()
            VMWindowController.close(self)
            state = .stopped
            runner = nil
            physicalBurn?.abort(); physicalBurn = nil
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
    /// This run is a wake, so a failure means the saved machine could not be
    /// read back rather than that Mac OS X stopped.  See `processEnded`.
    private var waking = false

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

    // MARK: snapshots

    /// The snapshots on the startup disk, newest last.  Readable whether or
    /// not the machine is running, because the disk holds them.
    var snapshots: [(tag: String, date: String, size: String)] {
        guard let d = startupDiskURL else { return [] }
        return VMRunner.snapshots(onDisk: d)
    }

    /// Taking, reverting and deleting all need the machine running: they are
    /// QEMU's own savevm, and it is the thing holding the disk.
    func takeSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        guard let r = runner else { done("Start the virtual Mac first."); return }
        r.takeSnapshot(named: name, done)
    }

    func revertToSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        guard let r = runner else { done("Start the virtual Mac first."); return }
        r.revertToSnapshot(named: name, done)
    }

    func deleteSnapshot(named name: String, _ done: @escaping @Sendable (String?) -> Void) {
        guard let r = runner else { done("Start the virtual Mac first."); return }
        r.deleteSnapshot(named: name, done)
    }

    func pressPowerKey() { runner?.pressPowerKey() }

    /// Whether this machine takes that device by itself when it starts.
    func setAutoConnectUSB(_ d: HostUSBDevice, _ on: Bool) {
        if on {
            guard !config.autoConnectUSB.contains(d.id) else { return }
            config.autoConnectUSB.append(d.id)
        } else {
            config.autoConnectUSB.removeAll { $0 == d.id }
        }
        try? save()
        objectWillChange.send()
    }

    /*
     * Connect the remembered devices once the machine is running.  A device
     * that is not plugged in is simply not there to take, which is not an
     * error worth reporting -- the machine is expected to start without it.
     */
    func connectRememberedUSB() {
        guard state == .running, !config.autoConnectUSB.isEmpty else { return }
        for d in HostUSBDevice.list() where config.autoConnectUSB.contains(d.id) {
            guard attachedUSB[d.id] == nil else { continue }
            runner?.attachUSB(d) { err in
                Task { @MainActor in
                    if err == nil { self.attachedUSB[d.id] = d.name }
                }
            }
        }
    }

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
    /*
     * Harmony: ask the guest to stop drawing what is not a window.
     *
     * PowerEmu can hide the desktop from this side -- it watches what the
     * guest copies to its screen and makes everything that is not a window
     * transparent -- but telling which is which from the copies alone is
     * guesswork, and the Dock arrives looking exactly like a window.  The
     * guest knows perfectly well what its own Dock and desktop are, so it
     * is asked to put them away, and to put them back afterwards.
     *
     * Without PowerEmu Tools installed there is nobody to ask, and Harmony
     * falls back to the mask alone, which is what it did before.
     */
    func harmony(_ on: Bool) {
        harmonyWanted = on
        agent?.send("CAPTUREMODE", on && ProcessInfo.processInfo.environment["POWEREMU_HARMONY_MASKED"] != "1" ? "1" : "0")
        agent?.send("HARMONY", on ? "1" : "0")
    }

    /*
     * Remembered because the tools can go away and come back -- they are
     * restarted when they are updated, and they would be restarted again if
     * they ever crashed -- and the guest comes back not knowing it was in
     * Harmony.  Its Dock and desktop return, its windows stop being reported,
     * and this side is left showing proxies of windows nobody is describing
     * any more.  Whatever was asked for last is asked for again.
     */
    private var harmonyWanted = false

    /// Harmony runs the guest at this Mac's screen resolution so its windows
    /// line up 1:1; (0,0) restores the guest's normal (config) resolution.
    func setGuestResolution(_ w: Int, _ h: Int) {
        let tw = w > 0 ? w : config.bootWidth
        let th = h > 0 ? h : config.bootHeight
        agent?.send("RESOLUTION", "\(tw) \(th)")
    }

    /// Rootless Harmony: bring a guest window to the front, or move it, so its
    /// macOS proxy and the real window stay in step.
    func raiseGuestWindow(_ id: Int) { agent?.send("RAISE", "\(id)") }
    /// Raise a guest window and bring its application up with it.  Only for the
    /// pass that has to read a window whole; a click must not do this.
    func raiseGuestWindowHard(_ id: Int) { agent?.send("RAISEHARD", "\(id)") }
    /// Ask the guest for one of its applications' icons.
    func guestAppIcon(_ pid: Int) { agent?.send("APPICON", "\(pid)") }
    /// Quit one of the guest's applications.
    func quitGuestApp(_ pid: Int) { agent?.send("QUITAPP", "\(pid)") }
    /// Take a guest window back out of the guest's Dock.
    func restoreGuestWindow(_ pid: Int, _ index: Int) { agent?.send("UNMINIMIZE", "\(pid) \(index)") }
    /// The yellow button, pressed on a proxy: the window it stands for is the
    /// one that has to go into the Dock, or the proxy comes straight back out.
    func minimizeGuestWindow(_ id: Int) { agent?.send("MINIMIZE", "\(id)") }
    /// Bring one of the guest's applications to the front.
    /// Called when what we know about the guest's tools changes.
    var onToolsChanged: (() -> Void)?

    /// How the guest's PowerEmu Tools compare with the ones this app carries.
    /// Only meaningful while the machine is running and has answered hello.
    var toolsState: GuestTools.State {
        guard state == .running else { return .notInstalled }
        return GuestTools.state(installed: agent?.info?.version)
    }

    func activateGuestApp(_ pid: Int) { agent?.send("ACTIVATE", "\(pid)") }
    /// Open one of the guest's Dock applications that is not running yet.
    func launchGuestApp(path: String) { agent?.send("LAUNCH", path) }
    /// Raise by clicking a point the guest window is not covered at.
    func raiseGuestWindowAt(_ id: Int, _ x: Int, _ y: Int) { agent?.send("RAISE", "\(id) \(x) \(y)") }
    /// Move by dragging the window's title bar, which is the only way the guest
    /// will accept from us.
    func dragGuestWindow(_ id: Int, _ gx: Int, _ gy: Int, _ ex: Int, _ ey: Int) {
        agent?.send("MOVEWINDOW", "\(id) \(gx) \(gy) \(ex) \(ey)")
    }
    func moveGuestWindow(_ id: Int, _ x: Int, _ y: Int) { agent?.send("MOVEWINDOW", "\(id) \(x) \(y)") }

    func requestRestart() {
        guard state == .running, let agent, agent.connected else { return }
        agent.send("RESTART")
    }

    var toolsConnected: Bool { agent?.connected ?? false }

    // MARK: shared folders

    /// The URL a shared folder has inside the guest, as Mac OS X's mount
    /// volume wants it: not percent-encoded (webdavfs encodes it itself).
    static func guestURL(_ f: SharedFolder) -> String { "http://10.0.2.100/\(f.name)/" }


    /// `POWEREMU_AGENT_RUN` -- a shell line for the guest to run as soon as
    /// the tools connect, so the guest can be measured from here: `sysctl
    /// hw.ncpu`, `hostinfo`, a timed parallel workload.  The output goes to
    /// this process's log, and to the file named by `POWEREMU_AGENT_RUN_OUT`
    /// if there is one.  Nothing in PowerEmu's interface sets either of these:
    /// a guest runs what whoever started the emulator asked for, and no more.
    private func runOnConnectCommandIfAsked() {
        let env = ProcessInfo.processInfo.environment
        guard let command = env["POWEREMU_AGENT_RUN"], !command.isEmpty,
              let agent else { return }
        let seconds = TimeInterval(env["POWEREMU_AGENT_RUN_TIMEOUT"] ?? "") ?? 300
        if let path = env["POWEREMU_AGENT_RUN_OUT"] {
            agent.onRunResult = { token, status, elapsed, note, output in
                let report = String(format: "RUN %@ status=%d %.3fs (%@)\n%@",
                                    token, status, elapsed, note, output)
                try? report.write(toFile: path, atomically: true, encoding: .utf8)
            }
        }
        agent.run(command, timeout: seconds, token: "onconnect")
    }

    private func mountSharedFolders() {
        for f in config.activeSharedFolders { agent?.send("MOUNT", "\(Self.guestURL(f))\t\(f.name)") }
        let d = dropShare
        agent?.send("MOUNT", "\(Self.guestURL(d))\t\(d.name)")
    }

    /*
     * Where a file dragged from this Mac onto a guest window is put down.
     *
     * It is an ordinary shared folder, mounted in the guest like any other but
     * never shown in the settings: dropping a file copies it in here, and the
     * tools then copy it out of the mount to wherever it was dropped.  Going
     * through the share means the guest reads it over its own network, which
     * it already knows how to do, rather than needing anything new.
     */
    lazy var dropShare: SharedFolder = {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Transfers/" + UUID().uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return SharedFolder(path: dir.path, name: "PowerEmu Drop")
    }()

    lazy var fileTransfer = GuestFileTransfer(root: URL(fileURLWithPath: dropShare.path))

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
        dav?.setShares(config.sharedFolders + [dropShare])
        shareWatcher?.watch(config.sharedFolders)
        agent?.send("MOUNT", "\(Self.guestURL(f))\t\(f.name)")
    }

    func removeSharedFolder(_ f: SharedFolder) {
        agent?.send("UNMOUNT", f.name)
        config.sharedFolders.removeAll { $0.id == f.id }
        try? save()
        dav?.setShares(config.sharedFolders + [dropShare])
        shareWatcher?.watch(config.sharedFolders)
    }

    func setSharedFolderReadOnly(_ f: SharedFolder, _ ro: Bool) {
        guard let i = config.sharedFolders.firstIndex(where: { $0.id == f.id }) else { return }
        config.sharedFolders[i].readOnly = ro
        try? save()
        dav?.setShares(config.sharedFolders + [dropShare])
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

    /// Stop the machine and start it again, to apply a change that only takes
    /// effect at launch -- attaching or detaching an external disk, or booting
    /// from a disc.  The guest is shut down *gracefully* (through PowerEmu
    /// Tools if it is there, otherwise the power key), so its disk is left
    /// clean; only if it has not gone after a while is the plug pulled.  When
    /// it is already stopped, it simply starts.
    private var restartWhenStopped = false
    func restartForConfigChange() {
        guard state != .stopped else { start(); return }
        restartWhenStopped = true
        requestShutDown()                       // graceful; processEnded restarts it
        DispatchQueue.main.asyncAfter(deadline: .now() + 60) { [weak self] in
            guard let self, self.restartWhenStopped, self.state != .stopped else { return }
            // The guest ignored the shutdown request -- fall back to force.
            self.forcePowerOff()
        }
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
        // A disc image chosen this way is a normal read-only disc, not a
        // blank recorder; only newBlankDisc() sets the recordable flag.
        config.discRecordable = false
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
            config.discRecordable = false
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
                    self.config.discRecordable = false
                    self.hostDiscName = nil
                    if self.config.bootFromDisc { self.config.bootFromDisc = false }
                    try? self.save()
                }
            }
        }
    }

    /// Create a fresh blank recordable disc image (a 4.7 GB DVD-R) in this
    /// machine's Disks folder and put it in the drive so the guest can burn to
    /// it.  Burning needs the drive brought up as a recorder, so if the
    /// machine is already running the disc is remembered and applied on the
    /// next start.  Returns the created file, or nil with lastError set.
    @discardableResult
    func newBlankDisc(sizeGB: Double = 4.7) -> URL? {
        let dir = disksURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var name = "Blank DVD.img"
        var url = dir.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: url.path) {
            name = "Blank DVD \(n).img"
            url = dir.appendingPathComponent(name)
            n += 1
        }
        // Match the physical blank media if one is in a real drive, so the
        // guest's disc is CD-sized for a CD-R and DVD-sized for a DVD -- the
        // guest then burns in the right mode and the sizes cannot mismatch.
        let bytes: Int64
        if let blocks = PhysicalBurn.blankMediaBlocks(), blocks > 0 {
            bytes = Int64(blocks) * 2048
        } else {
            bytes = Int64(sizeGB * 1_000_000_000)
        }
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            lastError = "Could not create the blank disc."
            return nil
        }
        do {
            let h = try FileHandle(forWritingTo: url)
            try h.truncate(atOffset: UInt64(bytes))   // sparse: no space used yet
            try h.close()
        } catch {
            try? FileManager.default.removeItem(at: url)
            lastError = "Could not size the blank disc: \(error.localizedDescription)"
            return nil
        }
        if !config.discs.contains(url.path) { config.discs.insert(url.path, at: 0) }
        config.insertedDisc = url.path
        config.discRecordable = true
        config.bootFromDisc = false
        try? save()
        // If the machine is running with a burner-capable drive, drop the blank
        // disc straight in -- no restart.  (When it booted with a read-only
        // disc the drive is not recordable and this insert is refused; the
        // caller then falls back to asking for a restart.)
        if state == .running, let runner {
            runner.insertRecordableDisc(url.path) { err in
                Task { @MainActor in if let err { self.lastError = err } else { self.hostDiscName = nil } }
            }
        }
        return url
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

    /// Lend a physical external disk to this machine as a real IDE hard disk
    /// (to browse, install Mac OS X onto, or boot from).  Unlike a disc, this
    /// attaches when the machine starts -- the emulated IDE bus cannot
    /// hot-plug -- so it is recorded in the config and applied on the next
    /// start.  A running machine must be restarted for it to appear.
    func attachExternalDisk(_ drive: HostDrive) {
        config.externalDisk = ExternalDisk(bsdName: drive.bsdName, label: drive.name,
                                           mediaUUID: drive.mediaUUID,
                                           sizeBytes: drive.sizeBytes)
        try? save()
        objectWillChange.send()
    }
    func detachExternalDisk() {
        config.externalDisk = nil
        try? save()
        objectWillChange.send()
    }
    func setExternalDiskBoot(_ on: Bool) {
        config.externalDisk?.bootFrom = on
        // Booting the external and booting the installer disc are exclusive.
        if on { config.bootFromDisc = false }
        try? save()
        objectWillChange.send()
    }

    /// Boot from the disc in the drive at the next start -- for installing Mac
    /// OS X (onto the internal disk or a lent external one).  Takes effect at
    /// launch, so a running machine restarts to apply it.
    func setBootFromDisc(_ on: Bool) {
        config.bootFromDisc = on
        if on { config.externalDisk?.bootFrom = false }
        try? save()
        objectWillChange.send()
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
        VMDisplayView.harmonized?.stopGuestDock()
        VMWindowController.close(self)
        attachedUSB = [:]
        hostDiscName = nil
        sshPortInUse = nil
        monitorPortInUse = nil
        state = .stopped
        runner = nil
        physicalBurn?.abort(); physicalBurn = nil
        if restartWhenStopped {
            restartWhenStopped = false
            // Let the emulator release its sockets and give the disk back
            // before starting again with the new configuration.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.start() }
            }
            return
        }
        let wasWaking = waking
        waking = false
        if status != 0 && wasWaking {
            /*
             * The saved machine could not be read back.  A machine saved by
             * an older PowerEmu can do this: what the emulator writes into a
             * saved machine has to match the hardware it starts, and when a
             * piece of that hardware changes -- the NVRAM did -- an older
             * saving no longer fits.  Rather than leave the reader with an
             * error and a machine that will not start, throw the saving away
             * and start Mac OS X from the beginning, which is what powering
             * off and on would have done anyway.
             */
            discardSleepAfterFailedWake()
            lastError = "“\(config.name)” could not be woken, so it has been started fresh. "
                      + "Anything that was open when it went to sleep is gone."
            start()
            return
        }
        if status != 0 {
            let log = (try? String(contentsOf: logsURL.appendingPathComponent("qemu.log"), encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n")
            lastError = "The virtual Mac stopped unexpectedly (status \(status)).\(tail.isEmpty ? "" : "\n" + tail)"
        }
    }

    /// Wipe a saved machine that would not load.  `discardSleep` insists the
    /// machine is still marked asleep; by the time a wake has failed it is
    /// not, because starting clears the flag.
    private func discardSleepAfterFailedWake() {
        guard let disk = startupDiskURL,
              let img = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else { return }
        asleep = false
        VMRunner.forgetSleep(disk: disk, qemuImg: img) {}
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
