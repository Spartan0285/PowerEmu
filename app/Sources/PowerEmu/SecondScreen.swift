import AppKit

/*
 * The virtual Mac's second screen.
 *
 * A second screen is a second graphics card (see VMRunner), and Mac OS X
 * extends its desktop across the two by itself.  Each card has its own
 * QEMU console and its own socket, so this is a second window showing a
 * second picture -- not another view of the first.
 *
 * It is deliberately plainer than the main window.  No toolbar, because
 * every control in it acts on the machine and the machine already has a
 * window with those controls; no Harmony, which is a one-screen idea and
 * runs on the first screen; no status sheets.  What it has is the picture,
 * the keyboard, and the mouse.
 *
 * The mouse is the one real constraint.  The virtual Mac's pointer is a USB
 * tablet, which reports where it is rather than how far it moved, and Mac OS
 * X maps those absolute positions onto its main display alone -- so with the
 * tablet driving it the pointer can never leave the first screen.  A machine
 * with two screens therefore uses the relative mouse: both windows capture,
 * and the pointer travels between the screens the way it does on a real Mac.
 * VirtualMachine switches the machine over when a second screen is turned on.
 */
@MainActor
final class SecondScreenController: NSWindowController, NSWindowDelegate {
    static var open: [URL: SecondScreenController] = [:]

    let display: VMDisplayView
    private let key: URL

    init(vm: VirtualMachine, channel: DisplayChannel) {
        key = vm.url
        display = VMDisplayView(channel: channel)
        let w = VMWindow(contentRect: NSRect(x: 0, y: 0, width: 1280, height: 1024),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "\(vm.config.name) \u{2014} Screen 2"
        w.contentView = display
        w.collectionBehavior = [.fullScreenPrimary]
        w.acceptsMouseMovedEvents = true
        w.backgroundColor = .black
        w.setFrameAutosaveName("PowerEmu VM \(vm.config.name) Screen 2")
        super.init(window: w)
        w.delegate = self
        display.onToggleFullScreen = { [weak w, weak vm] in
            if let vm, vm.config.displays > 1 {
                DualScreenLayout.toggle(for: vm)
            } else {
                w?.toggleFullScreen(nil)
            }
        }
        Self.configure(display, for: vm)
        /* The guest screen's shape, for sizing and placing this window. */
        let size = display.guestSize
        w.contentAspectRatio = size
        if w.frameAutosaveName.isEmpty || !w.setFrameUsingName(w.frameAutosaveName) {
            /*
             * Never placed before: put it beside the machine's own window
             * rather than on top of it, since the two stand side by side in
             * the guest's desktop as well.  Once it has been moved or
             * resized it stays where it was left.
             */
            var f = w.frame
            if let main = VMWindowController.open[vm.url]?.window,
               let screen = main.screen ?? NSScreen.main {
                let scale = min(1, (screen.visibleFrame.width - main.frame.width - 24)
                                / size.width,
                                screen.visibleFrame.height / size.height)
                let content = CGSize(width: (size.width * max(scale, 0.25)).rounded(),
                                     height: (size.height * max(scale, 0.25)).rounded())
                f = w.frameRect(forContentRect: CGRect(origin: .zero, size: content))
                f.origin = CGPoint(x: min(main.frame.maxX + 12,
                                          screen.visibleFrame.maxX - f.width),
                                   y: main.frame.maxY - f.height)
                f.origin.x = max(screen.visibleFrame.minX, f.origin.x)
                f.origin.y = max(screen.visibleFrame.minY, f.origin.y)
            }
            w.setFrame(f, display: false)
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    /*
     * The wiring a second guest screen's view needs, wherever it is shown:
     * its own window on a Mac with two screens, or the right-hand pane of the
     * machine's own window on a Mac with one.  Both presentations drive the
     * same second card, so they want the same view, and having one place to
     * set it up stops the two drifting apart.
     */
    static func configure(_ display: VMDisplayView, for vm: VirtualMachine) {
        display.machineName = vm.config.name
        /*
         * Relative only.  The guest's pointer is a USB tablet, which reports
         * where it is rather than how far it moved, and Mac OS X maps those
         * absolute positions onto its main display alone -- so with the tablet
         * driving it the pointer could never leave the first screen.
         */
        display.mouseMode = .captured
        /*
         * The second screen's own figures.  It is a second card with its own
         * frame counter, so its overlay asks card 1 rather than card 0.
         */
        display.queryPerf = { [weak vm] done in
            guard let vm else { done(nil); return }
            MainActor.assumeIsolated { vm.queryPerf(screen: 1, done: done) }
        }
        display.qemuPID = { [weak vm] in
            MainActor.assumeIsolated { vm?.qemuPID }
        }
        display.scaling = vm.config.scaling
        display.panelFilter = vm.config.panelFilter
        display.displayFit = vm.config.displayFit
        display.setGuestSize(CGSize(width: max(640, vm.config.display2Width),
                                    height: max(480, vm.config.display2Height)))
    }

    /*
     * Take this window away while harmony is on, and put it back after.
     *
     * Ordering a full-screen window out leaves its Space behind: the window
     * is hidden but macOS keeps the full-screen desktop it was living on, so
     * what the reader gets is a black screen sitting next to their work.  It
     * has to leave full screen first, and the hide has to wait for that
     * animation to finish -- hence the flag and the delegate callback rather
     * than an orderOut() straight after toggleFullScreen().
     */
    private var hideOnLeavingFullScreen = false
    private var wasFullScreenForHarmony = false

    func hideForHarmony() {
        guard let w = window else { return }
        if w.styleMask.contains(.fullScreen) {
            wasFullScreenForHarmony = true
            hideOnLeavingFullScreen = true
            w.toggleFullScreen(nil)
        } else {
            w.orderOut(nil)
        }
    }

    func showAfterHarmony() {
        guard let w = window else { return }
        hideOnLeavingFullScreen = false
        w.orderFront(nil)
        if wasFullScreenForHarmony {
            wasFullScreenForHarmony = false
            w.toggleFullScreen(nil)      // back to the screen it was filling
        }
    }

    func windowDidExitFullScreen(_ notification: Notification) {
        guard hideOnLeavingFullScreen else { return }
        hideOnLeavingFullScreen = false
        window?.orderOut(nil)
    }

    @discardableResult
    static func show(_ vm: VirtualMachine, channel: DisplayChannel) -> SecondScreenController {
        let c = open[vm.url] ?? SecondScreenController(vm: vm, channel: channel)
        open[vm.url] = c
        c.showWindow(nil)
        c.window?.makeFirstResponder(c.display)
        return c
    }

    static func close(_ vm: VirtualMachine) {
        guard let c = open.removeValue(forKey: vm.url) else { return }
        c.display.releaseAll()
        c.window?.orderOut(nil)
        c.window?.close()
    }

    /*
     * Closing this window does not stop the machine -- the machine's own
     * window is elsewhere.  It only puts the second screen away, and the
     * guest carries on drawing to a card nobody is watching, which is what
     * unplugging a monitor does.
     */
    func windowWillClose(_ note: Notification) {
        display.releaseAll()
        Self.open.removeValue(forKey: key)
    }
}
