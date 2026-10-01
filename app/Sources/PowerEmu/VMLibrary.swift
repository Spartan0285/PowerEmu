import Foundation
import AppKit

/// All virtual Macs in ~/Library/Application Support/PowerEmu/Virtual Machines.
@MainActor
final class VMLibrary: ObservableObject {
    private var autoStarted = false

    /// Start the virtual Macs marked to start when PowerEmu opens (once),
    /// after taking back any that outlived a PowerEmu that crashed.
    func autoStartOnce() {
        guard !autoStarted else { return }
        autoStarted = true
        for vm in machines { vm.adoptIfLeftRunning() }
        // A machine may have been put to sleep in an earlier run, with its
        // memory sitting in its disk waiting to be picked up again.
        for vm in machines where vm.state == .stopped { vm.checkForSleep() }
        for vm in machines where vm.config.autoStart && vm.state == .stopped {
            vm.start()
        }
    }

    @Published private(set) var machines: [VirtualMachine] = []
    /// Installs in progress, by machine.
    @Published private(set) var installs: [URL: InstallSession] = [:]
    @Published var loadError: String?

    let folder: URL

    /// ~/Library/Application Support/PowerEmu: the machines, the icons, the
    /// downloads.  Named once so everything that needs it agrees.
    nonisolated static var applicationSupport: URL {
        if let path = ProcessInfo.processInfo.environment["POWEREMU_EXPERIMENT_SUPPORT"] {
            return URL(fileURLWithPath: path, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu", isDirectory: true)
    }

    init() {
        folder = Self.applicationSupport.appendingPathComponent("Virtual Machines", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        let existing = Dictionary(uniqueKeysWithValues: machines.map { ($0.url, $0) })
        let savedOrder = (try? Data(contentsOf: folder.deletingLastPathComponent().appendingPathComponent("vm-order.json")))
            .flatMap { try? JSONDecoder().decode([String].self, from: $0) } ?? []
        let ranks = Dictionary(savedOrder.enumerated().map { ($0.element, $0.offset) }, uniquingKeysWith: min)
        machines = urls.filter { $0.pathExtension == "poweremu" }
            .compactMap { existing[$0] ?? (try? VirtualMachine(url: $0)) }
            .sorted {
                let left = ranks[$0.url.lastPathComponent] ?? Int.max
                let right = ranks[$1.url.lastPathComponent] ?? Int.max
                if left != right { return left < right }
                return $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending
            }
    }

    func moveMachines(from offsets: IndexSet, to destination: Int) {
        guard !offsets.isEmpty, offsets.allSatisfy({ machines.indices.contains($0) }),
              (0...machines.count).contains(destination) else { return }
        var reordered = machines
        // SwiftUI's destination is the index before removing the moved rows.
        let moving = offsets.sorted().map { reordered[$0] }
        for index in offsets.sorted(by: >) { reordered.remove(at: index) }
        let insertion = destination - offsets.filter { $0 < destination }.count
        reordered.insert(contentsOf: moving, at: insertion)
        do {
            let data = try JSONEncoder().encode(reordered.map { $0.url.lastPathComponent })
            try data.write(to: folder.deletingLastPathComponent().appendingPathComponent("vm-order.json"), options: .atomic)
            machines = reordered
        } catch { loadError = "Could not save the virtual Mac order: \(error.localizedDescription)" }
    }

    func moveMachine(_ vm: VirtualMachine, by offset: Int) {
        guard let index = machines.firstIndex(where: { $0.url == vm.url }),
              machines.indices.contains(index + offset) else { return }
        moveMachines(from: IndexSet(integer: index), to: index + offset + (offset > 0 ? 1 : 0))
    }

    /// Make a new package from existing files.  Disks and ROMs are cloned
    /// (APFS: instant, no space used until they diverge), so the originals are
    /// never touched.
    func importMachine(name: String, osName: String, startupDisk: URL, extraDisks: [URL],
                       romFolder: URL?) throws -> VirtualMachine {
        let pkg = folder.appendingPathComponent(name + ".poweremu", isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: pkg.path) else { throw PackageError.exists(name) }
        try fm.createDirectory(at: pkg.appendingPathComponent("Disks"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appendingPathComponent("ROMs"), withIntermediateDirectories: true)
        try fm.createDirectory(at: pkg.appendingPathComponent("Logs"), withIntermediateDirectories: true)

        var config = VMConfig(name: name)
        config.osName = osName
        do {
            for src in [startupDisk] + extraDisks {
                if VMConfig.discExtensions.contains(src.pathExtension.lowercased()) && src != startupDisk {
                    config.discs.append(src.path)         // discs are used where they are
                    continue
                }
                let dst = pkg.appendingPathComponent("Disks").appendingPathComponent(src.lastPathComponent)
                try cloneOrCopy(src, to: dst)
                config.disks.append(DiskConfig(file: src.lastPathComponent))
            }
            config.startupDisk = config.disks.first?.id
            let vm = VirtualMachine(url: pkg, config: config)
            try vm.save()
            reload()
            return machines.first { $0.url == pkg } ?? vm
        } catch {
            try? fm.removeItem(at: pkg)
            throw error
        }
    }

    /// Adds a disk image to a machine (cloned into its package).
    func addDisk(_ src: URL, to vm: VirtualMachine) throws {
        var name = src.lastPathComponent
        var dst = vm.disksURL.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: dst.path) {
            name = "\(src.deletingPathExtension().lastPathComponent) \(n).\(src.pathExtension)"
            dst = vm.disksURL.appendingPathComponent(name)
            n += 1
        }
        try cloneOrCopy(src, to: dst)
        vm.config.disks.append(DiskConfig(file: name))
        try vm.save()
    }

    /// A new empty hard disk (qcow2: grows as it fills) in the machine's package,
    /// already carrying an Apple partition map and an empty Mac OS Extended
    /// (Journaled) volume.  An unpartitioned disk is not just untidy: Mac OS X
    /// installs onto it happily and then cannot bless it, so the install fails
    /// on its last step.  Formatting costs about a second.
    /// How a new disk is laid out before the guest ever sees it.
    enum DiskLayout {
        /// An Apple partition map and a journaled HFS+ volume, the way Disk
        /// Utility does it on the guest.  Mac OS X will only bless a disk
        /// laid out this way.
        case macOSX
        /*
         * Nothing at all: the guest formats it.
         *
         * This is what a classic Mac OS guest gets, and not for want of
         * trying.  Mac OS 9 mounts an HFS+ volume only when it sits inside an
         * HFS wrapper -- Drive Setup writes one, with drEmbedSigWord 'H+' in
         * the wrapper's master directory block and the real volume embedded
         * inside it.  Measured against Mac OS 9.2.2: a disk this Mac laid out
         * as APM + HFS+ is seen by the guest (Drive Setup lists the ATA drive)
         * and reported as <not mounted>, because the volume is bare HFS+ with
         * no wrapper.
         *
         * No tool on this Mac can write one any more.  diskutil offers only
         * HFS+ and its journaled and case-sensitive variants, `newfs_hfs` lost
         * its wrapper option, and `hdiutil create -fs HFS` answers "HFS has
         * been deprecated; using HFS+ instead" and writes a bare volume.
         *
         * So the disk is left blank rather than laid out in a way the guest
         * would silently refuse, which reads as a broken disk rather than an
         * empty one.  The machine starts from the install disc, where Drive
         * Setup is in the Utilities folder; it initializes the drive in a few
         * seconds, exactly as it would on a real Power Mac.
         */
        case guestFormats
    }

    func createBlankDisk(named name: String, gigabytes: Int, layout: DiskLayout = .macOSX,
                         in vm: VirtualMachine) throws {
        guard let helper = VMRunner.helperURL else { throw PackageError.missing("The emulator (PowerEmu VM.app)") }
        let tool = helper.appendingPathComponent("Contents/MacOS/qemu-img")
        var file = name + ".qcow2"
        var n = 2
        while FileManager.default.fileExists(atPath: vm.disksURL.appendingPathComponent(file).path) {
            file = "\(name) \(n).qcow2"; n += 1
        }
        let p = Process()
        p.executableURL = tool
        p.arguments = ["create", "-q", "-f", "qcow2", vm.disksURL.appendingPathComponent(file).path, "\(gigabytes)G"]
        let err = Pipe()
        p.standardError = err
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "PowerEmu", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "Could not create the disk. \(msg)"])
        }
        /*
         * Lay the disk out the way Disk Utility would.  If this Mac will not
         * do it -- hdiutil or diskutil refusing for some reason of its own --
         * the plain disk is still usable: the guest can erase it itself, which
         * is what had to happen before.
         */
        let img = vm.disksURL.appendingPathComponent(file)
        if layout == .macOSX {
            do {
                try InstallPlan.formatDisk(img, gigabytes: gigabytes, named: name, qemuImg: tool)
            } catch {
                NSLog("PowerEmu: %@ could not be formatted, leaving it blank: %@",
                      file, error.localizedDescription)
            }
        }

        vm.config.disks.append(DiskConfig(file: file, label: name))
        if vm.config.startupDisk == nil { vm.config.startupDisk = vm.config.disks.last?.id }
        try vm.save()
    }

    /// A new virtual Mac to install from a disc: a blank disk, the install
    /// disc in the drive, starting from the disc.  The ATI ROMs are copied
    /// from an existing machine.
    func newMachine(name: String, osName: String, memoryMB: Int, vramMB: Int = 128, diskGB: Int,
                    installDisc: URL?, classic: Bool = false) throws -> VirtualMachine {
        let pkg = folder.appendingPathComponent(name + ".poweremu", isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: pkg.path) else { throw PackageError.exists(name) }
        for sub in ["Disks", "Logs"] {
            try fm.createDirectory(at: pkg.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var config = VMConfig(name: name)
        config.osName = osName
        config.memoryMB = memoryMB
        config.vramMB = vramMB
        config.classic = classic
        // Seamless pointing needs the USB tablet, which Mac OS 9 cannot
        // drive; a classic guest captures the mouse instead.  See VMRunner.
        if classic { config.mouseMode = "captured" }
        do {
            if let installDisc {
                config.discs = [installDisc.path]
                config.insertedDisc = installDisc.path
                config.bootFromDisc = true
            }
            let vm = VirtualMachine(url: pkg, config: config)
            try vm.save()
            try createBlankDisk(named: "Macintosh HD", gigabytes: diskGB,
                                layout: classic ? .guestFormats : .macOSX, in: vm)
            reload()
            return machines.first { $0.url == pkg } ?? vm
        } catch {
            try? fm.removeItem(at: pkg)
            throw error
        }
    }

    /// A new virtual Mac that installs onto a physical external disk of this
    /// Mac.  It has no internal disk -- the external is its only hard disk --
    /// boots the install disc, and the person does the install by hand.
    func newMachineOnExternal(name: String, osName: String, memoryMB: Int, vramMB: Int = 128,
                              external: HostDrive, installDisc: URL?) throws -> VirtualMachine {
        let pkg = folder.appendingPathComponent(name + ".poweremu", isDirectory: true)
        let fm = FileManager.default
        guard !fm.fileExists(atPath: pkg.path) else { throw PackageError.exists(name) }
        for sub in ["Disks", "Logs"] {
            try fm.createDirectory(at: pkg.appendingPathComponent(sub), withIntermediateDirectories: true)
        }
        var config = VMConfig(name: name)
        config.osName = osName
        config.memoryMB = memoryMB
        config.vramMB = vramMB
        if let installDisc {
            config.discs = [installDisc.path]
            config.insertedDisc = installDisc.path
            config.bootFromDisc = true
        }
        config.externalDisk = ExternalDisk(bsdName: external.bsdName, label: external.name)
        do {
            let vm = VirtualMachine(url: pkg, config: config)
            try vm.save()
            reload()
            return machines.first { $0.url == pkg } ?? vm
        } catch {
            try? fm.removeItem(at: pkg)
            throw error
        }
    }

    /// A new virtual Mac installed from `options.disc` with nobody at the
    /// keyboard (see InstallPlan). Returns at once; the install runs on.
    func installMachine(name: String, memoryMB: Int, vramMB: Int, options: InstallPlan.Options,
                        discVersion: String) throws -> VirtualMachine {
        let vm = try newMachine(name: name, osName: "Mac OS X \(discVersion) Tiger", memoryMB: memoryMB,
                                vramMB: vramMB, diskGB: options.diskGB, installDisc: nil)
        let s = InstallSession(vm: vm, options: options, discVersion: discVersion)
        s.onFinish = { [weak self, weak s] in
            // Keep the finished session a moment so the window can say so.
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                guard let self, let s, s.outcome == .finished else { return }
                self.installs[vm.url] = nil
            }
        }
        installs[vm.url] = s
        s.start()
        return vm
    }

    /// Developer testing only: POWEREMU_TEST_INSTALL=/path/to/disc.iso starts
    /// an install with the default choices when PowerEmu opens, so the whole
    /// path can be exercised without clicking through the sheet.
    /// POWEREMU_TEST_INSTALL_UPDATE=1 adds the 10.4.11 update.
    private var developerInstallStarted = false
    func developerAutoInstall() {
        let env = ProcessInfo.processInfo.environment
        guard !developerInstallStarted, let path = env["POWEREMU_TEST_INSTALL"], !path.isEmpty else { return }
        developerInstallStarted = true
        let disc = URL(fileURLWithPath: path)
        let update = env["POWEREMU_TEST_INSTALL_UPDATE"] == "1"
        Task.detached {
            guard let info = try? InstallPlan.inspect(disc), info.automatable else {
                NSLog("PowerEmu test install: %@ can't be installed automatically", path)
                return
            }
            await MainActor.run {
                var name = "Install Test"
                var n = 2
                while self.machines.contains(where: { $0.config.name == name }) { name = "Install Test \(n)"; n += 1 }
                let o = InstallPlan.Options(disc: disc, diskGB: 20, language: InstallPlan.hostLanguage.value,
                                            update10411: update)
                do {
                    let vm = try self.installMachine(name: name, memoryMB: 2048, vramMB: 128, options: o,
                                                     discVersion: info.version)
                    NotificationCenter.default.post(name: .selectVirtualMac, object: vm.url)
                } catch {
                    NSLog("PowerEmu test install failed to start: %@", error.localizedDescription)
                }
            }
        }
    }

    func dismissInstall(_ vm: VirtualMachine) {
        installs[vm.url] = nil
    }

    var installing: [InstallSession] { installs.values.filter { $0.outcome == .running } }

    func moveToTrash(_ vm: VirtualMachine) throws {
        installs[vm.url]?.cancel()
        installs[vm.url] = nil
        try FileManager.default.trashItem(at: vm.url, resultingItemURL: nil)
        reload()
    }

    /// The setup the command-line launcher uses, if present on this Mac.
    static var legacySetup: (disk: URL, extra: [URL], roms: URL)? {
        let dir = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("QEMU Project")
        let disk = dir.appendingPathComponent("tiger-fresh.qcow2")
        guard FileManager.default.fileExists(atPath: disk.path) else { return nil }
        let kexts = dir.appendingPathComponent("kexts.img")
        return (disk, FileManager.default.fileExists(atPath: kexts.path) ? [kexts] : [], dir)
    }
}
