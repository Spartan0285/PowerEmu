import Foundation

/// Starts the bundled QEMU for one virtual Mac and talks to it over QMP.
///
/// The command line mirrors launcher/launch-tiger-ati.sh, which is where each
/// option is explained; keep the two in step.
@MainActor
final class VMRunner {
    /// The lowest processor speed Mac OS X is told (see the boot command).
    static let minReportedMHz = 1420
    private let vm: VirtualMachine
    private var process: Process?
    /// Watches an adopted machine (one this PowerEmu did not start).
    private var adoptWatch: Timer?
    private var qmpPath: String
    /// PowerEmu Tools' socket (GuestAgent listens on it).
    private(set) var agentPath: String
    /// Shared folders' WebDAV socket (WebDAVServer listens on it).
    private(set) var davPath: String
    /// PowerEmu Clock's socket (ClockServer listens on it).
    private(set) var clockPath: String
    /// The screen's socket (DisplayChannel listens on it) when shown in PowerEmu.
    private(set) var displayPath: String
    /// The game controller's socket (GamepadServer listens on it).
    private(set) var gamepadPath: String
    /// Services of the guest offered to the network: guest service to the
    /// port this Mac listens on. Empty unless the reader shares them.
    var sharedPorts: [NetworkShare.Service: Int] = [:]
    /// Where the network helper and the emulator meet, when the guest is
    /// bridged straight on to this Mac's network.
    private(set) var bridgeHelperPath: String
    private(set) var bridgeEmulatorPath: String
    /// The address the network gave the bridge, for the guest's own card.
    var bridgeMAC: String?
    /// The host ports this run uses: the configured ones, or the next free
    /// ones when another virtual Mac (or anything else) has them.
    private(set) var sshPort: Int?
    private(set) var monitorPort: Int?
    /// An unattended run (installing): no screen, and a guest restart ends
    /// the emulator instead of restarting, which is how an install says done.
    var headless = false
    /// Start from the memory saved when the machine was put to sleep,
    /// rather than from the beginning.
    var wake = false
    /// What the saved machine is called inside the disk.
    static let sleepTag = "PowerEmuSleep"

    init(vm: VirtualMachine) {
        self.vm = vm
        // Unix socket paths are limited to 104 bytes; keep it short. The
        // name must be the same in every PowerEmu that ever runs this
        // machine -- that is how one finds a machine another left running
        // -- so it can't come from Swift's hashValue, which is seeded anew
        // in each process.
        let tag = "poweremu-\(Self.tag(for: vm.url.path))"
        qmpPath = NSTemporaryDirectory() + tag + ".qmp"
        agentPath = NSTemporaryDirectory() + tag + ".agent"
        davPath = NSTemporaryDirectory() + tag + ".dav"
        clockPath = NSTemporaryDirectory() + tag + ".clock"
        displayPath = NSTemporaryDirectory() + tag + ".display"
        gamepadPath = NSTemporaryDirectory() + tag + ".pad"
        bridgeHelperPath = NSTemporaryDirectory() + tag + ".net-helper"
        bridgeEmulatorPath = NSTemporaryDirectory() + tag + ".net-guest"
    }

    /// A short, steady name for a machine's sockets: FNV-1a of its path.
    nonisolated static func tag(for path: String) -> String {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in path.utf8 {
            h ^= UInt64(b)
            h &*= 0x0000_0100_0000_01B3
        }
        return String(h % 1_000_000_000, radix: 36)
    }

    /// The first port from `start` that nothing on 127.0.0.1 is using.
    nonisolated static func freePort(from start: Int) -> Int { freePort(from: start, avoiding: nil) }

    nonisolated static func freePort(from start: Int, avoiding other: Int?) -> Int {
        for p in start..<(start + 100) where p != other && p <= 65535 {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return start }
            defer { close(fd) }
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(p).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            let r = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if r == 0 { return p }
        }
        return start
    }

    /// The helper app holding QEMU, its libraries and firmware.
    static var helperURL: URL? {
        let fm = FileManager.default
        var candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/PowerEmu VM.app"),
        ]
        if let env = ProcessInfo.processInfo.environment["POWEREMU_HELPER"] {
            candidates.insert(URL(fileURLWithPath: env), at: 0)
        }
        // Running from the repository (swift run): ../build/PowerEmu VM.app
        candidates.append(URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("build/PowerEmu VM.app"))
        return candidates.first { fm.fileExists(atPath: $0.appendingPathComponent("Contents/MacOS/qemu-system-ppc").path) }
    }

    func arguments(firmware fw: URL) throws -> [String] {
        let c = vm.config
        guard let boot = c.startupDiskConfig else { throw PackageError.missing("A startup disk") }

        // OpenBIOS: fake AGP properties on the PCI path (only used when the
        // AGP bridge is off) and the VRAM size for the QEMU VGA node.
        let vramHex = String(c.vramMB * 1024 * 1024, radix: 16)
        // The processor speed Mac OS X reports is the cpu node's
        // clock-frequency. Programs read it too, and games refuse to run
        // below their minimum (Halo on a 500 MHz "Cube"), so a chosen speed
        // is only ever raised to, never lowered below, 1.42 GHz -- the
        // fastest Power Mac G4. About This Mac shows the chosen speed anyway
        // (PEPersonalize patches its text).
        let cpuSpeed = c.cpuMHz.map { #"" /cpus/PowerPC,G4@0" find-device d# "# + String(max($0, Self.minReportedMHz) * 1_000_000) + #" encode-int " clock-frequency" property device-end "# } ?? ""
        let bootCmd = #"boot-command="# + cpuSpeed + #"" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then " /pci@f2000000/QEMU,VGA@e" ['] find-device catch 0= if h# "# + vramHex + #" encode-int " VRAM,totalsize" property device-end then boot"#

        var a: [String] = [
            "-name", c.name,
            "-L", fw.path, "-nodefaults", "-vga", "none",
            "-smp", "cpus=1,sockets=1,cores=1,threads=1", "-machine", "mac99,via=pmu",
            "-accel", "tcg,tb-size=512", "-g", "\(max(640, c.bootWidth))x\(max(480, c.bootHeight))x32",
            "-device", "loader,addr=0x4000000,file=\(fw.appendingPathComponent("ppc-ndrvloader").path)",
            "-prom-env", bootCmd,
            "-m", String(c.memoryMB),
            "-audio", c.audio,
        ]
        if c.extraDisplayModes { a += ["-global", "ppc-mac-gpu.host-aspect-modes=on"] }
        if !c.verboseBoot {
            // Open Firmware's messages go to the serial log, not the screen:
            // it stays black until the loader draws the grey Apple.
            a += ["-prom-env", "output-device=ttya"]
        }
        if headless {
            a += ["-display", "none", "-no-reboot"]
        } else if c.embeddedDisplay {
            // No window of QEMU's own (and so no second app in the Dock).
            a += ["-display", "none", "-object", "poweremu-display,id=pd0,path=\(displayPath)"]
        } else {
            a += ["-display", "cocoa"]
            if c.startFullscreen { a.append("-full-screen") }
        }

        // No romfile or biosrom: the NDRV comes from ppc-ndrvloader above and
        // the kext binds on the PCI ID. See the note in VMConfig.
        //
        // While installing, cap the card at 64 MB. The Mac OS X 10.4
        // installer hangs with more -- it boots all the way to the point of
        // showing its Language Chooser, then waits forever with the Apple
        // logo on screen, which reads as a freeze at the logo but is not.
        // Measured: 128 MB hangs with the AGP bridge on or off and with or
        // without the ATI ROMs; 64 MB reaches the Language Chooser. An
        // installed system runs fine at the full size, so this only applies
        // while booting from the install disc and the machine keeps whatever
        // the reader chose for afterwards.
        let vram = c.bootFromDisc ? min(c.vramMB, 64) : c.vramMB
        a += ["-device", "ppc-mac-gpu,id=gpu0,vgamem_mb=\(vram)"]

        // The paravirtual GPU, alongside the emulated R200 rather than in
        // place of it: the guest keeps booting and displaying through the
        // R200, and the new device does nothing at all until a guest driver
        // opens it. Opt-in while that driver is being written, so a build
        // that ships cannot be slowed down or destabilised by a device
        // nothing in the guest is asking for yet.
        if ProcessInfo.processInfo.environment["POWEREMU_PARAVIRT_GPU"] == "1" {
            a += ["-device", "poweremu-gpu,id=pvgpu0"]
        }

        if c.network {
            var net = "user,id=net0,ipv6=off"
            sshPort = c.sshPort.map(Self.freePort)
            if let p = sshPort { net += ",hostfwd=tcp:127.0.0.1:\(p)-:22" }
            /*
             * Sharing: the same forwarding, but listening on every address
             * of this Mac rather than only on this Mac itself, so a
             * connection from another machine on the network reaches the
             * guest. Only the services the reader asked to share.
             */
            for (service, host) in sharedPorts.sorted(by: { $0.value < $1.value }) {
                net += ",hostfwd=tcp::\(host)-:\(service.guestPort)"
            }
            // PowerEmu Tools: the guest's connections to 10.0.2.100:7700
            // reach GuestAgent's socket, one nc per connection.
            net += ",guestfwd=tcp:10.0.2.100:7700-cmd:/usr/bin/nc -U \(agentPath)"
            // Shared folders: http://10.0.2.100/ in the guest.
            net += ",guestfwd=tcp:10.0.2.100:80-cmd:/usr/bin/nc -U \(davPath)"
            // The guest's clock daemon asks the time at 10.0.2.100:7701.
            net += ",guestfwd=tcp:10.0.2.100:7701-cmd:/usr/bin/nc -U \(clockPath)"
            // The Service Hub (shared by all virtual Macs): mail at
            // 10.0.2.100 on the standard IMAP and SMTP ports.
            net += ",guestfwd=tcp:10.0.2.100:143-cmd:/usr/bin/nc -U \(ServicesHub.imapSocket)"
            net += ",guestfwd=tcp:10.0.2.100:25-cmd:/usr/bin/nc -U \(ServicesHub.smtpSocket)"
            net += ",guestfwd=tcp:10.0.2.100:587-cmd:/usr/bin/nc -U \(ServicesHub.smtpSocket)"
            net += ",guestfwd=tcp:10.0.2.100:7780-cmd:/usr/bin/nc -U \(ServicesHub.webSocket)"
            // PowerMusic: the controller in Mac OS X finds this Mac's music
            // at 10.0.2.100:3001.  Always forwarded, like the mail and the
            // web; whether anything answers is the Service Hub's switch.
            net += ",guestfwd=tcp:10.0.2.100:3001-cmd:/usr/bin/nc -U \(ServicesHub.musicSocket)"
            a += ["-netdev", net, "-device", "sungem,netdev=net0"]
            /*
             * Bridged: a second card, straight on to this Mac's network
             * through the helper. The first card stays, because PowerEmu's
             * own services -- shared folders, the clipboard, the clock --
             * live on it at a fixed address the guest already knows.
             */
            if c.bridgedInterface != nil {
                unlink(bridgeEmulatorPath)
                a += ["-netdev", "dgram,id=net1,local.type=unix,local.path=\(bridgeEmulatorPath)"
                                + ",remote.type=unix,remote.path=\(bridgeHelperPath)"]
                var dev = "sungem,netdev=net1"
                if let mac = bridgeMAC { dev += ",mac=\(mac)" }
                a += ["-device", dev]
            }
        } else {
            a += ["-nic", "none"]
        }
        if c.agpBridge { a += ["-global", "uni-north-pci.agp-capable=on"] }
        if !c.bootArgs.isEmpty { a += ["-prom-env", "boot-args=\(c.bootArgs)"] }

        // Both pointing devices: the tablet takes absolute positions (seamless
        // mouse), the mouse relative movement (captured, for games).
        a += ["-usb", "-device", "usb-mouse,bus=usb-bus.0", "-device", "usb-tablet,bus=usb-bus.0",
              "-device", "usb-kbd,bus=usb-bus.0"]
        // A game controller of this Mac, as a USB gamepad in the guest
        // (GamepadServer listens on the socket; the device dials in).
        if c.gamepad {
            a += ["-device", "poweremu-gamepad,bus=usb-bus.0,path=\(gamepadPath)"]
        }

        // IDE: two buses with two units each.  The startup disk goes first on
        // ide.0; the CD/DVD drive (always present, so discs can be inserted
        // while running) takes the first slot on ide.1; other disks fill in.
        var slots = ["bus=ide.0,unit=0", "bus=ide.1,unit=0", "bus=ide.0,unit=1", "bus=ide.1,unit=1"]
        let hdOrder = [boot] + c.hardDisks.filter { $0.id != boot.id }
        let bootCD = c.bootFromDisc && c.insertedDisc != nil
        // startup disk
        a += hdDrive(hdOrder[0], index: 0, slot: slots.removeFirst(), bootIndex: bootCD ? 1 : 0)
        // CD/DVD drive
        let cdSlot = slots.removeFirst()
        var cd = "if=none,id=cd0,media=cdrom,readonly=on"
        if let disc = c.insertedDisc {
            cd += ",file.filename=\(disc),format=\(VMConfig.imageFormat(disc))"
        }
        a += ["-drive", cd, "-device", "ide-cd,\(cdSlot),drive=cd0,id=cd0dev" + (bootCD ? ",bootindex=0" : "")]
        for (i, d) in hdOrder.dropFirst().prefix(slots.count).enumerated() {
            a += hdDrive(d, index: i + 1, slot: slots[i], bootIndex: nil)
        }

        a += ["-serial", "file:\(vm.logsURL.appendingPathComponent("console.log").path)"]
        a += ["-qmp", "unix:\(qmpPath),server=on,wait=off"]
        monitorPort = c.monitorPort.map { Self.freePort(from: $0, avoiding: sshPort) }
        if let p = monitorPort { a += ["-monitor", "telnet:127.0.0.1:\(p),server,nowait"] }
        a += ["-trace", c.gpuTrace ? "ppc_mac_gpu_*" : "ppc_mac_gpu_realize",
              "-D", vm.logsURL.appendingPathComponent("gpu-trace.log").path]
        // Waking: the machine's memory was written into its startup disk
        // when it went to sleep, and the emulator loads it instead of
        // starting Mac OS X afresh.
        if wake { a += ["-loadvm", Self.sleepTag] }
        a += c.extraQEMUArgs
        return a
    }

    private func hdDrive(_ d: DiskConfig, index i: Int, slot: String, bootIndex: Int?) -> [String] {
        let path = vm.disksURL.appendingPathComponent(d.file).path
        var drive = "if=none,id=drive\(i),file.filename=\(path),format=\(VMConfig.imageFormat(d.file))"
        drive += ",media=disk,discard=unmap,detect-zeroes=unmap"
        if d.readOnly || VMConfig.imageFormat(d.file) == "dmg" { drive += ",readonly=on" }
        var dev = "ide-hd,\(slot),drive=drive\(i)"
        if let b = bootIndex { dev += ",bootindex=\(b)" }
        return ["-drive", drive, "-device", dev]
    }

    func launch(onExit: @escaping @Sendable (Int32) -> Void) throws {
        guard let helper = Self.helperURL else { throw PackageError.missing("The emulator (PowerEmu VM.app)") }
        let fw = helper.appendingPathComponent("Contents/Resources/firmware")
        try FileManager.default.createDirectory(at: vm.logsURL, withIntermediateDirectories: true)
        unlink(qmpPath)

        let p = Process()
        p.executableURL = helper.appendingPathComponent("Contents/MacOS/qemu-system-ppc")
        p.arguments = try arguments(firmware: fw)
        var env = ProcessInfo.processInfo.environment
        if vm.config.hardwareCursor {
            env["QEMU_PPC_NDRV"] = fw.appendingPathComponent("qemu_vga_hwc.ndrv").path
        } else {
            env.removeValue(forKey: "QEMU_PPC_NDRV")
        }
        p.environment = env
        let log = vm.logsURL.appendingPathComponent("qemu.log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let h = try FileHandle(forWritingTo: log)
        h.write(("PowerEmu: " + ([p.executableURL!.path] + p.arguments!).joined(separator: " ") + "\n\n").data(using: .utf8)!)
        p.standardOutput = h
        p.standardError = h
        p.terminationHandler = { proc in onExit(proc.terminationStatus) }
        try p.run()
        process = p
    }

    /// Whether an emulator for this machine is already running: its QMP
    /// socket answers.  A virtual Mac outlives a PowerEmu that crashed, and
    /// its sockets are named after the machine, so the next PowerEmu can
    /// find it again (see `adopt`).  Older PowerEmus named them otherwise,
    /// so the emulator's own command line is read as a fallback.
    func isLeftRunning() -> Bool {
        if Self.canConnect(qmpPath) { return true }
        guard let args = Self.runningEmulatorArguments(for: vm) else { return false }
        func value(_ suffix: String) -> String? {
            args.first { $0.contains("poweremu-") && $0.contains(suffix) }?
                .replacingOccurrences(of: "unix:", with: "")
                .split(separator: ",").first.map(String.init)
        }
        guard let qmp = value(".qmp"), Self.canConnect(qmp) else { return false }
        qmpPath = qmp
        agentPath = value(".agent") ?? agentPath
        davPath = value(".dav") ?? davPath
        clockPath = value(".clock") ?? clockPath
        displayPath = value(".display") ?? displayPath
        return true
    }

    /// The command line of an emulator running this machine's startup disk.
    private static func runningEmulatorArguments(for vm: VirtualMachine) -> [String]? {
        guard let disk = vm.config.startupDiskConfig?.file else { return nil }
        let wanted = vm.disksURL.appendingPathComponent(disk).path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "args="]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        for line in text.split(separator: "\n") where line.contains("qemu-system-ppc") && line.contains(wanted) {
            return line.split(separator: " ").map(String.init)
        }
        return nil
    }

    nonisolated static func canConnect(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return false }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        return withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }

    /// Take charge of an emulator that is already running (PowerEmu was
    /// quit unexpectedly while it ran).  Nothing is started; the machine is
    /// watched instead, and `onExit` is called when it goes.
    func adopt(onExit: @escaping @Sendable (Int32) -> Void) {
        adoptWatch?.invalidate()
        let path = qmpPath
        adoptWatch = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { t in
            guard !Self.canConnect(path) else { return }
            t.invalidate()
            onExit(0)
        }
    }

    /*
     * Sleep: the whole machine -- memory, processor, devices -- is written
     * into the startup disk, and the emulator then quits.  Starting again
     * with -loadvm puts it back exactly where it was, so a reader can shut
     * the app without losing what was open.
     *
     * This is QEMU's own savevm, driven through the monitor because it
     * picks the disk to write into by itself.  It takes a moment: the
     * machine's memory is gigabytes.
     */
    func sleep(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "human-monitor-command",
                                  "arguments": ["command-line": "savevm \(Self.sleepTag)"]]) { r in
            if let err = QMP.errorText(r) { done(err); return }
            // The monitor reports its own failures in the returned text.
            let text = (r?["return"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            done(text.isEmpty ? nil : text)
        }
    }

    /// Throw away the saved machine while the emulator is running it: a
    /// tool on this Mac cannot touch a disk the machine holds, so the
    /// emulator does it through the monitor.
    func forgetSleep() {
        QMP.shared.send(qmpPath, ["execute": "human-monitor-command",
                                  "arguments": ["command-line": "delvm \(Self.sleepTag)"]])
    }

    /// The same, for a machine that is not running.
    static func forgetSleep(disk: URL, qemuImg: URL, done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .utility).async {
            _ = try? InstallPlan.run(qemuImg.path, ["snapshot", "-d", sleepTag, disk.path])
            done()
        }
    }

    /// Whether a machine was left asleep in this disk.
    nonisolated static func hasSleep(disk: URL, qemuImg: URL) -> Bool {
        guard let out = try? InstallPlan.run(qemuImg.path, ["snapshot", "-l", disk.path]) else { return false }
        return String(decoding: out, as: UTF8.self).contains(sleepTag)
    }

    /// Whether the machine is running or paused right now, as the
    /// emulator sees it: a machine taken back after PowerEmu restarted may
    /// have been left paused.
    func askIfPaused(_ done: @escaping @Sendable (Bool) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "query-status"]) { reply in
            let ret = reply?["return"] as? [String: Any]
            done((ret?["status"] as? String) == "paused")
        }
    }

    /// Stop the guest's processor where it stands, and let it go again.
    /// Nothing inside the virtual Mac runs while it is paused: the screen
    /// holds its last frame and no time passes for the guest.
    func pause(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "stop"]) { r in done(QMP.errorText(r)) }
    }

    func resume(_ done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "cont"]) { r in done(QMP.errorText(r)) }
    }

    /// Whether the machine is still there: the process we started, or -- for
    /// one we adopted -- something still answering on its socket.
    func isAlive() -> Bool {
        if let p = process { return p.isRunning }
        return Self.canConnect(qmpPath)
    }

    func pressPowerKey() {
        QMP.shared.send(qmpPath, ["execute": "send-key",
                                  "arguments": ["keys": [["type": "qcode", "data": "power"]]]])
    }

    /// Give a USB device of this Mac to the guest (QEMU usb-host), or take
    /// it back.  `done` gets an error to show, or nil.
    func attachUSB(_ d: HostUSBDevice, done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "device_add",
                                  "arguments": ["driver": "usb-host", "id": d.id, "bus": "usb-bus.0",
                                                "vendorid": d.vendor, "productid": d.product]]) { r in
            done(QMP.errorText(r))
        }
    }

    func detachUSB(_ id: String, done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "device_del", "arguments": ["id": id]]) { r in
            done(QMP.errorText(r))
        }
    }

    func terminate() {
        adoptWatch?.invalidate()
        adoptWatch = nil
        QMP.shared.send(qmpPath, ["execute": "quit"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let p = self?.process, p.isRunning { p.terminate() }
        }
    }

    /// Put a disc image in the CD/DVD drive.  A disc already in it is
    /// ejected first, asking Mac OS X as the Eject button does.
    func insertDisc(_ path: String, done: @escaping @Sendable (String?) -> Void) {
        let qmp = qmpPath
        ejectDisc { err in
            if let err { done(err); return }
            QMP.shared.send(qmp, ["execute": "blockdev-change-medium",
                                  "arguments": ["id": "cd0dev", "filename": path,
                                                "format": VMConfig.imageFormat(path),
                                                "read-only-mode": "read-only"]]) { reply in
                done(QMP.errorText(reply))
            }
        }
    }

    /// Put a host device (already opened, e.g. by authopen) in the drive.
    /// QEMU gets the open file over the socket (an fdset) and reads it with
    /// its host_device driver, the one for raw disks.
    func insertDevice(fd: Int32, done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        ejectDisc { err in
            if let err { done(err); return }
            QMP.shared.send(path, ["execute": "add-fd"], passing: fd) { reply in
                guard let r = reply?["return"] as? [String: Any], let set = r["fdset-id"] as? Int else {
                    done(QMP.errorText(reply) ?? "The emulator did not accept the drive.")
                    return
                }
                QMP.shared.sequence(path, [
                    ["execute": "blockdev-add",
                     "arguments": ["driver": "raw", "node-name": Self.hostNode, "read-only": true,
                                   "file": ["driver": "host_device", "filename": "/dev/fdset/\(set)",
                                            "read-only": true]]],
                    ["execute": "blockdev-insert-medium", "arguments": ["id": "cd0dev", "node-name": Self.hostNode]],
                    ["execute": "blockdev-close-tray", "arguments": ["id": "cd0dev"]],
                ]) { err in
                    if err != nil { Self.releaseHostDevice(path) }
                    done(err)
                }
            }
        }
    }

    /// The block node for a host drive; one drive, so one name.
    nonisolated static let hostNode = "hostdrive"

    /// Close a host drive that has left the virtual drive.  Harmless when
    /// there is none.
    nonisolated static func releaseHostDevice(_ path: String, done: (@Sendable () -> Void)? = nil) {
        QMP.shared.send(path, ["execute": "blockdev-del", "arguments": ["node-name": hostNode]]) { _ in
            QMP.shared.send(path, ["execute": "query-fdsets"]) { reply in
                let sets = (reply?["return"] as? [[String: Any]] ?? []).compactMap { $0["fdset-id"] as? Int }
                for id in sets {
                    QMP.shared.send(path, ["execute": "remove-fd", "arguments": ["fdset-id": id]])
                }
                QMP.shared.send(path, ["execute": "query-status"]) { _ in done?() }
            }
        }
    }

    /// Eject the way a Mac does: while Mac OS X has the disc mounted it keeps
    /// the tray locked.  Mac OS X never looks at the drive's own eject
    /// request, so PowerEmu holds down F12 - the eject key on keyboards
    /// without one - and Mac OS X unmounts the disc and opens the tray; then
    /// the disc can be taken out.  Only `force` pulls it regardless (the
    /// guest may be left with a stale mount).
    func ejectDisc(force: Bool = false, done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        let pull: @Sendable () -> Void = {
            QMP.shared.send(path, ["execute": "eject", "arguments": ["id": "cd0dev", "force": force]]) { r in
                if let e = QMP.errorText(r) { done(e) } else { Self.releaseHostDevice(path) { done(nil) } }
            }
        }
        if force { pull(); return }
        Self.driveState(path) { inserted, locked in
            // Empty: just open the tray (inserting needs it open).
            guard inserted else { pull(); return }
            // Mac OS X locks the tray while the disc is mounted, but not
            // always, so ask it every time; an unlocked drive whose disc Mac
            // OS X doesn't answer for is simply opened.
            QMP.shared.send(path, ["execute": "send-key",
                                   "arguments": ["keys": [["type": "qcode", "data": "f12"]], "hold-time": 1500]]) { _ in }
            Self.waitForTray(path, tries: locked ? 20 : 4) { opened in
                if opened {
                    QMP.shared.send(path, ["execute": "blockdev-remove-medium", "arguments": ["id": "cd0dev"]]) { r in
                        if let e = QMP.errorText(r) { done(e) } else { Self.releaseHostDevice(path) { done(nil) } }
                    }
                } else if !locked {
                    pull()
                } else {
                    done(Self.discInUse)
                }
            }
        }
    }

    nonisolated static let discInUse = "Mac OS X is still using the disc. Quit programs using it, or drag it to the Trash in the virtual Mac, then eject again."

    /// Whether the drive holds a disc, and whether the guest has locked it.
    private nonisolated static func driveState(_ path: String, done: @escaping @Sendable (Bool, Bool) -> Void) {
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            done(cd?["inserted"] != nil, cd?["locked"] as? Bool ?? false)
        }
    }

    private nonisolated static func waitForTray(_ path: String, tries: Int, done: @escaping @Sendable (Bool) -> Void) {
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            if cd?["tray_open"] as? Bool == true || cd?["inserted"] == nil { done(true); return }
            if tries <= 0 { done(false); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { waitForTray(path, tries: tries - 1, done: done) }
        }
    }

    /// The emulator process, for the overlay's host-side sampling. nil when
    /// no VM is running, which the overlay shows as no host figures rather
    /// than as zeroes -- a zero reads as "idle", which is a different claim.
    var qemuPID: pid_t? {
        guard let p = process, p.isRunning else { return nil }
        return p.processIdentifier
    }

    /// The GPU model's running totals ("frames=… draws=… …"), for the
    /// performance overlay.
    func queryPerf(done: @escaping @Sendable (String?) -> Void) {
        QMP.shared.send(qmpPath, ["execute": "qom-get",
                                  "arguments": ["path": "/machine/peripheral/gpu0", "property": "perf"]]) { reply in
            done(reply?["return"] as? String)
        }
    }

    /// What is in the drive now (the guest can eject it): the image path,
    /// "" for a host device, nil when empty.
    func queryDisc(done: @escaping @Sendable (String?) -> Void) {
        let path = qmpPath
        QMP.shared.send(path, ["execute": "query-block"]) { reply in
            let devs = reply?["return"] as? [[String: Any]] ?? []
            let cd = devs.first { ($0["qdev"] as? String)?.contains("cd0dev") == true || ($0["device"] as? String) == "cd0" }
            let ins = cd?["inserted"] as? [String: Any]
            // Mac OS X ejected it (the disc was dragged to the Trash): the
            // tray stands open with the disc in it, so take it out.
            if ins != nil, cd?["tray_open"] as? Bool == true {
                QMP.shared.send(path, ["execute": "blockdev-remove-medium", "arguments": ["id": "cd0dev"]]) { _ in
                    Self.releaseHostDevice(path) { done(nil) }
                }
                return
            }
            let file = ins?["file"] as? String
            done(file.map { $0.hasPrefix("/dev/fdset") ? "" : $0 })
        }
    }
}

/// QMP client: one short connection per command, serialized.  Commands can
/// carry a file descriptor (SCM_RIGHTS), which is how add-fd receives host
/// devices the emulator could not open itself.
final class QMP: @unchecked Sendable {
    static let shared = QMP()
    private let queue = DispatchQueue(label: "poweremu.qmp")

    /// Send commands one after another, stopping at the first error.
    func sequence(_ socketPath: String, _ commands: [[String: Any]],
                  done: @escaping @Sendable (String?) -> Void) {
        guard let first = commands.first else { done(nil); return }
        send(socketPath, first) { reply in
            if let err = Self.errorText(reply) { done(err); return }
            self.sequence(socketPath, Array(commands.dropFirst()), done: done)
        }
    }

    static func errorText(_ reply: [String: Any]?) -> String? {
        guard let reply else { return "The emulator did not answer." }
        if let e = reply["error"] as? [String: Any] { return e["desc"] as? String ?? "Error" }
        return nil
    }

    func send(_ socketPath: String, _ command: [String: Any], passing fd: Int32 = -1,
              reply: (@Sendable ([String: Any]?) -> Void)? = nil) {
        queue.async {
            let r = Self.exchange(socketPath, command, fd: fd)
            if let reply { DispatchQueue.main.async { reply(r) } }
        }
    }

    private static func exchange(_ path: String, _ command: [String: Any], fd passFD: Int32) -> [String: Any]? {
        let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0 else { return nil }
        // Commands wait for the emulator's big lock, which a busy guest can
        // hold for a while.
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var pending = Data()
        func readMessage() -> [String: Any]? {
            // QMP messages are JSON objects, one per line; skip events.
            while true {
                if let nl = pending.firstIndex(of: 0x0a) {
                    let line = pending[pending.startIndex..<nl]
                    pending.removeSubrange(pending.startIndex...nl)
                    if let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] {
                        if obj["event"] != nil { continue }
                        return obj
                    }
                    continue
                }
                var buf = [UInt8](repeating: 0, count: 8192)
                let n = read(fd, &buf, buf.count)
                if n <= 0 { return nil }
                pending.append(contentsOf: buf[0..<n])
            }
        }
        func write(_ obj: [String: Any], fd extra: Int32 = -1) -> Bool {
            guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return false }
            d.append(0x0a)
            if extra < 0 {
                return d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) } == d.count
            }
            return sendWithFD(socket: fd, data: d, passing: extra)
        }
        _ = readMessage()                                   // greeting
        guard write(["execute": "qmp_capabilities"]) else { return nil }
        _ = readMessage()
        guard write(command, fd: passFD) else { return nil }
        return readMessage()
    }

    /// sendmsg with one SCM_RIGHTS descriptor.  Darwin aligns control data to
    /// 4 bytes: CMSG_SPACE(4) = CMSG_LEN(4) = 16.
    static func sendWithFD(socket: Int32, data: Data, passing passFD: Int32) -> Bool {
        var control = [UInt8](repeating: 0, count: 16)
        control.withUnsafeMutableBytes { c in
            c.storeBytes(of: UInt32(16), toByteOffset: 0, as: UInt32.self)          // cmsg_len
            c.storeBytes(of: Int32(SOL_SOCKET), toByteOffset: 4, as: Int32.self)    // cmsg_level
            c.storeBytes(of: Int32(SCM_RIGHTS), toByteOffset: 8, as: Int32.self)    // cmsg_type
            c.storeBytes(of: passFD, toByteOffset: 12, as: Int32.self)
        }
        var d = data
        return d.withUnsafeMutableBytes { dp -> Bool in
            control.withUnsafeMutableBytes { cp -> Bool in
                var iov = iovec(iov_base: dp.baseAddress, iov_len: dp.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Bool in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = cp.baseAddress
                    msg.msg_controllen = socklen_t(cp.count)
                    return sendmsg(socket, &msg, 0) == dp.count
                }
            }
        }
    }

    /// recvmsg one SCM_RIGHTS descriptor (from authopen -stdoutpipe).
    static func receiveFD(socket: Int32) -> Int32 {
        var byte = [UInt8](repeating: 0, count: 256)
        var control = [UInt8](repeating: 0, count: 16)
        return byte.withUnsafeMutableBytes { bp -> Int32 in
            control.withUnsafeMutableBytes { cp -> Int32 in
                var iov = iovec(iov_base: bp.baseAddress, iov_len: bp.count)
                return withUnsafeMutablePointer(to: &iov) { iovp -> Int32 in
                    var msg = msghdr()
                    msg.msg_iov = iovp
                    msg.msg_iovlen = 1
                    msg.msg_control = cp.baseAddress
                    msg.msg_controllen = socklen_t(cp.count)
                    guard recvmsg(socket, &msg, 0) >= 0, msg.msg_controllen >= 16 else { return -1 }
                    let type = cp.load(fromByteOffset: 8, as: Int32.self)
                    return type == SCM_RIGHTS ? cp.load(fromByteOffset: 12, as: Int32.self) : -1
                }
            }
        }
    }
}
