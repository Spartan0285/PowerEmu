import AppKit
import Foundation

/// Verifies that the tiny host Dock representative accepts a file and reports
/// it to only the PowerEmu session that created the tile.
@main struct GuestDockOpenTest {
    @MainActor static func main() async throws {
        guard CommandLine.arguments.count == 2 else { throw CocoaError(.fileNoSuchFile) }
        _ = NSApplication.shared
        let fm = FileManager.default
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.path.contains("PE-dock-open-") == true {
            app.forceTerminate()
        }
        let root = fm.temporaryDirectory.appendingPathComponent("PE-dock-open-" + UUID().uuidString)
        let bundle = root.appendingPathComponent("Guest TextEdit.app")
        let executable = bundle.appendingPathComponent("Contents/MacOS/GuestTextEdit")
        try fm.createDirectory(at: executable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: executable)
        let session = UUID().uuidString
        let info: [String: Any] = [
            "CFBundleExecutable": "GuestTextEdit",
            "CFBundleIdentifier": "com.spartan0285.poweremu.test.guestapp.\(session)",
            "CFBundleName": "Guest TextEdit",
            "CFBundlePackageType": "APPL",
            "LSUIElement": true,
            "PEGuestPID": "4242",
            "PESession": session,
            "CFBundleDocumentTypes": [[
                "CFBundleTypeName": "Files", "CFBundleTypeRole": "Viewer",
                "LSItemContentTypes": ["public.item"], "CFBundleTypeExtensions": ["*"]
            ]]
        ]
        let plist = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try plist.write(to: bundle.appendingPathComponent("Contents/Info.plist"))
        let document = root.appendingPathComponent("Dock document.txt")
        try Data("dock open".utf8).write(to: document)
        defer {
            for app in NSWorkspace.shared.runningApplications where app.bundleURL == bundle { app.forceTerminate() }
            try? fm.removeItem(at: root)
        }

        var received = false
        let observer = DistributedNotificationCenter.default().addObserver(
            forName: .init("com.spartan0285.poweremu.guestapp.open"), object: nil, queue: .main
        ) { note in
            MainActor.assumeIsolated {
                let paths = (note.userInfo?["paths"] as? [String])?.map {
                    URL(fileURLWithPath: $0).resolvingSymlinksInPath().path
                }
                received = note.userInfo?["pid"] as? String == "4242" &&
                    note.userInfo?["session"] as? String == session &&
                    paths == [document.resolvingSymlinksInPath().path]
            }
        }
        defer { DistributedNotificationCenter.default().removeObserver(observer) }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        try await NSWorkspace.shared.open([document], withApplicationAt: bundle, configuration: configuration)
        for _ in 0..<200 where !received { try await Task.sleep(nanoseconds: 10_000_000) }
        precondition(received)
        print("PASS: guest Dock tile accepts a document and reports PID, session, and path")
    }
}
