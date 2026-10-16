import Foundation

/// A user's selected guest applications, stored with the VM package rather
/// than in display-name based VM configuration. Identity is the canonical
/// package path plus the guest's application bundle path.
struct GuestAppShortcutSelection: Equatable {
    let vmPackagePath: String
    private(set) var applicationPaths: Set<String>

    init(vmPackageURL: URL, applicationPaths: Set<String> = []) {
        self.vmPackagePath = vmPackageURL.standardizedFileURL.resolvingSymlinksInPath().path
        self.applicationPaths = Set(applicationPaths.filter(Self.validApplicationPath))
    }

    mutating func setSelected(_ selected: Bool, applicationPath: String) {
        guard Self.validApplicationPath(applicationPath) else { return }
        if selected { applicationPaths.insert(applicationPath) }
        else { applicationPaths.remove(applicationPath) }
    }

    func contains(_ applicationPath: String) -> Bool {
        applicationPaths.contains(applicationPath)
    }

    static func validApplicationPath(_ path: String) -> Bool {
        path.hasPrefix("/") && path != "/" && path.utf8.count <= 4096 &&
            !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) &&
            !path.split(separator: "/").contains("..")
    }
}

/// Atomic, owner-only persistence beside the VM package. This file contains
/// only guest bundle paths; it never stores executable commands or host paths.
enum GuestAppShortcutStore {
    static let fileName = ".poweremu-guest-app-shortcuts.plist"

    static func fileURL(in package: URL) -> URL {
        package.standardizedFileURL.appendingPathComponent(fileName)
    }

    static func load(from package: URL) -> GuestAppShortcutSelection {
        let url = fileURL(in: package)
        guard let values = try? PropertyListSerialization.propertyList(from: Data(contentsOf: url),
                                                                        options: [], format: nil) as? [String: Any],
              values["Version"] as? Int == 1,
              values["VMPackagePath"] as? String == package.standardizedFileURL.resolvingSymlinksInPath().path,
              let paths = values["Applications"] as? [String] else {
            return GuestAppShortcutSelection(vmPackageURL: package)
        }
        return GuestAppShortcutSelection(vmPackageURL: package, applicationPaths: Set(paths))
    }

    static func save(_ selection: GuestAppShortcutSelection, to package: URL) throws {
        let canonical = package.standardizedFileURL.resolvingSymlinksInPath().path
        guard selection.vmPackagePath == canonical,
              package.isFileURL,
              FileManager.default.fileExists(atPath: package.path) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        let values: [String: Any] = [
            "Version": 1,
            "VMPackagePath": canonical,
            "Applications": selection.applicationPaths.sorted()
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: values, format: .xml, options: 0)
        let url = fileURL(in: package)
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
