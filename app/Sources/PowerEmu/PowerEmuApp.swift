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
            CommandGroup(after: .windowList) {
                OpenServicesButton()
            }
            CommandMenu("Machine") {
                Button("Release Mouse  (⌃⌥G)") { VMWindowController.key?.display.ungrab() }
                Button("Full Screen  (⌃⌥F)") { VMWindowController.key?.window?.toggleFullScreen(nil) }
                Button("Show Performance  (⌃⌥P)") { VMWindowController.key?.display.togglePerformance() }
                Divider()
                Button("Shut Down") { VMWindowController.key?.vm.requestShutDown() }
                Button("Restart") { VMWindowController.key?.vm.requestRestart() }
                Button("Force Power Off…") {
                    guard let vm = VMWindowController.key?.vm else { return }
                    let a = NSAlert()
                    a.messageText = "Force “\(vm.config.name)” to power off?"
                    a.informativeText = "This is like pulling the plug: unsaved work is lost and Mac OS X may need to repair its disk."
                    a.addButton(withTitle: "Cancel"); a.addButton(withTitle: "Force Power Off")
                    if a.runModal() == .alertSecondButtonReturn { vm.forcePowerOff() }
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Virtual Mac…") { NotificationCenter.default.post(name: .newVirtualMac, object: nil) }
                    .keyboardShortcut("n")
                Button("Add Existing Virtual Mac…") { NotificationCenter.default.post(name: .addVirtualMac, object: nil) }
                    .keyboardShortcut("o")
            }
        }

        Window("Service Hub", id: "services") {
            ServicesView()
        }
        .windowResizability(.contentMinSize)
    }
}

/// Window → Service Hub (the mail proxy and friends).
struct OpenServicesButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button("Service Hub") { openWindow(id: "services") }
            .keyboardShortcut("h", modifiers: [.command, .shift])
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ServicesHub.shared.start() }
    }

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
