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
    /// Which Mac it looks like (MacModel.id); only the icon.
    var model: String?
    /// The processor Mac OS X reports, in MHz: cosmetic only, the emulated
    /// CPU runs the same whatever it says. nil = the emulator's own figure.
    var cpuMHz: Int?
    var memoryMB: Int = 2048

    var disks: [DiskConfig] = []
    var startupDisk: UUID?

    /// Disc images known to this machine (absolute paths, used in place,
    /// read-only) and the one in the CD/DVD drive.
    var discs: [String] = []
    var insertedDisc: String?
    /// Boot from the disc in the drive (installing) instead of the startup disk.
    var bootFromDisc = false

    /*
     * There used to be two ATI ROM settings here, naming firmware dumped
     * from a real Radeon. They are gone, because they were never needed.
     *
     * PowerEmu loads its own NDRV through ppc-ndrvloader, so the Mac driver
     * in the card's ROM was always redundant; and Mac OS X's ATIRadeon8500
     * binds on the PCI ID, which the device presents either way. Measured
     * with no ROM at all: the desktop comes up, the kext loads, Quartz
     * Extreme reports Supported, and Warcraft III runs at the same frame
     * rate as with the ROMs. The only difference is cosmetic -- the card
     * calls itself "QEMU VGA" rather than an ATI name.
     *
     * Requiring them would have meant every user dumping firmware from a
     * physical Radeon Mac card, which almost nobody has, to gain nothing.
     * Old packages may still carry the keys; they are ignored.
     */

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
    /// Which chime: "g4", "warm", "bell", or "custom" (chimeFile).
    var chimeSound = "g4"
    var chimeFile: String?
    /// The guest's last screen size: the next boot starts at it, so the
    /// firmware and the grey Apple are already the right size.
    var bootWidth = 1024
    var bootHeight = 768
    /// Start this virtual Mac when PowerEmu opens.
    var autoStart = false
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
    /// Give the virtual Mac a game controller of this Mac, as a USB gamepad.
    var gamepad = true
    /// Let other Macs on the network see and reach this one. Off by
    /// default: an old Mac OS X should not meet a network unasked.
    var shareOnNetwork = false
    /// This Mac's network interface to put the guest directly on to
    /// ("en0"), or nil for the private network only. Bridged, the guest
    /// gets its own address and can see other Macs; it also needs an
    /// administrator each time it starts.
    var bridgedInterface: String?
    /// Let the guest reach PowerMusic on this Mac, at 10.0.2.100:3001.
    /// Off by default: a machine that has nothing to do with music should
    /// have no way into this Mac at all.
    var shareMusic = false
    /// Folders on this Mac shown in the guest (WebDAV; PowerEmu Tools mounts them).
    var sharedFolders: [SharedFolder] = []

    // Developer
    var agpBridge = true
    var monitorPort: Int? = 4444
    var gpuTrace = false
    /// Extra QEMU arguments, appended as given (config file only; for profiling).
    var extraQEMUArgs: [String] = []

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey {
        case name, osName, model, cpuMHz, memoryMB, disks, startupDisk, discs, insertedDisc, bootFromDisc
        case hardwareCursor, extraDisplayModes, startFullscreen, embeddedDisplay, vramMB, mouseMode
        case bootChime, chimeSound, chimeFile, bootWidth, bootHeight, autoStart, verboseBoot, safeBoot, singleUser, audio, network, sshPort, shareClipboard, sharedFolders
        case agpBridge, monitorPort, gpuTrace, extraQEMUArgs, gamepad, shareOnNetwork, bridgedInterface
        case shareMusic
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        var d = VMConfig(name: try c.decode(String.self, forKey: .name))
        func get<T: Decodable>(_ k: CodingKeys, _ into: inout T) throws {
            if let v = try c.decodeIfPresent(T.self, forKey: k) { into = v }
        }
        try get(.osName, &d.osName); try get(.memoryMB, &d.memoryMB)
        d.model = try c.decodeIfPresent(String.self, forKey: .model)
        d.cpuMHz = try c.decodeIfPresent(Int.self, forKey: .cpuMHz)
        try get(.disks, &d.disks)
        d.startupDisk = try c.decodeIfPresent(UUID.self, forKey: .startupDisk)
        try get(.discs, &d.discs)
        d.insertedDisc = try c.decodeIfPresent(String.self, forKey: .insertedDisc)
        try get(.bootFromDisc, &d.bootFromDisc)
        try get(.hardwareCursor, &d.hardwareCursor); try get(.extraDisplayModes, &d.extraDisplayModes)
        try get(.startFullscreen, &d.startFullscreen); try get(.bootChime, &d.bootChime)
        try get(.chimeSound, &d.chimeSound)
        d.chimeFile = try c.decodeIfPresent(String.self, forKey: .chimeFile)
        try get(.bootWidth, &d.bootWidth); try get(.bootHeight, &d.bootHeight); try get(.autoStart, &d.autoStart)
        try get(.embeddedDisplay, &d.embeddedDisplay); try get(.vramMB, &d.vramMB); try get(.mouseMode, &d.mouseMode)
        try get(.verboseBoot, &d.verboseBoot); try get(.safeBoot, &d.safeBoot)
        try get(.singleUser, &d.singleUser); try get(.audio, &d.audio); try get(.network, &d.network)
        if c.contains(.sshPort) { d.sshPort = try c.decodeIfPresent(Int.self, forKey: .sshPort) }
        try get(.shareClipboard, &d.shareClipboard); try get(.sharedFolders, &d.sharedFolders)
        try get(.shareMusic, &d.shareMusic)
        try get(.gamepad, &d.gamepad); try get(.shareOnNetwork, &d.shareOnNetwork)
        d.bridgedInterface = try c.decodeIfPresent(String.self, forKey: .bridgedInterface)
        try get(.agpBridge, &d.agpBridge)
        if c.contains(.monitorPort) { d.monitorPort = try c.decodeIfPresent(Int.self, forKey: .monitorPort) }
        try get(.gpuTrace, &d.gpuTrace); try get(.extraQEMUArgs, &d.extraQEMUArgs)
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
