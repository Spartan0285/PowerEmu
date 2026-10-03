import AppKit

/*
 * The performance overlay: what the virtual Mac and this Mac are doing,
 * with the recent past drawn behind the numbers.
 *
 * A single figure hides the interesting part.  A guest at "30 fps" that
 * drops to 4 for a moment every second feels nothing like a steady 30, and
 * an emulator that is starved only now and then looks fine in a snapshot.
 * So each row keeps its last couple of minutes and draws them as a small
 * graph, and the frame rate carries its lowest and highest with it.
 *
 * The reader can drag it anywhere in the window, in Harmony too; where it
 * was put is remembered for next time.
 */
final class PerfHUD: CALayer {
    /// One row: a label, the current reading, and its recent history.
    struct Row {
        var title: String
        var value: String
        var history: [Double]
        var scale: Double           // what the top of the graph means
        var tint: NSColor
        var graph = true
    }

    /// Full: every row, its graph, and the host lines.  Light: the frame
    /// rate and the processor only, side by side on one line.
    enum Style: String { case full, light }
    var hudStyle: Style = .full {
        didSet {
            guard hudStyle != oldValue else { return }
            // The two styles have nothing to do with each other's width.
            widthFloor = 0
            raiseWidth(for: hudStyle)
            setNeedsDisplay()
        }
    }
    static let styleKey = "PerformanceOverlayStyle"

    private(set) var rows: [Row] = []
    private var lines: [String] = []
    var lineCount: Int { lines.count }

    /// Which rows the light style shows, by the start of their title.
    private static let lightTitles = ["Frame", "CPU", "Processor"]
    private var lightRows: [Row] {
        rows.filter { r in Self.lightTitles.contains { r.title.hasPrefix($0) } }
    }

    /// Where it was dragged to, as the point of its top-left corner.  The
    /// name changed with the meaning: the old key held a fraction of the
    /// window, and reading one of those as a point would stack it in the
    /// corner.  A new key simply ignores them.
    static let positionKey = "PerformanceOverlayTopLeft"

    override init() {
        super.init()
        common()
    }

    override init(layer: Any) {
        super.init(layer: layer)
        common()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        common()
    }

    private func common() {
        backgroundColor = NSColor.black.withAlphaComponent(0.62).cgColor
        cornerRadius = 8
        contentsScale = 2
        isHidden = true
        /*
         * Redraw when it changes size.  Without this the overlay keeps the
         * picture it drew at its old size and stretches it: adding a row
         * left the first one drawn above the panel, outside the dark
         * background, over the guest's screen.
         */
        needsDisplayOnBoundsChange = true
        contentsGravity = .topLeft
        // No animation: the overlay must not slide about while it updates.
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(),
                   "hidden": NSNull(), "sublayers": NSNull()]
    }

    func update(rows: [Row], lines: [String]) {
        self.rows = rows
        self.lines = lines
        raiseWidth(for: hudStyle)
        /*
         * Take the size the new contents need straight away, rather than
         * waiting for the window to lay out again.  The overlay gains a
         * row -- the frame rate's lowest and highest arrive once there is
         * a second of history -- and until the frame caught up, the first
         * row was drawn outside the dark panel, over the guest's screen.
         * It grows downwards, so the top edge stays where it was put.
         */
        let want = wantedSize
        if abs(want.width - bounds.width) > 0.5 || abs(want.height - bounds.height) > 0.5 {
            let top = frame.maxY
            frame = CGRect(x: frame.minX, y: top - want.height,
                           width: want.width, height: want.height)
        }
        setNeedsDisplay()
    }

    /// Everything the layout depends on, in one place, so the height it
    /// asks for and the height it draws into can never disagree.
    enum Metric {
        static let leastWidth: CGFloat = 340
        /// Fixed widths, wide enough for the longest reading each style shows.
        static let fullWidth: CGFloat = 360
        static let lightWidth: CGFloat = 196
        static let padding: CGFloat = 8
        static let margin: CGFloat = 10     // text inset from the sides
        static let gap: CGFloat = 16        // between a row's label and its reading
        static let title: CGFloat = 15
        static let graph: CGFloat = 19
        static let line: CGFloat = 15
        static var row: CGFloat { title + graph }
        static let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .medium)
        static let small = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)
    }

    private static func width(_ s: String, _ f: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: s, attributes: [.font: f]).size().width)
    }

    /*
     * How big it is.  The width is fixed by the style, not measured from
     * what is on screen at this instant.
     *
     * It used to be the width of the longest string it happened to be
     * showing, so every time a reading changed length -- the pointer figures
     * change as the mouse moves -- the panel changed width underneath the
     * reader, and anything dragged near an edge shifted with it.  A panel
     * that resizes while being read is worse than one that is a little wider
     * than it needs to be, so the width is now a constant per style and the
     * text is laid out inside it.
     */
    var wantedSize: CGSize {
        switch hudStyle {
        case .light:
            return CGSize(width: max(Metric.lightWidth, widthFloor),
                          height: Metric.padding * 2 + Metric.title)
        case .full:
            return CGSize(width: max(Metric.fullWidth, widthFloor),
                          height: Metric.padding * 2 + CGFloat(rows.count) * Metric.row
                                + CGFloat(lines.count) * Metric.line)
        }
    }

    /*
     * The width only ever grows.
     *
     * Measuring it from whatever is on screen this second made the panel
     * change width as readings changed length -- the pointer figures move
     * with the mouse -- and a panel that resizes while being read is no good.
     * A fixed width was worse: the host lines are longer than any sensible
     * constant and were cut off.  So it is measured, but kept: it rises to
     * fit the widest thing seen and never falls back, which settles within a
     * second or two and then stays put.
     */
    private var widthFloor: CGFloat = 0

    private func raiseWidth(for style: Style) {
        var text: CGFloat = 0
        switch style {
        case .light:
            for row in lightRows {
                let label = row.title.hasPrefix("Frame") ? "FPS" : "CPU"
                text += Self.width("\(label) \(row.value)", Metric.font) + Metric.gap
            }
            text = max(0, text - Metric.gap)
        case .full:
            for row in rows {
                text = max(text, Self.width(row.title, Metric.font) + Metric.gap
                                 + Self.width(row.value, Metric.font))
            }
            for line in lines {
                text = max(text, Self.width(line, Metric.small))
            }
        }
        widthFloor = max(widthFloor, text + Metric.margin * 2)
    }

    override func draw(in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = Metric.font, small = Metric.small
        if hudStyle == .light {
            /*
             * One line, read left to right: the frame rate, then the
             * processor.  No graphs and no host lines -- the point of this
             * style is to sit in a corner of a game without being read as a
             * panel of its own.
             */
            let y = bounds.height - Metric.padding - Metric.title
            var x = Metric.margin
            for row in lightRows {
                let text = NSAttributedString(
                    string: "\(row.title.hasPrefix("Frame") ? "FPS" : "CPU") \(row.value)",
                    attributes: [.font: font, .foregroundColor: NSColor.white])
                text.draw(at: CGPoint(x: x, y: y))
                x += text.size().width + Metric.gap
            }
            NSGraphicsContext.restoreGraphicsState()
            return
        }
        var y = bounds.height - Metric.padding

        for row in rows {
            y -= Metric.title
            draw(row.title, at: CGPoint(x: Metric.margin, y: y), font: font, color: .white)
            let value = NSAttributedString(string: row.value,
                                           attributes: [.font: font, .foregroundColor: NSColor.white])
            value.draw(at: CGPoint(x: bounds.width - Metric.margin - value.size().width, y: y))
            y -= Metric.graph
            if row.graph {
                plot(row, in: CGRect(x: Metric.margin, y: y + 2,
                                     width: bounds.width - Metric.margin * 2,
                                     height: Metric.graph - 4), ctx: ctx)
            }
        }
        for line in lines {
            y -= Metric.line
            draw(line, at: CGPoint(x: Metric.margin, y: y), font: small,
                 color: line.contains("<<") ? .systemOrange : NSColor.white.withAlphaComponent(0.75))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ s: String, at p: CGPoint, font: NSFont, color: NSColor) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color]).draw(at: p)
    }

    /// The history as a filled line, oldest at the left.
    private func plot(_ row: Row, in rect: CGRect, ctx: CGContext) {
        ctx.saveGState()
        ctx.setFillColor(NSColor.white.withAlphaComponent(0.06).cgColor)
        ctx.fill(rect)

        guard row.history.count > 1, row.scale > 0 else { ctx.restoreGState(); return }
        let n = row.history.count
        let dx = rect.width / CGFloat(max(1, n - 1))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        for (i, v) in row.history.enumerated() {
            let f = min(1, max(0, v / row.scale))
            path.addLine(to: CGPoint(x: rect.minX + CGFloat(i) * dx,
                                     y: rect.minY + rect.height * CGFloat(f)))
        }
        path.addLine(to: CGPoint(x: rect.minX + CGFloat(n - 1) * dx, y: rect.minY))
        path.closeSubpath()
        ctx.addPath(path)
        ctx.setFillColor(row.tint.withAlphaComponent(0.35).cgColor)
        ctx.fillPath()

        let line = CGMutablePath()
        for (i, v) in row.history.enumerated() {
            let f = min(1, max(0, v / row.scale))
            let p = CGPoint(x: rect.minX + CGFloat(i) * dx, y: rect.minY + rect.height * CGFloat(f))
            if i == 0 { line.move(to: p) } else { line.addLine(to: p) }
        }
        ctx.addPath(line)
        ctx.setStrokeColor(row.tint.cgColor)
        ctx.setLineWidth(1)
        ctx.strokePath()
        ctx.restoreGState()
    }
}

/// The readings behind one row, kept for as long as the graph is wide.
struct PerfHistory {
    private(set) var values: [Double] = []
    private(set) var lowest: Double = .greatestFiniteMagnitude
    private(set) var highest: Double = 0
    let limit: Int

    init(limit: Int = 120) { self.limit = limit }

    mutating func add(_ v: Double) {
        values.append(v)
        if values.count > limit { values.removeFirst(values.count - limit) }
        // The first reading of a run is taken before anything is drawn, so
        // it says nothing about how the machine performs: ignore it in the
        // lowest and highest.
        guard values.count > 1 else { return }
        lowest = min(lowest, v)
        highest = max(highest, v)
    }

    var hasRange: Bool { highest > 0 && lowest <= highest }

    mutating func reset() {
        values.removeAll()
        lowest = .greatestFiniteMagnitude
        highest = 0
    }

    /// A round number above everything seen, so the graph doesn't rescale
    /// on every sample.
    func scale(atLeast floor: Double) -> Double {
        let top = max(floor, highest)
        let step: Double = top <= 30 ? 10 : top <= 120 ? 30 : 60
        return (top / step).rounded(.up) * step
    }
}
