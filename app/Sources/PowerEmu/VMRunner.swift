import Foundation

/// Starts the bundled QEMU for one virtual Mac and talks to it over QMP.
///
/// The command line mirrors launcher/launch-tiger-ati.sh, which is where each
/// option is explained; keep the two in step.
@MainActor
final class VMRunner {
    private let vm: VirtualMachine
    private var process: Process?
    private let qmpPath: String
    /// PowerEmu Tools' socket (GuestAgent listens on it).
    let agentPath: String
    /// Shared folders' WebDAV socket (WebDAVServer listens on it).
    let davPath: String
    /// PowerEmu Clock's socket (ClockServer listens on it).
    let clockPath: String
    /// The host ports this run uses: the configured ones, or the next free
    /// ones when another virtual Mac (or anything else) has them.
    private(set) var sshPort: Int?
    private(set) var monitorPort: Int?

    init(vm: VirtualMachine) {
        self.vm = vm
        // Unix socket paths are limited to 104 bytes; keep it short.
        let tag = "poweremu-\(abs(vm.url.path.hashValue) % 1_000_000)"
        qmpPath = NSTemporaryDirectory() + tag + ".qmp"
        agentPath = NSTemporaryDirectory() + tag + ".agent"
        davPath = NSTemporaryDirectory() + tag + ".dav"
        clockPath = NSTemporaryDirectory() + tag + ".clock"
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
        let bootCmd = #"boot-command=" /pci@f2000000" find-device " uni-north" encode-string " compatible" property device-end " /pci@f2000000/ATY,Adagio@e" ['] find-device catch 0= if 7 encode-int " IOAGPFlags" property h# 104 encode-int " IOAGPCommandValue" property device-end then " /pci@f2000000/QEMU,VGA@e" ['] find-device catch 0= if h# 4000000 encode-int " VRAM,totalsize" property device-end then boot"#

        var a: [String] = [
            "-name", c.name,
            "-L", fw.path, "-nodefaults", "-vga", "none", "-display", "cocoa",
            "-smp", "cpus=1,sockets=1,cores=1,threads=1", "-machine", "mac99,via=pmu",
            "-accel", "tcg,tb-size=512", "-g", "1024x768x32",
            "-device", "loader,addr=0x4000000,file=\(fw.appendingPathComponent("ppc-ndrvloader").path)",
            "-prom-env", bootCmd,
            "-m", String(c.memoryMB),
            "-audio", c.audio,
        ]
        if c.extraDisplayModes { a += ["-global", "ppc-mac-gpu.host-aspect-modes=on"] }
        if c.startFullscreen { a.append("-full-screen") }

        var gpu = "ppc-mac-gpu,vgamem_mb=64"
        if let r = c.gpuOptionROM { gpu += ",romfile=\(vm.romsURL.appendingPathComponent(r).path)" }
        if let r = c.gpuBIOSROM { gpu += ",biosrom=\(vm.romsURL.appendingPathComponent(r).path)" }
        a += ["-device", gpu]

        if c.network {
            var net = "user,id=net0,ipv6=off"
            sshPort = c.sshPort.map(Self.freePort)
            if let p = sshPort { net += ",hostfwd=tcp:127.0.0.1:\(p)-:22" }
            // PowerEmu Tools: the guest's connections to 10.0.2.100:7700
            // reach GuestAgent's socket, one nc per connection.
            net += ",guestfwd=tcp:10.0.2.100:7700-cmd:/usr/bin/nc -U \(agentPath)"
            // Shared folders: http://10.0.2.100/ in the guest.
            net += ",guestfwd=tcp:10.0.2.100:80-cmd:/usr/bin/nc -U \(davPath)"
            // The guest's clock daemon asks the time at 10.0.2.100:7701.
            net += ",guestfwd=tcp:10.0.2.100:7701-cmd:/usr/bin/nc -U \(clockPath)"
            a += ["-netdev", net, "-device", "sungem,netdev=net0"]
        } else {
            a += ["-nic", "none"]
        }
        if c.agpBridge { a += ["-global", "uni-north-pci.agp-capable=on"] }
        if !c.bootArgs.isEmpty { a += ["-prom-env", "boot-args=\(c.bootArgs)"] }

        a += ["-usb", "-device", "usb-mouse,bus=usb-bus.0", "-device", "usb-kbd,bus=usb-bus.0"]

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

    func pressPowerKey() {
        QMP.shared.send(qmpPath, ["execute": "send-key",
                                  "arguments": ["keys": [["type": "qcode", "data": "power"]]]])
    }

    func terminate() {
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
