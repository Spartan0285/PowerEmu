import Foundation

/// A folder on this Mac shared with a virtual Mac.
struct SharedFolder: Codable, Hashable, Identifiable {
    var id = UUID()
    var path: String
    var name: String
    var readOnly = false
}

/// A small WebDAV server for shared folders, which Mac OS X's Finder mounts
/// like any WebDAV volume (Connect to Server).  It listens on a Unix socket;
/// a slirp guestfwd rule hands the guest's connections to 10.0.2.100:80 to
/// it through `nc -U` (see VMRunner), so nothing on the network can reach
/// the shares.
///
/// Each share is at /<name>/.  Enough of RFC 4918 for Mac OS X 10.4's
/// webdavfs: OPTIONS, PROPFIND, PROPPATCH (acknowledged), GET/HEAD with
/// ranges, PUT, DELETE, MKCOL, COPY, MOVE and LOCK/UNLOCK (advertising
/// class 2 is what makes webdavfs mount read-write; the locks are nominal).
/// Mac OS X's .DS_Store files are kept apart from this Mac's own.
final class WebDAVServer: @unchecked Sendable {
    let socketPath: String
    private let lock = NSLock()
    private var shares: [String: SharedFolder] = [:]      // by name
    private var listenFD: Int32 = -1
    /// POWEREMU_DAV_TRACE=file logs every request and response there.
    static let traceFile: FileHandle? = {
        guard let p = ProcessInfo.processInfo.environment["POWEREMU_DAV_TRACE"] else { return nil }
        FileManager.default.createFile(atPath: p, contents: nil)
        return FileHandle(forWritingAtPath: p)
    }()
    static let traceLock = NSLock()
    static func trace(_ s: String) {
        guard let f = traceFile else { return }
        traceLock.lock(); defer { traceLock.unlock() }
        f.write(Data((s + "\n").utf8))
    }

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    func setShares(_ list: [SharedFolder]) {
        lock.lock(); defer { lock.unlock() }
        shares = Dictionary(list.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
    }

    private func share(named n: String) -> SharedFolder? {
        lock.lock(); defer { lock.unlock() }
        return shares[n]
    }

    private func allShares() -> [SharedFolder] {
        lock.lock(); defer { lock.unlock() }
        return shares.values.sorted { $0.name < $1.name }
    }

    // MARK: sockets

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
        guard ok == 0, listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listenFD = fd
        let t = Thread { [weak self] in self?.acceptLoop(fd) }
        t.name = "PowerEmu WebDAV"
        t.start()
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }

    private func acceptLoop(_ lfd: Int32) {
        while true {
            let c = accept(lfd, nil, nil)
            if c < 0 { if errno == EINTR { continue }; return }
            var one: Int32 = 1
            setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                self?.serve(HTTPConnection(fd: c))
                close(c)
            }
        }
    }

    // MARK: requests

    private func serve(_ c: HTTPConnection) {
        while let req = c.readRequest() {
            let keep = handle(req, c)
            if !keep || req.header("connection")?.lowercased() == "close" { return }
        }
    }

    /// Returns whether the connection can take another request.
    private func handle(_ r: HTTPRequest, _ c: HTTPConnection) -> Bool {
        let parts = r.path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if r.method == "OPTIONS" {
            let ro = parts.first.flatMap(share(named:))?.readOnly ?? false
            c.drainBody(r)
            return c.respond(200, headers: ["DAV": ro ? "1" : "1, 2", "MS-Author-Via": "DAV",
                                            "Allow": "OPTIONS, GET, HEAD, PUT, DELETE, MKCOL, COPY, MOVE, PROPFIND, PROPPATCH, LOCK, UNLOCK"])
        }
        // "/" lists the shares.
        guard let shareName = parts.first else {
            c.drainBody(r)
            if r.method == "PROPFIND" { return c.respondXML(207, rootListing(depth: r.header("depth") ?? "1")) }
            if r.method == "GET" || r.method == "HEAD" { return c.respond(200, body: Data("PowerEmu shared folders\n".utf8)) }
            return c.respond(405)
        }
        guard let sh = share(named: shareName) else { c.drainBody(r); return c.respond(404) }
        let rel = Array(parts.dropFirst())
        guard let url = Self.resolve(sh, rel) else { c.drainBody(r); return c.respond(403) }
        let href = "/" + parts.map(Self.encode).joined(separator: "/")
        let writes: Set = ["PUT", "DELETE", "MKCOL", "MOVE", "COPY", "PROPPATCH", "LOCK"]
        if sh.readOnly && writes.contains(r.method) { c.drainBody(r); return c.respond(403) }

        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)

        switch r.method {
        case "PROPFIND":
            c.drainBody(r)
            guard exists else { return c.respond(404) }
            var out = [propEntry(href: isDir.boolValue && !href.hasSuffix("/") ? href + "/" : href, url: url,
                                 name: rel.last ?? sh.name)]
            if isDir.boolValue && (r.header("depth") ?? "infinity") != "0" {
                for child in listing(url) {
                    let guestName = Self.guestName(child.lastPathComponent)
                    var h = (href.hasSuffix("/") ? href : href + "/") + Self.encode(guestName)
                    if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { h += "/" }
                    out.append(propEntry(href: h, url: child, name: guestName))
                }
            }
            return c.respondXML(207, multistatus(out))

        case "GET", "HEAD":
            c.drainBody(r)
            guard exists else { return c.respond(404) }
            if isDir.boolValue { return c.respond(200, body: Data(), headers: ["Content-Type": "text/plain"]) }
            return c.sendFile(url, range: r.header("range"), headOnly: r.method == "HEAD")

        case "PUT":
            guard !isDir.boolValue else { c.drainBody(r); return c.respond(405) }
            guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { c.drainBody(r); return c.respond(409) }
            guard c.receiveBody(r, to: url) else { return false }
            return c.respond(exists ? 204 : 201)

        case "DELETE":
            c.drainBody(r)
            guard exists else { return c.respond(404) }
            do { try fm.removeItem(at: url) } catch { return c.respond(403) }
            return c.respond(204)

        case "MKCOL":
            c.drainBody(r)
            if exists { return c.respond(405) }
            do { try fm.createDirectory(at: url, withIntermediateDirectories: false) } catch { return c.respond(409) }
            return c.respond(201)

        case "MOVE", "COPY":
            c.drainBody(r)
            guard exists else { return c.respond(404) }
            guard let dest = r.header("destination").flatMap(destination) else { return c.respond(400) }
            guard !dest.share.readOnly else { return c.respond(403) }
            let overwrite = (r.header("overwrite") ?? "T").uppercased() != "F"
            let existed = fm.fileExists(atPath: dest.url.path)
            if existed {
                guard overwrite else { return c.respond(412) }
                try? fm.removeItem(at: dest.url)
            }
            do {
                if r.method == "MOVE" { try fm.moveItem(at: url, to: dest.url) }
                else { try fm.copyItem(at: url, to: dest.url) }
            } catch { return c.respond(409) }
            return c.respond(existed ? 204 : 201)

        case "PROPPATCH":
            // Accept and ignore (webdavfs sets times it can't have anyway).
            c.drainBody(r)
            guard exists else { return c.respond(404) }
            return c.respondXML(207, multistatus([
                "<D:response><D:href>\(href)</D:href><D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"]))

        case "LOCK":
            c.drainBody(r)
            // A lock on a missing file creates it empty (a "lock-null" file).
            if !exists {
                guard fm.fileExists(atPath: url.deletingLastPathComponent().path) else { return c.respond(409) }
                fm.createFile(atPath: url.path, contents: nil)
            }
            let token = "opaquelocktoken:" + UUID().uuidString.lowercased()
            let xml = """
            <?xml version="1.0" encoding="utf-8"?>
            <D:prop xmlns:D="DAV:"><D:lockdiscovery><D:activelock>\
            <D:locktype><D:write/></D:locktype><D:lockscope><D:exclusive/></D:lockscope>\
            <D:depth>0</D:depth><D:timeout>Second-600</D:timeout>\
            <D:locktoken><D:href>\(token)</D:href></D:locktoken>\
            </D:activelock></D:lockdiscovery></D:prop>
            """
            return c.respondXML(exists ? 200 : 201, xml, headers: ["Lock-Token": "<\(token)>"])

        case "UNLOCK":
            c.drainBody(r)
            return c.respond(204)

        default:
            c.drainBody(r)
            return c.respond(405)
        }
    }

    // MARK: paths

    /// The file for a path inside a share; nil if it would leave the share.
    /// Components are checked one by one (no "..", "." or "/"), so the
    /// result is always inside the shared folder.
    private static func resolve(_ sh: SharedFolder, _ rel: [String]) -> URL? {
        var u = URL(fileURLWithPath: sh.path, isDirectory: true)
        for comp in rel {
            guard comp != "..", comp != ".", !comp.contains("/"), !comp.contains("\0") else { return nil }
            u.appendPathComponent(hostName(comp))
        }
        return u
    }

    /// Mac OS X's Finder writes .DS_Store into every folder it opens; keep
    /// it from replacing this Mac's own.
    private static let guestDSStore = ".poweremu-guest.DS_Store"
    private static func hostName(_ guest: String) -> String { guest == ".DS_Store" ? guestDSStore : guest }
    private static func guestName(_ host: String) -> String { host == guestDSStore ? ".DS_Store" : host }

    private func listing(_ dir: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys:
            [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])) ?? []
        // This Mac's .DS_Store stays private, and half-written uploads are hidden.
        return items.filter { $0.lastPathComponent != ".DS_Store" && !$0.lastPathComponent.hasPrefix(".poweremu-upload-") }
    }

    private func destination(_ s: String) -> (share: SharedFolder, url: URL)? {
        // Destination is an absolute URL (or a path).
        var path = s
        if let u = URLComponents(string: s), u.host != nil { path = u.percentEncodedPath.isEmpty ? "/" : u.percentEncodedPath }
        path = path.removingPercentEncoding ?? path
        let parts = path.split(separator: "/").map(String.init)
        guard let first = parts.first, let sh = share(named: first),
              let url = Self.resolve(sh, Array(parts.dropFirst())) else { return nil }
        return (sh, url)
    }

    static func encode(_ component: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~!$&'()*+,;=:@")
        return component.addingPercentEncoding(withAllowedCharacters: allowed) ?? component
    }

    // MARK: XML

    private static let httpDate: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    private static let isoDate: ISO8601DateFormatter = ISO8601DateFormatter()

    private static func xmlEscape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private func propEntry(href: String, url: URL, name: String) -> String {
        let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey, .creationDateKey])
        let dir = v?.isDirectory ?? false
        let mod = v?.contentModificationDate ?? Date()
        let created = v?.creationDate ?? mod
        let size = v?.fileSize ?? 0
        var p = "<D:displayname>\(Self.xmlEscape(name))</D:displayname>"
        p += dir ? "<D:resourcetype><D:collection/></D:resourcetype>"
                 : "<D:resourcetype/><D:getcontentlength>\(size)</D:getcontentlength><D:getcontenttype>application/octet-stream</D:getcontenttype>"
        p += "<D:getlastmodified>\(Self.httpDate.string(from: mod))</D:getlastmodified>"
        p += "<D:creationdate>\(Self.isoDate.string(from: created))</D:creationdate>"
        p += "<D:getetag>\"\(Int(mod.timeIntervalSince1970))-\(size)\"</D:getetag>"
        p += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope><D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock><D:lockdiscovery/>"
        return "<D:response><D:href>\(href)</D:href><D:propstat><D:prop>\(p)</D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private func rootListing(depth: String) -> String {
        var out = ["<D:response><D:href>/</D:href><D:propstat><D:prop><D:displayname>PowerEmu</D:displayname><D:resourcetype><D:collection/></D:resourcetype></D:prop><D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"]
        if depth != "0" {
            for sh in allShares() {
                out.append(propEntry(href: "/" + Self.encode(sh.name) + "/", url: URL(fileURLWithPath: sh.path), name: sh.name))
            }
        }
        return multistatus(out)
    }

    private func multistatus(_ responses: [String]) -> String {
        "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n<D:multistatus xmlns:D=\"DAV:\">" + responses.joined() + "</D:multistatus>"
    }
}

// MARK: - HTTP/1.1 over a blocking socket

struct HTTPRequest {
    var method: String
    var path: String                 // percent-decoded
    var target = ""                  // as sent (absolute-form URLs too)
    var version = "HTTP/1.1"
    var headers: [String: String]    // lower-case names
    func header(_ n: String) -> String? { headers[n] }
}

final class HTTPConnection {
    let fd: Int32
    private var buffer = Data()

    init(fd: Int32) {
        self.fd = fd
        var tv = timeval(tv_sec: 120, tv_usec: 0)        // idle keep-alive limit
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return false }
        buffer.append(contentsOf: chunk[0..<n])
        return true
    }

    func readRequest() -> HTTPRequest? {
        let end = Data("\r\n\r\n".utf8)
        while buffer.range(of: end) == nil {
            if buffer.count > 65536 || !fill() { return nil }
        }
        let r = buffer.range(of: end)!
        let head = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        buffer = Data(buffer[r.upperBound...])
        var lines = head.components(separatedBy: "\r\n")
        let first = lines.removeFirst().split(separator: " ")
        guard first.count >= 2 else { return nil }
        var headers: [String: String] = [:]
        for l in lines {
            guard let colon = l.firstIndex(of: ":") else { continue }
            headers[l[..<colon].lowercased()] = l[l.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        WebDAVServer.trace(">>> " + head)
        let raw = String(first[1])
        var target = raw
        if let u = URLComponents(string: target), u.host != nil { target = u.percentEncodedPath }   // absolute-form
        if let q = target.firstIndex(of: "?") { target = String(target[..<q]) }
        return HTTPRequest(method: String(first[0]).uppercased(),
                           path: target.removingPercentEncoding ?? target, target: raw,
                           version: first.count > 2 ? String(first[2]) : "HTTP/1.0", headers: headers)
    }

    /// Stream the request body into `sink`; false if the connection broke.
    func readBody(_ r: HTTPRequest, _ sink: (Data) -> Void) -> Bool {
        if r.header("transfer-encoding")?.lowercased().contains("chunked") == true {
            while true {
                guard let line = readLine(), let size = Int(line.split(separator: ";")[0].trimmingCharacters(in: .whitespaces), radix: 16) else { return false }
                if size == 0 {
                    while let l = readLine(), !l.isEmpty {}           // trailers
                    return true
                }
                guard readExactly(size, sink) else { return false }
                _ = readLine()
            }
        }
        let len = Int(r.header("content-length") ?? "0") ?? 0
        return readExactly(len, sink)
    }

    private func readLine() -> String? {
        while true {
            if let i = buffer.firstIndex(of: 0x0a) {
                let line = String(decoding: buffer[buffer.startIndex..<i], as: UTF8.self)
                buffer = Data(buffer[buffer.index(after: i)...])
                return line.hasSuffix("\r") ? String(line.dropLast()) : line
            }
            if !fill() { return nil }
        }
    }

    private func readExactly(_ n: Int, _ sink: (Data) -> Void) -> Bool {
        var left = n
        while left > 0 {
            if buffer.isEmpty && !fill() { return false }
            let take = min(left, buffer.count)
            sink(Data(buffer.prefix(take)))
            buffer = Data(buffer.dropFirst(take))
            left -= take
        }
        return true
    }

    func drainBody(_ r: HTTPRequest) {
        var body = Data()
        _ = readBody(r) { body.append($0) }
        if !body.isEmpty { WebDAVServer.trace(String(decoding: body.prefix(2000), as: UTF8.self)) }
    }

    /// PUT: write to a temporary file beside the target, then replace it.
    func receiveBody(_ r: HTTPRequest, to url: URL) -> Bool {
        let tmp = url.deletingLastPathComponent().appendingPathComponent(".poweremu-upload-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let h = try? FileHandle(forWritingTo: tmp) else { drainBody(r); return true }
        let ok = readBody(r) { h.write($0) }
        try? h.close()
        if ok {
            _ = try? FileManager.default.replaceItemAt(url, withItemAt: tmp)
            if FileManager.default.fileExists(atPath: tmp.path) {
                try? FileManager.default.removeItem(at: url)
                try? FileManager.default.moveItem(at: tmp, to: url)
            }
        } else {
            try? FileManager.default.removeItem(at: tmp)
        }
        return ok
    }

    func writeAll(_ d: Data) -> Bool {
        d.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                p += n; left -= n
            }
            return true
        }
    }

    private static let reasons = [200: "OK", 201: "Created", 204: "No Content", 206: "Partial Content",
                                  207: "Multi-Status", 400: "Bad Request", 403: "Forbidden", 404: "Not Found",
                                  405: "Method Not Allowed", 409: "Conflict", 412: "Precondition Failed",
                                  416: "Range Not Satisfiable", 500: "Internal Server Error", 401: "Unauthorized",
                                  502: "Bad Gateway", 504: "Gateway Timeout"]

    private func head(_ status: Int, _ headers: [String: String], length: Int) -> Data {
        var s = "HTTP/1.1 \(status) \(Self.reasons[status] ?? "Status")\r\n"
        var h = headers
        h["Content-Length"] = String(length)
        h["Server"] = "PowerEmu"
        for (k, v) in h { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    @discardableResult
    func respond(_ status: Int, body: Data = Data(), headers: [String: String] = [:]) -> Bool {
        var d = head(status, headers, length: body.count)
        WebDAVServer.trace("<<< " + String(decoding: d, as: UTF8.self) + String(decoding: body.prefix(1500), as: UTF8.self))
        d.append(body)
        return writeAll(d)
    }

    func respondXML(_ status: Int, _ xml: String, headers: [String: String] = [:]) -> Bool {
        var h = headers
        h["Content-Type"] = "text/xml; charset=\"utf-8\""
        return respond(status, body: Data(xml.utf8), headers: h)
    }

    func sendFile(_ url: URL, range: String?, headOnly: Bool) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return respond(403) }
        defer { try? h.close() }
        let size = Int((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        var start = 0, end = size - 1, status = 200
        var headers = ["Content-Type": "application/octet-stream", "Accept-Ranges": "bytes"]
        if let range, range.hasPrefix("bytes="), size > 0 {
            let spec = range.dropFirst(6).split(separator: ",")[0]
            let ab = spec.split(separator: "-", omittingEmptySubsequences: false)
            if ab.count == 2 {
                if ab[0].isEmpty, let n = Int(ab[1]) { start = max(0, size - n) }
                else { start = Int(ab[0]) ?? 0; if let e = Int(ab[1]) { end = min(e, size - 1) } }
                guard start <= end else { return respond(416, headers: ["Content-Range": "bytes */\(size)"]) }
                status = 206
                headers["Content-Range"] = "bytes \(start)-\(end)/\(size)"
            }
        }
        let length = max(0, end - start + 1)
        guard writeAll(head(status, headers, length: headOnly ? length : length)) else { return false }
        if headOnly || length == 0 { return true }
        try? h.seek(toOffset: UInt64(start))
        var left = length
        while left > 0 {
            guard let d = try? h.read(upToCount: min(left, 1 << 20)), !d.isEmpty else { return false }
            guard writeAll(d) else { return false }
            left -= d.count
        }
        return true
    }
}
