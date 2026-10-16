import AppKit
import CryptoKit
import Foundation

/// Exercises the v3 standalone launcher's native file-open path. This uses a
/// synthetic runtime sidecar owned by this test app; it never opens a VM.
@main struct GuestDockOpenTest {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2,
              Bundle.main.bundleURL.pathExtension == "app",
              let hostID = Bundle.main.bundleIdentifier else {
            throw CocoaError(.fileNoSuchFile)
        }
        _ = NSApplication.shared
        let fm = FileManager.default
        let helperBinary = URL(fileURLWithPath: CommandLine.arguments[1]).standardizedFileURL
        guard fm.isExecutableFile(atPath: helperBinary.path) else { throw CocoaError(.executableLoad) }

        let fixtureRoot = fm.temporaryDirectory.appendingPathComponent("PE-dock-open-" + UUID().uuidString,
                                                                         isDirectory: true)
        try fm.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: fixtureRoot) }

        let vmURL = fixtureRoot.appendingPathComponent("Fixture.poweremu", isDirectory: true)
        try fm.createDirectory(at: vmURL, withIntermediateDirectories: false)
        let appPath = "/Applications/Guest TextEdit.app"
        let request = try GuestAppLaunchRequest(vmPackageURL: vmURL, guestApplicationPath: appPath)
        let launchersRoot = fm.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
        let application = try request.install(helperBinary: helperBinary, displayName: "Guest TextEdit",
            applicationsDirectory: launchersRoot, hostApplicationURL: Bundle.main.bundleURL,
            hostBundleIdentifier: hostID)
        guard let helperExecutable = Bundle(url: application)?.executableURL else {
            throw CocoaError(.executableLoad)
        }
        let launcherDirectory = application.deletingLastPathComponent()
        defer { try? fm.removeItem(at: launcherDirectory) }
        let runtimeURL = launcherDirectory.appendingPathComponent("runtime.plist")
        let session = UUID().uuidString
        let runtime: [String: Any] = [
            "Version": 1, "StableIdentifier": request.stableIdentifier,
            "VMPackagePath": request.vmPackagePath, "GuestApplicationPath": appPath,
            "OwnerPID": Int(getpid()), "Session": session,
            "State": "running", "ProcessIDs": [4242]
        ]
        let runtimeData = try PropertyListSerialization.data(fromPropertyList: runtime, format: .xml, options: 0)
        try runtimeData.write(to: runtimeURL, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)

        let document = fixtureRoot.appendingPathComponent("Dock document.txt")
        try Data("dock open".utf8).write(to: document)
        var ready = false
        var openedPaths: [String]?
        var openedIdentity: (String, String, String)?
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spartan0285.poweremu.guestapp.action"),
            object: request.stableIdentifier as NSString, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                guard note.userInfo?["session"] as? String == session,
                      note.userInfo?["owner"] as? String == String(getpid()),
                      note.userInfo?["vm"] as? String == request.vmPackagePath,
                      note.userInfo?["app"] as? String == appPath else { return }
                switch note.userInfo?["action"] as? String {
                case "ready": ready = true
                case "open":
                    openedPaths = note.userInfo?["paths"] as? [String]
                    openedIdentity = (note.userInfo?["session"] as? String ?? "",
                                      note.userInfo?["owner"] as? String ?? "",
                                      note.userInfo?["app"] as? String ?? "")
                default: break
                }
            }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let helperExecutableURL = helperExecutable.standardizedFileURL
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where key.hasPrefix("PE_DOCK_") { environment.removeValue(forKey: key) }
        environment["PE_DOCK_RUNTIME"] = "1"
        let launchConfiguration = NSWorkspace.OpenConfiguration()
        launchConfiguration.activates = false
        launchConfiguration.environment = environment
        let helper = try await NSWorkspace.shared.openApplication(at: application,
                                                                   configuration: launchConfiguration)
        precondition(helper.executableURL?.standardizedFileURL == helperExecutableURL,
                     "LaunchServices started a different helper executable")
        defer {
            var stopped = runtime
            stopped["State"] = "stopped"
            if let data = try? PropertyListSerialization.data(fromPropertyList: stopped, format: .xml, options: 0) {
                try? data.write(to: runtimeURL, options: .atomic)
                try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeURL.path)
                DistributedNotificationCenter.default().postNotificationName(
                    .init("com.spartan0285.poweremu.guestapp.state"), object: request.stableIdentifier,
                    userInfo: ["session": session, "owner": String(getpid()), "vm": request.vmPackagePath,
                               "app": appPath, "state": "stopped"], deliverImmediately: true)
            }
            // The helper normally exits on this stop notification. If its
            // distributed-notification run loop is unavailable, terminate
            // only this fixture-owned process.
            if !helper.isTerminated, !helper.terminate() { _ = helper.forceTerminate() }
        }

        let attachDeadline = Date().addingTimeInterval(5)
        while !ready && Date() < attachDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(ready, "v3 helper did not attach to the matching runtime sidecar")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        do {
            try await NSWorkspace.shared.open([document], withApplicationAt: application, configuration: configuration)
        } catch {
            print("UNSUPPORTED: NSWorkspace could not open a document with the durable helper app: \(error)")
            print("The launcher can still activate apps, but native document routing requires an explicit host-side file-open handoff.")
            return
        }
        let openDeadline = Date().addingTimeInterval(5)
        while openedPaths == nil && Date() < openDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        let actualPath = document.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalOpenedPaths = openedPaths?.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().standardizedFileURL.path }
        precondition(canonicalOpenedPaths == [actualPath], "native openFiles callback did not report the exact document path")
        precondition(openedIdentity?.0 == session && openedIdentity?.1 == String(getpid()) && openedIdentity?.2 == appPath,
                     "file-open notification escaped its runtime identity")
        print("PASS: v3 helper accepted native file open and reported the scoped path")
    }
}
