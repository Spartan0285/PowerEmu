import Foundation
import AppKit

/// All virtual Macs in ~/Library/Application Support/PowerEmu/Virtual Machines.
@MainActor
final class VMLibrary: ObservableObject {
    @Published private(set) var machines: [VirtualMachine] = []
    @Published var loadError: String?

    let folder: URL

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        folder = base.appendingPathComponent("PowerEmu/Virtual Machines", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        reload()
    }

    func reload() {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        machines = urls.filter { $0.pathExtension == "poweremu" }
            .compactMap { try? VirtualMachine(url: $0) }
            .sorted { $0.config.name.localizedStandardCompare($1.config.name) == .orderedAscending }
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
                let dst = pkg.appendingPathComponent("Disks").appendingPathComponent(src.lastPathComponent)
                try cloneOrCopy(src, to: dst)
                let kind: DiskConfig.Kind = ["iso", "cdr", "toast"].contains(src.pathExtension.lowercased()) ? .cdrom : .hardDisk
                config.disks.append(DiskConfig(file: src.lastPathComponent, kind: kind))
            }
            config.startupDisk = config.disks.first?.id
            config.gpuOptionROM = nil
            config.gpuBIOSROM = nil
            if let romFolder {
                for rom in (try? fm.contentsOfDirectory(at: romFolder, includingPropertiesForKeys: nil)) ?? []
                    where rom.pathExtension.lowercased() == "rom" {
                    try cloneOrCopy(rom, to: pkg.appendingPathComponent("ROMs").appendingPathComponent(rom.lastPathComponent))
                    let n = rom.lastPathComponent.lowercased()
                    if n.contains("ndrv") { config.gpuOptionROM = rom.lastPathComponent }
                    else if n.contains("fcode") && config.gpuOptionROM == nil { config.gpuOptionROM = rom.lastPathComponent }
                    if n.contains("pciagp") || n.contains("bios") || n.contains("_full") {
                        // Prefer the newer 201 BIOS when several are present.
                        if config.gpuBIOSROM == nil || n.contains("201") { config.gpuBIOSROM = rom.lastPathComponent }
                    }
                }
            }
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
        let kind: DiskConfig.Kind = ["iso", "cdr", "toast"].contains(src.pathExtension.lowercased()) ? .cdrom : .hardDisk
        vm.config.disks.append(DiskConfig(file: name, kind: kind))
        try vm.save()
    }

    func moveToTrash(_ vm: VirtualMachine) throws {
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
