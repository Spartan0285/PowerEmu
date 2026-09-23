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
 * The reader can drag it anywhere in the window; where it was put is
 * remembered for next time.
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

    private(set) var rows: [Row] = []
    private var lines: [String] = []
    var lineCount: Int { lines.count }

    /// Where the reader dragged it, as a fraction of the window, so it
    /// stays put when the window is resized.
    static let positionKey = "PerformanceOverlayPosition"

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

    /// How big it wants to be for what it is showing.  The width follows
    /// the text: the host line grew past a fixed 340 points and was cut off
    /// mid-word.
    var wantedSize: CGSize {
        var text = Metric.leastWidth - Metric.margin * 2
        for row in rows {
            text = max(text, Self.width(row.title, Metric.font) + Metric.gap
                             + Self.width(row.value, Metric.font))
        }
        for line in lines {
            text = max(text, Self.width(line, Metric.small))
        }
        return CGSize(width: text + Metric.margin * 2,
                      height: Metric.padding * 2 + CGFloat(rows.count) * Metric.row
                            + CGFloat(lines.count) * Metric.line)
    }

    override func draw(in ctx: CGContext) {
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        let font = Metric.font, small = Metric.small
        var y = bounds.height - Metric.padding

        for row in rows {
            y -= Metric.title
            draw(row.title, at: CGPoint(x: Metric.margin, y: y), font: font, colour: .white)
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
                 colour: line.contains("<<") ? .systemOrange : NSColor.white.withAlphaComponent(0.75))
        }
        NSGraphicsContext.restoreGraphicsState()
    }

    private func draw(_ s: String, at p: CGPoint, font: NSFont, colour: NSColor) {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: colour]).draw(at: p)
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
