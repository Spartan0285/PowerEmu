import Foundation

/*
 * Giving a virtual Mac's hard disk more room.
 *
 * The size Mac OS X sees is fixed when the disk is made (the file itself
 * only takes space on this Mac as it fills).  Growing it means three
 * things: a bigger disk, an Apple partition map that describes the bigger
 * disk, and a volume that fills it.  Mac OS X 10.4's own Disk Utility
 * can't grow a volume, so this Mac does all of it while the virtual Mac
 * is shut down: the work happens on a copy, and the copy only takes the
 * disk's place once its file system has been checked.
 *
 * Only growing.  Shrinking would have to move files out of the way.
 */
enum DiskGrow {
    /// How much of this Mac the work needs on top of what the disk uses.
    /// The copy is written twice over: once as a plain image, once back.
    static func spaceNeeded(for disk: URL) -> Int64 {
        let used = (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? Int64).flatMap { $0 } ?? 0
        return used * 2 + (1 << 30)
    }

    static func freeSpace(at url: URL) -> Int64 {
        (try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage) ?? 0
    }

    /// The disk's size as Mac OS X sees it, read from the file itself.
    /// Never asks qemu-img: a running virtual Mac holds its disks, and a
    /// tool that waits on one would freeze whatever asked (it once froze
    /// the window while drawing it, which aborted the app).
    static func virtualSize(of disk: URL) throws -> Int64 {
        let h = try FileHandle(forReadingFrom: disk)
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 32)) ?? Data()
        if head.count >= 32, head.prefix(4) == Data([0x51, 0x46, 0x49, 0xFB]) {   // "QFI\u{fb}": qcow2
            return head.withUnsafeBytes { Int64(bigEndian: $0.loadUnaligned(fromByteOffset: 24, as: Int64.self)) }
        }
        // A plain disk image is as big as it looks.
        let size = (try? FileManager.default.attributesOfItem(atPath: disk.path)[.size] as? Int64).flatMap { $0 }
        guard let size else { throw InstallError.failed("The disk’s size could not be read.") }
        return size
    }

    /// Grow `disk` to `bytes` and put the old one in the Trash.  `step`
    /// is called on a background thread with what is happening.
    static func grow(_ disk: URL, to bytes: Int64, qemuImg: URL, step: (String) -> Void) throws {
        let fm = FileManager.default
        let old = try virtualSize(of: disk)
        guard bytes > old else { throw InstallError.failed("That size is not larger than the disk already is.") }
        guard freeSpace(at: disk.deletingLastPathComponent()) > spaceNeeded(for: disk) else {
            throw InstallError.failed("There isn’t enough room on this Mac to grow the disk safely.")
        }

        let work = disk.deletingPathExtension().appendingPathExtension("grow.qcow2")
        let raw  = disk.deletingPathExtension().appendingPathExtension("grow.img")
        let made = disk.deletingPathExtension().appendingPathExtension("grown.qcow2")
        for u in [work, raw, made] { try? fm.removeItem(at: u) }
        var keep = false
        defer { if !keep { for u in [work, raw, made] { try? fm.removeItem(at: u) } } }

        step("Copying the disk…")
        try fm.copyItem(at: disk, to: work)             // APFS: shares the blocks
        _ = try InstallPlan.run(qemuImg.path, ["resize", work.path, String(bytes)])

        step("Preparing the new space…")
        _ = try InstallPlan.run(qemuImg.path, ["convert", "-O", "raw", work.path, raw.path])
        try? fm.removeItem(at: work)
        try openUpMap(raw, to: bytes)

        step("Growing the volume…")
        let dev = try attach(raw)
        defer { _ = try? InstallPlan.run("/usr/bin/hdiutil", ["detach", "-force", dev]) }
        let part = try volumeSlice(dev)
        // diskutil wants the volume's own size: the disk, less what comes
        // before it (the partition map).
        _ = try InstallPlan.run("/usr/sbin/diskutil", ["resizeVolume", part.dev, "\(bytes - part.offset)B"])

        step("Checking the volume…")
        _ = try InstallPlan.run("/usr/sbin/diskutil", ["verifyVolume", part.dev])
        _ = try? InstallPlan.run("/usr/bin/hdiutil", ["detach", dev])

        step("Putting the disk back…")
        _ = try InstallPlan.run(qemuImg.path, ["convert", "-O", "qcow2", raw.path, made.path])
        try? fm.removeItem(at: raw)
        try fm.trashItem(at: disk, resultingItemURL: nil)
        do {
            try fm.moveItem(at: made, to: disk)
        } catch {
            keep = true                                  // never delete the grown disk
            throw InstallError.failed("The disk was grown but could not be put back. It is beside the old one, named “\(made.lastPathComponent)”.")
        }
    }

    // MARK: the partition map

    /// Make the Apple partition map describe the bigger disk: the block
    /// count in its first block, and free space to the new end.  Without
    /// this, diskutil refuses to touch the volume ("your partition map does
    /// not use the entire space of your whole-disk"), and it can't repair an
    /// Apple map itself.
    private static func openUpMap(_ raw: URL, to bytes: Int64) throws {
        let blockSize: Int64 = 512
        let total = bytes / blockSize
        let h = try FileHandle(forUpdating: raw)
        defer { try? h.close() }
        guard let block0 = try h.read(upToCount: 512), block0.count == 512,
              block0[0] == 0x45, block0[1] == 0x52 else {          // "ER"
            throw InstallError.failed("This disk doesn’t have an Apple partition map, so PowerEmu can’t grow it.")
        }
        var b0 = block0
        write32(&b0, at: 4, UInt32(total))                          // sbBlkCount
        try h.seek(toOffset: 0)
        try h.write(contentsOf: b0)

        // Entries follow, one per block. The last one is stretched to the
        // new end of the disk if it is free space; otherwise one is added.
        var entries: [(index: Int, start: UInt32, count: UInt32, type: String)] = []
        var i = 1
        while true {
            try h.seek(toOffset: UInt64(i) * 512)
            guard let d = try h.read(upToCount: 512), d.count == 512, d[0] == 0x50, d[1] == 0x4D else { break }   // "PM"
            entries.append((i, read32(d, 8), read32(d, 12), string(d, 48)))
            i += 1
        }
        guard let last = entries.last, let first = entries.first else {
            throw InstallError.failed("This disk’s partition map could not be read.")
        }
        let mapBlocks = read32(try blockAt(h, first.index), 4)      // how many entries the map has room for
        let end = Int64(last.start) + Int64(last.count)
        guard end < total else { return }                           // already spans the disk

        if last.type == "Apple_Free" {
            var d = try blockAt(h, last.index)
            write32(&d, at: 12, UInt32(total - Int64(last.start)))
            try h.seek(toOffset: UInt64(last.index) * 512)
            try h.write(contentsOf: d)
        } else {
            guard entries.count < Int(mapBlocks) else {
                throw InstallError.failed("This disk’s partition map is full, so PowerEmu can’t grow it.")
            }
            var d = try blockAt(h, last.index)                      // a copy of a real entry, then made free
            write32(&d, at: 8, UInt32(end))
            write32(&d, at: 12, UInt32(total - end))
            replace(&d, at: 16, 32, "Extra")
            replace(&d, at: 48, 32, "Apple_Free")
            write32(&d, at: 80, 0)
            write32(&d, at: 84, 0)
            write32(&d, at: 88, 0)                                  // not readable, not writable, not valid
            try h.seek(toOffset: UInt64(last.index + 1) * 512)
            try h.write(contentsOf: d)
        }
    }

    private static func blockAt(_ h: FileHandle, _ index: Int) throws -> Data {
        try h.seek(toOffset: UInt64(index) * 512)
        guard let d = try h.read(upToCount: 512), d.count == 512 else {
            throw InstallError.failed("This disk’s partition map could not be read.")
        }
        return d
    }

    private static func read32(_ d: Data, _ at: Int) -> UInt32 {
        d.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(fromByteOffset: at, as: UInt32.self)) }
    }

    private static func write32(_ d: inout Data, at: Int, _ v: UInt32) {
        var be = v.bigEndian
        withUnsafeBytes(of: &be) { src in
            for k in 0..<4 { d[d.startIndex + at + k] = src[k] }
        }
    }

    private static func string(_ d: Data, _ at: Int) -> String {
        let bytes = d[(d.startIndex + at)...].prefix(32).prefix { $0 != 0 }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func replace(_ d: inout Data, at: Int, _ length: Int, _ s: String) {
        let bytes = Array(s.utf8.prefix(length - 1))
        for k in 0..<length { d[d.startIndex + at + k] = k < bytes.count ? bytes[k] : 0 }
    }

    // MARK: this Mac's disks

    private static func attach(_ raw: URL) throws -> String {
        let out = try InstallPlan.run("/usr/bin/hdiutil", ["attach", "-nomount", "-noverify", "-plist",
                                                            "-imagekey", "diskimage-class=CRawDiskImage", raw.path])
        let plist = (try? PropertyListSerialization.propertyList(from: out, format: nil)) as? [String: Any]
        guard let dev = (plist?["system-entities"] as? [[String: Any]])?
                .compactMap({ $0["dev-entry"] as? String })
                .filter({ $0.hasPrefix("/dev/disk") })
                .min(by: { $0.count < $1.count }) else {
            throw InstallError.failed("The disk could not be opened on this Mac.")
        }
        return dev
    }

    /// The Mac OS Extended volume on the attached disk, and where it starts.
    private static func volumeSlice(_ dev: String) throws -> (dev: String, offset: Int64) {
        let out = try InstallPlan.run("/usr/sbin/diskutil", ["list", "-plist", dev])
        let plist = (try? PropertyListSerialization.propertyList(from: out, format: nil)) as? [String: Any]
        let disks = (plist?["AllDisksAndPartitions"] as? [[String: Any]]) ?? []
        for d in disks {
            for p in (d["Partitions"] as? [[String: Any]]) ?? [] {
                guard let content = p["Content"] as? String, content == "Apple_HFS",
                      let id = p["DeviceIdentifier"] as? String else { continue }
                let info = try InstallPlan.run("/usr/sbin/diskutil", ["info", "-plist", id])
                let ip = (try? PropertyListSerialization.propertyList(from: info, format: nil)) as? [String: Any]
                let offset = (ip?["PartitionMapPartitionOffset"] as? NSNumber)?.int64Value
                    ?? (ip?["Offset"] as? NSNumber)?.int64Value ?? 0
                return ("/dev/" + id, offset)
            }
        }
        throw InstallError.failed("PowerEmu could only grow a disk with one Mac OS Extended volume on it.")
    }
}
