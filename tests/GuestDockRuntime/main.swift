import AppKit
var diagnostics = [String]()
func harmonyDebug(_ text: String) { diagnostics.append(text); print(text) }

@MainActor func check() throws {
    let helper = URL(fileURLWithPath: CommandLine.arguments[1])
    let source = try Data(contentsOf: helper)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("poweremu-dock-test-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    for pixel in 0..<64 {
        let bytes = image.bitmapData! + pixel * 4
        bytes[0] = 255; bytes[1] = 64; bytes[2] = 0; bytes[3] = 255
    }
    let png = image.representation(using: .png, properties: [:])!
    let first = GuestDock(storageRoot: root, helperBinary: helper)
    let second = GuestDock(storageRoot: root, helperBinary: helper)
    defer { first.stop(); second.stop() }
    first.wantIcon = { first.setIcon(pid: $0, png: png) }
    second.wantIcon = { second.setIcon(pid: $0, png: png) }
    first.start(); first.setApps([(101, "Dock Test One")])
    second.start(); second.setApps([(101, "Dock Test Two")])
    RunLoop.current.run(until: Date().addingTimeInterval(3))
    let children = NSWorkspace.shared.runningApplications.filter { $0.executableURL?.path.hasPrefix(root.path + "/") == true }
    precondition(children.count == 2, "Both sessions must retain a live Dock representative")
    precondition(Set(children.compactMap(\.localizedName)) == ["Dock Test One", "Dock Test Two"])
    for child in children {
        precondition(child.activationPolicy == .regular)
        let copied = try Data(contentsOf: child.executableURL!)
        precondition(copied == source, "Executable signature bytes changed")
        let verify = Process(); verify.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        verify.arguments = ["--verify", "--strict", child.executableURL!.path]
        try verify.run(); verify.waitUntilExit(); precondition(verify.terminationStatus == 0)
        let storedIcon = child.executableURL!.deletingLastPathComponent().appendingPathComponent("icon.png")
        let storedPNG = try Data(contentsOf: storedIcon)
        precondition(storedPNG == png && NSImage(data: storedPNG)?.isValid == true)
    }
    first.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    precondition(NSWorkspace.shared.runningApplications.contains { $0.localizedName == "Dock Test Two" && !$0.isTerminated })
    second.stop()
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
    precondition(!NSWorkspace.shared.runningApplications.contains { $0.executableURL?.path.hasPrefix(root.path + "/") == true })

    // A rejected or crashing helper must not be launched every keeper tick.
    let failing = GuestDock(storageRoot: root, helperBinary: URL(fileURLWithPath: CommandLine.arguments[2]))
    failing.wantIcon = { failing.setIcon(pid: $0, png: png) }
    failing.start(); failing.setApps([(102, "Dock Failure Probe")])
    RunLoop.current.run(until: Date().addingTimeInterval(6.5))
    failing.stop()
    precondition(diagnostics.filter { $0.contains("exited with status 1; automatic relaunch disabled") }.count == 1)
    print("PASS: trusted bytes/signatures, distinct names/icon data, concurrent session ownership, cleanup and failed-launch suppression")
}
MainActor.assumeIsolated { try! check() }
