import AppKit
import UniformTypeIdentifiers

/// The virtual Mac's control bar, as in Parallels: mouse mode, keys the host
/// would otherwise take, devices (discs, this Mac's drives and USB),
/// performance, power and full screen.  It floats over the top of the
/// guest's screen - it never takes room from it - and stays hidden until the
/// pointer reaches the top edge (VMDisplayView.mouseMoved calls reveal).
@MainActor
final class VMToolbarController: NSObject, NSMenuDelegate {
    private weak var controller: VMWindowController?
    private var mouseControl: NSSegmentedControl?
    private var pauseButton: NSButton?
    private let devicesMenu = NSMenu(title: "Devices")
    private var keys = NSMenu(), power = NSMenu()
    let bar = OverlayBar()
    private var hideTimer: Timer?
    private var menuOpen = false
    private(set) var shown = false

    init(_ c: VMWindowController) {
        controller = c
        super.init()
        devicesMenu.delegate = self
        keys = keysMenu()
        keys.delegate = self
        power = NSMenu()
        power.addItem(entry("Shut Down", #selector(shutDown)))
        power.addItem(entry("Restart", #selector(restart)))
        power.addItem(.separator())
        power.addItem(entry("Force Power Off…", #selector(forceOff)))
        power.delegate = self
        build()
    }

    private var vm: VirtualMachine? { controller?.vm }
    private var display: VMDisplayView? { controller?.display }

    /// Clicks on the bar shouldn't leave the keyboard away from the guest.
    private func refocus() {
        if let d = display { controller?.window?.makeFirstResponder(d) }
    }

    // MARK: the bar

    private func build() {
        let seg = NSSegmentedControl(labels: ["Seamless", "Captured"], trackingMode: .selectOne,
                                     target: self, action: #selector(mouseChanged(_:)))
        seg.setImage(NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil), forSegment: 0)
        seg.setImage(NSImage(systemSymbolName: "scope", accessibilityDescription: nil), forSegment: 1)
        seg.setToolTip("The pointer moves in and out of the virtual Mac freely", forSegment: 0)
        seg.setToolTip("A click captures the mouse (for games); Control-Option-G releases it", forSegment: 1)
        seg.selectedSegment = display?.mouseMode == .captured ? 1 : 0
        seg.refusesFirstResponder = true
        seg.controlSize = .small
        mouseControl = seg

        let items: [NSView] = [
            seg,
            separator(),
            menuButton("keyboard", "Keys", "Send keys this Mac would keep for itself", keys),
            menuButton("externaldrive.connected.to.line.below", "Devices", "Discs, this Mac's drives and USB devices", devicesMenu),
            separator(),
            pauseItem(),
            labelledButton("moon.fill", "Sleep", "Save the virtual Mac as it is and close it", #selector(sleepMachine)),
            menuButton("power", "Power", "Shut down, restart or force off", power),
            OverlayBar.space(),
            labelledButton("macwindow.on.rectangle", "Coherence",
                           "Show the virtual Mac's windows on this Mac's desktop, without its wallpaper (Control-Option-C)",
                           #selector(toggleCoherence)),
            labelledButton("speedometer", "Stats", "Show what the virtual Mac and this Mac are doing (Control-Option-P)", #selector(togglePerf)),
            labelledButton("arrow.up.left.and.arrow.down.right", "Full Screen", "Fill the screen (Control-Option-F)", #selector(fullScreen)),
        ]
        bar.setContent(items)
        bar.alphaValue = 0
        bar.isHidden = true
    }

    /// A button that says what it does: an ordinary toolbar item, rather
    /// than an icon the reader has to hover over to identify.
    private func labelledButton(_ symbol: String, _ title: String, _ tip: String,
                                _ action: Selector) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                         target: self, action: action)
        b.imagePosition = .imageAbove
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.refusesFirstResponder = true
        b.imageScaling = .scaleProportionallyDown
        b.font = .systemFont(ofSize: 10)
        b.setAccessibilityLabel(title)
        return b
    }

    /// Pause, or Continue when the machine is already stopped where it
    /// stands: one button, saying which it will do.
    private func pauseItem() -> NSButton {
        let b = labelledButton("pause.fill", "Pause",
                               "Stop the virtual Mac where it stands", #selector(pauseOrResume))
        pauseButton = b
        return b
    }

    private func updatePauseItem() {
        guard let b = pauseButton else { return }
        let paused = vm?.state == .paused
        b.title = paused ? "Continue" : "Pause"
        b.image = NSImage(systemSymbolName: paused ? "play.fill" : "pause.fill",
                          accessibilityDescription: b.title)
        b.toolTip = paused ? "Let the virtual Mac carry on from where it stopped"
                           : "Stop the virtual Mac where it stands"
    }

    /// A hairline between groups of controls.
    private func separator() -> NSView {
        let v = NSBox()
        v.boxType = .separator
        v.translatesAutoresizingMaskIntoConstraints = false
        v.heightAnchor.constraint(equalToConstant: 30).isActive = true
        return v
    }

    private func iconButton(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: self, action: action)
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.refusesFirstResponder = true
        b.setAccessibilityLabel(tip)
        return b
    }

    private func menuButton(_ symbol: String, _ title: String, _ tip: String, _ menu: NSMenu) -> NSButton {
        let b = NSButton(title: title, image: NSImage(systemSymbolName: symbol, accessibilityDescription: title)!,
                         target: self, action: #selector(popMenu(_:)))
        b.imagePosition = .imageAbove
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.refusesFirstResponder = true
        b.imageScaling = .scaleProportionallyDown
        b.font = .systemFont(ofSize: 10)
        objc_setAssociatedObject(b, &Self.menuKey, menu, .OBJC_ASSOCIATION_RETAIN)
        return b
    }
    nonisolated(unsafe) private static var menuKey = 0

    @objc private func popMenu(_ b: NSButton) {
        guard let m = objc_getAssociatedObject(b, &Self.menuKey) as? NSMenu else { return }
        m.popUp(positioning: nil, at: NSPoint(x: 0, y: b.bounds.height + 4), in: b)
    }

    func menuWillOpen(_ menu: NSMenu) { menuOpen = true; hideTimer?.invalidate() }
    func menuDidClose(_ menu: NSMenu) { menuOpen = false; scheduleHide(); refocus() }

    // MARK: showing and hiding

    /// How close to the top the pointer must come for the bar to appear.
    /// A few pixels was too fine to aim at; a band the depth of a menu bar
    /// is what other virtual machine apps use.
    private static let revealBand: CGFloat = 26

    /// The pointer is at `p` (view coordinates): bring the bar down when it
    /// reaches the top of the screen, and let it go again once the pointer
    /// leaves.
    func pointerMoved(_ p: NSPoint, in view: NSView) {
        if !shown {
            if p.y >= view.bounds.maxY - Self.revealBand { reveal() }
            return
        }
        // Stay while the pointer is on the bar, or in the band above it.
        if p.y >= bar.frame.minY - 12 {
            hideTimer?.invalidate()
        } else {
            scheduleHide()
        }
    }

    func reveal() {
        hideTimer?.invalidate()
        guard !shown, let view = display else { return }
        shown = true
        mouseControl?.selectedSegment = display?.mouseMode == .captured ? 1 : 0
        updatePauseItem()
        bar.isHidden = false
        bar.alphaValue = 1
        place(in: view, shown: false, animated: false)   // just above the top edge
        place(in: view, shown: true, animated: true)     // and slide it down
        // The pointer is already where the bar is arriving, and no further
        // movement may follow, so hand it back to this Mac now rather than
        // leaving the reader with the guest's cursor stuck at the top edge.
        NSCursor.arrow.set()
        view.window?.invalidateCursorRects(for: view)
    }

    /// Put the bar where it belongs: down over the guest's screen when
    /// shown, tucked out of sight just above the top edge when not.
    ///
    /// Always flush with the top of the window, in full screen as anywhere
    /// else.  It used to be pushed down by the height of the menu bar in
    /// full screen, to sit below it -- but the menu bar only appears when
    /// the pointer reaches the top, which is the same movement that brings
    /// this bar down, so the two appeared together and the buttons ended up
    /// under the menu bar.  The window now keeps the menu bar hidden while
    /// it is full screen (see VMWindowController), and this edge is the
    /// bar's alone.
    func place(in view: NSView, shown showing: Bool, animated: Bool) {
        let height = OverlayBar.height
        let top = view.bounds.maxY
        let y = showing ? (top - height).rounded() : top.rounded()
        let frame = CGRect(x: view.bounds.minX, y: y, width: view.bounds.width, height: height)
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.22
                ctx.timingFunction = CAMediaTimingFunction(name: .easeOut)
                bar.animator().frame = frame
            }
        } else {
            bar.frame = frame
        }
    }

    private func scheduleHide() {
        guard shown, !menuOpen, hideTimer == nil || !(hideTimer!.isValid) else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        guard shown, !menuOpen, let view = display else { return }
        shown = false
        place(in: view, shown: false, animated: true)
        // Hidden only once it has slid back out of sight, so it isn't
        // clipped away mid-movement.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.24) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, !self.shown else { return }
                self.bar.isHidden = true
            }
        }
    }

    private func entry(_ title: String, _ action: Selector, _ tag: Int = 0) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        i.tag = tag
        return i
    }

    // MARK: mouse

    @objc private func mouseChanged(_ seg: NSSegmentedControl) {
        guard let d = display, let vm else { return }
        let mode: VMDisplayView.MouseMode = seg.selectedSegment == 1 ? .captured : .seamless
        d.mouseMode = mode
        vm.config.mouseMode = mode.rawValue
        try? vm.save()
        refocus()
    }

    // MARK: keys

    /// Combinations as Mac virtual key codes, pressed in order.
    private static let combos: [(String, [UInt16])] = [
        ("Force Quit  (⌘⌥⎋)", [55, 58, 53]),
        ("Switch Applications  (⌘⇥)", [55, 48]),
        ("Hide Others  (⌘⌥H)", [55, 58, 4]),
        ("Screenshot  (⌘⇧3)", [55, 56, 20]),
        ("Screenshot of Selection  (⌘⇧4)", [55, 56, 21]),
        ("-", []),
        ("Exposé: All Windows  (F9)", [101]),
        ("Exposé: Application Windows  (F10)", [109]),
        ("Exposé: Desktop  (F11)", [103]),
        ("Dashboard  (F12)", [111]),
        ("-", []),
        ("Log Out  (⌘⇧Q)", [55, 56, 12]),
    ]

    private func keysMenu() -> NSMenu {
        let m = NSMenu()
        for (i, c) in Self.combos.enumerated() {
            m.addItem(c.0 == "-" ? .separator() : entry(c.0, #selector(sendCombo(_:)), i))
        }
        m.addItem(.separator())
        m.addItem(entry("Power Key (shows the Shut Down dialog)", #selector(powerKey)))
        return m
    }

    @objc private func sendCombo(_ item: NSMenuItem) {
        display?.sendCombo(Self.combos[item.tag].1)
        refocus()
    }

    @objc private func powerKey() { vm?.pressPowerKey(); refocus() }

    // MARK: devices (built when the menu opens)

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === devicesMenu, let vm else { return }
        menu.removeAllItems()
        let running = vm.state == .running

        header(menu, "CD/DVD Drive")
        if let name = vm.hostDiscName ?? vm.config.insertedDisc.map({ ($0 as NSString).lastPathComponent }) {
            let cur = NSMenuItem(title: "In the drive: \(name)", action: nil, keyEquivalent: "")
            cur.isEnabled = false
            menu.addItem(cur)
            let e = entry("Eject", #selector(eject))
            e.isEnabled = running
            menu.addItem(e)
        } else {
            let none = NSMenuItem(title: "No disc", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(entry("Insert Disc Image…", #selector(insertDisc)))
        let recent = vm.config.discs.filter { $0 != vm.config.insertedDisc }.prefix(8)
        for (i, path) in recent.enumerated() {
            let it = entry("Insert " + (path as NSString).lastPathComponent, #selector(insertRecent(_:)), i)
            it.representedObject = path
            it.indentationLevel = 1
            menu.addItem(it)
        }
        if VirtualMachine.toolsDiscURL != nil {
            menu.addItem(entry("Insert PowerEmu Tools Disc", #selector(insertTools)))
        }
        let drives = HostDriveMonitor.shared.drives
        if !drives.isEmpty {
            menu.addItem(.separator())
            header(menu, "This Mac's Drives")
            for (i, d) in drives.enumerated() {
                let it = entry("Use " + d.name, #selector(useDrive(_:)), i)
                it.representedObject = d.bsdName
                it.isEnabled = running
                menu.addItem(it)
            }
        }

        menu.addItem(.separator())
        header(menu, "USB")
        let usb = HostUSBDevice.list()
        if usb.isEmpty {
            let none = NSMenuItem(title: "No USB devices", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        for d in usb {
            let it = entry(d.name, #selector(toggleUSB(_:)))
            it.representedObject = d
            it.state = vm.attachedUSB[d.id] != nil ? .on : .off
            it.isEnabled = running
            it.toolTip = String(format: "%04x:%04x — checked means the virtual Mac owns it", d.vendor, d.product)
            menu.addItem(it)
        }
    }

    private func header(_ menu: NSMenu, _ title: String) {
        if #available(macOS 14.0, *) {
            menu.addItem(NSMenuItem.sectionHeader(title: title))
        } else {
            let h = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            h.isEnabled = false
            menu.addItem(h)
        }
    }

    @objc private func eject() { vm?.ejectDisc(); refocus() }

    @objc private func insertDisc() {
        let p = NSOpenPanel()
        p.allowedContentTypes = VMConfig.discExtensions.compactMap { UTType(filenameExtension: $0) }
        p.message = "Choose a disc image to put in the virtual Mac's drive."
        p.prompt = "Insert"
        if p.runModal() == .OK, let u = p.url { vm?.insertDisc(u) }
        refocus()
    }

    @objc private func insertRecent(_ item: NSMenuItem) {
        if let path = item.representedObject as? String { vm?.insertDisc(URL(fileURLWithPath: path)) }
        refocus()
    }

    @objc private func insertTools() { vm?.insertToolsDisc(); refocus() }

    @objc private func useDrive(_ item: NSMenuItem) {
        if let bsd = item.representedObject as? String,
           let d = HostDriveMonitor.shared.drives.first(where: { $0.bsdName == bsd }) {
            vm?.insertHostDrive(d)
        }
        refocus()
    }

    @objc private func toggleUSB(_ item: NSMenuItem) {
        if let d = item.representedObject as? HostUSBDevice { vm?.toggleUSB(d) }
        refocus()
    }

    // MARK: the rest

    @objc private func toggleCoherence() {
        display?.coherence.toggle()
        refocus()
    }

    @objc private func togglePerf() { display?.togglePerformance(); refocus() }
    @objc private func pauseOrResume() {
        guard let vm else { return }
        if vm.state == .paused { vm.resume() } else { vm.pause() }
        refocus()
    }
    @objc private func sleepMachine() { vm?.sleep(); refocus() }
    @objc private func fullScreen() { controller?.window?.toggleFullScreen(nil) }
    @objc private func shutDown() { vm?.requestShutDown() }
    @objc private func restart() {
        guard let vm else { return }
        if vm.toolsConnected {
            vm.requestRestart()
        } else {
            let a = NSAlert()
            a.messageText = "Restart needs PowerEmu Tools"
            a.informativeText = "Install PowerEmu Tools in the virtual Mac (Devices → Insert PowerEmu Tools Disc), or choose Restart from its Apple menu."
            a.runModal()
        }
    }
    @objc private func forceOff() {
        guard let vm else { return }
        let a = NSAlert()
        a.messageText = "Force “\(vm.config.name)” to power off?"
        a.informativeText = "This is like pulling the plug: unsaved work is lost and Mac OS X may need to repair its disk."
        a.addButton(withTitle: "Cancel")
        a.addButton(withTitle: "Force Power Off")
        if a.runModal() == .alertSecondButtonReturn { vm.forcePowerOff() }
    }
}

/// The toolbar: the width of the window, coming down over the top of the
/// guest's screen when the pointer reaches the edge, the way a virtual
/// machine's controls are expected to behave.  It was a small floating
/// panel in the middle, which was fiddly to hit and looked like a widget
/// rather than a toolbar.
final class OverlayBar: NSVisualEffectView {
    private let stack = NSStackView()
    /// A toolbar's worth of height: an icon with its word underneath, as
    /// the Finder's own toolbar has them.
    static let height: CGFloat = 52

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        stack.orientation = .horizontal
        stack.spacing = 12
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 3, left: 14, bottom: 3, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError() }

    func setContent(_ views: [NSView]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        views.forEach { stack.addArrangedSubview($0) }
    }

    /// A line along the bottom, so the bar reads as a bar rather than as a
    /// tint over the guest's own picture.
    override func draw(_ dirty: NSRect) {
        super.draw(dirty)
        NSColor.white.withAlphaComponent(0.15).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }

    /// Something that pushes what follows it to the right.
    static func space() -> NSView {
        let v = NSView()
        v.translatesAutoresizingMaskIntoConstraints = false
        v.setContentHuggingPriority(.init(1), for: .horizontal)
        v.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return v
    }

    /// Over the bar the Mac's own pointer shows (the guest's hides).
    override func resetCursorRects() { addCursorRect(bounds, cursor: .arrow) }

    /// Clicks on the bar are the bar's, not the guest's: the background
    /// between buttons swallows them instead of passing them down.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {}
    override func mouseUp(with event: NSEvent) {}
    override func rightMouseDown(with event: NSEvent) {}
    override func rightMouseUp(with event: NSEvent) {}
}
