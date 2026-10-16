import AppKit

/// Searchable guest application shortcuts for one virtual Mac.
@MainActor
final class GuestAppsPanel: NSPanel, NSSearchFieldDelegate {
    private final class AppListDocument: NSView {
        override var isFlipped: Bool { true }
    }
    typealias Item = (path: String, name: String, installed: Bool)
    private let search = NSSearchField()
    private let scroll = NSScrollView()
    private let stack = NSStackView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private var apps: [Item] = []
    private var open: ((Item) -> Void)?
    private var reveal: ((Item) -> Void)?

    init(title name: String) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 560),
                   styleMask: [.titled, .closable, .utilityWindow],
                   backing: .buffered, defer: false)
        title = "\(name) Applications"
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isReleasedWhenClosed = false

        let heading = NSTextField(wrappingLabelWithString: "Open a guest app, then use Keep in Dock on its icon to pin it like a Mac app.")
        heading.font = .systemFont(ofSize: 12)
        heading.textColor = .secondaryLabelColor
        search.placeholderString = "Search installed apps"
        search.delegate = self
        search.sendsSearchStringImmediately = true
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        let document = AppListDocument()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(stack)
        scroll.documentView = document
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        status.font = .systemFont(ofSize: 12)
        status.textColor = .secondaryLabelColor
        let content = NSView()
        for view in [heading, search, scroll, status] {
            view.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(view)
        }
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: document.topAnchor),
            stack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            heading.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
            heading.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
            heading.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
            search.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 12),
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            search.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.topAnchor.constraint(equalTo: search.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: status.topAnchor, constant: -8),
            status.leadingAnchor.constraint(equalTo: heading.leadingAnchor),
            status.trailingAnchor.constraint(equalTo: heading.trailingAnchor),
            status.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            status.heightAnchor.constraint(greaterThanOrEqualToConstant: 18),
        ])
        contentView = content
    }

    func present(apps: [Item], status message: String,
                 open: @escaping (Item) -> Void, reveal: @escaping (Item) -> Void) {
        self.open = open; self.reveal = reveal
        self.apps = Self.unique(apps)
        status.stringValue = message
        render()
        if !isVisible, let screen = NSScreen.main {
            let frame = screen.visibleFrame
            setFrameOrigin(NSPoint(x: frame.midX - frame.width / 2, y: frame.midY - frame.height / 2))
        }
        makeKeyAndOrderFront(nil)
    }

    func update(apps: [Item], status message: String) {
        self.apps = Self.unique(apps)
        status.stringValue = message
        render()
    }

    func controlTextDidChange(_ obj: Notification) { render() }

    private func render() {
        stack.arrangedSubviews.forEach { view in
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        let query = search.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = apps.filter { query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.path.localizedCaseInsensitiveContains(query) }
        if visible.isEmpty {
            let empty = NSTextField(labelWithString: apps.isEmpty ? "No installed-app list is available yet." : "No apps match this search.")
            empty.textColor = .secondaryLabelColor
            stack.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            return
        }
        for (index, app) in visible.enumerated() {
            let row = NSStackView()
            row.orientation = .horizontal
            row.alignment = .centerY
            row.spacing = 8
            let label = NSTextField(labelWithString: app.name)
            label.toolTip = app.path
            let context = NSMenu()
            let show = NSMenuItem(title: "Show Shortcut in Finder", action: #selector(revealShortcut(_:)), keyEquivalent: "")
            show.target = self; show.representedObject = app.path
            context.addItem(show)
            label.menu = context
            let launch = NSButton(title: "Open", target: self, action: #selector(openApp(_:)))
            launch.bezelStyle = .rounded
            launch.isEnabled = app.installed
            launch.toolTip = app.installed ? nil : "Reconnect PowerEmu Tools to verify this saved shortcut."
            launch.tag = index
            launch.identifier = NSUserInterfaceItemIdentifier(app.path)
            row.addArrangedSubview(label)
            row.addArrangedSubview(NSView())
            row.addArrangedSubview(launch)
            stack.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -12).isActive = true
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 250).isActive = true
        }
    }

    @objc private func openApp(_ sender: NSButton) {
        guard let path = sender.identifier?.rawValue,
              let item = apps.first(where: { $0.path == path }) else { return }
        open?(item)
    }

    @objc private func revealShortcut(_ sender: NSMenuItem) {
        guard let path = sender.representedObject as? String,
              let item = apps.first(where: { $0.path == path }) else { return }
        reveal?(item)
    }

    private static func unique(_ apps: [Item]) -> [Item] {
        var byPath: [String: Item] = [:]
        for app in apps where GuestAppShortcutSelection.validApplicationPath(app.path) {
            byPath[app.path] = app
        }
        return byPath.values.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
}
