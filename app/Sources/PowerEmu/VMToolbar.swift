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
            menuButton("keyboard", "Keys", "Send keys this Mac would keep for itself", keys),
            menuButton("externaldrive.connected.to.line.below", "Devices", "Discs, this Mac's drives and USB devices", devicesMenu),
            iconButton("speedometer", "Performance (Control-Option-P)", #selector(togglePerf)),
            menuButton("power", "Power", "Shut down, restart or force off", power),
            iconButton("arrow.up.left.and.arrow.down.right", "Full screen (Control-Option-F)", #selector(fullScreen)),
        ]
        bar.setContent(items)
        bar.alphaValue = 0
        bar.isHidden = true
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
        b.imagePosition = .imageLeading
        b.bezelStyle = .texturedRounded
        b.isBordered = false
        b.toolTip = tip
        b.refusesFirstResponder = true
        b.controlSize = .small
        b.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
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

    /// The pointer is at `p` (view coordinates): show the bar when it reaches
    /// the top edge, hide it after the pointer has left it.
    func pointerMoved(_ p: NSPoint, in view: NSView) {
        if !shown {
            if p.y >= view.bounds.maxY - 4 && abs(p.x - view.bounds.midX) < view.bounds.width / 2 { reveal() }
            return
        }
        if bar.frame.insetBy(dx: -24, dy: -24).contains(p) {
            hideTimer?.invalidate()
        } else {
            scheduleHide()
        }
    }

    func reveal() {
        hideTimer?.invalidate()
        guard !shown else { return }
        shown = true
        mouseControl?.selectedSegment = display?.mouseMode == .captured ? 1 : 0
        bar.isHidden = false
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.18
            bar.animator().alphaValue = 1
        }
    }

    private func scheduleHide() {
        guard shown, !menuOpen, hideTimer == nil || !(hideTimer!.isValid) else { return }
        hideTimer = Timer.scheduledTimer(withTimeInterval: 0.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.hide() }
        }
    }

    func hide() {
        guard shown, !menuOpen else { return }
        shown = false
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = 0.25
            bar.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { if self?.shown == false { self?.bar.isHidden = true } }
        })
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

    @objc private func togglePerf() { display?.togglePerformance(); refocus() }
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

/// A small rounded HUD holding the controls, like Parallels' bar.
final class OverlayBar: NSVisualEffectView {
    private let stack = NSStackView()

    init() {
        super.init(frame: .zero)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        stack.orientation = .horizontal
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
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

    var fittingBarSize: NSSize { stack.fittingSize }

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
