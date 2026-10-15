import AppKit
import CryptoKit

// Branding belongs to the running process, not to a rewritten code bundle.
// LaunchServices has no public display-name setter. Resolve this optional
// naming SPI at runtime; a missing symbol leaves the executable's name intact.
private func setDockName(_ name: String) {
    ProcessInfo.processInfo.processName = name
    guard let services = CFBundleGetBundleWithIdentifier("com.apple.LaunchServices" as CFString),
          let getPointer = CFBundleGetFunctionPointerForName(services, "_LSGetCurrentApplicationASN" as CFString),
          let setPointer = CFBundleGetFunctionPointerForName(services, "_LSSetApplicationInformationItem" as CFString),
          let keyPointer = CFBundleGetDataPointerForName(services, "_kLSDisplayNameKey" as CFString) else { return }
    typealias GetASN = @convention(c) () -> Unmanaged<CFTypeRef>?
    typealias SetName = @convention(c) (Int32, CFTypeRef, CFString, CFString, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?) -> Int32
    // Called after AppKit registers this application with the process manager.
    guard let asn = unsafeBitCast(getPointer, to: GetASN.self)()?.takeUnretainedValue() else { return }
    let key = keyPointer.assumingMemoryBound(to: CFString.self).pointee
    _ = unsafeBitCast(setPointer, to: SetName.self)(-2, asn, key, name as CFString, nil)
}

/*
 * One guest application's place in this Mac's Dock.
 *
 * This Mac gives a Dock tile to a running process, so a guest application
 * needs something of its own running here to have one.  That is all this is:
 * it shows no window, draws nothing, and does no work.  It sits in the Dock
 * under the guest application's name and icon, and when somebody clicks it or
 * quits it, it says so and lets PowerEmu do the rest.
 *
 * PowerEmu copies this signed executable unchanged. Environment data supplies
 * the name, icon, guest process and session; no code bundle is rewritten.
 */
final class Delegate: NSObject, NSApplicationDelegate {
    private var pid = ""
    private var session = ""
    private var persistentURL: URL?
    private var persistentMode = false
    private var ignoreNextActivation = false
    private var lastPersistentOpen = Date.distantPast

    func applicationDidFinishLaunching(_ note: Notification) {
        let environment = ProcessInfo.processInfo.environment
        pid = environment["PE_DOCK_GUEST_PID"] ?? Bundle.main.object(forInfoDictionaryKey: "PEGuestPID") as? String ?? ""
        session = environment["PE_DOCK_SESSION"] ?? Bundle.main.object(forInfoDictionaryKey: "PESession") as? String ?? ""
        // Nothing to show: the tile is the whole of it.
        NSApp.setActivationPolicy(.regular)
        if let name = environment["PE_DOCK_NAME"] { setDockName(name) }
        if let path = environment["PE_DOCK_ICON"], let icon = NSImage(contentsOfFile: path) {
            NSApp.applicationIconImage = icon
        }
        if pid.isEmpty != session.isEmpty { NSApp.terminate(nil); return }
        if pid.isEmpty {
            guard let config = persistentLauncher() else { NSApp.terminate(nil); return }
            persistentMode = true
            persistentURL = config.url
            setDockName(config.name)
            if let iconPath = config.iconPath, let icon = NSImage(contentsOfFile: iconPath) {
                NSApp.applicationIconImage = icon
            }
            // The first launch only makes the new tile available for the
            // user's Dock menu. Opening the launcher is reserved for clicks.
            ignoreNextActivation = environment["PE_DOCK_INSTALL_ONLY"] == "1"
            // A cold executable launch need not deliver a later activation
            // callback. Dispatch once after validation; activation/reopen
            // callbacks are debounced by openPersistentLauncher().
            if !ignoreNextActivation { openPersistentLauncher() }
            return
        }
        watchForOrphanhood()
    }

    /*
     * Go when PowerEmu goes.
     *
     * This stands in the Dock for an application inside a virtual Mac, so it
     * has nothing to say once the thing it represents is unreachable.  Nobody
     * tears it down on the way out, though: PowerEmu starts it as a child, and
     * this Mac does not end an application's children when the application
     * ends.  Quitting PowerEmu -- or its crashing, or being force quit -- left
     * a Dock full of icons for a virtual Mac that was no longer running, and
     * the next run added its own on top.
     *
     * Being orphaned is the one signal that covers all of those, so watch for
     * it.  Termination has to be immediate rather than polite: the ordinary
     * quit path below refuses, because normally only the guest may decide.
     */
    private func watchForOrphanhood() {
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { _ in
            if getppid() == 1 { exit(0) }
        }
    }

    /// Clicking the tile, whether or not this happens to be the active
    /// application already.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if persistentMode { openPersistentLauncher(); return true }
        tell("clicked")
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        if persistentMode {
            if ignoreNextActivation { ignoreNextActivation = false }
            else { openPersistentLauncher() }
            NSApp.hide(nil)
            return
        }
        tell("clicked")
        // Never keep the focus: the guest's window is what should have it, and
        // it lives in PowerEmu.
        NSApp.hide(nil)
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        if persistentMode { return .terminateNow }
        tell("quit")
        // The guest may present a Save dialog or decline to quit. Keep its
        // tile until PowerEmu observes the guest process actually disappear.
        return .terminateCancel
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !persistentMode else { sender.reply(toOpenOrPrint: .failure); return }
        guard !pid.isEmpty, !session.isEmpty else {
            sender.reply(toOpenOrPrint: .failure); return
        }
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.spartan0285.poweremu.guestapp.open"), object: nil,
            userInfo: ["pid": pid, "session": session, "paths": filenames], deliverImmediately: true)
        sender.reply(toOpenOrPrint: .success)
        NSApp.hide(nil)
    }

    private func tell(_ what: String) {
        guard !pid.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.spartan0285.poweremu.guestapp.\(what)"),
            object: nil, userInfo: ["pid": pid, "session": session], deliverImmediately: true)
    }

    private struct PersistentConfig {
        let url: URL
        let name: String
        let iconPath: String?
    }

    /// Persistent launchers use mutable data beside an unchanged signed
    /// executable. Validate it before handing a URL to LaunchServices.
    private func persistentLauncher() -> PersistentConfig? {
        guard let executable = Bundle.main.executableURL else { return nil }
        guard (Bundle.main.object(forInfoDictionaryKey: "PEGuestLauncherVersion") as? NSNumber)?.intValue == 1 else {
            return nil
        }
        let directory = executable.deletingLastPathComponent()
        let expectedRoot = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true)
            .standardizedFileURL
        let resolvedDirectory = directory.resolvingSymlinksInPath().standardizedFileURL
        let directoryName = directory.lastPathComponent
        guard resolvedDirectory.deletingLastPathComponent() == expectedRoot,
              directoryName.count == 32,
              directoryName.allSatisfy({ $0.isHexDigit }),
              safeOwnedPath(directory, directory: true) else { return nil }
        let configURL = directory.appendingPathComponent("launcher.plist")
        guard safeOwnedPath(configURL, directory: false),
              let attributes = try? FileManager.default.attributesOfItem(atPath: configURL.path),
              (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 64 * 1024,
              let data = try? Data(contentsOf: configURL),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let vmPath = values["VMPackagePath"] as? String,
              let appPath = values["GuestApplicationPath"] as? String,
              let name = values["DisplayName"] as? String,
              (values["LauncherVersion"] as? NSNumber)?.intValue == 1,
              !name.isEmpty, name.utf8.count <= 256, !containsControlCharacters(name),
              vmPath.hasPrefix("/"), vmPath.hasSuffix(".poweremu"), vmPath.utf8.count <= 4096, !containsControlCharacters(vmPath),
              appPath.hasPrefix("/"), appPath != "/", appPath.utf8.count <= 4096, !containsControlCharacters(appPath),
              !appPath.split(separator: "/").contains("..") else { return nil }
        let canonicalVMPath = URL(fileURLWithPath: vmPath).standardizedFileURL.resolvingSymlinksInPath().path
        let launcherID = SHA256.hash(data: Data((canonicalVMPath + "\0" + appPath).utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        guard canonicalVMPath == vmPath, launcherID == directoryName else { return nil }
        var parts = URLComponents()
        parts.scheme = "poweremu"
        parts.host = "guest-app"
        parts.queryItems = [URLQueryItem(name: "vm", value: vmPath), URLQueryItem(name: "app", value: appPath)]
        guard let url = parts.url else { return nil }
        let iconURL = directory.appendingPathComponent("icon.png")
        let iconAttributes = try? FileManager.default.attributesOfItem(atPath: iconURL.path)
        let iconSize = (iconAttributes?[.size] as? NSNumber)?.intValue ?? Int.max
        let iconPath = safeOwnedPath(iconURL, directory: false) && iconSize <= 4 * 1024 * 1024
            ? iconURL.path : nil
        return PersistentConfig(url: url, name: name, iconPath: iconPath)
    }

    private func safeOwnedPath(_ url: URL, directory: Bool) -> Bool {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true,
              values.isDirectory == directory,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              let permissions = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              permissions & 0o022 == 0 else { return false }
        return true
    }

    private func openPersistentLauncher() {
        guard let url = persistentURL,
              Date().timeIntervalSince(lastPersistentOpen) > 1 else { return }
        lastPersistentOpen = Date()
        NSWorkspace.shared.open(url)
    }

    private func containsControlCharacters(_ string: String) -> Bool {
        string.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
