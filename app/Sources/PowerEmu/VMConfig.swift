import Foundation

/// A disk attached to the virtual Mac.  `file` is relative to the package's
/// Disks folder.
struct DiskConfig: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case hardDisk = "hd"
        case cdrom = "cdrom"
    }
    var id = UUID()
    var file: String
    var kind: Kind = .hardDisk
    var readOnly = false
    var label: String?

    var displayName: String { label ?? (file as NSString).deletingPathExtension }
}

/// Everything PowerEmu needs to start one virtual Mac; stored as
/// config.plist inside the .poweremu package.
struct VMConfig: Codable, Equatable {
    var name: String
    var osName: String = "Mac OS X 10.4 Tiger"
    var memoryMB: Int = 2048

    var disks: [DiskConfig] = []
    var startupDisk: UUID?

    /// ATI option ROMs for the emulated Radeon, in the package's ROMs folder.
    /// They are firmware from the real card and are supplied by the user.
    var gpuOptionROM: String? = "ati_ndrv_joy.rom"
    var gpuBIOSROM: String? = "ati_ret_9200_201_pciagp_full.rom"

    // Display
    var hardwareCursor = true
    var extraDisplayModes = true
    var startFullscreen = false

    // Startup
    var bootChime = true
    var verboseBoot = false
    var safeBoot = false
    var singleUser = false

    // Sound and network
    var audio = "coreaudio"
    var network = true
    /// Host port forwarded to the guest's ssh (Remote Login); nil = none.
    var sshPort: Int? = 2222

    // Developer
    var agpBridge = true
    var monitorPort: Int? = 4444
    var gpuTrace = false

    var startupDiskConfig: DiskConfig? {
        disks.first { $0.id == startupDisk } ?? disks.first { $0.kind == .hardDisk }
    }

    /// Mac OS X's boot-args for the chosen startup options.
    var bootArgs: String {
        var a: [String] = []
        if verboseBoot { a.append("-v") }
        if safeBoot { a.append("-x") }
        if singleUser { a.append("-s") }
        return a.joined(separator: " ")
    }
}
