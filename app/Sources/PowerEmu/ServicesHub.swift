import Foundation
import Security

/// The Service Hub: things this Mac does for old Macs - the virtual ones,
/// and (when allowed) real ones on the network.  The first is a mail proxy:
/// old mail programs speak plain IMAP and SMTP to PowerEmu, which signs in
/// to the real provider over modern TLS and then relays (MailProxy.swift).
///
/// Virtual Macs reach the services at 10.0.2.100 (guestfwd rules to the Unix
/// sockets below, see VMRunner); other Macs at this Mac's name and the
/// network ports.

// MARK: - Model

struct MailAccount: Codable, Hashable, Identifiable {
    enum Provider: String, Codable, CaseIterable, Identifiable {
        case icloud, gmail, yahoo, fastmail, other
        var id: String { rawValue }
        var title: String {
            switch self {
            case .icloud: return "iCloud"
            case .gmail: return "Gmail"
            case .yahoo: return "Yahoo"
            case .fastmail: return "Fastmail"
            case .other: return "Other"
            }
        }
        /// Where to create the app-specific password the proxy signs in with.
        var passwordHelp: String {
            switch self {
            case .icloud: return "account.apple.com → Sign-In and Security → App-Specific Passwords"
            case .gmail: return "myaccount.google.com/apppasswords (needs 2-Step Verification)"
            case .yahoo: return "Yahoo Account Security → Generate app password"
            case .fastmail: return "Fastmail Settings → Privacy & Security → App passwords"
            case .other: return "Use a password your provider allows for IMAP and SMTP"
            }
        }
    }
    enum Security: String, Codable, CaseIterable { case tls, starttls }

    var id = UUID()
    var provider: Provider
    var email: String
    /// Sign-in name at the provider (usually the address).
    var login: String
    var imapHost: String
    var imapPort = 993
    var smtpHost: String
    var smtpPort = 465
    var smtpSecurity = Security.tls

    /// The name old Macs sign in to PowerEmu with.
    var localUser: String { email }

    static func preset(_ p: Provider, email: String) -> MailAccount {
        switch p {
        case .icloud:
            // iCloud's sign-in name is the part before @ for @icloud.com/@me.com/@mac.com.
            let lower = email.lowercased()
            let login = ["@icloud.com", "@me.com", "@mac.com"].contains { lower.hasSuffix($0) }
                ? String(email.split(separator: "@").first ?? "") : email
            return MailAccount(provider: p, email: email, login: login, imapHost: "imap.mail.me.com",
                               smtpHost: "smtp.mail.me.com", smtpPort: 587, smtpSecurity: .starttls)
        case .gmail:
            return MailAccount(provider: p, email: email, login: email, imapHost: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        case .yahoo:
            return MailAccount(provider: p, email: email, login: email, imapHost: "imap.mail.yahoo.com", smtpHost: "smtp.mail.yahoo.com")
        case .fastmail:
            return MailAccount(provider: p, email: email, login: email, imapHost: "imap.fastmail.com", smtpHost: "smtp.fastmail.com")
        case .other:
            let domain = email.split(separator: "@").last.map(String.init) ?? ""
            return MailAccount(provider: p, email: email, login: email, imapHost: "imap." + domain, smtpHost: "smtp." + domain)
        }
    }
}

struct ServicesConfig: Codable {
    var mailEnabled = true
    /// Let real Macs on the network use the services, not just virtual ones.
    var allowNetwork = false
    var accounts: [MailAccount] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mailEnabled = try c.decodeIfPresent(Bool.self, forKey: .mailEnabled) ?? true
        allowNetwork = try c.decodeIfPresent(Bool.self, forKey: .allowNetwork) ?? false
        accounts = try c.decodeIfPresent([MailAccount].self, forKey: .accounts) ?? []
    }
}

// MARK: - Secrets

/// Passwords live in the login keychain.  POWEREMU_TEST_SECRETS=file keeps
/// them in a plist instead (development only: rebuilt ad-hoc-signed copies
/// of the app would otherwise be asked for keychain access every time).
enum Secrets {
    private static let service = "PowerEmu"
    private static let testFile = ProcessInfo.processInfo.environment["POWEREMU_TEST_SECRETS"]
    private static let lock = NSLock()

    static func get(_ key: String) -> String? {
        if let f = testFile {
            lock.lock(); defer { lock.unlock() }
            return (NSDictionary(contentsOfFile: f) as? [String: String])?[key]
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecReturnData as String: true]
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
        return String(data: d, encoding: .utf8)
    }

    static func set(_ value: String, for key: String) {
        if let f = testFile {
            lock.lock(); defer { lock.unlock() }
            var d = (NSDictionary(contentsOfFile: f) as? [String: String]) ?? [:]
            d[key] = value
            (d as NSDictionary).write(toFile: f, atomically: true)
            chmod(f, 0o600)
            return
        }
        delete(key)
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key, kSecAttrLabel as String: "PowerEmu: \(key)",
                                kSecValueData as String: Data(value.utf8)]
        SecItemAdd(q as CFDictionary, nil)
    }

    static func delete(_ key: String) {
        if let f = testFile {
            lock.lock(); defer { lock.unlock() }
            var d = (NSDictionary(contentsOfFile: f) as? [String: String]) ?? [:]
            d[key] = nil
            (d as NSDictionary).write(toFile: f, atomically: true)
            return
        }
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                kSecAttrAccount as String: key]
        SecItemDelete(q as CFDictionary)
    }

    static func providerPasswordKey(_ a: MailAccount) -> String { "mail.\(a.id.uuidString).provider" }
    static func localPasswordKey(_ a: MailAccount) -> String { "mail.\(a.id.uuidString).local" }

    /// A password that is easy to type on an old keyboard: four groups of
    /// four lower-case letters.
    static func newLocalPassword() -> String {
        let letters = Array("abcdefghjkmnpqrstuvwxyz")
        return (0..<4).map { _ in String((0..<4).map { _ in letters.randomElement()! }) }.joined(separator: "-")
    }
}

// MARK: - Hub

@MainActor
final class ServicesHub: ObservableObject {
    static let shared = ServicesHub()

    @Published private(set) var config = ServicesConfig()
    /// Recent activity, newest last, for the Service Hub window.
    @Published private(set) var log: [String] = []

    /// Unix sockets the virtual Macs' guestfwd rules point at.
    nonisolated static let imapSocket = NSTemporaryDirectory() + "poweremu-imap.sock"
    nonisolated static let smtpSocket = NSTemporaryDirectory() + "poweremu-smtp.sock"
    /// Ports for real Macs on the network (above 1024: no privileges needed).
    nonisolated static let networkIMAPPort: UInt16 = 1143
    nonisolated static let networkSMTPPort: UInt16 = 1025

    /// What the proxy sessions (on their own threads) read.
    nonisolated let accounts = AccountStore()
    private var listeners: [SocketListener] = []

    private var configURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Services.plist")
    }

    private init() {
        if let d = try? Data(contentsOf: configURL), let c = try? PropertyListDecoder().decode(ServicesConfig.self, from: d) {
            config = c
        }
    }

    func start() {
        restartListeners()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: configURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        try? enc.encode(config).write(to: configURL, options: .atomic)
    }

    private func restartListeners() {
        listeners.forEach { $0.stop() }
        listeners = []
        accounts.set(config.accounts)
        guard config.mailEnabled else { return }
        let store = accounts
        let note: @Sendable (String) -> Void = { s in Task { @MainActor in ServicesHub.shared.note(s) } }
        let imap: @Sendable (Int32, String) -> Void = { fd, peer in IMAPProxySession(fd: fd, peer: peer, accounts: store, note: note).run() }
        let smtp: @Sendable (Int32, String) -> Void = { fd, peer in SMTPProxySession(fd: fd, peer: peer, accounts: store, note: note).run() }
        var l: [SocketListener] = []
        l.append(SocketListener(unixPath: Self.imapSocket, name: "virtual Mac", handler: imap))
        l.append(SocketListener(unixPath: Self.smtpSocket, name: "virtual Mac", handler: smtp))
        if config.allowNetwork {
            l.append(SocketListener(tcpPort: Self.networkIMAPPort, handler: imap))
            l.append(SocketListener(tcpPort: Self.networkSMTPPort, handler: smtp))
        }
        for x in l {
            do { try x.start() } catch { note("Could not listen for \(x.name): \(error.localizedDescription)") }
        }
        listeners = l
    }

    func note(_ s: String) {
        let f = DateFormatter()
        f.timeStyle = .medium
        log.append("\(f.string(from: Date()))  \(s)")
        if log.count > 200 { log.removeFirst(log.count - 200) }
    }

    // MARK: settings

    func setMailEnabled(_ on: Bool) { config.mailEnabled = on; save(); restartListeners() }
    func setAllowNetwork(_ on: Bool) { config.allowNetwork = on; save(); restartListeners() }

    /// Add an account after its provider sign-in has been checked.
    func add(_ a: MailAccount, providerPassword: String) {
        Secrets.set(providerPassword, for: Secrets.providerPasswordKey(a))
        if Secrets.get(Secrets.localPasswordKey(a)) == nil {
            Secrets.set(Secrets.newLocalPassword(), for: Secrets.localPasswordKey(a))
        }
        config.accounts.removeAll { $0.id == a.id }
        config.accounts.append(a)
        save()
        accounts.set(config.accounts)
        note("Added \(a.email)")
    }

    func remove(_ a: MailAccount) {
        config.accounts.removeAll { $0.id == a.id }
        Secrets.delete(Secrets.providerPasswordKey(a))
        Secrets.delete(Secrets.localPasswordKey(a))
        save()
        accounts.set(config.accounts)
    }

    func localPassword(_ a: MailAccount) -> String { Secrets.get(Secrets.localPasswordKey(a)) ?? "" }

    func newLocalPassword(_ a: MailAccount) {
        Secrets.set(Secrets.newLocalPassword(), for: Secrets.localPasswordKey(a))
        objectWillChange.send()
    }

    /// This Mac's Bonjour name, for settings on other Macs.
    nonisolated static var hostName: String {
        let h = ProcessInfo.processInfo.hostName
        return h.hasSuffix(".local") ? h : (h.split(separator: ".").first.map { $0 + ".local" } ?? h)
    }
}

/// The accounts, readable from the proxy threads.
final class AccountStore: @unchecked Sendable {
    private let lock = NSLock()
    private var list: [MailAccount] = []

    func set(_ a: [MailAccount]) { lock.lock(); list = a; lock.unlock() }

    /// The account an old Mac signed in to PowerEmu as, if the password is right.
    func authenticate(user: String, password: String) -> MailAccount? {
        lock.lock(); let all = list; lock.unlock()
        guard let a = all.first(where: { $0.localUser.caseInsensitiveCompare(user) == .orderedSame }),
              let want = Secrets.get(Secrets.localPasswordKey(a)) else { return nil }
        // Compare without an early exit.
        let x = Array(want.utf8), y = Array(password.utf8)
        guard x.count == y.count else { return nil }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0 ? a : nil
    }
}

// MARK: - Listening

/// Accepts connections on a Unix socket (virtual Macs) or a TCP port (the
/// network) and runs `handler` for each on its own thread.
final class SocketListener: @unchecked Sendable {
    let name: String
    private let unixPath: String?
    private let port: UInt16
    private let handler: @Sendable (Int32, String) -> Void
    private var fd: Int32 = -1

    init(unixPath: String, name: String, handler: @escaping @Sendable (Int32, String) -> Void) {
        self.unixPath = unixPath; self.port = 0; self.name = name; self.handler = handler
    }

    init(tcpPort: UInt16, handler: @escaping @Sendable (Int32, String) -> Void) {
        self.unixPath = nil; self.port = tcpPort; self.name = "port \(tcpPort)"; self.handler = handler
    }

    func start() throws {
        if let path = unixPath {
            unlink(path)
            fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            let bytes = Array(path.utf8)
            guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { throw POSIXError(.ENAMETOOLONG) }
            withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            guard ok == 0 else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        } else {
            fd = socket(AF_INET, SOCK_STREAM, 0)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(port.bigEndian)
            addr.sin_addr.s_addr = INADDR_ANY
            let ok = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            guard ok == 0 else { close(fd); throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        guard listen(fd, 16) == 0 else { close(fd); throw POSIXError(.EIO) }
        let lfd = fd, handler = self.handler, isUnix = unixPath != nil, label = name
        let t = Thread {
            while true {
                var sa = sockaddr_storage()
                var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
                let c = withUnsafeMutablePointer(to: &sa) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(lfd, $0, &len) }
                }
                if c < 0 { if errno == EINTR { continue }; return }
                var one: Int32 = 1
                setsockopt(c, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
                var peer = label
                if !isUnix, sa.ss_family == sa_family_t(AF_INET) {
                    peer = withUnsafePointer(to: &sa) {
                        $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { String(cString: inet_ntoa($0.pointee.sin_addr)) }
                    }
                }
                Thread.detachNewThread { handler(c, peer) }
            }
        }
        t.name = "PowerEmu services \(name)"
        t.start()
    }

    func stop() {
        if fd >= 0 { shutdown(fd, SHUT_RDWR); close(fd); fd = -1 }
        if let p = unixPath { unlink(p) }
    }
}
