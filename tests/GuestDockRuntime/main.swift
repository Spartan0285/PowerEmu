import AppKit
func harmonyDebug(_ text: String) { print(text) }

@MainActor func runChecks() throws {
    precondition(CommandLine.arguments.count == 2)
    let helper = URL(fileURLWithPath: CommandLine.arguments[1])
    let bytes = try Data(contentsOf: helper)
    let fm = FileManager.default
    let temp = fm.temporaryDirectory.appendingPathComponent("UnifiedDock-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: temp, withIntermediateDirectories: true)
    let vm1 = temp.appendingPathComponent("One.poweremu", isDirectory: true)
    let vm2 = temp.appendingPathComponent("Two.poweremu", isDirectory: true)
    for vm in [vm1, vm2] { try fm.createDirectory(at: vm, withIntermediateDirectories: true) }
    let path = "/Applications/Unified Dock Test.app"
    let root = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
    let requests = try [vm1, vm2].map { try GuestAppLaunchRequest(vmPackageURL: $0, guestApplicationPath: path) }
    let dirs = requests.map { root.appendingPathComponent($0.stableIdentifier, isDirectory: true) }
    precondition(dirs.allSatisfy { !fm.fileExists(atPath: $0.path) })
    let one = GuestDock(helperBinary: helper)
    let two = GuestDock(helperBinary: helper)
    defer {
        one.stop(); two.stop()
        RunLoop.current.run(until: Date().addingTimeInterval(1))
        for dir in dirs {
            for app in NSWorkspace.shared.runningApplications where app.executableURL?.path.hasPrefix(dir.path + "/") == true { app.forceTerminate() }
            try? fm.removeItem(at: dir)
        }
        try? fm.removeItem(at: temp)
    }
    func wait(_ seconds: Double = 0.8) { RunLoop.current.run(until: Date().addingTimeInterval(seconds)) }
    func helpers(_ index: Int) -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter { !$0.isTerminated && $0.executableURL?.path.hasPrefix(dirs[index].path + "/") == true }
    }
    func runtime(_ index: Int) throws -> [String: Any] {
        try PropertyListSerialization.propertyList(from: Data(contentsOf: dirs[index].appendingPathComponent("runtime.plist")), options: [], format: nil) as! [String: Any]
    }
    func action(_ index: Int, _ name: String, session: String? = nil, vm: String? = nil) throws {
        let value = try runtime(index)
        DistributedNotificationCenter.default().postNotificationName(.init("com.spartan0285.poweremu.guestapp.action"),
            object: requests[index].stableIdentifier, userInfo: ["action": name, "owner": String(getpid()),
                "session": session ?? value["Session"] as! String, "vm": vm ?? requests[index].vmPackagePath, "app": path], deliverImmediately: true)
    }
    var launches = [String](), activated = [Int](), quits = [Int]()
    one.launchApplication = { launches.append($0) }; one.activate = { activated.append($0) }; one.quit = { quits.append($0) }
    one.configure(vmPackageURL: vm1); two.configure(vmPackageURL: vm2)
    one.start(); two.start()
    let application = try one.prepareApplication(path: path, name: "Unified Dock Test")
    let executable = Bundle(url: application)!.executableURL!
    wait()
    precondition(helpers(0).isEmpty && launches.isEmpty, "Preparing a closed shortcut must not start its helper or guest app")
    one.setRunningGuestApps([(path, "Unified Dock Test", 301)])
    two.setRunningGuestApps([(path, "Unified Dock Test", 401)])
    wait(3)
    precondition(helpers(0).count == 1 && helpers(1).count == 1, "One icon per VM and app")
    let originalPID = helpers(0)[0].processIdentifier
    let initialBytes = try Data(contentsOf: executable)
    precondition(!initialBytes.isEmpty)
    let mode = try fm.attributesOfItem(atPath: dirs[0].appendingPathComponent("runtime.plist").path)[.posixPermissions] as! NSNumber
    precondition(mode.intValue == 0o600)
    one.setRunningGuestApps([(path, "Unified Dock Test", 301), (path, "Unified Dock Test", 302)])
    wait()
    precondition(helpers(0).count == 1 && helpers(0)[0].processIdentifier == originalPID, "Multiple processes/windows do not duplicate the app identity")
    try action(0, "activate", session: UUID().uuidString)
    try action(0, "quit", vm: requests[1].vmPackagePath)
    wait()
    precondition(activated.isEmpty && quits.isEmpty, "Foreign session and VM actions rejected")
    try action(0, "activate"); wait(); precondition(activated == [301])
    let duplicate = Process()
    duplicate.executableURL = executable
    try duplicate.run(); wait()
    precondition(!duplicate.isRunning && duplicate.terminationStatus == 0 && helpers(0).count == 1,
                 "A simultaneous launch coalesces into the existing stable representative")
    precondition(activated == [301, 301], "The duplicate launch activates the existing guest app once")
    _ = helpers(0)[0].terminate(); wait()
    precondition(Set(quits) == [301, 302] && helpers(0).count == 1, "Quit reaches the guest and preserves the representative while Save/Cancel is pending")
    let image = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 8, pixelsHigh: 8, bitsPerSample: 8,
        samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 32, bitsPerPixel: 32)!
    memset(image.bitmapData!, 255, 256)
    let png = image.representation(using: .png, properties: [:])!
    one.setApplicationPathIcon(path: path, png: png); wait()
    precondition(helpers(0)[0].processIdentifier == originalPID, "Artwork must update without helper restart")
    let runningBytes = try Data(contentsOf: executable)
    precondition(runningBytes == initialBytes, "A live artwork update must not rewrite a running signed bundle")
    one.guestToolsDisconnected(); wait()
    let unknown = try runtime(0)
    precondition(unknown["State"] as? String == "unknown" && helpers(0).count == 1)
    one.setRunningGuestApps([]); wait(1.5)
    precondition(helpers(0).isEmpty && helpers(1).count == 1, "Complete empty snapshot clears only its own VM runtime")
    precondition(fm.fileExists(atPath: executable.path), "Pinned launcher target survives guest app exit")
    one.setRunningGuestApps([(path, "Unified Dock Test", 601)]); wait(1.5)
    precondition(helpers(0).count == 1 && helpers(0)[0].executableURL?.path == executable.path)
    let newPID = helpers(0)[0].processIdentifier
    one.stop(); wait(1.5)
    precondition(helpers(0).isEmpty && fm.fileExists(atPath: executable.path))
    one.start(); one.setRunningGuestApps([(path, "Unified Dock Test", 701)]); wait(1.5)
    precondition(helpers(0).count == 1 && helpers(0)[0].processIdentifier != newPID && helpers(0)[0].executableURL?.path == executable.path)
    let finalBytes = try Data(contentsOf: executable)
    let sourceAfter = try Data(contentsOf: helper)
    precondition(sourceAfter == bytes, "Distributed Developer ID template is unchanged")
    precondition(!finalBytes.isEmpty)
    let template = helper.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let sourceHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: Bundle.main.bundleURL)
    let receipt = try GuestLauncherTrust.loadReceipt(from: dirs[0], applicationURL: application,
        stableIdentifier: requests[0].stableIdentifier, sourceCDHash: sourceHash)
    precondition(GuestLauncherTrust.validatesInstalledBundle(applicationURL: application, receipt: receipt))
    precondition(GuestLauncherTrust.validates(process: helpers(0)[0], receipt: receipt))
    print("PASS: one stable VM/app identity, no launch on creation, multi-process grouping, scoped actions, graceful Quit/Cancel, icon updates without restart, disconnect vs empty snapshot, stable restart target and cross-VM isolation")
}
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
app.finishLaunching()
MainActor.assumeIsolated {
    do { try runChecks(); exit(0) }
    catch { fputs("FAIL: \(error)\n", stderr); exit(1) }
}
