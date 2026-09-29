import Foundation

struct FileTransferError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
    init(_ message: String) { self.message = message }
}

/// Transfer only owned staging directories. ZIP keeps Tiger resource forks and
/// Finder metadata, which would otherwise be lost on a WebDAV file copy.
enum FileTransferArchive {
    static func validName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") &&
        !name.contains("\\") && !name.contains("\0") && name != "__MACOSX"
    }

    static func run(_ arguments: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = arguments
        p.qualityOfService = .utility
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FileTransferError("The file could not be copied. Check available disk space and file permissions.") }
    }

    static func pack(_ source: URL, to archive: URL) throws {
        guard source.isFileURL, validName(source.lastPathComponent) else { throw FileTransferError("This filename is not supported for transfer.") }
        // Explicitly reject links rather than accidentally following a link
        // outside the selected folder, on either end of the connection.
        try checkTree(source)
        var arguments = ["-c", "-k", "--sequesterRsrc"]
        if try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true { arguments.append("--keepParent") }
        try run(arguments + [source.path, archive.path])
    }

    static func checkTree(_ source: URL) throws {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey]
        func check(_ u: URL) throws {
            let v = try u.resourceValues(forKeys: keys)
            guard v.isSymbolicLink != true, v.isRegularFile == true || v.isDirectory == true else {
                throw FileTransferError("Folders containing symbolic links or special files cannot be dragged yet. Copy an archive of the folder instead.")
            }
        }
        try check(source)
        if let e = fm.enumerator(at: source, includingPropertiesForKeys: Array(keys)) {
            for case let u as URL in e { try check(u) }
        }
    }

    /// Validate both central and local headers before giving an untrusted
    /// guest archive to ditto. In particular, never extract symlink entries or
    /// absolute/parent paths. ZIP64 is deliberately not part of this protocol.
    static func validate(_ archive: URL, name: String) throws {
        let d = try Data(contentsOf: archive, options: .mappedIfSafe)
        func bad() -> FileTransferError { FileTransferError("The transfer archive is invalid or unsupported (maximum 4 GB per item).") }
        func u16(_ i: Int) -> Int { Int(d[i]) | Int(d[i+1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i+2) << 16 }
        guard validName(name), d.count >= 22 else { throw bad() }
        var end: Int?
        for i in stride(from: d.count - 22, through: max(0, d.count - 65557), by: -1) {
            if u32(i) == 0x06054b50 && i + 22 + u16(i+20) == d.count { end = i; break }
        }
        guard let e = end, u16(e+4) == 0, u16(e+6) == 0, u16(e+8) == u16(e+10),
              u16(e+10) > 0, u16(e+10) < 65535 else { throw bad() }
        let start = u32(e+16), size = u32(e+12)
        guard start < e, size == e - start else { throw bad() }
        var p = start, total = 0, names = Set<String>()
        for _ in 0..<u16(e+10) {
            guard p + 46 <= e, u32(p) == 0x02014b50 else { throw bad() }
            let n = u16(p+28), extra = u16(p+30), comment = u16(p+32)
            let compressed = u32(p+20), raw = u32(p+24), local = u32(p+42)
            guard p + 46 + n + extra + comment <= e, u16(p+8) & 1 == 0,
                  [0,8].contains(u16(p+10)), u16(p+34) == 0,
                  raw != 0xffffffff, compressed != 0xffffffff,
                  let path = String(data: d.subdata(in: p+46..<p+46+n), encoding: .utf8) else { throw bad() }
            let parts = path.split(separator: "/", omittingEmptySubsequences: false)
            guard !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
                  !parts.contains(".."), !parts.contains("."),
                  parts.first == Substring(name) || parts.first == "__MACOSX",
                  names.insert(path).inserted else { throw bad() }
            let mode = (u32(p+38) >> 16) & 0xf000
            guard mode == 0 || mode == 0x8000 || mode == 0x4000 else { throw bad() }
            guard local + 30 <= start, u32(local) == 0x04034b50,
                  u16(local+6) == u16(p+8), u16(local+8) == u16(p+10), u16(local+26) == n else { throw bad() }
            let dataStart = local + 30 + n + u16(local+28)
            guard dataStart <= start, compressed <= start-dataStart,
                  d.subdata(in: local+30..<local+30+n) == d.subdata(in: p+46..<p+46+n) else { throw bad() }
            total += raw
            guard total <= 4_000_000_000 else { throw bad() }
            p += 46 + n + extra + comment
        }
        guard p == e, names.contains(name) || names.contains(name + "/") else { throw bad() }
    }

    static func unpack(_ archive: URL, name: String, to destination: URL) throws {
        try validate(archive, name: name)
        let fm = FileManager.default
        let staging = fm.temporaryDirectory.appendingPathComponent("PowerEmu-" + UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: staging) }
        try run(["-x", "-k", archive.path, staging.path])
        let item = staging.appendingPathComponent(name)
        try checkTree(item)
        // NSFilePromiseReceiver chooses the final filename; never replace it.
        try fm.moveItem(at: item, to: destination)
    }
}
