import AppKit

/*
 * The virtual Mac's applications, in a window of this Mac's own.
 *
 * They can already be reached from PowerEmu's Dock menu, but only while
 * Harmony is on and only by holding the Dock icon down: a list that is hard to
 * find and gone the moment the pointer leaves it.  This is the same list as a
 * panel -- it floats above everything, including a guest running fullscreen,
 * and a click brings that application forward inside the guest.
 *
 * It owns nothing.  The applications come from the machine, every click is
 * handed straight back to it, and the panel closes with the machine it belongs
 * to.
 */
@MainActor
final class GuestAppsPanel: NSPanel {
    private let stack = NSStackView()
    typealias Item = (path: String, name: String, pid: Int)
    private var open: ((Item) -> Void)?
    private var apps: [Item] = []

    init(title name: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 260, height: 120),
                   styleMask: [.titled, .closable, .utilityWindow, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        self.title = name
        isFloatingPanel = true
        // Above a guest running fullscreen, which an ordinary floating window
        // would sit behind.
        level = .modalPanel
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 2
        stack.edgeInsets = NSEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor),
        ])
        contentView = content
    }

    /// Show the panel for a machine, with the list it has now.
    func present(apps: [Item], open: @escaping (Item) -> Void) {
        self.open = open
        update(apps: apps)
        if !isVisible, let screen = NSScreen.main {
            // Near the Dock end of the screen, where the icon that opens it is.
            let f = screen.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 80))
        }
        orderFrontRegardless()
    }

    /// Keep the list current while the panel is open; the guest's applications
    /// come and go without anybody clicking anything.
    func update(apps: [Item]) {
        guard apps.map(\.pid) != self.apps.map(\.pid)
                || apps.map(\.path) != self.apps.map(\.path) else { return }
        self.apps = apps
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        if apps.isEmpty {
            let empty = NSTextField(labelWithString: "This virtual Mac's Dock is empty, or its PowerEmu Tools are older than 2.21")
            empty.textColor = .secondaryLabelColor
            empty.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(empty)
        }
        for (i, a) in apps.enumerated() {
            // Running applications are marked, the way the Dock marks them, so
            // a click is understood as bringing one forward rather than
            // opening a second copy.
            let b = NSButton(title: a.pid > 0 ? "\u{25CF} " + a.name : "   " + a.name,
                             target: self, action: #selector(pick(_:)))
            b.tag = i
            b.bezelStyle = .inline
            b.isBordered = false
            b.contentTintColor = .labelColor
            b.alignment = .left
            b.font = .systemFont(ofSize: 13)
            stack.addArrangedSubview(b)
            b.widthAnchor.constraint(equalTo: stack.widthAnchor,
                                     constant: -24).isActive = true
        }
        let rows = max(1, apps.count)
        setContentSize(NSSize(width: 260, height: CGFloat(rows) * 22 + 20))
    }

    @objc private func pick(_ sender: NSButton) {
        guard sender.tag >= 0, sender.tag < apps.count else { return }
        open?(apps[sender.tag])
    }
}
