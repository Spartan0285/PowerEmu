import Foundation
import CoreGraphics

/// A title-bar click must finish on the same control where it began. A
/// missing drag event or a moved window must never turn a drag into Close.
enum HarmonyTitleClick {
    static func control(at point: CGPoint, height: CGFloat) -> Int {
        guard point.y >= height - 22, point.y <= height, point.x >= 0 else { return -1 }
        if point.x < 25 { return 1 }
        if point.x <= 47 { return 2 }
        if point.x <= 69 { return 3 }
        return 0
    }
    static func accepts(downScreen: CGPoint, upScreen: CGPoint,
                        downLocal: CGPoint, upLocal: CGPoint, height: CGFloat) -> Bool {
        abs(downScreen.x - upScreen.x) < 3 && abs(downScreen.y - upScreen.y) < 3 &&
        control(at: downLocal, height: height) >= 0 &&
        control(at: downLocal, height: height) == control(at: upLocal, height: height)
    }
}

/// Restore intent survives stale absent/minimized reports. Only a visible
/// guest window or a newer explicit minimize ends the transition.
struct HarmonyRestoreIntent {
    private enum Phase { case idle, awaitingBinding, awaitingVisibility }
    private var phase = Phase.idle
    var isPending: Bool { phase != .idle }
    var canAcknowledgeVisible: Bool { phase == .awaitingVisibility }
    mutating func request(hasBinding: Bool) -> Bool {
        if phase == .awaitingVisibility { return false }
        phase = hasBinding ? .awaitingVisibility : .awaitingBinding
        return hasBinding
    }
    mutating func bind() -> Bool {
        guard phase == .awaitingBinding else { return false }
        phase = .awaitingVisibility
        return true
    }
    mutating func acknowledgeVisible() {
        if canAcknowledgeVisible { phase = .idle }
    }
    mutating func cancelForMinimize() { phase = .idle }
}

/// A menu's asynchronous guest reply may arrive after another selection.
struct HarmonyMenuFocusIntent {
    private var pending: (token: String, deadline: TimeInterval)?
    mutating func begin(token: String, now: TimeInterval) { pending = (token, now + 2) }
    mutating func cancel() { pending = nil }
    mutating func consume(token: String, now: TimeInterval) -> Bool {
        guard let value = pending, value.token == token else { return false }
        pending = nil
        return now <= value.deadline
    }
}
