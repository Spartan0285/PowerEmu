import AppKit

/*
 * The Mac a virtual Mac looks like: its icon in the library and in the
 * Installation Assistant. Purely cosmetic -- every model runs the same
 * emulated Power Mac G4.
 *
 * The pictures are the ones macOS itself has for these Macs (Finder uses
 * them for network devices), read from this Mac's own CoreTypes at run time
 * and never copied into PowerEmu. macOS no longer has the G4 Cube, so
 * PowerEmu carries that one picture. If a future macOS drops any of the
 * others, that model falls back to a plain symbol.
 *
 * The Tiger install disc and "Macintosh HD" pictures come from the reader's
 * own install disc, saved when PowerEmu first reads it (see `DiscIcons`).
 */
/// A processor configuration Apple shipped: speed, and one or two G4s.
struct CPUConfig: Hashable, Identifiable {
    let mhz: Int
    var dual = false
    var id: String { "\(dual ? 2 : 1)x\(mhz)" }

    /// "867 MHz", "1.42 GHz", "1 GHz".
    var speed: String {
        if mhz < 1000 { return "\(mhz) MHz" }
        var g = String(format: "%.2f", Double(mhz) / 1000)
        while g.hasSuffix("0") { g.removeLast() }
        if g.hasSuffix(".") { g.removeLast() }
        return "\(g) GHz"
    }
    /// How Apple sold it: "Dual 1.42 GHz".
    var label: String { (dual ? "Dual " : "") + speed }
    /// How Tiger's About This Mac shows it.
    var aboutText: String { (dual ? "2 x " : "") + speed + " PowerPC G4" }
}

struct MacModel: Identifiable, Hashable {
    let id: String
    let name: String
    /// A system type whose icon is this Mac, if macOS has one.
    let systemType: String?
    let laptop: Bool
    /// What Apple shipped, slowest first; the last is the default.
    var cpus: [CPUConfig] = []

    private static func c(_ list: [(Int, Bool)]) -> [CPUConfig] { list.map { CPUConfig(mhz: $0.0, dual: $0.1) } }

    static let all: [MacModel] = [
        MacModel(id: "powermac-g4-mdd", name: "Power Mac G4 (Mirrored Drive Doors)",
                 systemType: "com.apple.powermac-g4-mirrored-drive-doors", laptop: false,
                 cpus: c([(867, false), (867, true), (1000, true), (1250, false), (1250, true), (1420, true)])),
        MacModel(id: "powermac-g4-quicksilver", name: "Power Mac G4 (Quicksilver)",
                 systemType: "com.apple.powermac-g4-quicksilver", laptop: false,
                 cpus: c([(733, false), (800, false), (867, false), (933, false), (800, true), (1000, true)])),
        MacModel(id: "powermac-g4-agp", name: "Power Mac G4 (AGP Graphics)",
                 systemType: "com.apple.powermac-g4-graphite", laptop: false,
                 cpus: c([(350, false), (400, false), (450, false), (500, false), (450, true), (500, true)])),
        MacModel(id: "powermac-g4-cube", name: "Power Mac G4 Cube", systemType: nil, laptop: false,
                 cpus: c([(450, false), (500, false)])),
        MacModel(id: "macmini-g4", name: "Mac mini G4", systemType: "com.apple.macmini", laptop: false,
                 cpus: c([(1250, false), (1330, false), (1420, false), (1500, false)])),
        MacModel(id: "powerbook-g4-titanium", name: "PowerBook G4 (Titanium)",
                 systemType: "com.apple.powerbook-g4-titanium", laptop: true,
                 cpus: c([(400, false), (500, false), (550, false), (667, false), (800, false), (867, false), (1000, false)])),
        MacModel(id: "powerbook-g4-12", name: "PowerBook G4 12-inch", systemType: "com.apple.powerbook-g4-12", laptop: true,
                 cpus: c([(867, false), (1000, false), (1330, false), (1500, false)])),
        MacModel(id: "powerbook-g4-15", name: "PowerBook G4 15-inch", systemType: "com.apple.powerbook-g4-15", laptop: true,
                 cpus: c([(1000, false), (1250, false), (1330, false), (1500, false), (1670, false)])),
        MacModel(id: "powerbook-g4-17", name: "PowerBook G4 17-inch", systemType: "com.apple.powerbook-g4-17", laptop: true,
                 cpus: c([(1000, false), (1330, false), (1500, false), (1670, false)])),
        MacModel(id: "ibook-g4", name: "iBook G4", systemType: "com.apple.ibook-g4-12", laptop: true,
                 cpus: c([(800, false), (933, false), (1000, false), (1070, false), (1200, false),
                          (1250, false), (1330, false), (1420, false)])),
        // Not a real Mac: PowerEmu's own icon, with any G4 configuration.
        MacModel(id: "poweremu", name: "PowerEmu", systemType: nil, laptop: false,
                 cpus: c([(350, false), (400, false), (450, false), (500, false), (550, false), (667, false),
                          (733, false), (800, false), (867, false), (933, false), (1000, false), (1250, false),
                          (1330, false), (1420, false), (1500, false), (1670, false),
                          (450, true), (500, true), (800, true), (867, true), (1000, true), (1250, true), (1420, true)])),
    ]

    var defaultCPU: CPUConfig { cpus.last ?? CPUConfig(mhz: 1000) }

    /// The name System Profiler shows for this Mac.
    var profilerName: String { id == "poweremu" ? "PowerEmu Virtual Mac" : name }

    static let standard = all[0]

    static func named(_ id: String?) -> MacModel? { all.first { $0.id == id } }

    /// The picture, or nil when neither macOS nor PowerEmu has one.
    var image: NSImage? {
        if let cached = Self.cache[id] { return cached }
        var img: NSImage?
        if let t = systemType {
            let file = "/System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/\(t).icns"
            // Read from macOS's own copy on this Mac; not every one of
            // these is a declared type, so ask for the file itself.
            if FileManager.default.fileExists(atPath: file) {
                img = NSImage(contentsOfFile: file)
            }
        } else if id == "poweremu" {
            img = NSApp.applicationIconImage
        } else if let url = Bundle.main.url(forResource: id, withExtension: "png")
                    ?? Self.devResource(id) {
            img = NSImage(contentsOf: url)
        }
        Self.cache[id] = img
        return img
    }

    var symbol: String { laptop ? "laptopcomputer" : "desktopcomputer" }

    nonisolated(unsafe) private static var cache: [String: NSImage?] = [:]

    /// Running from the repository: app/Resources/Models.
    private static func devResource(_ name: String) -> URL? {
        let u = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/Models/\(name).png")
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }
}

/// The pictures PowerEmu keeps from the reader's own install disc, one set
/// per system: Tiger's installer and Leopard's do not look alike, and the
/// wizard should show whichever disc is in front of the reader.
enum DiscIcons {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Icons", isDirectory: true)
    }

    /// "10.4.11" -> "10.4": one set per system, not per point release.
    static func family(_ version: String?) -> String {
        let v = version ?? "10.4"
        return v.split(separator: ".").prefix(2).joined(separator: ".")
    }

    private static func name(_ family: String) -> String {
        family == "10.5" ? "leopard" : "tiger"
    }

    static func installDisc(_ version: String?) -> URL {
        folder.appendingPathComponent("\(name(family(version)))-install-disc.icns")
    }
    static func hardDisk(_ version: String?) -> URL {
        folder.appendingPathComponent("\(name(family(version)))-hard-disk.icns")
    }

    static func installDiscImage(_ version: String?) -> NSImage? {
        NSImage(contentsOf: installDisc(version))
    }
    static func hardDiskImage(_ version: String?) -> NSImage? {
        NSImage(contentsOf: hardDisk(version)) ?? NSImage(contentsOf: hardDisk("10.4"))
    }

    /// Copy the install and hard disk icons off a mounted disc.
    ///
    /// Tiger keeps its installer in a folder called "Install Mac OS X";
    /// Leopard's is an application bundle, "Install Mac OS X.app".  Both
    /// are looked for, so either disc gives the wizard its own picture.
    static func save(fromDiscAt root: URL, version: String?) {
        let fm = FileManager.default
        try? fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let installer = [
            "Install Mac OS X/Contents/Resources/Install Mac OS X.icns",
            "Install Mac OS X.app/Contents/Resources/Install Mac OS X.icns",
        ].map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        let disk = [
            "System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/Internal.icns",
            "System/Library/Extensions/IOStorageFamily.kext/Contents/Resources/Internal.icns",
        ].map { root.appendingPathComponent($0) }.first { fm.fileExists(atPath: $0.path) }
        for (src, dst) in [(installer, installDisc(version)), (disk, hardDisk(version))] {
            guard let src, fm.fileExists(atPath: src.path) else { continue }
            try? fm.removeItem(at: dst)
            try? fm.copyItem(at: src, to: dst)
        }
    }
}

/// Tiger's About This Mac picture (214 x 124, the Apple logo over "Mac OS X"),
/// redrawn with the chosen Mac in place of the logo. PowerEmu draws it; no
/// Apple artwork is copied.
enum AboutBoxImage {
    static let size = NSSize(width: 214, height: 124)

    static func tiff(for model: MacModel) -> Data? {
        guard let picture = model.image else { return nil }
        guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSGraphicsContext.current?.imageInterpolation = .high
        // The Mac, where the logo was: centred, about 84 points tall.
        let side: CGFloat = 86
        picture.draw(in: NSRect(x: (size.width - side) / 2, y: size.height - side - 2, width: side, height: side),
                     from: .zero, operation: .sourceOver, fraction: 1)
        // "Mac OS X" underneath, as Tiger sets it.
        let font = NSFont(name: "LucidaGrande-Bold", size: 21) ?? .boldSystemFont(ofSize: 21)
        let text = NSAttributedString(string: "Mac OS X", attributes: [
            .font: font, .foregroundColor: NSColor(white: 0.12, alpha: 1)])
        let w = text.size().width
        text.draw(at: NSPoint(x: (size.width - w) / 2, y: 6))
        NSGraphicsContext.restoreGraphicsState()
        return rep.tiffRepresentation(using: .lzw, factor: 0)
    }
}
