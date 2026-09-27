import AppKit

/*
 * One guest application's place in this Mac's Dock.
 *
 * This Mac gives a Dock tile to a running process, so a guest application
 * needs something of its own running here to have one.  That is all this is:
 * it shows no window, draws nothing, and does no work.  It sits in the Dock
 * under the guest application's name and icon, and when somebody clicks it or
 * quits it, it says so and lets PowerEmu do the rest.
 *
 * PowerEmu builds one of these for each of the guest's applications, with the
 * name, the icon and the guest's process id written into its Info.plist.
 */
final class Delegate: NSObject, NSApplicationDelegate {
    private var pid = ""

    func applicationDidFinishLaunching(_ note: Notification) {
        pid = Bundle.main.object(forInfoDictionaryKey: "PEGuestPID") as? String ?? ""
        // Nothing to show: the tile is the whole of it.
        NSApp.setActivationPolicy(.regular)
    }

    /// Clicking the tile, whether or not this happens to be the active
    /// application already.
    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        tell("clicked")
        return true
    }

    func applicationDidBecomeActive(_ note: Notification) {
        tell("clicked")
        // Never keep the focus: the guest's window is what should have it, and
        // it lives in PowerEmu.
        NSApp.hide(nil)
    }

    func applicationShouldTerminate(_ s: NSApplication) -> NSApplication.TerminateReply {
        tell("quit")
        return .terminateNow
    }

    private func tell(_ what: String) {
        guard !pid.isEmpty else { return }
        DistributedNotificationCenter.default().postNotificationName(
            .init("com.spartan0285.poweremu.guestapp.\(what)"),
            object: nil, userInfo: ["pid": pid], deliverImmediately: true)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
