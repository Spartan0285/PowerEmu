import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The Web Accelerator: old browsers (Captain Polliwog) hand their HTTP and
/// HTTPS requests to PowerEmu, which fetches them with this Mac's modern
/// networking (TLS 1.3, HTTP/2) and slims the answers down for the old Mac:
/// images it can't decode or doesn't need at full size are converted, ad and
/// tracker requests are answered empty, text is compressed for the last hop.
/// The old Mac still renders the page and runs its scripts itself.
///
/// Protocol (Captain Polliwog: docs/POWEREMU_WEB_ACCELERATOR.md): a request
/// with the full URL as its target, "GET https://host/path HTTP/1.1", plus
/// X-PowerEmu-Engine describing what the old engine can take.  Virtual Macs
/// reach it at 10.0.2.100:7780, other Macs at this Mac's port 7780
/// (Bonjour _poweremu-web._tcp) with a pairing code.
final class WebAccelerator: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    struct Settings {
        var convertImages = true
        var blockTrackers = true
        var pairingCode = ""
    }

    struct Stats {
        var requests = 0, converted = 0, blocked = 0
        var bytesSaved: Int64 = 0
    }

    static let port: UInt16 = 7780

    private let lock = NSLock()
    private var settings = Settings()
    private var stats = Stats()
    private var tasks: [Int: UpstreamTask] = [:]
    private let note: @Sendable (String) -> Void
    private var session: URLSession!

    init(note: @escaping @Sendable (String) -> Void) {
        self.note = note
        super.init()
        let cfg = URLSessionConfiguration.ephemeral
        cfg.httpCookieStorage = nil
        cfg.httpShouldSetCookies = false
        cfg.httpCookieAcceptPolicy = .never
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        cfg.httpMaximumConnectionsPerHost = 8
        let q = OperationQueue()
        q.maxConcurrentOperationCount = 4
        session = URLSession(configuration: cfg, delegate: self, delegateQueue: q)
    }

    func update(_ s: Settings) { lock.lock(); settings = s; lock.unlock() }
    var currentStats: Stats { lock.lock(); defer { lock.unlock() }; return stats }
    private func count(_ f: (inout Stats) -> Void) { lock.lock(); f(&stats); lock.unlock() }

    // MARK: connections

    /// One connection from an old Mac; `fromNetwork` ones must pair.
    func serve(fd: Int32, fromNetwork: Bool) {
        let c = HTTPConnection(fd: fd)
        defer { close(fd) }
        while let r = c.readRequest() {
            lock.lock(); let s = settings; lock.unlock()
            if fromNetwork && !Self.sameCode(r.header("x-poweremu-token") ?? "", s.pairingCode) {
                c.drainBody(r)
                guard c.respond(401, body: Data("PowerEmu needs the pairing code shown in its Service Hub.\n".utf8),
                                headers: ["X-PowerEmu": "1", "Content-Type": "text/plain"]) else { return }
                continue
            }
            let keep: Bool
            if r.target.hasPrefix("/.poweremu/v1/hello") {
                c.drainBody(r)
                let body = "service: PowerEmu Web Accelerator\nversion: 1\nfeatures: tls http2 images block compress\nname: \(Host.current().localizedName ?? "PowerEmu")\n"
                keep = c.respond(200, body: Data(body.utf8), headers: ["X-PowerEmu": "1", "Content-Type": "text/plain; charset=utf-8"])
            } else if r.target.lowercased().hasPrefix("http://") || r.target.lowercased().hasPrefix("https://") {
                keep = fetch(r, c, s)
            } else {
                c.drainBody(r)
                keep = c.respond(400, body: Data("Send the full URL: GET https://host/path HTTP/1.1\n".utf8),
                                 headers: ["X-PowerEmu": "1", "Content-Type": "text/plain"])
            }
            if !keep || r.header("connection")?.lowercased() == "close" || r.version == "HTTP/1.0" { return }
        }
    }

    private static func sameCode(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard !y.isEmpty, x.count == y.count else { return false }
        var d: UInt8 = 0
        for i in 0..<x.count { d |= x[i] ^ y[i] }
        return d == 0
    }

    // MARK: fetching

    private static let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-connection", "proxy-authorization",
        "proxy-authenticate", "te", "trailer", "upgrade", "host", "accept-encoding", "content-length",
        "transfer-encoding", "expect"]

    /// Returns whether the connection can carry another request.
    private func fetch(_ r: HTTPRequest, _ c: HTTPConnection, _ s: Settings) -> Bool {
        count { $0.requests += 1 }
        let engine = Engine(r.header("x-poweremu-engine"))
        let isPrivate = r.header("x-poweremu-private") == "1"
        guard let url = URL(string: r.target), let host = url.host?.lowercased() else {
            c.drainBody(r)
            return c.respond(400, body: Data("Bad URL\n".utf8), headers: ["X-PowerEmu": "1"])
        }
        if s.blockTrackers, let list = Blocklist.match(host) {
            c.drainBody(r)
            count { $0.blocked += 1 }
            return c.respond(204, headers: ["X-PowerEmu": "1", "X-PowerEmu-Blocked": list])
        }

        var body: Data?
        if r.header("transfer-encoding") != nil || (Int(r.header("content-length") ?? "0") ?? 0) > 0 {
            var d = Data()
            guard c.readBody(r, { d.append($0) }) else { return false }
            body = d
        }
        var req = URLRequest(url: url)
        req.httpMethod = r.method
        req.httpShouldHandleCookies = false
        for (k, v) in r.headers where !Self.hopByHop.contains(k) && !k.hasPrefix("x-poweremu-") {
            req.setValue(v, forHTTPHeaderField: k)
        }
        req.httpBody = body

        let up = UpstreamTask()
        let task = session.dataTask(with: req)
        up.task = task
        lock.lock(); tasks[task.taskIdentifier] = up; lock.unlock()
        defer { lock.lock(); tasks[task.taskIdentifier] = nil; lock.unlock() }
        task.resume()

        // The site's status and headers.
        guard let first = up.next(timeout: 75) else {
            task.cancel()
            return failed(c, 504, "timed out waiting for \(host)")
        }
        let resp: HTTPURLResponse
        switch first {
        case .response(let x): resp = x
        case .done(let e):
            let msg = Self.describe(e, host: host)
            if !isPrivate { note("Web: \(msg)") }
            return failed(c, (e as? URLError)?.code == .timedOut ? 504 : 502, msg)
        case .data: return failed(c, 502, "no response from \(host)")
        }

        var headers: [(String, String)] = [("X-PowerEmu", "1")]
        var setCookies: [String] = []
        for (k, v) in resp.allHeaderFields {
            guard let k = k as? String, let v = v as? String else { continue }
            let lk = k.lowercased()
            if ["content-encoding", "content-length", "transfer-encoding", "connection", "keep-alive"].contains(lk) { continue }
            if lk == "set-cookie" { continue }
            headers.append((k, v))
        }
        if let raw = resp.allHeaderFields.first(where: { ($0.key as? String)?.lowercased() == "set-cookie" })?.value as? String {
            for ck in HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: url) {
                setCookies.append(Self.serialize(ck))
            }
        }
        headers += setCookies.map { ("Set-Cookie", $0) }

        let status = resp.statusCode
        let noBody = r.method == "HEAD" || status == 204 || status == 304 || (100..<200).contains(status)
        if noBody {
            _ = drain(up, max: 0)
            return c.writeAll(Self.head(status, headers, extra: nil))
        }

        let mime = (resp.mimeType ?? "").lowercased()
        let convertible = s.convertImages && status == 200 && r.header("range") == nil
            && ImageConverter.candidate(mime: mime, engine: engine)
        let accepts = (r.header("accept-encoding") ?? "").lowercased()
        let encoding = accepts.contains("gzip") ? "gzip" : (accepts.contains("deflate") ? "deflate" : nil)
        let compressible = encoding != nil && Self.isText(mime)
        let expected = resp.expectedContentLength

        if convertible || (compressible && (expected < 0 || expected < 8 << 20)) {
            // Whole body first.
            guard var data = drain(up, max: 48 << 20) else {
                task.cancel()
                return failed(c, 502, "\(host) sent an incomplete or too large answer")
            }
            if convertible, let (img, newMime, what) = ImageConverter.convert(data, mime: mime, engine: engine) {
                count { $0.converted += 1; $0.bytesSaved += Int64(data.count - img.count) }
                headers = headers.filter { $0.0.lowercased() != "content-type" && $0.0.lowercased() != "etag" }
                headers.append(("Content-Type", newMime))
                headers.append(("X-PowerEmu-Converted", what))
                data = img
            } else if compressible, let enc = encoding, data.count > 1024, let z = Compression.encode(data, enc) {
                count { $0.bytesSaved += Int64(data.count - z.count) }
                headers.append(("Content-Encoding", enc))
                headers.append(("Vary", "Accept-Encoding"))
                data = z
            }
            headers.append(("Content-Length", String(data.count)))
            return c.writeAll(Self.head(status, headers, extra: nil)) && c.writeAll(data)
        }

        // Stream: chunked to HTTP/1.1 clients, until close to HTTP/1.0 ones.
        let chunked = r.version != "HTTP/1.0"
        headers.append(chunked ? ("Transfer-Encoding", "chunked") : ("Connection", "close"))
        guard c.writeAll(Self.head(status, headers, extra: nil)) else { task.cancel(); return false }
        while let ev = up.next(timeout: 120) {
            switch ev {
            case .data(let d):
                let ok = chunked ? c.writeAll(Data(String(d.count, radix: 16).utf8) + Data("\r\n".utf8) + d + Data("\r\n".utf8))
                                 : c.writeAll(d)
                if !ok { task.cancel(); return false }
            case .done(let e):
                if e != nil { return false }            // cut short: close so the client notices
                return chunked ? c.writeAll(Data("0\r\n\r\n".utf8)) : false
            case .response: break
            }
        }
        task.cancel()
        return false
    }

    /// Collect the rest of the body; nil if it failed or passed `max` bytes.
    private func drain(_ up: UpstreamTask, max: Int) -> Data? {
        var d = Data()
        while let ev = up.next(timeout: 120) {
            switch ev {
            case .data(let x):
                d.append(x)
                if max > 0 && d.count > max { return nil }
            case .done(let e): return e == nil ? d : nil
            case .response: break
            }
        }
        return nil
    }

    private func failed(_ c: HTTPConnection, _ status: Int, _ why: String) -> Bool {
        c.respond(status, body: Data("PowerEmu could not fetch this: \(why)\n".utf8),
                  headers: ["X-PowerEmu": "1", "X-PowerEmu-Error": why.replacingOccurrences(of: "\n", with: " "),
                            "Content-Type": "text/plain; charset=utf-8"])
    }

    private static func describe(_ e: Error?, host: String) -> String {
        guard let e = e as? URLError else { return "could not reach \(host)" }
        switch e.code {
        case .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot,
             .serverCertificateNotYetValid, .clientCertificateRejected, .secureConnectionFailed:
            return "certificate: \(host): \(e.localizedDescription)"
        case .cannotFindHost, .dnsLookupFailed: return "no such host: \(host)"
        case .timedOut: return "timed out: \(host)"
        default: return "\(host): \(e.localizedDescription)"
        }
    }

    private static func head(_ status: Int, _ headers: [(String, String)], extra: String?) -> Data {
        var s = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (k, v) in headers { s += "\(k): \(v)\r\n" }
        return Data((s + "\r\n").utf8)
    }

    private static func reason(_ status: Int) -> String {
        let r = [200: "OK", 201: "Created", 202: "Accepted", 204: "No Content", 206: "Partial Content",
                 301: "Moved Permanently", 302: "Found", 303: "See Other", 304: "Not Modified",
                 307: "Temporary Redirect", 308: "Permanent Redirect", 400: "Bad Request", 401: "Unauthorized",
                 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 410: "Gone",
                 429: "Too Many Requests", 500: "Internal Server Error", 502: "Bad Gateway",
                 503: "Service Unavailable", 504: "Gateway Timeout"]
        return r[status] ?? (status < 400 ? "OK" : "Error")
    }

    private static func isText(_ mime: String) -> Bool {
        mime.hasPrefix("text/") || mime.contains("javascript") || mime.contains("json") || mime.contains("xml")
            || mime == "image/svg+xml"
    }

    /// Back to one Set-Cookie line (URLSession joins them with commas).
    private static func serialize(_ c: HTTPCookie) -> String {
        var s = "\(c.name)=\(c.value)"
        if c.domain.hasPrefix(".") { s += "; Domain=\(c.domain)" }
        s += "; Path=\(c.path)"
        if let d = c.expiresDate {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = TimeZone(identifier: "GMT")
            f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
            s += "; Expires=\(f.string(from: d))"
        }
        if c.isSecure { s += "; Secure" }
        if c.isHTTPOnly { s += "; HttpOnly" }
        if let ss = c.sameSitePolicy { s += "; SameSite=\(ss.rawValue)" }
        return s
    }

    // MARK: URLSession

    private func upstream(_ t: URLSessionTask) -> UpstreamTask? {
        lock.lock(); defer { lock.unlock() }
        return tasks[t.taskIdentifier]
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if let r = response as? HTTPURLResponse { upstream(dataTask)?.push(.response(r)) }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        upstream(dataTask)?.push(.data(data))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        upstream(task)?.push(.done(error))
    }

    /// Redirects go back to the browser, which follows them itself.
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Events from URLSession for one request, read by the connection's thread.
/// Delivery pauses while more than 8 MB wait (an old Mac reads slowly).
final class UpstreamTask: @unchecked Sendable {
    enum Event { case response(HTTPURLResponse), data(Data), done(Error?) }
    weak var task: URLSessionTask?
    private var events: [Event] = []
    private var queued = 0
    private var paused = false
    private let cond = NSCondition()

    func push(_ e: Event) {
        cond.lock()
        events.append(e)
        if case .data(let d) = e {
            queued += d.count
            if queued > 8 << 20 && !paused { paused = true; task?.suspend() }
        }
        cond.signal()
        cond.unlock()
    }

    func next(timeout: TimeInterval) -> Event? {
        cond.lock(); defer { cond.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while events.isEmpty {
            if !cond.wait(until: deadline) { return nil }
        }
        let e = events.removeFirst()
        if case .data(let d) = e {
            queued -= d.count
            if paused && queued < 2 << 20 { paused = false; task?.resume() }
        }
        return e
    }
}

/// What the old engine can take (X-PowerEmu-Engine).
struct Engine {
    var images: Set<String> = ["jpeg", "png", "gif"]
    var maxImage = 0
    var js = "es5"

    init(_ header: String?) {
        guard let header else { return }
        for part in header.split(separator: ";") {
            let kv = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "images": images = Set(kv[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
            case "max-image": maxImage = Int(kv[1]) ?? 0
            case "js": js = kv[1]
            default: break
            }
        }
    }
}

enum ImageConverter {
    /// Formats ImageIO reads that old WebKits don't.
    private static let modern: Set<String> = ["image/webp", "image/avif", "image/heic", "image/heif", "image/jxl"]

    static func candidate(mime: String, engine: Engine) -> Bool {
        if modern.contains(mime) { return !engine.images.contains(String(mime.dropFirst(6))) }
        return engine.maxImage > 0 && (mime == "image/jpeg" || mime == "image/png")
    }

    /// The converted image, its type and a description; nil to send the original.
    static func convert(_ d: Data, mime: String, engine: Engine) -> (Data, String, String)? {
        guard let src = CGImageSourceCreateWithData(d as CFData, nil), CGImageSourceGetCount(src) > 0,
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        let unsupported = modern.contains(mime) && !engine.images.contains(String(mime.dropFirst(6)))
        let tooBig = engine.maxImage > 0 && max(w, h) > engine.maxImage
        guard unsupported || tooBig else { return nil }
        let edge = tooBig ? engine.maxImage : max(w, h)
        let opts: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                     kCGImageSourceThumbnailMaxPixelSize: edge,
                                     kCGImageSourceCreateThumbnailWithTransform: true]
        guard let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let alpha = ![.none, .noneSkipFirst, .noneSkipLast].contains(img.alphaInfo)
        // PNGs stay PNG (graphics, text); photos and anything opaque become JPEG.
        let png = alpha || mime == "image/png"
        let type = png ? UTType.png : UTType.jpeg
        let out = NSMutableData()
        guard let dst = CGImageDestinationCreateWithData(out, type.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dst, img, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
        guard CGImageDestinationFinalize(dst) else { return nil }
        if !unsupported && out.length >= d.count { return nil }      // resizing didn't pay
        let newMime = png ? "image/png" : "image/jpeg"
        return (out as Data, newMime, "\(mime) -> \(newMime) \(img.width)x\(img.height)")
    }
}

/// gzip and zlib ("deflate") around Foundation's raw DEFLATE.
enum Compression {
    static func encode(_ d: Data, _ encoding: String) -> Data? {
        guard let raw = try? (d as NSData).compressed(using: .zlib) as Data else { return nil }
        var out = Data()
        if encoding == "gzip" {
            out.append(contentsOf: [0x1f, 0x8b, 8, 0, 0, 0, 0, 0, 0, 3])
            out.append(raw)
            appendLE(&out, crc32(d)); appendLE(&out, UInt32(truncatingIfNeeded: d.count))
        } else {
            out.append(contentsOf: [0x78, 0x9c])
            out.append(raw)
            let a = adler32(d)
            out.append(contentsOf: [UInt8(a >> 24), UInt8(a >> 16 & 0xff), UInt8(a >> 8 & 0xff), UInt8(a & 0xff)])
        }
        return out
    }

    private static func appendLE(_ d: inout Data, _ v: UInt32) {
        d.append(contentsOf: [UInt8(v & 0xff), UInt8(v >> 8 & 0xff), UInt8(v >> 16 & 0xff), UInt8(v >> 24)])
    }

    private static let table: [UInt32] = (0..<256).map { i -> UInt32 in
        var c = UInt32(i)
        for _ in 0..<8 { c = c & 1 != 0 ? 0xEDB88320 ^ (c >> 1) : c >> 1 }
        return c
    }

    static func crc32(_ d: Data) -> UInt32 {
        var c: UInt32 = 0xffffffff
        d.withUnsafeBytes { for b in $0 { c = table[Int((c ^ UInt32(b)) & 0xff)] ^ (c >> 8) } }
        return c ^ 0xffffffff
    }

    static func adler32(_ d: Data) -> UInt32 {
        var a: UInt32 = 1, b: UInt32 = 0
        d.withUnsafeBytes { for x in $0 { a = (a + UInt32(x)) % 65521; b = (b + a) % 65521 } }
        return b << 16 | a
    }
}

/// Hosts that serve ads and tracking, answered with 204.  Matched as the
/// host itself or any subdomain.
enum Blocklist {
    private static let hosts: Set<String> = [
        "doubleclick.net", "googlesyndication.com", "googleadservices.com", "google-analytics.com",
        "googletagmanager.com", "googletagservices.com", "adservice.google.com", "pagead2.googlesyndication.com",
        "connect.facebook.net", "scorecardresearch.com", "adnxs.com", "criteo.com", "criteo.net", "taboola.com",
        "outbrain.com", "amazon-adsystem.com", "hotjar.com", "cdn.segment.com", "quantserve.com", "chartbeat.com",
        "chartbeat.net", "moatads.com", "rubiconproject.com", "pubmatic.com", "openx.net", "casalemedia.com",
        "adsrvr.org", "bat.bing.com", "clarity.ms", "js-agent.newrelic.com", "nr-data.net", "adform.net",
        "teads.tv", "smartadserver.com", "yieldmo.com", "sharethrough.com", "33across.com", "indexww.com",
        "media.net", "zedo.com", "krxd.net", "bluekai.com", "demdex.net", "everesttech.net", "omtrdc.net",
        "mathtag.com", "tapad.com", "rlcdn.com", "agkn.com", "adsafeprotected.com", "doubleverify.com",
        "branch.io", "app-measurement.com", "mixpanel.com", "fullstory.com", "mouseflow.com", "crazyegg.com",
    ]

    /// The list's name if the host is on it.
    static func match(_ host: String) -> String? {
        var h = Substring(host)
        while true {
            if hosts.contains(String(h)) { return "ads and trackers" }
            guard let dot = h.firstIndex(of: ".") else { return nil }
            h = h[h.index(after: dot)...]
        }
    }
}
