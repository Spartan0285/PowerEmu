import AppKit
import CryptoKit
import Security

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

    /// One durable application path per VM/application. Mutable launch data and
    /// artwork stay beside the unchanged signed executable, never inside it.
    func install(helperBinary: URL, displayName: String, iconData: Data? = nil,
                 applicationsDirectory: URL? = nil, hostApplicationURL: URL? = nil,
                 hostBundleIdentifier: String? = nil) throws -> URL {
        guard FileManager.default.isExecutableFile(atPath: helperBinary.path),
              !displayName.isEmpty, displayName.utf8.count <= 256,
              !Self.containsControlCharacters(displayName),
              iconData?.count ?? 0 <= 4 * 1024 * 1024 else {
            throw InstallError.invalidInput
        }
        let fm = FileManager.default
        let root = applicationsDirectory ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
        let directory = root.standardizedFileURL.resolvingSymlinksInPath().appendingPathComponent(stableIdentifier, isDirectory: true)
        guard directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw InstallError.invalidInput
        }
        try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        let attributes = try fm.attributesOfItem(atPath: directory.path)
        guard (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              (attributes[.type] as? FileAttributeType) == .typeDirectory else {
            throw InstallError.invalidInput
        }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let configURL = directory.appendingPathComponent("launcher.plist")
        let old = (try? Data(contentsOf: configURL)).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        // The distributed template remains Developer-ID signed. App-specific
        // artwork belongs to a separately generated, locally signed bundle.
        // Never alter a generated bundle while its representative is running.
        let template = helperBinary.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard template.pathExtension == "app", Bundle(url: template)?.executableURL?.path == helperBinary.path else {
            throw InstallError.missingHelper
        }
        let host = (hostApplicationURL ?? Bundle.main.bundleURL).standardizedFileURL.resolvingSymlinksInPath()
        let sourceCDHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: host)
        let savedName = old?["ApplicationBundleName"] as? String
        let bundleName = savedName.flatMap {
            Self.safeExecutableName($0) == $0 && $0.hasSuffix(".app") ? $0 : nil
        } ?? Self.safeExecutableName(displayName) + ".app"
        let application = directory.appendingPathComponent(bundleName, isDirectory: true)
        guard application.resolvingSymlinksInPath().path == application.path else { throw InstallError.invalidInput }
        let sidecarIcon = directory.appendingPathComponent("icon.png")
        if let iconData, !iconData.isEmpty {
            guard NSImage(data: iconData)?.isValid == true else { throw InstallError.invalidInput }
            if (try? Data(contentsOf: sidecarIcon)) != iconData { try iconData.write(to: sidecarIcon, options: .atomic) }
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: sidecarIcon.path)
        }
        let artwork = (try? Data(contentsOf: sidecarIcon)).flatMap { NSImage(data: $0) }
            ?? NSWorkspace.shared.icon(forFile: host.path)
        let icns = try Self.nativeIcon(artwork)
        let artworkHash = SHA256.hash(data: icns).map { String(format: "%02x", $0) }.joined()
        let identifier = "com.spartan0285.poweremu.guestapp." + stableIdentifier
        let existingInfo = (try? Data(contentsOf: application.appendingPathComponent("Contents/Info.plist"))).flatMap {
            try? PropertyListSerialization.propertyList(from: $0, options: [], format: nil) as? [String: Any]
        }
        let receipt = try? GuestLauncherTrust.loadReceipt(from: directory, applicationURL: application,
            stableIdentifier: stableIdentifier, sourceCDHash: sourceCDHash)
        let validExisting = receipt.map { GuestLauncherTrust.validatesInstalledBundle(applicationURL: application, receipt: $0) } ?? false
        let sameGeneration = validExisting && existingInfo?["PEArtworkSHA256"] as? String == artworkHash &&
            existingInfo?["CFBundleIdentifier"] as? String == identifier &&
            existingInfo?["CFBundleDisplayName"] as? String == displayName
        if !sameGeneration {
            let running = NSWorkspace.shared.runningApplications.contains {
                !$0.isTerminated && $0.bundleURL?.standardizedFileURL.resolvingSymlinksInPath() == application.standardizedFileURL
            }
            // A new icon is live artwork immediately; its sealed counterpart
            // waits until the app is closed. Existing trusted code stays intact.
            if running && !validExisting { throw InstallError.runningOldHelper }
            if !running {
                let staging = directory.appendingPathComponent(".install-" + UUID().uuidString + ".app")
                let previous = directory.appendingPathComponent(".previous-" + UUID().uuidString + ".app")
                defer { try? fm.removeItem(at: staging) }
                let executable = staging.appendingPathComponent("Contents/MacOS/PowerEmuGuestApp")
                try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.createDirectory(at: staging.appendingPathComponent("Contents/Resources"), withIntermediateDirectories: true)
                // These are newly generated local files, not a downloaded app
                // with its quarantine removed or a modified signed template.
                try Data(contentsOf: helperBinary).write(to: executable)
                try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
                var info = Bundle(url: template)!.infoDictionary!
                info["CFBundleIdentifier"] = identifier
                info["CFBundleName"] = displayName
                info["CFBundleDisplayName"] = displayName
                info["CFBundleIconFile"] = "GuestApp.icns"
                info["PEArtworkSHA256"] = artworkHash
                try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
                    .write(to: staging.appendingPathComponent("Contents/Info.plist"))
                try icns.write(to: staging.appendingPathComponent("Contents/Resources/GuestApp.icns"))
                let signer = Process()
                signer.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
                signer.arguments = ["--force", "--sign", "-", "--options", "runtime", "--identifier", identifier, staging.path]
                signer.standardOutput = FileHandle.nullDevice
                signer.standardError = FileHandle.nullDevice
                try signer.run(); signer.waitUntilExit()
                guard signer.terminationStatus == 0 else { throw InstallError.signingFailed }
                let generatedReceipt = try GuestLauncherTrust.makeReceipt(applicationURL: staging,
                    installedApplicationURL: application, stableIdentifier: stableIdentifier, sourceCDHash: sourceCDHash)
                let existed = fm.fileExists(atPath: application.path)
                if existed { try fm.moveItem(at: application, to: previous) }
                do {
                    try fm.moveItem(at: staging, to: application)
                    try GuestLauncherTrust.saveReceipt(generatedReceipt, to: directory)
                } catch {
                    if existed { try? fm.removeItem(at: application); try? fm.moveItem(at: previous, to: application) }
                    throw error
                }
                if existed { try? fm.removeItem(at: previous) }
                NSWorkspace.shared.noteFileSystemChanged(application.path)
            }
        }
        let hostID = hostBundleIdentifier ?? Bundle.main.bundleIdentifier ?? ""
        let config: [String: Any] = [
            "LauncherVersion": 3, "StableIdentifier": stableIdentifier,
            "VMPackagePath": vmPackagePath, "GuestApplicationPath": guestApplicationPath,
            "DisplayName": displayName, "ApplicationBundleName": bundleName,
            "HostApplicationPath": host.path, "HostBundleIdentifier": hostID
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: config, format: .xml, options: 0)
        if (try? Data(contentsOf: configURL)) != data { try data.write(to: configURL, options: .atomic) }
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
        return application
    }

    /// Native ICNS resources are read by Finder/Dock with no helper process.
    private static func nativeIcon(_ image: NSImage) throws -> Data {
        var body = Data()
        let entries: [(Int, String)] = [(16,"icp4"),(32,"icp5"),(64,"icp6"),(128,"ic07"),(256,"ic08"),(512,"ic09")]
        func word(_ value: Int) -> Data { var n = UInt32(value).bigEndian; return withUnsafeBytes(of: &n) { Data($0) } }
        guard let source = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw InstallError.invalidInput }
        for (size, type) in entries {
            guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw InstallError.invalidInput }
            context.interpolationQuality = .high
            context.draw(source, in: CGRect(x: 0, y: 0, width: size, height: size))
            guard let resized = context.makeImage(),
                  let png = NSBitmapImageRep(cgImage: resized).representation(using: .png, properties: [:]) else { throw InstallError.invalidInput }
            body.append(Data(type.utf8)); body.append(word(png.count + 8)); body.append(png)
        }
        return Data("icns".utf8) + word(body.count + 8) + body
    }

    private static func safeExecutableName(_ name: String) -> String {
        let value = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        var result = ""
        for scalar in value.unicodeScalars where !CharacterSet.controlCharacters.contains(scalar) {
            if result.utf8.count + scalar.utf8.count > 240 { break }
            result.unicodeScalars.append(scalar)
        }
        return result.isEmpty || result == "." || result == ".." ? "Guest Application" : result
    }

    enum InstallError: LocalizedError {
        case invalidInput
        case missingHelper
        case unsupportedHelper
        case runningOldHelper
        case signingFailed

        var errorDescription: String? {
            switch self {
            case .signingFailed: return "The local guest app launcher could not be signed."
            case .invalidInput: return "The guest app launcher details are invalid."
            case .missingHelper: return "PowerEmu’s trusted guest app helper is missing."
            case .runningOldHelper: return "Quit the older guest app Dock icon before updating its launcher."
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
