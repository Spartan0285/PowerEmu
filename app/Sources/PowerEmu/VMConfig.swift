import Foundation

/// A hard disk attached to the virtual Mac; `file` is relative to the
/// package's Disks folder.
struct DiskConfig: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable {
        case hardDisk = "hd"
        case cdrom = "cdrom"        // older packages; discs now live in VMConfig.discs
    }
    var id = UUID()
    var file: String
    var kind: Kind = .hardDisk
    var readOnly = false
    var label: String?

    var displayName: String { label ?? (file as NSString).deletingPathExtension }
}

/// Everything PowerEmu needs to start one virtual Mac; stored as
/// config.plist inside the .poweremu package.  Every field has a default and
/// missing keys decode to it, so packages from older versions keep loading.
struct VMConfig: Codable, Equatable {
    var name: String
    var osName: String = "Mac OS X 10.4 Tiger"
    var memoryMB: Int = 2048

    var disks: [DiskConfig] = []
    var startupDisk: UUID?

    /// Disc images known to this machine (absolute paths, used in place,
    /// read-only) and the one in the CD/DVD drive.
    var discs: [String] = []
    var insertedDisc: String?
    /// Boot from the disc in the drive (installing) instead of the startup disk.
    var bootFromDisc = false

    /// ATI option ROMs for the emulated Radeon, in the package's ROMs folder.
    /// They are firmware from the real card and are supplied by the user.
    var gpuOptionROM: String? = "ati_ndrv_joy.rom"
    var gpuBIOSROM: String? = "ati_ret_9200_201_pciagp_full.rom"

    // Display
    var hardwareCursor = true
    var extraDisplayModes = true
    var startFullscreen = false
    /// Show the guest in PowerEmu's own window (poweremu-display); false
    /// uses QEMU's Cocoa window, a separate app in the Dock.
    var embeddedDisplay = true
    /// Video memory of the emulated Radeon, in MB: 64, 128 or 256 (the
    /// driver sees 4 MB less).  More than 64 needs poweremu-qemu's wider
    /// uni-north PCI window.
    var vramMB = 128
    static let vramChoices = [64, 128, 256]
    /// "seamless" (USB tablet: the pointer moves in and out freely) or
    /// "captured" (raw mouse movement for games).
    var mouseMode = "seamless"

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
    /// Share the clipboard with the guest (needs PowerEmu Tools).
    var shareClipboard = true
    /// Folders on this Mac shown in the guest (WebDAV; PowerEmu Tools mounts them).
    var sharedFolders: [SharedFolder] = []

    // Developer
    var agpBridge = true
    var monitorPort: Int? = 4444
    var gpuTrace = false

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey {
        case name, osName, memoryMB, disks, startupDisk, discs, insertedDisc, bootFromDisc
        case gpuOptionROM, gpuBIOSROM, hardwareCursor, extraDisplayModes, startFullscreen, embeddedDisplay, vramMB, mouseMode
        case bootChime, verboseBoot, safeBoot, singleUser, audio, network, sshPort, shareClipboard, sharedFolders
        case agpBridge, monitorPort, gpuTrace
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = VMConfig(name: try c.decode(String.self, forKey: .name))
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: k) { into = v }
        }
        try get(.osName, &d.osName); try get(.memoryMB, &d.memoryMB)
        try get(.disks, &d.disks)
        d.startupDisk = try c.decodeIfPresent(UUID.self, forKey: .startupDisk)
        try get(.discs, &d.discs)
        d.insertedDisc = try c.decodeIfPresent(String.self, forKey: .insertedDisc)
        try get(.bootFromDisc, &d.bootFromDisc)
        if c.contains(.gpuOptionROM) { d.gpuOptionROM = try c.decodeIfPresent(String.self, forKey: .gpuOptionROM) }
        if c.contains(.gpuBIOSROM) { d.gpuBIOSROM = try c.decodeIfPresent(String.self, forKey: .gpuBIOSROM) }
        try get(.hardwareCursor, &d.hardwareCursor); try get(.extraDisplayModes, &d.extraDisplayModes)
        try get(.startFullscreen, &d.startFullscreen); try get(.bootChime, &d.bootChime)
        try get(.embeddedDisplay, &d.embeddedDisplay); try get(.vramMB, &d.vramMB); try get(.mouseMode, &d.mouseMode)
        try get(.verboseBoot, &d.verboseBoot); try get(.safeBoot, &d.safeBoot)
        try get(.singleUser, &d.singleUser); try get(.audio, &d.audio); try get(.network, &d.network)
        if c.contains(.sshPort) { d.sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) }
        try get(.shareClipboard, &d.shareClipboard); try get(.sharedFolders, &d.sharedFolders)
        try get(.agpBridge, &d.agpBridge)
        if c.contains(.monitorPort) { d.monitorPort = try c.decodeIfPresent(Int.self, forKey: .monitorPort) }
        try get(.gpuTrace, &d.gpuTrace)
        self = d
    }

    var hardDisks: [DiskConfig] { disks.filter { $0.kind == .hardDisk } }

    var startupDiskConfig: DiskConfig? {
        hardDisks.first { $0.id == startupDisk } ?? hardDisks.first
    }

    /// Mac OS X's boot-args for the chosen startup options.
    var bootArgs: String {
        var a: [String] = []
        if verboseBoot { a.append("-v") }
        if safeBoot { a.append("-x") }
        if singleUser { a.append("-s") }
        return a.joined(separator: " ")
    }

    /// QEMU block format for a disc or disk image file.
    static func imageFormat(_ path: String) -> String {
        switch (path as NSString).pathExtension.lowercased() {
        case "qcow2": return "qcow2"
        case "dmg": return "dmg"            // QEMU reads UDIF (zlib/bzip2) images
        default: return "raw"               // iso, cdr, toast, img, raw
        }
    }

    static let discExtensions = ["iso", "cdr", "toast", "dmg", "cue", "bin"]
}
