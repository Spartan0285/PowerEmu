import SwiftUI
import AppKit
import ServiceManagement

@main
struct PowerEmuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary()

    var body: some Scene {
        WindowGroup("PowerEmu") {
            ContentView()
                .environmentObject(library)
                .frame(minWidth: 760, minHeight: 520)
                .onAppear {
                    appDelegate.library = library
                    library.autoStartOnce()
                    library.developerAutoInstall()
                    Feedback.flushOutbox()
                }
        }
        .windowResizability(.contentMinSize)
        .commands {
            // The standard About panel cannot carry the stage badge, the
            // alpha sentence or what PowerEmu is not, so it draws its own.
            CommandGroup(replacing: .appInfo) {
                Button("About PowerEmu") { AboutWindowController.present() }
                Button("Check for Updates\u{2026}") { UpdateWindowController.checkNow(library: library) }
            }
            CommandGroup(replacing: .help) {
                Button("Send Feedback…") { FeedbackWindowController.present() }
            }
            CommandGroup(after: .windowList) {
                OpenServicesButton()
            }
            CommandMenu("Machine") {
                Button("Release Mouse  (⌃⌥G)") { VMWindowController.key?.display.ungrab() }
                Button("Full Screen  (⌃⌥F)") { VMWindowController.key?.window?.toggleFullScreen(nil) }
                Button("Show Performance  (⌃⌥P)") { VMWindowController.key?.display.togglePerformance() }
                Divider()
                Button("Pause") { VMWindowController.key?.vm.pause() }
                    .keyboardShortcut("p", modifiers: [.command, .control])
                Button("Continue") { VMWindowController.key?.vm.resume() }
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

        Settings {
            AppSettingsView()
        }
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
    /// object: the machine's package URL
    static let selectVirtualMac = Notification.Name("PowerEmuSelectVirtualMac")
}

/// Quitting PowerEmu would leave running virtual Macs without their
/// controls, so ask first.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var library: VMLibrary?

    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated { ServicesHub.shared.start() }
        /*
         * Look for a newer PowerEmu, quietly: at most once a day, never for
         * a version the reader has skipped, and only ever offering.  A
         * little after opening, so it is not competing with the machines
         * that start with the app.
         */
        let lib = MainActor.assumeIsolated { library }
        if MainActor.assumeIsolated({ Updater.runCommandLine(CommandLine.arguments, library: lib) }) {
            return                      // --update-check / --update-install
        }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await Updater.checkInBackground(library: lib)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // An install can't be picked up again, so say what quitting costs.
        let installing = MainActor.assumeIsolated { library?.installing ?? [] }
        if !installing.isEmpty {
            let a = NSAlert()
            a.messageText = "Stop installing Mac OS X?"
            a.informativeText = "Quitting PowerEmu stops the installation. You would need to start it again from the beginning."
            a.addButton(withTitle: "Keep Installing")
            a.addButton(withTitle: "Stop and Quit")
            guard a.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
            MainActor.assumeIsolated { for s in installing { s.cancel() } }
        }
        let running = MainActor.assumeIsolated {
            library?.machines.filter { $0.state != .stopped } ?? []
        }
        guard !running.isEmpty else { return .terminateNow }

        /*
         * A virtual Mac cannot simply be left behind: its window belongs to
         * PowerEmu, so once PowerEmu has gone there is no window, no menu
         * and no way to reach it. So quitting means deciding what happens
         * to it -- put it to sleep and have everything exactly as it was
         * next time, or shut Mac OS X down properly.
         */
        let names = running.map { $0.config.name }
        let a = NSAlert()
        a.messageText = names.count == 1 ? "What should “\(names[0])” do before quitting?"
                                         : "What should \(names.count) virtual Macs do before quitting?"
        a.informativeText = "Sleep saves everything as it is, in the virtual Mac's disk, and "
                          + "puts it back when you start it again. Shutting down closes Mac OS X "
                          + "properly, so save your work in it first."
        a.addButton(withTitle: "Sleep and Quit")
        a.addButton(withTitle: "Shut Down and Quit")
        a.addButton(withTitle: "Cancel")
        let choice = a.runModal()
        guard choice != .alertThirdButtonReturn else { return .terminateCancel }
        let sleeping = choice == .alertFirstButtonReturn

        Task { @MainActor in
            if sleeping {
                for vm in running { vm.sleep() }
                // Writing a machine's memory takes a while; a machine that
                // fails to sleep is shut down rather than left stranded.
                for _ in 0..<240 {
                    if running.allSatisfy({ $0.state == .stopped }) { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            } else {
                for vm in running { vm.requestShutDown() }
                // Give Mac OS X a moment to go down on its own; a guest that
                // ignores it is powered off rather than left behind.
                for _ in 0..<20 {
                    if running.allSatisfy({ $0.state == .stopped }) { break }
                    try? await Task.sleep(nanoseconds: 500_000_000)
                }
            }
            for vm in running where vm.state != .stopped { vm.forcePowerOff() }
            try? await Task.sleep(nanoseconds: 500_000_000)
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

/// PowerEmu → Settings: opening at login.
struct AppSettingsView: View {
    @State private var status = SMAppService.mainApp.status
    @State private var problem: String?
    @State private var checksForUpdates =
        UserDefaults.standard.object(forKey: Updater.automaticKey) as? Bool ?? true

    var body: some View {
        Form {
            Toggle("Open PowerEmu when you log in", isOn: Binding(
                get: { status == .enabled || status == .requiresApproval },
                set: { on in
                    problem = nil
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        problem = error.localizedDescription
                    }
                    status = SMAppService.mainApp.status
                }))
            if status == .requiresApproval {
                Text("Allow PowerEmu in System Settings → General → Login Items.")
                    .font(.caption).foregroundStyle(.orange)
            }
            if let problem {
                Text(problem).font(.caption).foregroundStyle(.red)
            }
            Text("Virtual Macs with “Start when PowerEmu opens” turned on (in their Startup settings) start with it.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Toggle("Look for new versions of PowerEmu", isOn: $checksForUpdates)
                .onChange(of: checksForUpdates) { _, on in
                    UserDefaults.standard.set(on, forKey: Updater.automaticKey)
                }
            Text("Checked at most once a day, and never installed without asking. Use PowerEmu \u{2192} Check for Updates to look now.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { status = SMAppService.mainApp.status }
    }
}
