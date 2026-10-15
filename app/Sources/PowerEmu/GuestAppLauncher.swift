import Foundation
import CryptoKit

/// A durable request for opening an app installed in one of PowerEmu's guests.
/// The VM package path is the identity: names are editable and are not unique.
///
/// URLs have this form:
/// `poweremu://guest-app?vm=%2F...%2FMachine.poweremu&app=%2FApplications%2FTextEdit.app`
struct GuestAppLaunchRequest: Equatable {
    let vmPackagePath: String
    let guestApplicationPath: String

    enum ParseError: Error, Equatable {
        case wrongScheme
        case wrongRoute
        case missingVM
        case missingApplication
        case invalidVM
        case invalidApplication
    }

    init(vmPackageURL: URL, guestApplicationPath: String) throws {
        guard vmPackageURL.isFileURL,
              vmPackageURL.pathExtension == "poweremu",
              vmPackageURL.path.utf8.count <= 4096,
              !Self.containsControlCharacters(vmPackageURL.path) else {
            throw ParseError.invalidVM
        }
        guard Self.isValidGuestApplicationPath(guestApplicationPath) else {
            throw ParseError.invalidApplication
        }
        self.vmPackagePath = Self.canonicalPath(vmPackageURL)
        self.guestApplicationPath = guestApplicationPath
    }

    private init(vmPackagePath: String, guestApplicationPath: String) throws {
        let vmURL = URL(fileURLWithPath: vmPackagePath).standardizedFileURL
        let canonical = Self.canonicalPath(vmURL)
        guard vmURL.pathExtension == "poweremu", canonical == vmPackagePath,
              vmPackagePath.utf8.count <= 4096,
              !Self.containsControlCharacters(vmPackagePath) else {
            throw ParseError.invalidVM
        }
        guard Self.isValidGuestApplicationPath(guestApplicationPath) else {
            throw ParseError.invalidApplication
        }
        self.vmPackagePath = Self.canonicalPath(vmURL)
        self.guestApplicationPath = guestApplicationPath
    }

    func url(scheme: String = "poweremu") -> URL? {
        var components = URLComponents()
        components.scheme = scheme
        components.host = "guest-app"
        components.queryItems = [
            URLQueryItem(name: "vm", value: vmPackagePath),
            URLQueryItem(name: "app", value: guestApplicationPath)
        ]
        return components.url
    }

    static func parse(_ url: URL, scheme: String = "poweremu") throws -> GuestAppLaunchRequest {
        guard url.scheme?.caseInsensitiveCompare(scheme) == .orderedSame else {
            throw ParseError.wrongScheme
        }
        guard url.host == "guest-app", url.path.isEmpty || url.path == "/",
              url.user == nil, url.password == nil, url.port == nil,
              url.fragment == nil else {
            throw ParseError.wrongRoute
        }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard values.count == 2,
              values.filter({ $0.name == "vm" }).count == 1,
              let vm = values.first(where: { $0.name == "vm" })?.value, !vm.isEmpty else {
            throw ParseError.missingVM
        }
        guard values.filter({ $0.name == "app" }).count == 1,
              let app = values.first(where: { $0.name == "app" })?.value, !app.isEmpty else {
            throw ParseError.missingApplication
        }
        return try GuestAppLaunchRequest(vmPackagePath: vm, guestApplicationPath: app)
    }

    /// Match against the library after it has reloaded. Package paths stay
    /// stable across renames of the VM's display name and duplicate names.
    func matchingPackage(in packageURLs: [URL]) -> URL? {
        packageURLs.first { Self.canonicalPath($0) == vmPackagePath }
    }

    /// Install an unchanged copy of PowerEmu's signed standalone helper. Its
    /// sibling sidecar carries only launch data and an optional guest icon.
    /// Each launcher owns a dedicated directory so multiple launchers never
    /// share mutable configuration.
    func install(helperBinary: URL, displayName: String, iconData: Data? = nil,
                 applicationsDirectory: URL? = nil) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: helperBinary.path),
              !displayName.isEmpty, displayName.utf8.count <= 256,
              !Self.containsControlCharacters(displayName),
              iconData?.count ?? 0 <= 4 * 1024 * 1024 else {
            throw InstallError.invalidInput
        }
        let root = applicationsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
        let id = stableIdentifier
        let directory = root.appendingPathComponent(id, isDirectory: true)
        let fileName = "PowerEmuGuestApp"
        let executable = directory.appendingPathComponent(fileName)
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let staged = directory.appendingPathComponent("PowerEmuGuestApp.new")
        try? fm.removeItem(at: staged)
        try fm.copyItem(at: helperBinary, to: staged)
        if fm.fileExists(atPath: executable.path) {
            _ = try fm.replaceItemAt(executable, withItemAt: staged)
        } else {
            try fm.moveItem(at: staged, to: executable)
        }
        if let iconData, !iconData.isEmpty {
            try iconData.write(to: directory.appendingPathComponent("icon.png"), options: .atomic)
        } else {
            try? fm.removeItem(at: directory.appendingPathComponent("icon.png"))
        }
        let config: [String: Any] = [
            "LauncherVersion": 1,
            "VMPackagePath": vmPackagePath,
            "GuestApplicationPath": guestApplicationPath,
            "DisplayName": displayName
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("launcher.plist"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent("launcher.plist").path)
        return executable
    }

    enum InstallError: LocalizedError {
        case invalidInput
        case missingHelper
        case unsupportedHelper

        var errorDescription: String? {
            switch self {
            case .invalidInput: return "The guest app launcher details are invalid."
            case .missingHelper: return "PowerEmu’s trusted guest app helper is missing."
            case .unsupportedHelper: return "Update PowerEmu before creating persistent guest app launchers."
            }
        }
    }

    var stableIdentifier: String {
        let bytes = SHA256.hash(data: Data((vmPackagePath + "\0" + guestApplicationPath).utf8))
        return bytes.prefix(16).map { String(format: "%02x", $0) }.joined()
    }

    static func isValidGuestApplicationPath(_ path: String) -> Bool {
        guard path.hasPrefix("/"), path != "/", path.utf8.count <= 4096,
              !containsControlCharacters(path) else { return false }
        return !path.split(separator: "/").contains("..")
    }

    private static func canonicalPath(_ url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    private static func containsControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

}
