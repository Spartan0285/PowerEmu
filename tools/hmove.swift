// hmove DX DY N [ms] : post N real host mouse-moved events with deltas
import Foundation
import CoreGraphics
let a = CommandLine.arguments
let dx = Int64(a[1])!, dy = Int64(a[2])!, n = Int(a[3])!, ms = a.count > 4 ? UInt32(a[4])! : 10
for _ in 0..<n {
    let cur = CGEvent(source: nil)!.location
    let p = CGPoint(x: cur.x + CGFloat(dx), y: cur.y + CGFloat(dy))
    let e = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: p, mouseButton: .left)!
    e.setIntegerValueField(.mouseEventDeltaX, value: dx)
    e.setIntegerValueField(.mouseEventDeltaY, value: dy)
    e.post(tap: .cghidEventTap)
    usleep(ms * 1000)
}
