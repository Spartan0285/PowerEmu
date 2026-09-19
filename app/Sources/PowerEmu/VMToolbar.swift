import AppKit
import UniformTypeIdentifiers

/// The virtual Mac window's toolbar, as in Parallels: mouse mode, keys the
/// host would otherwise take, devices (discs, this Mac's drives and USB),
/// performance, power and full screen.  In full screen it hides with the
/// menu bar and drops down when the pointer reaches the top of the screen.
@MainActor
final class VMToolbarController: NSObject, NSToolbarDelegate, NSMenuDelegate {
    private weak var controller: VMWindowController?
    private var mouseControl: NSSegmentedControl?
    private let devicesMenu = NSMenu(title: "Devices")

    private enum ID {
        static let mouse = NSToolbarItem.Identifier("pe.mouse")
        static let keys = NSToolbarItem.Identifier("pe.keys")
        static let devices = NSToolbarItem.Identifier("pe.devices")
        static let perf = NSToolbarItem.Identifier("pe.perf")
        static let power = NSToolbarItem.Identifier("pe.power")
        static let fullScreen = NSToolbarItem.Identifier("pe.fullscreen")
    }

    init(_ c: VMWindowController) {
        controller = c
        super.init()
        devicesMenu.delegate = self
        let tb = NSToolbar(identifier: "PowerEmuVM")
        tb.delegate = self
        tb.displayMode = .iconOnly
        tb.allowsUserCustomization = false
        c.window?.toolbar = tb
        c.window?.toolbarStyle = .unified
    }

    private var vm: VirtualMachine? { controller?.vm }
    private var display: VMDisplayView? { controller?.display }

    /// Toolbar clicks shouldn't leave the keyboard away from the guest.
    private func refocus() {
        if let d = display { controller?.window?.makeFirstResponder(d) }
    }

    // MARK: NSToolbarDelegate

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [ID.mouse, ID.keys, ID.devices, .flexibleSpace, ID.perf, ID.power, ID.fullScreen]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar)
    }

    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier,
                 willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        switch id {
        case ID.mouse:
            let seg = NSSegmentedControl(labels: ["Seamless", "Captured"], trackingMode: .selectOne,
                                         target: self, action: #selector(mouseChanged(_:)))
            seg.setImage(NSImage(systemSymbolName: "cursorarrow", accessibilityDescription: nil), forSegment: 0)
            seg.setImage(NSImage(systemSymbolName: "scope", accessibilityDescription: nil), forSegment: 1)
            seg.setToolTip("The pointer moves in and out of the virtual Mac freely", forSegment: 0)
            seg.setToolTip("A click captures the mouse (for games); Control-Option-G releases it", forSegment: 1)
            seg.selectedSegment = display?.mouseMode == .captured ? 1 : 0
            seg.refusesFirstResponder = true
            mouseControl = seg
            let item = NSToolbarItem(itemIdentifier: id)
            item.view = seg
            item.label = "Mouse"
            return item

        case ID.keys:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "keyboard", accessibilityDescription: "Keys")
            item.label = "Keys"
            item.toolTip = "Send keys this Mac would keep for itself"
            item.menu = keysMenu()
            item.showsIndicator = true
            return item

        case ID.devices:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "externaldrive.connected.to.line.below", accessibilityDescription: "Devices")
            item.label = "Devices"
            item.toolTip = "Discs, this Mac's drives and USB devices"
            item.menu = devicesMenu
            item.showsIndicator = true
            return item

        case ID.perf:
            return button(id, "speedometer", "Performance", "Show frame rate, VRAM and texture use (Control-Option-P)",
                          #selector(togglePerf))

        case ID.power:
            let item = NSMenuToolbarItem(itemIdentifier: id)
            item.image = NSImage(systemSymbolName: "power", accessibilityDescription: "Power")
            item.label = "Power"
            let m = NSMenu()
            m.addItem(entry("Shut Down", #selector(shutDown)))
            m.addItem(entry("Restart", #selector(restart)))
            m.addItem(.separator())
            m.addItem(entry("Force Power Off…", #selector(forceOff)))
            item.menu = m
            item.showsIndicator = true
            return item

        case ID.fullScreen:
            return button(id, "arrow.up.left.and.arrow.down.right", "Full Screen", "Full screen (Control-Option-F)",
                          #selector(fullScreen))

        default:
            return nil
        }
    }

    private func button(_ id: NSToolbarItem.Identifier, _ symbol: String, _ label: String, _ tip: String,
                        _ action: Selector) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: id)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.toolTip = tip
        item.target = self
        item.action = action
        return item
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
