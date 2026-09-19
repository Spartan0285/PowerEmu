import Foundation

/// The mail proxy.  An old Mac's mail program connects without encryption
/// (it can't do modern TLS) and signs in with the local password PowerEmu
/// gave it.  PowerEmu then signs in to the real provider over TLS with the
/// account's app-specific password and, from there on, relays bytes both
/// ways - the mail program is talking to the real server.
///
/// IMAP: PowerEmu answers until LOGIN / AUTHENTICATE PLAIN.
/// SMTP: PowerEmu answers until AUTH PLAIN / AUTH LOGIN.

// MARK: - The old Mac's side (a plain socket)

final class ClientConn {
    let fd: Int32
    private var buf = Data()

    init(fd: Int32) {
        self.fd = fd
        setTimeout(300)
    }

    /// Seconds a read may wait (0: forever).
    func setTimeout(_ s: Int) {
        var tv = timeval(tv_sec: s, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = read(fd, &chunk, chunk.count)
        if n <= 0 { return false }
        buf.append(contentsOf: chunk[0..<n])
        return true
    }

    /// A line without its CR LF.
    func readLine(max: Int = 65536) -> String? {
        while true {
            if let i = buf.firstIndex(of: 0x0a) {
                var line = buf[buf.startIndex..<i]
                if line.last == 0x0d { line = line.dropLast() }
                buf = Data(buf[buf.index(after: i)...])
                return String(decoding: line, as: UTF8.self)
            }
            if buf.count > max || !fill() { return nil }
        }
    }

    func readBytes(_ n: Int) -> Data? {
        while buf.count < n { if !fill() { return nil } }
        let d = buf.prefix(n)
        buf = Data(buf.dropFirst(n))
        return Data(d)
    }

    /// Whatever has been read ahead, then new data; nil at the end.
    func readSome() -> Data? {
        if !buf.isEmpty { defer { buf = Data() }; return buf }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = read(fd, &chunk, chunk.count)
        return n > 0 ? Data(chunk[0..<n]) : nil
    }

    @discardableResult
    func write(_ s: String) -> Bool { write(Data(s.utf8)) }

    @discardableResult
    func write(_ d: Data) -> Bool {
        d.withUnsafeBytes { raw in
            guard var p = raw.baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = Darwin.write(fd, p, left)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { return false }
                p += n; left -= n
            }
            return true
        }
    }

    func close() { shutdown(fd, SHUT_RDWR); Darwin.close(fd) }
}

// MARK: - The provider's side (TLS)

/// A TLS connection to a mail server through Foundation streams, which can
/// also start TLS part-way through (SMTP STARTTLS).
final class Upstream {
    private let input: InputStream
    private let output: OutputStream
    private var buf = Data()
    private let host: String
    /// POWEREMU_MAIL_INSECURE=1 skips certificate checks (testing against a
    /// local server with a self-signed certificate).
    private static let insecure = ProcessInfo.processInfo.environment["POWEREMU_MAIL_INSECURE"] == "1"

    init?(host: String, port: Int, tls: Bool) {
        var i: InputStream?, o: OutputStream?
        Stream.getStreamsToHost(withName: host, port: port, inputStream: &i, outputStream: &o)
        guard let i, let o else { return nil }
        input = i; output = o; self.host = host
        if tls { secure() }
        input.open(); output.open()
    }

    /// Switch the connection to TLS (at once, or after STARTTLS).
    func secure() {
        let key = Stream.PropertyKey(kCFStreamPropertySSLSettings as String)
        var settings: [String: Any] = [kCFStreamSSLPeerName as String: host]
        if Self.insecure { settings[kCFStreamSSLValidatesCertificateChain as String] = false }
        input.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        output.setProperty(StreamSocketSecurityLevel.negotiatedSSL.rawValue, forKey: .socketSecurityLevelKey)
        input.setProperty(settings, forKey: key)
        output.setProperty(settings, forKey: key)
    }

    var error: String? {
        if let e = input.streamError ?? output.streamError { return e.localizedDescription }
        return nil
    }

    private func fill() -> Bool {
        var chunk = [UInt8](repeating: 0, count: 16384)
        let n = input.read(&chunk, maxLength: chunk.count)
        if n <= 0 { return false }
        buf.append(contentsOf: chunk[0..<n])
        return true
    }

    func readLine() -> String? {
        while true {
            if let i = buf.firstIndex(of: 0x0a) {
                var line = buf[buf.startIndex..<i]
                if line.last == 0x0d { line = line.dropLast() }
                buf = Data(buf[buf.index(after: i)...])
                return String(decoding: line, as: UTF8.self)
            }
            if buf.count > 1 << 20 || !fill() { return nil }
        }
    }

    func readSome() -> Data? {
        if !buf.isEmpty { defer { buf = Data() }; return buf }
        var chunk = [UInt8](repeating: 0, count: 65536)
        let n = input.read(&chunk, maxLength: chunk.count)
        return n > 0 ? Data(chunk[0..<n]) : nil
    }

    @discardableResult
    func write(_ s: String) -> Bool { write(Data(s.utf8)) }

    @discardableResult
    func write(_ d: Data) -> Bool {
        d.withUnsafeBytes { raw in
            guard var p = raw.bindMemory(to: UInt8.self).baseAddress else { return true }
            var left = raw.count
            while left > 0 {
                let n = output.write(p, maxLength: left)
                if n <= 0 { return false }
                p += n; left -= n
            }
            return true
        }
    }

    func close() { input.close(); output.close() }
}

/// Copy bytes both ways until either side closes.
private func relay(_ c: ClientConn, _ u: Upstream) {
    c.setTimeout(0)                      // IMAP IDLE can sit for half an hour
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        while let d = u.readSome() { if !c.write(d) { break } }
        shutdown(c.fd, SHUT_RDWR)
        done.signal()
    }
    while let d = c.readSome() { if !u.write(d) { break } }
    u.close()
    done.wait()
    c.close()
}

private func b64(_ s: String) -> String { Data(s.utf8).base64EncodedString() }
private func unb64(_ s: String) -> String? {
    Data(base64Encoded: s.trimmingCharacters(in: .whitespaces)).map { String(decoding: $0, as: UTF8.self) }
}

/// SASL PLAIN: [authzid] NUL authcid NUL password.
private func parsePlain(_ s: String) -> (String, String)? {
    guard let d = Data(base64Encoded: s.trimmingCharacters(in: .whitespaces)) else { return nil }
    let parts = d.split(separator: 0, omittingEmptySubsequences: false)
    guard parts.count == 3 else { return nil }
    return (String(decoding: parts[1], as: UTF8.self), String(decoding: parts[2], as: UTF8.self))
}

// MARK: - IMAP

final class IMAPProxySession {
    private let c: ClientConn
    private let peer: String
    private let accounts: AccountStore
    private let note: @Sendable (String) -> Void

    init(fd: Int32, peer: String, accounts: AccountStore, note: @escaping @Sendable (String) -> Void) {
        c = ClientConn(fd: fd); self.peer = peer; self.accounts = accounts; self.note = note
    }

    private static let capabilities = "IMAP4rev1 AUTH=PLAIN"

    func run() {
        c.write("* OK [CAPABILITY \(Self.capabilities)] PowerEmu mail proxy ready\r\n")
        while let (tag, cmd, args) = readCommand() {
            switch cmd {
            case "CAPABILITY":
                c.write("* CAPABILITY \(Self.capabilities)\r\n\(tag) OK CAPABILITY completed\r\n")
            case "NOOP":
                c.write("\(tag) OK NOOP completed\r\n")
            case "ID":
                c.write("* ID (\"name\" \"PowerEmu\")\r\n\(tag) OK ID completed\r\n")
            case "LOGOUT":
                c.write("* BYE PowerEmu mail proxy\r\n\(tag) OK LOGOUT completed\r\n")
                c.close(); return
            case "STARTTLS":
                c.write("\(tag) NO Connect without SSL; PowerEmu adds it on the way out\r\n")
            case "LOGIN":
                guard args.count >= 2 else { c.write("\(tag) BAD LOGIN needs a name and a password\r\n"); continue }
                if signIn(tag, args[0], args[1]) { return }
            case "AUTHENTICATE":
                guard args.first?.uppercased() == "PLAIN" else {
                    c.write("\(tag) NO Only AUTHENTICATE PLAIN\r\n"); continue
                }
                var resp = args.count > 1 ? args[1] : nil
                if resp == nil {
                    c.write("+ \r\n")
                    resp = c.readLine()
                }
                guard let r = resp, r != "*", let (u, p) = parsePlain(r) else {
                    c.write("\(tag) BAD AUTHENTICATE cancelled\r\n"); continue
                }
                if signIn(tag, u, p) { return }
            default:
                c.write("\(tag) BAD Sign in first\r\n")
            }
        }
        c.close()
    }

    /// Returns true once the session has been handed to the relay (or ended).
    private func signIn(_ tag: String, _ user: String, _ pass: String) -> Bool {
        guard let a = accounts.authenticate(user: user, password: pass) else {
            note("Mail: wrong name or password from \(peer) (\(user))")
            Thread.sleep(forTimeInterval: 1)
            c.write("\(tag) NO [AUTHENTICATIONFAILED] Use the name and password shown in PowerEmu's Service Hub\r\n")
            return false
        }
        guard let pw = Secrets.get(Secrets.providerPasswordKey(a)) else {
            c.write("\(tag) NO [UNAVAILABLE] PowerEmu has no password for \(a.email)\r\n")
            return false
        }
        switch Self.connect(a, password: pw) {
        case .failure(let msg):
            note("Mail: \(a.email) - \(msg)")
            c.write("\(tag) NO [UNAVAILABLE] \(msg)\r\n")
            return false
        case .success(let (u, okLine)):
            // Pass on the server's capabilities if it gave them with its OK.
            var reply = "\(tag) OK LOGIN completed"
            if let r = okLine.range(of: "[CAPABILITY ") , let end = okLine[r.upperBound...].firstIndex(of: "]") {
                reply = "\(tag) OK [CAPABILITY \(okLine[r.upperBound..<end])] LOGIN completed"
            }
            c.write(reply + "\r\n")
            note("Mail: \(peer) reading \(a.email)")
            relay(c, u)
            return true
        }
    }

    enum Result { case success((Upstream, String)), failure(String) }

    /// Sign in to the provider: TLS, then AUTHENTICATE PLAIN.
    static func connect(_ a: MailAccount, password: String) -> Result {
        guard let u = Upstream(host: a.imapHost, port: a.imapPort, tls: true) else { return .failure("Could not reach \(a.imapHost)") }
        guard let greeting = u.readLine() else {
            return .failure("\(a.imapHost) did not answer\(u.error.map { ": " + $0 } ?? "")")
        }
        guard greeting.hasPrefix("* OK") else { u.close(); return .failure("\(a.imapHost): \(greeting)") }
        u.write("P1 AUTHENTICATE PLAIN\r\n")
        while let line = u.readLine() {
            if line.hasPrefix("+") {
                u.write(b64("\0\(a.login)\0\(password)") + "\r\n")
            } else if line.hasPrefix("P1 OK") {
                return .success((u, line))
            } else if line.hasPrefix("P1 ") {
                u.close()
                return .failure("\(a.imapHost) refused the sign-in: \(line.dropFirst(3))")
            }
        }
        u.close()
        return .failure("\(a.imapHost) closed the connection\(u.error.map { ": " + $0 } ?? "")")
    }

    /// One command: tag, upper-cased name and its arguments (atoms, quoted
    /// strings and literals, which are asked for with "+").
    private func readCommand() -> (String, String, [String])? {
        var tokens: [String] = []
        guard var line = c.readLine() else { return nil }
        while true {
            var rest = Substring(line)
            var literal: Int? = nil
            while !rest.isEmpty {
                rest = rest.drop(while: { $0 == " " })
                guard let ch = rest.first else { break }
                if ch == "\"" {
                    var s = "", i = rest.index(after: rest.startIndex), esc = false
                    while i < rest.endIndex {
                        let x = rest[i]
                        if esc { s.append(x); esc = false }
                        else if x == "\\" { esc = true }
                        else if x == "\"" { break }
                        else { s.append(x) }
                        i = rest.index(after: i)
                    }
                    tokens.append(s)
                    rest = i < rest.endIndex ? rest[rest.index(after: i)...] : ""
                } else if ch == "{", rest.hasSuffix("}"), let n = Int(rest.dropFirst().dropLast().replacingOccurrences(of: "+", with: "")) {
                    if !rest.hasSuffix("+}") { c.write("+ Ready\r\n") }
                    literal = n
                    rest = ""
                } else {
                    let end = rest.firstIndex(of: " ") ?? rest.endIndex
                    tokens.append(String(rest[..<end]))
                    rest = rest[end...]
                }
            }
            guard let n = literal else { break }
            guard n < 65536, let d = c.readBytes(n), let more = c.readLine() else { return nil }
            tokens.append(String(decoding: d, as: UTF8.self))
            line = more
        }
        guard tokens.count >= 2 else {
            c.write("\(tokens.first ?? "*") BAD Command missing\r\n")
            return readCommand()
        }
        return (tokens[0], tokens[1].uppercased(), Array(tokens.dropFirst(2)))
    }
}

// MARK: - SMTP

final class SMTPProxySession {
    private let c: ClientConn
    private let peer: String
    private let accounts: AccountStore
    private let note: @Sendable (String) -> Void

    init(fd: Int32, peer: String, accounts: AccountStore, note: @escaping @Sendable (String) -> Void) {
        c = ClientConn(fd: fd); self.peer = peer; self.accounts = accounts; self.note = note
    }

    func run() {
        c.write("220 PowerEmu mail proxy ESMTP\r\n")
        while let line = c.readLine() {
            let verb = line.split(separator: " ").first.map { $0.uppercased() } ?? ""
            switch verb {
            case "EHLO":
                // AUTH= too, for mail programs from before RFC 2554's final form.
                c.write("250-PowerEmu\r\n250-AUTH PLAIN LOGIN\r\n250-AUTH=PLAIN LOGIN\r\n250-8BITMIME\r\n250 SIZE 36700160\r\n")
            case "HELO":
                c.write("250 PowerEmu\r\n")
            case "NOOP", "RSET":
                c.write("250 OK\r\n")
            case "QUIT":
                c.write("221 Bye\r\n"); c.close(); return
            case "STARTTLS":
                c.write("454 Connect without SSL; PowerEmu adds it on the way out\r\n")
            case "AUTH":
                let f = line.split(separator: " ").map(String.init)
                var user: String?, pass: String?
                switch f.count > 1 ? f[1].uppercased() : "" {
                case "PLAIN":
                    var r = f.count > 2 ? f[2] : nil
                    if r == nil { c.write("334 \r\n"); r = c.readLine() }
                    if let r, let (u, p) = parsePlain(r) { user = u; pass = p }
                case "LOGIN":
                    if f.count > 2 { user = unb64(f[2]) } else { c.write("334 VXNlcm5hbWU6\r\n"); user = c.readLine().flatMap(unb64) }
                    c.write("334 UGFzc3dvcmQ6\r\n")
                    pass = c.readLine().flatMap(unb64)
                default:
                    c.write("504 Use AUTH PLAIN or AUTH LOGIN\r\n"); continue
                }
                guard let user, let pass else { c.write("501 Malformed authentication\r\n"); continue }
                if signIn(user, pass) { return }
            case "MAIL", "RCPT", "DATA":
                c.write("530 5.7.0 Authentication required: use the name and password shown in PowerEmu\r\n")
            default:
                c.write("502 Command not implemented\r\n")
            }
        }
        c.close()
    }

    private func signIn(_ user: String, _ pass: String) -> Bool {
        guard let a = accounts.authenticate(user: user, password: pass) else {
            note("Mail: wrong name or password from \(peer) (\(user)), sending")
            Thread.sleep(forTimeInterval: 1)
            c.write("535 5.7.8 Use the name and password shown in PowerEmu's Service Hub\r\n")
            return false
        }
        guard let pw = Secrets.get(Secrets.providerPasswordKey(a)) else {
            c.write("454 4.7.0 PowerEmu has no password for \(a.email)\r\n"); return false
        }
        switch Self.connect(a, password: pw) {
        case .failure(let msg):
            note("Mail: \(a.email) - \(msg)")
            c.write("454 4.7.0 \(msg)\r\n")
            return false
        case .success(let u):
            c.write("235 2.7.0 Authentication successful\r\n")
            note("Mail: \(peer) sending as \(a.email)")
            relay(c, u)
            return true
        }
    }

    enum Result { case success(Upstream), failure(String) }

    /// A reply: its code and the text of all its lines.
    static func reply(_ u: Upstream) -> (Int, String)? {
        var text: [String] = []
        while let line = u.readLine() {
            text.append(String(line.dropFirst(4)))
            if line.count < 4 || line[line.index(line.startIndex, offsetBy: 3)] != "-" {
                return (Int(line.prefix(3)) ?? 0, text.joined(separator: " "))
            }
        }
        return nil
    }

    /// Sign in to the provider: TLS (at once or via STARTTLS), then AUTH PLAIN.
    static func connect(_ a: MailAccount, password: String) -> Result {
        let host = a.smtpHost
        guard let u = Upstream(host: host, port: a.smtpPort, tls: a.smtpSecurity == .tls) else {
            return .failure("Could not reach \(host)")
        }
        func fail(_ s: String) -> Result { u.close(); return .failure(s) }
        guard let (g, gt) = reply(u) else { return fail("\(host) did not answer\(u.error.map { ": " + $0 } ?? "")") }
        guard g == 220 else { return fail("\(host): \(gt)") }
        u.write("EHLO [127.0.0.1]\r\n")
        guard let (e, et) = reply(u), e == 250 else { return fail("\(host) refused EHLO") }
        if a.smtpSecurity == .starttls {
            guard et.uppercased().contains("STARTTLS") else { return fail("\(host) does not offer STARTTLS") }
            u.write("STARTTLS\r\n")
            guard let (s, st) = reply(u), s == 220 else { return fail("\(host) refused STARTTLS") }
            _ = st
            u.secure()
            u.write("EHLO [127.0.0.1]\r\n")
            guard let (e2, _) = reply(u), e2 == 250 else {
                return fail("TLS with \(host) failed\(u.error.map { ": " + $0 } ?? "")")
            }
        }
        u.write("AUTH PLAIN " + b64("\0\(a.outgoingLogin)\0\(password)") + "\r\n")
        guard let (r, rt) = reply(u) else { return fail("\(host) closed the connection") }
        guard r == 235 else { return fail("\(host) refused the sign-in: \(r) \(rt)") }
        return .success(u)
    }
}

// MARK: - Checking an account

enum MailAccountCheck {
    /// App-specific passwords are letters and dashes; anything pasted
    /// around them (spaces, a line break) is dropped.
    static func clean(_ password: String) -> String {
        password.filter { !$0.isWhitespace && !$0.isNewline }
    }

    /// Sign in to both servers, trying the account's possible sign-in names.
    /// Returns the account with the names that worked, and nil or what went
    /// wrong.
    static func run(_ account: MailAccount, password: String) async -> (MailAccount, String?) {
        await withCheckedContinuation { cont in
            Thread.detachNewThread {
                var a = account
                var problems: [String] = []
                var imapError = "", smtpError = ""
                var imapOK = false, smtpOK = false
                for name in account.loginCandidates {
                    var t = a; t.login = name
                    switch IMAPProxySession.connect(t, password: password) {
                    case .success(let (u, _)):
                        u.write("P2 LOGOUT\r\n"); u.close()
                        a.login = name; imapOK = true
                    case .failure(let m): imapError = m
                    }
                    if imapOK { break }
                }
                // SMTP: the whole address first, then the others.
                let smtpNames = [account.email] + account.loginCandidates.filter { $0 != account.email }
                for name in smtpNames {
                    var t = a; t.smtpLogin = name
                    switch SMTPProxySession.connect(t, password: password) {
                    case .success(let u):
                        u.write("QUIT\r\n"); u.close()
                        a.smtpLogin = name == a.login ? nil : name; smtpOK = true
                    case .failure(let m): smtpError = m
                    }
                    if smtpOK { break }
                }
                let tried = account.loginCandidates.map { "“\($0)”" }.joined(separator: " and ")
                if !imapOK { problems.append("Incoming mail: " + imapError) }
                if !smtpOK { problems.append("Outgoing mail: " + smtpError) }
                if !imapOK && !smtpOK && imapError.contains("refused the sign-in") {
                    problems.append("Tried signing in as \(tried). If that is right, the app-specific password is probably mistyped or revoked: it looks like xxxx-xxxx-xxxx-xxxx. Make a new one and paste it here.")
                }
                cont.resume(returning: (a, problems.isEmpty ? nil : problems.joined(separator: "\n")))
            }
        }
    }
}
