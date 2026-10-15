import Foundation

/// Opt-in, bounded host-local focus request→ack timing. No I/O during input.
/// A superseded request has no matching acknowledgement and is counted apart.
struct HarmonyFocusTiming {
    struct Row {
        let id: Int
        let sequence: Int
        let milliseconds: Double
        let ok: Bool
        let queuedEvents: Int
    }
    let enabled: Bool
    private(set) var rows: [Row] = []
    private(set) var superseded = 0
    private(set) var dropped = 0
    private var pending: (id: Int, sequence: Int, time: Double)?
    init(enabled: Bool = ProcessInfo.processInfo.environment["POWEREMU_FOCUS_TIMING"] == "1") {
        self.enabled = enabled
    }
    mutating func begin(id: Int, sequence: Int, now: Double) {
        guard enabled else { return }
        if pending != nil { superseded += 1 }
        pending = (id, sequence, now)
    }
    mutating func acknowledge(id: Int, sequence: Int, ok: Bool, queuedEvents: Int, now: Double) {
        guard enabled, let start = pending, start.id == id, start.sequence == sequence else { return }
        pending = nil
        guard rows.count < 256 else { dropped += 1; return }
        rows.append(Row(id: id, sequence: sequence, milliseconds: max(0, now - start.time) * 1000,
                        ok: ok, queuedEvents: queuedEvents))
    }
    mutating func finish() -> [String] {
        guard enabled else { return [] }
        let output = ["PEFOCUSTIMING rows=\(rows.count) superseded=\(superseded) drops=\(dropped) pending=\(pending == nil ? 0 : 1)"] + rows.map {
            String(format: "PEFOCUSTIMING id=%d sequence=%d requestAckMS=%.3f ok=%d queued=%d",
                   $0.id, $0.sequence, $0.milliseconds, $0.ok ? 1 : 0, $0.queuedEvents)
        }
        rows.removeAll(keepingCapacity: true); pending = nil; superseded = 0; dropped = 0
        return output
    }
}
