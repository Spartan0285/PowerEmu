import Foundation
import DiskArbitration

/// A drive of this Mac that can be lent to the virtual Mac: an optical drive
/// with a disc in it, or a floppy-sized removable disk.
struct HostDrive: Identifiable, Hashable {
    let bsdName: String          // "disk4"
    let name: String             // "MATSHITA DVD-R  (Warcraft III)"
    let kind: Kind
    var id: String { bsdName }

    enum Kind { case optical, floppy, image }

    /// Open /dev/rdiskN read-only.  Raw devices belong to root; when this
    /// process may not read one, macOS's authopen asks for an administrator's
    /// approval and hands back the open file (over a socket, SCM_RIGHTS).
    static func open(_ d: HostDrive, done: @escaping @Sendable (Int32, String?) -> Void) {
        let path = "/dev/r" + d.bsdName
        DispatchQueue.global().async {
            let fd = Darwin.open(path, O_RDONLY)
            if fd >= 0 { done(fd, nil); return }
            guard errno == EACCES || errno == EPERM else {
                done(-1, "Could not open \(d.name): \(String(cString: strerror(errno)))")
                return
            }
            var sv: [Int32] = [0, 0]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &sv) == 0 else { done(-1, "Could not ask for access."); return }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/libexec/authopen")
            p.arguments = ["-stdoutpipe", "-o", String(O_RDONLY), path]
            p.standardOutput = FileHandle(fileDescriptor: sv[1], closeOnDealloc: false)
            do { try p.run() } catch { close(sv[0]); close(sv[1]); done(-1, error.localizedDescription); return }
            let got = QMP.receiveFD(socket: sv[0])
            p.waitUntilExit()
            close(sv[0]); close(sv[1])
            done(got, got >= 0 ? nil : "Access to \(d.name) was not granted.")
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

        let kind: HostDrive.Kind
        if ["IOCDMedia", "IODVDMedia", "IOBDMedia"].contains(mediaKind) {
            kind = .optical
        } else if removable && size > 0 && size <= 2_949_120 {
            kind = .floppy              // up to 2.88 MB: 400K/800K/1.44M disks
        } else if includeImages && model == "Disk Image" {
            kind = .image
        } else {
            return
        }
        var label = model.isEmpty ? name : model
        if let volume, !volume.isEmpty { label += " (\(volume))" }
        let d = HostDrive(bsdName: name, name: label, kind: kind)
        if !drives.contains(d) { drives.append(d) }
    }
}
