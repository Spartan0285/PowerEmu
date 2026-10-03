import SwiftUI
import AppKit
import ServiceManagement

@main
struct PowerEmuApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var library = VMLibrary()

    var body: some Scene {
        Window("PowerEmu", id: "configuration") {
            ContentView()
                .environmentObject(library)
                .background(ConfigurationWindowAccess(delegate: appDelegate))
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
                Button("What\u{2019}s New in PowerEmu") { WhatsNewWindowController.present() }
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
    weak var configurationWindow: NSWindow?
    var openConfiguration: (() -> Void)?

    /*
     * A file sent here from this Mac's Finder -- "Open With > PowerEmu", or
     * dropped on PowerEmu's Dock tile.
     *
     * PowerEmu opens nothing itself; the running virtual Mac does, with one of
     * its own applications.  Which virtual Mac is only a question when more
     * than one is running, so ask then and not otherwise.
     */
    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        var urls = filenames.map { URL(fileURLWithPath: $0) }
        /*
         * A virtual Mac is not a file to hand to a virtual Mac.  Opening one
         * opens that machine here, which is what dropping it on PowerEmu
         * plainly means.
         */
        let machines = urls.filter { $0.pathExtension == "poweremu" }
        urls.removeAll { $0.pathExtension == "poweremu" }
        if !machines.isEmpty {
            MainActor.assumeIsolated { library?.reload() }
            openConfiguration?()
            if urls.isEmpty { sender.reply(toOpenOrPrint: .success); return }
        }
        let running = MainActor.assumeIsolated {
            (library?.machines ?? []).filter { $0.state == .running && $0.agent?.connected == true }
        }
        guard !running.isEmpty else {
            let a = NSAlert()
            a.messageText = urls.count == 1
                ? "No virtual Mac is ready to open “\(urls[0].lastPathComponent)”"
                : "No virtual Mac is ready to open these files"
            a.informativeText = "Start a virtual Mac with PowerEmu Tools installed, then try again."
            a.runModal()
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        let target: VirtualMachine
        if running.count == 1 {
            target = running[0]
        } else {
            let a = NSAlert()
            a.messageText = "Which virtual Mac should open this?"
            for m in running.prefix(3) { a.addButton(withTitle: m.config.name) }
            a.addButton(withTitle: "Cancel")
            let picked = a.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
            guard picked >= 0, picked < min(running.count, 3) else {
                sender.reply(toOpenOrPrint: .failure); return
            }
            target = running[picked]
        }
        MainActor.assumeIsolated {
            for url in urls { target.openInGuest(url) }
        }
        sender.reply(toOpenOrPrint: .success)
    }

    /// The Dock menu.  In Harmony the guest's windows have no shared title bar
    /// or toolbar to reach, so offer a way out here.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        menu.addItem(withTitle: "Show Configuration", action: #selector(showConfiguration), keyEquivalent: "").target = self
        menu.addItem(.separator())
        if MainActor.assumeIsolated({ VMDisplayView.harmonized }) != nil {
            menu.addItem(withTitle: "Exit Harmony", action: #selector(exitHarmony), keyEquivalent: "")
                .target = self
        }
        // The guest's own applications, so they can be reached from this Mac's
        // Dock while Harmony is on -- the guest's Dock is put away, and macOS
        // will not let one app add Dock tiles for another's windows, so they
        // live in this menu.
        /*
         * Any running machine, not only one in Harmony.  The list was reached
         * through VMDisplayView.harmonized, which is nil unless Harmony is on,
         * so a guest running in an ordinary window offered nothing here at all.
         */
        if let d = MainActor.assumeIsolated({ VMDisplayView.harmonized ?? VMDisplayView.showing }) {
            let apps = MainActor.assumeIsolated { d.guestApps }
            if !apps.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let header = NSMenuItem(title: "Virtual Mac", action: nil, keyEquivalent: "")
                header.isEnabled = false
                menu.addItem(header)
                menu.addItem(withTitle: "Keep This List on Screen",
                             action: #selector(showGuestAppsPanel), keyEquivalent: "").target = self
                for a in apps {
                    let item = NSMenuItem(title: a.app, action: #selector(openGuestApp(_:)), keyEquivalent: "")
                    item.target = self
                    item.tag = a.pid
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
            }
            /*
             * And the guest's own Dock -- what somebody keeps there, running or
             * not.  Harmony hides that Dock, so without this there is no way to
             * open anything that is not already up.  Needs PowerEmu Tools 2.21.
             */
            let dockApps = MainActor.assumeIsolated { d.guestDockApps }.filter { $0.pid == 0 }
            if !dockApps.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let h = NSMenuItem(title: "In the Virtual Mac's Dock", action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                for a in dockApps.prefix(16) {
                    let item = NSMenuItem(title: a.name, action: #selector(launchGuestApp(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = a.path
                    item.indentationLevel = 1
                    menu.addItem(item)
                }
                menu.addItem(NSMenuItem.separator())
            }
        }
        // Windows the guest has put in its own Dock, which is hidden while
        // Harmony is on -- without these there would be no way back to them.
        if let d = MainActor.assumeIsolated({ VMDisplayView.harmonized ?? VMDisplayView.showing }) {
            let mins = MainActor.assumeIsolated { d.minimizedGuestWindows }
            if !mins.isEmpty {
                menu.addItem(NSMenuItem.separator())
                let h = NSMenuItem(title: "Minimized", action: nil, keyEquivalent: "")
                h.isEnabled = false
                menu.addItem(h)
                for (i, w) in mins.enumerated() where i < 12 {
                    let item = NSMenuItem(title: w.title.isEmpty ? "Untitled" : w.title,
                                          action: #selector(restoreGuestWindow(_:)), keyEquivalent: "")
                    item.target = self
                    item.indentationLevel = 1
                    item.representedObject = [w.pid, w.index]
                    menu.addItem(item)
                }
            }
        }
        // The overlay carries the pointer readout, so it has to be reachable in
        // Harmony, where there is no toolbar of ours on screen.
        if let d = MainActor.assumeIsolated({ VMDisplayView.harmonized ?? VMWindowController.key?.display }) {
            let on = MainActor.assumeIsolated { d.showsPerformance }
            menu.addItem(withTitle: on ? "Hide Performance Overlay" : "Show Performance Overlay",
                         action: #selector(togglePerfOverlay), keyEquivalent: "").target = self
        }
        return menu.numberOfItems > 0 ? menu : nil
    }

    @MainActor @objc private func showConfiguration() {
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        openConfiguration?()
        if let window = configurationWindow {
            if window.isMiniaturized { window.deminiaturize(nil) }
            window.makeKeyAndOrderFront(nil)
        }
    }

    @MainActor @objc private func exitHarmony() {
        VMDisplayView.harmonized?.requestHarmony(false)
    }

    @MainActor @objc private func openGuestApp(_ sender: NSMenuItem) {
        (VMDisplayView.harmonized ?? VMDisplayView.showing)?.activateGuestApp(sender.tag)
    }

    @MainActor @objc private func launchGuestApp(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        (VMDisplayView.harmonized ?? VMDisplayView.showing)?.onLaunchGuestApp?(path)
    }

    /// The same list, kept on screen above everything, so it can be used
    /// without holding the Dock icon down each time.
    @MainActor @objc private func showGuestAppsPanel() {
        (VMDisplayView.harmonized ?? VMDisplayView.showing)?.showGuestAppsPanel()
    }

    @MainActor @objc private func restoreGuestWindow(_ sender: NSMenuItem) {
        guard let pair = sender.representedObject as? [Int], pair.count == 2 else { return }
        VMDisplayView.harmonized?.restoreGuestWindow(pair[0], pair[1])
    }

    @MainActor @objc private func togglePerfOverlay() {
        (VMDisplayView.harmonized ?? VMWindowController.key?.display)?.togglePerformance()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before anything else, and before any machine starts: using
        // something is not the same as having been told what it does.
        MainActor.assumeIsolated { TermsWindowController.presentIfNeeded() }
        // Developer testing: POWEREMU_TEST_NO_SERVICES starts the app with no
        // listeners at all.  The mail, Web Accelerator and PowerMusic sockets
        // live at fixed paths in the temporary directory -- a path Foundation
        // takes from the user record, so no environment variable moves it --
        // and each listener unlinks its path before binding.  A second copy of
        // PowerEmu started for testing therefore takes those sockets away from
        // the copy already running, and the first copy's guests lose their
        // services with nothing to say so.  This is how to look at the
        // windows without touching them.
        if ProcessInfo.processInfo.environment["POWEREMU_TEST_NO_SERVICES"] == nil {
            MainActor.assumeIsolated { ServicesHub.shared.start() }
        }
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
        // Opened for the first time since an update: say what changed.
        MainActor.assumeIsolated { WhatsNewWindowController.presentIfJustUpdated() }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await Updater.checkInBackground(library: lib)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Leave the guest at its own resolution, not Harmony's: it remembers
        // the last one and boots into it.
        MainActor.assumeIsolated { VMDisplayView.harmonized?.restoreGuestResolutionIfNeeded() }
        // Take the guest's Dock tiles down on the way out.  They stand for
        // applications in a virtual Mac that is about to stop existing, and
        // nothing else will clear them until the next run.
        MainActor.assumeIsolated { VMDisplayView.harmonized?.stopGuestDock() }
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
            Divider()
            HStack {
                Text("Terms and Conditions")
                Spacer()
                Button("Read\u{2026}") { TermsWindowController.present() }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .onAppear { status = SMAppService.mainApp.status }
    }
}

/// Keeps the Dock action available even after the configuration window closes.
private struct ConfigurationWindowAccess: NSViewRepresentable {
    @Environment(\.openWindow) private var openWindow
    let delegate: AppDelegate
    func makeNSView(context: Context) -> Probe { Probe() }
    func updateNSView(_ view: Probe, context: Context) {
        delegate.openConfiguration = { openWindow(id: "configuration") }
        view.register = { [weak delegate] window in delegate?.configurationWindow = window }
        if let window = view.window { view.register?(window) }
    }
    final class Probe: NSView {
        var register: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { register?(window) }
        }
    }
}
