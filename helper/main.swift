import AppKit
import CryptoKit

/*
 * A durable, per-guest-app Dock representative. Every launcher is an
 * identical copy of the build-time signed app template; only launcher.plist,
 * runtime.plist, and icon.png beside it are mutable user data.
 */
private let stateNotification = Notification.Name("com.spartan0285.poweremu.guestapp.state")
private let actionNotification = Notification.Name("com.spartan0285.poweremu.guestapp.action")
private let attachWait: TimeInterval = 210

private func setDockName(_ name: String) {
    ProcessInfo.processInfo.processName = name
    guard let services = CFBundleGetBundleWithIdentifier("com.apple.LaunchServices" as CFString),
          let getPointer = CFBundleGetFunctionPointerForName(services, "_LSGetCurrentApplicationASN" as CFString),
          let setPointer = CFBundleGetFunctionPointerForName(services, "_LSSetApplicationInformationItem" as CFString),
          let keyPointer = CFBundleGetDataPointerForName(services, "_kLSDisplayNameKey" as CFString) else { return }
    typealias GetASN = @convention(c) () -> Unmanaged<CFTypeRef>?
    typealias SetName = @convention(c) (Int32, CFTypeRef, CFString, CFString, UnsafeMutablePointer<Unmanaged<CFDictionary>?>?) -> Int32
    guard let asn = unsafeBitCast(getPointer, to: GetASN.self)()?.takeUnretainedValue() else { return }
    let key = keyPointer.assumingMemoryBound(to: CFString.self).pointee
    _ = unsafeBitCast(setPointer, to: SetName.self)(-2, asn, key, name as CFString, nil)
}

private func setDockIcon(_ icon: NSImage) {
    NSApp.applicationIconImage = icon
    let view = NSImageView(frame: NSRect(origin: .zero, size: NSApp.dockTile.size))
    view.image = icon
    view.imageScaling = .scaleProportionallyUpOrDown
    NSApp.dockTile.contentView = view
    NSApp.dockTile.display()
}

private func containsControls(_ value: String) -> Bool {
    value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
}

private func isCanonicalGuestPath(_ value: String) -> Bool {
    value.hasPrefix("/") && value != "/" && value.utf8.count <= 4096 &&
        !containsControls(value) && !value.split(separator: "/").contains("..") &&
        (value as NSString).standardizingPath == value
}

private func validDockIcon(_ data: Data) -> Bool {
    guard data.count >= 24, data.count <= 4 * 1024 * 1024,
          data.prefix(8) == Data([137, 80, 78, 71, 13, 10, 26, 10]) else { return false }
    let bytes = Array(data.prefix(24))
    func dimension(_ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 |
            UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
    }
    return (1...512).contains(dimension(16)) && (1...512).contains(dimension(20))
}

private struct LauncherConfig {
    let stableID: String
    let vmPath: String
    let appPath: String
    let displayName: String
    let hostPath: String
    let hostBundleID: String
    let directory: URL

    static func load() -> LauncherConfig? {
        guard (Bundle.main.object(forInfoDictionaryKey: "PEGuestLauncherVersion") as? NSNumber)?.intValue == 3,
              let executable = Bundle.main.executableURL else { return nil }
        let fm = FileManager.default
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Applications/PowerEmu Guest Apps", isDirectory: true).standardizedFileURL
        let bundle = Bundle.main.bundleURL.standardizedFileURL
        let bundledTemplate = bundle.pathExtension == "app" &&
            Bundle.main.object(forInfoDictionaryKey: "CFBundleExecutable") as? String == "PowerEmuGuestApp" &&
            bundle.appendingPathComponent("Contents/MacOS/PowerEmuGuestApp").standardizedFileURL ==
                executable.standardizedFileURL &&
            safeOwnedDirectory(bundle) &&
            safeOwnedDirectory(bundle.appendingPathComponent("Contents")) &&
            safeOwnedDirectory(bundle.appendingPathComponent("Contents/MacOS"))
        let directory = (bundledTemplate ? bundle.deletingLastPathComponent() :
            executable.deletingLastPathComponent()).standardizedFileURL
        guard directory.resolvingSymlinksInPath().standardizedFileURL == directory,
              directory.deletingLastPathComponent() == root,
              safePath(directory, directory: true) else { return nil }
        let configURL = directory.appendingPathComponent("launcher.plist")
        guard safePath(configURL, directory: false),
              let attributes = try? fm.attributesOfItem(atPath: configURL.path),
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 64 * 1024,
              let data = try? Data(contentsOf: configURL),
              let values = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              (values["LauncherVersion"] as? NSNumber)?.intValue == 3,
              let stableID = values["StableIdentifier"] as? String,
              let vmPath = values["VMPackagePath"] as? String,
              let appPath = values["GuestApplicationPath"] as? String,
              let displayName = values["DisplayName"] as? String,
              let hostPath = values["HostApplicationPath"] as? String,
              let hostBundleID = values["HostBundleIdentifier"] as? String,
              stableID.count == 32, stableID.allSatisfy({ $0.isHexDigit }),
              vmPath.hasSuffix(".poweremu"), vmPath.utf8.count <= 4096, !containsControls(vmPath),
              isCanonicalGuestPath(appPath),
              !displayName.isEmpty, displayName.utf8.count <= 256, !containsControls(displayName),
              hostPath.hasPrefix("/"), hostPath.hasSuffix(".app"), hostPath.utf8.count <= 4096,
              URL(fileURLWithPath: hostPath).standardizedFileURL.path == hostPath,
              !containsControls(hostPath), hostBundleID.utf8.count <= 256, !hostBundleID.isEmpty,
              !containsControls(hostBundleID) else { return nil }

        let canonicalVM = URL(fileURLWithPath: vmPath).standardizedFileURL.resolvingSymlinksInPath().path
        let expectedID = SHA256.hash(data: Data((canonicalVM + "\0" + appPath).utf8))
            .prefix(16).map { String(format: "%02x", $0) }.joined()
        guard canonicalVM == vmPath, expectedID == stableID,
              directory.lastPathComponent == stableID,
              let executableAttributes = try? fm.attributesOfItem(atPath: executable.path),
              (executableAttributes[.posixPermissions] as? NSNumber).map({ $0.intValue & 0o111 != 0 }) == true,
              let hostURL = validHostURL(path: hostPath, bundleID: hostBundleID) else { return nil }
        _ = hostURL // Validation is repeated when the URL is dispatched.
        return LauncherConfig(stableID: stableID, vmPath: vmPath, appPath: appPath,
                              displayName: displayName, hostPath: hostPath,
                              hostBundleID: hostBundleID, directory: directory)
    }

    private static func safePath(_ url: URL, directory: Bool) -> Bool {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isDirectory == directory,
              (directory || values.isRegularFile == true),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              let mode = (attributes[.posixPermissions] as? NSNumber)?.intValue,
              (directory ? mode == 0o700 : mode == 0o600) else { return false }
        return true
    }

    private static func safeOwnedDirectory(_ url: URL) -> Bool {
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()) else { return false }
        return true
    }

    private static func validHostURL(path: String, bundleID: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        if isHostApplication(url, bundleID: bundleID) { return url }
        // The originally selected host may have moved. Resolve by its exact
        // bundle identifier only; never fall back to the system URL handler.
        guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              isHostApplication(registered, bundleID: bundleID) else { return nil }
        return registered
    }

    private static func isHostApplication(_ url: URL, bundleID: String) -> Bool {
        let canonical = url.standardizedFileURL
        guard canonical.pathExtension == "app",
              canonical.resolvingSymlinksInPath().standardizedFileURL == canonical,
              let values = try? canonical.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
              values.isSymbolicLink != true, values.isDirectory == true,
              Bundle(url: canonical)?.bundleIdentifier == bundleID else { return false }
        return true
    }

    func runtimeURL() -> URL { directory.appendingPathComponent("runtime.plist") }
    func iconURL() -> URL { directory.appendingPathComponent("icon.png") }
}

private struct RuntimeState {
    let stableID: String
    let vmPath: String
    let appPath: String
    let ownerPID: Int32
    let session: String
    let state: String

    static func load(config: LauncherConfig) -> RuntimeState? {
        let url = config.runtimeURL()
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              (attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600,
              (attributes[.size] as? NSNumber)?.intValue ?? Int.max <= 16 * 1024,
              let data = try? Data(contentsOf: url),
              let object = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil),
              let dict = object as? [String: Any],
              (dict["Version"] as? NSNumber)?.intValue == 1,
              let stableID = dict["StableIdentifier"] as? String,
              let vmPath = dict["VMPackagePath"] as? String,
              let appPath = dict["GuestApplicationPath"] as? String,
              let owner = dict["OwnerPID"] as? NSNumber,
              let session = dict["Session"] as? String,
              let state = dict["State"] as? String,
              ["running", "unknown", "stopped"].contains(state),
              stableID == config.stableID, vmPath == config.vmPath, appPath == config.appPath,
              owner.int64Value > 0, owner.int64Value <= Int32.max,
              UUID(uuidString: session) != nil,
              processIDsAreSafe(dict["ProcessIDs"]) else { return nil }
        return RuntimeState(stableID: stableID, vmPath: vmPath, appPath: appPath,
                            ownerPID: owner.int32Value, session: session, state: state)
    }

    private static func processIDsAreSafe(_ value: Any?) -> Bool {
        guard let value else { return true }
        guard let numbers = value as? [NSNumber], numbers.count <= 256 else { return false }
        return numbers.allSatisfy { $0.int64Value > 0 && $0.int64Value <= Int32.max }
    }
}

final class Delegate: NSObject, NSApplicationDelegate {
    private var config: LauncherConfig?
    private var validatedStartupConfig: LauncherConfig?
    private var runtimeMode = false
    private var attachedSession: String?
    private var attachedOwner: Int32?
    private var coldURLSent = false
    // LaunchServices may deliver an open-doc Apple event before the host has
    // published this launcher's runtime attachment. Keep only validated paths
    // until attach(), then forward them through the same scoped action channel.
    private var pendingOpenPaths: [String] = []
    private var lastActionByName: [String: Date] = [:]
    private var timeout: DispatchWorkItem?
    private var ownerWatch: Timer?
    private var stateObserver: NSObjectProtocol?

    fileprivate func useStartupConfig(_ config: LauncherConfig) {
        validatedStartupConfig = config
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        NSApp.setActivationPolicy(.regular)
        guard let config = validatedStartupConfig ?? LauncherConfig.load() else { NSApp.terminate(nil); return }
        self.config = config
        runtimeMode = ProcessInfo.processInfo.environment["PE_DOCK_RUNTIME"] == "1"
        setDockName(config.displayName)
        reloadOwnIcon()
        stateObserver = DistributedNotificationCenter.default().addObserver(
            forName: stateNotification, object: config.stableID as NSString, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated { self?.receiveState(note) }
        }

        if let state = RuntimeState.load(config: config), attachable(state) {
            attach(state)
            // A user-started durable launcher should activate the already
            // running guest app. Host-started representatives set runtimeMode
            // and must remain passive; cold URL launches attach later through
            // receiveState and must not dispatch a second activation here.
            if !runtimeMode && !coldURLSent {
                postAction("activate", session: state.session, owner: state.ownerPID)
            }
        } else if runtimeMode {
            // A host-started representative is never responsible for starting
            // the VM. If its runtime sidecar is already stale, exit instead of
            // lingering as an unattached Dock process.
            NSApp.terminate(nil)
            return
        } else {
            dispatchColdURL()
        }
        armAttachDeadline()
        ownerWatch = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOwner() }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if attachedSession != nil { postAction("activate") }
        else if !runtimeMode { dispatchColdURL() }
        NSApp.hide(nil)
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        // Launching a representative must not itself open the guest app.
        NSApp.hide(nil)
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard attachedSession != nil else { return .terminateNow }
        postAction("quit")
        return .terminateCancel
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        guard !filenames.isEmpty, filenames.count <= 64,
              pendingOpenPaths.count + filenames.count <= 64,
              filenames.allSatisfy({ $0.hasPrefix("/") && $0.utf8.count <= 4096 && !containsControls($0) }) else {
            sender.reply(toOpenOrPrint: .failure)
            return
        }
        if attachedSession != nil {
            postAction("open", paths: filenames)
        } else {
            pendingOpenPaths.append(contentsOf: filenames)
        }
        sender.reply(toOpenOrPrint: .success)
        NSApp.hide(nil)
    }

    private func receiveState(_ note: Notification) {
        guard let config, (note.object as? String) == config.stableID,
              let userInfo = note.userInfo,
              let session = userInfo["session"] as? String,
              let ownerString = userInfo["owner"] as? String,
              let owner = Int32(ownerString), let vm = userInfo["vm"] as? String,
              let app = userInfo["app"] as? String,
              let state = userInfo["state"] as? String,
              ["running", "unknown", "stopped"].contains(state),
              UUID(uuidString: session) != nil,
              vm == config.vmPath, app == config.appPath,
              let saved = RuntimeState.load(config: config),
              saved.session == session, saved.ownerPID == owner, saved.state == state else { return }
        if state == "stopped" {
            if attachedSession == session && attachedOwner == owner {
                // Clear attachment first so the normal close path cannot
                // interpret the host's stop request as a guest Quit request.
                attachedSession = nil
                attachedOwner = nil
                NSApp.terminate(nil)
            }
            return
        }
        guard attachable(saved) else { return }
        attach(saved)
    }

    private func attachable(_ state: RuntimeState) -> Bool {
        guard state.state == "running" || state.state == "unknown",
              kill(state.ownerPID, 0) == 0,
              let ownerApp = NSRunningApplication(processIdentifier: state.ownerPID),
              ownerApp.bundleIdentifier == config?.hostBundleID else { return false }
        return true
    }

    private func attach(_ state: RuntimeState) {
        guard attachedSession != state.session || attachedOwner != state.ownerPID else {
            // Icon data is updated beside the immutable helper, then the host
            // republishes the same session state. Refresh artwork without
            // emitting another ready/action handshake.
            reloadOwnIcon()
            return
        }
        attachedSession = state.session
        attachedOwner = state.ownerPID
        timeout?.cancel(); timeout = nil
        postAction("ready", session: state.session, owner: state.ownerPID)
        reloadOwnIcon()
        if !pendingOpenPaths.isEmpty {
            let paths = pendingOpenPaths
            pendingOpenPaths.removeAll(keepingCapacity: false)
            postAction("open", paths: paths)
        }
    }

    private func checkOwner() {
        guard let session = attachedSession, let owner = attachedOwner else { return }
        guard let config, let state = RuntimeState.load(config: config),
              state.session == session, state.ownerPID == owner,
              state.state == "running" || state.state == "unknown",
              attachable(state) else {
            attachedSession = nil
            attachedOwner = nil
            NSApp.terminate(nil)
            return
        }
    }

    private func armAttachDeadline() {
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.attachedSession == nil else { return }
            NSApp.terminate(nil)
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + attachWait, execute: work)
    }

    private func dispatchColdURL() {
        guard !coldURLSent, let config else { return }
        coldURLSent = true
        var components = URLComponents()
        components.scheme = "poweremu"
        components.host = "guest-app"
        components.queryItems = [URLQueryItem(name: "vm", value: config.vmPath),
                                 URLQueryItem(name: "app", value: config.appPath)]
        guard let url = components.url,
              let hostURL = resolvedHostURL(config),
              let hostBundle = Bundle(url: hostURL), hostBundle.bundleIdentifier == config.hostBundleID else {
            NSApp.terminate(nil)
            return
        }
        let open = NSWorkspace.OpenConfiguration()
        open.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: hostURL, configuration: open) { [weak self] _, error in
            guard error != nil else { return }
            DispatchQueue.main.async { self?.terminateIfUnattached() }
        }
    }

    private func resolvedHostURL(_ config: LauncherConfig) -> URL? {
        let exact = URL(fileURLWithPath: config.hostPath).standardizedFileURL
        if let values = try? exact.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey]),
           values.isSymbolicLink != true, values.isDirectory == true,
           Bundle(url: exact)?.bundleIdentifier == config.hostBundleID {
            return exact
        }
        guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: config.hostBundleID),
              Bundle(url: registered)?.bundleIdentifier == config.hostBundleID else { return nil }
        return registered
    }

    private func terminateIfUnattached() {
        if attachedSession == nil { NSApp.terminate(nil) }
    }

    private func postAction(_ action: String, session: String? = nil,
                            owner: Int32? = nil, paths: [String]? = nil) {
        guard let config,
              let current = RuntimeState.load(config: config), attachable(current),
              current.session == (session ?? attachedSession),
              current.ownerPID == (owner ?? attachedOwner) else { return }
        let now = Date()
        if action != "ready" && action != "open" {
            guard now.timeIntervalSince(lastActionByName[action] ?? .distantPast) >= 0.35 else { return }
            lastActionByName[action] = now
        }
        var info: [String: Any] = ["action": action, "session": current.session,
                                   "owner": String(current.ownerPID), "vm": config.vmPath,
                                   "app": config.appPath]
        if let paths { info["paths"] = paths }
        DistributedNotificationCenter.default().postNotificationName(
            actionNotification, object: config.stableID,
            userInfo: info, deliverImmediately: true)
    }

    private func reloadOwnIcon() {
        guard let config else { return }
        let url = config.iconURL()
        guard url.resolvingSymlinksInPath().standardizedFileURL == url.standardizedFileURL,
              let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey]),
              values.isSymbolicLink != true, values.isRegularFile == true,
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == UInt32(geteuid()),
              let data = try? Data(contentsOf: url), validDockIcon(data),
              let image = NSImage(data: data), image.isValid else { return }
        setDockIcon(image)
    }
}

// The Dock can start a pinned app at the same time PowerEmu starts a
// representative through LaunchServices. Serialize by stable launcher identity
// before NSApplication registers either process with LaunchServices.
private var instanceLeaseDescriptor: Int32 = -1
private var startupConfig: LauncherConfig?

private func acquireInstanceLease(for config: LauncherConfig) -> Int32? {
    let lockURL = config.directory.appendingPathComponent("instance.lock")
    let fd = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, mode_t(S_IRUSR | S_IWUSR))
    guard fd >= 0 else { return nil }
    var info = stat()
    guard fstat(fd, &info) == 0,
          (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG),
          info.st_uid == uid_t(geteuid()),
          (info.st_mode & 0o777) == 0o600,
          info.st_nlink == 1 else {
        close(fd)
        return nil
    }
    if flock(fd, LOCK_EX | LOCK_NB) == 0 { return fd }
    let lockError = errno
    close(fd)
    if lockError == EWOULDBLOCK || lockError == EAGAIN { return -1 }
    return nil
}

private func activateExistingOwner(for config: LauncherConfig) {
    guard let state = RuntimeState.load(config: config),
          state.state == "running" || state.state == "unknown",
          kill(state.ownerPID, 0) == 0,
          let ownerApp = NSRunningApplication(processIdentifier: state.ownerPID),
          ownerApp.bundleIdentifier == config.hostBundleID else { return }
    DistributedNotificationCenter.default().postNotificationName(
        actionNotification, object: config.stableID,
        userInfo: ["action": "activate", "session": state.session,
                   "owner": String(state.ownerPID), "vm": config.vmPath,
                   "app": config.appPath], deliverImmediately: true)
}

// Do not initialize/register an AppKit application for a duplicate process.
// A busy lock with no valid active session is a coalesced cold start and exits
// quietly; the lock holder is already responsible for opening PowerEmu.
if let config = LauncherConfig.load() {
    guard let lease = acquireInstanceLease(for: config) else { exit(1) }
    if lease == -1 {
        // A LaunchServices open from PowerEmu is only an attempt to establish
        // the representative; if another instance won the race, it must stay
        // passive. A user-launched duplicate (Dock click) means activate.
        if ProcessInfo.processInfo.environment["PE_DOCK_RUNTIME"] != "1" {
            activateExistingOwner(for: config)
        }
        exit(0)
    }
    instanceLeaseDescriptor = lease
    startupConfig = config
}

let app = NSApplication.shared
let delegate = Delegate()
// The config was validated before acquiring the identity lease. Reuse that
// snapshot so a concurrent sidecar rewrite cannot switch this process to a
// different identity after the lock has been acquired.
if let startupConfig { delegate.useStartupConfig(startupConfig) }
app.delegate = delegate
app.run()
