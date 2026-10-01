import Foundation

/*
 * Mac OS 8 and 9 install discs, read without mounting them.
 *
 * This Mac cannot mount them at all: macOS dropped HFS standard, and every
 * classic install CD is HFS.  `hdiutil attach` answers "no mountable file
 * systems", so InstallPlan's inspect -- which mounts the image and reads
 * SystemVersion.plist -- has nothing to look at and throws notInstallDisc.
 *
 * So the disc is read directly instead.  Three structures, all at fixed
 * offsets near the front of the image:
 *
 *   block 0        Driver Descriptor Map: the signature and the device
 *                  block size the map was written for.
 *   block 1..n     Apple Partition Map, one 512-byte entry per partition.
 *                  The one with an HFS type holds the volume.
 *   +1024 into it  the volume header, an HFS Master Directory Block.
 *
 * The volume name comes out of the MDB, and on a retail disc it is the name
 * of the release -- "Mac OS 9.2.2" -- which is both what to show the reader
 * and where the version number comes from.  The blessed system folder's
 * directory ID (Finder info word 0, non-zero when a System Folder has been
 * blessed) says the disc can actually be started from, which is what makes
 * it an install disc rather than a disc that merely holds HFS files.
 *
 * Only HFS standard counts.  Every retail Mac OS 8/9 CD is HFS, and every
 * Mac OS X disc is HFS+ -- which this Mac does mount, and so stays
 * InstallPlan's job.  Reading HFS+ here would claim Tiger and Leopard discs
 * as classic ones, because they too have a blessed System folder.
 *
 * Partition starts are stored in units of a block size that is not always
 * the one in the Driver Descriptor Map: a CD written by Toast says 2048
 * there, but counts partition starts in 512-byte blocks.  Both readings are
 * tried and the one that lands on a volume signature wins.
 */
enum ClassicDisc {

    struct Info: Equatable {
        /// The HFS volume name, e.g. "Mac OS 9.2.2".
        let volumeName: String
        /// Just the release, e.g. "9.2.2", when the name carries one.
        let version: String?
        /// A System Folder on the volume has been blessed, so it can boot.
        let bootable: Bool

        /// What to call the machine: "Mac OS 9.2.2".
        var osName: String {
            if let version { return "Mac OS \(version)" }
            return volumeName
        }

        /// A short name to suggest for a new machine: "Mac OS 9".
        var suggestedName: String {
            guard let version, let major = version.split(separator: ".").first else { return volumeName }
            return "Mac OS \(major)"
        }
    }

    /// Read `disc` and say whether it is a startable Mac OS 8/9 disc.
    /// Returns nil for anything else, including Mac OS X discs (which mount,
    /// and so are InstallPlan's job) and images with no Apple partition map.
    static func inspect(_ disc: URL) -> Info? {
        guard let h = try? FileHandle(forReadingFrom: disc) else { return nil }
        defer { try? h.close() }

        guard let ddm = read(h, at: 0, 512), be16(ddm, 0) == 0x4552 else { return nil }   // 'ER'
        let deviceBlock = Int(be16(ddm, 2))
        let mapStride = (deviceBlock == 512 || deviceBlock == 2048) ? deviceBlock : 512

        for (start, blocks) in partitions(h, stride: mapStride) {
            _ = blocks
            // The start is counted either in device blocks or in 512-byte
            // ones; whichever lands on a volume signature is the right one.
            for unit in Set([mapStride, 512]) {
                let base = start * unit
                guard let vh = read(h, at: base + 1024, 512) else { continue }
                if let info = hfs(vh) { return info }
            }
        }
        return nil
    }

    // MARK: The partition map

    /// Every partition in the map that holds an HFS volume, as
    /// (start block, block count).
    private static func partitions(_ h: FileHandle, stride: Int) -> [(Int, Int)] {
        var out: [(Int, Int)] = []
        var i = 1
        var entries = 1
        while i <= entries && i <= 64 {
            guard let e = read(h, at: i * stride, 512), be16(e, 0) == 0x504D else { break }  // 'PM'
            entries = Int(be32(e, 4))
            let start = Int(be32(e, 8)), count = Int(be32(e, 12))
            let type = string(e, at: 48, max: 32)
            if type.contains("HFS") { out.append((start, count)) }
            i += 1
        }
        return out
    }

    // MARK: The volume headers

    /// An HFS Master Directory Block: signature 'BD', a Pascal volume name at
    /// 36, and the blessed system folder's directory ID at 92.
    private static func hfs(_ b: Data) -> Info? {
        guard be16(b, 0) == 0x4244 else { return nil }                      // 'BD'
        let name = pascalString(b, at: 36, max: 27)
        guard !name.isEmpty else { return nil }
        /*
         * An HFS volume can be a wrapper around an embedded HFS+ one, which
         * is how Mac OS 8.1 and later format a disk that OS 9 and OS X share.
         * The wrapper's own name is still the volume's name, and the blessed
         * folder in the wrapper still points at a bootable System Folder, so
         * there is nothing more to chase here.
         */
        return classify(name: name, blessed: be32(b, 92))
    }

    /// A blessed volume whose name names a classic release.
    private static func classify(name: String, blessed: UInt32) -> Info? {
        guard blessed != 0 else { return nil }
        return Info(volumeName: name, version: version(in: name), bootable: true)
    }

    /// "Mac OS 9.2.2" -> "9.2.2".  Only 8.x and 9.x count: a volume called
    /// "Mac OS X 10.4" is not this kind of disc, and 10 does not match.
    static func version(in name: String) -> String? {
        var digits = ""
        var seen = false
        for ch in name {
            if ch.isNumber || (ch == "." && !digits.isEmpty && digits.last != ".") {
                digits.append(ch); seen = true
            } else if seen {
                break
            }
        }
        while digits.hasSuffix(".") { digits.removeLast() }
        guard let major = digits.split(separator: ".").first, major == "8" || major == "9" else { return nil }
        return digits
    }

    // MARK: Reading

    private static func read(_ h: FileHandle, at offset: Int, _ count: Int) -> Data? {
        guard (try? h.seek(toOffset: UInt64(offset))) != nil,
              let d = try? h.read(upToCount: count), d.count == count else { return nil }
        return d
    }

    private static func be16(_ d: Data, _ i: Int) -> UInt16 {
        guard i + 2 <= d.count else { return 0 }
        return UInt16(d[d.startIndex + i]) << 8 | UInt16(d[d.startIndex + i + 1])
    }

    private static func be32(_ d: Data, _ i: Int) -> UInt32 {
        guard i + 4 <= d.count else { return 0 }
        return (0..<4).reduce(UInt32(0)) { $0 << 8 | UInt32(d[d.startIndex + i + $1]) }
    }

    /// A Pascal string: a length byte, then that many Mac Roman characters.
    private static func pascalString(_ d: Data, at i: Int, max: Int) -> String {
        guard i < d.count else { return "" }
        let n = min(Int(d[d.startIndex + i]), max)
        guard n > 0, i + 1 + n <= d.count else { return "" }
        return String(data: d.subdata(in: (d.startIndex + i + 1)..<(d.startIndex + i + 1 + n)),
                      encoding: .macOSRoman)?.trimmingCharacters(in: .whitespaces) ?? ""
    }

    /// A C string in a fixed-width field.
    private static func string(_ d: Data, at i: Int, max: Int) -> String {
        guard i < d.count else { return "" }
        let end = min(i + max, d.count)
        let bytes = d.subdata(in: (d.startIndex + i)..<(d.startIndex + end)).prefix { $0 != 0 }
        return String(data: bytes, encoding: .macOSRoman) ?? ""
    }
}
