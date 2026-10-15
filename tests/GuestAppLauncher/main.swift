import Foundation

@main
enum GuestAppLauncherChecks {
    static func main() throws {
        let package = URL(fileURLWithPath: "/tmp/PowerEmu Launcher Fixture/Test.poweremu", isDirectory: true)
        let original = try GuestAppLaunchRequest(
            vmPackageURL: package,
            guestApplicationPath: "/Applications/Utilities/Activity Monitor.app"
        )
        guard let encoded = original.url(),
              try GuestAppLaunchRequest.parse(encoded) == original else {
            fatalError("guest app launch URL did not round-trip")
        }
        guard original.matchingPackage(in: [package]) != nil,
              original.matchingPackage(in: []) == nil else {
            fatalError("VM package lookup did not distinguish present and missing VMs")
        }
        let sameRequest = try GuestAppLaunchRequest(
            vmPackageURL: package, guestApplicationPath: original.guestApplicationPath
        )
        guard original.stableIdentifier == sameRequest.stableIdentifier else {
            fatalError("launcher identity changed for the same VM and app")
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuestAppLauncher-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = URL(fileURLWithPath: "/bin/ls")
        let installed = try original.install(helperBinary: source, displayName: "Activity Monitor",
                                             iconData: Data([1, 2, 3]),
                                             applicationsDirectory: root)
        guard try Data(contentsOf: source) == Data(contentsOf: installed),
              FileManager.default.fileExists(atPath: installed.deletingLastPathComponent()
                .appendingPathComponent("launcher.plist").path) else {
            fatalError("persistent launcher changed helper bytes or omitted its sidecar")
        }

        let badApplicationURLs = [
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2FTest.poweremu")!,
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2FTest.poweremu&app=relative.app")!,
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2FTest.poweremu&app=%2FApplications%2F..%2Fsecret.app")!,
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2FTest.poweremu&app=%2FApplications%2FA.app&app=%2FApplications%2FB.app")!,
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2FTest.poweremu&app=%2FApplications%2FA.app#fragment")!,
            URL(string: "poweremu://guest-app?vm=%2Ftmp%2Fdir%2F..%2FTest.poweremu&app=%2FApplications%2FA.app")!
        ]
        for url in badApplicationURLs {
            do {
                _ = try GuestAppLaunchRequest.parse(url)
                fatalError("invalid launch request was accepted: \(url)")
            } catch is GuestAppLaunchRequest.ParseError {
                // Expected: incomplete, relative, or traversal path.
            }
        }
    }
}
