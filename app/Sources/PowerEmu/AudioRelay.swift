import AppKit
import Foundation
import AVFoundation
import CoreAudio
import os

/*
 * The Audio Relay: the sound PowerMusic makes on this Mac, sent to old Macs
 * so that they can play it.
 *
 * Apple's music can only be decrypted here, by MusicKit in a browser, so
 * the old Mac was never going to fetch it itself.  The obvious way to hand
 * it on was AirPlay, and AirPlay is why this exists instead.  AirPlay makes
 * the *receiver* keep time: a G4 taking an AirPlay stream decrypts every
 * packet, decodes ALAC, and then runs a clock-recovery filter and a
 * sample-stuffing resampler to chase the sender's clock to a two-second
 * deadline.  All of that is protocol, not music, and it is being run on the
 * slowest processor in the system.  A 1.5GHz G4 cannot do it and draw a
 * window at the same time, which is the whole fault this replaces.
 *
 * So the model is inverted.  The old Mac holds the clock: it reads bytes
 * into a ring and its own sound card pulls from that ring at whatever rate
 * its crystal happens to run at.  TCP's own backpressure is what paces this
 * Mac -- a receiver that stops reading stops us writing, with no protocol
 * for it at all.  The drift between the two machines' crystals is corrected
 * here, on the fast Mac, by resampling a few parts per million either way.
 *
 * And it is sent uncompressed, 16-bit stereo, big-endian by default.
 * 1.41 Mbit/s is nothing on a wired network and about seven per cent of
 * real 802.11g, while a decoder is processor the old Mac has not got.
 * Big-endian because the receiver is a PowerPC Mac and then it swaps
 * nothing: the whole cost of playing this on a G4 is one memcpy and one
 * multiply per sample.
 *
 * Protocol (and the client, pmaudio): PowerMusic's
 * docs/POWEREMU-AUDIO-RELAY.md.  Virtual Macs reach it at
 * 10.0.2.100:7781, other Macs at this Mac's port 7781 (Bonjour
 * _poweremu-audio._tcp) with a pairing code.
 */
final class AudioRelay: @unchecked Sendable {
    static let port: UInt16 = 7781

    /// Where the sound comes from.
    enum Source: Equatable {
        /// Only the browsers that could be showing the player page.  The
        /// usual choice: a notification or a film playing on this Mac is
        /// then not sent to the speakers in another room.
        case player
        /// Everything this Mac plays.
        case system
        /// One input device by UID, for a Mac with a loopback of its own.
        case device(String)
    }

    struct Settings {
        var source: Source = .player
        /// Keep this Mac silent while it is sending.  Otherwise you hear
        /// the same music twice, three seconds apart.
        var muteHost = true
        var pairingCode = ""
    }

    /// One listening Mac, as the Service Hub and /api/audio/receivers show it.
    struct ReceiverInfo: Identifiable {
        /// This connection, so a Mac that reconnects is not confused with
        /// the one it replaces, and two listeners on one Mac stay apart.
        var id: String
        var name: String
        var address: String
        var sinceSeconds: Int
        var fillMs: Int
        var underruns: Int
        var overruns: Int
        var format: String
        var rate: Int
    }

    private let note: @Sendable (String) -> Void
    private let lock = NSLock()
    private var settings = Settings()
    private var clients: [Receiver] = []
    /// Said once per reason, not once per connection: a Mac reconnecting
    /// every two seconds must not fill the Service Hub's log.
    private var complained: Set<String> = []

    private var capture: AudioCapture?

    init(note: @escaping @Sendable (String) -> Void) {
        self.note = note
    }

    func update(_ s: Settings) {
        lock.lock()
        let sourceChanged = s.source != settings.source || s.muteHost != settings.muteHost
        settings = s
        let running = capture != nil
        lock.unlock()
        // The tap describes its source when it is made, so a different
        // source means a different tap.  Only worth doing if anything is
        // listening; otherwise the next connection will make it.
        if sourceChanged && running { restartCapture() }
    }

    func receivers() -> [ReceiverInfo] {
        lock.lock(); let all = clients; lock.unlock()
        return all.map { $0.info() }
    }

    var isCapturing: Bool { lock.lock(); defer { lock.unlock() }; return capture != nil }

    // MARK: - What the music is doing

    /// Pause, seek, a different track: what is in flight is wrong now.  The
    /// receivers drop it and go quiet, which is what makes a three-second
    /// buffer and an immediate pause button possible at the same time.
    func flush() {
        lock.lock(); let all = clients; let c = capture; lock.unlock()
        c?.dropBuffered()
        for r in all { r.flush() }
    }

    func meta(title: String, artist: String, album: String) {
        let body = "title: \(title)\nartist: \(artist)\nalbum: \(album)\n"
        lock.lock(); let all = clients; lock.unlock()
        for r in all { r.send(.meta, Data(body.utf8)) }
    }

    // MARK: - A connection

    /// One connection from an old Mac; `fromNetwork` ones must pair.
    func serve(fd: Int32, fromNetwork: Bool) {
        defer { close(fd) }
        lock.lock(); let s = settings; lock.unlock()

        // The handshake is read here rather than with the HTTP reader the
        // other services use.  It looks close enough to an HTTP request to
        // be tempting -- a first line, then "key: value" -- but that reader
        // wants CRLF and waits two minutes for it, and the client at the
        // other end of this is a few hundred lines of C on a Mac from 2004
        // that may well end its lines with a bare newline.  Either is taken
        // here, and a client that sends neither is let go in five seconds
        // instead of holding a thread.
        guard let r = Handshake(fd: fd) else { return }
        guard r.greeting == "HELLO poweremu-audio/1" else {
            Self.write(fd, "ERROR 400 this is PowerEmu's audio relay, not a web server\r\n")
            return
        }
        if fromNetwork && !WebAccelerator.sameCode(r["token"] ?? "", s.pairingCode) {
            Self.write(fd, "ERROR 401 pairing code required\r\n")
            complain("audio: a Mac asked for the sound without the pairing code")
            return
        }

        let format = (r["format"] ?? "s16be").lowercased()
        guard format == "s16be" || format == "s16le" else {
            Self.write(fd, "ERROR 400 unsupported format\r\n")
            return
        }
        guard (r["channels"].flatMap { Int($0) } ?? 2) == 2 else {
            Self.write(fd, "ERROR 400 two channels only\r\n")
            return
        }
        let rate = min(max(Int(r["rate"] ?? "44100") ?? 44100, 8000), 96000)
        let bufferMs = min(max(Int(r["buffer"] ?? "3000") ?? 3000, 500), 8000)
        let name = r["name"] ?? "an old Mac"

        let receiver = Receiver(fd: fd, name: name, address: Self.peerName(fd),
                                rate: rate, format: format, bufferMs: bufferMs)

        guard startCapture(for: receiver) else {
            Self.write(fd, "ERROR 503 no audio source\r\n")
            return
        }

        Self.write(fd, "OK poweremu-audio/1\r\n"
                   + "rate: \(rate)\r\nformat: \(format)\r\nchannels: 2\r\n"
                   + "chunk: \(Receiver.chunkBytes)\r\n"
                   + "name: \(Host.current().localizedName ?? "PowerEmu")\r\n\r\n")

        lock.lock(); clients.append(receiver); lock.unlock()
        note("audio: \(name) is listening (\(format) at \(rate), \(bufferMs)ms)")

        // This thread becomes the receiver's: it writes frames and reads the
        // FILL reports coming back, until one end stops.
        receiver.run()

        lock.lock()
        clients.removeAll { $0 === receiver }
        let left = clients.count
        lock.unlock()
        let i = receiver.info()
        note("audio: \(name) stopped listening"
             + (i.underruns > 0 || i.overruns > 0
                ? " (\(i.underruns) underrun\(i.underruns == 1 ? "" : "s"), "
                  + "\(i.overruns) overrun\(i.overruns == 1 ? "" : "s"))" : ""))
        if left == 0 { stopCapture() }
    }

    private func complain(_ m: String) {
        lock.lock(); let fresh = complained.insert(m).inserted; lock.unlock()
        if fresh { note(m) }
    }

    // MARK: - Capture, while somebody is listening

    /// The tap is made when the first Mac connects and destroyed when the
    /// last one goes, so this Mac's sound is its own -- and the permission
    /// to record it only engaged -- while the music is actually going
    /// somewhere.
    private func startCapture(for r: Receiver) -> Bool {
        lock.lock()
        if let c = capture {
            c.add(r)
            lock.unlock()
            return true
        }
        let s = settings
        lock.unlock()

        guard #available(macOS 14.2, *) else {
            complain("audio: sending the sound to another Mac needs macOS 14.2 or later")
            return false
        }
        do {
            let c = try Capture(source: s.source, muteHost: s.muteHost)
            c.add(r)
            lock.lock(); capture = c; lock.unlock()
            return true
        } catch let e as CaptureError {
            complain("audio: \(e.message)")
            return false
        } catch {
            complain("audio: could not listen to this Mac's sound: \(error.localizedDescription)")
            return false
        }
    }

    private func stopCapture() {
        lock.lock(); let c = capture; capture = nil; lock.unlock()
        c?.stop()
    }

    private func restartCapture() {
        lock.lock(); let old = capture; let s = settings; let all = clients; lock.unlock()
        old?.stop()
        guard #available(macOS 14.2, *), !all.isEmpty else { return }
        guard let c = try? Capture(source: s.source, muteHost: s.muteHost) else {
            lock.lock(); capture = nil; lock.unlock()
            complain("audio: could not change where the sound comes from")
            return
        }
        for r in all { c.add(r) }
        lock.lock(); capture = c; lock.unlock()
        note("audio: now sending \(Self.describe(s.source))")
    }

    static func describe(_ s: Source) -> String {
        switch s {
        case .player: return "the player page's sound"
        case .system: return "everything this Mac plays"
        case .device(let uid): return "the input \(uid)"
        }
    }

    // MARK: - Small socket helpers

    fileprivate static func write(_ fd: Int32, _ s: String) {
        var d = Array(s.utf8)
        var off = 0
        while off < d.count {
            let n = d.withUnsafeMutableBytes { Darwin.send(fd, $0.baseAddress!.advanced(by: off), $0.count - off, 0) }
            if n <= 0 { return }
            off += n
        }
    }

    private static func peerName(_ fd: Int32) -> String {
        var sa = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard ok == 0, sa.ss_family == sa_family_t(AF_INET) else { return "virtual Mac" }
        return withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
        }
    }
}

/// The first thing a listener sends: a greeting line, then "key: value"
/// lines, then a blank one.  Lines end with LF or CRLF, whichever the
/// client found easier to write.
private struct Handshake {
    let greeting: String
    private let fields: [String: String]
    subscript(_ k: String) -> String? { fields[k] }

    /// nil if the client did not finish in five seconds, sent more than a
    /// handshake could possibly be, or went away.
    init?(fd: Int32) {
        var text = Data()
        var buf = [UInt8](repeating: 0, count: 512)
        let deadline = Date().addingTimeInterval(5)
        var done = false
        while !done {
            if Date() > deadline || text.count > 4096 { return nil }
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&p, 1, 250)
            if ready < 0 && errno != EINTR { return nil }
            if ready <= 0 { continue }
            let n = read(fd, &buf, buf.count)
            if n <= 0 { return nil }
            text.append(contentsOf: buf[0..<n])
            // A blank line, written either way round.
            done = text.range(of: Data("\n\n".utf8)) != nil
                || text.range(of: Data("\r\n\r\n".utf8)) != nil
        }
        var lines = String(decoding: text, as: UTF8.self)
            .replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        guard let first = lines.first else { return nil }
        greeting = first.trimmingCharacters(in: .whitespaces)
        lines.removeFirst()
        var f: [String: String] = [:]
        for l in lines {
            if l.isEmpty { break }
            guard let colon = l.firstIndex(of: ":") else { continue }
            f[l[..<colon].lowercased().trimmingCharacters(in: .whitespaces)] =
                String(l[l.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        fields = f
    }
}

/// What the relay needs of whatever is listening to this Mac.  A protocol
/// so the relay, which runs on every system PowerEmu supports, can hold a
/// Capture, which needs macOS 14.2.
private protocol AudioCapture: AnyObject {
    func add(_ r: Receiver)
    func dropBuffered()
    func stop()
}

// MARK: - The frames

/// What a frame on the wire is: a type, a flag byte nothing uses yet, and a
/// big-endian length, then the payload.  Four bytes per 4KB of music.
enum AudioFrameType: UInt8 {
    case audio = 0x01
    case flush = 0x02
    case ping  = 0x03
    case meta  = 0x04
}

// MARK: - One listening Mac

/// Holds the bytes owed to one receiver and writes them to it.
///
/// Two threads touch this: the pump (converting this Mac's sound) puts
/// bytes in, and the receiver's own thread takes them out and writes them to
/// the socket.  A ring with a lock held only across a memcpy is enough for
/// that, and the pump must never wait on the socket -- one slow Mac on a
/// tired Wi-Fi card must not hold up the tap or anybody else listening.
private final class Receiver: @unchecked Sendable {
    static let chunkBytes = 4096            // 1024 frames, 23ms of stereo

    let fd: Int32
    let id = UUID().uuidString
    let name: String
    let address: String
    let rate: Int
    let format: String
    let bufferMs: Int
    /// The format and rate this receiver asked for, as the pump groups them.
    var key: String { "\(format)/\(rate)" }

    private let started = Date()
    private let lock = NSLock()
    private let waiting = NSCondition()
    private var ring: Data = Data()
    private let capacity: Int
    private var finished = false
    /// What the receiver last reported about itself.
    private var fillMs = 0
    private var underruns = 0
    private var overruns = 0
    private var lastHeard = Date()
    /// Set by flush(), cleared when the FLUSH frame has gone out.
    private var flushPending = false

    init(fd: Int32, name: String, address: String, rate: Int, format: String, bufferMs: Int) {
        self.fd = fd
        self.name = name
        self.address = address
        self.rate = rate
        self.format = format
        self.bufferMs = bufferMs
        // Room for twice what the receiver wants to hold, so this Mac can
        // be comfortably ahead without the ring being the thing that limits
        // it.  3000ms at 44100 is about a megabyte.
        capacity = max(bufferMs * 2 * rate * 4 / 1000, Self.chunkBytes * 8)
        ring.reserveCapacity(capacity)
    }

    func info() -> AudioRelay.ReceiverInfo {
        lock.lock(); defer { lock.unlock() }
        return .init(id: id, name: name, address: address,
                     sinceSeconds: Int(Date().timeIntervalSince(started)),
                     fillMs: fillMs, underruns: underruns, overruns: overruns,
                     format: format, rate: rate)
    }

    /// How far the receiver is from the depth it asked for, in milliseconds.
    /// Negative means it is draining.  nil until it has reported.
    func fillError() -> Int? {
        lock.lock(); defer { lock.unlock() }
        return lastHeard.timeIntervalSinceNow > -30 && fillMs > 0 ? fillMs - bufferMs : nil
    }

    // MARK: putting bytes in

    /// Called by the pump.  Never blocks: if the ring is full this receiver
    /// is behind, and the oldest music is the music to lose.
    func enqueue(_ d: Data) {
        lock.lock()
        ring.append(d)
        if ring.count > capacity {
            let drop = ring.count - capacity
            ring.removeFirst(drop)
            overruns += 1
        }
        lock.unlock()
        waiting.signal()
    }

    func flush() {
        lock.lock()
        ring.removeAll(keepingCapacity: true)
        flushPending = true
        lock.unlock()
        waiting.signal()
    }

    func send(_ type: AudioFrameType, _ payload: Data) {
        guard payload.count <= 0xFFFF else { return }
        var out = Data([type.rawValue, 0,
                        UInt8((payload.count >> 8) & 0xFF), UInt8(payload.count & 0xFF)])
        out.append(payload)
        lock.lock(); ring.append(out); lock.unlock()
        waiting.signal()
    }

    func finish() {
        lock.lock(); finished = true; lock.unlock()
        waiting.signal()
    }

    // MARK: the receiver's own thread

    /// Writes frames until the socket or the relay closes, reading the
    /// receiver's FILL reports in between.  Blocking writes are deliberate:
    /// they are the backpressure that paces this Mac to the old one.
    func run() {
        // Five seconds: long enough that a busy G4 is never mistaken for a
        // gone one, short enough that a Mac switched off at the wall does
        // not pin this thread for the rest of the afternoon.
        var tv = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var zero = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &zero, socklen_t(MemoryLayout<timeval>.size))
        var yes: Int32 = 1
        setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &yes, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL, 0) | O_NONBLOCK)

        var lastPing = Date()
        while true {
            readReports()

            lock.lock()
            if finished { lock.unlock(); return }
            if flushPending {
                flushPending = false
                lock.unlock()
                guard writeAll(Data([AudioFrameType.flush.rawValue, 0, 0, 0])) else { return }
                continue
            }
            let take = min(ring.count, Self.chunkBytes)
            let chunk = take > 0 ? Data(ring.prefix(take)) : Data()
            if take > 0 { ring.removeFirst(take) }
            lock.unlock()

            if chunk.isEmpty {
                // Nothing owed.  Ask how it is getting on now and then, so
                // a receiver that has gone quiet is noticed.
                if Date().timeIntervalSince(lastPing) > 5 {
                    lastPing = Date()
                    guard writeAll(Data([AudioFrameType.ping.rawValue, 0, 0, 0])) else { return }
                }
                waiting.lock()
                waiting.wait(until: Date().addingTimeInterval(0.05))
                waiting.unlock()
                continue
            }

            var header = Data([AudioFrameType.audio.rawValue, 0,
                               UInt8((chunk.count >> 8) & 0xFF), UInt8(chunk.count & 0xFF)])
            header.append(chunk)
            guard writeAll(header) else { return }

            lock.lock(); let silent = lastHeard.timeIntervalSinceNow < -30; lock.unlock()
            if silent {
                harmonyDebug("PEAUDIO \(name) said nothing for 30s; dropping it")
                return
            }
        }
    }

    /// Blocking in effect, on a non-blocking socket: a full send buffer
    /// means the old Mac is not reading yet, which is exactly when we should
    /// wait rather than throw music away.
    private func writeAll(_ d: Data) -> Bool {
        var off = 0
        let deadline = Date().addingTimeInterval(20)
        return d.withUnsafeBytes { raw -> Bool in
            while off < raw.count {
                let n = Darwin.send(fd, raw.baseAddress!.advanced(by: off), raw.count - off, 0)
                if n > 0 { off += n; continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) {
                    if Date() > deadline { return false }
                    var p = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                    poll(&p, 1, 200)
                    readReports()
                    continue
                }
                return false
            }
            return true
        }
    }

    /// FILL lines coming back up the same socket.  Non-blocking: whatever
    /// has arrived, and no waiting for the rest.
    private var inbox = Data()
    private func readReports() {
        var buf = [UInt8](repeating: 0, count: 512)
        while true {
            let n = recv(fd, &buf, buf.count, 0)
            if n > 0 { inbox.append(contentsOf: buf[0..<n]); continue }
            if n == 0 { lock.lock(); finished = true; lock.unlock(); return }
            break                                  // EAGAIN: nothing more for now
        }
        while let i = inbox.firstIndex(of: 0x0a) {
            let line = String(decoding: inbox[inbox.startIndex..<i], as: UTF8.self)
                .trimmingCharacters(in: .whitespaces)
            inbox = Data(inbox[inbox.index(after: i)...])
            let f = line.split(separator: " ").map(String.init)
            switch f.first {
            case "FILL":
                lock.lock()
                if f.count > 1, let ms = Int(f[1]) { fillMs = ms }
                if f.count > 2, let u = Int(f[2]) { underruns = u }
                lastHeard = Date()
                lock.unlock()
            case "BYE":
                lock.lock(); finished = true; lock.unlock()
            default:
                break                               // v2's business, not ours
            }
        }
        if inbox.count > 4096 { inbox.removeAll(keepingCapacity: true) }
    }
}

// MARK: - Listening to this Mac

private struct CaptureError: Error { let message: String }

/// The tap, the device that carries it, and the thread that turns what it
/// hears into what the old Macs asked for.
@available(macOS 14.2, *)
private final class Capture: AudioCapture, @unchecked Sendable {
    private var tap = AudioObjectID(kAudioObjectUnknown)
    private var aggregate = AudioObjectID(kAudioObjectUnknown)
    private var proc: AudioDeviceIOProcID?
    private let inputFormat: AVAudioFormat

    /// What the tap heard, waiting to be converted.  The tap's callback runs
    /// on a thread this Mac schedules in real time: it may copy and signal,
    /// and it may not allocate, convert, or take a lock anybody holds for
    /// long.  So it does a memcpy under an unfair lock -- held for
    /// microseconds, never across anything that can wait -- and wakes the
    /// pump.
    private let ringLock = OSAllocatedUnfairLock()
    private let ring: UnsafeMutablePointer<Float>
    private let ringFrames: Int
    private var ringWrite = 0
    private var ringRead = 0
    private var dropped = 0
    private let awake = DispatchSemaphore(value: 0)

    private let lock = NSLock()
    private var receivers: [Receiver] = []
    private var converters: [String: Converter] = [:]
    private var running = true

    init(source: AudioRelay.Source, muteHost: Bool) throws {
        let desc = try Self.describe(source: source, muteHost: muteHost)
        var id = AudioObjectID(kAudioObjectUnknown)
        let st = AudioHardwareCreateProcessTap(desc, &id)
        guard st == noErr, id != AudioObjectID(kAudioObjectUnknown) else {
            // The one failure worth naming: this Mac has not been told it
            // may listen to itself.  Everything else is a number.
            if st == kAudioHardwareIllegalOperationError {
                throw CaptureError(message: "this Mac has not allowed PowerEmu to record its sound "
                                   + "— System Settings → Privacy & Security → Audio Recording")
            }
            throw CaptureError(message: "could not listen to this Mac's sound (CoreAudio \(st))")
        }
        tap = id

        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd) == noErr,
              let fmt = AVAudioFormat(streamDescription: &asbd), fmt.channelCount >= 1 else {
            AudioHardwareDestroyProcessTap(tap)
            throw CaptureError(message: "the sound this Mac is making is in a format PowerEmu cannot read")
        }
        inputFormat = fmt

        // Two and a half seconds at 48kHz: room for the pump to be held up
        // by something else on this Mac without a gap reaching the old one.
        ringFrames = 1 << 17
        ring = UnsafeMutablePointer<Float>.allocate(capacity: ringFrames * Int(fmt.channelCount))
        ring.initialize(repeating: 0, count: ringFrames * Int(fmt.channelCount))

        do {
            try start()
        } catch {
            ring.deallocate()
            AudioHardwareDestroyProcessTap(tap)
            throw error
        }
        Thread.detachNewThread { [weak self] in self?.pump() }
    }

    // MARK: the tap

    private static func describe(source: AudioRelay.Source, muteHost: Bool) throws -> CATapDescription {
        let d: CATapDescription
        switch source {
        case .player:
            // On macOS 26 a tap can name the applications it wants and
            // follow them as they come and go, which is what we want: the
            // browser showing the player page may be started after this.
            if #available(macOS 26.0, *) {
                d = CATapDescription(stereoMixdownOfProcesses: [])
                d.bundleIDs = Self.playerBundleIDs
                d.isProcessRestoreEnabled = true
            } else {
                let ids = Self.playerProcessIDs()
                guard !ids.isEmpty else {
                    throw CaptureError(message: "no browser is open to play the music — "
                                       + "open the player page, or send everything this Mac plays")
                }
                d = CATapDescription(stereoMixdownOfProcesses: ids)
            }
        case .system:
            d = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .device(let uid):
            d = CATapDescription(__excludingProcesses: [], andDeviceUID: uid, withStream: 0)
        }
        d.name = "PowerEmu Audio Relay"
        // Private: this is PowerEmu's own business and has no place in
        // other applications' device lists.
        d.isPrivate = true
        // Unmuted until somebody reads it, muted while they do, so this Mac
        // plays normally when nothing is listening and goes quiet -- rather
        // than playing the same music three seconds out -- when it is.
        d.muteBehavior = muteHost ? .mutedWhenTapped : .unmuted
        return d
    }

    /// The browsers that could be showing the player page, and PowerEmu
    /// itself for the day it shows the page in a window of its own.
    private static let playerBundleIDs = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview",
        "com.google.Chrome", "com.google.Chrome.canary",
        "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.Browser",
        "org.mozilla.firefox", "com.operasoftware.Opera", "com.vivaldi.Vivaldi",
        Bundle.main.bundleIdentifier ?? "com.spartan0285.poweremu",
    ]

    private static func playerProcessIDs() -> [AudioObjectID] {
        var out: [AudioObjectID] = []
        for id in playerBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: id) {
                var pid = app.processIdentifier
                var obj = AudioObjectID(kAudioObjectUnknown)
                var size = UInt32(MemoryLayout<AudioObjectID>.size)
                var addr = AudioObjectPropertyAddress(
                    mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain)
                if AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                              UInt32(MemoryLayout<pid_t>.size), &pid,
                                              &size, &obj) == noErr,
                   obj != AudioObjectID(kAudioObjectUnknown) {
                    out.append(obj)
                }
            }
        }
        return out
    }

    /// A private aggregate device is what makes a tap readable: the tap is
    /// its input, and this Mac's own output is its clock.
    private func start() throws {
        guard let outputUID = Self.defaultOutputUID() else {
            throw CaptureError(message: "this Mac has no sound output to keep time by")
        }
        guard let uuid = tapUUID() else {
            throw CaptureError(message: "the sound tap would not say what it is called")
        }
        let desc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PowerEmu Audio Relay",
            kAudioAggregateDeviceUIDKey: "com.spartan0285.poweremu.audiorelay",
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: uuid,
                                               kAudioSubTapDriftCompensationKey: true]],
        ]
        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg) == noErr,
              agg != AudioObjectID(kAudioObjectUnknown) else {
            throw CaptureError(message: "could not make the device that carries the sound tap")
        }
        aggregate = agg

        let channels = Int(inputFormat.channelCount)
        var procID: AudioDeviceIOProcID?
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) {
            [weak self] _, inData, _, _, _ in
            guard let self else { return }
            let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inData))
            guard let b = abl.first, let base = b.mData, b.mDataByteSize > 0 else { return }
            let frames = Int(b.mDataByteSize) / (MemoryLayout<Float>.size * max(channels, 1))
            self.deposit(base.assumingMemoryBound(to: Float.self), frames: frames, channels: channels)
        }
        guard st == noErr, let procID else {
            AudioHardwareDestroyAggregateDevice(agg)
            throw CaptureError(message: "could not start reading the sound tap")
        }
        proc = procID
        guard AudioDeviceStart(agg, procID) == noErr else {
            AudioDeviceDestroyIOProcID(agg, procID)
            AudioHardwareDestroyAggregateDevice(agg)
            throw CaptureError(message: "the device that carries the sound tap would not start")
        }
    }

    /// In the tap's callback.  A copy and a signal, nothing else.
    private func deposit(_ src: UnsafePointer<Float>, frames: Int, channels: Int) {
        ringLock.lock()
        let used = ringWrite - ringRead
        if used + frames > ringFrames {
            // The pump is behind.  Keep the newest sound: old sound that
            // nobody has sent yet is of no use to anyone.
            ringRead = ringWrite + frames - ringFrames
            dropped += 1
        }
        var w = ringWrite
        for i in 0..<frames {
            let dst = ring + ((w + i) % ringFrames) * channels
            memcpy(dst, src + i * channels, channels * MemoryLayout<Float>.size)
        }
        w += frames
        ringWrite = w
        ringLock.unlock()
        awake.signal()
    }

    private func take(_ into: UnsafeMutablePointer<Float>, max frames: Int, channels: Int) -> Int {
        ringLock.lock()
        let have = min(ringWrite - ringRead, frames)
        let r = ringRead
        for i in 0..<have {
            memcpy(into + i * channels, ring + ((r + i) % ringFrames) * channels,
                   channels * MemoryLayout<Float>.size)
        }
        ringRead = r + have
        ringLock.unlock()
        return have
    }

    // MARK: receivers

    func add(_ r: Receiver) {
        lock.lock()
        receivers.append(r)
        if converters[r.key] == nil {
            converters[r.key] = Converter(from: inputFormat, rate: r.rate, bigEndian: r.format == "s16be")
        }
        lock.unlock()
    }

    func dropBuffered() {
        ringLock.lock(); ringRead = ringWrite; ringLock.unlock()
        lock.lock(); for c in converters.values { c.reset() }; lock.unlock()
    }

    func stop() {
        lock.lock(); running = false; let all = receivers; receivers = []; lock.unlock()
        for r in all { r.finish() }
        awake.signal()
        if let proc {
            AudioDeviceStop(aggregate, proc)
            AudioDeviceDestroyIOProcID(aggregate, proc)
        }
        if aggregate != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyAggregateDevice(aggregate) }
        if tap != AudioObjectID(kAudioObjectUnknown) { AudioHardwareDestroyProcessTap(tap) }
        proc = nil
        aggregate = AudioObjectID(kAudioObjectUnknown)
        tap = AudioObjectID(kAudioObjectUnknown)
    }

    // MARK: the pump

    /// Off the real-time thread, where converting and allocating are
    /// allowed: whatever the tap has heard becomes what each receiver asked
    /// for, and goes into its ring.
    private func pump() {
        let channels = Int(inputFormat.channelCount)
        let slice = 4096
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: slice * channels)
        defer { staging.deallocate() }
        var lastDrift = Date()

        while true {
            awake.wait(timeout: .now() + .milliseconds(100))
            lock.lock(); let go = running; let all = receivers; let convs = converters; lock.unlock()
            if !go { break }

            while true {
                let got = take(staging, max: slice, channels: channels)
                if got == 0 { break }
                for (key, conv) in convs {
                    guard let bytes = conv.convert(staging, frames: got), !bytes.isEmpty else { continue }
                    for r in all where r.key == key { r.enqueue(bytes) }
                }
            }

            // Drift: slowly, and only on the clock's own timescale.  The two
            // machines' crystals differ by a few parts per million and
            // nothing about that changes from one second to the next, so a
            // fast correction would only be a fast correction to hear.
            if Date().timeIntervalSince(lastDrift) >= 10 {
                lastDrift = Date()
                for (key, conv) in convs {
                    let errors = all.filter { $0.key == key }.compactMap { $0.fillError() }
                    guard let worst = errors.max(by: { abs($0) < abs($1) }) else { continue }
                    conv.nudge(towards: worst)
                }
            }
        }

        lock.lock(); let left = receivers; lock.unlock()
        for r in left { r.finish() }
    }

    // MARK: this Mac's output, for the clock

    private func tapUUID() -> String? {
        var uuid: CFString? = nil
        var size = UInt32(MemoryLayout<CFString?>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyUID,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &uuid) == noErr else { return nil }
        return uuid as String?
    }

    private static func defaultOutputUID() -> String? {
        var dev = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                              mScope: kAudioObjectPropertyScopeGlobal,
                                              mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                         0, nil, &size, &dev) == noErr,
              dev != AudioObjectID(kAudioObjectUnknown) else { return nil }
        var uid: CFString? = nil
        var usize = UInt32(MemoryLayout<CFString?>.size)
        var uaddr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                               mScope: kAudioObjectPropertyScopeGlobal,
                                               mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(dev, &uaddr, 0, nil, &usize, &uid) == noErr else { return nil }
        return uid as String?
    }
}

// MARK: - Float32 in, 16-bit out, at the old Mac's rate

/// One format an old Mac asked for.  Rebuilt when the drift correction
/// changes, which is at most once every ten seconds.
private final class Converter {
    private let input: AVAudioFormat
    private let rate: Int
    private let bigEndian: Bool
    /// Parts per million, positive meaning "produce slightly more", which
    /// fills a receiver that is draining.  Clamped: a real crystal
    /// difference between two Macs is tens of ppm, never hundreds, so a
    /// larger number would be a fault in this loop rather than a correction.
    private var ppm = 0.0
    private static let maxPPM = 100.0
    private static let stepPPM = 5.0
    /// Below this, nothing is wrong and nothing is changed.  Most of the
    /// time the relay lives here.
    private static let deadbandMs = 100

    private var converter: AVAudioConverter?
    private var output: AVAudioFormat?
    private var pending: AVAudioPCMBuffer?

    init(from input: AVAudioFormat, rate: Int, bigEndian: Bool) {
        self.input = input
        self.rate = rate
        self.bigEndian = bigEndian
        rebuild()
    }

    private func rebuild() {
        // The receiver plays everything at the rate it asked for, so asking
        // the converter for slightly more or less than that is how a few
        // parts per million of drift are taken out.
        let effective = Double(rate) * (1.0 + ppm / 1_000_000.0)
        guard let out = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: effective,
                                      channels: input.channelCount >= 2 ? 2 : 1, interleaved: true),
              let c = AVAudioConverter(from: input, to: out) else {
            converter = nil
            return
        }
        c.sampleRateConverterQuality = AVAudioQuality.high.rawValue
        c.channelMap = input.channelCount >= 2 ? [0, 1] : [0]
        converter = c
        output = out
    }

    func reset() {
        converter?.reset()
        pending = nil
    }

    func nudge(towards errorMs: Int) {
        guard abs(errorMs) > Self.deadbandMs else { return }
        let next = max(-Self.maxPPM, min(Self.maxPPM, ppm + (errorMs < 0 ? Self.stepPPM : -Self.stepPPM)))
        guard next != ppm else { return }
        ppm = next
        harmonyDebug("PEAUDIO drift at \(rate): \(errorMs)ms out, now \(ppm)ppm")
        rebuild()
    }

    /// Interleaved Float32 in, the receiver's bytes out.
    func convert(_ src: UnsafeMutablePointer<Float>, frames: Int) -> Data? {
        guard let converter, let output, frames > 0 else { return nil }
        let channels = Int(input.channelCount)
        guard let inBuf = AVAudioPCMBuffer(pcmFormat: input, frameCapacity: AVAudioFrameCount(frames)),
              let dst = inBuf.floatChannelData else { return nil }
        inBuf.frameLength = AVAudioFrameCount(frames)
        if input.isInterleaved {
            memcpy(dst[0], src, frames * channels * MemoryLayout<Float>.size)
        } else {
            for c in 0..<channels {
                for i in 0..<frames { dst[c][i] = src[i * channels + c] }
            }
        }

        // Rate conversion can produce a little more than it was given, so
        // the output buffer is generous rather than exact.
        let capacity = AVAudioFrameCount(Double(frames) * output.sampleRate / input.sampleRate + 64)
        guard let outBuf = AVAudioPCMBuffer(pcmFormat: output, frameCapacity: capacity) else { return nil }

        var fed = false
        var err: NSError?
        let status = converter.convert(to: outBuf, error: &err) { _, outStatus in
            if fed { outStatus.pointee = .noDataNow; return nil }
            fed = true
            outStatus.pointee = .haveData
            return inBuf
        }
        guard status != .error, outBuf.frameLength > 0, let samples = outBuf.int16ChannelData else {
            if let err { harmonyDebug("PEAUDIO convert failed: \(err.localizedDescription)") }
            return nil
        }

        let count = Int(outBuf.frameLength) * Int(output.channelCount)
        var out = Data(count: count * 2)
        out.withUnsafeMutableBytes { raw in
            let d = raw.baseAddress!.assumingMemoryBound(to: UInt16.self)
            let s = samples[0]
            if bigEndian {
                // The receiver is a PowerPC Mac: sent this way round it
                // swaps nothing at all, which is the point.
                for i in 0..<count { d[i] = UInt16(bitPattern: s[i]).bigEndian }
            } else {
                for i in 0..<count { d[i] = UInt16(bitPattern: s[i]).littleEndian }
            }
        }
        return out
    }
}
