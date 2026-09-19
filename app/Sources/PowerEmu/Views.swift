import SwiftUI
import AppKit
import UniformTypeIdentifiers

// MARK: - Library window

struct ContentView: View {
    @EnvironmentObject var library: VMLibrary
    @State private var selection: URL?
    @State private var showingImport = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(library.machines) { vm in
                    MachineRow(vm: vm).tag(vm.url)
                }
            }
            .navigationSplitViewColumnWidth(min: 200, ideal: 230)
            .toolbar {
                ToolbarItem {
                    Button { showingImport = true } label: { Label("Add Virtual Mac", systemImage: "plus") }
                        .help("Add a virtual Mac from an existing disk")
                }
            }
            .overlay {
                if library.machines.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: "desktopcomputer").font(.system(size: 40)).foregroundStyle(.secondary)
                        Text("No Virtual Macs").font(.headline)
                        Button("Add Virtual Mac…") { showingImport = true }
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
        .sheet(isPresented: $showingImport) {
            ImportSheet { vm in selection = vm.url }
        }
        .onAppear { if selection == nil { selection = library.machines.first?.url } }
    }
}

struct MachineRow: View {
    @ObservedObject var vm: VirtualMachine
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "desktopcomputer")
                .font(.title2)
                .foregroundStyle(vm.state == .stopped ? Color.secondary : Color.green)
            VStack(alignment: .leading) {
                Text(vm.config.name).font(.headline)
                Text(vm.state == .stopped ? vm.config.osName : "Running")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 3)
    }
}

// MARK: - One virtual Mac

struct MachineDetail: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var vm: VirtualMachine
    @State private var confirmForce = false
    @State private var confirmTrash = false
    @State private var error: String?

    private var locked: Bool { vm.state != .stopped }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .center, spacing: 16) {
                    Image(systemName: "desktopcomputer").font(.system(size: 44))
                        .foregroundStyle(locked ? Color.green : Color.accentColor)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(vm.config.name).font(.title2.bold())
                        Text("\(vm.config.osName) · \(vm.config.memoryMB >= 1024 ? "\(vm.config.memoryMB / 1024) GB" : "\(vm.config.memoryMB) MB") · PowerPC G4")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.state == .stopped {
                        Button { vm.start() } label: { Label("Start", systemImage: "play.fill").frame(minWidth: 80) }
                            .buttonStyle(.borderedProminent).controlSize(.large)
                    } else {
                        Label(vm.state == .starting ? "Starting…" : "Running", systemImage: "circle.fill")
                            .foregroundStyle(.green).font(.headline)
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

            Group {
            Section("General") {
                TextField("Name", text: binding(\.name))
                TextField("System", text: binding(\.osName))
                Picker("Memory", selection: binding(\.memoryMB)) {
                    ForEach([512, 768, 1024, 1536, 2048], id: \.self) {
                        Text($0 >= 1024 ? "\(Double($0) / 1024, specifier: "%g") GB" : "\($0) MB").tag($0)
                    }
                }
            }

            DisksSection(vm: vm, error: $error)

            Section {
                Toggle("Start in fullscreen", isOn: binding(\.startFullscreen))
                Toggle("Offer resolutions shaped like this Mac’s screen", isOn: binding(\.extraDisplayModes))
                Toggle("Hardware cursor", isOn: binding(\.hardwareCursor))
            } header: {
                Text("Display")
            } footer: {
                Text("Pick the resolution inside Mac OS X, in System Preferences → Displays. 1440 × 932 fills this Mac’s screen; 1440 × 904 and 16:10 modes sit below the notch in fullscreen. Fullscreen: Control-Option-F; Control-Option-G releases the mouse.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Startup") {
                Toggle("Play startup chime", isOn: binding(\.bootChime))
                Toggle("Verbose startup (show messages instead of the Apple logo)", isOn: binding(\.verboseBoot))
                Toggle("Safe Boot (skip third-party extensions)", isOn: binding(\.safeBoot))
                Toggle("Single-user mode", isOn: binding(\.singleUser))
            }

            Section("Sound & Network") {
                Picker("Sound", selection: binding(\.audio)) {
                    Text("On").tag("coreaudio")
                    Text("Off").tag("none")
                }
                Toggle("Network", isOn: binding(\.network))
                Toggle("Reach the guest’s Remote Login (ssh) at localhost:2222", isOn: Binding(
                    get: { vm.config.sshPort != nil },
                    set: { vm.config.sshPort = $0 ? 2222 : nil; try? vm.save() }))
                    .disabled(!vm.config.network)
            }

            }
            .disabled(locked)

            Section("Developer") {
                Group {
                Toggle("QEMU monitor at localhost:4444", isOn: Binding(
                    get: { vm.config.monitorPort != nil },
                    set: { vm.config.monitorPort = $0 ? 4444 : nil; try? vm.save() }))
                Toggle("AGP bridge (Quartz Extreme)", isOn: binding(\.agpBridge))
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
        }
        .formStyle(.grouped)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) { controls }
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

    @ViewBuilder private var controls: some View {
        switch vm.state {
        case .stopped:
            Button { vm.start() } label: { Label("Start", systemImage: "play.fill").frame(minWidth: 80) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        case .starting:
            ProgressView().controlSize(.small)
        case .running, .stopping:
            HStack {
                Button { vm.requestShutDown() } label: { Label("Shut Down…", systemImage: "power") }
                    .help("Press the virtual Mac’s power key; Mac OS X asks whether to shut down.")
                Button("Force Power Off") { confirmForce = true }
            }
        }
    }

    /// A binding into the config that saves on every change; read-only while
    /// the machine runs.
    private func binding<T>(_ kp: WritableKeyPath<VMConfig, T>) -> Binding<T> {
        Binding(get: { vm.config[keyPath: kp] },
                set: { v in
                    guard !locked else { return }
                    vm.config[keyPath: kp] = v
                    do { try vm.save() } catch { self.error = error.localizedDescription }
                })
    }
}

struct DisksSection: View {
    @EnvironmentObject var library: VMLibrary
    @ObservedObject var vm: VirtualMachine
    @Binding var error: String?

    var body: some View {
        Section {
            ForEach(vm.config.disks) { d in
                HStack {
                    Image(systemName: d.kind == .cdrom ? "opticaldisc" : "internaldrive")
                    VStack(alignment: .leading) {
                        Text(d.displayName)
                        Text(d.file).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if vm.config.startupDiskConfig?.id == d.id {
                        Text("Startup Disk").font(.caption.bold()).foregroundStyle(.green)
                    } else if d.kind == .hardDisk && vm.state == .stopped {
                        Button("Start Up From This") { vm.config.startupDisk = d.id; try? vm.save() }
                            .controlSize(.small)
                    }
                    if vm.state == .stopped && vm.config.startupDiskConfig?.id != d.id {
                        Button { remove(d) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).help("Detach (the file stays in the package)")
                    }
                }
            }
        } header: {
            HStack {
                Text("Disks")
                Spacer()
                Button("Add Disk Image…") { add() }.controlSize(.small).disabled(vm.state != .stopped)
            }
        }
    }

    private func add() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = false
        p.message = "Choose a disk image (qcow2, img, dmg, iso, toast, cdr)"
        guard p.runModal() == .OK, let u = p.url else { return }
        do { try library.addDisk(u, to: vm) } catch { self.error = error.localizedDescription }
    }

    private func remove(_ d: DiskConfig) {
        vm.config.disks.removeAll { $0.id == d.id }
        try? vm.save()
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
