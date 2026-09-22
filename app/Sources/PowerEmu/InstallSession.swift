import Foundation
import CryptoKit

/// How long each part of an install takes on the Mac it was measured on
/// (an M-series MacBook Air, retail 10.4.6 DVD, 2026-09-22: 8½ minutes to
/// install, 5½ more for 10.4.11). The progress window scales
/// these by how fast the parts already done went, so a slower Mac gets a
/// longer estimate after the first minute or two rather than a wrong one.
enum InstallTiming {
    /// Cloning the disc and adding PowerEmu's files.
    static let prepare: Double = 15
    /// From starting the emulator to the Installer writing its first file:
    /// the disc boots, PowerEmu erases "Macintosh HD", the Installer loads.
    static let startInstaller: Double = 100
    /// The Installer writes "Macintosh HD" at about this rate.
    static let writeKBps: Double = 4500
    /// After the last file: receipts, "Optimizing System Performance", restart.
    static let finishInstall: Double = 45
    /// The first start from "Macintosh HD", up to the update beginning.
    static let startUpdate: Double = 110
    /// The 10.4.11 combo update, start to "The install was successful":
    /// 3½ minutes over 10.4.6, about 11 over 10.4.0 (it replaces far more).
    static let installUpdate: Double = 220
    static func installUpdate(from version: String) -> Double {
        let minor = Int(version.split(separator: ".").dropFirst(2).first ?? "") ?? 0
        return minor >= 6 ? 220 : minor >= 3 ? 420 : 660
    }
    /// Its shutdown, then Apple's startup-time step (a restart) and the
    /// cache rebuild, each a cold start: about 4 minutes.
    static let finishUpdate: Double = 240

    static func total(expectedKB: Int, update: Bool, from version: String = "10.4.6") -> Double {
        var t = prepare + startInstaller + Double(expectedKB) / writeKBps + finishInstall
        if update { t += startUpdate + installUpdate(from: version) + finishUpdate }
        return t
    }
}

/// One headless install of Mac OS X into a new virtual Mac, from choosing
/// the disc to the first screen the reader sees.
@MainActor
final class InstallSession: ObservableObject {
    struct Step: Identifiable {
        let id: Int
        let title: String
    }

    enum Outcome: Equatable { case running, finished, failed, cancelled }

    let vm: VirtualMachine
    let options: InstallPlan.Options
    let steps: [Step]
    /// "10.4.0", "10.4.6": the disc's version, for the update's estimate.
    let discVersion: String

    /// The headline ("Installing Essentials") and the line under it.
    @Published private(set) var title = "Preparing the installer"
    @Published private(set) var detail = ""
    /// 0...1 over the whole install.
    @Published private(set) var fraction: Double = 0
    /// Seconds left for the whole install, nil while it can't be told yet.
    @Published private(set) var remaining: Double?
    @Published private(set) var stepIndex = 0
    @Published private(set) var outcome: Outcome = .running
    @Published private(set) var failure: String?
    /// What the guest last wrote in its log, shown when something fails.
    @Published private(set) var guestLog = ""
    /// Said at the end when the update had to be left out.
    @Published private(set) var note: String?

    private let setupDisc: URL
    private let mailbox: URL
    private var prepared: InstallPlan.Prepared?
    private var runner: VMRunner?
    private var poll: Timer?

    // Timing
    private var stepStarted = Date()
    /// Measured duration / baseline of the parts done; scales what is left.
    private var speed: Double = 1
    private var writeStarted: Date?
    private var writeRate: Double?            // KB/s, smoothed
    private var lastUsed: (kb: Int, at: Date)?
    private var lastGrowth = Date()
    private var filesDone: Date?
    private var baseUsedKB = 0
    private var updatePercentStarted: (at: Date, pct: Double)?
    private var updatePct: Double = 0
    private var updateOptimizing: Date?
    private var smoothedRemaining: Double?
    /// When "Macintosh HD" last changed on the host: a guest that stops
    /// writing for long enough while installing is stuck, not slow.
    private var diskChanged = Date()
    private var diskStamp: Date?
    @Published private(set) var slow = false

    // The update disc
    private var combo: URL?
    private var comboError: String?
    private var download: ComboDownload?
    @Published private(set) var downloadProgress: (done: Int64, total: Int64)?
    /// One line about Apple's update file, so downloading and installing are
    /// never confused: "already on this Mac", "downloading …", "downloaded".
    @Published private(set) var updateSource: String?

    var onFinish: (() -> Void)?
    /// Cold starts after the update installed, while Mac OS X finishes it.
    private var finishingBoots = 0
    private var finishing = false

    init(vm: VirtualMachine, options: InstallPlan.Options, discVersion: String) {
        self.vm = vm
        self.options = options
        self.discVersion = discVersion
        var s = [Step(id: 0, title: "Erase “Macintosh HD”"),
                 Step(id: 1, title: "Start the Mac OS X Installer"),
                 Step(id: 2, title: "Install Mac OS X")]
        if options.update10411 { s.append(Step(id: 3, title: "Install the Mac OS X 10.4.11 update")) }
        s.append(Step(id: s.count, title: "Start up"))
        steps = s
        setupDisc = vm.disksURL.appendingPathComponent("Installer (PowerEmu).iso")
        mailbox = vm.disksURL.appendingPathComponent("PowerEmu Setup.img")
    }

    // MARK: Log

    /// Logs/install.log in the machine's package: what happened, for support.
    private var lastLoggedStatus = ""
    private func log(_ line: String) {
        let text = "\(ISO8601DateFormatter().string(from: Date())) \(line)\n"
        NSLog("PowerEmu install: %@", line)
        // The machine was moved to the Trash: don't make a new one.
        guard FileManager.default.fileExists(atPath: vm.url.path) else { return }
        let url = vm.logsURL.appendingPathComponent("install.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(text.data(using: .utf8)!); try? h.close()
        } else {
            try? text.write(to: url, atomically: false, encoding: .utf8)
        }
    }

    private func logStatus(_ s: String) {
        guard s != lastLoggedStatus else { return }
        lastLoggedStatus = s
        log("guest: \(s)")
    }

    // MARK: Running

    func start() {
        log("start: disc=\(options.disc.path) disk=\(options.diskGB)GB language=\(options.language) languages=\(options.additionalLanguages) printers=\(options.printerDrivers) fonts=\(options.additionalFonts) update=\(options.update10411)")
        if options.update10411 { fetchCombo() }
        setStep(0, "Erasing “Macintosh HD”", "Mac OS Extended (Journaled), \(options.diskGB) GB")
        let opts = options
        let dest = setupDisc
        let box = mailbox
        let disk = vm.config.startupDiskConfig.map { vm.disksURL.appendingPathComponent($0.file) }
        let qemuImg = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img")
        Task.detached {
            do {
                if let disk, let qemuImg {
                    try InstallPlan.formatDisk(disk, gigabytes: opts.diskGB, qemuImg: qemuImg)
                    await MainActor.run {
                        self.log("erased on the host: \(disk.lastPathComponent)")
                        self.detail = "Preparing your install disc"
                    }
                }
                let p = try InstallPlan.prepare(opts, to: dest)
                try InstallPlan.writeMailbox(box, diskGB: opts.diskGB, update: opts.update10411)
                await MainActor.run {
                    self.log("prepared: \(p.packages.count) packages, \(p.expectedKB) KB: " + p.packages.map(\.name).joined(separator: ","))
                    self.prepared = p; self.runInstaller()
                }
            } catch {
                await MainActor.run { self.fail("The installer could not be prepared. \(error.localizedDescription)") }
            }
        }
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func cancel() {
        guard outcome == .running else { return }
        log("cancelled")
        outcome = .cancelled
        download?.cancel()
        runner?.terminate()
        runner = nil
        finishCleanup(keepMachine: true)
        failure = "Installation stopped. You can move this virtual Mac to the Trash, or make a new one."
    }

    /// Phase 1: boot the prepared disc; the Installer runs by itself and
    /// restarts at the end, which with -no-reboot ends the emulator.
    private func runInstaller() {
        guard outcome == .running, let prepared else { return }
        setStep(1, "Starting the Mac OS X Installer", "Starting up from the install disc")
        var c = headlessConfig()
        c.insertedDisc = prepared.disc.path
        c.bootFromDisc = true
        launch(c) { [weak self] _ in self?.installerEnded() }
    }

    private func installerEnded() {
        guard outcome == .running else { return }
        let box = InstallPlan.readMailbox(mailbox)
        guestLog = box.log
        let expected = prepared?.expectedKB ?? 0
        let used = (box.usedKB ?? 0) - baseUsedKB
        log("installer ended: status=\(box.status) used=\(used)KB expected=\(expected)KB")
        guard box.status.hasPrefix("PARTOK"), used > expected * 8 / 10 else {
            fail(installerFailure(box))
            return
        }
        if options.update10411 {
            if !box.status.contains("COMBOITEM") {
                note = "The 10.4.11 update could not be set up, so this Mac has Mac OS X \(installedVersion)."
                finishInstall()
            } else {
                runUpdateWhenReady()
            }
        } else {
            finishInstall()
        }
    }

    /// Phase 2 (optional): start "Macintosh HD" with the update disc in the
    /// drive; PowerEmu's StartupItem installs it and powers off.
    private func runUpdateWhenReady() {
        guard outcome == .running else { return }
        setStep(3, "Getting the Mac OS X 10.4.11 update", "")
        if let err = comboError {
            note = "The 10.4.11 update was left out (\(err)). This Mac has Mac OS X \(installedVersion); you can update it later from Software Update’s download page."
            removeUpdateItemAndFinish()
            return
        }
        guard let combo else {
            // Still downloading: tick() calls back here when it lands.
            detail = "Waiting for the download from Apple"
            return
        }
        setStep(3, "Starting up for the update", "Starting Mac OS X from “Macintosh HD”")
        var c = headlessConfig()
        c.insertedDisc = combo.path
        c.bootFromDisc = false
        c.vramMB = 64
        launch(c) { [weak self] _ in self?.updateEnded() }
    }

    private func updateEnded() {
        guard outcome == .running else { return }
        let box = InstallPlan.readMailbox(mailbox)
        guestLog = box.log
        log("update ended: status=\(box.status)")
        if box.status == "COMBOOK" {
            vm.config.osName = "Mac OS X 10.4.11 Tiger"
            runFinishingBoot()
            return
        } else if box.status == "COMBONODISC" || box.status.isEmpty || box.status.hasPrefix("PARTOK") {
            note = "The 10.4.11 update didn’t run, so this Mac has Mac OS X \(installedVersion)."
        } else {
            note = "The 10.4.11 update didn’t finish (\(box.status.replacingOccurrences(of: "COMBO", with: "").trimmingCharacters(in: .whitespaces))). This Mac has Mac OS X \(installedVersion)."
        }
        finishInstall()
    }

    /// After the update: start the machine cold, headless, until the update
    /// item reports it's done. Apple's startup-time step restarts the Mac
    /// once to move the new system files into place; headless, that restart
    /// ends the emulator and the next start here is a cold one. (A warm
    /// restart right there has been seen to hang in BootX.)
    private func runFinishingBoot() {
        guard outcome == .running else { return }
        finishing = true
        finishingBoots += 1
        setStep(3, "Finishing the 10.4.11 update", "Mac OS X is putting the updated system files in place")
        var c = headlessConfig()
        c.insertedDisc = nil
        c.bootFromDisc = false
        c.vramMB = 64
        launch(c) { [weak self] _ in self?.finishingEnded() }
    }

    private func finishingEnded() {
        guard outcome == .running else { return }
        let box = InstallPlan.readMailbox(mailbox)
        log("finishing boot \(finishingBoots) ended: status=\(box.status)")
        if box.status == "COMBODONE" { finishInstall(); return }
        if finishingBoots < 4 { runFinishingBoot(); return }
        note = "The 10.4.11 update is installed; Mac OS X may take a little longer on its first startup while it finishes."
        finishInstall()
    }

    /// The update was chosen but can't happen: the item is already on the
    /// disk and would wait for a disc forever, so let it run once with no
    /// disc -- it finds none, removes itself and powers off.
    private func removeUpdateItemAndFinish() {
        setStep(3, "Tidying up", "Removing the update step")
        var c = headlessConfig()
        c.insertedDisc = nil
        c.bootFromDisc = false
        c.vramMB = 64
        launch(c) { [weak self] _ in self?.finishInstall() }
    }

    /// Put the machine back the way the reader will use it and start it.
    private func finishInstall() {
        guard outcome == .running else { return }
        log("finished\(note.map { ": " + $0 } ?? "")")
        setStep(steps.count - 1, "Starting Mac OS X", "")
        fraction = 1
        remaining = 0
        finishCleanup(keepMachine: true)
        if let tools = VirtualMachine.toolsDiscURL { vm.config.insertedDisc = tools.path }
        try? vm.save()
        outcome = .finished
        vm.start()
        onFinish?()
    }

    private func finishCleanup(keepMachine: Bool) {
        poll?.invalidate()
        poll = nil
        guard FileManager.default.fileExists(atPath: vm.url.path) else { return }
        vm.config.disks.removeAll { $0.file == mailbox.lastPathComponent }
        vm.config.bootFromDisc = false
        if vm.config.insertedDisc == setupDisc.path { vm.config.insertedDisc = nil }
        try? vm.save()
        try? FileManager.default.removeItem(at: setupDisc)
        try? FileManager.default.removeItem(at: mailbox)
    }

    private func fail(_ message: String) {
        guard outcome == .running else { return }
        log("FAILED: \(message)")
        outcome = .failed
        failure = message
        download?.cancel()
        runner?.terminate()
        runner = nil
        finishCleanup(keepMachine: true)
    }

    private var installedVersion: String {
        vm.config.osName.replacingOccurrences(of: "Mac OS X ", with: "").replacingOccurrences(of: " Tiger", with: "")
    }

    private func installerFailure(_ box: InstallPlan.MailboxState) -> String {
        switch box.status {
        case "": return "The install disc didn’t start. Check that it is a Mac OS X 10.4 install DVD for PowerPC Macs."
        case let s where s.hasPrefix("NOTARGET"): return "The new disk wasn’t found by the installer."
        case let s where s.hasPrefix("PARTFAIL"): return "The installer couldn’t use “Macintosh HD”."
        default: return "The installer stopped before Mac OS X was installed."
        }
    }

    // MARK: The emulator

    /// This machine's settings for an unattended run: no screen, sound or
    /// network, and the mailbox as a second disk.
    private func headlessConfig() -> VMConfig {
        var c = vm.config
        c.network = false
        c.audio = "none"
        c.monitorPort = nil
        c.sshPort = nil
        c.bootChime = false
        c.singleUser = false
        c.safeBoot = false
        c.verboseBoot = false
        if !c.disks.contains(where: { $0.file == mailbox.lastPathComponent }) {
            c.disks.append(DiskConfig(file: mailbox.lastPathComponent, label: "PowerEmu Setup"))
        }
        return c
    }

    private func launch(_ config: VMConfig, onExit: @escaping (Int32) -> Void) {
        log("emulator: disc=\(config.insertedDisc ?? "none") bootFromDisc=\(config.bootFromDisc) vram=\(config.vramMB)")
        let temp = VirtualMachine(url: vm.url, config: config)
        let r = VMRunner(vm: temp)
        r.headless = true
        runner = r
        do {
            try r.launch { status in
                Task { @MainActor [weak self] in
                    guard let self, self.runner === r else { return }
                    self.log("emulator exited: \(status)")
                    self.runner = nil
                    onExit(status)
                }
            }
        } catch {
            fail("The emulator could not start. \(error.localizedDescription)")
        }
    }

    // MARK: Progress

    private func setStep(_ i: Int, _ t: String, _ d: String) {
        if i != stepIndex { stepStarted = Date() }
        stepIndex = i
        title = t
        detail = d
    }

    private func clampSpeed(_ measured: Double, weight: Double) -> Double {
        let m = min(max(measured, 0.4), 4)
        return speed * (1 - weight) + m * weight
    }

    private func tick() {
        guard outcome == .running else { return }
        // Its package went to the Trash (from this or another copy of
        // PowerEmu): stop, and leave nothing behind.
        if !FileManager.default.fileExists(atPath: vm.url.path) {
            NSLog("PowerEmu install: machine removed, stopping")
            outcome = .cancelled
            download?.cancel()
            runner?.terminate()
            runner = nil
            poll?.invalidate()
            poll = nil
            return
        }
        if let d = download, combo == nil, comboError == nil {
            downloadProgress = (d.received, d.expected)
            updateSource = d.received > 0
                ? "Apple’s 10.4.11 update: downloading from Apple, \(Self.mb(d.received)) of \(Self.mb(d.expected))"
                : "Apple’s 10.4.11 update: starting download from Apple"
        }
        switch stepIndex {
        case 1, 2: tickInstaller()
        case 3: tickUpdate()
        default: break
        }
        watchForHang()
        updateEstimate()
    }

    private func tickInstaller() {
        let box = InstallPlan.readMailbox(mailbox)
        logStatus(box.status)
        let expected = max(prepared?.expectedKB ?? 1, 1)
        let now = Date()
        // The guest gave up: say so now, not when someone notices.
        if box.status.hasPrefix("PARTFAIL") || box.status.hasPrefix("NOTARGET") || box.status.hasPrefix("NOSIZE") {
            guestLog = box.log
            fail(installerFailure(box))
            return
        }
        if box.status.isEmpty {
            setStep(1, "Starting the Mac OS X Installer", "Starting up from the install disc")
            return
        }
        guard box.status.hasPrefix("PARTOK"), let usedRaw = box.usedKB else {
            setStep(1, "Starting the Mac OS X Installer", "Finding “Macintosh HD”")
            return
        }
        if baseUsedKB == 0 { baseUsedKB = usedRaw }
        let used = max(usedRaw - baseUsedKB, 0)
        if let last = lastUsed, usedRaw > last.kb {
            lastGrowth = now
            let dt = now.timeIntervalSince(last.at)
            if dt > 0 {
                let r = Double(usedRaw - last.kb) / dt
                writeRate = writeRate.map { $0 * 0.85 + r * 0.15 } ?? r
            }
        }
        if lastUsed?.kb != usedRaw { lastUsed = (usedRaw, now) }

        if used < 2048 {
            setStep(1, "Starting the Mac OS X Installer", "“Macintosh HD” is ready; the Installer is loading")
            return
        }
        if writeStarted == nil {
            writeStarted = now
            speed = clampSpeed(now.timeIntervalSince(stepStarted) / InstallTiming.startInstaller, weight: 0.5)
        }
        let frac = min(Double(used) / Double(expected), 1)
        if frac > 0.97 || (filesDone == nil && frac > 0.85 && now.timeIntervalSince(lastGrowth) > 25) {
            if filesDone == nil { filesDone = now }
            setStep(2, "Finishing the installation", "Optimizing system performance, then restarting")
        } else {
            setStep(2, "Installing \(currentPackage(usedKB: used))",
                    "\(Self.gb(used)) of \(Self.gb(expected)) written to “Macintosh HD”")
        }
    }

    private func tickUpdate() {
        guard combo != nil || comboError != nil else {
            if let p = downloadProgress, p.total > 0 {
                detail = "Downloading from Apple: \(Self.mb(p.done)) of \(Self.mb(p.total))"
            }
            return
        }
        guard runner != nil else { return }
        let box = InstallPlan.readMailbox(mailbox)
        let s = box.status
        if s.hasPrefix("COMBO") && !s.contains("Completed") { logStatus(s) }
        if finishing {
            if s.hasPrefix("COMBOFINISH") || s == "COMBODONE" {
                setStep(3, "Finishing the 10.4.11 update", "Rebuilding the kernel extension cache")
            }
            return
        }
        guard s.hasPrefix("COMBO") else {
            // Still starting up: the item hasn't spoken yet.
            // The item speaks within a few minutes of starting up.
            if Date().timeIntervalSince(stepStarted) > 6 * 60 * speed + 60 {
                note = "The 10.4.11 update didn’t start, so this Mac has Mac OS X \(installedVersion)."
                runner?.terminate()
            }
            return
        }
        if let r = s.range(of: #"(\d+)% Completed"#, options: .regularExpression) {
            let pct = Double(s[r].prefix { $0.isNumber }) ?? 0
            if updatePercentStarted == nil {
                updatePercentStarted = (Date(), pct)
                speed = clampSpeed(Date().timeIntervalSince(stepStarted) / InstallTiming.startUpdate, weight: 0.3)
            }
            updatePct = pct / 100
            setStep(3, "Installing the Mac OS X 10.4.11 update", "Installing the update: writing files, \(Int(pct))%")
        } else if s.contains("Optimiz") || s.contains("Finishing") {
            if updateOptimizing == nil { updateOptimizing = Date() }
            updatePct = 1
            setStep(3, "Finishing the 10.4.11 update", "Installing the update: optimizing system performance")
        } else if s == "COMBOOK" || s == "COMBOFAIL" || s == "COMBONODISC" {
            setStep(3, "Shutting down", "The update is done; restarting into Mac OS X")
        } else {
            setStep(3, "Preparing the 10.4.11 update", "")
        }
    }

    /// While the guest should be writing (installing files or the update),
    /// minutes with no change to its disk mean it has stopped. Say so
    /// early, then give up with an explanation rather than a frozen clock.
    private func watchForHang() {
        guard runner != nil, stepIndex == 2 || (stepIndex == 3 && combo != nil) else {
            diskChanged = Date(); slow = false; return
        }
        let disk = vm.config.startupDiskConfig.map { vm.disksURL.appendingPathComponent($0.file) }
        let m = disk.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path)[.modificationDate] as? Date }
        if m != diskStamp { diskStamp = m; diskChanged = Date() }
        let idle = Date().timeIntervalSince(diskChanged)
        slow = idle > 3 * 60 * speed
        if idle > 10 * 60 * speed {
            log("no disk activity for \(Int(idle))s: giving up")
            fail(stepIndex == 3
                 ? "The 10.4.11 update stopped responding. Mac OS X itself installed; you can move this virtual Mac to the Trash and try again, or turn the update off."
                 : "The installer stopped responding.")
        }
    }

    private func currentPackage(usedKB: Int) -> String {
        guard let pkgs = prepared?.packages, !pkgs.isEmpty else { return "Mac OS X" }
        var sum = 0
        for p in pkgs {
            sum += p.kb
            if usedKB < sum { return InstallPlan.displayName(ofPackage: p.name) }
        }
        return InstallPlan.displayName(ofPackage: pkgs.last!.name)
    }

    /// Whole-install progress and time left: the step in hand from what it
    /// has measured, the steps after it from their baselines times `speed`.
    private func updateEstimate() {
        let now = Date()
        let expected = Double(prepared?.expectedKB ?? 2_000_000)
        let writeTime = expected / InstallTiming.writeKBps
        // Baseline length of each step, scaled.
        var lengths: [Double] = [InstallTiming.prepare, InstallTiming.startInstaller,
                                 writeTime + InstallTiming.finishInstall]
        if options.update10411 {
            lengths.append(InstallTiming.startUpdate + InstallTiming.installUpdate(from: discVersion) + InstallTiming.finishUpdate)
        }
        lengths.append(5)
        lengths = lengths.map { $0 * speed }

        let elapsed = now.timeIntervalSince(stepStarted)
        var leftInStep: Double
        var doneInStep: Double
        switch stepIndex {
        case 2:
            let used = Double(max((lastUsed?.kb ?? 0) - baseUsedKB, 0))
            if let done = filesDone {
                leftInStep = max(InstallTiming.finishInstall * speed - now.timeIntervalSince(done), 15)
            } else {
                let rate = writeRate ?? InstallTiming.writeKBps / speed
                leftInStep = max(expected - used, 0) / max(rate, 100) + InstallTiming.finishInstall * speed
            }
            doneInStep = max(lengths[2] - leftInStep, 0)
        case 3 where options.update10411:
            var left: Double
            if combo == nil, let p = downloadProgress, p.total > 0, p.done > 0 {
                let rate = Double(p.done) / max(now.timeIntervalSince(download?.started ?? now), 1)
                left = Double(p.total - p.done) / max(rate, 1) + lengths[3]
            } else if let opt = updateOptimizing {
                left = max(InstallTiming.finishUpdate * speed + 60 * speed - now.timeIntervalSince(opt), 10)
            } else if let st = updatePercentStarted, updatePct - st.pct / 100 > 0.03 {
                let perUnit = now.timeIntervalSince(st.at) / (updatePct - st.pct / 100)
                left = perUnit * (1 - updatePct) + (60 + InstallTiming.finishUpdate) * speed
            } else {
                left = max(lengths[3] - elapsed, 60)
            }
            leftInStep = left
            doneInStep = max(lengths[3] - left, 0)
        default:
            let len = stepIndex < lengths.count ? lengths[stepIndex] : 0
            leftInStep = max(len - elapsed, min(len * 0.1, 20))
            doneInStep = len - leftInStep
        }
        let after = lengths.dropFirst(stepIndex + 1).reduce(0, +)
        let before = lengths.prefix(stepIndex).reduce(0, +)
        let total = lengths.reduce(0, +)
        let raw = leftInStep + after
        smoothedRemaining = smoothedRemaining.map { $0 * 0.8 + raw * 0.2 } ?? raw
        remaining = smoothedRemaining
        fraction = min(max((before + doneInStep) / max(total, 1), fraction), 0.99)
    }

    // MARK: The update disc

    private func fetchCombo() {
        // Developer testing: POWEREMU_TEST_FORCE_DOWNLOAD=1 ignores copies on this Mac.
        let force = ProcessInfo.processInfo.environment["POWEREMU_TEST_FORCE_DOWNLOAD"] == "1"
        if !force, let found = InstallPlan.existingCombo {
            Task.detached {
                let ok = Self.sha1(of: found) == InstallPlan.comboSHA1
                await MainActor.run {
                    self.log("existing update \(found.path): checksum \(ok ? "ok" : "wrong, downloading")")
                    if ok {
                        self.combo = found
                        self.updateSource = "Apple’s 10.4.11 update: already on this Mac"
                    } else { self.startDownload() }
                }
            }
            return
        }
        startDownload()
    }

    private func startDownload() {
        let d = ComboDownload(to: InstallPlan.comboCacheURL) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let url):
                    self.combo = url; self.log("update downloaded: \(url.path)")
                    self.updateSource = "Apple’s 10.4.11 update: downloaded from Apple"
                case .failure(let e):
                    self.comboError = e.localizedDescription; self.log("update download failed: \(e.localizedDescription)")
                    self.updateSource = "Apple’s 10.4.11 update: download failed"
                }
                self.downloadProgress = nil
                // The install got there first and is waiting.
                if self.stepIndex == 3, self.runner == nil, self.outcome == .running { self.runUpdateWhenReady() }
            }
        }
        download = d
        d.start()
    }

    nonisolated static func sha1(of url: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try? h.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Formatting

    static func gb(_ kb: Int) -> String {
        String(format: "%.1f GB", Double(kb) / 1_048_576)
    }

    static func mb(_ bytes: Int64) -> String {
        "\(bytes / 1_048_576) MB"
    }

    /// "About 12 minutes remaining", the way the Mac OS X Installer says it.
    static func remainingText(_ s: Double?) -> String {
        guard let s else { return "Estimating time remaining…" }
        if s < 50 { return "Less than a minute remaining" }
        let m = Int((s / 60).rounded())
        if m <= 1 { return "About a minute remaining" }
        if m < 60 { return "About \(m) minutes remaining" }
        let h = m / 60, r = m % 60
        return "About \(h) hour\(h == 1 ? "" : "s")\(r >= 5 ? " \(r) minutes" : "") remaining"
    }

    /// "about 15 minutes" for the estimate shown before installing.
    static func durationText(_ s: Double) -> String {
        let m = max(Int((s / 60).rounded()), 1)
        if m < 60 { return "about \(m) minutes" }
        let h = m / 60, r = m % 60
        return "about \(h) hour\(h == 1 ? "" : "s")\(r >= 5 ? " \(r) minutes" : "")"
    }
}

/// Downloads Apple's combo update to the cache, checking its SHA-1.
final class ComboDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let done: (Result<URL, Error>) -> Void
    private var session: URLSession?
    private let lock = NSLock()
    private var _received: Int64 = 0
    private var _expected: Int64 = InstallPlan.comboBytes
    let started = Date()

    var received: Int64 { lock.lock(); defer { lock.unlock() }; return _received }
    var expected: Int64 { lock.lock(); defer { lock.unlock() }; return _expected }

    init(to dest: URL, done: @escaping (Result<URL, Error>) -> Void) {
        self.dest = dest
        self.done = done
    }

    func start() {
        let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        session = s
        s.downloadTask(with: InstallPlan.comboURL).resume()
    }

    func cancel() { session?.invalidateAndCancel() }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        lock.lock()
        _received = totalBytesWritten
        if totalBytesExpectedToWrite > 0 { _expected = totalBytesExpectedToWrite }
        lock.unlock()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let fm = FileManager.default
        do {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                throw InstallError.failed("Apple’s server answered \(http.statusCode)")
            }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? fm.removeItem(at: dest)
            try fm.moveItem(at: location, to: dest)
            guard InstallSession.sha1(of: dest) == InstallPlan.comboSHA1 else {
                try? fm.removeItem(at: dest)
                throw InstallError.failed("the download didn’t match Apple’s checksum")
            }
            done(.success(dest))
        } catch {
            done(.failure(error))
        }
        session.finishTasksAndInvalidate()
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, (error as NSError).code != NSURLErrorCancelled {
            done(.failure(InstallError.failed("the download failed: \(error.localizedDescription)")))
        }
    }
}
