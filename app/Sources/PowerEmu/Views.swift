import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Library window

struct ContentView: View {
    @EnvironmentObject var library: VMLibrary
    @State private var selection: URL?
    @State private var showingImport = false
    @State private var showingNew = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.machines) { vm in
                    MachineRow(vm: vm).tag(vm.url)
                        .contextMenu {
                            Button("Move Up") { library.moveMachine(vm, by: -1) }
                                .disabled(library.machines.first?.url == vm.url)
                            Button("Move Down") { library.moveMachine(vm, by: 1) }
                                .disabled(library.machines.last?.url == vm.url)
                        }
                }
                .onMove { library.moveMachines(from: $0, to: $1) }
            }
            // Rebuilt when machines come and go: a List that has a row
            // inserted and selected keeps a scroll offset that hides the
            // top row under the toolbar.
            .id(library.machines.map { $0.url.path }.sorted())
            .safeAreaInset(edge: .bottom) { ServiceHubButton() }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Menu {
                        Button("New Virtual Mac…") { showingNew = true }
                        Button("Add Existing Virtual Mac…") { showingImport = true }
                    } label: { Label("Add Virtual Mac", systemImage: "plus") }
                        .help("Make a new virtual Mac or add one from existing disks")
                }
            }
            .overlay {
                if library.machines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Virtual Macs").font(.headline)
                        Button("New Virtual Mac…") { showingNew = true }
                        Button("Add Existing Virtual Mac…") { showingImport = true }
                    }
                }
            }
        } detail: {
            if let vm = library.machines.first(where: { $0.url == selection }) {
                MachineDetail(vm: vm)
            } else {
                Text("Select a virtual Mac").foregroundStyle(.secondary)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .newVirtualMac)) { _ in showingNew = true }
        .onReceive(NotificationCenter.default.publisher(for: .addVirtualMac)) { _ in showingImport = true }
        .onReceive(NotificationCenter.default.publisher(for: .selectVirtualMac)) { n in
            if let u = n.object as? URL { select(u) }
        }
        .sheet(isPresented: $showingImport) {
            ImportSheet { vm in selection = vm.url }
        }
        .sheet(isPresented: $showingNew) {
            NewMachineSheet(initialDisc: ProcessInfo.processInfo.environment["POWEREMU_TEST_NEW_SHEET"].map(URL.init(fileURLWithPath:))) { vm in select(vm.url) }
        }
        .onAppear {
            // Developer testing: POWEREMU_TEST_NEW_SHEET=<disc> opens the sheet with it chosen.
            if ProcessInfo.processInfo.environment["POWEREMU_TEST_NEW_SHEET"] != nil { showingNew = true }
        }
        .onAppear { if selection == nil { selection = library.machines.first?.url } }
        .alert("Could Not Save Order", isPresented: Binding(
            get: { library.loadError != nil }, set: { if !$0 { library.loadError = nil } })) {
                Button("OK") { library.loadError = nil }
            } message: { Text(library.loadError ?? "") }
        .background(NoTitlebarSeparator())
    }

    /// Select a machine that was just added. Selecting it in the same pass
    /// that inserts its row scrolls the list so the row sits under the
    /// toolbar, half hidden; a moment later it lands where it should.
    private func select(_ url: URL) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { selection = url }
    }
}

/// Turns off the window's own title-bar separator. The split view draws the
/// line under the toolbar itself; the window's line could also turn up
/// across the middle of the toolbar, at plain title-bar height, while a
/// virtual Mac was running.
struct NoTitlebarSeparator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { Probe() }
    func updateNSView(_ v: NSView, context: Context) {}

    final class Probe: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.titlebarSeparatorStyle = .none
        }
    }
}

/// At the foot of the sidebar: the Service Hub, which serves all old Macs.
struct ServiceHubButton: View {
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Button { openWindow(id: "services") } label: {
            Label("Service Hub", systemImage: "network").frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 12).padding(.vertical, 8)
        .help("Mail and other services for old Macs, virtual and real")
    }
}

struct MachineRow: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var vm: VirtualMachine
    private var subtitle: String {
        switch vm.state {
        case .stopped: return vm.asleep ? "Asleep" : vm.config.osName
        case .paused:  return "Paused"
        case .sleeping: return "Going to sleep…"
        default:       return "Running"
        }
    }
    var body: some View {
        HStack(spacing: 10) {
            MachineIcon(model: vm.config.model, size: 30, running: vm.state != .stopped)
            VStack(alignment: .leading) {
                Text(vm.config.name).font(.headline)
                if let s = library.installs[vm.url], s.outcome == .running {
                    InstallRowStatus(session: s)
                } else {
                    Text(subtitle).font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 3)
    }
}

/// "Installing… 42%" under a machine's name, following its install.
struct InstallRowStatus: View {
    @ObservedObject var session: InstallSession
    var body: some View {
        Text("Installing… \(Int(session.fraction * 100))%")
            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
    }
}

/// The Mac a virtual Mac looks like, with a green dot while it runs.
struct MachineIcon: View {
    let model: String?
    let size: CGFloat
    var running = false
    var body: some View {
        let m = MacModel.named(model)
        ZStack(alignment: .bottomTrailing) {
            if let img = m?.image {
                Image(nsImage: img).resizable().interpolation(.high).frame(width: size, height: size)
            } else {
                Image(systemName: m?.symbol ?? "desktopcomputer")
                    .font(.system(size: size * 0.7))
                    .foregroundStyle(running ? Color.green : Color.secondary)
                    .frame(width: size, height: size)
            }
            if running, m?.image != nil {
                Circle().fill(.green).frame(width: size * 0.26, height: size * 0.26)
                    .overlay(Circle().stroke(.background, lineWidth: 1.5))
            }
        }
    }
}

// MARK: - One virtual Mac

struct MachineDetail: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var vm: VirtualMachine
    @ObservedObject private var hostScreens = HostScreens.shared
    @State private var confirmForce = false
    @State private var confirmDiscardSleep = false
    @State private var confirmTrash = false
    @State private var error: String?
    @State private var snapshotName = ""
    @State private var snapshots: [(tag: String, date: String, size: String)] = []
    @State private var busy: String?
    @State private var duplicating = false

    /// Snapshots are QEMU's, so they need the emulator to be the thing
    /// holding the disk.
    private var machineRunning: Bool { vm.state != .stopped }

    private func duplicate(linked: Bool) {
        busy = "Copying…"
        do {
            _ = try library.duplicate(vm, linked: linked)
            busy = nil
        } catch {
            busy = nil
            self.error = error.localizedDescription
        }
    }

    private var locked: Bool { vm.state != .stopped || installing }

    private var install: InstallSession? { library.installs[vm.url] }
    private var installing: Bool { install?.outcome == .running }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
            if let install {
                InstallProgressSection(session: install)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 16) {
                    MachineIcon(model: vm.config.model, size: 56, running: locked)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.config.name).font(.title2.bold())
                        Text("\(vm.config.osName) · \(vm.config.memoryMB >= 1024 ? "\(vm.config.memoryMB / 1024) GB" : "\(vm.config.memoryMB) MB") · PowerPC G4")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if installing {
                        Label("Installing…", systemImage: "arrow.down.circle")
                            .foregroundStyle(.secondary).font(.headline)
                    } else if vm.state == .stopped {
                        Button { vm.start() } label: {
                            // A machine with its memory saved is woken, not started.
                            Label(vm.asleep ? "Wake" : "Start",
                                  systemImage: vm.asleep ? "sun.max.fill" : "play.fill")
                                .frame(minWidth: 80)
                        }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Label(vm.state == .starting ? "Starting…"
                              : vm.state == .paused ? "Paused"
                              : vm.state == .sleeping ? "Going to sleep…" : "Running",
                              systemImage: "circle.fill")
                            .foregroundStyle(vm.state == .paused ? .orange : .green).font(.headline)
                        if vm.hasWindow {
                            Button("Show Window") { vm.showWindow() }
                        }
                    }
                }
                if let e = vm.lastError ?? error {
                    Text(e).foregroundStyle(.red).font(.callout).textSelection(.enabled)
                }
                if locked {
                    Text("Settings can be changed while the virtual Mac is shut down.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            }
            .padding(20)
            TabView {
                generalTab
                storageTab
                displayTab
                sharingTab
                devicesTab
                advancedTab
            }
            .padding([.horizontal, .bottom], 12)
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { controls }
        }
        .confirmationDialog("Start “\(vm.config.name)” from the beginning?",
                            isPresented: $confirmDiscardSleep) {
            Button("Start Fresh", role: .destructive) { vm.discardSleep() }
        } message: {
            Text("What the virtual Mac was doing when it went to sleep is thrown away, as if it had been switched off. Anything unsaved in it is lost.")
        }
        .confirmationDialog("Force “\(vm.config.name)” to power off?", isPresented: $confirmForce) {
            Button("Force Power Off", role: .destructive) { vm.forcePowerOff() }
        } message: {
            Text("This is like pulling the plug: unsaved work is lost and Mac OS X may need to repair its disk. Use Shut Down when you can.")
        }
        .confirmationDialog("Move “\(vm.config.name)” to the Trash?", isPresented: $confirmTrash) {
            Button("Move to Trash", role: .destructive) {
                do { try library.moveToTrash(vm) } catch { self.error = error.localizedDescription }
            }
        } message: {
            Text("Its disks and settings go to the Trash. The original disks you imported are not affected.")
        }
    }

    private var generalTab: some View {
        Form {
            Section("General") {
                TextField("Name", text: binding(\.name))
                TextField("System", text: binding(\.osName))
                Picker("CPUs", selection: binding(\.cpuCount)) {
                    Text("1 CPU").tag(1)
                    // Classic Mac OS is single-processor: Mac OS 9 runs on one
                    // CPU whatever the machine has, so a second is not offered.
                    if !vm.config.classic,
                       SMPCapabilities.load(helper: VMRunner.helperURL) != nil || vm.config.cpuCount > 1 {
                        Text("2 CPUs (experimental)").tag(2)
                        Text("4 CPUs (experimental)").tag(4)
                    }
                }
                .disabled(vm.asleep || vm.config.classic)
                if vm.config.classic {
                    Text("\(vm.config.osName) uses one processor.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if vm.asleep {
                    Text("Wake and shut down this virtual Mac before changing its CPUs.")
                        .font(.caption).foregroundStyle(.secondary)
                } else if SMPCapabilities.load(helper: VMRunner.helperURL) != nil {
                    Text("Two CPUs can speed up apps that do parallel work. Choose one CPU if an app has problems.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Picker("Memory", selection: binding(\.memoryMB)) {
                    ForEach(vm.config.classic ? VMConfig.classicMemoryChoices
                                              : [512, 768, 1024, 1536, 2048], id: \.self) {
                        Text($0 >= 1024 ? "\(Double($0) / 1024, specifier: "%g") GB" : "\($0) MB").tag($0)
                    }
                }
                if vm.config.classic {
                    // Measured: 1 GB starts, 1.5 GB and 2 GB fail in Open
                    // Firmware before the Mac OS ROM runs.
                    Text("More than 1 GB stops \(vm.config.osName) starting.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            Section("Startup") {
                Toggle("Start from the disc in the drive (to install)", isOn: binding(\.bootFromDisc))
                    .disabled(vm.config.insertedDisc == nil)
                Picker("Startup chime", selection: Binding(
                    get: { vm.config.bootChime ? vm.config.chimeSound : "none" },
                    set: { v in
                        guard !locked else { return }
                        if v == "none" { vm.config.bootChime = false }
                        else if v == "custom" { chooseChimeFile() }
                        else { vm.config.bootChime = true; vm.config.chimeSound = v; Chime.play(v) }
                        try? vm.save()
                    })) {
                    Text("None").tag("none")
                    ForEach(Chime.choices, id: \.0) { c in
                        Text(c.0 == "custom" && vm.config.chimeFile != nil
                             ? "Sound file: " + ((vm.config.chimeFile! as NSString).lastPathComponent)
                             : c.1).tag(c.0)
                    }
                }
                Toggle("Start when PowerEmu opens", isOn: binding(\.autoStart))
                /*
                 * These three are Mac OS X boot-args.  Classic Mac OS has no
                 * equivalent PowerEmu can set from here: extensions are
                 * skipped by holding Shift as the guest starts, and there is
                 * no single-user mode at all.
                 */
                Group {
                    Toggle("Verbose startup (show messages instead of the Apple logo)", isOn: binding(\.verboseBoot))
                    Toggle("Safe Boot (skip third-party extensions)", isOn: binding(\.safeBoot))
                    Toggle("Single-user mode (a root prompt instead of the desktop)", isOn: binding(\.singleUser))
                }
                .disabled(vm.config.classic)
                if vm.config.classic {
                    Text("These are Mac OS X startup options. In \(vm.config.osName), hold Shift as it starts to skip extensions.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

                }.formStyle(.grouped).disabled(locked)
                    .tabItem { Text("General") }
    }

    private var storageTab: some View {
        Form {
                    DisksSection(vm: vm, error: $error).disabled(locked)
                    DriveSection(vm: vm)
                }.formStyle(.grouped).tabItem { Text("Storage") }
    }

    /*
     * What to pick in the guest, worked out from the screen this Mac actually
     * has rather than named outright.  The sizes used to be written into the
     * sentence, which was right on one machine and wrong on every other.
     */
    /// The startup resolution, as one choice rather than two numbers.
    private var startupResolution: Binding<String> {
        Binding(get: { "\(vm.config.bootWidth)x\(vm.config.bootHeight)" },
                set: { v in
                    guard !locked else { return }
                    let parts = v.split(separator: "x").compactMap { Int($0) }
                    guard parts.count == 2 else { return }
                    vm.config.bootWidth = parts[0]
                    vm.config.bootHeight = parts[1]
                    do { try vm.save() } catch { self.error = error.localizedDescription }
                })
    }

    private static var screenAdvice: String {
        guard let screen = NSScreen.main else {
            return "Modes shaped like this Mac’s screen are offered"
        }
        let full = HarmonyDisplayMode.size(screen: screen)
        let notch = HarmonyDisplayMode.notch(on: screen)
        let whole = Int(screen.frame.height.rounded())
        let w = Int(full.width)
        if notch > 0 {
            return "\(w) × \(Int(full.height)) sits below the notch in fullscreen; "
                 + "\(w) × \(whole) fills the screen and puts the guest’s menu bar behind it"
        }
        return "\(w) × \(Int(full.height)) fills this Mac’s screen"
    }

    private var displayTab: some View {
        Form {
            Section {
                Picker("Startup resolution", selection: startupResolution) {
                    ForEach(VMConfig.displayModes(for: NSScreen.main), id: \.self) { m in
                        Text("\(m.label) — \(m.width) × \(m.height)")
                            .tag("\(m.width)x\(m.height)")
                    }
                    // Whatever the machine is set to now, if it is not one of
                    // the offered sizes, so opening this page never silently
                    // changes it.
                    if !VMConfig.displayModes(for: NSScreen.main)
                        .contains(where: { $0.width == vm.config.bootWidth && $0.height == vm.config.bootHeight }) {
                        Text("\(vm.config.bootWidth) × \(vm.config.bootHeight)")
                            .tag("\(vm.config.bootWidth)x\(vm.config.bootHeight)")
                    }
                }
                Toggle("Start in fullscreen", isOn: binding(\.startFullscreen))
                Toggle("Discard changes on shutdown", isOn: binding(\.discardChanges))
                Toggle("Isolate from this Mac", isOn: binding(\.isolated))
                Toggle("Offer resolutions shaped like this Mac’s screen", isOn: binding(\.extraDisplayModes))
                Picker("Scaling", selection: displayBinding(\.scaling, { $0.scaling = $1 })) {
                    ForEach(VMConfig.scalingChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Display filter", selection: displayBinding(\.panelFilter, { $0.panelFilter = $1 })) {
                    ForEach(PanelFilters.choices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Picker("Picture", selection: displayBinding(\.displayFit, { $0.displayFit = $1 })) {
                    ForEach(VMConfig.displayFitChoices, id: \.0) { Text($0.1).tag($0.0) }
                }
                Toggle("Hardware cursor", isOn: binding(\.hardwareCursor))
                /*
                 * "Two" is offered only when this Mac has somewhere to put
                 * the second window.  A machine already set to two screens
                 * keeps the choice visible even on one screen, so the reader
                 * can see what it is set to and switch it back -- hiding it
                 * would strand the setting.
                 */
                Picker("Screens", selection: binding(\.displays)) {
                    Text("One").tag(1)
                    Text("Two").tag(2)
                }.disabled(vm.config.classic)
                if !hostScreens.canUseTwo && !vm.config.classic
                    && vm.config.displays > 1 {
                    Text("This Mac has one screen, so both guest screens share "
                         + "the machine\u{2019}s window, side by side.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if vm.config.displays > 1 && !vm.config.classic {
                    Picker("Second screen", selection: binding(\.display2Width)) {
                        ForEach(VMConfig.secondScreenSizes, id: \.0) {
                            Text($0.2).tag($0.0)
                        }
                    }
                    .onChange(of: vm.config.display2Width) { _, w in
                        if let m = VMConfig.secondScreenSizes.first(where: { $0.0 == w }) {
                            vm.config.display2Height = m.1
                            try? vm.save()
                        }
                    }
                }
                Picker("Video memory", selection: binding(\.vramMB)) {
                    ForEach(vm.config.classic ? VMConfig.classicVRAMChoices
                                              : VMConfig.vramChoices, id: \.self) { Text("\($0) MB").tag($0) }
                }
                if vm.config.displays > 1 && vm.config.vramMB > 128 {
                    Text("With two screens each card is held at 128 MB: two "
                         + "cards of 256 MB do not fit in this Mac\u{2019}s PCI "
                         + "window, and Mac OS X stops when it cannot reach "
                         + "the second card.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Graphics acceleration") {
                    // Quartz Extreme and the OpenGL renderer are Mac OS X's,
                    // driven by its own ATI driver.  Classic Mac OS has
                    // neither; it draws through the card's framebuffer.
                    Text(vm.config.classic ? "Not available in \(vm.config.osName)"
                                           : "On — Quartz Extreme and OpenGL")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Display")
            } footer: {
                Text("Mac OS X drives the emulated Radeon with its own ATI driver, so Quartz Extreme and OpenGL are available; more video memory lets games and the desktop keep more textures on the card. No ROM files are needed.\n\nA second screen is a second graphics card, the way a Power Mac did it: Mac OS X extends its desktop across the two and arranges them in System Preferences \u{2192} Displays. It costs a second card\u{2019}s worth of video memory, and the pointer moves between the screens by relative motion, so a two-screen machine captures the mouse \u{2014} Control-Option-G gives it back.\n\nWhile starting from an install disc the card is held at 64 MB, because the Mac OS X installer will not start with more. Your choice applies once Mac OS X is installed.\n\nPick the resolution inside Mac OS X, in System Preferences → Displays. \(Self.screenAdvice). Fullscreen: Control-Option-F; Control-Option-G releases the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
            }

                }.formStyle(.grouped).disabled(locked).tabItem { Text("Display") }
    }

    private var sharingTab: some View {
        Form {
            Section("Snapshots") {
                /*
                 * A snapshot is the whole machine -- memory, processor,
                 * devices -- written into its disk, so it can be returned to
                 * exactly.  QEMU can only do that while it is the thing
                 * holding the disk, which is why these need the machine
                 * running; the list itself is read from the disk and is
                 * readable either way.
                 */
                HStack {
                    TextField("Name", text: $snapshotName)
                    Button("Take") {
                        let n = snapshotName.isEmpty ? "Snapshot" : snapshotName
                        busy = "Saving the machine…"
                        vm.takeSnapshot(named: n) { err in
                            Task { @MainActor in
                                busy = nil
                                if let err { self.error = err } else { snapshotName = "" }
                                snapshots = vm.snapshots
                            }
                        }
                    }
                    .disabled(!machineRunning || busy != nil)
                }
                if !machineRunning {
                    Text("Start the virtual Mac to take or return to a snapshot.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                ForEach(snapshots, id: \.tag) { snap in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(snap.tag)
                            Text("\(snap.date) · \(snap.size)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Return To") {
                            busy = "Returning…"
                            vm.revertToSnapshot(named: snap.tag) { err in
                                Task { @MainActor in busy = nil; if let err { self.error = err } }
                            }
                        }.disabled(!machineRunning || busy != nil)
                        Button("Delete") {
                            vm.deleteSnapshot(named: snap.tag) { err in
                                Task { @MainActor in
                                    if let err { self.error = err }
                                    snapshots = vm.snapshots
                                }
                            }
                        }.disabled(!machineRunning || busy != nil)
                    }
                }
                if snapshots.isEmpty {
                    Text("None yet.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .onAppear { snapshots = vm.snapshots }

            Section("This Virtual Mac") {
                Button("Duplicate…") { duplicating = true }
                    .disabled(machineRunning || busy != nil)
                Button("Reclaim Disk Space") {
                    guard let d = vm.config.startupDiskConfig else { return }
                    busy = "Reclaiming…"
                    do {
                        let r = try library.compact(vm, disk: d)
                        busy = nil
                        let saved = max(0, r.before - r.after)
                        self.error = saved > 0
                            ? "Reclaimed \(ByteCountFormatter.string(fromByteCount: saved, countStyle: .file))."
                            : "Nothing to reclaim."
                    } catch {
                        busy = nil
                        self.error = error.localizedDescription
                    }
                }
                .disabled(machineRunning || busy != nil)
                if let busy { Text(busy).font(.caption).foregroundStyle(.secondary) }
            }
            .confirmationDialog("Duplicate this virtual Mac?", isPresented: $duplicating) {
                Button("Linked Copy (fast, shares disks)") { duplicate(linked: true) }
                Button("Full Copy") { duplicate(linked: false) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A linked copy starts out sharing this machine's disks, so it is quick and small, but this machine must not be changed afterwards or the copy will be spoiled. A full copy is independent and takes as much room as the disks.")
            }

            Section("Connectivity") {
                Toggle("Network", isOn: binding(\.network))
                Toggle("Reach the guest’s Remote Login (ssh) at localhost:\(String(vm.sshPortInUse ?? vm.config.sshPort ?? 2222))", isOn: Binding(
                    get: { vm.config.sshPort != nil },
                    set: { vm.config.sshPort = $0 ? 2222 : nil; try? vm.save() }))
                    .disabled(!vm.config.network || vm.config.classic)
                if vm.config.classic {
                    Text("\(vm.config.osName) has no Remote Login (ssh) to reach.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.disabled(locked)

                    NetworkShareSection(vm: vm)
                    SharedFoldersSection(vm: vm)
                }.formStyle(.grouped).tabItem { Text("Sharing") }
    }

    private var devicesTab: some View {
        Form {
                    Section {
                Picker("Sound", selection: binding(\.audio)) {
                    Text("On").tag("coreaudio")
                    Text("Off").tag("none")
                }
                .disabled(vm.config.classic)
                Toggle("Microphone", isOn: binding(\.microphone))
                    .disabled(vm.config.classic || vm.config.audio == "none")
                    } header: {
                        Text("Sound")
                    } footer: {
                        /*
                         * The emulated AWACS answers Mac OS X's driver, not
                         * Mac OS 9's: left in place, Apple Audio Extension
                         * takes an address error at startup.  PowerEmu keeps
                         * the sound hardware out of a classic guest's device
                         * tree entirely -- see VMRunner -- so there is nothing
                         * here to turn on.
                         */
                        if vm.config.classic {
                            Text("Sound is not available in \(vm.config.osName) yet. The emulated audio hardware answers Mac OS X's driver, and \(vm.config.osName) crashes on it at startup, so PowerEmu leaves it out.")
                                .font(.caption).foregroundStyle(.secondary)
                        } else {
                            Text("The microphone gives the virtual Mac a sound input, which it shows in System Preferences \u{2192} Sound. Nothing is recorded until something inside the virtual Mac starts recording, and this Mac asks your permission the first time that happens.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }.disabled(locked)
                    ToolsSection(vm: vm)
                    GamepadSection(vm: vm)
                }.formStyle(.grouped).tabItem { Text("Devices") }
    }

    private var advancedTab: some View {
        Form {
            Section("Developer") {
                Group {
                Toggle("QEMU monitor at localhost:\(String(vm.monitorPortInUse ?? vm.config.monitorPort ?? 4444))", isOn: Binding(
                    get: { vm.config.monitorPort != nil },
                    set: { vm.config.monitorPort = $0 ? 4444 : nil; try? vm.save() }))
                Toggle("AGP bridge (Quartz Extreme)", isOn: binding(\.agpBridge))
                Toggle("Show in QEMU’s own window (a separate app in the Dock)", isOn: Binding(
                    get: { !vm.config.embeddedDisplay }, set: { v in guard !locked else { return }; vm.config.embeddedDisplay = !v; try? vm.save() }))
                Toggle("Trace GPU registers (slow)", isOn: binding(\.gpuTrace))
                }
                .disabled(locked)
                HStack {
                    Button("Show Logs") { NSWorkspace.shared.open(vm.logsURL) }
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([vm.url]) }
                    Spacer()
                    Button("Move to Trash…", role: .destructive) { confirmTrash = true }.disabled(locked)
                }
            }
                }.formStyle(.grouped).tabItem { Text("Advanced") }
    }

    @ViewBuilder private var controls: some View {
        switch vm.state {
        case .stopped:
            HStack {
                Button { vm.start() } label: {
                    Label(vm.asleep ? "Wake" : "Start", systemImage: vm.asleep ? "sun.max.fill" : "play.fill")
                        .frame(minWidth: 80)
                }
                .buttonStyle(.borderedProminent).controlSize(.large)
                if vm.asleep {
                    Button("Start Fresh Instead…") { confirmDiscardSleep = true }
                        .help("Throw away what was saved and start Mac OS X from the beginning.")
                }
            }
        case .starting:
            ProgressView().controlSize(.small)
        case .sleeping:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Going to sleep…").foregroundStyle(.secondary)
            }
        case .running, .stopping:
            HStack {
                Button { vm.pause() } label: { Label("Pause", systemImage: "pause.fill") }
                    .help("Stop the virtual Mac where it stands. Nothing runs inside it until you continue.")
                    .disabled(vm.state != .running)
                Button { vm.sleep() } label: { Label("Sleep", systemImage: "moon.fill") }
                    .help("Save everything the virtual Mac is doing into its disk and close it. Starting it again puts it back exactly where it was.")
                if vm.toolsConnected {
                    Button { vm.requestShutDown() } label: { Label("Shut Down", systemImage: "power") }
                        .help("Shut down Mac OS X, as from the Apple menu; programs are asked to quit first.")
                } else {
                    Button { vm.requestShutDown() } label: { Label("Shut Down…", systemImage: "power") }
                        .help("Press the virtual Mac’s power key; Mac OS X asks whether to shut down.")
                }
                Button("Force Power Off") { confirmForce = true }
            }
        case .paused:
            HStack {
                Button { vm.resume() } label: { Label("Continue", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)
                    .help("Let the virtual Mac carry on from where it stopped.")
                Button { vm.sleep() } label: { Label("Sleep", systemImage: "moon.fill") }
                Button("Force Power Off") { confirmForce = true }
            }
        }
    }

    /// A sound of the user's own for the startup chime.
    private func chooseChimeFile() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [.audio]
        p.message = "Choose a sound to play when this virtual Mac starts."
        p.prompt = "Use"
        guard p.runModal() == .OK, let u = p.url else { return }
        vm.config.chimeFile = u.path
        vm.config.chimeSound = "custom"
        vm.config.bootChime = true
        Chime.play("custom", file: u.path)
    }

    /// A binding into the config that saves on every change; read-only while
    /// the machine runs.
    /*
     * Settings writes the stored value and nothing else, which is right for
     * most things -- they are read when the machine next starts.  The display
     * settings are not like that: the machine is usually on screen while they
     * are being changed, and the whole point of choosing a filter or a scaling
     * mode is to see it.  Scaling worked from the toolbar, which sets the live
     * view as well as the config, and did nothing from here; the display
     * filter had no toolbar control at all, so it appeared to do nothing
     * anywhere until the machine was restarted.
     *
     * So tell the open window too, if there is one.
     */
    private func displayBinding<T>(_ kp: WritableKeyPath<VMConfig, T>,
                                   _ apply: @escaping (VMDisplayView, T) -> Void) -> Binding<T> {
        Binding(get: { vm.config[keyPath: kp] },
                set: { v in
                    guard !locked else { return }
                    vm.config[keyPath: kp] = v
                    do { try vm.save() } catch { self.error = error.localizedDescription }
                    if let d = VMWindowController.open[vm.url]?.display { apply(d, v) }
                })
    }

    private func binding<T>(_ kp: WritableKeyPath<VMConfig, T>) -> Binding<T> {
        Binding(get: { vm.config[keyPath: kp] },
                set: { v in
                    guard !locked else { return }
                    vm.config[keyPath: kp] = v
                    do { try vm.save() } catch { self.error = error.localizedDescription }
                })
    }
}

/// Letting other Macs on the network see and reach this virtual Mac.
struct NetworkShareSection: View {
    @ObservedObject var vm: VirtualMachine
    @ObservedObject private var share: NetworkShare

    init(vm: VirtualMachine) {
        self.vm = vm
        self.share = vm.share
    }

    var body: some View {
        Section {
            Picker("Connection", selection: Binding(
                get: { vm.config.bridgedInterface ?? "" },
                set: { vm.config.bridgedInterface = $0.isEmpty ? nil : $0; try? vm.save() })) {
                Text("Private to this Mac").tag("")
                ForEach(NetBridge.interfaces()) { i in
                    Text("Bridged to \(i.label)").tag(i.bsdName)
                }
            }
            .disabled(vm.state != .stopped)
            Text(vm.config.bridgedInterface == nil
                 ? "The virtual Mac reaches the internet through this Mac, and nothing on your network can see it."
                 : "The virtual Mac gets its own address from your router and behaves like any other Mac on the network — it can see others, and they can see it. Starting it asks for an administrator, because only macOS itself may attach to a network interface this way.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let p = vm.bridge.problem {
                Label(p, systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
            Divider()
            Toggle("Share this virtual Mac on the local network", isOn: Binding(
                get: { vm.config.shareOnNetwork },
                set: { vm.config.shareOnNetwork = $0; try? vm.save() }))
                .disabled(vm.state != .stopped)
            if vm.config.shareOnNetwork {
                Text(vm.state == .stopped
                     ? "Other Macs will see “\(vm.config.name)” in their Finder when it is running."
                     : "Other Macs see “\(share.advertisedName)” in their Finder.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(NetworkShare.Service.all) { service in
                    HStack {
                        Text(service.name).font(.caption)
                        Spacer()
                        Text(share.open[service].map { "this Mac’s port \($0)" } ?? "when running")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
            Text("Sharing forwards a few services from this Mac into the virtual one and announces them, which a private virtual Mac needs to be reachable at all. A bridged one is already on the network in its own right. Either way the virtual Mac decides what it offers, in System Preferences → Sharing, and either way it exposes an old system to your network.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Network")
        }
    }
}

/// A game controller of this Mac, given to the virtual Mac as a plain USB
/// gamepad: the guest needs no driver, and the controller keeps talking to
/// this Mac, which knows how to read Xbox and PlayStation pads over
/// Bluetooth.
struct GamepadSection: View {
    @ObservedObject var vm: VirtualMachine

    var body: some View {
        Section {
            HStack {
                if let name = vm.gamepad?.controllerName {
                    Label("\(name) is connected", systemImage: "gamecontroller.fill")
                        .foregroundStyle(.green)
                } else if vm.state == .running && vm.config.gamepad {
                    Label("No controller connected to this Mac", systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                } else {
                    Label("The virtual Mac gets a USB gamepad when it starts",
                          systemImage: "gamecontroller")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { vm.config.gamepad },
                    set: { vm.config.gamepad = $0; try? vm.save() }))
                    .labelsHidden()
                    .disabled(vm.state != .stopped)
            }
            Text("Pair the controller with this Mac in System Settings. Mac OS X sees an ordinary USB gamepad, so games that read a controller find it; the setting takes effect when the virtual Mac next starts.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Game Controller")
        }
    }
}

/// PowerEmu Tools: whether the agent is running in the guest, installing
/// it, and what it offers.
struct ToolsSection: View {
    @ObservedObject var vm: VirtualMachine

    var body: some View {
        if vm.config.classic { classicSection } else { toolsSection }
    }

    /// Classic Mac OS: the agent cannot run, so the section says so rather
    /// than offering an install that would fail.
    private var classicSection: some View {
        Section {
            Label("Not available in \(vm.config.osName)", systemImage: "circle.slash")
                .foregroundStyle(.secondary)
            Toggle("Share the clipboard with this Mac", isOn: .constant(false)).disabled(true)
        } header: {
            Text("PowerEmu Tools")
        } footer: {
            Text("PowerEmu Tools is a Mac OS X application, so it does not run in \(vm.config.osName). The shared clipboard and Harmony need it.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var toolsSection: some View {
        Section {
            HStack {
                if let info = vm.agent?.info {
                    Label("Running in Mac OS X \(info.system) for \(info.user)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if vm.state == .running {
                    Label("Not running in the virtual Mac", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                } else {
                    Label("Start the virtual Mac to use or install them", systemImage: "circle.dashed")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if vm.toolsConnected {
                    Button("Restart") { vm.requestRestart() }
                        .help("Restart Mac OS X, as from the Apple menu.")
                }
                Button(vm.toolsConnected ? "Update Tools…" : "Install Tools…") { vm.insertToolsDisc() }
                    .disabled(vm.state != .running || VirtualMachine.toolsDiscURL == nil)
                    .help(VirtualMachine.toolsDiscURL == nil
                          ? "This copy of PowerEmu was built without the Tools disc."
                          : "Put the PowerEmu Tools disc in the drive; open its installer in Mac OS X.")
            }
            Toggle("Share the clipboard with this Mac", isOn: Binding(
                get: { vm.config.shareClipboard }, set: { vm.setShareClipboard($0) }))
                .disabled(vm.config.classic)
        } header: {
            Text("PowerEmu Tools")
        } footer: {
            /*
             * The guest agent is a Mac OS X application built against Tiger's
             * frameworks, so none of what it provides -- the shared clipboard,
             * clean Shut Down and Restart, Harmony's window list -- reaches a
             * classic guest.  Saying so is better than offering a disc that
             * will not install.
             */
            if vm.config.classic {
                Text("PowerEmu Tools is a Mac OS X application, so it does not run in \(vm.config.osName). The shared clipboard and Harmony need it.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("With PowerEmu Tools installed in Mac OS X, text you copy on either Mac can be pasted on the other, and Shut Down and Restart work without asking.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

/// Folders on this Mac that appear in the guest as network volumes.
struct SharedFoldersSection: View {
    @ObservedObject var vm: VirtualMachine

    var body: some View {
        Section {
            ForEach(vm.config.sharedFolders) { f in
                HStack {
                    Image(systemName: "folder")
                    VStack(alignment: .leading) {
                        Text(f.name)
                        Text(f.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Toggle("Read only", isOn: Binding(get: { f.readOnly },
                                                      set: { vm.setSharedFolderReadOnly(f, $0) }))
                        .toggleStyle(.checkbox).controlSize(.small)
                    Button { vm.removeSharedFolder(f) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Stop sharing (the folder is not touched)")
                }
            }
            if vm.config.sharedFolders.isEmpty {
                Text("No shared folders").foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("Shared Folders")
                Spacer()
                Button("Add Folder…") { chooseFolder() }.controlSize(.small)
            }
        } footer: {
            Text("PowerEmu Tools open shared folders in Mac OS X as network volumes on the desktop. Without the tools: Go → Connect to Server, http://10.0.2.100/ and the folder’s name. Mac OS X can take up to half a minute to notice files added on this Mac. Read-only changes apply the next time it opens the folder.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func chooseFolder() {
        let p = NSOpenPanel()
        p.canChooseDirectories = true
        p.canChooseFiles = false
        p.allowsMultipleSelection = true
        p.prompt = "Share"
        p.message = "Choose folders to share with the virtual Mac."
        guard p.runModal() == .OK else { return }
        for u in p.urls { vm.addSharedFolder(u) }
    }
}

struct DisksSection: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var vm: VirtualMachine
    @Binding var error: String?
    @State private var showingNewDisk = false
    @State private var newName = "Data"
    @State private var newSize = 20
    @State private var removing: DiskConfig?
    @State private var growing: DiskConfig?
    @State private var growTo = 0
    @State private var growStep: String?

    var body: some View {
        disks.sheet(isPresented: $showingNewDisk) { newDiskSheet }
            .sheet(item: $growing) { d in growSheet(d) }
            .confirmationDialog("Remove “\(removing?.displayName ?? "")” from this virtual Mac?",
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
                Button("Move to Trash", role: .destructive) { if let d = removing { remove(d, trash: true) } }
                Button("Keep the File") { if let d = removing { remove(d, trash: false) } }
            } message: {
                Text("Move the disk file to the Trash, or keep it in the virtual Mac’s package to add again later.")
            }
    }

    private var disks: some View {
        Section {
            ForEach(vm.config.hardDisks) { d in
                HStack {
                    if let hd = DiscIcons.hardDiskImage(vm.config.osName.contains("10.5") ? "10.5" : "10.4") {
                        Image(nsImage: hd).resizable().frame(width: 24, height: 24)
                    } else {
                        Image(systemName: "internaldrive")
                    }
                    VStack(alignment: .leading) {
                        Text(d.displayName)
                        Text(sizeLine(d)).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.state == .stopped {
                        Button("Change Size…") { startGrow(d) }.controlSize(.small)
                    }
                    if vm.config.startupDiskConfig?.id == d.id {
                        Text("Startup Disk").font(.caption.bold()).foregroundStyle(.green)
                    } else if vm.state == .stopped {
                        Button("Start Up From This") { vm.config.startupDisk = d.id; try? vm.save() }
                            .controlSize(.small)
                    }
                    if vm.state == .stopped && vm.config.startupDiskConfig?.id != d.id {
                        Button { removing = d } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Remove this disk")
                    }
                }
            }
        } header: {
            HStack {
                Text("Disks")
                Spacer()
                Button("New Disk…") { showingNewDisk = true }.controlSize(.small).disabled(vm.state != .stopped)
                Button("Add Disk Image…") { add() }.controlSize(.small).disabled(vm.state != .stopped)
            }
        }
    }

    private func add() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.message = "Choose a hard disk image (qcow2, img, dmg). Discs go in the CD/DVD drive."
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try library.addDisk(u, to: vm) } catch { self.error = error.localizedDescription }
    }

    private var newDiskSheet: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Disk").font(.title2.bold())
            Form {
                TextField("Name", text: $newName)
                Picker("Size", selection: $newSize) {
                    ForEach([2, 5, 10, 20, 40, 80, 120], id: \.self) { Text("\($0) GB").tag($0) }
                }
            }.formStyle(.grouped)
            Text("The disk takes space on this Mac only as it fills. Initialize it in Mac OS X with Disk Utility (Mac OS Extended).")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Cancel") { showingNewDisk = false }.keyboardShortcut(.cancelAction)
                Button("Create") {
                    do { try library.createBlankDisk(named: newName, gigabytes: newSize, in: vm) }
                    catch { self.error = error.localizedDescription }
                    showingNewDisk = false
                }.keyboardShortcut(.defaultAction).disabled(newName.isEmpty)
            }
        }
        .padding(20).frame(width: 420)
    }

    /// The file's name, and the size Mac OS X sees.
    private func sizeLine(_ d: DiskConfig) -> String {
        guard let size = diskSize(d) else { return d.file }
        return "\(d.file) · \(size >> 30) GB"
    }

    private func diskSize(_ d: DiskConfig) -> Int64? {
        try? DiskGrow.virtualSize(of: vm.disksURL.appendingPathComponent(d.file))
    }

    private func startGrow(_ d: DiskConfig) {
        growTo = Int((diskSize(d).map { $0 >> 30 } ?? 10) + 10)
        growStep = nil
        growing = d
    }

    /// Give a disk more room.  Mac OS X sees the new size at its next start;
    /// the volume is grown here, on this Mac, because 10.4's Disk Utility
    /// can't.  The old disk goes to the Trash once the new one checks out.
    private func growSheet(_ d: DiskConfig) -> some View {
        let current = Int((diskSize(d).map { $0 >> 30 } ?? 0))
        let choices = [10, 20, 40, 60, 80, 120, 200].filter { $0 > current }
        return VStack(alignment: .leading, spacing: 14) {
            Text("Change the Size of “\(d.displayName)”").font(.title2.bold())
            if let growStep {
                HStack(spacing: 10) { ProgressView().controlSize(.small); Text(growStep) }
                Text("This takes a few minutes for a large disk. Don’t quit PowerEmu.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Form {
                    LabeledContent("Now", value: "\(current) GB")
                    Picker("New size", selection: $growTo) {
                        ForEach(choices, id: \.self) { Text("\($0) GB").tag($0) }
                    }
                }
                .formStyle(.grouped)
                Text("A disk can only be made larger. The disk takes space on this Mac as it fills, and Mac OS X sees the new size the next time this virtual Mac starts. The old disk goes to the Trash.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { growing = nil }.keyboardShortcut(.cancelAction).disabled(growStep != nil)
                Button("Change Size") { runGrow(d) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(growStep != nil || choices.isEmpty)
            }
        }
        .padding(20).frame(width: 460)
        .interactiveDismissDisabled(growStep != nil)
    }

    private func runGrow(_ d: DiskConfig) {
        guard let tool = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else { return }
        let file = vm.disksURL.appendingPathComponent(d.file)
        let bytes = Int64(growTo) << 30
        growStep = "Starting…"
        Task.detached {
            do {
                try DiskGrow.grow(file, to: bytes, qemuImg: tool) { s in
                    Task { @MainActor in growStep = s }
                }
                await MainActor.run { growing = nil; growStep = nil }
            } catch {
                await MainActor.run {
                    growing = nil
                    growStep = nil
                    self.error = error.localizedDescription
                }
            }
        }
    }

    private func remove(_ d: DiskConfig, trash: Bool) {
        vm.config.disks.removeAll { $0.id == d.id }
        try? vm.save()
        if trash {
            let url = vm.disksURL.appendingPathComponent(d.file)
            do { try FileManager.default.trashItem(at: url, resultingItemURL: nil) }
            catch { self.error = error.localizedDescription }
        }
    }
}

// MARK: - Import

struct ImportSheet: View {
    @EnvironmentObject var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    var onDone: (VirtualMachine) -> Void

    @State private var name = "Tiger"
    @State private var osName = "Mac OS X 10.4 Tiger"
    @State private var disk: URL?
    @State private var extra: [URL] = []
    @State private var roms: URL?
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Add a Virtual Mac").font(.title2.bold())
            Text("PowerEmu makes its own copy of the disks (an instant APFS clone), so the originals are never changed.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let legacy = VMLibrary.legacySetup {
                Button("Use the setup in “QEMU Project”") {
                    disk = legacy.disk; extra = legacy.extra; roms = legacy.roms
                }
            }
            Form {
                TextField("Name", text: $name)
                TextField("System", text: $osName)
                LabeledContent("Startup disk") {
                    HStack {
                        Text(disk?.lastPathComponent ?? "None").foregroundStyle(disk == nil ? .secondary : .primary)
                        Button("Choose…") { disk = pick(dirs: false) }
                    }
                }
                LabeledContent("Other disks") {
                    HStack {
                        Text(extra.isEmpty ? "None" : extra.map(\.lastPathComponent).joined(separator: ", "))
                            .foregroundStyle(extra.isEmpty ? .secondary : .primary)
                        Button("Add…") { if let u = pick(dirs: false) { extra.append(u) } }
                    }
                }
                LabeledContent("ATI ROM folder") {
                    HStack {
                        Text(roms?.lastPathComponent ?? "None").foregroundStyle(roms == nil ? .secondary : .primary)
                        Button("Choose…") { roms = pick(dirs: true) }
                    }
                }
            }
            .formStyle(.grouped)
            Text("The emulated Radeon needs the ATI option ROM and BIOS images from a real Radeon 9000/9200 (for example ati_ndrv_joy.rom and ati_ret_9200_201_pciagp_full.rom). They are firmware and are not included with PowerEmu.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Add") { add() }.keyboardShortcut(.defaultAction)
                    .disabled(disk == nil || name.isEmpty || working)
            }
        }
        .padding(20)
        .frame(width: 520)
    }

    private func pick(dirs: Bool) -> URL? {
        let p = NSOpenPanel()
        p.canChooseDirectories = dirs
        p.canChooseFiles = !dirs
        return p.runModal() == .OK ? p.url : nil
    }

    private func add() {
        guard let disk else { return }
        working = true
        do {
            let vm = try library.importMachine(name: name, osName: osName, startupDisk: disk, extraDisks: extra, romFolder: roms)
            onDone(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
        working = false
    }
}


// MARK: - CD/DVD drive

struct DriveSection: View {
    @ObservedObject var vm: VirtualMachine
    @ObservedObject var host = HostDriveMonitor.shared

    private var running: Bool { vm.state == .running || vm.state == .paused }

    var body: some View {
        Section {
            HStack {
                Image(systemName: "opticaldiscdrive")
                if let h = vm.hostDiscName {
                    Text(h)
                    Text("(this Mac’s drive)").foregroundStyle(.secondary)
                } else if let d = vm.config.insertedDisc {
                    Text((d as NSString).lastPathComponent)
                } else {
                    Text("No disc").foregroundStyle(.secondary)
                }
                Spacer()
                if vm.ejecting {
                    ProgressView().controlSize(.small)
                    Text("Asking Mac OS X…").font(.caption).foregroundStyle(.secondary)
                } else if vm.config.insertedDisc != nil || vm.hostDiscName != nil {
                    if vm.ejectRefused {
                        Button("Force Eject") { vm.ejectDisc(force: true) }
                            .help("Take the disc out even though Mac OS X is using it")
                    }
                    Button("Eject") { vm.ejectDisc() }
                }
                Button("Insert Disc…") { pickDisc() }
            }
            ForEach(vm.config.discs.filter { $0 != vm.config.insertedDisc }, id: \.self) { path in
                HStack {
                    Image(systemName: "opticaldisc").foregroundStyle(.secondary)
                    VStack(alignment: .leading) {
                        Text((path as NSString).lastPathComponent)
                        Text((path as NSString).deletingLastPathComponent).font(.caption).foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.middle)
                    }
                    Spacer()
                    Button("Insert") { vm.insertDisc(URL(fileURLWithPath: path)) }.controlSize(.small)
                        .disabled(!FileManager.default.fileExists(atPath: path))
                    Button { vm.forgetDisc(path) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.borderless).help("Remove from this list (the file is not touched)")
                }
            }
            ForEach(host.drives) { d in
                HStack {
                    Image(systemName: d.kind == .floppy ? "externaldrive" : "opticaldiscdrive.fill")
                    Text(d.name)
                    Text(d.kind == .floppy ? "floppy" : "this Mac").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Use") { vm.insertHostDrive(d) }.controlSize(.small).disabled(!running)
                        .help(running ? "Lend this drive to the virtual Mac (read-only)" : "Start the virtual Mac first")
                }
            }
        } header: {
            Text("CD/DVD Drive")
        } footer: {
            Text("Disc images (iso, cdr, toast, dmg) are used where they are, read-only. Discs can be changed while the virtual Mac runs. Using one of this Mac’s drives asks for an administrator’s password.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func pickDisc() {
        let p = NSOpenPanel()
        p.message = "Choose a disc image (iso, cdr, toast, dmg)"
        p.allowedContentTypes = VMConfig.discExtensions.compactMap { UTType(filenameExtension: $0) }
        guard p.runModal() == .OK, let u = p.url else { return }
        vm.insertDisc(u)
    }
}
