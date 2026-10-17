import Foundation

/// Diagnostic only: dispatch to publication of a capture REQUESTED after input.
/// This is not a guest paint acknowledgment or physical click-to-photon timing.
/// Bounded memory, flushed only when Harmony changes session.
struct HarmonyInteractionTiming {
    let enabled: Bool
    private var pending: (id: Int, afterSequence: Int, time: Double)?
    private(set) var rows: [Double] = []
    private(set) var superseded = 0
    private(set) var dropped = 0
    init(enabled: Bool = ProcessInfo.processInfo.environment["POWEREMU_INTERACTION_TIMING"] == "1") {
        self.enabled = enabled
    }
    mutating func dispatched(id: Int, sequence: Int, now: Double) {
        guard enabled else { return }
        if pending != nil { superseded += 1 }
        pending = (id, sequence, now)
    }
    mutating func published(id: Int, sequence: Int, now: Double) {
        guard enabled, let input = pending, input.id == id, sequence > input.afterSequence else { return }
        pending = nil
        guard rows.count < 256 else { dropped += 1; return }
        rows.append(max(0, now - input.time) * 1000)
    }
    mutating func finish() -> [String] {
        guard enabled else { return [] }
        let result = ["PEINTERACTION rows=\(rows.count) superseded=\(superseded) drops=\(dropped) pending=\(pending == nil ? 0 : 1)"] + rows.map {
            String(format: "PEINTERACTION dispatchToPostRequestPublicationMS=%.3f", $0)
        }
        pending = nil; rows.removeAll(keepingCapacity: true); superseded = 0; dropped = 0
        return result
    }
}
