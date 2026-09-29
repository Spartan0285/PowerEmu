import Foundation

/// Completion-driven policy; the manager owns the single outstanding request.
/// Times are monotonic seconds. A due time is eligibility, not a refresh promise:
/// every window still shares the guest's serial capture worker.
struct HarmonyCaptureScheduler {
    struct Candidate {
        let id: Int
        let needsImage: Bool
    }
    private struct State {
        var last = -Double.infinity
        var due = -Double.infinity
        var retry = -Double.infinity
        var idle = 0
    }
    private var states: [Int: State] = [:]
    private var foregroundStreak = 0

    mutating func invalidate(_ id: Int) { states.removeValue(forKey: id) }

    mutating func next(_ candidates: [Candidate], foreground: Int?, now: Double) -> Int? {
        let live = Set(candidates.map(\.id))
        states = states.filter { live.contains($0.key) }
        let eligible = candidates.filter {
            let state = states[$0.id] ?? State()
            return state.retry <= now && ($0.id == foreground || $0.needsImage || state.due <= now)
        }
        func oldest(_ items: [Candidate]) -> Candidate? {
            items.min { (states[$0.id]?.last ?? -.infinity) < (states[$1.id]?.last ?? -.infinity) }
        }
        // First images/resizes must not wait behind repeats. Failed windows
        // have a retry deadline so they cannot monopolize this priority lane.
        if let first = oldest(eligible.filter(\.needsImage)) {
            foregroundStreak = 0
            return first.id
        }
        let front = eligible.first { $0.id == foreground }
        let background = oldest(eligible.filter { $0.id != foreground })
        if let front, foregroundStreak < 3 || background == nil {
            foregroundStreak = min(3, foregroundStreak + 1)
            return front.id
        }
        if let background {
            foregroundStreak = 0
            return background.id
        }
        return nil
    }

    mutating func completed(_ id: Int, unchanged: Bool, visible: Bool, now: Double) {
        var state = states[id] ?? State()
        state.last = now
        state.retry = -.infinity
        state.idle = unchanged ? min(6, state.idle + 1) : 0
        // Changing background windows stay responsive; stationary ones back
        // off. Foreground bypasses this delay, preserving animation/input.
        let cap = visible ? 0.8 : 2.0
        state.due = now + min(cap, 0.05 * pow(2, Double(state.idle)))
        states[id] = state
    }

    mutating func failed(_ id: Int, now: Double) {
        var state = states[id] ?? State()
        state.last = now
        state.retry = now + 0.5
        states[id] = state
    }
}
