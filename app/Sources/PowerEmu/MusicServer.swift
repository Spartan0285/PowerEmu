import Foundation
import CryptoKit
import Compression
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/*
 * The half of PowerMusic the old Macs talk to: an HTTP server with a
 * WebSocket on it, answering exactly what the Node server it replaces
 * answered, so the PowerPC controller needs no changes at all.
 *
 * Everything here runs off the main thread, one thread per connection, the
 * way PowerEmu's other servers do.
 */
final class MusicServer: @unchecked Sendable {
    struct Settings {
        var apple: AppleMusicAPI.Settings
        /// Where the controller and player pages are: the built web app.
        var webRoot: String
    }

    let store: MusicStore
    let api: AppleMusicAPI
    private var webRoot: String
    private let note: @Sendable (String) -> Void
    private let cacheDir: URL

    private let clientLock = NSLock()
    private var clients: [String: WebSocketPeer] = [:]
    private var reaper: DispatchSourceTimer?

    init(settings: Settings, note: @escaping @Sendable (String) -> Void) {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Music")
        store = MusicStore(file: support.appendingPathComponent("state.json"))
        api = AppleMusicAPI(settings.apple)
        webRoot = settings.webRoot
        self.note = note
        cacheDir = support.appendingPathComponent("Artwork")
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        store.onChange = { [weak self] in self?.broadcastState() }
        startReaper()
    }

    func update(_ s: Settings) {
        api.update(s.apple)
        clientLock.lock(); webRoot = s.webRoot; clientLock.unlock()
    }

    private var currentWebRoot: String { clientLock.lock(); defer { clientLock.unlock() }; return webRoot }

    /// A player that stops saying it is there loses the role, so another
    /// device can take it without the reader having to force anything.
    private func startReaper() {
        let t = DispatchSource.makeTimerSource(queue: DispatchQueue.global(qos: .utility))
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.store.dropStalePlayer() }
        t.resume()
        reaper = t
    }

    // MARK: - A connection

    func serve(fd: Int32, peer: String) {
        let c = HTTPConnection(fd: fd)
        defer { close(fd) }
        while let r = c.readRequest() {
            if r.path == "/ws" , r.header("upgrade")?.lowercased().contains("websocket") == true {
                serveWebSocket(c, r, peer: peer)
                return                       // the socket is the WebSocket's now
            }
            var body = Data()
            _ = c.readBody(r) { body.append($0) }
            let keepAlive = r.header("connection")?.lowercased() != "close"
            respond(to: r, body: body, on: c, keepAlive: keepAlive)
            if !keepAlive { return }
        }
    }

    // MARK: - What it answers

    private func respond(to r: HTTPRequest, body: Data, on c: HTTPConnection, keepAlive: Bool) {
        let query = Self.query(r.target)
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        let gzip = r.header("accept-encoding")?.contains("gzip") == true

        func ok(_ o: Any) { send(c, 200, json: o, gzip: gzip, keepAlive: keepAlive) }
        func fail(_ code: Int, _ message: String) {
            send(c, code, json: ["error": message], gzip: gzip, keepAlive: keepAlive)
        }
        /// Apple's answers: anything that needs the reader's own token and
        /// hasn't got one is a 401, as it was before, so the controller can
        /// tell "not signed in" from "went wrong".
        func attempt(_ work: () throws -> Any) {
            do { ok(try work()) } catch let e as AppleMusicAPI.MusicError {
                if case .needsUserToken = e { fail(401, e.localizedDescription) } else { fail(500, e.localizedDescription) }
            } catch { fail(500, error.localizedDescription) }
        }

        switch (r.method, r.path) {
        case ("GET", "/api/token"):
            do { ok(["token": try api.developerToken()]) } catch { fail(500, "Failed to generate token") }

        case ("GET", "/api/search"):
            guard let q = query["q"], !q.isEmpty else { return ok([]) }
            attempt { try api.searchSongs(q) }

        case ("GET", "/api/search/collections"):
            guard let q = query["q"], !q.isEmpty else { return ok([]) }
            attempt { try api.searchCollections(q) }

        case ("POST", "/api/user-token"):
            guard let t = json["userToken"] as? String, !t.isEmpty else { return fail(400, "userToken required") }
            api.setUserToken(t)
            api.libraryClearCache()
            note("Music: the player signed in to Apple Music")
            ok(["ok": true])

        case ("GET", "/api/user-token/status"):
            ok(["hasUserToken": api.hasUserToken])

        case ("GET", "/api/library/songs"):
            attempt { try api.librarySongs(offset: Int(query["offset"] ?? "0") ?? 0) }

        case ("GET", "/api/library/playlists"):
            attempt { try api.libraryPlaylists() }

        case ("GET", "/api/library/albums"):
            attempt { try api.libraryAlbums() }

        case ("GET", "/api/recent"):
            attempt { try api.recentlyPlayed() }

        case ("GET", "/api/recommendations"):
            attempt { try api.recommendations() }

        case ("GET", "/api/heavy-rotation"):
            attempt { try api.heavyRotation() }

        case ("GET", "/api/radio/stations"):
            attempt { try api.radioStations() }

        case ("GET", "/api/state"):
            ok(store.snapshot())

        case ("POST", "/api/play-station"):
            guard let id = json["stationId"] as? String else { return fail(400, "stationId required") }
            // A station is not a track, but everything downstream understands
            // tracks, so it arrives as one with no length.
            store.add(id, meta: ["id": id,
                                 "title": json["name"] as? String ?? "Radio Station",
                                 "artist": "Apple Music Radio",
                                 "album": "",
                                 "durationSeconds": 0,
                                 "artworkUrl": json["artworkUrl"] as Any? ?? NSNull()])
            store.play(id)
            ok(store.snapshot())

        case ("POST", "/api/queue/add"):
            guard let id = json["trackId"] as? String else { return fail(400, "trackId required") }
            store.add(id, meta: json["meta"] as? [String: Any])
            ok(store.snapshot())

        case ("POST", "/api/queue/remove"):
            guard let i = json["index"] as? Int else { return fail(400, "Invalid index") }
            store.remove(at: i)
            ok(store.snapshot())

        case ("POST", "/api/queue/clear"):
            store.clear()
            ok(store.snapshot())

        case ("POST", "/api/play-context"):
            guard let tracks = json["tracks"] as? [[String: Any]], let start = json["startTrackId"] as? String else {
                return fail(400, "tracks array and startTrackId required")
            }
            store.setContext(tracks, start: start)
            ok(store.snapshot())

        case ("POST", "/api/play"):
            store.play(json["trackId"] as? String)
            ok(store.snapshot())

        case ("POST", "/api/pause"):
            store.pause(); ok(store.snapshot())

        case ("POST", "/api/next"):
            store.next(); ok(store.snapshot())

        case ("POST", "/api/prev"):
            store.previous(); ok(store.snapshot())

        case ("POST", "/api/seek"):
            guard let p = json["positionSeconds"] as? Double else { return fail(400, "Invalid positionSeconds") }
            store.seek(p); ok(store.snapshot())

        case ("POST", "/api/volume"):
            guard let v = json["volume"] as? Double else { return fail(400, "Invalid volume") }
            store.setVolume(v); ok(store.snapshot())

        case ("POST", "/api/repeat"):
            guard let m = json["mode"] as? String, ["off", "one", "all"].contains(m) else { return fail(400, "Invalid mode") }
            store.setRepeat(m); ok(store.snapshot())

        case ("POST", "/api/shuffle"):
            guard let e = json["enabled"] as? Bool else { return fail(400, "Invalid enabled") }
            store.setShuffle(e); ok(store.snapshot())

        case ("GET", "/api/artwork"):
            serveArtwork(query, on: c, keepAlive: keepAlive)

        default:
            serveFile(r.path, on: c, gzip: gzip, keepAlive: keepAlive)
        }
    }

    // MARK: - The pages

    /// The built web app.  Anything that is not a file is the app's own
    /// page: it does its own routing, so /player and /controller are index
    /// with a different address, not files on disk.
    private func serveFile(_ path: String, on c: HTTPConnection, gzip: Bool, keepAlive: Bool) {
        let root = URL(fileURLWithPath: currentWebRoot)
        let rel = path == "/" ? "index.html" : String(path.drop(while: { $0 == "/" }))
        var file = root.appendingPathComponent(rel).standardizedFileURL
        // Nothing above the web root, whatever the address asks for.
        if !file.path.hasPrefix(root.standardizedFileURL.path) { file = root.appendingPathComponent("index.html") }
        var isDir: ObjCBool = false
        if !FileManager.default.fileExists(atPath: file.path, isDirectory: &isDir) || isDir.boolValue {
            file = root.appendingPathComponent("index.html")
        }
        guard let data = try? Data(contentsOf: file) else {
            send(c, 404, body: Data("Not found".utf8), type: "text/plain", gzip: false, keepAlive: keepAlive)
            return
        }
        let type = Self.contentType(file.pathExtension)
        // Only what gains from it: pictures and fonts are already packed, and
        // an old Mac should not spend its processor unpacking them twice.
        let worth = type.hasPrefix("text/") || type.contains("javascript") || type.contains("json") || type.contains("svg")
        send(c, 200, body: data, type: type, gzip: gzip && worth, keepAlive: keepAlive)
    }

    private static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": return "text/html; charset=utf-8"
        case "js", "mjs": return "application/javascript; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "jpg", "jpeg": return "image/jpeg"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "ico": return "image/x-icon"
        case "woff": return "font/woff"
        case "woff2": return "font/woff2"
        case "ttf": return "font/ttf"
        case "map": return "application/json; charset=utf-8"
        default: return "application/octet-stream"
        }
    }

    // MARK: - Artwork

    /// Apple's artwork is enormous and its address is a template.  An old
    /// Mac gets it at the size it will draw it, as a plain JPEG, and this
    /// Mac keeps a copy so the second look costs nothing.
    private func serveArtwork(_ query: [String: String], on c: HTTPConnection, keepAlive: Bool) {
        guard let url = query["url"], !url.isEmpty else {
            send(c, 400, json: ["error": "url required"], gzip: false, keepAlive: keepAlive)
            return
        }
        let size = Int(query["size"] ?? "0") ?? 0
        let key = Insecure.MD5.hash(data: Data("\(url)__\(size)".utf8)).map { String(format: "%02x", $0) }.joined()
        let cached = cacheDir.appendingPathComponent(key + ".jpg")

        if let d = try? Data(contentsOf: cached) {
            send(c, 200, body: d, type: "image/jpeg", gzip: false, keepAlive: keepAlive,
                 extra: ["Cache-Control": "public, max-age=604800", "X-Cache": "HIT"])
            return
        }
        guard let source = URL(string: url) else {
            send(c, 400, json: ["error": "url required"], gzip: false, keepAlive: keepAlive)
            return
        }
        let sem = DispatchSemaphore(value: 0)
        var raw: Data?
        var status = 0
        URLSession.shared.dataTask(with: source) { d, r, _ in
            raw = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; sem.signal()
        }.resume()
        sem.wait()
        guard let raw, (200..<300).contains(status) else {
            send(c, status == 0 ? 500 : status, body: Data("Upstream error".utf8), type: "text/plain",
                 gzip: false, keepAlive: keepAlive)
            return
        }
        let jpeg = Self.jpeg(raw, size: size) ?? raw
        try? jpeg.write(to: cached, options: .atomic)
        send(c, 200, body: jpeg, type: "image/jpeg", gzip: false, keepAlive: keepAlive,
             extra: ["Cache-Control": "public, max-age=604800", "X-Cache": "MISS"])
    }

    private static func jpeg(_ data: Data, size: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        if size > 0 { options[kCGImageSourceThumbnailMaxPixelSize] = size }
        guard let image = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 0.7] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    // MARK: - Writing an answer

    private func send(_ c: HTTPConnection, _ status: Int, json: Any, gzip: Bool, keepAlive: Bool) {
        let d = (try? JSONSerialization.data(withJSONObject: json, options: [.fragmentsAllowed])) ?? Data("null".utf8)
        send(c, status, body: d, type: "application/json; charset=utf-8", gzip: gzip, keepAlive: keepAlive)
    }

    private func send(_ c: HTTPConnection, _ status: Int, body: Data, type: String,
                      gzip: Bool, keepAlive: Bool, extra: [String: String] = [:]) {
        var payload = body
        var headers = extra
        // The link to an old Mac is the slow part of all this, so text goes
        // over it packed.
        if gzip, body.count > 512, let z = Self.gzipped(body) {
            payload = z
            headers["Content-Encoding"] = "gzip"
        }
        var head = "HTTP/1.1 \(status) \(Self.reason(status))\r\n"
        head += "Content-Type: \(type)\r\n"
        head += "Content-Length: \(payload.count)\r\n"
        head += "Connection: \(keepAlive ? "keep-alive" : "close")\r\n"
        // The controller is served from here, so this is same-origin; the
        // header is for a reader who opens it from somewhere else.
        head += "Access-Control-Allow-Origin: *\r\n"
        for (k, v) in headers { head += "\(k): \(v)\r\n" }
        head += "\r\n"
        var out = Data(head.utf8)
        out.append(payload)
        Self.writeAll(c.fd, out)
    }

    private static func reason(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        default: return "OK"
        }
    }

    static func writeAll(_ fd: Int32, _ data: Data) {
        data.withUnsafeBytes { raw in
            var off = 0
            while off < raw.count {
                let n = write(fd, raw.baseAddress!.advanced(by: off), raw.count - off)
                if n <= 0 { return }
                off += n
            }
        }
    }

    // MARK: gzip

    /// Deflate with a gzip wrapper around it: the framework gives the
    /// compressed bytes, the header, checksum and length are ours.
    private static func gzipped(_ data: Data) -> Data? {
        let cap = data.count + 64 * 1024
        var out = Data(count: cap)
        let written = out.withUnsafeMutableBytes { dst -> Int in
            data.withUnsafeBytes { src -> Int in
                compression_encode_buffer(dst.bindMemory(to: UInt8.self).baseAddress!, cap,
                                          src.bindMemory(to: UInt8.self).baseAddress!, data.count,
                                          nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return nil }
        var gz = Data([0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 0x03])   // deflate, no name, unix
        gz.append(out.prefix(written))
        var crc = crc32(data).littleEndian
        var size = UInt32(truncatingIfNeeded: data.count).littleEndian
        withUnsafeBytes(of: &crc) { gz.append(contentsOf: $0) }
        withUnsafeBytes(of: &size) { gz.append(contentsOf: $0) }
        return gz
    }

    private static let crcTable: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = (c & 1) != 0 ? (0xEDB88320 ^ (c >> 1)) : (c >> 1) }
        return c
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var c: UInt32 = 0xFFFFFFFF
        for b in data { c = crcTable[Int((c ^ UInt32(b)) & 0xFF)] ^ (c >> 8) }
        return c ^ 0xFFFFFFFF
    }

    // MARK: - The WebSocket

    private func serveWebSocket(_ c: HTTPConnection, _ r: HTTPRequest, peer: String) {
        guard let key = r.header("sec-websocket-key") else { return }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8)))
            .base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\n"
            + "Upgrade: websocket\r\nConnection: Upgrade\r\n"
            + "Sec-WebSocket-Accept: \(accept)\r\n\r\n"
        Self.writeAll(c.fd, Data(head.utf8))

        let id = UUID().uuidString
        let peerIP = r.header("x-forwarded-for")?.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? peer
        let agent = r.header("user-agent") ?? "unknown"
        let ws = WebSocketPeer(fd: c.fd, id: id)
        clientLock.lock(); clients[id] = ws; clientLock.unlock()
        note("Music: \(peerIP) connected")

        ws.send(Self.encode(["type": "STATE", "state": store.snapshot()]))

        while let frame = ws.read() {
            guard let msg = (try? JSONSerialization.jsonObject(with: frame)) as? [String: Any] else { continue }
            handle(msg, from: ws, ip: peerIP, agent: agent)
        }

        clientLock.lock(); clients[id] = nil; clientLock.unlock()
        store.clearPlayer(ifID: id)          // the player's tab has gone
        note("Music: \(peerIP) disconnected")
    }

    private func handle(_ msg: [String: Any], from ws: WebSocketPeer, ip: String, agent: String) {
        switch msg["type"] as? String ?? "" {
        case "CLAIM_PLAYER", "FORCE_CLAIM_PLAYER":
            let force = (msg["type"] as? String) == "FORCE_CLAIM_PLAYER"
            let name = msg["deviceName"] as? String ?? "Unknown"
            let r = store.claimPlayer(id: ws.id, device: name, ip: ip, userAgent: agent, force: force)
            if r.granted { note("Music: \(name) is the player") }
            ws.send(Self.encode(["type": "CLAIM_RESULT",
                                 "granted": r.granted,
                                 "activePlayerMeta": r.meta as Any? ?? NSNull()]))

        case "HEARTBEAT":
            store.heartbeat(ws.id)

        case "POSITION":
            guard store.isPlayer(ws.id) else { return }
            store.updatePosition(msg["positionSeconds"] as? Double ?? 0,
                                 duration: msg["durationSeconds"] as? Double)

        case "CMD":
            command(msg["action"] as? String ?? "", msg["payload"] as? [String: Any] ?? [:])

        default:
            break
        }
    }

    private func command(_ action: String, _ p: [String: Any]) {
        switch action {
        case "play": store.play(p["trackId"] as? String)
        case "pause": store.pause()
        case "next": store.next()
        case "prev": store.previous()
        case "seek": store.seek(p["positionSeconds"] as? Double ?? 0)
        case "volume": store.setVolume(p["volume"] as? Double ?? 1)
        case "repeat": store.setRepeat(p["mode"] as? String ?? "off")
        case "shuffle": store.setShuffle(p["enabled"] as? Bool ?? false)
        case "play_context":
            if let t = p["tracks"] as? [[String: Any]], let s = p["startTrackId"] as? String { store.setContext(t, start: s) }
        case "queue_add":
            if let id = p["trackId"] as? String { store.add(id, meta: p["meta"] as? [String: Any]) }
        case "queue_remove":
            if let i = p["index"] as? Int { store.remove(at: i) }
        case "queue_clear": store.clear()
        default: break
        }
    }

    private static func encode(_ o: [String: Any]) -> Data {
        (try? JSONSerialization.data(withJSONObject: o)) ?? Data("{}".utf8)
    }

    private func broadcastState() {
        let d = Self.encode(["type": "STATE", "state": store.snapshot()])
        clientLock.lock()
        let all = Array(clients.values)
        clientLock.unlock()
        for c in all { c.send(d) }
    }
}

// MARK: - One WebSocket

/// Enough of RFC 6455 for this: text frames, both ways, with the pings and
/// the closing handshake answered.  Nothing here fragments a message, and
/// the messages are small, so a received message is gathered whole before
/// it is handed on.
final class WebSocketPeer: @unchecked Sendable {
    let fd: Int32
    let id: String
    private let writeLock = NSLock()
    private var buffer = Data()
    private var open = true

    init(fd: Int32, id: String) {
        self.fd = fd
        self.id = id
        // No idle timeout: a controller can sit untouched all evening and is
        // still there.  A dead one is noticed when a write fails.
        var tv = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    func send(_ payload: Data) {
        guard open else { return }
        var frame = Data([0x81])                     // final, text
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n < 65536 {
            frame.append(126)
            frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((n >> shift) & 0xFF)) }
        }
        frame.append(payload)
        writeLock.lock()
        MusicServer.writeAll(fd, frame)
        writeLock.unlock()
    }

    /// The next text message, or nil when the connection ends.
    func read() -> Data? {
        while true {
            guard let (opcode, payload) = readFrame() else { open = false; return nil }
            switch opcode {
            case 0x1:
                return payload
            case 0x8:                                // close
                writeLock.lock(); MusicServer.writeAll(fd, Data([0x88, 0])); writeLock.unlock()
                open = false
                return nil
            case 0x9:                                // ping
                writeLock.lock()
                var pong = Data([0x8A, UInt8(min(payload.count, 125))])
                pong.append(payload.prefix(125))
                MusicServer.writeAll(fd, pong)
                writeLock.unlock()
            default:
                break                                // pong, and anything else
            }
        }
    }

    private func fill(_ n: Int) -> Bool {
        while buffer.count < n {
            var chunk = [UInt8](repeating: 0, count: 65536)
            let got = Foundation.read(fd, &chunk, chunk.count)
            if got <= 0 { return false }
            buffer.append(contentsOf: chunk[0..<got])
        }
        return true
    }

    private func take(_ n: Int) -> Data {
        let d = Data(buffer.prefix(n))
        buffer = Data(buffer.dropFirst(n))
        return d
    }

    private func readFrame() -> (UInt8, Data)? {
        guard fill(2) else { return nil }
        let head = take(2)
        let opcode = head[0] & 0x0F
        let masked = (head[1] & 0x80) != 0
        var length = Int(head[1] & 0x7F)
        if length == 126 {
            guard fill(2) else { return nil }
            let e = take(2)
            length = Int(e[0]) << 8 | Int(e[1])
        } else if length == 127 {
            guard fill(8) else { return nil }
            let e = take(8)
            length = e.reduce(0) { $0 << 8 | Int($1) }
        }
        // A client that sends an unreasonable length is not one of ours.
        guard length <= 8 * 1024 * 1024 else { return nil }
        var mask = Data()
        if masked {
            guard fill(4) else { return nil }
            mask = take(4)
        }
        guard fill(length) else { return nil }
        var payload = take(length)
        if masked, mask.count == 4 {
            for i in 0..<payload.count { payload[i] ^= mask[i % 4] }
        }
        return (opcode, payload)
    }
}

// MARK: - Bits of an address

extension MusicServer {
    /// The query, from the address as it was sent (HTTPRequest keeps the
    /// path without it).
    static func query(_ target: String) -> [String: String] {
        guard let q = target.firstIndex(of: "?") else { return [:] }
        var out: [String: String] = [:]
        for pair in target[target.index(after: q)...].split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard let name = kv.first.map(String.init)?.removingPercentEncoding else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            out[name] = value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? value
        }
        return out
    }
}
