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
        // The guest may present a Save dialog or decline to quit. Keep its
        // tile until PowerEmu observes the guest process actually disappear.
        return .terminateCancel
    }

    func application(_ sender: NSApplication, openFiles filenames: [String]) {
        let info = Bundle.main.infoDictionary ?? [:]
        guard let pid = info["PEGuestPID"] as? String, let session = info["PESession"] as? String else {
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
            object: nil, userInfo: ["pid": pid, "session": Bundle.main.object(forInfoDictionaryKey: "PESession") as? String ?? ""], deliverImmediately: true)
    }
}

let app = NSApplication.shared
let delegate = Delegate()
app.delegate = delegate
app.run()
