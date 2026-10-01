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
    /// Harmony: the guest's on-screen windows -- id and rectangle (guest
    /// points, top-left), front-most first -- or empty when Harmony is off.
    var onWindows: (([(id: Int, rect: CGRect, visible: CGRect)]) -> Void)?
    /// Harmony: which application each guest window belongs to.
    var onWindowApps: (([(id: Int, pid: Int, app: String)]) -> Void)?
    /// What is in the guest's own Dock: where each application lives, what the
    /// Dock calls it, and its pid when it happens to be running.
    var onDockApps: (([(path: String, name: String, pid: Int)]) -> Void)?
    /// Harmony: the guest's windows that have been put in its Dock.
    var onMinimized: (([(pid: Int, index: Int, title: String)]) -> Void)?
    /// One of the guest's applications' icons, as a PNG.
    var onAppIcon: ((Int, Data) -> Void)?
    var onWindowFrame: ((Data) -> Void)?
    var onFocusReady: ((Int, Int, Bool) -> Void)?
    var onFileTransfer: (([String: Any]) -> Void)?
    var onDisconnect: (() -> Void)?
    var onSheets: (([Int: Int]) -> Void)?
    var onDragWindows: ((Set<Int>) -> Void)?
    var onMenuFocus: ((String, Int) -> Void)?
    var onGuestFullscreen: (() -> Void)?
    var onHarmonyReady: ((String, CGSize, Bool) -> Void)?
    /// Per window, the rectangles of it that something else is drawn over.
    var onOcclusion: (([Int: [CGRect]]) -> Void)?
    /// The guest window that has the focus: the one nothing is drawn over.
    var onFocused: ((Int) -> Void)?
    /// The front guest application and the titles across its menu bar.
    var onMenuBar: ((Int, String, [(index: Int, title: String)]) -> Void)?
    /// Everything in one of those menus, once it has been asked for.
    var onMenuItems: ((Int, String, [HarmonyMenuItem]) -> Void)?
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conn: Connection?
    private var frameConnection: Connection?
    private var frameSession = UUID().uuidString
    private var incoming: [Int32: Connection] = [:]
    private var connectionEpochs: [Int32: UUID] = [:]
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
        info = nil
        onDisconnect?()
        for connection in incoming.values { connection.close() }
        incoming.removeAll(); connectionEpochs.removeAll()
        frameConnection?.close(); frameConnection = nil
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
        // A frame uses a separate short-lived connection to the same guestfwd
        // endpoint. Classify the first message before replacing the control link.
        guard incoming.count < 16 else { close(fd); return }
        let epoch = UUID()
        connectionEpochs[fd] = epoch
        incoming[fd] = Connection(fd: fd,
            onMessage: { [weak self] verb, payload in
                MainActor.assumeIsolated {
                    guard self?.connectionEpochs[fd] == epoch else { return }
                    self?.receive(fd: fd, verb: verb, payload: payload)
                }
            }, onClose: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.connectionEpochs[fd] == epoch else { return }
                    self.connectionEpochs.removeValue(forKey: fd)
                    self.incoming.removeValue(forKey: fd)
                    if self.conn?.fd == fd { self.conn = nil; self.info = nil; self.onDisconnect?(); self.frameConnection?.close(); self.frameConnection = nil }
                    if self.frameConnection?.fd == fd { self.frameConnection = nil }
                }
            })
        let accepted = incoming[fd]
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self, weak accepted] in
            guard let self, let accepted, self.incoming[fd] === accepted else { return }
            self.incoming.removeValue(forKey: fd)?.close()
        }
    }

    private func receive(fd: Int32, verb: String, payload: Data) {
        if conn?.fd == fd { handle(verb, payload); return }
        if frameConnection?.fd == fd {
            if verb == "WINDOWFRAME" { onWindowFrame?(payload) }
            return
        }
        guard let candidate = incoming.removeValue(forKey: fd) else { return }
        if verb == "FRAMEHELLO", connected, String(decoding: payload, as: UTF8.self) == frameSession {
            frameConnection?.close()
            frameConnection = candidate
        } else if verb == "HELLO" {
            if conn != nil { info = nil; onDisconnect?() }
            frameConnection?.close(); frameConnection = nil
            conn?.close()
            conn = candidate
            info = nil
            frameSession = UUID().uuidString
            send("HELLO", "PowerEmu 1 " + frameSession)
            handle(verb, payload)
        } else { connectionEpochs.removeValue(forKey: fd); candidate.close() }
    }

    // MARK: messages

    func send(_ verb: String, _ text: String) { send(verb, Data(text.utf8)) }

    func send(_ verb: String, _ payload: Data = Data()) {
        conn?.send(verb, payload)
    }

    private func handle(_ verb: String, _ payload: Data) {
        if verb == "WINDOWFRAME" { onWindowFrame?(payload); return }
        let text = String(decoding: payload, as: UTF8.self)
        switch verb {
        case "DRAGWINDOWS":
            onDragWindows?(Set(text.split(separator: ";").compactMap { Int($0) }.filter { $0 > 0 }))
        case "SHEETS":
            var parents: [Int: Int] = [:]
            for row in text.split(separator: ";") {
                let ids = row.split(separator: ",").compactMap { Int($0) }
                if ids.count == 2, ids[0] > 0, ids[1] > 0, ids[0] != ids[1] { parents[ids[0]] = ids[1] }
            }
            onSheets?(parents)
        case "FILERESULT":
            if let fields = (try? PropertyListSerialization.propertyList(from: payload, options: [], format: nil)) as? [String: Any] { onFileTransfer?(fields) }
        case "FOCUSREADY":
            let f = text.split(separator: " ").compactMap { Int($0) }
            if f.count == 3 { onFocusReady?(f[0], f[1], f[2] == 1) }
        case "HARMONYREADY":
            let f = text.split(separator: " ").map(String.init)
            if f.count == 4, let w = Int(f[1]), let h = Int(f[2]) {
                onHarmonyReady?(f[0], CGSize(width: w, height: h), f[3] == "1")
            }
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
            harmonyDebug("PEAGENT " + text)
        case "FULLSCREEN":
            if text == "captured" { onGuestFullscreen?() }
        case "WINDOWS":
            var windows: [(id: Int, rect: CGRect, visible: CGRect)] = []
            for part in text.split(separator: ";") {
                let n = part.split(separator: ",").compactMap { Double($0) }
                guard n.count >= 5 else { continue }
                let frame = CGRect(x: n[1], y: n[2], width: n[3], height: n[4])
                // Older tools do not send the visible part; assume all of it.
                let vis = n.count >= 9 ? CGRect(x: n[5], y: n[6], width: n[7], height: n[8]) : frame
                windows.append((id: Int(n[0]), rect: frame, visible: vis))
            }
            onWindows?(windows)
        case "WINAPPS":
            var apps: [(id: Int, pid: Int, app: String)] = []
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 2, let pid = Int(f[0]) {
                    let ids = f.count > 2 ? f[2].split(separator: ",").compactMap { Int($0) } : []
                    for id in ids.isEmpty ? [0] : ids { apps.append((id: id, pid: pid, app: f[1])) }
                }
            }
            onWindowApps?(apps)
        case "DOCKAPPS":
            var items: [(path: String, name: String, pid: Int)] = []
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 3, !f[0].isEmpty else { continue }
                items.append((path: f[0], name: f[1], pid: Int(f[2]) ?? 0))
            }
            onDockApps?(items)
        case "MINWINDOWS":
            var mins: [(pid: Int, index: Int, title: String)] = []
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 3, let pid = Int(f[0]), let idx = Int(f[1]) {
                    mins.append((pid: pid, index: idx, title: f[2]))
                }
            }
            onMinimized?(mins)
        case "APPICON":
            // "<pid>\n" and then the PNG itself.
            guard let nl = payload.firstIndex(of: 0x0A) else { return }
            let head = String(decoding: payload[..<nl], as: UTF8.self)
            guard let pid = Int(head.trimmingCharacters(in: .whitespaces)) else { return }
            onAppIcon?(pid, Data(payload[payload.index(after: nl)...]))
        case "OCCLUDE":
            var out: [Int: [CGRect]] = [:]
            for line in text.split(separator: "\n") {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 2, let id = Int(f[0]) else { continue }
                out[id] = f[1].split(separator: "|").compactMap { part -> CGRect? in
                    let n = part.split(separator: ",").compactMap { Double($0) }
                    guard n.count == 4 else { return nil }
                    return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
                }
            }
            onOcclusion?(out)
        case "MENUFOCUS":
            let fields = text.split(separator: " ")
            if fields.count == 2, let id = Int(fields[1]), id > 0 { onMenuFocus?(String(fields[0]), id) }
        case "FOCUSED":
            onFocused?(Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0)
        case "MENUS":
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            // Empty means the guest has no menus to show: Harmony is off.
            guard let head = lines.first, !head.isEmpty else { onMenuBar?(0, "", []); return }
            let hf = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard let pid = Int(hf.first ?? "") else { return }
            lines.removeFirst()
            var tops: [(index: Int, title: String)] = []
            for line in lines where !line.isEmpty {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                if f.count >= 2, let i = Int(f[0]) { tops.append((index: i, title: f[1])) }
            }
            onMenuBar?(pid, hf.count > 1 ? hf[1] : "", tops)
        case "MENUITEMS":
            var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
            guard let head = lines.first, !head.isEmpty else { return }
            let hf = head.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard hf.count >= 2, let pid = Int(hf[0]) else { return }
            lines.removeFirst()
            var items: [HarmonyMenuItem] = []
            for line in lines where !line.isEmpty {
                let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
                guard f.count >= 7 else { continue }
                items.append(HarmonyMenuItem(path: f[0], title: f[1], enabled: f[2] != "0",
                                             key: f[3], modifiers: Int(f[4]) ?? 0,
                                             mark: f[5], hasSubmenu: f[6] != "0"))
            }
            onMenuItems?(pid, hf[1], items)
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
        source.setCancelHandler { Darwin.close(fd) }
        source.setEventHandler { [weak self] in
            guard let self else { return }
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
            guard head.count == 2, let size = Int(head[1]), (0...70_000_000).contains(size) else {
                close(); inbox.removeAll(); return []
            }
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
    }
}
