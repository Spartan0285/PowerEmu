import AppKit
import Foundation
import Security

/// Trust checks for locally generated guest-app launcher bundles.
///
/// The distributed helper template remains Developer ID signed. A generated
/// per-app bundle may be ad-hoc signed so it can carry a stable Dock identity
/// and icon; its identity is pinned to the verified template and generated
/// CodeDirectory hash in an owner-only receipt beside the bundle.
enum GuestLauncherTrust {
    static let templateIdentifier = "com.spartan0285.poweremu.guestapp.template"
    static let developerTeamIdentifier = "7B2D3VV69V"
    static let receiptFilename = "code-receipt.plist"
    private static let developerIDRequirement = "anchor apple generic and certificate leaf[subject.OU] = \"7B2D3VV69V\""
    // SecCodeSignatureFlags.kSecCodeSignatureAdhoc (Security/SecCode.h).
    private static let adHocSignatureFlag: UInt32 = 0x0002
    private static let hostCheckLock = NSLock()
    private static var verifiedHostTeams: [String: (fingerprint: String, team: String)] = [:]

    enum TrustError: LocalizedError {
        case invalidBundle
        case invalidSignature(String)
        case wrongDeveloper
        case wrongTemplate
        case notAdHoc
        case receiptUnsafe
        case receiptMismatch
        case processMismatch

        var errorDescription: String? {
            switch self {
            case .invalidBundle: return "The guest launcher bundle is invalid."
            case .invalidSignature(let detail): return "The guest launcher signature could not be verified: \(detail)."
            case .wrongDeveloper: return "The guest launcher template was not signed by PowerEmu’s developer."
            case .wrongTemplate: return "This is not the expected PowerEmu guest launcher template."
            case .notAdHoc: return "The generated guest launcher is not locally ad-hoc signed."
            case .receiptUnsafe: return "The guest launcher trust receipt is unsafe or unreadable."
            case .receiptMismatch: return "The guest launcher does not match its trust receipt."
            case .processMismatch: return "The running guest launcher does not match its trusted identity."
            }
        }
    }

    struct Receipt: Codable, Equatable {
        let version: Int
        let stableID: String
        let executablePath: String
        let bundleIdentifier: String
        let sourceCDHash: Data
        let cdHash: Data
    }

    /// Verifies the immutable distributed template and returns its CodeDirectory hash.
    static func verifyTemplate(templateURL: URL, hostApplicationURL: URL) throws -> Data {
        let template = try staticCode(at: templateURL)
        try checkDeveloperID(template, at: templateURL)
        let templateInfo = try signingInfo(template)
        let templateTeam = templateInfo[kSecCodeInfoTeamIdentifier as String] as? String
        let hostTeam = try verifiedHostTeam(at: hostApplicationURL)
        guard templateTeam == developerTeamIdentifier,
              hostTeam == developerTeamIdentifier,
              templateTeam == hostTeam else { throw TrustError.wrongDeveloper }
        guard templateInfo[kSecCodeInfoIdentifier as String] as? String == templateIdentifier else {
            throw TrustError.wrongTemplate
        }
        guard let hash = templateInfo[kSecCodeInfoUnique as String] as? Data,
              validHash(hash) else { throw TrustError.invalidSignature("missing template CDHash") }
        return hash
    }

    /// Pins a locally ad-hoc-signed generated app to the verified source template.
    static func makeReceipt(applicationURL: URL, installedApplicationURL: URL,
                            stableIdentifier: String, sourceCDHash: Data) throws -> Receipt {
        guard validStableIdentifier(stableIdentifier), validHash(sourceCDHash),
              applicationURL.pathExtension == "app",
              installedApplicationURL.pathExtension == "app" else { throw TrustError.invalidBundle }
        let code = try staticCode(at: applicationURL)
        try checkStrict(code, at: applicationURL)
        let info = try signingInfo(code)
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & adHocSignatureFlag != 0,
              info[kSecCodeInfoTeamIdentifier as String] == nil else { throw TrustError.notAdHoc }
        guard let hash = info[kSecCodeInfoUnique as String] as? Data, validHash(hash),
              let identifier = info[kSecCodeInfoIdentifier as String] as? String,
              identifier == generatedIdentifier(for: stableIdentifier) else {
            throw TrustError.invalidSignature("generated bundle identifier mismatch")
        }
        let bundle = Bundle(url: applicationURL)
        guard let executableName = bundle?.executableURL?.lastPathComponent,
              !executableName.isEmpty else { throw TrustError.invalidBundle }
        return Receipt(version: 1, stableID: stableIdentifier,
                      executablePath: canonical(installedApplicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
                        .appendingPathComponent(executableName)),
                      bundleIdentifier: identifier, sourceCDHash: sourceCDHash, cdHash: hash)
    }

    /// Atomically saves a bounded receipt into the existing owner-only launcher directory.
    static func saveReceipt(_ receipt: Receipt, to directory: URL) throws {
        guard validReceiptFields(receipt) else { throw TrustError.receiptUnsafe }
        let data = try PropertyListEncoder().encode(receipt)
        guard data.count <= 16 * 1024 else { throw TrustError.receiptUnsafe }
        let directoryFD = try openSafeDirectory(directory)
        defer { close(directoryFD) }
        var previous = stat()
        if fstatat(directoryFD, receiptFilename, &previous, AT_SYMLINK_NOFOLLOW) == 0 {
            guard (previous.st_mode & S_IFMT) == S_IFREG,
                  previous.st_uid == geteuid(), (previous.st_mode & 0o777) == 0o600 else {
                throw TrustError.receiptUnsafe
            }
        } else if errno != ENOENT {
            throw TrustError.receiptUnsafe
        }
        let temporaryName = ".receipt-\(UUID().uuidString).tmp"
        let fd = openat(directoryFD, temporaryName, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw TrustError.receiptUnsafe }
        var keepTemporary = true
        defer { close(fd); if keepTemporary { _ = unlinkat(directoryFD, temporaryName, 0) } }
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { throw TrustError.receiptUnsafe }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base.advanced(by: offset), raw.count - offset)
                guard written > 0 else { throw TrustError.receiptUnsafe }
                offset += written
            }
        }
        guard fsync(fd) == 0,
              renameat(directoryFD, temporaryName, directoryFD, receiptFilename) == 0,
              fsync(directoryFD) == 0 else { throw TrustError.receiptUnsafe }
        keepTemporary = false
    }

    /// Loads and validates the receipt, then verifies the installed bundle still has its pinned signature.
    static func loadReceipt(from directory: URL, applicationURL: URL,
                            stableIdentifier: String, sourceCDHash: Data) throws -> Receipt {
        guard validStableIdentifier(stableIdentifier), validHash(sourceCDHash) else { throw TrustError.receiptUnsafe }
        let dirFD = try openSafeDirectory(directory)
        defer { close(dirFD) }
        var st = stat()
        guard fstatat(dirFD, receiptFilename, &st, AT_SYMLINK_NOFOLLOW) == 0,
              (st.st_mode & S_IFMT) == S_IFREG,
              st.st_uid == geteuid(), (st.st_mode & 0o777) == 0o600,
              st.st_size > 0, st.st_size <= 16 * 1024 else { throw TrustError.receiptUnsafe }
        let fd = openat(dirFD, receiptFilename, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw TrustError.receiptUnsafe }
        defer { close(fd) }
        var actual = stat()
        guard fstat(fd, &actual) == 0, actual.st_ino == st.st_ino, actual.st_size == st.st_size,
              actual.st_uid == geteuid(), (actual.st_mode & S_IFMT) == S_IFREG,
              (actual.st_mode & 0o777) == 0o600 else { throw TrustError.receiptUnsafe }
        var data = Data(count: Int(st.st_size))
        try data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { throw TrustError.receiptUnsafe }
            var offset = 0
            while offset < raw.count {
                let count = read(fd, base.advanced(by: offset), raw.count - offset)
                guard count > 0 else { throw TrustError.receiptUnsafe }
                offset += count
            }
        }
        guard data.count <= 16 * 1024,
              let receipt = try? PropertyListDecoder().decode(Receipt.self, from: data),
              validReceiptFields(receipt), receipt.stableID == stableIdentifier,
              receipt.sourceCDHash == sourceCDHash,
              receipt.executablePath == expectedExecutablePath(applicationURL, receipt: receipt) else {
            throw TrustError.receiptMismatch
        }
        try validateInstalledBundleThrowing(applicationURL, receipt: receipt)
        return receipt
    }

    static func validatesInstalledBundle(applicationURL: URL, receipt: Receipt) -> Bool {
        do {
            try validateInstalledBundleThrowing(applicationURL, receipt: receipt)
            return true
        } catch {
            return false
        }
    }

    private static func validateInstalledBundleThrowing(_ applicationURL: URL, receipt: Receipt) throws {
        guard validReceiptFields(receipt), canonical(applicationURL).hasSuffix(".app") else {
            throw TrustError.invalidBundle
        }
        let code = try staticCode(at: applicationURL)
        try checkStrict(code, at: applicationURL)
        let info = try signingInfo(code)
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & adHocSignatureFlag != 0,
              info[kSecCodeInfoTeamIdentifier as String] == nil,
              info[kSecCodeInfoUnique as String] as? Data == receipt.cdHash,
              info[kSecCodeInfoIdentifier as String] as? String == receipt.bundleIdentifier,
              Bundle(url: applicationURL)?.executableURL.map(canonical) == receipt.executablePath else {
            throw TrustError.receiptMismatch
        }
    }

    /// Confirms an NSRunningApplication is the exact ad-hoc-signed executable pinned by the receipt.
    static func validates(process: NSRunningApplication, receipt: Receipt) -> Bool {
        guard validReceiptFields(receipt), !process.isTerminated,
              process.processIdentifier > 0,
              process.executableURL.map(canonical) == receipt.executablePath,
              process.bundleIdentifier == receipt.bundleIdentifier,
              validates(processIdentifier: process.processIdentifier, receipt: receipt) else { return false }
        let stillRunning = NSRunningApplication(processIdentifier: process.processIdentifier)
        return stillRunning?.isTerminated == false
            && stillRunning?.executableURL.map(canonical) == receipt.executablePath
            && stillRunning?.bundleIdentifier == receipt.bundleIdentifier
    }

    /// PID-level validation is also useful to test the Security.framework
    /// process identity check without LaunchServices registration.
    static func validates(processIdentifier: Int32, receipt: Receipt) -> Bool {
        guard validReceiptFields(receipt), processIdentifier > 0 else { return false }
        let attributes: [String: Any] = [kSecGuestAttributePid as String: NSNumber(value: processIdentifier)]
        var dynamicCode: SecCode?
        var staticCode: SecStaticCode?
        guard SecCodeCopyGuestWithAttributes(nil, attributes as CFDictionary, [], &dynamicCode) == errSecSuccess,
              let dynamicCode,
              SecCodeCheckValidity(dynamicCode, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(dynamicCode, [], &staticCode) == errSecSuccess,
              let staticCode,
              let info = try? signingInfo(staticCode) else { return false }
        let flags = (info[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
        guard flags & adHocSignatureFlag != 0,
              info[kSecCodeInfoTeamIdentifier as String] == nil,
              info[kSecCodeInfoUnique as String] as? Data == receipt.cdHash,
              info[kSecCodeInfoIdentifier as String] as? String == receipt.bundleIdentifier,
              let mainExecutable = info[kSecCodeInfoMainExecutable as String] as? URL,
              canonical(mainExecutable) == receipt.executablePath else { return false }
        return true
    }

    private static func expectedExecutablePath(_ applicationURL: URL, receipt: Receipt) -> String? {
        let path = canonical(applicationURL)
        guard path.hasSuffix(".app") else { return nil }
        return canonical(applicationURL.appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(URL(fileURLWithPath: receipt.executablePath).lastPathComponent))
    }

    private static func generatedIdentifier(for stableID: String) -> String {
        "com.spartan0285.poweremu.guestapp." + stableID
    }

    /// The running host bundle is immutable for this process. Cache its strict
    /// signature result so shortcut creation does not rescan large app resources.
    private static func verifiedHostTeam(at hostURL: URL) throws -> String {
        let hostPath = canonical(hostURL)
        guard let executable = Bundle(url: URL(fileURLWithPath: hostPath))?.executableURL,
              let attributes = try? FileManager.default.attributesOfItem(atPath: executable.path),
              let fileID = attributes[.systemFileNumber] as? NSNumber,
              let size = attributes[.size] as? NSNumber,
              let modified = attributes[.modificationDate] as? Date else { throw TrustError.invalidBundle }
        let fingerprint = "\(fileID.uint64Value):\(size.uint64Value):\(modified.timeIntervalSince1970)"
        hostCheckLock.lock()
        defer { hostCheckLock.unlock() }
        if let cached = verifiedHostTeams[hostPath], cached.fingerprint == fingerprint {
            return cached.team
        }
        let hostURL = URL(fileURLWithPath: hostPath, isDirectory: true)
        let host = try staticCode(at: hostURL)
        try checkDeveloperID(host, at: hostURL)
        let info = try signingInfo(host)
        guard let team = info[kSecCodeInfoTeamIdentifier as String] as? String,
              team == developerTeamIdentifier else { throw TrustError.wrongDeveloper }
        verifiedHostTeams[hostPath] = (fingerprint, team)
        return team
    }

    private static func validReceiptFields(_ receipt: Receipt) -> Bool {
        receipt.version == 1 && validStableIdentifier(receipt.stableID)
            && validHash(receipt.sourceCDHash) && validHash(receipt.cdHash)
            && !receipt.bundleIdentifier.isEmpty && receipt.bundleIdentifier.utf8.count <= 256
            && receipt.executablePath.hasPrefix("/") && receipt.executablePath.utf8.count <= 4096
            && canonical(URL(fileURLWithPath: receipt.executablePath)) == receipt.executablePath
    }

    private static func validStableIdentifier(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102) }
    }

    private static func validHash(_ data: Data) -> Bool { (16...64).contains(data.count) }

    private static func canonical(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func openSafeDirectory(_ url: URL) throws -> Int32 {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw TrustError.receiptUnsafe }
        var st = stat()
        guard fstat(fd, &st) == 0,
              (st.st_mode & S_IFMT) == S_IFDIR,
              st.st_uid == geteuid(), (st.st_mode & 0o077) == 0 else {
            close(fd)
            throw TrustError.receiptUnsafe
        }
        return fd
    }

    private static func staticCode(at url: URL) throws -> SecStaticCode {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else {
            throw TrustError.invalidBundle
        }
        return code
    }

    private static func checkStrict(_ code: SecStaticCode, at url: URL) throws {
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else { throw TrustError.invalidSignature("\(url.lastPathComponent), OSStatus \(status)") }
    }

    private static func checkDeveloperID(_ code: SecStaticCode, at url: URL) throws {
        var requirement: SecRequirement?
        let createStatus = SecRequirementCreateWithString(developerIDRequirement as CFString, [], &requirement)
        guard createStatus == errSecSuccess, let requirement else {
            throw TrustError.invalidSignature("could not create the Developer ID requirement")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode | kSecCSStrictValidate)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw TrustError.invalidSignature("\(url.lastPathComponent) is not valid Developer ID code (OSStatus \(status))")
        }
    }

    private static func signingInfo(_ code: SecStaticCode) throws -> [String: Any] {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info else { throw TrustError.invalidSignature("signing information unavailable") }
        return info as! [String: Any]
    }
}
