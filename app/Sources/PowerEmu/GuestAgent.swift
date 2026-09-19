import Foundation
import AppKit

/// The host end of PowerEmu Tools.
///
/// Inside the guest, PowerEmu Agent connects to 10.0.2.100:7700; QEMU's
/// user-mode network hands each such connection to `nc -U` on this Unix
/// socket (a guestfwd rule, see VMRunner).  Messages both ways are a header
/// line "VERB LENGTH\n" and LENGTH bytes of payload - see guest/src/PEAgent.m.
@MainActor
final class GuestAgent: ObservableObject {
    /// Set once the agent has said hello: (agent version, Mac OS X version, user).
    @Published private(set) var info: (version: String, system: String, user: String)?
    var connected: Bool { info != nil }

    let socketPath: String
    var shareClipboard = true
    /// Called when the agent says hello (after every guest login).
    var onConnect: (() -> Void)?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conn: Connection?
    private var clipTimer: Timer?
    private var lastChangeCount = NSPasteboard.general.changeCount
    private var lastClip: String?

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: listening

    func start() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.acceptOne() }
        }
        src.resume()
        acceptSource = src
    }

    func stop() {
        conn?.close()
        conn = nil
        info = nil
        clipTimer?.invalidate()
        clipTimer = nil
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptOne() {
        let fd = accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        // A new agent connection replaces the old one (the guest restarted
        // the agent, or logged in again).
        conn?.close()
        info = nil
        conn = Connection(fd: fd,
                          onMessage: { [weak self] verb, payload in
                              MainActor.assumeIsolated { self?.handle(verb, payload) }
                          },
                          onClose: { [weak self, fd] in
                              MainActor.assumeIsolated {
                                  guard let self, self.conn?.fd == fd else { return }
                                  self.conn = nil
                                  self.info = nil
                              }
                          })
        send("HELLO", "PowerEmu 1")
    }

    // MARK: messages

    func send(_ verb: String, _ text: String) { send(verb, Data(text.utf8)) }

    func send(_ verb: String, _ payload: Data = Data()) {
        conn?.send(verb, payload)
    }

    private func handle(_ verb: String, _ payload: Data) {
        let text = String(decoding: payload, as: UTF8.self)
        switch verb {
        case "HELLO":
            let f = text.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            info = (f.first ?? "?", f.count > 1 ? f[1] : "?", f.count > 2 ? f[2] : "?")
            startClipboard()
            onConnect?()
        case "CLIP":
            guard shareClipboard else { return }
            lastClip = text
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(text, forType: .string)
            lastChangeCount = pb.changeCount
        case "LOG":
            NSLog("PowerEmu Agent: %@", text)
        default:
            break
        }
    }

    // MARK: clipboard

    private func startClipboard() {
        clipTimer?.invalidate()
        lastChangeCount = NSPasteboard.general.changeCount
        clipTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPasteboard() }
        }
    }

    /// Copying on this Mac puts the text on the guest's clipboard too.
    private func checkPasteboard() {
        let pb = NSPasteboard.general
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard shareClipboard, connected, let s = pb.string(forType: .string), s != lastClip else { return }
        lastClip = s
        send("CLIP", s)
    }
}

/// One agent connection: reads frames on a background queue, writes
/// synchronously (messages are small).
private final class Connection: @unchecked Sendable {
    let fd: Int32
    private let source: DispatchSourceRead
    private var inbox = Data()
    private let lock = NSLock()
    private var closed = false

    init(fd: Int32, onMessage: @escaping @Sendable (String, Data) -> Void, onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "poweremu.agent"))
        source.setEventHandler { [unowned self] in
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = read(fd, &buf, buf.count)
            if n <= 0 {
                self.close()
                DispatchQueue.main.async { onClose() }
                return
            }
            self.inbox.append(contentsOf: buf[0..<n])
            for (verb, payload) in self.frames() {
                DispatchQueue.main.async { onMessage(verb, payload) }
            }
        }
        source.resume()
    }

    /// Complete frames in the inbox, removed from it.
    private func frames() -> [(String, Data)] {
        var out: [(String, Data)] = []
        while let nl = inbox.firstIndex(of: 0x0a) {
            let head = String(decoding: inbox[inbox.startIndex..<nl], as: UTF8.self).split(separator: " ")
            let size = head.count > 1 ? Int(head[1]) ?? 0 : 0
            let start = inbox.index(after: nl)
            guard inbox.distance(from: start, to: inbox.endIndex) >= size else { break }
            let end = inbox.index(start, offsetBy: size)
            out.append((head.first.map(String.init) ?? "", Data(inbox[start..<end])))
            inbox = Data(inbox[end...])
        }
        return out
    }

    func send(_ verb: String, _ payload: Data) {
        var d = Data("\(verb) \(payload.count)\n".utf8)
        d.append(payload)
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        d.withUnsafeBytes { raw in
            var p = raw.baseAddress!
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                p += n; left -= n
            }
        }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        closed = true
        source.cancel()
        Darwin.close(fd)
    }
}
