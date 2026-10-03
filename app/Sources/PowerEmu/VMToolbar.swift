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
    private lazy var devicesButton: NSButton = menuButton(
        "externaldrive.connected.to.line.below", "Devices",
        "Discs, this Mac's drives and USB devices", devicesMenu)
    /// The dot drawn on the Devices icon while the guest's tools want
    /// installing or updating.
    private let devicesBadge: NSView = {
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 9, height: 9))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.systemBlue.cgColor
        v.layer?.cornerRadius = 4.5
        v.layer?.borderWidth = 1.5
        v.layer?.borderColor = NSColor.windowBackgroundColor.cgColor
        v.isHidden = true
        return v
    }()

    /// Put a dot on Devices when PowerEmu Tools are missing or out of date, so
    /// the reader is told rather than having to go looking.
    func refreshToolsBadge() {
        guard let vm else { devicesBadge.isHidden = true; return }
        // Only point at Devices when opening it leads somewhere: without a
        // Tools disc the menu can explain the situation but not mend it.
        // PowerEmu Tools is a Mac OS X application; a classic guest is never
        // nagged about an install that cannot work there.
        let show = vm.state == .running && vm.toolsState.needsAttention
            && VirtualMachine.toolsDiscURL != nil && !vm.config.classic
        devicesBadge.isHidden = !show
        if show, devicesBadge.superview == nil {
            devicesButton.addSubview(devicesBadge)
        }
        if show {
            let b = devicesButton.bounds
            devicesBadge.frame = NSRect(x: b.midX + 5, y: b.maxY - 22, width: 9, height: 9)
        }
        switch vm.toolsState {
        case .updateAvailable(_, let shipped):
            devicesButton.toolTip = "PowerEmu Tools \(shipped) is available for this virtual Mac"
        case .notInstalled where vm.state == .running:
            devicesButton.toolTip = "PowerEmu Tools are not installed in this virtual Mac"
        default:
            devicesButton.toolTip = "Discs, this Mac's drives and USB devices"
        }
    }
    private var keys = NSMenu(), power = NSMenu(), filters = NSMenu()
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
        /*
         * Filters: how the guest's picture is drawn on this Mac, as opposed
         * to what the guest is drawing.  Scaling lives here rather than only
         * in the configurator because it is the kind of thing a reader wants
         * to flip while looking at the screen and judge by eye.
         */
        header(filters, "Scaling")
        for (value, title) in VMConfig.scalingChoices {
            let it = entry(title, #selector(setScaling(_:)))
            it.representedObject = value
            it.tag = Self.tagScaling
            filters.addItem(it)
        }
        filters.addItem(.separator())
        /*
         * Picture belongs next to scaling, and in the bar rather than only in
         * the configurator: the configurator locks while the machine runs,
         * which is exactly when a picture setting is worth changing, since it
         * is judged by eye against what is on the screen.
         */
        header(filters, "Picture")
        for (value, title) in VMConfig.displayFitChoices {
            let it = entry(title, #selector(setDisplayFit(_:)))
            it.representedObject = value
            it.tag = Self.tagFit
            filters.addItem(it)
        }
        filters.addItem(.separator())
        header(filters, "Display")
        for (value, title) in PanelFilters.choices {
            let it = entry(title, #selector(setPanelFilter(_:)))
            it.representedObject = value
            it.tag = Self.tagPanel
            filters.addItem(it)
        }
        filters.delegate = self
        /*
         * Statistics has its own menu, under its own button.  The style of
         * the overlay is a statistics setting, and putting it beside the
         * picture settings was simply the wrong place to look for it.
         */
        stats.addItem(entry("Show Statistics", #selector(togglePerf)))
        statsShowItem = stats.items.last
        stats.addItem(.separator())
        header(stats, "Style")
        for (value, title) in [("full", "Full readings"), ("light", "Frame rate and CPU only")] {
            let it = entry(title, #selector(setPerfStyle(_:)))
            it.representedObject = value
            it.tag = Self.tagPerfStyle
            stats.addItem(it)
        }
        stats.delegate = self
        build()
    }

    private let stats = NSMenu()
    private var statsShowItem: NSMenuItem?

    private static let tagScaling = 1, tagFit = 2, tagPanel = 4, tagPerfStyle = 5

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

        var items: [NSView] = [
            seg,
            separator(),
            menuButton("keyboard", "Keys", "Send keys this Mac would keep for itself", keys),
            menuButton("camera.filters", "Filters", "How the guest's picture is drawn on this Mac", filters),
            devicesButton,
            separator(),
            pauseItem(),
            labeledButton("moon.fill", "Sleep", "Save the virtual Mac as it is and close it", #selector(sleepMachine)),
            menuButton("power", "Power", "Shut down, restart or force off", power),
            OverlayBar.space(),
        ]
        /*
         * Harmony puts the guest's windows on this Mac's desktop by asking
         * the guest agent what windows it has.  The agent is a Mac OS X
         * application, so there is nothing to ask in a classic guest and the
         * button is left out rather than offered and doing nothing.
         */
        if vm?.config.classic != true {
            items.append(labeledButton("macwindow.on.rectangle", "Harmony",
                           "In testing: show the virtual Mac's windows on this Mac's desktop, without its wallpaper (Control-Option-H)",
                           #selector(toggleHarmony)))
        }
        items += [
            menuButton("speedometer", "Stats",
                       "What the virtual Mac and this Mac are doing, and how much of it to show (Control-Option-P)",
                       stats),
            labeledButton("arrow.up.left.and.arrow.down.right", "Full Screen", "Fill the screen (Control-Option-F)", #selector(fullScreen)),
        ]
        bar.setContent(items)
        bar.alphaValue = 0
        bar.isHidden = true
    }

    /// A button that says what it does: an ordinary toolbar item, rather
    /// than an icon the reader has to hover over to identify.
    private func labeledButton(_ symbol: String, _ title: String, _ tip: String,
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
        let b = labeledButton("pause.fill", "Pause",
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

    @MainActor @objc private func setScaling(_ sender: NSMenuItem) {
        guard let vm, let mode = sender.representedObject as? String else { return }
        vm.config.scaling = mode
        try? vm.save()
        display?.scaling = mode
    }

    @MainActor @objc private func setDisplayFit(_ sender: NSMenuItem) {
        guard let vm, let mode = sender.representedObject as? String else { return }
        vm.config.displayFit = mode
        try? vm.save()
        display?.displayFit = mode
    }

    @MainActor @objc private func setPerfStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let st = PerfHUD.Style(rawValue: raw) else { return }
        display?.perfStyle = st
    }

    @MainActor @objc private func setPanelFilter(_ sender: NSMenuItem) {
        guard let vm, let mode = sender.representedObject as? Int else { return }
        vm.config.panelFilter = mode
        try? vm.save()
        display?.panelFilter = mode
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
        if menu === filters {
            /*
             * Tick what the machine is set to.  Which group an item belongs to
             * is carried by its tag: matching on the type of representedObject
             * worked only while scaling was the one String in the menu, and
             * quietly stopped as soon as Picture added another.
             */
            let scale = vm?.config.scaling ?? "smooth"
            let fit = vm?.config.displayFit ?? "fit"
            let panel = vm?.config.panelFilter ?? 0
            for it in menu.items {
                switch it.tag {
                case Self.tagScaling:
                    it.state = (it.representedObject as? String) == scale ? .on : .off
                case Self.tagFit:
                    it.state = (it.representedObject as? String) == fit ? .on : .off
                case Self.tagPanel:
                    it.state = (it.representedObject as? Int) == panel ? .on : .off
                default: break
                }
            }
            return
        }
        if menu === stats {
            statsShowItem?.state = (display?.showsPerformance ?? false) ? .on : .off
            let style = (display?.perfStyle ?? .full).rawValue
            for it in menu.items where it.tag == Self.tagPerfStyle {
                it.state = (it.representedObject as? String) == style ? .on : .off
            }
            return
        }
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
            // Boot from this disc at the next start -- for installing Mac OS X.
            let bootIt = entry("Boot from this disc (for installing)", #selector(toggleBootDisc))
            bootIt.state = vm.config.bootFromDisc ? .on : .off
            menu.addItem(bootIt)
        } else {
            let none = NSMenuItem(title: "No disc", action: nil, keyEquivalent: "")
            none.isEnabled = false
            menu.addItem(none)
        }
        menu.addItem(entry("Insert Disc Image…", #selector(insertDisc)))
        menu.addItem(entry("New Blank Disc for Burning…", #selector(newBlankDisc)))
        let recent = vm.config.discs.filter { $0 != vm.config.insertedDisc }.prefix(8)
        for (i, path) in recent.enumerated() {
            let it = entry("Insert " + (path as NSString).lastPathComponent, #selector(insertRecent(_:)), i)
            it.representedObject = path
            it.indentationLevel = 1
            menu.addItem(it)
        }
        /*
         * Always say where the guest's tools stand.
         *
         * This section used to appear only when the app had a Tools disc to
         * offer, while the dot on this very button was put there by the state
         * of the guest's tools alone.  A build without the disc therefore said
         * "there is an update" and then gave the reader nothing to open --
         * which is worse than saying nothing, because the badge is the only
         * thing telling them to look here in the first place.
         */
        menu.addItem(NSMenuItem.separator())
        header(menu, "PowerEmu Tools")
        if VirtualMachine.toolsDiscURL == nil {
            let s = NSMenuItem(title: "The Tools disc is missing from this copy of PowerEmu",
                               action: nil, keyEquivalent: "")
            s.isEnabled = false
            menu.addItem(s)
        } else {
            switch vm.toolsState {
            case .notInstalled:
                let s = NSMenuItem(title: running ? "Not installed in this virtual Mac"
                                                  : "Start the virtual Mac to install them",
                                   action: nil, keyEquivalent: "")
                s.isEnabled = false
                menu.addItem(s)
                let it = entry("Install PowerEmu Tools…", #selector(openToolsAssistant))
                it.isEnabled = running
                menu.addItem(it)
            case .upToDate(let v):
                let s = NSMenuItem(title: "Version \(v) — up to date", action: nil, keyEquivalent: "")
                s.isEnabled = false
                menu.addItem(s)
                menu.addItem(entry("Reinstall PowerEmu Tools…", #selector(openToolsAssistant)))
            case .updateAvailable(let installed, let shipped):
                let s = NSMenuItem(title: "Version \(installed) installed — \(shipped) available",
                                   action: nil, keyEquivalent: "")
                s.isEnabled = false
                menu.addItem(s)
                let it = entry("Update PowerEmu Tools…", #selector(openToolsAssistant))
                it.image = NSImage(systemSymbolName: "arrow.down.circle.fill",
                                   accessibilityDescription: "Update available")
                menu.addItem(it)
            }
            menu.addItem(entry("Insert PowerEmu Tools Disc", #selector(insertTools)))
        }
        /*
         * Open a file from this Mac in the virtual Mac.
         *
         * The guest's own applications do the opening, so the list comes from
         * the guest and is empty until the tools connect -- which is also why
         * this sits under the same button as the tools themselves.
         */
        menu.addItem(.separator())
        header(menu, "Files")
        let openIt = entry("Open File in “\(vm.config.name)”…", #selector(openFileInGuest))
        openIt.isEnabled = running && vm.agent?.connected == true && !vm.config.isolated
        menu.addItem(openIt)
        let withIt = NSMenuItem(title: "Open File With", action: nil, keyEquivalent: "")
        let apps = vm.guestApps
        if apps.isEmpty {
            withIt.isEnabled = false
        } else {
            let sub = NSMenu()
            for (i, a) in apps.enumerated() {
                let it = NSMenuItem(title: a.name, action: #selector(openFileInGuestWith(_:)),
                                    keyEquivalent: "")
                it.target = self
                it.tag = i
                it.representedObject = a.path
                sub.addItem(it)
            }
            withIt.submenu = sub
            withIt.isEnabled = openIt.isEnabled
        }
        menu.addItem(withIt)

        let drives = HostDriveMonitor.shared.drives
        let discDrives = drives.filter { $0.kind != .hardDisk }
        if !discDrives.isEmpty {
            menu.addItem(.separator())
            header(menu, "This Mac's Drives")
            for (i, d) in discDrives.enumerated() {
                let it = entry("Use " + d.name, #selector(useDrive(_:)), i)
                it.representedObject = d.bsdName
                it.isEnabled = running
                menu.addItem(it)
            }
        }

        // External hard disks -- lent whole as a real IDE hard disk, to browse,
        // install Mac OS X onto, or boot from.  This attaches at launch, so it
        // is set in the config and applied on the next start.
        let hardDrives = drives.filter { $0.kind == .hardDisk }
        if !hardDrives.isEmpty || vm.config.externalDisk != nil {
            menu.addItem(.separator())
            header(menu, "External Disk (install / boot)")
            if let ext = vm.config.externalDisk {
                let cur = NSMenuItem(title: "Attached: \(ext.displayName)", action: nil, keyEquivalent: "")
                cur.isEnabled = false
                menu.addItem(cur)
                let boot = entry("Boot from this disk", #selector(toggleExternalBoot))
                boot.state = ext.bootFrom ? .on : .off
                menu.addItem(boot)
                menu.addItem(entry("Detach (give back to this Mac)", #selector(detachExternal)))
                if running {
                    let note = NSMenuItem(title: "Restart to apply changes", action: nil, keyEquivalent: "")
                    note.isEnabled = false
                    menu.addItem(note)
                }
            } else {
                for (i, d) in hardDrives.enumerated() {
                    let it = entry("Install / boot from " + d.name, #selector(attachExternal(_:)), i)
                    it.representedObject = d.bsdName
                    menu.addItem(it)
                }
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
        let remembered = Set(vm.config.autoConnectUSB)
        for d in usb {
            let auto = remembered.contains(d.id)
            let it = entry(auto ? d.name + " (automatic)" : d.name,
                           #selector(toggleUSB(_:)))
            it.representedObject = d
            it.state = vm.attachedUSB[d.id] != nil ? .on : .off
            it.isEnabled = true
            it.toolTip = String(format: "%04x:%04x — checked means the virtual Mac owns it; "
                                + "hold Option to connect it automatically at every start",
                                d.vendor, d.product)
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

    @objc private func newBlankDisc() {
        guard let vm else { return }
        let running = vm.state == .running
        vm.newBlankDisc()
        if running {
            let a = NSAlert()
            a.messageText = "Blank disc inserted"
            a.informativeText = "A blank disc is now in the virtual Mac's drive. "
                + "Burn to it from inside the guest -- drag files onto the disc "
                + "and choose Burn, or use Disk Utility. If a blank CD or DVD is "
                + "in a real drive on this Mac, the disc burns there too."
            a.addButton(withTitle: "OK")
            a.runModal()
        }
        refocus()
    }

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

    @objc private func openToolsAssistant() {
        guard let vm else { return }
        ToolsAssistant.present(for: vm)
    }

    @objc private func insertTools() { vm?.insertToolsDisc(); refocus() }

    @objc private func useDrive(_ item: NSMenuItem) {
        if let bsd = item.representedObject as? String,
           let d = HostDriveMonitor.shared.drives.first(where: { $0.bsdName == bsd }) {
            vm?.insertHostDrive(d)
        }
        refocus()
    }

    @objc private func openFileInGuest() { pickAndOpenInGuest(nil) }

    @objc private func openFileInGuestWith(_ item: NSMenuItem) {
        pickAndOpenInGuest(item.representedObject as? String)
    }

    private func pickAndOpenInGuest(_ app: String?) {
        guard let vm else { return }
        let p = NSOpenPanel()
        p.canChooseFiles = true
        p.canChooseDirectories = false
        p.allowsMultipleSelection = true
        p.prompt = "Open"
        p.message = app == nil
            ? "This file is opened in “\(vm.config.name)” by whichever of its applications claims it."
            : "This file is opened in “\(vm.config.name)”."
        guard p.runModal() == .OK else { refocus(); return }
        for url in p.urls { vm.openInGuest(url, with: app) }
        refocus()
    }

    @objc private func toggleUSB(_ item: NSMenuItem) {
        if let d = item.representedObject as? HostUSBDevice {
            // Option-click sets whether this machine takes the device by
            // itself in future, rather than connecting it now.
            if NSEvent.modifierFlags.contains(.option) {
                let on = !(vm?.config.autoConnectUSB.contains(d.id) ?? false)
                vm?.setAutoConnectUSB(d, on)
            } else if vm?.state == .running {
                vm?.toggleUSB(d)
            }
        }
        refocus()
    }

    @objc private func attachExternal(_ item: NSMenuItem) {
        guard let vm, let bsd = item.representedObject as? String,
              let d = HostDriveMonitor.shared.drives.first(where: { $0.bsdName == bsd }) else { return }
        let running = vm.state == .running
        let a = NSAlert()
        a.messageText = "Attach “\(d.name)” to “\(vm.config.name)”?"
        a.informativeText = "This disk will be unmounted from this Mac and given to the "
            + "virtual Mac as a real hard disk, so you can install Mac OS X on it or boot "
            + "from it. It appears when the virtual Mac starts. Installing Mac OS X onto it "
            + "will erase everything on the disk.\n\nYou will be asked for an administrator "
            + "password so the virtual Mac can write to it."
        a.addButton(withTitle: running ? "Attach and Restart" : "Attach")
        a.addButton(withTitle: "Cancel")
        guard a.runModal() == .alertFirstButtonReturn else { refocus(); return }
        vm.attachExternalDisk(d)
        if running { vm.restartForConfigChange() }
        refocus()
    }

    @objc private func detachExternal() {
        guard let vm else { return }
        vm.detachExternalDisk()
        if vm.state == .running { vm.restartForConfigChange() }
        refocus()
    }

    @objc private func toggleExternalBoot() {
        guard let vm, let ext = vm.config.externalDisk else { return }
        vm.setExternalDiskBoot(!ext.bootFrom)
        if vm.state == .running { vm.restartForConfigChange() }
        refocus()
    }

    @objc private func toggleBootDisc() {
        guard let vm else { return }
        vm.setBootFromDisc(!vm.config.bootFromDisc)
        if vm.state == .running { vm.restartForConfigChange() }
        refocus()
    }

    // MARK: the rest

    /*
     * Harmony is in testing, and the first time it is switched on says so
     * -- once, and never again on this Mac.  It is worth a warning rather
     * than a footnote: every frame costs more work, and what is drawn is
     * worked out by watching the guest rather than being told, so it can be
     * wrong in ways an ordinary setting cannot.
     */
    @objc private func toggleHarmony() {
        guard let display else { return }
        if !display.harmony && !UserDefaults.standard.bool(forKey: "PEHarmonyWarned") {
            let a = NSAlert()
            a.messageText = "Harmony is still being tested"
            a.informativeText = """
                The virtual Mac's windows are shown on this Mac's desktop and \
                its wallpaper is left out. Two things to expect.

                It is slower. Every frame is worked over again to decide which \
                parts are windows, and on a large screen that is real work \
                \u{2014} more so while something is moving.

                It can be wrong. Which parts are windows is worked out by \
                watching what the virtual Mac draws, not by being told, so a \
                window may take a moment to appear and a patch of its desktop \
                may linger. Turning harmony off puts everything back.

                A click on one of the virtual Mac's windows goes to it; a click \
                where you can see through to this Mac's desktop goes to this Mac.
                """
            a.addButton(withTitle: "Turn On Harmony")
            a.addButton(withTitle: "Cancel")
            a.showsSuppressionButton = true
            a.suppressionButton?.title = "Don\u{2019}t show this again"
            let r = a.runModal()
            if a.suppressionButton?.state == .on {
                UserDefaults.standard.set(true, forKey: "PEHarmonyWarned")
            }
            guard r == .alertFirstButtonReturn else { refocus(); return }
        }
        display.requestHarmony(!display.harmony)
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
