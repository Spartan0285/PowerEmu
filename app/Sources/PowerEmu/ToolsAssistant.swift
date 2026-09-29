import AppKit

/// Installing PowerEmu Tools takes a few steps inside the virtual Mac, and the
/// reader cannot see how far along they are from out here.  This walks through
/// it: put the disc in, run the installer in there, and watch for the tools to
/// say hello -- at which point the window says so itself rather than leaving
/// anyone guessing.
@MainActor
final class ToolsAssistant: NSWindowController {
    private static var open: ToolsAssistant?

    private weak var vm: VirtualMachine?
    private let icon = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let bodyLabel = NSTextField(wrappingLabelWithString: "")
    private let stepLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let actionButton = NSButton(title: "", target: nil, action: nil)
    private let closeButton = NSButton(title: "Close", target: nil, action: nil)
    private var timer: Timer?
    /// The version the guest had when this opened, so an update can be told
    /// from a reinstall.
    private let versionAtStart: String?

    static func present(for vm: VirtualMachine) {
        if let w = open { w.vm = vm; w.showWindow(nil); w.window?.makeKeyAndOrderFront(nil); w.refresh(); return }
        let c = ToolsAssistant(vm: vm)
        open = c
        c.showWindow(nil)
        c.window?.center()
        c.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private init(vm: VirtualMachine) {
        self.vm = vm
        self.versionAtStart = vm.agent?.info?.version
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 260),
                         styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "PowerEmu Tools"
        super.init(window: w)
        build()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }
    required init?(coder: NSCoder) { fatalError() }

    private func build() {
        guard let content = window?.contentView else { return }
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        titleLabel.font = .boldSystemFont(ofSize: 15)
        bodyLabel.textColor = .secondaryLabelColor
        stepLabel.font = .systemFont(ofSize: 12)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        actionButton.target = self
        actionButton.action = #selector(act)
        actionButton.keyEquivalent = "\r"
        closeButton.target = self
        closeButton.action = #selector(dismiss)

        for v in [icon, titleLabel, bodyLabel, stepLabel, spinner, actionButton, closeButton] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            content.addSubview(v)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: content.topAnchor, constant: 20),
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64),

            titleLabel.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 16),
            titleLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            titleLabel.topAnchor.constraint(equalTo: content.topAnchor, constant: 22),

            bodyLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            bodyLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            bodyLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 8),

            spinner.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            spinner.centerYAnchor.constraint(equalTo: stepLabel.centerYAnchor),
            spinner.widthAnchor.constraint(equalToConstant: 16),

            stepLabel.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: 8),
            stepLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            stepLabel.topAnchor.constraint(equalTo: bodyLabel.bottomAnchor, constant: 18),

            closeButton.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -18),
            actionButton.trailingAnchor.constraint(equalTo: closeButton.leadingAnchor, constant: -10),
            actionButton.bottomAnchor.constraint(equalTo: closeButton.bottomAnchor),
        ])
    }

    /// Redraw for wherever the install has got to.
    private func refresh() {
        guard let vm else { return }
        let discIn = vm.hostDiscName == nil && (vm.config.insertedDisc.map { $0.contains("PowerEmu Tools") } ?? false)
        switch vm.toolsState {
        case .notInstalled:
            titleLabel.stringValue = "Install PowerEmu Tools"
            bodyLabel.stringValue = "PowerEmu Tools let this Mac and the virtual Mac share a clipboard and folders, "
                                  + "keep the clock right, and arrange the virtual Mac's windows on this desktop."
            actionButton.title = discIn ? "Disc Inserted" : "Insert Tools Disc"
            actionButton.isEnabled = !discIn
            stepLabel.stringValue = discIn
                ? "In the virtual Mac, open the PowerEmu Tools disc and open Install PowerEmu Tools.pkg. "
                + "It will ask for an administrator's password — that is what lets PowerEmu move and "
                + "raise the virtual Mac's windows."
                : "Put the Tools disc into the virtual Mac's drive to begin."
            spinner.startAnimation(nil)
        case .upToDate(let v):
            titleLabel.stringValue = "PowerEmu Tools \(v) are installed"
            bodyLabel.stringValue = versionAtStart != nil && versionAtStart != v
                ? "The virtual Mac has been updated and is talking to PowerEmu again."
                : "Everything is up to date. You can reinstall them if something is not working."
            actionButton.title = "Reinstall…"
            actionButton.isEnabled = true
            stepLabel.stringValue = ""
            spinner.stopAnimation(nil)
        case .updateAvailable(let installed, let shipped):
            titleLabel.stringValue = "Update PowerEmu Tools"
            bodyLabel.stringValue = "This virtual Mac has version \(installed). This copy of PowerEmu carries \(shipped)."
            actionButton.title = discIn ? "Disc Inserted" : "Insert Tools Disc"
            actionButton.isEnabled = !discIn
            stepLabel.stringValue = discIn
                ? "In the virtual Mac, open the PowerEmu Tools disc and open Install PowerEmu Tools.pkg."
                : "Put the Tools disc into the virtual Mac's drive to begin."
            spinner.startAnimation(nil)
        }
    }

    @objc private func act() {
        vm?.insertToolsDisc()
        refresh()
    }

    @objc private func dismiss() {
        timer?.invalidate(); timer = nil
        Self.open = nil
        close()
    }
}
