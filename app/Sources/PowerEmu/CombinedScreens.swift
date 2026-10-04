import AppKit

/*
 * Both of the virtual Mac's screens, side by side in one window.
 *
 * A second guest screen is a second graphics card, and on a Mac with two
 * screens each card gets its own window (SecondScreen.swift).  On a Mac with
 * one screen that would put the second window on top of the first, which is
 * the worst of both worlds: the reader paid a card's worth of video memory
 * and cannot see what it draws without dragging a window out of the way every
 * time.  So on a single screen the two pictures share one window and stand
 * side by side, the way the guest itself arranges them -- screen 1 on the
 * left with the menu bar, screen 2 to its right.
 *
 * Each pane keeps its own guest's shape.  The width is split in proportion to
 * the two guests' aspect ratios so that, at a window shaped like the pair,
 * both run at the same height with neither letterboxed; at any other window
 * shape each pane letterboxes itself, which is what the single-screen window
 * has always done.
 */
@MainActor
final class CombinedScreensView: NSView {
    let first: VMDisplayView
    let second: VMDisplayView

    /// A hairline so the join between the two guest screens is visible; without
    /// it a window spanning two desktops reads as one very wide desktop.
    private let divider: NSView = {
        let v = NSView()
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.cgColor
        return v
    }()

    private let gap: CGFloat = 2

    /*
     * Whether the second guest screen's pane is drawn.
     *
     * Harmony turns the guest's windows into windows on this Mac, so while it
     * is on there is nothing left for a guest *screen* to show -- the first
     * pane is masked down to its windows, and the second would otherwise go
     * on drawing its whole desktop across half the display, which is what it
     * did.  Hidden, the first pane takes the window and the second screen is
     * represented by its windows, like the first.
     */
    var showsSecond = true {
        didSet {
            guard showsSecond != oldValue else { return }
            second.isHidden = !showsSecond
            divider.isHidden = !showsSecond
            needsLayout = true
        }
    }

    init(first: VMDisplayView, second: VMDisplayView) {
        self.first = first
        self.second = second
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.black.cgColor
        addSubview(first)
        addSubview(divider)
        addSubview(second)
    }

    required init?(coder: NSCoder) { fatalError() }

    /// The shape the pair wants, for sizing the window.
    var combinedAspect: CGSize {
        let a = first.guestSize, b = second.guestSize
        let h = max(a.height, b.height)
        let w = a.width * (h / max(1, a.height)) + b.width * (h / max(1, b.height))
        return CGSize(width: w + gap, height: h)
    }

    override func layout() {
        super.layout()
        guard showsSecond else {
            first.frame = bounds
            return
        }
        let a = first.guestSize, b = second.guestSize
        let ar1 = a.width / max(1, a.height)
        let ar2 = b.width / max(1, b.height)
        let h = bounds.height
        let usable = max(0, bounds.width - gap)
        let w1 = (ar1 + ar2) > 0 ? usable * ar1 / (ar1 + ar2) : usable / 2
        first.frame = CGRect(x: 0, y: 0, width: w1.rounded(), height: h)
        divider.frame = CGRect(x: w1.rounded(), y: 0, width: gap, height: h)
        second.frame = CGRect(x: w1.rounded() + gap, y: 0,
                              width: usable - w1.rounded(), height: h)
    }

    /// Which pane the pointer is over, so a click goes to the right guest screen.
    func pane(at point: NSPoint) -> VMDisplayView {
        point.x <= first.frame.maxX ? first : second
    }
}
