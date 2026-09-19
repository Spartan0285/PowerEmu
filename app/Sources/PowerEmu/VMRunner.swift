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

    init(vm: VirtualMachine) {
        self.vm = vm
        // Unix socket paths are limited to 104 bytes; keep it short.
        qmpPath = NSTemporaryDirectory() + "poweremu-\(abs(vm.url.path.hashValue) % 1_000_000).qmp"
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
            if let p = c.sshPort { net += ",hostfwd=tcp:127.0.0.1:\(p)-:22" }
            a += ["-netdev", net, "-device", "sungem,netdev=net0"]
        } else {
            a += ["-nic", "none"]
        }
        if c.agpBridge { a += ["-global", "uni-north-pci.agp-capable=on"] }
        if !c.bootArgs.isEmpty { a += ["-prom-env", "boot-args=\(c.bootArgs)"] }

        a += ["-usb", "-device", "usb-mouse,bus=usb-bus.0", "-device", "usb-kbd,bus=usb-bus.0"]

        // Disks: the startup disk first on ide.0, the rest after it.
        let ordered = [boot] + c.disks.filter { $0.id != boot.id }
        let slots = ["bus=ide.0,unit=0", "bus=ide.1,unit=0", "bus=ide.0,unit=1", "bus=ide.1,unit=1"]
        for (i, d) in ordered.prefix(slots.count).enumerated() {
            let path = vm.disksURL.appendingPathComponent(d.file).path
            let fmt = d.file.lowercased().hasSuffix(".qcow2") ? "qcow2" : "raw"
            var drive = "if=none,id=drive\(i),file.filename=\(path),format=\(fmt)"
            drive += d.kind == .cdrom ? ",media=cdrom,readonly=on" : ",media=disk,discard=unmap,detect-zeroes=unmap"
            if d.readOnly && d.kind == .hardDisk { drive += ",readonly=on" }
            let dev = d.kind == .cdrom ? "ide-cd" : "ide-hd"
            a += ["-drive", drive, "-device", "\(dev),\(slots[i]),drive=drive\(i)" + (i == 0 ? ",bootindex=0" : "")]
        }

        a += ["-serial", "file:\(vm.logsURL.appendingPathComponent("console.log").path)"]
        a += ["-qmp", "unix:\(qmpPath),server=on,wait=off"]
        if let p = c.monitorPort { a += ["-monitor", "telnet:127.0.0.1:\(p),server,nowait"] }
        a += ["-trace", c.gpuTrace ? "ppc_mac_gpu_*" : "ppc_mac_gpu_realize",
              "-D", vm.logsURL.appendingPathComponent("gpu-trace.log").path]
        return a
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
        QMP.send(socket: qmpPath, command: ["execute": "send-key",
                                             "arguments": ["keys": [["type": "qcode", "data": "power"]]]])
    }

    func terminate() {
        QMP.send(socket: qmpPath, command: ["execute": "quit"])
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            if let p = self?.process, p.isRunning { p.terminate() }
        }
    }
}

/// Minimal QMP client: connect, negotiate capabilities, send one command.
enum QMP {
    static func send(socket path: String, command: [String: Any]) {
        DispatchQueue.global().async {
            let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { return }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in
                for (i, b) in bytes.enumerated() { buf[i] = b }
            }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard ok == 0 else { return }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            func readReply() { var buf = [UInt8](repeating: 0, count: 4096); _ = read(fd, &buf, buf.count) }
            func write(_ obj: [String: Any]) {
                guard var d = try? JSONSerialization.data(withJSONObject: obj) else { return }
                d.append(0x0a)
                _ = d.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, d.count) }
            }
            readReply()                                   // greeting
            write(["execute": "qmp_capabilities"])
            readReply()
            write(command)
            readReply()
        }
    }
}
