import Foundation

/*
 * Installing Mac OS X with nobody at the keyboard.
 *
 * Apple built this in. When a Tiger install disc starts up, /etc/rc.cdrom
 * looks for /etc/minstallconfig.xml; if it is there, the Installer runs the
 * package it names onto the volume it names with no questions at all, and
 * restarts when done. (`InstallType` = `automated` is what stops it waiting
 * on its "Click Install" page.) Before the Installer, rc.cdrom also runs
 * /etc/rc.cdrom.local as root, which is where PowerEmu erases the blank disk
 * and names it "Macintosh HD".
 *
 * PowerEmu never touches the reader's disc image. It makes an APFS clone of
 * it (instant, no space until it differs), mounts the clone read-write on the
 * host and adds three things: those two files, and an edited OSInstall.dist
 * whose choices leave out what the reader turned off (extra languages,
 * printer drivers, extra fonts). The clone is deleted once installed.
 *
 * The guest has no network and no screen anyone is looking at, so it
 * reports through a 1 MB "mailbox" disk: sector 0 carries a signature the
 * guest finds it by, sector 1 is a status line, sector 2 the host's
 * instructions, sector 3 how full the new disk is, sectors 80 on a log.
 *
 * Measured on a retail 10.4.6 DVD (8I128): 11½ minutes from a blank disk to
 * the Installer's restart, then Setup Assistant on the accelerated card.
 */
enum InstallPlan {

    // MARK: Options

    struct Options {
        var disc: URL
        var diskGB: Int
        /// An Installer language (see `languages`).
        var language: String
        var additionalLanguages = false
        var printerDrivers = false
        var additionalFonts = false
        /// Install X11.  Mac OS X's installer never selects it, so unlike
        /// the others this one has to be turned on rather than left alone.
        var x11 = false
        /// Apply Apple's 10.4.11 combo update before Setup Assistant.
        var update10411 = false
        /// How About This Mac and System Profiler describe the Mac.
        var personalize: Personalize?
    }

    /// Cosmetic touches inside the guest. Each is a text or picture file
    /// Mac OS X only displays; the originals are kept beside them.
    struct Personalize {
        /// About This Mac's processor line, e.g. "2 x 1.42 GHz PowerPC G4".
        /// nil leaves Mac OS X's own (which already shows the chosen speed).
        var processorText: String?
        /// System Profiler's Machine Name.
        var modelName: String?
        /// A TIFF to show in About This Mac instead of the Apple logo.
        var aboutImage: Data?
    }

    /// Installer languages: (value rc.cdrom passes as AppleLanguages, name
    /// shown, OSInstall.dist choice for its translation, host language codes).
    struct Language: Hashable {
        let value: String
        let name: String
        let choice: String?
        let codes: [String]
    }

    static let languages: [Language] = [
        Language(value: "English", name: "English", choice: nil, codes: ["en"]),
        Language(value: "French", name: "Français", choice: "French", codes: ["fr"]),
        Language(value: "German", name: "Deutsch", choice: "German", codes: ["de"]),
        Language(value: "Japanese", name: "日本語", choice: "Japanese", codes: ["ja"]),
        Language(value: "Spanish", name: "Español", choice: "Spanish", codes: ["es"]),
        Language(value: "Italian", name: "Italiano", choice: "Italian", codes: ["it"]),
        Language(value: "Dutch", name: "Nederlands", choice: "Dutch", codes: ["nl"]),
        Language(value: "da", name: "Dansk", choice: "Danish", codes: ["da"]),
        Language(value: "fi", name: "Suomi", choice: "Finnish", codes: ["fi"]),
        Language(value: "ko", name: "한국어", choice: "Korean", codes: ["ko"]),
        Language(value: "no", name: "Norsk", choice: "Norwegian", codes: ["nb", "no", "nn"]),
        Language(value: "sv", name: "Svenska", choice: "Swedish", codes: ["sv"]),
        Language(value: "pt", name: "Português", choice: "BrazilianPortuguese", codes: ["pt"]),
        Language(value: "zh_CN", name: "简体中文", choice: "SimplifiedChinese", codes: ["zh-Hans", "zh_CN"]),
        Language(value: "zh_TW", name: "繁體中文", choice: "TraditionalChinese", codes: ["zh-Hant", "zh_TW"]),
    ]

    /// The Installer language matching this Mac's own, else English.
    static var hostLanguage: Language {
        for pref in Locale.preferredLanguages {
            for l in languages where l.codes.contains(where: { pref == $0 || pref.hasPrefix($0 + "-") || pref.hasPrefix($0 + "_") }) {
                return l
            }
        }
        return languages[0]
    }

    // MARK: The 10.4.11 combo update

    /// Apple's own download (support.apple.com/en-us/106535), and its
    /// published SHA-1. PowerEmu fetches it for the reader; it never ships it.
    static let comboURL = URL(string: "https://download.info.apple.com/Mac_OS_X/061-3461.20071114.8Uy45/MacOSXUpdCombo10.4.11PPC.dmg")!
    static let comboSHA1 = "3d403bfa769424c61a3cfac173f8527658f9d4af"
    static let comboFileName = "MacOSXUpdCombo10.4.11PPC.dmg"
    static let comboBytes: Int64 = 189_552_989

    /// Where a download of it is kept, so a second install doesn't fetch it again.
    static var comboCacheURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("PowerEmu/Updates/\(comboFileName)")
    }

    /// A copy the reader already has, if its size says it is Apple's file.
    /// (The SHA-1 is checked before it is used.)
    static var existingCombo: URL? {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        let places = [comboCacheURL,
                      home.appendingPathComponent("Downloads/\(comboFileName)"),
                      home.appendingPathComponent("Desktop/\(comboFileName)"),
                      home.appendingPathComponent("QEMU Project/\(comboFileName)")]
        return places.first { url in
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? nil
            return size == comboBytes
        }
    }

    // MARK: Inspecting the disc

    struct DiscInfo {
        let version: String        // "10.4.6"
        let build: String          // "8I128"
        /// rc.cdrom knows minstallconfig.xml, and OSInstall.mpkg is there.
        let automatable: Bool
        /// OSInstall.dist and each package's installed size (KB), for the
        /// estimate shown before installing.
        let dist: String
        let sizes: [String: Int]

        /// What these options install, in order.
        func packages(_ o: Options) -> [(name: String, kb: Int)] {
            let off = InstallPlan.choicesOff(o)
            let on = InstallPlan.choicesOn(o)
            let d = InstallPlan.turnOn(on, in: InstallPlan.turnOff(off, in: dist))
            return InstallPlan.packagesInOrder(dist: d, off: off, on: on, sizes: sizes)
        }
    }

    /// Mount the image read-only and read what it is. Blocking; seconds.
    static func inspect(_ disc: URL) throws -> DiscInfo {
        let mount = try Mount(image: disc, readWrite: false)
        defer { mount.detach() }
        let root = mount.point
        let sv = root.appendingPathComponent("System/Library/CoreServices/SystemVersion.plist")
        guard let plist = NSDictionary(contentsOf: sv) else {
            throw InstallError.notInstallDisc
        }
        let version = plist["ProductUserVisibleVersion"] as? String ?? "?"
        let build = plist["ProductBuildVersion"] as? String ?? "?"
        /*
         * What makes a disc drivable: it must run /etc/rc.cdrom.local, which
         * is where PowerEmu's own script goes, and read /etc/minstallconfig.xml,
         * which is where the answers go.  Tiger keeps both in etc/rc.cdrom;
         * Leopard moved most of that file into etc/rc.install and kept the
         * hooks, so both are read.
         */
        let rc = ["etc/rc.cdrom", "etc/rc.install"]
            .map { (try? String(contentsOf: root.appendingPathComponent($0), encoding: .utf8)) ?? "" }
            .joined(separator: "\n")
        let dist = (try? choices(at: root)) ?? ""
        DiscIcons.save(fromDiscAt: root, version: version)
        let automatable = rc.contains("minstallconfig") && rc.contains("rc.cdrom.local") && !dist.isEmpty
        return DiscInfo(version: version, build: build, automatable: automatable, dist: dist,
                        sizes: packageSizes(root.appendingPathComponent("System/Installation/Packages")))
    }

    /// The installer's choices document.
    ///
    /// Tiger's OSInstall.mpkg is a folder with the document inside it.
    /// Leopard's is a single flat archive (xar), with the document under the
    /// name "Distribution" -- so it has to be taken out to be read, and put
    /// back to be changed.
    static func mpkgURL(_ root: URL) -> URL {
        root.appendingPathComponent("System/Installation/Packages/OSInstall.mpkg")
    }

    static func isFlatPackage(_ url: URL) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &dir) && !dir.boolValue
    }

    static func choices(at root: URL) throws -> String {
        let mpkg = mpkgURL(root)
        if !isFlatPackage(mpkg) {
            return try String(contentsOf: mpkg.appendingPathComponent("Contents/OSInstall.dist"), encoding: .utf8)
        }
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("poweremu-dist-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        _ = try run("/usr/bin/xar", ["-x", "-f", mpkg.path, "-C", tmp.path, "Distribution"])
        return try String(contentsOf: tmp.appendingPathComponent("Distribution"), encoding: .utf8)
    }

    /// Put a changed choices document back where it came from.
    static func writeChoices(_ dist: String, at root: URL) throws {
        let mpkg = mpkgURL(root)
        if !isFlatPackage(mpkg) {
            try dist.write(to: mpkg.appendingPathComponent("Contents/OSInstall.dist"),
                           atomically: false, encoding: .utf8)
            return
        }
        // A flat archive has to be unpacked, changed and packed again: it is
        // under a megabyte, so this costs nothing worth saving.
        let fm = FileManager.default
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("poweremu-mpkg-\(UUID().uuidString.prefix(8))")
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        _ = try run("/usr/bin/xar", ["-x", "-f", mpkg.path, "-C", tmp.path])
        try dist.write(to: tmp.appendingPathComponent("Distribution"), atomically: false, encoding: .utf8)
        let rebuilt = tmp.appendingPathComponent("rebuilt.mpkg")
        // --distribution keeps it a distribution package rather than a plain
        // archive, which is what the Installer will open.
        // --prop-include: xar leaves ownership and creation times out of a
        // new archive unless asked, and the original carries them for all
        // of its files.  A package that arrives with everything owned by
        // whoever repacked it is not what the Installer was given.
        _ = try run("/usr/bin/xar", ["-c", "-f", rebuilt.path, "--distribution", "-C", tmp.path,
                                     "--prop-include", "uid", "--prop-include", "gid",
                                     "--prop-include", "ctime",
                                     "Distribution", "Resources"])
        try? fm.removeItem(at: mpkg)
        try fm.moveItem(at: rebuilt, to: mpkg)
    }

    // MARK: Preparing the disc

    /// What the prepared disc will install, for the progress bar: packages in
    /// install order with their installed sizes (KB, from each package's
    /// Info.plist), so "how full is Macintosh HD" becomes both a fraction and
    /// the name of the package being written.
    struct Prepared {
        let disc: URL
        let packages: [(name: String, kb: Int)]
        var expectedKB: Int { packages.reduce(0) { $0 + $1.kb } }
    }

    /// Clone `options.disc` to `dest` and add the unattended-install files.
    static func prepare(_ options: Options, to dest: URL) throws -> Prepared {
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        try cloneOrCopy(options.disc, to: dest)
        let mount = try Mount(image: dest, readWrite: true)
        defer { mount.detach() }
        let root = mount.point
        guard var dist = try? choices(at: root) else {
            throw InstallError.notInstallDisc
        }
        let off = choicesOff(options)
        let on = choicesOn(options)
        /*
         * How the options are applied depends on the installer's shape.
         *
         * Tiger's package is a folder, and its choices document is edited
         * in place -- it has always worked and there is no reason to change
         * it.  Leopard's is a single flat archive, and a package this Mac
         * has unpacked and packed again is refused outright, so its options
         * go in a choice-changes file instead and the package is left
         * exactly as Apple shipped it.
         */
        let flat = isFlatPackage(mpkgURL(root))
        if flat {
            let cc = root.appendingPathComponent(choiceChangesPath)
            try? fm.createDirectory(at: cc.deletingLastPathComponent(), withIntermediateDirectories: true)
            try choiceChanges(off: off, on: on).write(to: cc, atomically: false, encoding: .utf8)
        } else {
            dist = turnOff(off, in: dist)
            dist = turnOn(on, in: dist)
            try writeChoices(dist, at: root)
        }

        let etc = root.appendingPathComponent("etc")
        try minstallConfig(language: options.language, choiceChanges: flat)
            .write(to: etc.appendingPathComponent("minstallconfig.xml"),
                   atomically: false, encoding: .utf8)
        let hook = etc.appendingPathComponent("rc.cdrom.local")
        try hookScript.write(to: hook, atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)

        let item = root.appendingPathComponent("System/Installation/PowerEmu/PEUpdate")
        try? fm.removeItem(at: item)
        try fm.createDirectory(at: item, withIntermediateDirectories: true)
        try updateScript.write(to: item.appendingPathComponent("PEUpdate"), atomically: false, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: item.appendingPathComponent("PEUpdate").path)
        try updateParameters.write(to: item.appendingPathComponent("StartupParameters.plist"), atomically: false, encoding: .utf8)

        let pz = root.appendingPathComponent("System/Installation/PowerEmu/PEPersonalize")
        try? fm.removeItem(at: pz)
        if let p = options.personalize {
            try fm.createDirectory(at: pz, withIntermediateDirectories: true)
            try personalizeScript.write(to: pz.appendingPathComponent("PEPersonalize"), atomically: false, encoding: .utf8)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pz.appendingPathComponent("PEPersonalize").path)
            try personalizeParameters.write(to: pz.appendingPathComponent("StartupParameters.plist"), atomically: false, encoding: .utf8)
            if let t = p.processorText { try t.write(to: pz.appendingPathComponent("processor.txt"), atomically: false, encoding: .utf8) }
            if let m = p.modelName { try m.write(to: pz.appendingPathComponent("model.txt"), atomically: false, encoding: .utf8) }
            if let img = p.aboutImage { try img.write(to: pz.appendingPathComponent("AboutThisMac.tiff")) }
        }
        sync()

        let pkgs = packagesInOrder(dist: dist, off: off,
                                   sizes: packageSizes(root.appendingPathComponent("System/Installation/Packages")))
        return Prepared(disc: dest, packages: pkgs)
    }

    /// Choice ids in OSInstall.dist to switch off for these options.
    static func choicesOff(_ o: Options) -> Set<String> {
        var off: Set<String> = []
        let lang = languages.first { $0.value == o.language }
        if !o.additionalLanguages {
            off.insert("AsianLanguagesSupport")
            for l in languages { if let c = l.choice, c != lang?.choice { off.insert(c) } }
        }
        if !o.additionalFonts { off.insert("AdditionalFonts") }
        // Leopard selects X11 by default; Tiger does not.  Saying so either
        // way costs nothing and means the switch means the same thing on both.
        if !o.x11 { off.insert("X11") }
        if !o.printerDrivers {
            // Both systems' vendors: Tiger has EFI and Gimp, Leopard has
            // Guten, FujiXerox and Samsung instead.  A choice that a disc
            // does not have is simply never found, so naming all of them
            // costs nothing and keeps one list.
            for p in ["Brother", "Canon", "EFI", "Epson", "HP", "Lexmark", "Gimp",
                      "Ricoh", "Xerox", "Guten", "FujiXerox", "Samsung"] {
                off.insert(p + "_Printer_Drivers")
            }
        }
        return off
    }

    /// Choices to switch on that Mac OS X would leave off.
    static func choicesOn(_ o: Options) -> Set<String> {
        o.x11 ? ["X11"] : []
    }

    /// Set start_selected and selected to "true" on these choices: the
    /// mirror of turnOff, for the things the Installer ships switched off.
    static func turnOn(_ on: Set<String>, in dist: String) -> String {
        guard !on.isEmpty else { return dist }
        let re = try! NSRegularExpression(pattern: #"<choice\s[^>]*>"#, options: [.dotMatchesLineSeparators])
        let ns = dist as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: dist, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var el = ns.substring(with: m.range)
            if let id = firstMatch(#"id="([^"]+)""#, in: el), on.contains(id) {
                el = replace(#"start_selected\s*=\s*"[^"]*""#, in: el, with: #"start_selected="true""#)
                el = replace(#"(?<!start_)selected\s*=\s*"[^"]*""#, in: el, with: #"selected="true""#)
                if !el.contains("start_selected") {
                    el = el.replacingOccurrences(of: "<choice", with: #"<choice start_selected="true""#)
                }
            }
            out += el
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Set start_selected and selected to "false" on these choices.
    static func turnOff(_ off: Set<String>, in dist: String) -> String {
        let re = try! NSRegularExpression(pattern: #"<choice\s[^>]*>"#, options: [.dotMatchesLineSeparators])
        let ns = dist as NSString
        var out = ""
        var last = 0
        for m in re.matches(in: dist, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            var el = ns.substring(with: m.range)
            if let id = firstMatch(#"id="([^"]+)""#, in: el), off.contains(id) {
                el = replace(#"start_selected\s*=\s*"[^"]*""#, in: el, with: #"start_selected="false""#)
                el = replace(#"(?<!start_)selected\s*=\s*"[^"]*""#, in: el, with: #"selected="false""#)
                if !el.contains("start_selected") {
                    el = el.replacingOccurrences(of: "<choice", with: #"<choice start_selected="false""#)
                }
            }
            out += el
            last = m.range.location + m.range.length
        }
        out += ns.substring(from: last)
        return out
    }

    /// Packages the Installer will write, in the order it writes them: the
    /// dist's choices in document order, each choice's pkg-refs in turn.
    /// Each package's installed size in KB, by file name without ".pkg".
    static func packageSizes(_ dir: URL) -> [String: Int] {
        var sizes: [String: Int] = [:]
        for name in (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [] where name.hasSuffix(".pkg") {
            let pkg = dir.appendingPathComponent(name)
            let key = String(name.dropLast(4))
            if !isFlatPackage(pkg) {
                if let kb = NSDictionary(contentsOf: pkg.appendingPathComponent("Contents/Info.plist"))?["IFPkgFlagInstalledSize"] as? Int {
                    sizes[key] = kb
                }
                continue
            }
            // Flat (Leopard): the size is an attribute in PackageInfo.
            if let kb = flatPackageKB(pkg) { sizes[key] = kb }
        }
        return sizes
    }

    /// installKBytes from a flat package's PackageInfo.
    private static func flatPackageKB(_ pkg: URL) -> Int? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("poweremu-pkginfo-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard (try? run("/usr/bin/xar", ["-x", "-f", pkg.path, "-C", tmp.path, "PackageInfo"])) != nil,
              let text = try? String(contentsOf: tmp.appendingPathComponent("PackageInfo"), encoding: .utf8),
              let kb = firstMatch(#"installKBytes="(\d+)""#, in: text) else { return nil }
        return Int(kb)
    }

    static func packagesInOrder(dist: String, off: Set<String>, on: Set<String> = [],
                                sizes: [String: Int]) -> [(name: String, kb: Int)] {
        // pkg-ref id -> file name
        var files: [String: String] = [:]
        // Tiger writes file:../Foo.pkg, Leopard file:./Foo.pkg.
        let refRE = try! NSRegularExpression(pattern: #"<pkg-ref\s+id="([^"]+)"[^>]*>\s*file:\.{1,2}/([^<]+?)\.pkg\s*</pkg-ref>"#)
        let ns = dist as NSString
        for m in refRE.matches(in: dist, range: NSRange(location: 0, length: ns.length)) {
            files[ns.substring(with: m.range(at: 1))] = ns.substring(with: m.range(at: 2))
        }
        // Choices the Installer leaves off unless they were asked for.
        let neverOn = Set(["X11"]).subtracting(on)
        let choiceRE = try! NSRegularExpression(pattern: #"<choice\s([^>]*)>(.*?)</choice>"#, options: [.dotMatchesLineSeparators])
        var seen: Set<String> = []
        var order: [(String, Int)] = []
        for m in choiceRE.matches(in: dist, range: NSRange(location: 0, length: ns.length)) {
            let attrs = ns.substring(with: m.range(at: 1))
            let body = ns.substring(with: m.range(at: 2))
            guard let id = firstMatch(#"id="([^"]+)""#, in: attrs), !off.contains(id), !neverOn.contains(id) else { continue }
            let innerRE = try! NSRegularExpression(pattern: #"<pkg-ref\s+id="([^"]+)""#)
            let b = body as NSString
            for r in innerRE.matches(in: body, range: NSRange(location: 0, length: b.length)) {
                let ref = b.substring(with: r.range(at: 1))
                guard let file = files[ref], !seen.contains(file), file != "OSInstall" else { continue }
                seen.insert(file)
                if let kb = sizes[file], kb > 0 { order.append((file, kb)) }
            }
        }
        return order
    }

    /// "AdditionalEssentials" -> "Additional Essentials".
    static func displayName(ofPackage p: String) -> String {
        switch p {
        case "BSD": return "BSD Subsystem"
        case "BaseSystem": return "Base System"
        case "iCal", "iChat", "iTunes": return p
        case "X11User": return "X11"
        default:
            var s = ""
            for (i, ch) in p.enumerated() {
                if i > 0, ch.isUppercase, let prev = s.last, prev.isLowercase { s.append(" ") }
                s.append(ch)
            }
            return s.replacingOccurrences(of: "Printer Drivers", with: "printer drivers")
        }
    }

    private static func firstMatch(_ pattern: String, in s: String) -> String? {
        let re = try! NSRegularExpression(pattern: pattern)
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)), m.numberOfRanges > 1 else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    private static func replace(_ pattern: String, in s: String, with t: String) -> String {
        let re = try! NSRegularExpression(pattern: pattern)
        return re.stringByReplacingMatches(in: s, range: NSRange(location: 0, length: (s as NSString).length),
                                           withTemplate: NSRegularExpression.escapedTemplate(for: t))
    }

    // MARK: Erasing "Macintosh HD" on the host

    /// Replace `disk` (a qcow2) with an erased one: an Apple partition map
    /// and one Mac OS Extended (Journaled) volume, made by this Mac's own
    /// diskutil on a sparse raw image and converted.  A second or two, the
    /// same for every install disc, and it fails here rather than inside a
    /// guest nobody can see.
    ///
    /// The partition map matters more than it looks: `diskutil` lays a disk
    /// out the way Disk Utility does on the guest, and an installed Mac OS X
    /// will only bless a disk laid out that way.  A disk that arrives with
    /// no map at all -- or with one from `hdiutil create -layout SPUD` --
    /// takes the whole install and then fails on the last step with "could
    /// not make the computer start up from the volume".
    static func formatDisk(_ disk: URL, gigabytes: Int, named volume: String = "Macintosh HD",
                           qemuImg: URL) throws {
        let fm = FileManager.default
        let raw = disk.deletingPathExtension().appendingPathExtension("erase.img")
        try? fm.removeItem(at: raw)
        defer { try? fm.removeItem(at: raw) }
        guard fm.createFile(atPath: raw.path, contents: nil),
              let h = try? FileHandle(forWritingTo: raw) else {
            throw InstallError.failed("“\(volume)” could not be created.")
        }
        try h.truncate(atOffset: UInt64(gigabytes) << 30)       // sparse
        try h.close()

        let attach = try run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-plist",
                                                   "-imagekey", "diskimage-class=CRawDiskImage", raw.path])
        let plist = (try? PropertyListSerialization.propertyList(from: attach, format: nil)) as? [String: Any]
        guard let dev = (plist?["system-entities"] as? [[String: Any]])?.compactMap({ $0["dev-entry"] as? String }).first else {
            throw InstallError.failed("“\(volume)” could not be attached for erasing.")
        }
        do {
            _ = try run("/usr/sbin/diskutil", ["partitionDisk", dev, "1", "APM", "JHFS+", volume, "100%"])
        } catch {
            _ = try? run("/usr/bin/hdiutil", ["detach", "-force", dev])
            throw InstallError.failed("“\(volume)” could not be erased. \(error.localizedDescription)")
        }
        _ = try? run("/usr/bin/hdiutil", ["detach", dev])
        let tmp = disk.deletingPathExtension().appendingPathExtension("new.qcow2")
        try? fm.removeItem(at: tmp)
        _ = try run(qemuImg.path, ["convert", "-O", "qcow2", raw.path, tmp.path])
        try? fm.removeItem(at: disk)
        try fm.moveItem(at: tmp, to: disk)
    }

    /// Run a tool, return its standard output, throw with its error output.
    @discardableResult
    static func run(_ tool: String, _ args: [String]) throws -> Data {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let msg = (String(data: e, encoding: .utf8) ?? "") + (String(data: data, encoding: .utf8) ?? "")
            throw InstallError.failed(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return data
    }

    // MARK: The mailbox

    static let signature = "PEMBOX"

    /// A fresh mailbox for an install of `diskGB`, optionally asking for the
    /// 10.4.11 update item.
    static func writeMailbox(_ url: URL, diskGB: Int, update: Bool) throws {
        var data = Data(count: 1024 * 1024)
        func put(_ sector: Int, _ text: String) {
            let bytes = Array(text.utf8.prefix(511))
            data.replaceSubrange(sector * 512 ..< sector * 512 + bytes.count, with: bytes)
        }
        put(0, signature)
        // The whole disk less room for the Apple partition map.
        put(2, "SIZE_MB=\(diskGB * 1024 - 64)\nCOMBO=\(update ? 1 : 0)\n")
        try data.write(to: url)
    }

    struct MailboxState {
        var status = ""
        var usedKB: Int?
        var log = ""
    }

    static func readMailbox(_ url: URL) -> MailboxState {
        guard let h = try? FileHandle(forReadingFrom: url) else { return MailboxState() }
        defer { try? h.close() }
        let d = (try? h.read(upToCount: 128 * 512)) ?? Data()
        func text(_ from: Int, _ to: Int) -> String {
            guard d.count >= to * 512 else { return "" }
            let slice = d[from * 512 ..< to * 512]
            let upToNul = slice.prefix { $0 != 0 }
            return String(decoding: upToNul, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var s = MailboxState()
        s.status = text(1, 2)
        let p = text(3, 4)
        if let r = p.range(of: "USED_KB=") { s.usedKB = Int(p[r.upperBound...].prefix { $0.isNumber }) }
        s.log = text(80, 128)
        return s
    }

    // MARK: Files put on the disc

    /// The options, as a list of changes rather than a rewritten package.
    ///
    /// Mac OS X 10.5's Installer reads a "choice changes" file -- the same
    /// thing `installer -applyChoiceChangesXML` takes -- and applies it to
    /// the package's own choices.  That is much safer than editing the
    /// package: 10.5's Installer would not read one this Mac had unpacked
    /// and packed again, and said only "there was a problem with the
    /// automated installation", which is also what it says when the disk is
    /// too small or the target is missing.
    static func choiceChanges(off: Set<String>, on: Set<String>) -> String {
        var body = ""
        for (ids, setting) in [(off.sorted(), 0), (on.sorted(), 1)] {
            for id in ids {
                body += "\t<dict>\n"
                body += "\t\t<key>choiceIdentifier</key>\n\t\t<string>\(id)</string>\n"
                body += "\t\t<key>choiceAttribute</key>\n\t\t<string>selected</string>\n"
                body += "\t\t<key>attributeSetting</key>\n\t\t<integer>\(setting)</integer>\n"
                body += "\t</dict>\n"
            }
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <array>
        \(body)</array>
        </plist>

        """
    }

    /// Where the choice-changes file goes on the disc.  The Installer looks
    /// for it by this name, and is told the path in the automation file.
    static let choiceChangesPath = "private/var/db/MacOSXInstaller.choiceChanges"

    static func minstallConfig(language: String, choiceChanges: Bool = false) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple Computer//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        \t<key>InstallType</key>
        \t<string>automated</string>
        \t<key>Language</key>
        \t<string>\(language)</string>
        \t<key>Package</key>
        \t<string>/System/Installation/Packages/OSInstall.mpkg</string>
        \t<key>Target</key>
        \t<string>/Volumes/Macintosh HD</string>
        \(choiceChanges ? "\t<key>Choice Changes File Location</key>\n\t<string>/" + choiceChangesPath + "</string>\n" : "")</dict>
        </plist>

        """
    }

    /// Run by rc.cdrom as root before the Installer. The install DVD has no
    /// grep and no tail: perl does their jobs.
    ///
    /// "Macintosh HD" normally arrives already erased by the host (see
    /// `formatDisk`), so this only has to find it mounted. If the disk is
    /// blank (the host couldn't erase it) it is erased here, with the
    /// DVD's own diskutil -- whose arguments changed during 10.4, so both
    /// forms are tried.
    static let hookScript = #"""
    #!/bin/sh
    M=""
    for d in 0 1 2 3 4 5 6; do
      [ -e /dev/rdisk$d ] || continue
      dd if=/dev/rdisk$d bs=512 count=1 2>/dev/null | perl -e 'read(STDIN,$b,512); exit($b=~/PEMBOX/?0:1)' && M=/dev/rdisk$d
    done
    r(){ [ -n "$M" ] && echo "$1" | dd of=$M bs=512 seek=1 count=1 conv=sync 2>/dev/null; }
    out(){ [ -n "$M" ] && dd of=$M bs=512 seek=80 count=48 conv=sync 2>/dev/null; }
    r "HOOK $M"
    # The target: not the mailbox, not the disc we started from.
    ROOT=$(df / | perl -ne 'print $1 if m{^/dev/(disk\d+)}')
    T=""
    for d in 0 1 2 3 4 5 6; do
      [ -e /dev/rdisk$d ] || continue
      [ "/dev/rdisk$d" = "$M" ] && continue
      [ "disk$d" = "$ROOT" ] && continue
      T=disk$d; break
    done
    SZ=$(dd if=$M bs=512 skip=2 count=1 2>/dev/null | perl -ne 'print $1 if /SIZE_MB=(\d+)/')
    CO=$(dd if=$M bs=512 skip=2 count=1 2>/dev/null | perl -ne 'print $1 if /COMBO=(\d)/')
    r "TARGET $T"
    [ -z "$T" ] && { r "NOTARGET"; exit 0; }
    {
      echo "== diskutil list"; diskutil list
      Z=$(dd if=/dev/r$T bs=512 count=2 2>/dev/null | perl -e 'read(STDIN,$b,1024); print(($b!~/[^\0]/) ? "Z" : "N")')
      if [ "$Z" = "Z" ]; then
        echo "== blank: erasing here"
        [ -z "$SZ" ] && SZ=10000
        diskutil partitionDisk $T 1 APMFormat "Journaled HFS+" "Macintosh HD" ${SZ}M \
          || diskutil partitionDisk $T 1 "Journaled HFS+" "Macintosh HD" ${SZ}M
      else
        echo "== erased by the host: mounting"
        i=0
        while [ ! -d "/Volumes/Macintosh HD" ] && [ $i -lt 10 ]; do sleep 2; i=$((i+1)); done
        [ -d "/Volumes/Macintosh HD" ] || diskutil mountDisk $T
      fi
      i=0
      while [ ! -d "/Volumes/Macintosh HD" ] && [ $i -lt 10 ]; do sleep 2; i=$((i+1)); done
      echo "== volumes"; ls -la /Volumes
    } > /var/tmp/pe-part.txt 2>&1
    out < /var/tmp/pe-part.txt
    if [ ! -d "/Volumes/Macintosh HD" ]; then r "PARTFAIL"; exit 0; fi
    if [ "$CO" = "1" ]; then ST="PARTOK COMBO"; else ST="PARTOK"; fi
    r "$ST"
    # Report how full the disk is. For the 10.4.11 update, put its item on
    # the disk once the Installer has laid down /Library (it replaces
    # /Library/StartupItems wholesale, so anything put there first is lost),
    # and put it back if it goes missing, until the Installer restarts.
    I="/Volumes/Macintosh HD/Library/StartupItems"
    ( while :; do
        U=$(df -k "/Volumes/Macintosh HD" | perl -ne 'print((split)[2]) if $.==2')
        echo "USED_KB=$U" | dd of=$M bs=512 seek=3 count=1 conv=sync 2>/dev/null
        if [ -d /System/Installation/PowerEmu/PEPersonalize ] && [ -d "/Volumes/Macintosh HD/Library/Receipts/BaseSystem.pkg" ] && [ ! -x "$I/PEPersonalize/PEPersonalize" ]; then
          mkdir -p "$I" && cp -R /System/Installation/PowerEmu/PEPersonalize "$I/"
        fi
        if [ "$CO" = "1" ] && [ -d "/Volumes/Macintosh HD/Library/Receipts/BaseSystem.pkg" ] && [ ! -x "$I/PEUpdate/PEUpdate" ]; then
          mkdir -p "$I" && cp -R /System/Installation/PowerEmu/PEUpdate "$I/" \
            && { ST="PARTOK COMBOITEM"; r "$ST"; }
        fi
        # No login window during the update's startup: Setup Assistant
        # starting underneath the update leaves Apple's installer waiting on
        # it forever. PEUpdate puts the line back before it powers off.
        TT="/Volumes/Macintosh HD/private/etc/ttys"
        if [ "$CO" = "1" ] && [ -f "$TT" ] && perl -ne '$f=1 if /^console\s.*loginwindow.*\son\s/; END { exit($f ? 0 : 1) }' "$TT"; then
          [ -f "$TT.pe-orig" ] || cp -p "$TT" "$TT.pe-orig"
          perl -pi -e 's/^(console\s.*loginwindow.*\s)on(\s)/${1}off$2/' "$TT"
        fi
        # Bless the new system ourselves.
        #
        # The Installer's own last step is `bless --setBoot`, which asks Open
        # Firmware for its variables; this machine cannot answer, so bless
        # dies on the error and the Installer reports "could not make the
        # computer start up from the volume" over a system that is complete
        # and correct.  Blessing without --setBoot works, and the startup
        # disk is PowerEmu's to choose anyway.  Doing it as soon as the files
        # are down means the volume is bootable whatever the Installer then
        # says.  If the Installer manages it first, BootX is already there
        # and this does nothing.
        V="/Volumes/Macintosh HD"
        if [ -f "$V/var/log/OSInstall.custom" ] && [ ! -f "$V/System/Library/CoreServices/BootX" ] \
           && [ -f "$V/usr/standalone/ppc/bootx.bootinfo" ]; then
          bless --folder "$V/System/Library/CoreServices" \
                --bootinfo "$V/usr/standalone/ppc/bootx.bootinfo" >/var/tmp/pe-bless.txt 2>&1
          case "$ST" in *BLESS*) ;; *) ST="$ST BLESSED" ;; esac
          if [ ! -f "$V/System/Library/CoreServices/BootX" ]; then
            ST="${ST% BLESSED} BLESSFAIL"
            out < /var/tmp/pe-bless.txt      # only worth the log space when it fails
          fi
          r "$ST"
        fi
        sleep 4
      done ) &
    exit 0
    """#

    /// A StartupItem put on the new disk when the reader chose 10.4.11. It
    /// runs on the first startup, before Setup Assistant, under the full
    /// multi-user system: the combo's own "Optimizing System Performance"
    /// step fails when the update is installed from single-user mode, and
    /// that failure leaves WindowServer crashing on every start.
    static let updateScript = #"""
    #!/bin/sh
    # PowerEmu: apply the Mac OS X 10.4.11 combo update before Setup
    # Assistant, in two stages, each ending in a power-off:
    #   1. install the update from the disc;
    #   2. after Apple's own startup-time step has moved the new system files
    #      into place (it restarts the Mac to do it), rebuild the kernel
    #      extension cache, put the login window back and remove this item.
    # PowerEmu starts the machine cold for each boot: never a warm restart.
    # Progress goes to the PowerEmu mailbox (sector 1 status, 80 on log).
    . /etc/rc.common
    LOG=/var/log/pe-update.log
    STAGE=/var/db/.pe-update-stage
    M=""
    for d in 0 1 2 3 4 5 6; do
      [ -e /dev/rdisk$d ] || continue
      dd if=/dev/rdisk$d bs=512 count=1 2>/dev/null | perl -e 'read(STDIN,$b,512); exit($b=~/PEMBOX/?0:1)' && M=/dev/rdisk$d
    done
    r(){ [ -n "$M" ] && echo "$1" | dd of=$M bs=512 seek=1 count=1 conv=sync 2>/dev/null; }
    out(){ [ -n "$M" ] && dd of=$M bs=512 seek=80 count=48 conv=sync 2>/dev/null; }
    # Put the login window back (the install switched it off for this start).
    restore(){ [ -f /etc/ttys.pe-orig ] && mv -f /etc/ttys.pe-orig /etc/ttys; sync; }
    done_(){ restore; rm -f $STAGE; rm -rf /Library/StartupItems/PEUpdate; sync; sync; }
    # Only while PowerEmu is installing (its setup disk is attached). On any
    # other start, tidy up and get out of the way: never stop a normal boot.
    if [ -z "$M" ]; then done_; kill -HUP 1; exit 0; fi

    if [ -f $STAGE ]; then
      # Stage 2: Apple's startup-time step has run.
      r "COMBOFINISH Rebuilding the kernel extension cache"
      echo "stage 2 $(date)" >> $LOG
      /usr/sbin/kextcache -a ppc -m /System/Library/Extensions.mkext /System/Library/Extensions >> $LOG 2>&1
      done_
      r "COMBODONE"
      tail -20 $LOG | out
      sleep 2
      /sbin/shutdown -h now
      exit 0
    fi

    echo "PEUpdate start $(date)" > $LOG
    r "COMBO Waiting for the update disc"
    mkdir -p /pemnt
    P=""
    for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
      for dev in /dev/disk*s0s3; do
        [ -e "$dev" ] || continue
        if mount -t hfs -o rdonly "$dev" /pemnt 2>/dev/null; then
          C=$(ls -d /pemnt/*.pkg 2>/dev/null | head -1)
          if [ -n "$C" ]; then P="$C"; break; fi
          umount /pemnt 2>/dev/null
        fi
      done
      [ -n "$P" ] && break
      sleep 4
    done
    echo "pkg=[$P]" >> $LOG
    if [ -z "$P" ]; then
      r "COMBONODISC"; out < $LOG
      done_
      sleep 2; /sbin/shutdown -h now
      exit 0
    fi
    r "COMBO Preparing the update"
    installer -verbose -pkg "$P" -target / 2>&1 | while read l; do
      echo "$l" >> $LOG
      case "$l" in
        *Completed*|*Preparing*|*Installing*|*Optimiz*|*Finishing*|*successful*) r "COMBO $l" ;;
      esac
    done
    umount /pemnt 2>/dev/null
    tail -40 $LOG | out
    if grep -q 'install was successful' $LOG; then
      echo installed > $STAGE
      r "COMBOOK"
    else
      done_
      r "COMBOFAIL"
    fi
    sync; sync; sleep 2
    /sbin/shutdown -h now
    """#

    /// Every startup: make About This Mac and System Profiler say what the
    /// reader chose. Idempotent, quick, and it re-applies after an Apple
    /// update puts the originals back. Only strings and one picture change;
    /// each original is kept as <file>.pe-orig.
    static let personalizeScript = #"""
    #!/bin/sh
    . /etc/rc.common
    D=/Library/StartupItems/PEPersonalize
    # Set KEY's value in a .strings file (UTF-16 or UTF-8), keeping the original.
    setstring(){
      [ -f "$1" ] || return 0
      perl -MEncode -e '
        my ($f, $k, $v) = @ARGV;
        local $/; open(F, "<", $f) or exit 0; my $raw = <F>; close F;
        my $u16 = ($raw =~ /^(\xFE\xFF|\xFF\xFE)/);
        my $t = $u16 ? decode("UTF-16", $raw) : decode("UTF-8", $raw);
        my $n = $t;
        $n =~ s/^("\Q$k\E"\s*=\s*")[^"]*(";)/$1$v$2/m;
        exit 0 if $n eq $t;
        open(O, ">", "$f.pe-orig"); print O $raw; close O;
        open(F, ">", $f) or exit 0; print F ($u16 ? encode("UTF-16", $n) : encode("UTF-8", $n)); close F;
      ' "$1" "$2" "$3"
    }
    # About This Mac's processor line.
    if [ -f $D/processor.txt ]; then
      P=$(cat $D/processor.txt)
      for f in /System/Library/CoreServices/loginwindow.app/Contents/Resources/*.lproj/AboutThisMac.strings; do
        setstring "$f" ABOUT_BOX_SINGLE_PROCESSOR_FIELD_FORMAT "$P"
      done
    fi
    # System Profiler's Machine Name, under whatever key this model maps to.
    if [ -f $D/model.txt ]; then
      N=$(cat $D/model.txt)
      R=/System/Library/SystemProfiler/SPPlatformReporter.spreporter/Contents/Resources
      K=$(perl -0777 -ne 'my $m=`sysctl -n hw.model`; $m =~ s/\s+$//; print $1 if m{<key>\Q$m\E</key>\s*<string>([^<]+)</string>}' $R/SPMachineTypes.plist)
      if [ -n "$K" ]; then
        for f in $R/*.lproj/Localizable.strings; do setstring "$f" "$K" "$N"; done
      fi
    fi
    # The picture in About This Mac.
    L=/System/Library/CoreServices/loginwindow.app/Contents/Resources
    if [ -f $D/AboutThisMac.tiff ] && [ -f $L/MacOSX.tif ] && ! cmp -s $D/AboutThisMac.tiff $L/MacOSX.tif; then
      cp -p $L/MacOSX.tif $L/MacOSX.tif.pe-orig
      cp $D/AboutThisMac.tiff $L/MacOSX.tif
    fi
    exit 0
    """#

    static let personalizeParameters = """
    {
      Description     = "PowerEmu About This Mac";
      Provides        = ("PEPersonalize");
      Requires        = ("Disks");
      OrderPreference = "Late";
    }

    """

    static let updateParameters = """
    {
      Description     = "PowerEmu 10.4.11 update";
      Provides        = ("PEUpdate");
      Requires        = ("Disks");
      OrderPreference = "Last";
    }

    """
}

enum InstallError: LocalizedError {
    case notInstallDisc
    case notAutomatable(String)
    case mount(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstallDisc: return "This doesn’t look like a Mac OS X install disc."
        case .notAutomatable(let v): return "This \(v) disc can’t be installed automatically."
        case .mount(let m): return "The disc image could not be opened. \(m)"
        case .failed(let m): return m
        }
    }
}

/// A disc image mounted on the host with hdiutil, out of the Finder's sight.
/// If the image is already mounted (the reader double-clicked it), that
/// mount is used and left alone.
final class Mount {
    private(set) var point: URL
    private var owned = true

    /// Mount, trying once more after a moment: an image that was just
    /// detached (by another copy of PowerEmu, say) can briefly refuse.
    ///
    /// Then, if it is still refused, once more as a plain disk.  A hybrid
    /// install DVD -- an Apple partition map with an HFS+ volume on it and
    /// an ISO 9660 filesystem beside it, which is what a retail Mac OS X
    /// DVD is -- is turned away as "not recognized" unless it is opened
    /// that way.  Leopard's disc is one of these.
    convenience init(image: URL, readWrite: Bool) throws {
        do { try self.init(once: image, readWrite: readWrite) } catch {
            Thread.sleep(forTimeInterval: 1.5)
            do { try self.init(once: image, readWrite: readWrite) } catch {
                try self.init(once: image, readWrite: readWrite, raw: true)
            }
        }
    }

    private init(once image: URL, readWrite: Bool, raw: Bool = false) throws {
        let requested = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("poweremu-disc-\(UUID().uuidString.prefix(8))")
        point = requested
        try FileManager.default.createDirectory(at: requested, withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        var args = ["attach", readWrite ? "-readwrite" : "-readonly", "-nobrowse", "-noverify", "-noautofsck",
                    "-plist", "-mountpoint", requested.path]
        if raw { args += ["-imagekey", "diskimage-class=CRawDiskImage"] }
        args.append(image.path)
        p.arguments = args
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        try p.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            try? FileManager.default.removeItem(at: requested)
            // Already attached ("Resource busy"): use the mount it has.
            if !readWrite, let mp = Self.existingMount(of: image) {
                point = URL(fileURLWithPath: mp)
                owned = false
                return
            }
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw InstallError.mount(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        let points = (plist?["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
        // hdiutil reports /private/var/... for our /var/... folder: the same
        // place, so compare resolved paths.
        let resolved = { (p: String) in URL(fileURLWithPath: p).resolvingSymlinksInPath().path }
        if let mp = points.first, resolved(mp) != resolved(requested.path) {
            // Already mounted elsewhere: use it, and don't unmount it later.
            try? FileManager.default.removeItem(at: requested)
            if readWrite { throw InstallError.mount("It is already open in the Finder; eject it and try again.") }
            point = URL(fileURLWithPath: mp)
            owned = false
        }
    }

    /// Where hdiutil already has this image mounted, if it does.
    static func existingMount(of image: URL) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        p.arguments = ["info", "-plist"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let want = image.resolvingSymlinksInPath().path
        let plist = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        for img in plist?["images"] as? [[String: Any]] ?? [] {
            guard let path = img["image-path"] as? String,
                  URL(fileURLWithPath: path).resolvingSymlinksInPath().path == want else { continue }
            let points = (img["system-entities"] as? [[String: Any]] ?? []).compactMap { $0["mount-point"] as? String }
            if let mp = points.first { return mp }
        }
        return nil
    }

    func detach() {
        guard owned else { return }
        for force in [false, true] {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
            p.arguments = ["detach", point.path] + (force ? ["-force"] : [])
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            try? p.run()
            p.waitUntilExit()
            if p.terminationStatus == 0 { break }
        }
        try? FileManager.default.removeItem(at: point)
    }
}
