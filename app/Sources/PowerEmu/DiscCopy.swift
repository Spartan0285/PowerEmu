import Foundation

/*
 * Copying a disc in this Mac's drive into an image.
 *
 * A virtual Mac can read a real DVD straight from the drive while it runs,
 * and for using a disc that is all anyone needs.  Installing hands-off is
 * different: PowerEmu answers the installer's questions by patching a copy
 * of the disc, and a pressed DVD cannot be patched.  So a disc destined
 * for an unattended install is copied here first, once, and the install
 * then proceeds exactly as it would from a disc image.
 *
 * Reading a raw disc needs permission macOS does not hand out lightly;
 * that is the same path the CD/DVD drive already uses, where the reader is
 * asked for an administrator once (HostDrive.open).
 */
@MainActor
final class DiscCopy: ObservableObject {
    @Published private(set) var copied: Int64 = 0
    @Published private(set) var total: Int64 = 0
    @Published private(set) var running = false
    @Published private(set) var problem: String?
    @Published private(set) var file: URL?

    /// Read by the copying thread, set from the window: its own small
    /// lock, because asking the main actor from a background thread is not
    /// allowed and would bring the app down.
    private let stop = Flag()

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
        func set() { lock.lock(); value = true; lock.unlock() }
        func clear() { lock.lock(); value = false; lock.unlock() }
    }

    /// "2.1 of 3.5 GB"
    var progressText: String {
        let gb = { (n: Int64) in String(format: "%.1f GB", Double(n) / 1_073_741_824) }
        return total > 0 ? "\(gb(copied)) of \(gb(total))" : gb(copied)
    }

    var fraction: Double? { total > 0 ? min(1, Double(copied) / Double(total)) : nil }

    func cancel() { stop.set() }

    /// Copy `drive` into PowerEmu's installers folder.  The name comes from
    /// the disc itself, so a reader recognises it later.
    func start(_ drive: HostDrive) {
        problem = nil
        file = nil
        stop.clear()
        running = true
        copied = 0
        total = 0

        let name = drive.name + ".iso"
        let dest = MediaDownload.folder.appendingPathComponent(name.replacingOccurrences(of: "/", with: "-"))
        try? FileManager.default.createDirectory(at: MediaDownload.folder, withIntermediateDirectories: true)

        HostDrive.open(drive) { [weak self] fd, error in
            guard fd >= 0 else {
                Task { @MainActor in
                    self?.running = false
                    self?.problem = error ?? "The disc could not be read."
                }
                return
            }
            DispatchQueue.global(qos: .userInitiated).async {
                self?.copyDisc(fd: fd, to: dest)
            }
        }
    }

    private nonisolated func copyDisc(fd: Int32, to dest: URL) {
        defer { close(fd) }
        let fm = FileManager.default
        try? fm.removeItem(at: dest)
        guard fm.createFile(atPath: dest.path, contents: nil),
              let out = try? FileHandle(forWritingTo: dest) else {
            Task { @MainActor in
                self.running = false
                self.problem = "The copy could not be written."
            }
            return
        }
        defer { try? out.close() }

        // How big the disc is, so there is something to show progress against.
        var size: UInt64 = 0
        _ = withUnsafeMutablePointer(to: &size) { ioctl(fd, UInt(0x40086419), $0) }   // DKIOCGETBLOCKCOUNT
        var blockSize: UInt32 = 2048
        _ = withUnsafeMutablePointer(to: &blockSize) { ioctl(fd, UInt(0x40046418), $0) }  // DKIOCGETBLOCKSIZE
        let bytes = Int64(size) * Int64(blockSize)
        Task { @MainActor in self.total = bytes }

        let chunk = 2 << 20
        var buffer = [UInt8](repeating: 0, count: chunk)
        var done: Int64 = 0
        while true {
            let n = buffer.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, chunk) }
            if n <= 0 { break }
            do {
                try out.write(contentsOf: Data(buffer[0..<n]))
            } catch {
                Task { @MainActor in
                    self.running = false
                    self.problem = "Writing the copy failed: \(error.localizedDescription)"
                }
                return
            }
            done += Int64(n)
            Task { @MainActor in self.copied = done }
            if stop.isSet {
                try? out.close()
                try? fm.removeItem(at: dest)        // a half-copied disc is no use
                Task { @MainActor in self.running = false }
                return
            }
        }
        Task { @MainActor in
            self.running = false
            if done > 0 {
                self.file = dest
            } else {
                self.problem = "Nothing could be read from the disc."
            }
        }
    }
}
