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
                }
            }
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
        .sheet(isPresented: $showingImport) {
            ImportSheet { vm in selection = vm.url }
        }
        .sheet(isPresented: $showingNew) {
            NewMachineSheet { vm in selection = vm.url }
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
            }
            .disabled(locked)

            DriveSection(vm: vm)

            ToolsSection(vm: vm)

            SharedFoldersSection(vm: vm)

            Group {

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
                Toggle("Start from the disc in the drive (to install)", isOn: binding(\.bootFromDisc))
                    .disabled(vm.config.insertedDisc == nil)
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
                Toggle("Reach the guest’s Remote Login (ssh) at localhost:\(String(vm.sshPortInUse ?? vm.config.sshPort ?? 2222))", isOn: Binding(
                    get: { vm.config.sshPort != nil },
                    set: { vm.config.sshPort = $0 ? 2222 : nil; try? vm.save() }))
                    .disabled(!vm.config.network)
            }

            }
            .disabled(locked)

            Section("Developer") {
                Group {
                Toggle("QEMU monitor at localhost:\(String(vm.monitorPortInUse ?? vm.config.monitorPort ?? 4444))", isOn: Binding(
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
                if vm.toolsConnected {
                    Button { vm.requestShutDown() } label: { Label("Shut Down", systemImage: "power") }
                        .help("Shut down Mac OS X, as from the Apple menu; programs are asked to quit first.")
                } else {
                    Button { vm.requestShutDown() } label: { Label("Shut Down…", systemImage: "power") }
                        .help("Press the virtual Mac’s power key; Mac OS X asks whether to shut down.")
                }
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

/// PowerEmu Tools: whether the agent is running in the guest, installing
/// it, and what it offers.
struct ToolsSection: View {
    @ObservedObject var vm: VirtualMachine

    var body: some View {
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
                    .help("Put the PowerEmu Tools disc in the drive; open its installer in Mac OS X.")
            }
            Toggle("Share the clipboard with this Mac", isOn: Binding(
                get: { vm.config.shareClipboard }, set: { vm.setShareClipboard($0) }))
        } header: {
            Text("PowerEmu Tools")
        } footer: {
            Text("With PowerEmu Tools installed in Mac OS X, text you copy on either Mac can be pasted on the other, and Shut Down and Restart work without asking.")
                .font(.caption).foregroundStyle(.secondary)
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

    var body: some View {
        disks.sheet(isPresented: $showingNewDisk) { newDiskSheet }
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
                    Image(systemName: "internaldrive")
                    VStack(alignment: .leading) {
                        Text(d.displayName)
                        Text(d.file).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
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

    private var running: Bool { vm.state == .running }

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

// MARK: - New virtual Mac

struct NewMachineSheet: View {
    @EnvironmentObject var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    var onDone: (VirtualMachine) -> Void

    @State private var name = "Leopard"
    @State private var osName = "Mac OS X 10.5 Leopard"
    @State private var memory = 2048
    @State private var diskGB = 40
    @State private var disc: URL?
    @State private var romSource: URL?
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New Virtual Mac").font(.title2.bold())
            Text("Makes a Power Mac G4 with an empty disk and your install disc in the drive. Start it, erase the disk in the installer’s Disk Utility (Mac OS Extended, Journaled), then install.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Name", text: $name)
                Picker("System", selection: $osName) {
                    ForEach(["Mac OS X 10.5 Leopard", "Mac OS X 10.4 Tiger", "Mac OS X 10.3 Panther",
                             "Mac OS X 10.2 Jaguar"], id: \.self) { Text($0).tag($0) }
                }
                Picker("Memory", selection: $memory) {
                    ForEach([512, 1024, 1536, 2048], id: \.self) { Text($0 >= 1024 ? "\($0 / 1024) GB" : "\($0) MB").tag($0) }
                }
                Picker("Disk", selection: $diskGB) {
                    ForEach([10, 20, 40, 80, 120], id: \.self) { Text("\($0) GB").tag($0) }
                }
                LabeledContent("Install disc") {
                    HStack {
                        Text(disc?.lastPathComponent ?? "None").foregroundStyle(disc == nil ? .secondary : .primary)
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.allowedContentTypes = VMConfig.discExtensions.compactMap { UTType(filenameExtension: $0) }
                            if p.runModal() == .OK { disc = p.url }
                        }
                    }
                }
                Picker("ATI ROMs from", selection: $romSource) {
                    Text("None").tag(URL?.none)
                    ForEach(library.machines.filter { $0.config.gpuOptionROM != nil }) { m in
                        Text(m.config.name).tag(Optional(m.url))
                    }
                }
            }
            .formStyle(.grouped)
            if let error { Text(error).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Create") { create() }.keyboardShortcut(.defaultAction).disabled(name.isEmpty)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { romSource = library.machines.first { $0.config.gpuOptionROM != nil }?.url }
        .onChange(of: osName) { _, v in
            if let short = v.split(separator: " ").last { name = String(short) }
        }
    }

    private func create() {
        do {
            let src = library.machines.first { $0.url == romSource }
            let vm = try library.newMachine(name: name, osName: osName, memoryMB: memory, diskGB: diskGB,
                                            installDisc: disc, romsFrom: src)
            onDone(vm)
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
