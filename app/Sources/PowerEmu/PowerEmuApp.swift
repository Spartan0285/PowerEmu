import SwiftUI
import AppKit

@main
struct PowerEmuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary()

    var body: some Scene {
        WindowGroup("PowerEmu") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear { appDelegate.library = library }
        }
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Mac…") { NotificationCenter.default.post(name: .newVirtualMac, object: nil) }
                    .keyboardShortcut("n")
                Button("Add Existing Virtual Mac…") { NotificationCenter.default.post(name: .addVirtualMac, object: nil) }
                    .keyboardShortcut("o")
            }
        }
    }
}

extension Notification.Name {
    static let newVirtualMac = Notification.Name("PowerEmuNewVirtualMac")
    static let addVirtualMac = Notification.Name("PowerEmuAddVirtualMac")
}

/// Quitting PowerEmu would leave running virtual Macs without their
/// controls, so ask first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: VMLibrary?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = MainActor.assumeIsolated {
            library?.machines.filter { $0.state != .stopped }.map { $0.config.name } ?? []
        }
        guard !running.isEmpty else { return .terminateNow }
        let a = NSAlert()
        a.messageText = running.count == 1 ? "“\(running[0])” is still running."
                                           : "\(running.count) virtual Macs are still running."
        a.informativeText = "Shut them down before quitting PowerEmu. If you quit now they keep running, but PowerEmu can no longer control them."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Quit Anyway")
        return a.runModal() == .alertSecondButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}
