import AppKit

/*
 * The performance overlay's light style, which picks the rows it shows by
 * matching the start of their titles.
 *
 * That is a string match against titles written somewhere else, and it had
 * already rotted once: the rows were renamed, the match was not, and the
 * light style quietly showed the host cores and no frame rate at all -- the
 * one figure it exists for.  Nothing failed, nothing logged, and the style is
 * the one a reader turns on in a game and squints at.  So the match is pinned
 * here.
 *
 * Build and run:
 *   swiftc -o /tmp/perfoverlay tests/PerfOverlay/main.swift \
 *       app/Sources/PowerEmu/PerfHUD.swift && /tmp/perfoverlay
 */

func row(_ title: String, _ value: String, light: String? = nil,
         graph: Bool = true) -> PerfHUD.Row {
    PerfHUD.Row(title: title, value: value, history: [1, 2], scale: 10,
                tint: .systemGreen, graph: graph, lightValue: light)
}

/* The rows VMDisplay builds, in the order it builds them. */
let full = [
    row("Guest", "53 fps   (4 low, 60 high)", light: "53"),
    row("Window", "60 fps"),
    row("Draws", "1200/s"),
    row("Emulator", "180% host CPU", light: "180%"),
    row("CPU 1", "92% host core"),
    row("CPU 2", "88% host core"),
]

let hud = PerfHUD()
hud.hudStyle = .light
hud.update(rows: full, lines: ["this Mac 40% busy"])

/* The frame rate first, the emulator's host CPU second, and nothing else. */
assert(hud.lightRows.map(\.title) == ["Guest", "Emulator"],
       "light style shows \(hud.lightRows.map(\.title))")

/* Named by what they measure, since there is no room for the titles. */
assert(PerfHUD.lightLabel("Guest") == "FPS")
assert(PerfHUD.lightLabel("Emulator") == "CPU")

/* Its own order, not the order the rows happen to arrive in. */
hud.update(rows: full.reversed(), lines: [])
assert(hud.lightRows.map(\.title) == ["Guest", "Emulator"])

/* Every title the light style asks for is a title that exists. */
for t in PerfHUD.lightTitles {
    assert(full.contains { $0.title.hasPrefix(t) }, "no row is called \(t)")
}

/* One line of text, whatever the rows say. */
hud.update(rows: full, lines: [])
let light = hud.wantedSize
assert(light.height < PerfHUD.Metric.row, "light style is \(light.height) tall")

/*
 * An unaccelerated second screen reads as words, not as zeros: the full style
 * has room to say why, the light style has room only for the short form.
 */
let none = row("Guest", "no 3D on this screen", light: "no 3D", graph: false)
assert(none.lightValue == "no 3D" && !none.graph)

/* The full style grows with its rows; the light style does not. */
hud.hudStyle = .full
hud.update(rows: full, lines: [])
let tall = hud.wantedSize.height
hud.update(rows: Array(full.dropLast(2)), lines: [])
assert(hud.wantedSize.height < tall)
assert(hud.wantedSize.height > light.height)

print("PerfOverlay: ok")
