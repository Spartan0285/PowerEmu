import AppKit

/// One item read out of a guest application's menu.
struct HarmonyMenuItem {
    /// Where it sits, as indices from the guest's menu bar: "3.5.1".
    let path: String
    let title: String
    let enabled: Bool
    /// The key it answers to, if it has one, and which modifiers go with it.
    let key: String
    /// The guest's bits: 1 shift, 2 option, 4 control, 8 *no* command.
    let modifiers: Int
    /// A tick or a dash beside it, if it is showing one.
    let mark: String
    let hasSubmenu: Bool

    var isSeparator: Bool { title.isEmpty }
}

/*
 * Harmony: the front guest application's menus, in this Mac's menu bar.
 *
 * In Harmony the guest's own menu bar is never drawn -- a window that looks
 * like it belongs here should have its menus here too -- so the front guest
 * application's are read out over the agent and rebuilt as a real menu bar.
 * Picking one sends its path back and the guest presses the same item.
 *
 * What is inside each menu is fetched a menu at a time, and only once the
 * menu has been opened.  Reading one costs a round trip into the other
 * application for every item in it; reading every menu of every application
 * as it comes to the front would be felt in the guest.  The first open
 * therefore shows a menu that fills itself in a moment later, which is why
 * an open menu is updated in place rather than only built up front.
 */
@MainActor
final class HarmonyMenuBar: NSObject, NSMenuDelegate {
    /// Sends a verb to the guest agent.
    var send: ((String, String) -> Void)?

    private(set) var pid = 0
    private var appName = ""
    private var tops: [(index: Int, title: String)] = []
    private var menus: [String: NSMenu] = [:]      // path -> the menu under it
    private var filled = Set<String>()             // paths already read from the guest
    private var requested = Set<String>()
    private var savedMainMenu: NSMenu?
    private var installed: NSMenu?
    private(set) var active = false
    private var guestWindowFocused = false
    func setGuestWindowFocused(_ focused: Bool) {
        guestWindowFocused = focused
        if focused, !tops.isEmpty {
            if let installed { NSApp.mainMenu = installed; active = true }
            else { install() }
        } else if !focused, let saved = savedMainMenu {
            NSApp.mainMenu = saved; active = false
        }
    }

    // MARK: what the guest tells us

    /// The front guest application changed, or its menu bar did.
    func setMenuBar(pid: Int, app: String, tops: [(index: Int, title: String)]) {
        guard pid != 0, !tops.isEmpty else { return }
        // Same application, same menus: leave what is built alone, or every
        // report would throw away menus already read.
        if pid == self.pid, tops.map({ $0.title }) == self.tops.map({ $0.title }),
           tops.map({ $0.index }) == self.tops.map({ $0.index }) { return }
        self.pid = pid
        self.appName = app
        self.tops = tops
        menus.removeAll(); filled.removeAll(); requested.removeAll()
        install()
    }

    /// The contents of one menu came back.
    func setItems(pid: Int, path: String, items: [HarmonyMenuItem]) {
        guard pid == self.pid, let menu = menus[path] else { return }
        filled.insert(path)
        fill(menu, path: path, from: items)
    }

    // MARK: building

    private func install() {
        installed = nil
        guard guestWindowFocused else { return }
        guard let main = NSApp.mainMenu else { return }
        if savedMainMenu == nil { savedMainMenu = main }
        let bar = NSMenu()
        bar.addItem(appMenuItem())
        for t in tops {
            let path = "\(t.index)"
            let item = NSMenuItem(title: t.title, action: nil, keyEquivalent: "")
            let menu = NSMenu(title: t.title)
            menu.delegate = self
            menu.autoenablesItems = false
            // Something has to be in it or the title is drawn grayed out and
            // will not open at all.
            menu.addItem(placeholder())
            menus[path] = menu
            item.submenu = menu
            bar.addItem(item)
        }
        installed = bar
        NSApp.mainMenu = bar
        active = true
        prefetch()
    }

    /*
     * Read the menus before anybody opens one.  Waiting for the first click
     * would show an empty menu that fills itself a moment later, which looks
     * broken; by the time somebody gets to the menu bar these have arrived.
     * They go one at a time so the guest is not asked for its whole menu bar
     * at once -- each one is a round of calls into the other application.
     */
    private func prefetch() {
        let pid = self.pid
        for (n, t) in tops.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15 * Double(n)) { [weak self] in
                guard let self, self.pid == pid else { return }   // moved on since
                let path = "\(t.index)"
                guard !self.filled.contains(path) else { return }
                self.send?("MENUITEMS", "\(pid) \(path)")
            }
        }
    }

    /// This Mac's own menu, kept so there is always a way out of Harmony.
    private func appMenuItem() -> NSMenuItem {
        let item = NSMenuItem(title: "PowerEmu", action: nil, keyEquivalent: "")
        let menu = NSMenu(title: "PowerEmu")
        let exit = NSMenuItem(title: "Exit Harmony", action: Selector(("exitHarmony:")), keyEquivalent: "")
        exit.target = nil                     // down the responder chain
        menu.addItem(exit)
        menu.addItem(.separator())
        /*
         * No key for Quit: the guest application almost certainly has one on
         * Command-Q, and a menu bar answers the first match it finds -- which
         * would quit PowerEmu out from under the guest.
         */
        menu.addItem(NSMenuItem(title: "Quit PowerEmu", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: ""))
        item.submenu = menu
        return item
    }

    private func placeholder() -> NSMenuItem {
        let i = NSMenuItem(title: "Loading…", action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    private func fill(_ menu: NSMenu, path: String, from items: [HarmonyMenuItem]) {
        menu.removeAllItems()
        let prefix = path + "."
        for it in items {
            // Only this menu's own items: the rest belong to the submenus,
            // which are built as their parents are reached.
            let rest = it.path.hasPrefix(prefix) ? String(it.path.dropFirst(prefix.count)) : ""
            guard !rest.isEmpty, !rest.contains(".") else { continue }
            if it.isSeparator { menu.addItem(.separator()); continue }
            let m = NSMenuItem(title: it.title, action: #selector(pick(_:)), keyEquivalent: "")
            m.target = self
            m.representedObject = it.path
            m.isEnabled = it.enabled
            if !it.key.isEmpty {
                m.keyEquivalent = it.key.lowercased()
                var flags: NSEvent.ModifierFlags = []
                if it.modifiers & 8 == 0 { flags.insert(.command) }
                if it.modifiers & 1 != 0 { flags.insert(.shift) }
                if it.modifiers & 2 != 0 { flags.insert(.option) }
                if it.modifiers & 4 != 0 { flags.insert(.control) }
                m.keyEquivalentModifierMask = flags
            }
            /*
             * A tick or a dash beside it in the guest.  Anything else -- and
             * Tiger hands back a space for an item with no mark at all -- is
             * no mark, not a dash: treating "not empty" as marked put a dash
             * against every item in every menu.
             */
            switch it.mark.trimmingCharacters(in: .whitespacesAndNewlines) {
            case "✓", "✔", "√": m.state = .on
            case "-", "–", "—": m.state = .mixed
            default: m.state = .off
            }
            if it.hasSubmenu {
                let sub = NSMenu(title: it.title)
                sub.delegate = self
                sub.autoenablesItems = false
                menus[it.path] = sub
                // The whole tree under a top-level menu arrives at once, so
                // these can be filled straight away.
                fill(sub, path: it.path, from: items)
                if sub.numberOfItems == 0 { sub.addItem(placeholder()) }
                filled.insert(it.path)
                m.action = nil                // opening it is what it is for
                m.target = nil
                m.submenu = sub
            }
            menu.addItem(m)
        }
        if menu.numberOfItems == 0 { menu.addItem(placeholder()) }
    }

    // MARK: working them

    func menuWillOpen(_ menu: NSMenu) {
        guard let path = menus.first(where: { $0.value === menu })?.key else { return }
        // Top-level menus carry everything under them, so a submenu that is
        // already built needs nothing; only ask again if it never arrived.
        guard !filled.contains(path) else { return }
        guard !path.contains(".") else { return }
        requested.insert(path)
        send?("MENUITEMS", "\(pid) \(path)")
    }

    @objc private func pick(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String else { return }
        send?("MENUPICK", "\(pid) \(path)")
        // What it did may have changed ticks or what is grayed out.
        if let top = path.split(separator: ".").first {
            let t = String(top)
            filled.remove(t)
            let pid = self.pid
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                guard let self, self.pid == pid, !self.filled.contains(t) else { return }
                self.send?("MENUITEMS", "\(pid) \(t)")
            }
        }
    }

    // MARK: leaving

    func remove() {
        pid = 0; tops = []; menus.removeAll(); filled.removeAll(); requested.removeAll()
        active = false; guestWindowFocused = false
        if let saved = savedMainMenu {
            NSApp.mainMenu = saved
            savedMainMenu = nil
        }
        installed = nil
    }

    // MARK: driving it without a mouse, for testing

    /// Ask for a menu's contents as though it had just been opened.
    func openForTest(_ path: String) {
        guard let menu = menus[path] else { harmonyDebug("PEMENU no menu at \(path)"); return }
        filled.remove(path)
        menuWillOpen(menu)
    }

    /// Everything in one built menu, as it would be drawn.
    func dump(_ path: String) -> String {
        guard let menu = menus[path] else { return "no menu at \(path)" }
        return menu.items.map { i -> String in
            if i.isSeparatorItem { return "----" }
            var s = i.title
            if !i.keyEquivalent.isEmpty { s += " [\(i.keyEquivalentModifierMask.rawValue):\(i.keyEquivalent)]" }
            if !i.isEnabled { s += " (off)" }
            if i.state == .on { s += " ✓" }
            if i.state == .mixed { s += " –" }
            if i.hasSubmenu { s += " >" }
            return s
        }.joined(separator: " | ")
    }

    /// Pick an item by its guest path, as though it had been clicked.
    func pickForTest(_ path: String) {
        harmonyDebug("PEMENUPICK \(pid) \(path)")
        send?("MENUPICK", "\(pid) \(path)")
    }

    var report: String {
        "PEMENUBAR pid=\(pid) app=\(appName) tops=\(tops.map { $0.title }.joined(separator: ",")) "
        + "built=\(menus.count) filled=\(filled.count) active=\(active)"
    }
}
