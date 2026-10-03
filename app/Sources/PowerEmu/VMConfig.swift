import AppKit

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

/// A whole physical disk of the host Mac (an external drive) lent to the
/// virtual Mac as a real IDE hard disk.  Unlike a `DiskConfig`, it is not a
/// file in the package -- `bsdName` names the host device (e.g. "disk14").
/// PowerEmu unmounts it from the host before the guest starts and gives it
/// back when the guest stops.  It attaches at launch (the emulated IDE bus
/// cannot hot-plug) and read-write (an IDE hard disk needs a writable
/// backing), so it can be installed onto and booted from.
struct ExternalDisk: Codable, Hashable {
    var bsdName: String            // "disk14"
    var label: String?             // "HM2T80A0 (Macintosh HD)"
    /*
     * How the disk is actually recognised again.  bsdName is only a hint:
     * macOS reuses disk numbers, so it routinely names a different device
     * later.  The media UUID is stable where the disk has one; the size is a
     * weaker check that still separates a lent drive from whatever disk image
     * has inherited its number.  Both are optional so packages written before
     * this keep loading -- they fall back to matching on the label alone.
     */
    var mediaUUID: String?
    var sizeBytes: Int64?
    /// Boot the virtual Mac from this disk instead of the internal startup disk.
    var bootFrom = false

    var displayName: String { label ?? "/dev/" + bsdName }
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
    /// One CPU preserves existing packages; two requires the experimental helper.
    var cpuCount: Int = 1
    var memoryMB: Int = 2048

    /*
     * A classic Mac OS guest -- Mac OS 8 or 9 -- rather than Mac OS X.
     *
     * Set when the machine was made from a classic install disc, and false
     * in every package written before, so existing machines decode as the
     * Mac OS X guests they are.  It changes three things, each of them
     * measured against a Mac OS 9.2.2 install disc on mac99:
     *
     *  - Memory is capped.  512 MB and 1 GB start; 1.5 GB and 2 GB do not,
     *    failing in Open Firmware with "No valid state has been set by load
     *    or init-program" before the Mac OS ROM ever runs.  PowerEmu's own
     *    default of 2 GB would therefore never boot.
     *  - The sound hardware is taken out of the device tree, because Mac OS
     *    9 crashes on it at startup; see the note in VMRunner.
     *  - The pointer is the relative USB mouse.  Mac OS 9's USB stack has no
     *    driver for an absolute tablet, and with one attached the guest's
     *    cursor does not move at all, so the machine captures the mouse.
     *  - The disk is left blank for the guest to erase; see DiskLayout.
     *
     * via=pmu, the NDRV loader, output-device=ttya, the Radeon and its
     * 128 MB were all tried and all boot, so they are left alone.  So is the
     * Open Firmware boot-command: an earlier reading here said it stopped a
     * classic guest booting, but that test was missing the NDRV loader --
     * with the loader, which every PowerEmu machine gets, the same disc
     * boots to the Finder with the boot-command in place.
     */
    var classic = false

    /// The most memory a classic guest will start with.  1 GB boots, 1.5 GB
    /// does not; see the note on `classic`.
    static let classicMaxMemoryMB = 1024
    static let classicDefaultMemoryMB = 512
    /// Memory choices offered for a classic guest.
    static let classicMemoryChoices = [256, 512, 768, 1024]
    /// Video memory offered to a classic guest.  64 MB and 128 MB were both
    /// measured booting Mac OS 9.2.2; 256 MB was not, so it is not offered.
    static let classicVRAMChoices = [64, 128]

    /// What this machine will actually be started with.
    var effectiveMemoryMB: Int {
        classic ? min(memoryMB, Self.classicMaxMemoryMB) : memoryMB
    }

    var disks: [DiskConfig] = []
    var startupDisk: UUID?

    /// Disc images known to this machine (absolute paths, used in place,
    /// read-only) and the one in the CD/DVD drive.
    var discs: [String] = []
    var insertedDisc: String?
    /// The disc in the drive is a blank recordable disc (a writable image the
    /// guest can burn to), not a pressed read-only disc.  Turns the emulated
    /// drive into a DVD-R burner.
    var discRecordable = false
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
    /*
     * How many screens the virtual Mac has: 1 or 2.
     *
     * A second screen is a second graphics card, which is how a Power Mac
     * did it.  Mac OS X binds its driver to both and extends the desktop
     * across them with no help from here.  Each card costs its own video
     * memory, so two is not free.
     */
    var displays = 1
    /*
     * Give the virtual Mac a sound input -- this Mac's microphone, or
     * whatever it is listening to.
     *
     * Off unless it is asked for.  Switching it on opens a capture stream
     * on this Mac, which is what lights the microphone indicator in the
     * menu bar, and that should never happen merely because a virtual Mac
     * was started.
     */
    var microphone = false
    /// The second screen's size.  The first takes this Mac's screen size, so
    /// Harmony can map one guest pixel to one host point; the second is an
    /// ordinary window and picks a plain size.
    var display2Width = 1280
    var display2Height = 1024
    /// Sizes offered for the second screen: width, height, and what to call
    /// it.  The card can do others; these are the ones worth a menu.
    static let secondScreenSizes: [(Int, Int, String)] = [
        (1024, 768, "1024 \u{00d7} 768"),
        (1280, 1024, "1280 \u{00d7} 1024"),
        (1440, 900, "1440 \u{00d7} 900"),
        (1680, 1050, "1680 \u{00d7} 1050"),
        (1920, 1200, "1920 \u{00d7} 1200"),
    ]
    /// Video memory of the emulated Radeon, in MB: 64, 128 or 256 (the
    /// driver sees 4 MB less).  More than 64 needs poweremu-qemu's wider
    /// uni-north PCI window and matching Open Firmware ranges.
    var vramMB = 128
    static let vramChoices = [64, 128, 256]
    /*
     * How the guest's screen is scaled up to fill the window.
     *
     *   "smooth"  linear, except at exactly 1:1 -- what PowerEmu has always
     *             done.  Kind to text at awkward scales, soft on pixel art.
     *   "sharp"   nearest at every scale.  Every guest pixel stays a crisp
     *             block, at the cost of uneven block sizes when the scale is
     *             not a whole number.
     *   "integer" nearest, and only whole multiples.  Every guest pixel is
     *             the same size square; the picture is letterboxed rather
     *             than stretched to the last few points.
     */
    var scaling = "smooth"

    /*
     * How the guest's picture is fitted to the window.
     *
     *   "fit"      the whole picture, its shape kept, letterboxed where the
     *              window is a different shape.  What PowerEmu has always done.
     *   "fill"     scaled until no border is left, its shape kept, so the
     *              overflowing edges are cropped.
     *   "stretch"  pulled to the window's shape.  A 4:3 guest on a 16:10
     *              screen fills it at the cost of round things being oval --
     *              which is what a period CRT's horizontal size control did,
     *              and is sometimes exactly what is wanted at low resolutions.
     */
    var displayFit = "fit"
    static let displayFitChoices: [(String, String)] = [
        ("fit",     "Fit"),
        ("fill",    "Fill (crop)"),
        ("stretch", "Stretch"),
    ]

    /// Period display emulation over the guest's screen; 0 is off.  The
    /// numbering is PocketShaver's -- see PanelFilters.
    var panelFilter = 0
    static let scalingChoices: [(String, String)] = [
        ("smooth",  "Smooth"),
        ("sharp",   "Sharp"),
        ("integer", "Sharp, whole pixels"),
    ]

    /// "seamless" (USB tablet: the pointer moves in and out freely) or
    /// "captured" (raw mouse movement for games).
    var mouseMode = "seamless"

    // Startup
    var bootChime = true
    /// Which chime: "g4", "warm", "bell", or "custom" (chimeFile).
    var chimeSound = "g4"
    var chimeFile: String?
    /// The guest's last screen size: the next boot starts at it, so the
    /// firmware and the gray Apple are already the right size.
    /*
     * Startup resolutions worth offering, worked out from the screen this Mac
     * has.
     *
     * The guest can change resolution in System Preferences once it is up, but
     * the one it starts in came only from the configuration file, and nothing
     * in the app ever showed it.  A reader on a notched Mac had no way to pick
     * the size that clears the notch except by editing a plist.
     *
     * The host-shaped sizes come first because they are the ones that make
     * fullscreen land right; the standard sizes follow for anything that wants
     * a shape Mac OS X knows well.
     */
    struct DisplayMode: Hashable { let label: String, width: Int, height: Int }

    static func displayModes(for screen: NSScreen?) -> [DisplayMode] {
        var out: [DisplayMode] = []
        if let screen {
            let fitted = HarmonyDisplayMode.size(screen: screen)
            let notch = HarmonyDisplayMode.notch(on: screen)
            let whole = Int(screen.frame.height.rounded())
            let w = Int(fitted.width)
            if notch > 0 {
                out.append(DisplayMode(label: "This Mac, below the notch", width: w, height: Int(fitted.height)))
                out.append(DisplayMode(label: "This Mac, whole screen", width: w, height: whole))
            } else {
                out.append(DisplayMode(label: "This Mac’s screen", width: w, height: Int(fitted.height)))
            }
        }
        let host = screen?.frame.size ?? CGSize(width: 4096, height: 4096)
        /*
         * The small 4:3 sizes come first and are offered to every machine,
         * not just a classic one.  A guest that has been left in a mode its
         * display cannot show -- picked inside the guest, by hand -- is hard
         * to get out of from inside, and the startup resolution is the way
         * back.  832 x 624 and 1152 x 870 are the old Apple multiscan sizes.
         */
        for (w, h) in [(640, 480), (800, 600), (832, 624), (1024, 768), (1152, 870),
                       (1280, 800), (1280, 1024), (1440, 900), (1680, 1050), (1920, 1200)]
        where CGFloat(w) <= host.width && CGFloat(h) <= host.height {
            out.append(DisplayMode(label: "\(w) × \(h)", width: w, height: h))
        }
        return out
    }

    var bootWidth = 1024
    var bootHeight = 768
    /// Start this virtual Mac when PowerEmu opens.
    var autoStart = false
    var verboseBoot = false
    var safeBoot = false
    var singleUser = false

    // Sound and network
    var audio = "coreaudio"
    /*
     * Isolation: one switch that cuts every path between this Mac and the
     * guest -- the network, the clipboard, the shared folders and the
     * services.  The individual settings are left exactly as they were, so
     * turning it off again restores what the reader had rather than a set of
     * defaults.
     */
    /*
     * USB devices this machine connects by itself once it is running, by the
     * identity HostUSBDevice gives them.  Without this every device has to be
     * picked from the menu again on every start, which for a machine that
     * exists to use one dongle is the whole job done by hand each time.
     */
    var autoConnectUSB: [String] = []

    var isolated = false
    /*
     * Rollback: run from a throwaway overlay, so everything the guest writes
     * is discarded when it shuts down and it starts from the same place every
     * time.  QEMU's own -snapshot does this for every disk at once.
     */
    var discardChanges = false

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
    /// Folders on this Mac shown in the guest (WebDAV; PowerEmu Tools mounts them).
    var sharedFolders: [SharedFolder] = []

    // Developer
    var agpBridge = true
    var monitorPort: Int? = 4444
    var gpuTrace = false
    /// Extra QEMU arguments, appended as given (config file only; for profiling).
    var extraQEMUArgs: [String] = []

    /// A physical external disk of the host lent to this machine as a real
    /// IDE hard disk (to browse, install onto, or boot from). nil = none.
    var externalDisk: ExternalDisk?

    init(name: String) { self.name = name }

    enum CodingKeys: String, CodingKey {
        case name, osName, model, cpuMHz, cpuCount, memoryMB, disks, startupDisk, discs, insertedDisc, discRecordable, bootFromDisc
        case hardwareCursor, extraDisplayModes, startFullscreen, embeddedDisplay, vramMB, mouseMode
        case bootChime, chimeSound, chimeFile, bootWidth, bootHeight, autoStart, verboseBoot, safeBoot, singleUser, audio, network, sshPort, shareClipboard, sharedFolders
        case agpBridge, monitorPort, gpuTrace, extraQEMUArgs, gamepad, shareOnNetwork, bridgedInterface
        case externalDisk
        case classic, scaling, panelFilter, displayFit, isolated, discardChanges, autoConnectUSB
        case displays, display2Width, display2Height, microphone
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
        try get(.cpuCount, &d.cpuCount)
        guard [1, 2, 4].contains(d.cpuCount) else {
            throw DecodingError.dataCorruptedError(forKey: .cpuCount, in: c, debugDescription: "CPU count must be 1, 2 or 4")
        }
        try get(.disks, &d.disks)
        d.startupDisk = try c.decodeIfPresent(UUID.self, forKey: .startupDisk)
        try get(.discs, &d.discs)
        d.insertedDisc = try c.decodeIfPresent(String.self, forKey: .insertedDisc)
        d.discRecordable = try c.decodeIfPresent(Bool.self, forKey: .discRecordable) ?? false
        try get(.bootFromDisc, &d.bootFromDisc)
        try get(.classic, &d.classic)
        try get(.scaling, &d.scaling)
        try get(.panelFilter, &d.panelFilter)
        try get(.displayFit, &d.displayFit)
        try get(.isolated, &d.isolated)
        try get(.discardChanges, &d.discardChanges)
        try get(.autoConnectUSB, &d.autoConnectUSB)
        try get(.displays, &d.displays); try get(.display2Width, &d.display2Width)
        try get(.display2Height, &d.display2Height); try get(.microphone, &d.microphone)
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
        try get(.gamepad, &d.gamepad); try get(.shareOnNetwork, &d.shareOnNetwork)
        d.bridgedInterface = try c.decodeIfPresent(String.self, forKey: .bridgedInterface)
        try get(.agpBridge, &d.agpBridge)
        if c.contains(.monitorPort) { d.monitorPort = try c.decodeIfPresent(Int.self, forKey: .monitorPort) }
        try get(.gpuTrace, &d.gpuTrace); try get(.extraQEMUArgs, &d.extraQEMUArgs)
        d.externalDisk = try c.decodeIfPresent(ExternalDisk.self, forKey: .externalDisk)
        self = d
    }

    /// What the settings mean once isolation has had its say.
    var networkEnabled: Bool { network && !isolated }
    var clipboardShared: Bool { shareClipboard && !isolated }
    var activeSharedFolders: [SharedFolder] { isolated ? [] : sharedFolders }

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
