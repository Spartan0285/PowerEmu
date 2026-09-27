import Foundation
import DiscRecording

/*
 * Option B: the guest burns a disc and the bytes flow through to a physical
 * disc in one of this Mac's optical drives, in real time.
 *
 * The emulated recordable drive writes the guest's burn to a disc-image file
 * (config.insertedDisc, raw) and reports the burn lifecycle over a Unix socket
 * (POWEREMU_BURN_STREAM, handled in poweremu-qemu's hw/ide/atapi.c):
 *
 *   TRACK <blocks>          a burn of that many 2048-byte blocks begins
 *   WROTE  <lba> <blocks>   the guest has written that range to the image
 *   CLOSE                   the session is closed
 *
 * On TRACK we start a DRBurn on the host drive with a data producer that
 * reads the image file as the guest fills it -- the guest runs ahead of the
 * physical burn, so the data the producer needs is always already there.
 * DiscRecording finalises the disc after the track's blocks are consumed.
 *
 * The DiscRecording burn engine here is the one proven against real hardware
 * (a bit-for-bit CD-R of a Toast image); see scratchpad/physburn.swift lineage.
 */
@MainActor
final class PhysicalBurn: ObservableObject {
    enum State: Equatable { case idle, waiting, burning(Double), done, failed(String) }
    @Published private(set) var state: State = .idle

    let socketPath: String
    /// Returns the current recordable disc-image path (the guest's blank disc),
    /// or nil.  Resolved when a burn actually begins, so the listener can be
    /// armed at boot regardless of what is in the drive.
    private let backing: () -> String?
    private var device: DRDevice?
    private var listenFD: Int32 = -1
    private var producer: StreamProducer?
    private let connFD = Atomic<Int32>(-1)
    private var burn: DRBurn?
    private var observer: NSObjectProtocol?

    /// A physical optical drive with blank, writable media, or nil.
    static func availableBurner() -> DRDevice? {
        guard let devices = DRDevice.devices() as? [DRDevice] else { return nil }
        for d in devices {
            guard let mi = d.status()?[DRDeviceMediaInfoKey as String] as? [String: Any] else { continue }
            let blank = (mi[DRDeviceMediaIsBlankKey as String] as? Bool) ?? false
            let overwritable = (mi[DRDeviceMediaIsOverwritableKey as String] as? Bool) ?? false
            if blank || overwritable { return d }
        }
        return nil
    }

    /// Free blocks on the blank disc in a real drive, or nil -- used to size
    /// the guest's emulated blank disc to match the physical media.
    static func blankMediaBlocks() -> UInt64? {
        guard let d = availableBurner(),
              let mi = d.status()?[DRDeviceMediaInfoKey as String] as? [String: Any],
              let free = mi[DRDeviceMediaBlocksFreeKey as String] as? NSNumber else { return nil }
        return free.uint64Value
    }

    static func burnerName(_ d: DRDevice) -> String {
        (d.info()?[DRDeviceProductNameKey as String] as? String) ?? "optical drive"
    }

    init(backing: @escaping () -> String?) {
        self.backing = backing
        // A short, unique socket path (AF_UNIX caps sun_path near 104 bytes).
        self.socketPath = NSTemporaryDirectory() + "peburn-\(getpid()).sock"
    }

    /// Begin listening for the guest's burn.  Returns false if the socket
    /// could not be created.
    func startListening() -> Bool {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = socketPath.withCString { src in
            withUnsafeMutablePointer(to: &addr.sun_path) { dst in
                dst.withMemoryRebound(to: CChar.self, capacity: 104) { strcpy($0, src) }
            }
        }
        let len = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) }
        }
        guard bound == 0, listen(fd, 1) == 0 else { close(fd); return false }
        listenFD = fd
        state = .waiting
        // Accept + read on a background thread; hop to main for state changes.
        Thread.detachNewThread { [weak self] in self?.acceptLoop() }
        return true
    }

    /// The guest wrote this many 2048-byte blocks so far (shared with the
    /// producer thread).
    private let written = Atomic<UInt64>(0)
    private let closed = Atomic<Bool>(false)

    private func acceptLoop() {
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { return }
        connFD.store(conn)
        var buf = Data()
        var tmp = [UInt8](repeating: 0, count: 4096)
        while true {
            let n = read(conn, &tmp, tmp.count)
            if n <= 0 { break }
            buf.append(contentsOf: tmp[0..<n])
            while let nl = buf.firstIndex(of: 0x0a) {
                let line = String(data: buf[buf.startIndex..<nl], encoding: .utf8) ?? ""
                buf.removeSubrange(buf.startIndex...nl)
                handle(line: line.trimmingCharacters(in: .whitespaces))
            }
        }
        close(conn)
    }

    private func handle(line: String) {
        let f = line.split(separator: " ")
        guard let verb = f.first else { return }
        switch verb {
        case "TRACK":
            if f.count >= 2, let blocks = UInt64(f[1]) {
                DispatchQueue.main.async { self.beginBurn(totalBlocks: blocks) }
            }
        case "WROTE":
            if f.count >= 2, let hw = UInt64(f[1]) {
                written.store(max(written.load(), hw))
            }
        case "CLOSE":
            closed.store(true)
        case "EJECT":
            // The guest ejected its disc -- eject the real one too, so the
            // guest's drive and the physical drive stay in lockstep.
            DispatchQueue.global().async {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/drutil")
                p.arguments = ["eject"]
                try? p.run(); p.waitUntilExit()
            }
        default:
            break
        }
    }

    private func beginBurn(totalBlocks: UInt64) {
        guard case .waiting = state else { return }   // one burn at a time
        // Resolve the guest's blank-disc image and a real drive with blank
        // media right now.  Missing either just means no physical mirror --
        // the guest still burns its own emulated disc.
        guard let imgPath = backing(), let dev = PhysicalBurn.availableBurner() else {
            state = .idle; return
        }
        device = dev
        let imageURL = URL(fileURLWithPath: imgPath)
        dev.acquireExclusiveAccess()
        dev.acquireMediaReservation()
        let isDVD = ((dev.status()?[DRDeviceMediaInfoKey as String] as? [String: Any])?[DRDeviceMediaTypeKey as String] as? String ?? "").contains("DVD")
        guard let prod = StreamProducer(image: imageURL, totalBlocks: totalBlocks,
                                        written: written, closed: closed, connFD: connFD),
              let track = DRTrack(producer: prod) else {
            fail("Could not open the disc image for burning."); return
        }
        producer = prod
        track.setProperties([
            DRTrackLengthKey as String: NSNumber(value: totalBlocks),
            DRBlockSizeKey as String: NSNumber(value: 2048),
            DRBlockTypeKey as String: NSNumber(value: 8),
            DRDataFormKey as String: NSNumber(value: 16),
            DRTrackModeKey as String: NSNumber(value: isDVD ? 5 : 4),
            DRSessionFormatKey as String: NSNumber(value: 0),
        ])
        guard let dev = device, let b = DRBurn(for: dev) else { fail("Could not start the burner."); return }
        b.setProperties([
            DRBurnCompletionActionKey as String: DRBurnCompletionActionMount,
            DRBurnVerifyDiscKey as String: false,
            DRBurnAppendableKey as String: false,
        ])
        burn = b
        observer = NotificationCenter.default.addObserver(
            forName: .DRBurnStatusChanged, object: b, queue: .main) { [weak self] _ in
            self?.pollStatus()
        }
        state = .burning(0)
        b.writeLayout([track])
    }

    private func pollStatus() {
        guard let b = burn else { return }
        let st = b.status() ?? [:]
        let s = (st[DRStatusStateKey as String] as? String) ?? ""
        let pct = (st[DRStatusPercentCompleteKey as String] as? Double) ?? 0
        if s == (DRStatusStateDone as String) { state = .done; releaseDevice(); state = .waiting }
        else if s == (DRStatusStateFailed as String) {
            let e = st[DRErrorStatusKey as String] as? [String: Any]
            fail((e?[DRErrorStatusErrorStringKey as String] as? String) ?? "The burn failed.")
        } else if pct >= 0 {
            state = .burning(pct)
        }
    }

    private func fail(_ msg: String) { state = .failed(msg); cleanup() }

    private func releaseDevice() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        device?.releaseMediaReservation(); device?.releaseExclusiveAccess(); device = nil
        burn = nil; producer = nil
    }

    private func cleanup() {
        if let o = observer { NotificationCenter.default.removeObserver(o); observer = nil }
        device?.releaseMediaReservation(); device?.releaseExclusiveAccess(); device = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    /// Cancel a burn cleanly (never leave the drive hung mid-session).
    func abort() {
        burn?.abort()
        cleanup()
        state = .idle
    }
}

/// Serves the disc image to DiscRecording as the guest fills it.  DiscRecording
/// passes `address` as a byte offset here (verified on real hardware), so we
/// read the image at that offset directly.  The guest runs ahead of the
/// physical burn; if it has not yet written far enough we spin briefly.
final class StreamProducer: NSObject {
    private let fd: Int32
    private let totalBlocks: UInt64
    private let written: Atomic<UInt64>
    private let closed: Atomic<Bool>
    private let connFD: Atomic<Int32>

    init?(image: URL, totalBlocks: UInt64, written: Atomic<UInt64>, closed: Atomic<Bool>, connFD: Atomic<Int32>) {
        let f = open(image.path, O_RDONLY)
        guard f >= 0 else { return nil }
        self.fd = f; self.totalBlocks = totalBlocks
        self.written = written; self.closed = closed; self.connFD = connFD
        super.init()
    }

    deinit { if fd >= 0 { close(fd) } }

    @objc(estimateLengthOfTrack:)
    func estimateLength(ofTrack track: DRTrack) -> UInt64 { totalBlocks }

    @objc(prepareTrack:forBurn:toMedia:)
    func prepareTrack(_ t: DRTrack, for b: DRBurn, toMedia i: [String: Any]) -> Bool { true }

    @objc(cleanupTrackAfterBurn:)
    func cleanupTrack(afterBurn t: DRTrack) {}

    @objc(produceDataForTrack:intoBuffer:length:atAddress:blockSize:ioFlags:)
    func produceData(for track: DRTrack, intoBuffer buffer: UnsafeMutablePointer<Int8>,
                     length bufferLength: UInt32, atAddress address: UInt64,
                     blockSize bs: UInt32, ioFlags flags: UnsafeMutablePointer<UInt32>) -> UInt32 {
        let want = Int(bufferLength)
        let start = Int(address)                 // byte offset
        // Wait until the guest has durably written past this range.  WROTE is
        // emitted from the write completion, so the data is on disk by then.
        let needBlock = (UInt64(start) + UInt64(want) + 2047) / 2048
        var spins = 0
        while written.load() < needBlock && !closed.load() && spins < 500_000 {
            usleep(200); spins += 1
        }
        let raw = UnsafeMutableRawPointer(buffer)
        let got = pread(fd, raw, want, off_t(start))   // live read, not a snapshot
        let avail = max(0, Int(got))
        if avail < want { memset(raw + avail, 0, want - avail) }
        // Tell the emulator how far the physical burn has consumed, so it can
        // pace the guest's writes to the real burn speed (lockstep).
        let consumed = (UInt64(start) + UInt64(want) + 2047) / 2048
        let fd = connFD.load()
        if fd >= 0 {
            let msg = "CONSUMED \(consumed)\n"
            _ = msg.withCString { write(fd, $0, strlen($0)) }
        }
        return bufferLength
    }
}

/// A tiny lock-guarded value shared between the socket thread and the burn.
final class Atomic<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func load() -> T { lock.lock(); defer { lock.unlock() }; return value }
    func store(_ v: T) { lock.lock(); value = v; lock.unlock() }
}
