import AppKit
import Darwin

private func readLine(_ fd: Int32) throws -> String? {
    var line = [UInt8]()
    while line.count < 160 {
        var byte: UInt8 = 0
        let n = Darwin.read(fd, &byte, 1)
        if n < 0 && errno == EINTR { continue }
        if n == 0 && line.isEmpty { return nil }
        guard n == 1 else { throw NSError(domain: "publish.read", code: Int(errno)) }
        if byte == 10 { return String(decoding: line, as: UTF8.self) }
        line.append(byte)
    }
    throw NSError(domain: "publish.header", code: 1)
}
private func readData(_ fd: Int32, size: Int) throws -> Data {
    var bytes = Data(count: size)
    try bytes.withUnsafeMutableBytes { buffer in
        var received = 0
        while received < size {
            let n = Darwin.read(fd, buffer.baseAddress! + received, size - received)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw NSError(domain: "publish.payload", code: Int(errno)) }
            received += n
        }
    }
    return bytes
}
private func writeAck(_ fd: Int32, sequence: Int) -> Bool {
    let data = Data("ACK \(sequence)\n".utf8)
    return data.withUnsafeBytes { bytes in
        var sent = 0
        while sent < bytes.count {
            let n = Darwin.write(fd, bytes.baseAddress! + sent, bytes.count - sent)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { return false }
            sent += n
        }
        return true
    }
}
private func validate(_ frame: HarmonyWindowFrame) -> Bool {
    guard frame.id == 1, (1...240).contains(frame.sequence),
          frame.image.width == (frame.sequence <= 160 ? 615 : 512),
          frame.image.height == (frame.sequence <= 160 ? 407 : 320),
          let bytes = frame.image.dataProvider?.data else { return false }
    let w = frame.image.width, h = frame.image.height, seq = frame.sequence
    guard CFDataGetLength(bytes) == w * h * 4, let p = CFDataGetBytePtr(bytes) else { return false }
    for y in 0..<h { for x in 0..<w {
        let at = (y * w + x) * 4
        if p[at] != UInt8(((x / 32 + seq) & 1) * 255) ||
            p[at+1] != UInt8(((y / 32 + seq / 2) & 1) * 255) ||
            p[at+2] != UInt8(((x / 64 + y / 64 + seq / 3) & 1) * 255) || p[at+3] != 255 { return false }
    } }
    return true
}
@MainActor final class Host: NSObject, NSApplicationDelegate {
    let output: URL
    let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    var window: NSWindow!
    var layer: CALayer!
    var listener: Int32 = -1
    var published = 0
    var rows = [[String: Any]]()
    var finished = false
    init(output: URL) { self.output = output }
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        window = NSWindow(contentRect: NSRect(x: 120, y: 180, width: 615, height: 407),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "Harmony direct publication prototype — test pattern only"
        let view = NSView(); view.wantsLayer = true; window.contentView = view
        layer = view.layer!; layer.contentsGravity = .resize; layer.magnificationFilter = .nearest
        window.orderFront(nil)
        do {
            listener = socket(AF_INET, SOCK_STREAM, 0)
            guard listener >= 0 else { throw NSError(domain: "listen", code: Int(errno)) }
            var address = sockaddr_in(); address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET); address.sin_addr.s_addr = inet_addr("127.0.0.1")
            let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
            guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw NSError(domain: "listen", code: Int(errno)) }
            var size = socklen_t(MemoryLayout<sockaddr_in>.size)
            withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { _ = getsockname(listener, $0, &size) } }
            try "\(UInt16(bigEndian: address.sin_port)) \(nonce)".write(to: output.appendingPathExtension("config"), atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.appendingPathExtension("config").path)
            let fd = listener, expected = nonce
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                let client = accept(fd, nil, nil)
                guard client >= 0 else { return }
                defer { Darwin.close(client) }
                var timeout = timeval(tv_sec: 15, tv_usec: 0); var one: Int32 = 1
                setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var previous = 0; var failure: String?
                var priorPixels: Data?
                do {
                    guard try readLine(client) == "PUBLISHHELLO \(expected)" else { throw NSError(domain: "identity", code: 1) }
                    while let head = try readLine(client) {
                        let fields = head.split(separator: " ")
                        guard fields.count == 2, fields[0] == "FRAME", let n = Int(fields[1]), (1...4_000_000).contains(n) else { throw NSError(domain: "frame.header", code: 1) }
                        let received = ProcessInfo.processInfo.systemUptime
                        let payload = try readData(client, size: n)
                        guard let frame = HarmonyWindowFrame.decode(payload), frame.sequence > previous, validate(frame) else { throw NSError(domain: "frame.content", code: 1) }
                        previous = frame.sequence
                        let currentPixels = frame.image.dataProvider!.data! as Data
                        let pixelChanged = priorPixels != currentPixels
                        priorPixels = currentPixels
                        let ready = ProcessInfo.processInfo.systemUptime
                        var acked = false
                        DispatchQueue.main.sync {
                            guard let self, !self.finished else { return }
                            CATransaction.begin(); CATransaction.setDisableActions(true)
                            self.window.setContentSize(NSSize(width: frame.image.width, height: frame.image.height))
                            self.layer.contents = frame.image; CATransaction.commit(); CATransaction.flush()
                            let published = ProcessInfo.processInfo.systemUptime
                            self.published += 1
                            if self.rows.count < 240 { self.rows.append(["sequence":frame.sequence,"received":received,"transferDecodeVerifyMS":(ready-received)*1000,"publishMS":(published-ready)*1000,"published":published,"bytes":n,"pixelChanged":pixelChanged]) }
                            acked = writeAck(client, sequence: frame.sequence)
                        }
                        guard acked else { throw NSError(domain: "ack", code: 1) }
                    }
                    guard previous == 240 else { throw NSError(domain: "frame.incomplete", code: 1) }
                } catch { failure = String(describing: error) }
                let result = failure
                DispatchQueue.main.async { self?.finish(error: result) }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in self?.finish(error: "deadline") }
        } catch { finish(error: String(describing: error)) }
    }
    func finish(error: String?) {
        guard !finished else { return }; finished = true
        let result: [String: Any] = ["published":published,"error":error ?? NSNull(),"rows":rows,
            "scope":"Cooperative source, byte-verified layer publication; not proof of scanout or Finder export"]
        do { try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted,.sortedKeys]).write(to: output) }
        catch { fputs("summary write failed\n",stderr) }
        if listener >= 0 { Darwin.close(listener) }
        exit(error == nil && published > 0 ? 0 : 1)
    }
}
@main struct Entry {
    @MainActor static func main() {
        guard CommandLine.arguments.count == 2 else { exit(2) }
        let app = NSApplication.shared
        let host = Host(output: URL(fileURLWithPath: CommandLine.arguments[1])); app.delegate = host
        app.run()
    }
}
