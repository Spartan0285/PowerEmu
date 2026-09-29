import Foundation
import CoreGraphics

@main
struct HarmonyInteractionRegression {
    static func main() {
        var menuFocus = HarmonyMenuFocusIntent()
        menuFocus.begin(token: "old", now: 0)
        menuFocus.begin(token: "new", now: 0.1)
        precondition(!menuFocus.consume(token: "old", now: 0.2))
        precondition(menuFocus.consume(token: "new", now: 0.3))
        precondition(!menuFocus.consume(token: "new", now: 0.4))
        menuFocus.begin(token: "late", now: 1)
        precondition(!menuFocus.consume(token: "late", now: 3.1))
        menuFocus.begin(token: "cancelled", now: 4)
        menuFocus.cancel()
        precondition(!menuFocus.consume(token: "cancelled", now: 4.1))
        print("PASS: explicit menu focus, superseded/late/duplicate replies, host focus cancellation")
        let height: CGFloat = 400
        func accept(_ down: CGPoint, _ up: CGPoint, moved: CGPoint = .zero) -> Bool {
            HarmonyTitleClick.accepts(downScreen: CGPoint(x: 500, y: 500),
                upScreen: CGPoint(x: 500 + moved.x, y: 500 + moved.y),
                downLocal: down, upLocal: up, height: height)
        }
        let close = CGPoint(x: 13, y: 389), minimize = CGPoint(x: 35, y: 389)
        let title = CGPoint(x: 250, y: 389)
        precondition(accept(close, close) && accept(minimize, minimize) && accept(title, title))
        precondition(!accept(title, close), "moving the window beneath a stationary pointer must not turn a title click into Close")
        precondition(!accept(minimize, close), "release on another control must not activate it")
        precondition(!accept(close, close, moved: CGPoint(x: 40, y: 0)), "missing mouseDragged must not turn a drag into a click")
        precondition(!accept(title, CGPoint(x: 250, y: 200)), "release outside title bar cancels")
        precondition(!accept(title, title, moved: CGPoint(x: 0, y: 3)))
        precondition(accept(title, title, moved: CGPoint(x: 1, y: 1)))
        var restore = HarmonyRestoreIntent()
        precondition(restore.request(hasBinding: true))
        for _ in 0..<20 {
            precondition(restore.isPending)
            precondition(!restore.request(hasBinding: true), "native callback must not duplicate restore")
            precondition(!restore.bind(), "stale minimized entry must not restart restore")
        }
        restore.acknowledgeVisible()
        precondition(!restore.isPending)
        // User restores before the guest has completed its minimize.
        precondition(!restore.request(hasBinding: false))
        restore.acknowledgeVisible() // stale pre-minimize WINDOWS report
        precondition(restore.isPending && !restore.canAcknowledgeVisible)
        precondition(restore.bind(), "late Dock binding must send exactly one restore")
        precondition(!restore.bind() && restore.canAcknowledgeVisible)
        restore.acknowledgeVisible()
        precondition(!restore.isPending)
        precondition(restore.request(hasBinding: true))
        restore.cancelForMinimize()
        precondition(!restore.isPending && !restore.bind(), "new minimize supersedes restore")
        print("PASS: restore survives stale reports, early restore binds once, visible acknowledgment and newer minimize")
        print("PASS: title control identity, moved-window release, missing drag event, and click slop")
    }
}
