import AppKit

/*
 * Where the virtual Mac's two screens go on this Mac's screens.
 *
 * A second guest screen is a second graphics card with its own window, and
 * the two windows are not interchangeable: guest screen 1 carries the menu
 * bar and the Dock, so it belongs on the screen the reader treats as their
 * main one, with guest screen 2 beside it.  Left to itself macOS would send
 * both windows full screen on whichever screen each happened to be sitting
 * on, which is routinely the same one -- one guest screen full screen and
 * the other hidden behind it.
 *
 * The placement is only ever applied on the way *into* full screen.  A
 * windowed pair stays wherever the reader dragged it, and comes back there
 * afterwards, because each window has its own frame autosave name and AppKit
 * restores the pre-full-screen frame on the way out.
 */
@MainActor
enum DualScreenLayout {
    /*
     * This Mac's screens, main one first.
     *
     * NSScreen.screens is in no particular order and NSScreen.main is "the
     * one with the key window", which during a menu action is whichever
     * window the reader last used -- not necessarily the one carrying the
     * menu bar.  The menu bar's screen is the first element of
     * NSScreen.screens, which is the stable meaning of "primary" here.
     */
    static func ordered() -> [NSScreen] {
        let all = NSScreen.screens
        guard let primary = all.first else { return [] }
        return [primary] + all.dropFirst()
    }

    /// The screen guest screen `index` (0 or 1) should occupy, if there is one.
    static func host(for index: Int) -> NSScreen? {
        let screens = ordered()
        guard index < screens.count else { return nil }
        return screens[index]
    }

    /*
     * Move a window onto `screen` without resizing it.
     *
     * macOS enters full screen on the screen the window is currently on, so
     * a window has to be moved *before* toggleFullScreen, not after.  The
     * frame is clamped into the target's visible area so the title bar stays
     * reachable if the reader leaves full screen again.
     */
    static func move(_ window: NSWindow, to screen: NSScreen) {
        guard window.screen !== screen else { return }
        let area = screen.visibleFrame
        var f = window.frame
        f.size.width = min(f.width, area.width)
        f.size.height = min(f.height, area.height)
        f.origin.x = area.midX - f.width / 2
        f.origin.y = area.midY - f.height / 2
        window.setFrame(f, display: true)
    }

    /*
     * Put the machine's windows on their screens and send both full screen.
     *
     * With one host screen there is nothing to arrange and this is an
     * ordinary full-screen toggle on the main window: the second window is
     * left alone rather than being stacked full screen on top of the first,
     * where it would hide it.
     */
    static func enterFullScreen(main: NSWindow, second: NSWindow?, vm: VirtualMachine? = nil) {
        /* Remember the windowed arrangement for this set of monitors before
         * full screen overwrites both frames.  See WindowPlacement. */
        if let vm { WindowPlacement.saveAll(for: vm) }
        let screens = ordered()
        guard let secondWindow = second, screens.count > 1 else {
            if !main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
            return
        }
        if let a = host(for: 0) { move(main, to: a) }
        if let b = host(for: 1) { move(secondWindow, to: b) }
        /*
         * Each window animates onto its own screen independently.  Toggling
         * them in the same turn of the run loop makes AppKit animate both at
         * once, which is what a reader expects from one keystroke.
         */
        if !main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
        if !secondWindow.styleMask.contains(.fullScreen) {
            secondWindow.toggleFullScreen(nil)
        }
    }

    /// Leave full screen on both windows.  AppKit restores each one's own
    /// pre-full-screen frame, so nothing has to be remembered here.
    static func leaveFullScreen(main: NSWindow, second: NSWindow?, vm: VirtualMachine? = nil) {
        if main.styleMask.contains(.fullScreen) { main.toggleFullScreen(nil) }
        if let s = second, s.styleMask.contains(.fullScreen) { s.toggleFullScreen(nil) }
        /*
         * AppKit restores each window's own pre-full-screen frame, but it
         * does that per window and knows nothing about the pair or about
         * which monitor each belonged to.  Putting the saved arrangement back
         * afterwards covers the case where the monitors changed while the
         * machine was full screen.  It runs after the exit animation, or it
         * would fight it.
         */
        if let vm {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                MainActor.assumeIsolated { WindowPlacement.restoreAll(for: vm) }
            }
        }
    }

    /// Both windows of a machine, when it has a second screen open.
    static func windows(for vm: VirtualMachine) -> (main: NSWindow?, second: NSWindow?) {
        (VMWindowController.open[vm.url]?.window,
         SecondScreenController.open[vm.url]?.window)
    }

    /// The full-screen action for a machine: into full screen across both
    /// screens, or out of it, depending on where it is now.
    static func toggle(for vm: VirtualMachine) {
        let (main, second) = windows(for: vm)
        guard let main else { return }
        if main.styleMask.contains(.fullScreen) {
            leaveFullScreen(main: main, second: second, vm: vm)
        } else {
            enterFullScreen(main: main, second: second, vm: vm)
        }
    }
}
