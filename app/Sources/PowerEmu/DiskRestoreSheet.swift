import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// A whole-disk image can be copied into a new virtual Mac here. Restore-only
/// volume images such as Sorbet Leopard's DMG require an APM volume restore.
@MainActor
struct DiskRestoreSheet: View {
    @EnvironmentObject private var library: VMLibrary
    @Environment(\.dismiss) private var dismiss
    let onDone: (VirtualMachine) -> Void

    @State private var image: URL?
    @State private var name = "Restored Mac"
    @State private var osName = "Mac OS X"
    @State private var busy = false
    @State private var problem: String?
    @State private var operation: DiskRestoreOperation?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Restore a Disk Image").font(.title2.bold())
            Text("Choose an installed system image that represents a complete disk. PowerEmu checks it and makes a separate QCOW2 copy for a new virtual Mac. Installer discs belong in the install flow.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Form {
                TextField("Virtual Mac name", text: $name)
                TextField("System", text: $osName)
                LabeledContent("Disk image") {
                    HStack {
                        Text(image?.lastPathComponent ?? "Choose a disk image")
                            .foregroundStyle(image == nil ? .secondary : .primary).lineLimit(1)
                        Button("Choose…", action: chooseImage).disabled(busy)
                    }
                }
            }
            .formStyle(.grouped)
            Text("Supported: self-contained raw IMG and unencrypted QCOW2. VMDK, VDI, VHDX, and restore-only DMG images need a different import path. The original image is read only.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if busy { HStack { ProgressView(); Text("Checking and copying the disk…").foregroundStyle(.secondary) } }
            if let problem { Text(problem).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Spacer()
                Button("Cancel") { if let operation { operation.cancel() } else { dismiss() } }
                    .keyboardShortcut(.cancelAction)
                Button("Create Virtual Mac", action: restore)
                    .keyboardShortcut(.defaultAction)
                    .disabled(busy || image == nil || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20).frame(width: 540)
        .interactiveDismissDisabled(busy)
    }

    private func chooseImage() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.data]
        panel.allowsOtherFileTypes = true
        if panel.runModal() == .OK { image = panel.url; problem = nil }
    }

    private func restore() {
        guard let image else { return }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanOS = osName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/"), !cleanName.contains("\0"), cleanName != ".", cleanName != ".." else {
            problem = "Choose a virtual Mac name that does not contain a slash."
            return
        }
        guard let qemuImg = VMRunner.helperURL?.appendingPathComponent("Contents/MacOS/qemu-img") else {
            problem = "The emulator disk tool could not be found."
            return
        }
        problem = nil
        busy = true
        let operation = DiskRestoreOperation()
        self.operation = operation
        let destinationRoot = library.folder
        Task.detached {
            do {
                let vm = try await DiskRestoreService.restore(image: image, name: cleanName,
                                                             osName: cleanOS.isEmpty ? "Mac OS X" : cleanOS,
                                                             in: destinationRoot, qemuImg: qemuImg,
                                                             operation: operation)
                await MainActor.run {
                    library.reload()
                    onDone(library.machines.first { $0.url == vm.url } ?? vm)
                    dismiss()
                }
            } catch {
                await MainActor.run { problem = error.localizedDescription }
            }
            await MainActor.run { busy = false; self.operation = nil }
        }
    }
}
