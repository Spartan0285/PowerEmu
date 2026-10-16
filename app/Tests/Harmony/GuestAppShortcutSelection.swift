import Foundation

@main struct GuestAppShortcutSelectionTest {
    static func main() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("PE-guest-shortcut-store-" + UUID().uuidString, isDirectory: true)
        let vm = root.appendingPathComponent("Test.poweremu", isDirectory: true)
        let otherVM = root.appendingPathComponent("Other.poweremu", isDirectory: true)
        try FileManager.default.createDirectory(at: vm, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherVM, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var selection = GuestAppShortcutSelection(vmPackageURL: vm)
        selection.setSelected(true, applicationPath: "/Applications/Chess.app")
        selection.setSelected(true, applicationPath: "/Applications/Chess.app")
        selection.setSelected(true, applicationPath: "/Applications/../tmp/Unsafe.app")
        try GuestAppShortcutStore.save(selection, to: vm)

        let restored = GuestAppShortcutStore.load(from: vm)
        precondition(restored.applicationPaths == ["/Applications/Chess.app"])
        precondition(GuestAppShortcutStore.load(from: otherVM).applicationPaths.isEmpty)
        let attributes = try FileManager.default.attributesOfItem(atPath: GuestAppShortcutStore.fileURL(in: vm).path)
        precondition((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)

        var deselected = restored
        deselected.setSelected(false, applicationPath: "/Applications/Chess.app")
        try GuestAppShortcutStore.save(deselected, to: vm)
        precondition(GuestAppShortcutStore.load(from: vm).applicationPaths.isEmpty)
        print("PASS: per-package selections persist, deduplicate, reject invalid paths, and stay isolated")
    }
}
