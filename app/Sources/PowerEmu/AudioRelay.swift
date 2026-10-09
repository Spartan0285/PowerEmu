import AVFoundation
import AppKit
import CoreAudio
import Foundation
import os

/// The Audio Relay: the sound this Mac is making, sent to old Macs that
/// cannot make it themselves.
///
/// Apple Music's audio can only be decrypted on a modern Mac, so PowerEmu's
/// player page does the playing; this listens to the result with a CoreAudio
/// process tap, resamples it to whatever rate the old Mac's own hardware
/// runs at, and sends it as plain uncompressed PCM down one TCP connection.
/// Nothing is encoded: 1.41 Mbit/s is nothing on a LAN, and a G4 has no
/// processor to spare for a decoder.
///
/// The old Mac holds the clock.  It reads into a ring and its CoreAudio
/// pulls from that ring at the rate its own crystal dictates; when the ring
/// is full it stops reading, which arrives here as TCP backpressure and
/// throttles this Mac for free.  That is the whole reason this exists
/// instead of AirPlay, where the receiver has to chase the sender's clock --
/// decrypt, decode, filter and resample against a deadline -- and a 1.5 GHz
/// G4 cannot afford to (PowerMusic: docs/STREAMING-ARCHITECTURE.md).
///
/// Protocol (PowerMusic: docs/POWEREMU-AUDIO-RELAY.md): a line-based
/// HELLO/OK handshake, then 4-byte framed PCM for ever, with the old Mac
/// reporting how full its buffer is on the same socket.  Virtual Macs reach
/// it at 10.0.2.100:7781, other Macs at this Mac's port 7781 (Bonjour
/// _poweremu-audio._tcp) with a pairing code.
final class AudioRelay: @unchecked Sendable {
    static let port: UInt16 = 7781
    /// One AUDIO payload: 1024 stereo s16 frames, 23 ms, 0.1 % framing
    /// overhead.  Small, so a FLUSH is never far behind the audio it has to
    /// get in front of.
    static let chunk = 4096

    /// What the tap listens to.
    enum Source: Equatable {
        /// The browsers that could be showing the player page.
        case player
        /// Everything this Mac plays.
        case system
        /// Only what goes to one of this Mac's output devices.
        case device(String)
    }

    struct Settings {
        var source = Source.player
        var muteHost = true
        var pairingCode = ""
    }

    /// One old Mac listening, as the Service Hub and /api/audio/receivers
    /// show it.
    struct ReceiverInfo: Identifiable, Equatable, Sendable {
        var id: Int
        var name: String
        var address: String
        var sinceSeconds: Int
        var fillMs: Int
        var underruns: Int
        var overruns: Int
        var format: String
        var rate: Int
    }

    /// An output device of this Mac, for the Source list.
    struct OutputDevice: Identifiable, Equatable, Sendable {
        var uid: String
        var name: String
        var id: String { uid }
    }

    /// The four frame types.  A client skips anything it does not know
    /// using the length, so adding a fifth never desynchronises it.
    enum Kind: UInt8 { case audio = 1, flush = 2, ping = 3, meta = 4 }

    private let lock = NSLock()
    private var settings = Settings()
    private let note: @Sendable (String) -> Void

    private var clients: [AudioReceiver] = []
    private var nextID = 1
    /// The tap, its aggregate device and the thread that converts: there
    /// while anyone is listening and not a moment longer.
    private var capture: AudioCapture?
    private var captureUsers = 0
    /// What stopped the last attempt to listen, for the Service Hub.  Noted
    /// in the log once and then not again: a refused tap is a decision the
    /// reader has to change in System Settings, not something to retry.
    private var trouble: String?
    private var troubleNoted = false
    private var lastMeta = Data()

    init(note: @escaping @Sendable (String) -> Void) {
        self.note = note
    }

    func update(_ s: Settings) {
        lock.lock()
        let different = s.source != settings.source || s.muteHost != settings.muteHost
        settings = s
        let listening = capture != nil
        lock.unlock()
        if different && listening { restartCapture() }
    }

    // MARK: - What the Service Hub asks

    func receivers() -> [ReceiverInfo] {
        lock.lock(); let c = clients; lock.unlock()
        return c.map { $0.info() }
    }

    /// Whether the tap is actually running.
    var capturing: Bool { lock.lock(); defer { lock.unlock() }; return capture != nil }

    /// What stopped it, if anything.
    var problem: String? { lock.lock(); defer { lock.unlock() }; return trouble }

    // MARK: - What the music tells it

    /// Pause, seek, a different track: everything in flight is wrong.  Each
    /// receiver throws its buffer away and goes silent now, which is what
    /// makes the controls feel immediate with a three-second buffer.
    func flush() {
        lock.lock(); let c = clients; lock.unlock()
        for r in c { r.flush() }
    }

    func meta(title: String, artist: String, album: String) {
        let text = "title: \(title)\nartist: \(artist)\nalbum: \(album)\n"
        let f = Self.frame(.meta, Data(text.utf8))
        lock.lock()
        lastMeta = f
        let c = clients
        lock.unlock()
        for r in c { r.queue(f) }
    }

    // MARK: - One connection

    /// One old Mac, on its own thread for as long as it listens.
    /// `fromNetwork` ones must pair; a virtual Mac on the Unix socket is
    /// already inside this Mac.
    func serve(fd: Int32, fromNetwork: Bool) {
        defer { close(fd) }
        // Five seconds to say hello, and five for any one write: a machine
        // that has vanished must not pin a thread.
        var deadline = timeval(tv_sec: 5, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &deadline, socklen_t(MemoryLayout<timeval>.size))
        let lines = AudioLines(fd: fd)

        guard let hello = lines.headers() else { return }
        guard hello.first == "HELLO poweremu-audio/1" else {
            // Including an HTTP request: someone who pointed a browser at
            // this port gets a sentence rather than silence.
            _ = sendAll(fd, Data("ERROR 400 this is the PowerEmu Audio Relay; send HELLO poweremu-audio/1\r\n".utf8))
            return
        }
        // Pairing first: a Mac that has not got the code is told that, and
        // nothing else.  Answering "unsupported format" to someone who was
        // never going to be let in tells them what we accept for no reason.
        lock.lock(); let code = settings.pairingCode; lock.unlock()
        if fromNetwork && !WebAccelerator.sameCode(hello.fields["token"] ?? "", code) {
            _ = sendAll(fd, Data("ERROR 401 pairing code required\r\n".utf8))
            return
        }
        let format = (hello.fields["format"] ?? "s16be").lowercased()
        guard format == "s16be" || format == "s16le" else {
            _ = sendAll(fd, Data("ERROR 400 unsupported format\r\n".utf8))
            return
        }
        guard (Int(hello.fields["channels"] ?? "2") ?? 2) == 2 else {
            _ = sendAll(fd, Data("ERROR 400 two channels only in version 1\r\n".utf8))
            return
        }
        let rate = min(192_000, max(8_000, Int(hello.fields["rate"] ?? "44100") ?? 44_100))
        let buffer = min(8_000, max(500, Int(hello.fields["buffer"] ?? "3000") ?? 3_000))
        let name = hello.fields["name"]?.isEmpty == false ? hello.fields["name"]! : "an old Mac"

        // The tap starts for the first receiver, so the capture permission
        // engages only while sound is actually being sent.
        if let refused = beginCapture() {
            _ = sendAll(fd, Data((refused + "\r\n").utf8))
            return
        }
        defer { endCapture() }

        let peer = fromNetwork ? Self.peerAddress(fd) : "virtual Mac"
        let rx = AudioReceiver(id: register(), name: name, address: peer, rate: rate,
                              bigEndian: format == "s16be", bufferMs: buffer)
        let ok = "OK poweremu-audio/1\r\nrate: \(rate)\r\nformat: \(format)\r\nchannels: 2\r\n"
            + "chunk: \(Self.chunk)\r\nname: \(Host.current().localizedName ?? "PowerEmu")\r\n\r\n"
        guard sendAll(fd, Data(ok.utf8)) else { return }

        lock.lock()
        clients.append(rx)
        let meta = lastMeta
        lock.unlock()
        if !meta.isEmpty { rx.queue(meta) }
        note("Sound: \(name) is listening at \(peer) (\(format), \(rate) Hz, \(buffer) ms)")

        stream(fd, rx, lines)

        lock.lock()
        clients.removeAll { $0 === rx }
        lock.unlock()
        let i = rx.info()
        note("Sound: \(name) stopped listening after \(i.sinceSeconds) s"
            + (i.underruns + i.overruns > 0 ? " (\(i.underruns) underruns, \(i.overruns) overruns)" : ""))
    }

    /// Frames out, `FILL` lines in, until one end of it stops.
    private func stream(_ fd: Int32, _ rx: AudioReceiver, _ lines: AudioLines) {
        var pinged = Date.distantPast
        while true {
            guard let said = lines.said() else { return }        // the socket broke
            for line in said {
                let f = line.split(separator: " ", omittingEmptySubsequences: true)
                guard let word = f.first else { continue }
                if word == "FILL" && f.count >= 2 {
                    rx.said(fill: Int(f[1]) ?? 0,
                            under: f.count > 2 ? Int(f[2]) ?? 0 : 0,
                            over: f.count > 3 ? Int(f[3]) ?? 0 : 0)
                } else if word == "BYE" {
                    return
                }
            }
            // A machine that has said nothing for half a minute is gone,
            // whatever the socket still claims.
            let quiet = rx.quietFor
            if quiet > 30 { return }
            if quiet > 5 && Date().timeIntervalSince(pinged) > 5 {
                rx.queue(Self.frame(.ping))
                pinged = Date()
            }
            let work = rx.take(timeout: 0.5)
            for frame in work.control {
                guard sendAll(fd, frame) else { return }
            }
            if !work.audio.isEmpty {
                var d = Data([Kind.audio.rawValue, 0,
                              UInt8(work.audio.count >> 8), UInt8(work.audio.count & 0xff)])
                d.append(contentsOf: work.audio)
                guard sendAll(fd, d) else { return }
            }
        }
    }

    private func register() -> Int {
        lock.lock(); defer { lock.unlock() }
        let id = nextID
        nextID += 1
        return id
    }

    /// 4 bytes: type, flags, then a big-endian length.
    static func frame(_ t: Kind, _ payload: Data = Data()) -> Data {
        var d = Data([t.rawValue, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xff)])
        d.append(payload)
        return d
    }

    /// Blocking `send` -- that is what turns the old Mac's full buffer into
    /// backpressure on this one -- but against the socket's 5 s send
    /// timeout, so a machine that stops reading altogether is dropped
    /// rather than waited on for ever.
    private func sendAll(_ fd: Int32, _ d: Data) -> Bool {
        var sent = 0
        var stalls = 0
        while sent < d.count {
            let n = d.withUnsafeBytes { raw -> Int in
                send(fd, raw.baseAddress!.advanced(by: sent), d.count - sent, 0)
            }
            if n > 0 { sent += n; stalls = 0; continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return false }
            stalls += 1
            if stalls >= 2 { return false }                      // ten seconds of nothing
        }
        return true
    }

    private static func peerAddress(_ fd: Int32) -> String {
        var sa = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let ok = withUnsafeMutablePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getpeername(fd, $0, &len) }
        }
        guard ok == 0, sa.ss_family == sa_family_t(AF_INET) else { return "the network" }
        return withUnsafePointer(to: &sa) {
            $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                String(cString: inet_ntoa($0.pointee.sin_addr))
            }
        }
    }

    // MARK: - The tap

    /// Count one more listener, starting the tap if it is the first.
    /// Returns nil, or the ERROR line to answer with.
    private func beginCapture() -> String? {
        lock.lock()
        defer { lock.unlock() }
        if capture == nil, let refused = startTap() {
            return refused
        }
        captureUsers += 1
        return nil
    }

    private func endCapture() {
        lock.lock()
        captureUsers -= 1
        if captureUsers <= 0 {
            captureUsers = 0
            stopTap()
        }
        lock.unlock()
    }

    /// The source or the mute behaviour changed under a live tap: a tap
    /// cannot be edited, so it is made again.  The receivers stay where
    /// they are and flush, so the gap is a gap and not three seconds of
    /// what used to be playing.
    private func restartCapture() {
        lock.lock()
        if capture != nil {
            stopTap()
            // startTap has already said what went wrong, if anything did.
            _ = startTap()
        }
        lock.unlock()
        flush()
    }

    /// Builds the tap, the private aggregate device that carries it, and the
    /// thread that converts what they produce.  Called with `lock` held.
    /// Returns nil, or the ERROR line for whoever asked.
    private func startTap() -> String? {
        guard #available(macOS 14.2, *) else {
            return record("ERROR 503 audio capture needs macOS 14.2 or later")
        }
        guard let desc = tapDescription(settings) else {
            return record("ERROR 503 no audio source",
                          "nothing on this Mac is playing the music: open the player page in a browser")
        }

        var tap = AudioObjectID(kAudioObjectUnknown)
        let made = AudioHardwareCreateProcessTap(desc, &tap)
        guard made == noErr, tap != AudioObjectID(kAudioObjectUnknown) else {
            // TCC refuses a tap before anything else can go wrong with one,
            // so this is almost always the permission.  Either way there is
            // nothing to retry: it is a decision in System Settings.
            return record("ERROR 503 audio capture not allowed", detail: made)
        }
        guard let outputUID = Self.defaultOutputUID() else {
            AudioHardwareDestroyProcessTap(tap)
            return record("ERROR 503 no audio source")
        }
        // A private aggregate device is what an IOProc can be attached to.
        // It carries the tap, and the current default output is its main
        // sub-device purely so that the aggregate has a clock to run on --
        // nothing is played through it.
        let uid = "com.spartan0285.poweremu.audio-relay." + UUID().uuidString
        let dict: [String: Any] = [
            kAudioAggregateDeviceNameKey: "PowerEmu Audio Relay",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[String: Any]](),
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var device = AudioObjectID(kAudioObjectUnknown)
        let aggregated = AudioHardwareCreateAggregateDevice(dict as CFDictionary, &device)
        guard aggregated == noErr, device != AudioObjectID(kAudioObjectUnknown) else {
            AudioHardwareDestroyProcessTap(tap)
            return record("ERROR 503 no audio source", detail: aggregated)
        }
        guard let asbd = Self.tapFormat(tap), asbd.mSampleRate > 0,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0 else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return record("ERROR 503 this Mac's audio is in a format PowerEmu does not know")
        }

        // A second of room.  The pump empties this within a callback or two;
        // the size is there so a scheduling hiccup on this Mac costs nothing.
        let cap = AudioCapture(tap: tap, device: device, rate: asbd.mSampleRate,
                              ring: AudioCaptureRing(frames: Int(asbd.mSampleRate)))
        let ring = cap.ring
        var proc: AudioDeviceIOProcID?
        // The IOProc is the audio device's real-time thread: it interleaves
        // what the tap gave it into the ring and returns.  It never waits
        // for a receiver, a lock that anything slow holds, or the network.
        let started = AudioDeviceCreateIOProcIDWithBlock(&proc, device, nil) { _, input, _, _, _ in
            ring.write(input)
        }
        guard started == noErr, let proc else {
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return record("ERROR 503 no audio source", detail: started)
        }
        cap.proc = proc
        // From here the tap delivers whatever is playing, and nothing at all
        // when the Mac is making no sound: CoreAudio stops running the
        // aggregate rather than handing over silence.  That is the right way
        // round -- an old Mac that is sent nothing has nothing to play -- and
        // it is why the music's own pause has to arrive as a FLUSH rather
        // than as an absence of frames.
        let running = AudioDeviceStart(device, proc)
        guard running == noErr else {
            AudioDeviceDestroyIOProcID(device, proc)
            AudioHardwareDestroyAggregateDevice(device)
            AudioHardwareDestroyProcessTap(tap)
            return record("ERROR 503 no audio source", detail: running)
        }

        capture = cap
        trouble = nil
        troubleNoted = false
        let thread = Thread { [weak self] in self?.pump(cap) }
        thread.name = "PowerEmu audio relay"
        // Converting and sending is ordinary work, but it is work the whole
        // stream waits on, so it is asked for ahead of the interface.
        thread.qualityOfService = .userInitiated
        thread.start()
        note("Sound: listening to \(Self.describe(settings.source)) at \(Int(asbd.mSampleRate)) Hz")
        return nil
    }

    /// Called with `lock` held.
    private func stopTap() {
        guard let cap = capture else { return }
        capture = nil
        cap.stopping = true
        if let proc = cap.proc {
            AudioDeviceStop(cap.device, proc)
            AudioDeviceDestroyIOProcID(cap.device, proc)
        }
        AudioHardwareDestroyAggregateDevice(cap.device)
        if #available(macOS 14.2, *) { AudioHardwareDestroyProcessTap(cap.tap) }
    }

    /// Remember a refusal for the Service Hub, and say it in the log once.
    /// Called with `lock` held.
    private func record(_ line: String, _ explain: String? = nil, detail: OSStatus = noErr) -> String {
        trouble = explain ?? line.replacingOccurrences(of: "ERROR 503 ", with: "")
        if !troubleNoted {
            troubleNoted = true
            note("Sound: \(trouble!)" + (detail != noErr ? " (CoreAudio \(detail))" : ""))
        }
        return line
    }

    @available(macOS 14.2, *)
    private func tapDescription(_ s: Settings) -> CATapDescription? {
        let desc: CATapDescription
        switch s.source {
        case .player:
            let ids = Self.playerProcesses()
            desc = CATapDescription(stereoMixdownOfProcesses: ids)
            if #available(macOS 26.0, *) {
                // Name the browsers themselves as well as the ones running
                // now, so one opened later joins the tap on its own.
                desc.bundleIDs = Self.playerBundleIDs
            } else if ids.isEmpty {
                return nil
            }
        case .system:
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        case .device(let uid):
            desc = CATapDescription(__excludingProcesses: [], andDeviceUID: uid, withStream: 0)
        }
        desc.name = "PowerEmu Audio Relay"
        // Private, so it does not turn up in every other application's list
        // of devices.
        desc.isPrivate = true
        // Muted while it is being read is the right default: the Mac plays
        // normally until the relay is actually sending, and is silent while
        // it is, so you never hear this Mac and the old one three seconds
        // apart in the same room.
        desc.muteBehavior = s.muteHost ? .mutedWhenTapped : .unmuted
        return desc
    }

    /// The browsers that could be showing the player page -- and PowerEmu
    /// itself, for the day the player moves into a WKWebView of its own.
    private static let playerBundleIDs = ["com.apple.Safari", "com.google.Chrome", "org.mozilla.firefox",
                                          Bundle.main.bundleIdentifier ?? "com.spartan0285.poweremu"]

    private static func playerProcesses() -> [AudioObjectID] {
        var ids: [AudioObjectID] = []
        for bundle in playerBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundle) {
                if let id = processObject(app.processIdentifier), !ids.contains(id) { ids.append(id) }
            }
        }
        return ids
    }

    /// CoreAudio's own handle for a process, which is what a tap is built
    /// from.
    private static func processObject(_ pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var want = pid
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let ok = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                            UInt32(MemoryLayout<pid_t>.size), &want, &size, &object)
        guard ok == noErr, object != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return object
    }

    private static func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(tap, &address, 0, nil, &size, &asbd) == noErr else { return nil }
        return asbd
    }

    private static func defaultOutputUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &device) == noErr,
              device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceUID(device)
    }

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        text(device, kAudioDevicePropertyDeviceUID)
    }

    private static func deviceName(_ device: AudioObjectID) -> String? {
        text(device, kAudioObjectPropertyName)
    }

    /// A string property.  CoreAudio hands these over already retained, so
    /// the string is taken rather than borrowed.
    private static func text(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let ok = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard ok == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// The devices this Mac can play through, for the Source list.  The
    /// relay's own aggregate is left out: it is private, so this process is
    /// the only one that can see it at all, and tapping it would be a
    /// circle.
    static func outputDevices() -> [OutputDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                             &size) == noErr, size > 0 else { return [] }
        var devices = [AudioObjectID](repeating: AudioObjectID(kAudioObjectUnknown),
                                      count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                         &size, &devices) == noErr else { return [] }
        var out: [OutputDevice] = []
        for device in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioObjectPropertyScopeOutput,
                                                     mElement: kAudioObjectPropertyElementMain)
            var bytes: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &bytes) == noErr, bytes > 0,
                  let uid = deviceUID(device), let name = deviceName(device),
                  !uid.hasPrefix("com.spartan0285.poweremu.audio-relay.") else { continue }
            out.append(OutputDevice(uid: uid, name: name))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private static func describe(_ s: Source) -> String {
        switch s {
        case .player: return "the player page"
        case .system: return "everything this Mac plays"
        case .device(let uid):
            return "what goes to " + (outputDevices().first { $0.uid == uid }?.name ?? uid)
        }
    }

    // MARK: - Converting and handing out

    /// The thread between the tap and the receivers: it takes the tap's
    /// Float32 out of the ring, resamples it to each rate and byte order
    /// somebody asked for, and copies the result into every receiver.
    private func pump(_ cap: AudioCapture) {
        let maxFrames = 8192
        let staging = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
        defer { staging.deallocate() }
        var groups: [String: AudioGroup] = [:]
        while !cap.stopping {
            _ = cap.ring.wake.wait(timeout: .now() + 0.1)
            while !cap.stopping {
                let frames = cap.ring.read(into: staging, maxFrames: maxFrames)
                if frames == 0 { break }
                hand(staging, frames, cap.rate, &groups)
            }
        }
    }

    private func hand(_ frames: UnsafeMutablePointer<Float>, _ count: Int, _ tapRate: Double,
                      _ groups: inout [String: AudioGroup]) {
        lock.lock(); let listeners = clients; lock.unlock()
        guard !listeners.isEmpty else { return }
        for rx in listeners where groups[rx.group] == nil {
            guard let g = AudioGroup(rate: rx.rate, bigEndian: rx.bigEndian, tapRate: tapRate,
                                     maxInputFrames: 8192) else {
                note("Sound: this Mac cannot resample to \(rx.rate) Hz")
                continue
            }
            g.clock = rx.id
            groups[rx.group] = g
        }
        // A receiver that has gone takes its converter with it.
        let live = Set(listeners.map { $0.group })
        groups = groups.filter { live.contains($0.key) }

        for (key, g) in groups {
            let mine = listeners.filter { $0.group == key }
            drift(g, mine)
            guard let bytes = g.convert(frames, count) else { continue }
            for rx in mine { rx.push(bytes) }
        }
    }

    /// Drift.  The old Mac's crystal is not this Mac's, so over an hour the
    /// two rates differ by a few parts per million and its buffer slowly
    /// fills up or empties out.  The correction is a nudge to the
    /// resampler's idea of this Mac's rate -- at most 100 ppm, at most once
    /// every ten seconds -- because there is nothing to chase on this
    /// timescale and a fast correction is audible.  A ratio that walks
    /// steadily one way is a real crystal difference and is fine; one that
    /// oscillates is a bug in this loop.
    private func drift(_ g: AudioGroup, _ listeners: [AudioReceiver]) {
        guard Date().timeIntervalSince(g.changed) >= 10 else { return }
        // Two machines cannot both be the clock, so the one that has been
        // listening longest is the one whose buffer this follows.
        guard let rx = listeners.first(where: { $0.id == g.clock })
                ?? listeners.min(by: { $0.started < $1.started }) else { return }
        g.clock = rx.id
        let i = rx.info()
        guard i.fillMs > 0 else { return }                       // nothing reported yet
        let error = Double(i.fillMs - rx.bufferMs)
        guard abs(error) > 25 else { return }                    // close enough; leave it alone
        let was = (g.ppm * 10).rounded() / 10
        g.retune(max(-100, min(100, g.ppm - error * 0.5)))
        let now = (g.ppm * 10).rounded() / 10
        if now != was {
            note(String(format: "Sound: resampling %+.1f ppm for %@ (buffer %d ms, wanted %d)",
                        now, rx.name, i.fillMs, rx.bufferMs))
        }
    }
}

// MARK: - The tap's own objects

/// The CoreAudio side of a live tap, kept together so it can be taken down
/// in one go.
private final class AudioCapture: @unchecked Sendable {
    let tap: AudioObjectID
    let device: AudioObjectID
    let rate: Double
    let ring: AudioCaptureRing
    var proc: AudioDeviceIOProcID?
    /// Set when the tap is being destroyed, so the pump finishes.
    var stopping = false

    init(tap: AudioObjectID, device: AudioObjectID, rate: Double, ring: AudioCaptureRing) {
        self.tap = tap
        self.device = device
        self.rate = rate
        self.ring = ring
    }
}

/// Interleaved stereo Float32 as it comes off the tap: filled by the audio
/// device's real-time thread, emptied by the relay's pump.
///
/// One producer, one consumer, and the lock is held only long enough to read
/// or publish an index -- never across a copy, and never while anything that
/// could be slow is running -- so the real-time thread is never waiting on
/// this Mac's scheduler.  When it does fill up (which means the pump has
/// been starved for a whole second) the new audio is dropped rather than the
/// callback made to wait.
private final class AudioCaptureRing: @unchecked Sendable {
    private struct Indices: Sendable {
        var read = 0
        var used = 0
        var dropped = 0
    }

    private let frames: Int
    private let buffer: UnsafeMutablePointer<Float>
    /// Where a tap that hands over separate mono buffers is interleaved.
    private let scratch: UnsafeMutablePointer<Float>
    private let scratchFrames = 4096
    private let indices = OSAllocatedUnfairLock(initialState: Indices())
    let wake = DispatchSemaphore(value: 0)

    init(frames: Int) {
        self.frames = max(4096, frames)
        buffer = UnsafeMutablePointer<Float>.allocate(capacity: self.frames * 2)
        scratch = UnsafeMutablePointer<Float>.allocate(capacity: scratchFrames * 2)
    }

    deinit {
        buffer.deallocate()
        scratch.deallocate()
    }

    /// From the IOProc.
    func write(_ list: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        guard buffers.count > 0, let first = buffers[0].mData else { return }
        let channels = Int(buffers[0].mNumberChannels)
        let have = Int(buffers[0].mDataByteSize) / (4 * max(1, channels))
        guard have > 0 else { return }
        if channels == 2 {
            append(first.assumingMemoryBound(to: Float.self), have)
            return
        }
        // Mono, or a channel per buffer: interleave the first two into a
        // stereo pair, duplicating a single channel.  A few hundred
        // multiply-free copies on an Apple Silicon Mac is nothing.
        let left = first.assumingMemoryBound(to: Float.self)
        let right = buffers.count > 1 ? buffers[1].mData?.assumingMemoryBound(to: Float.self) : nil
        var done = 0
        while done < have {
            let run = min(scratchFrames, have - done)
            for i in 0..<run {
                scratch[i * 2] = left[done + i]
                scratch[i * 2 + 1] = (right ?? left)[done + i]
            }
            append(scratch, run)
            done += run
        }
    }

    private func append(_ src: UnsafePointer<Float>, _ count: Int) {
        let state = indices.withLock { $0 }
        let free = frames - state.used
        guard free > 0 else {
            indices.withLock { $0.dropped += count }
            return
        }
        let take = min(count, free)
        var at = (state.read + state.used) % frames
        var left = take
        var from = 0
        while left > 0 {
            let run = min(left, frames - at)
            buffer.advanced(by: at * 2).update(from: src.advanced(by: from * 2), count: run * 2)
            at = (at + run) % frames
            from += run
            left -= run
        }
        indices.withLock { $0.used += take; if take < count { $0.dropped += count - take } }
        wake.signal()
    }

    /// From the pump: how many stereo frames it got.
    func read(into dst: UnsafeMutablePointer<Float>, maxFrames: Int) -> Int {
        let state = indices.withLock { $0 }
        let take = min(maxFrames, state.used)
        guard take > 0 else { return 0 }
        var at = state.read
        var done = 0
        while done < take {
            let run = min(take - done, frames - at)
            dst.advanced(by: done * 2).update(from: buffer.advanced(by: at * 2), count: run * 2)
            at = (at + run) % frames
            done += run
        }
        let next = at
        indices.withLock { $0.read = next; $0.used -= take }
        return take
    }

    /// Frames the IOProc had to throw away because the pump was not there
    /// to take them.
    var dropped: Int { indices.withLock { $0.dropped } }
}

// MARK: - One rate and byte order

/// One AVAudioConverter for each (rate, byte order) somebody asked for --
/// realistically one, because every old Mac here wants 44 100.
///
/// The drift nudge lives here too, and it is the only thing done to the
/// audio: the converter is told this Mac's rate is a few parts per million
/// away from what it really is, so it produces slightly more or slightly
/// fewer samples per second.  That is what a resampler is for.  No biquads,
/// no sample stuffing, none of what AirPlay forces on to the receiver.
private final class AudioGroup {
    let rate: Int
    let bigEndian: Bool
    let tapRate: Double
    private let maxInputFrames: Int
    /// Parts per million, positive when this Mac sends faster than the tap's
    /// own rate to fill a receiver that is running dry.
    private(set) var ppm = 0.0
    private(set) var changed = Date.distantPast
    /// Whose buffer this follows.
    var clock = 0

    private var converter: AVAudioConverter
    private var input: AVAudioPCMBuffer
    private let output: AVAudioPCMBuffer

    init?(rate: Int, bigEndian: Bool, tapRate: Double, maxInputFrames: Int) {
        self.rate = rate
        self.bigEndian = bigEndian
        self.tapRate = tapRate
        self.maxInputFrames = maxInputFrames
        guard let outFormat = Self.outFormat(rate: Double(rate), bigEndian: bigEndian),
              let inFormat = Self.inFormat(tapRate),
              let c = AVAudioConverter(from: inFormat, to: outFormat),
              let i = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(maxInputFrames)),
              // Room for everything the input can turn into, and then some,
              // so the converter always takes the whole input and nothing is
              // left inside it to arrive late.
              let o = AVAudioPCMBuffer(pcmFormat: outFormat,
                                       frameCapacity: AVAudioFrameCount(Double(maxInputFrames)
                                                                        * Double(rate) / tapRate + 4096))
        else { return nil }
        converter = c
        input = i
        output = o
    }

    private static func inFormat(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 2, interleaved: true)
    }

    private static func outFormat(rate: Double, bigEndian: Bool) -> AVAudioFormat? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked
                | (bigEndian ? kAudioFormatFlagIsBigEndian : 0),
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4,
            mChannelsPerFrame: 2, mBitsPerChannel: 16, mReserved: 0)
        return AVAudioFormat(streamDescription: &asbd)
    }

    /// Change the ratio, by making the converter again against a slightly
    /// different input rate.  There is no way to retune one in place, and
    /// none is needed: this happens at most once every ten seconds, and the
    /// resampler starting its filter again costs a sample or two of
    /// settling, which at these intervals is not something anybody hears.
    func retune(_ to: Double) {
        changed = Date()
        guard abs(to - ppm) >= 0.05 else { return }
        guard let inFormat = Self.inFormat(tapRate * (1 - to / 1_000_000)),
              let c = AVAudioConverter(from: inFormat, to: output.format),
              let i = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: AVAudioFrameCount(maxInputFrames))
        else { return }
        ppm = to
        converter = c
        input = i
    }

    /// The tap's frames in, the receiver's bytes out: a view of the
    /// converter's own output buffer, good until the next call.
    func convert(_ src: UnsafePointer<Float>, _ frames: Int) -> UnsafeRawBufferPointer? {
        guard frames > 0, frames <= Int(input.frameCapacity) else { return nil }
        input.frameLength = AVAudioFrameCount(frames)
        guard let into = input.audioBufferList.pointee.mBuffers.mData else { return nil }
        into.copyMemory(from: src, byteCount: frames * 8)
        var fed = false
        var problem: NSError?
        let status = converter.convert(to: output, error: &problem) { [input] _, request in
            if fed { request.pointee = .noDataNow; return nil }
            fed = true
            request.pointee = .haveData
            return input
        }
        guard status == .haveData || status == .inputRanDry else { return nil }
        let made = output.audioBufferList.pointee.mBuffers
        guard let base = made.mData, made.mDataByteSize > 0 else { return nil }
        return UnsafeRawBufferPointer(start: base, count: Int(made.mDataByteSize))
    }
}

// MARK: - One receiver

/// One old Mac listening.  Its own thread drains this with blocking
/// `send()`; the pump fills it and throws the oldest audio away rather than
/// wait, because the tap and the other receivers must never be held up by
/// the slowest machine on the network.
final class AudioReceiver: @unchecked Sendable {
    let id: Int
    let name: String
    let address: String
    let rate: Int
    let bigEndian: Bool
    let bufferMs: Int
    let started = Date()

    /// Which converter's output this takes.
    var group: String { "\(rate)/\(bigEndian ? "be" : "le")" }
    var format: String { bigEndian ? "s16be" : "s16le" }

    private let cond = NSCondition()
    private var ring: [UInt8]
    private var start = 0
    private var used = 0
    private var control: [Data] = []
    private var fillMs = 0
    private var underruns = 0
    private var overruns = 0
    private var heard = Date()

    init(id: Int, name: String, address: String, rate: Int, bigEndian: Bool, bufferMs: Int) {
        self.id = id
        self.name = name
        self.address = address
        self.rate = rate
        self.bigEndian = bigEndian
        self.bufferMs = bufferMs
        // Twice what the old Mac means to hold, so this Mac can be ahead of
        // it without throwing anything away the first time the network
        // hesitates.
        ring = [UInt8](repeating: 0, count: bufferMs * 2 * rate * 4 / 1000)
    }

    func info() -> AudioRelay.ReceiverInfo {
        cond.lock()
        defer { cond.unlock() }
        return .init(id: id, name: name, address: address,
                     sinceSeconds: Int(Date().timeIntervalSince(started)),
                     fillMs: fillMs, underruns: underruns, overruns: overruns,
                     format: format, rate: rate)
    }

    /// How long since the old Mac last said anything.
    var quietFor: TimeInterval { cond.lock(); defer { cond.unlock() }; return Date().timeIntervalSince(heard) }

    /// A `FILL` line.
    func said(fill: Int, under: Int, over: Int) {
        cond.lock()
        heard = Date()
        fillMs = fill
        underruns = under
        if over > overruns { overruns = over }
        cond.unlock()
    }

    /// Converted bytes from the pump.  When the ring is full the oldest
    /// audio goes -- never the newest, and never the pump's thread.
    func push(_ bytes: UnsafeRawBufferPointer) {
        guard !bytes.isEmpty, let from = bytes.baseAddress else { return }
        cond.lock()
        defer { cond.unlock() }
        var count = bytes.count
        var skip = 0
        if count > ring.count {                                  // a whole ring at once: keep the end
            skip = count - ring.count
            count = ring.count
        }
        if count > ring.count - used {
            let drop = count - (ring.count - used)
            start = (start + drop) % ring.count
            used -= drop
            overruns += (drop + AudioRelay.chunk - 1) / AudioRelay.chunk
        }
        var at = (start + used) % ring.count
        ring.withUnsafeMutableBytes { into in
            var left = count
            var done = skip
            while left > 0 {
                let run = min(left, into.count - at)
                into.baseAddress!.advanced(by: at).copyMemory(from: from.advanced(by: done), byteCount: run)
                at = (at + run) % into.count
                done += run
                left -= run
            }
        }
        used += count
        cond.signal()
    }

    /// Drop everything in flight and tell the old Mac to go silent now.
    func flush() {
        cond.lock()
        start = 0
        used = 0
        control.append(AudioRelay.frame(.flush))
        cond.signal()
        cond.unlock()
    }

    func queue(_ frame: Data) {
        cond.lock()
        control.append(frame)
        cond.signal()
        cond.unlock()
    }

    /// The next thing to send: the control frames, then one AUDIO payload.
    ///
    /// A whole chunk is worth the wait.  The tap hands over about half of
    /// one every ten milliseconds, so filling a frame costs a few more, and
    /// sending them full is both what the protocol promises and a third as
    /// many writes.  A control frame, or the timeout, sends what there is.
    func take(timeout: TimeInterval) -> (control: [Data], audio: [UInt8]) {
        cond.lock()
        defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while control.isEmpty && used < AudioRelay.chunk {
            if !cond.wait(until: deadline) { break }
        }
        if control.isEmpty && used == 0 { return ([], []) }
        let frames = control
        control = []
        var audio: [UInt8] = []
        if used > 0 {
            let count = min(used, AudioRelay.chunk)
            audio = [UInt8](repeating: 0, count: count)
            audio.withUnsafeMutableBytes { into in
                ring.withUnsafeBytes { from in
                    var left = count
                    var at = start
                    var done = 0
                    while left > 0 {
                        let run = min(left, from.count - at)
                        into.baseAddress!.advanced(by: done)
                            .copyMemory(from: from.baseAddress!.advanced(by: at), byteCount: run)
                        at = (at + run) % from.count
                        done += run
                        left -= run
                    }
                }
            }
            start = (start + count) % ring.count
            used -= count
        }
        return (frames, audio)
    }
}

// MARK: - The text half of the protocol

/// The handshake and the old Mac's `FILL` lines, read off a blocking socket
/// a line at a time -- the same shape as `HTTPConnection`'s reader in
/// WebDAVServer.swift, which this protocol's text half deliberately
/// resembles.
private final class AudioLines {
    private let fd: Int32
    private var buffer: [UInt8] = []
    /// The old Mac has said everything it is going to.
    private var done = false

    init(fd: Int32) { self.fd = fd }

    /// The HELLO block: the first line, then `key: value` until a blank one.
    /// nil if the socket closed or the deadline passed first.
    func headers(max: Int = 32) -> (first: String, fields: [String: String])? {
        guard let first = line() else { return nil }
        var fields: [String: String] = [:]
        for _ in 0..<max {
            guard let l = line() else { return nil }
            if l.isEmpty { return (first, fields) }
            guard let colon = l.firstIndex(of: ":") else { continue }   // unknown lines are ignored
            fields[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return (first, fields)
    }

    private func line() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {
                let text = String(decoding: buffer[..<i], as: UTF8.self)
                buffer.removeFirst(i + 1)
                return text.hasSuffix("\r") ? String(text.dropLast()) : text
            }
            if buffer.count > 4096 { return nil }
            var chunk = [UInt8](repeating: 0, count: 1024)
            let n = read(fd, &chunk, chunk.count)
            if n <= 0 { return nil }
            buffer.append(contentsOf: chunk[0..<n])
        }
    }

    /// Whatever the old Mac has said since last time, without waiting for
    /// it: the frames have to keep going out between one `FILL` and the
    /// next.  nil when the socket itself has broken.
    ///
    /// An end to what it is saying is not an end to the connection.  A
    /// client that has closed only its reading half -- which is what the
    /// `printf | nc` test in the build instruction produces -- has simply
    /// stopped talking, and keeps its audio until the thirty-second silence
    /// rule or a failed write ends it.
    func said() -> [String]? {
        var chunk = [UInt8](repeating: 0, count: 1024)
        while !done {
            let n = recv(fd, &chunk, chunk.count, MSG_DONTWAIT)
            if n > 0 { buffer.append(contentsOf: chunk[0..<n]); continue }
            if n == 0 { done = true; break }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return nil }
            break
        }
        var out: [String] = []
        while let i = buffer.firstIndex(of: 0x0a) {
            let text = String(decoding: buffer[..<i], as: UTF8.self)
            buffer.removeFirst(i + 1)
            out.append(text.hasSuffix("\r") ? String(text.dropLast()) : text)
        }
        if buffer.count > 4096 { buffer.removeAll() }            // not lines: forget it
        return out
    }
}
