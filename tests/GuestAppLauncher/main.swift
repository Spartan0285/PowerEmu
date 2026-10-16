import AppKit

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
        precondition(CommandLine.arguments.count == 3, "Pass the signed template executable and signed host app")
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let host = URL(fileURLWithPath: CommandLine.arguments[2])
        let sourceBytes = try Data(contentsOf: source)
        let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 16, pixelsHigh: 16, bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 64, bitsPerPixel: 32)!
        memset(bitmap.bitmapData!, 255, 1024)
        let png = bitmap.representation(using: .png, properties: [:])!
        let installed = try original.install(helperBinary: source, displayName: "Activity Monitor", iconData: png,
            applicationsDirectory: root, hostApplicationURL: host, hostBundleIdentifier: Bundle(url: host)!.bundleIdentifier!)
        let again = try original.install(helperBinary: source, displayName: "Monitor Renamed", iconData: png,
            applicationsDirectory: root, hostApplicationURL: host, hostBundleIdentifier: Bundle(url: host)!.bundleIdentifier!)
        precondition(installed == again, "App display-name change must preserve a pinned application URL")
        let template = source.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let sourceHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: host)
        let receipt = try GuestLauncherTrust.loadReceipt(from: installed.deletingLastPathComponent(), applicationURL: installed,
            stableIdentifier: original.stableIdentifier, sourceCDHash: sourceHash)
        precondition(GuestLauncherTrust.validatesInstalledBundle(applicationURL: installed, receipt: receipt))
        let unchangedSource = try Data(contentsOf: source)
        precondition(unchangedSource == sourceBytes)
        precondition(FileManager.default.fileExists(atPath: installed.appendingPathComponent("Contents/Resources/GuestApp.icns").path))

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
