import Foundation
import DiskArbitration

/// A drive of this Mac that can be lent to the virtual Mac: an optical drive
/// with a disc in it, or a floppy-sized removable disk.
struct HostDrive: Identifiable, Hashable {
    let bsdName: String          // "disk4"
    let name: String             // "MATSHITA DVD-R  (Warcraft III)"
    let kind: Kind
    /// Bytes of the whole medium, as DiskArbitration reports it; 0 when unknown.
    var sizeBytes: Int64 = 0
    /// The medium's UUID where it has one -- a name that survives replugging,
    /// unlike bsdName.
    var mediaUUID: String? = nil
    var id: String { bsdName }

    enum Kind { case optical, floppy, image, hardDisk }

    /// Open /dev/diskN read-only -- the *buffered* block node, deliberately
    /// not the raw /dev/rdiskN character node.  A DVD's physical block is
    /// 2048 bytes, and reads from the raw node must land on a buffer aligned
    /// to it; QEMU's raw driver probes the alignment as 512 and hands macOS a
    /// 512-aligned bounce buffer, so every read past the first few sectors
    /// comes back EINVAL and the guest sees an unreadable disc.  The buffered
    /// node goes through the kernel's buffer cache, which does the alignment,
    /// and an optical read is not fast enough for the extra copy to matter.
    /// These nodes belong to root; when this process may not read one,
    /// macOS's authopen asks for an administrator's approval and hands back
    /// the open file (over a socket, SCM_RIGHTS).
    /// The device node to read this disc through.  A DVD's whole-disc node is
    /// already 2048-byte cooked sectors, but a data CD's whole-disc node is
    /// 2352-byte raw sectors (sync + header + ECC); the guest expects 2048, so
    /// reading the raw node gives it garbage and it sees an unreadable disc.
    /// The cooked 2048-byte view lives in the disc's data partition, so when
    /// the whole-disc node is not 2048 we open the first 2048-byte partition.
    static func opticalNode(_ bsdName: String) -> String {
        func blockSize(_ path: String) -> UInt32? {
            let fd = Darwin.open(path, O_RDONLY)
            guard fd >= 0 else { return nil }
            defer { close(fd) }
            var bs: UInt32 = 0
            let DKIOCGETBLOCKSIZE: UInt = 0x4004_6418   // _IOR('d', 24, uint32)
            return ioctl(fd, DKIOCGETBLOCKSIZE, &bs) == 0 ? bs : nil
        }
        let whole = "/dev/" + bsdName
        if blockSize(whole) == 2048 { return whole }
        for i in 1...9 {
            let part = whole + "s\(i)"
            if blockSize(part) == 2048 { return part }
        }
        return whole
    }

    static func open(_ d: HostDrive, writable: Bool = false,
                     done: @escaping @Sendable (Int32, String?) -> Void) {
        // A hard disk is lent whole (the guest reads its partition table); an
        // optical disc is read through its 2048-byte cooked node.
        let path = d.kind == .hardDisk ? "/dev/" + d.bsdName : HostDrive.opticalNode(d.bsdName)
        let flags: Int32 = writable ? O_RDWR : O_RDONLY
        DispatchQueue.global().async {
            let fd = Darwin.open(path, flags)
            if fd >= 0 { done(fd, nil); return }
            guard errno == EACCES || errno == EPERM else {
                done(-1, "Could not open \(d.name): \(String(cString: strerror(errno)))")
                return
            }
            var sv: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { done(-1, "Could not ask for access."); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            p.arguments = ["-stdoutpipe", "-o", String(flags), path]
            p.standardOutput = FileHandle(fileDescriptor: sv[1], closeOnDealloc: false)
            do { try p.run() } catch { close(sv[0]); close(sv[1]); done(-1, error.localizedDescription); return }
            let got = QMP.receiveFD(socket: sv[0])
            p.waitUntilExit()
            close(sv[0]); close(sv[1])
            if got >= 0 { done(got, nil); return }
            /*
             * authopen came back with nothing, and there are two quite
             * different reasons for that: the reader said no, or the disc
             * could not be read however much authority was brought to bear.
             * Saying "access was not granted" for both sends somebody
             * hunting through Privacy settings for a disc that is simply
             * blank, which is what happened.
             */
            let second = Darwin.open(path, flags)
            if second >= 0 { done(second, nil); return }
            if errno == EACCES || errno == EPERM {
                done(-1, "Access to \(d.name) was not granted.")
            } else {
                done(-1, "\(d.name) could not be read: "
                       + String(cString: strerror(errno)) + ".")
            }
        }
    }
}

/// Watches DiskArbitration for drives worth offering.
@MainActor
final class HostDriveMonitor: ObservableObject {
    static let shared = HostDriveMonitor()
    @Published private(set) var drives: [HostDrive] = []
    private let session: DASession?

    /// Disk images attached in the Finder show up too when this is set - for
    /// testing without a physical drive.
    private let includeImages = ProcessInfo.processInfo.environment["POWEREMU_HOST_IMAGES"] != nil

    private init() {
        session = DASessionCreate(kCFAllocatorDefault)
        guard let session else { return }
        DASessionScheduleWithRunLoop(session, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        DARegisterDiskAppearedCallback(session, nil, { disk, ctx in
            guard let ctx else { return }
            let me = Unmanaged<HostDriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.appeared(disk) }
        }, ctx)
        DARegisterDiskDisappearedCallback(session, nil, { disk, ctx in
            guard let ctx, let bsd = DADiskGetBSDName(disk) else { return }
            let name = String(cString: bsd)
            let me = Unmanaged<HostDriveMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { me.drives.removeAll { $0.bsdName == name } }
        }, ctx)
    }

    private func appeared(_ disk: DADisk) {
        guard let bsd = DADiskGetBSDName(disk),
              let desc = DADiskCopyDescription(disk) as? [String: Any] else { return }
        let name = String(cString: bsd)
        guard desc[kDADiskDescriptionMediaWholeKey as String] as? Bool == true else { return }
        let mediaKind = desc[kDADiskDescriptionMediaKindKey as String] as? String ?? ""
        let removable = desc[kDADiskDescriptionMediaRemovableKey as String] as? Bool ?? false
        let size = (desc[kDADiskDescriptionMediaSizeKey as String] as? NSNumber)?.int64Value ?? 0
        let model = (desc[kDADiskDescriptionDeviceModelKey as String] as? String ?? "")
            .trimmingCharacters(in: .whitespaces)
        let volume = desc[kDADiskDescriptionVolumeNameKey as String] as? String
            ?? desc[kDADiskDescriptionMediaNameKey as String] as? String

        /*
         * A blank disc has nothing to lend.  DiskArbitration says so by
         * leaving the content empty -- the same disc that `diskutil info`
         * reports as "Content (IOContent): None" and "File System: None".
         * Offering one anyway ends with the raw device refusing to open at
         * all (ENXIO, "Device not configured"), which PowerEmu used to
         * report as a refused authorization: the reader is sent to look for
         * a permission problem that was never there.
         */
        let content = desc[kDADiskDescriptionMediaContentKey as String] as? String ?? ""
        let blank = content.isEmpty

        // Never offer this Mac's own internal disks -- only external drives
        // (USB/FireWire/Thunderbolt) may be lent, so the host system disk can
        // never be handed to a guest.
        let internalDisk = desc[kDADiskDescriptionDeviceInternalKey as String] as? Bool ?? true

        let kind: HostDrive.Kind
        if ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(mediaKind) {
            if blank { return }
            kind = .optical
        } else if removable && size > 0 && size <= 2_949_120 {
            kind = .floppy              // up to 2.88 MB: 400K/800K/1.44M disks
        } else if includeImages && model == "Disk Image" {
            kind = .image
        } else if !internalDisk && !blank && size > 2_949_120 {
            // An external hard disk (or SSD/USB stick): lend it whole so the
            // guest sees its partition table -- to browse it, install onto it,
            // or boot from it.
            kind = .hardDisk
        } else {
            return
        }
        var label = model.isEmpty ? name : model
        if let volume, !volume.isEmpty { label += " (\(volume))" }
        var uuid: String? = nil
        if let raw = desc[kDADiskDescriptionMediaUUIDKey as String] {
            let cf = raw as CFTypeRef
            if CFGetTypeID(cf) == CFUUIDGetTypeID(),
               let str = CFUUIDCreateString(kCFAllocatorDefault, (cf as! CFUUID)) {
                uuid = str as String
            }
        }
        let d = HostDrive(bsdName: name, name: label, kind: kind, sizeBytes: size,
                          mediaUUID: uuid)
        if !drives.contains(d) { drives.append(d) }
    }
}
