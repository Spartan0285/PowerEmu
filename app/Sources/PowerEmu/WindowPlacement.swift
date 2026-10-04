import AppKit

/*
 * Where a machine's windows were, per screen arrangement.
 *
 * A machine can show its screens three ways -- Harmony, full screen, or
 * plain windows -- and moving between them destroys the arrangement the
 * reader made.  AppKit's own frame autosave remembers one frame per window
 * and nothing about which screen it was on, so a window saved while a second
 * monitor was attached comes back off-screen, or stacked on the first
 * screen, once that monitor is gone.
 *
 * This records a frame per (machine, role) *and per screen arrangement*, so a
 * layout is only ever restored onto the monitors it was made on.  Plug the
 * second monitor back in and the two-monitor layout returns; unplug it and
 * the one-monitor layout does.
 */
@MainActor
enum WindowPlacement {
    /// Which of a machine's windows a frame belongs to.
    enum Role: String {
        case main = "main"
        case second = "screen2"
    }

    /*
     * A name for the current set of screens.
     *
     * Screen *frames*, not count: two monitors arranged side by side and the
     * same two stacked are different arrangements, and a layout made for one
     * puts windows in the wrong place on the other.  Sorted, because
     * NSScreen.screens is in no guaranteed order.
     */
    static func arrangement() -> String {
        NSScreen.screens
            .map { s in
                let f = s.frame
                return "\(Int(f.minX)),\(Int(f.minY)),\(Int(f.width)),\(Int(f.height))"
            }
            .sorted()
            .joined(separator: ";")
    }

    private static func key(_ vm: VirtualMachine, _ role: Role) -> String {
        "PowerEmu.placement.\(vm.url.lastPathComponent).\(role.rawValue).\(arrangement())"
    }

    /*
     * Remember a window's frame.
     *
     * A full-screen window is skipped: its frame is the whole screen, and
     * saving that would overwrite the windowed layout the reader wants back
     * when they leave full screen.
     */
    static func save(_ window: NSWindow, for vm: VirtualMachine, role: Role) {
        guard !window.styleMask.contains(.fullScreen) else { return }
        let f = window.frame
        UserDefaults.standard.set(
            ["x": f.minX, "y": f.minY, "w": f.width, "h": f.height],
            forKey: key(vm, role))
    }

    /*
     * Put a window back, if this arrangement has a remembered frame and that
     * frame is still usable.  Returns whether it was restored, so a caller
     * can fall back to its own placement.
     */
    @discardableResult
    static func restore(_ window: NSWindow, for vm: VirtualMachine, role: Role) -> Bool {
        guard let d = UserDefaults.standard.dictionary(forKey: key(vm, role)) as? [String: CGFloat],
              let x = d["x"], let y = d["y"], let w = d["w"], let h = d["h"],
              w > 100, h > 100 else { return false }
        let frame = CGRect(x: x, y: y, width: w, height: h)
        /*
         * Only restore somewhere the reader can still reach it.  Screens can
         * have changed since, in ways the arrangement key does not catch --
         * a resolution change under the same frame, for instance.
         */
        guard NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }) else {
            return false
        }
        window.setFrame(frame, display: true)
        return true
    }

    /// Record both of a machine's windows, before a mode change moves them.
    static func saveAll(for vm: VirtualMachine) {
        if let w = VMWindowController.open[vm.url]?.window { save(w, for: vm, role: .main) }
        if let w = SecondScreenController.open[vm.url]?.window { save(w, for: vm, role: .second) }
    }

    /// Put both of a machine's windows back where this arrangement had them.
    static func restoreAll(for vm: VirtualMachine) {
        if let w = VMWindowController.open[vm.url]?.window { restore(w, for: vm, role: .main) }
        if let w = SecondScreenController.open[vm.url]?.window { restore(w, for: vm, role: .second) }
    }
}
