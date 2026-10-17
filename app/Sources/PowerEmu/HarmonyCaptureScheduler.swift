import Foundation

/// Completion-driven policy; the manager owns the single outstanding request.
/// Times are monotonic seconds. A due time is eligibility, not a refresh promise:
/// every window still shares the guest's serial capture worker.
struct HarmonyCaptureScheduler {
    struct Candidate {
        let id: Int
        let needsImage: Bool
        var visible = true
    }
    private struct State {
        var last = -Double.infinity
        var due = -Double.infinity
        var retry = -Double.infinity
        var idle = 0
        var visible: Bool?
        var exposed = false
    }
    private var states: [Int: State] = [:]
    private var foregroundStreak = 0
    private var lastForeground: Int?
    private var interaction: (id: Int, expires: Double)?
    private var interactionPending = false
    private var interactionDebt = false
    private(set) var borrowedInteractionSlots = 0
    var paceForegroundIdle = false
    /// Permit one post-input foreground slot beyond the normal burst, then
    /// service an eligible background window before permitting another loan.
    var prioritizeInteraction = false
    /// A complete first image is still needed before ordering a new proxy.
    /// Once painted, a fully occluded host window can keep its last image
    /// until AppKit reports it exposed. No guest visibility guess is used.
    var suspendOccluded = false

    /// A prompt refresh followed by a short foreground burst. The streak
    /// budget survives repeated input so background windows cannot starve.
    mutating func interacted(_ id: Int, now: Double) {
        interaction = (id, now + 0.45)
        interactionPending = true
        var state = states[id] ?? State()
        state.idle = 0
        states[id] = state
    }

    mutating func invalidate(_ id: Int) { states.removeValue(forKey: id) }

    mutating func next(_ candidates: [Candidate], foreground: Int?, now: Double) -> Int? {
        let live = Set(candidates.map(\.id))
        states = states.filter { live.contains($0.key) }
        if foreground != lastForeground {
            foregroundStreak = 0
            lastForeground = foreground
        }
        for candidate in candidates {
            var state = states[candidate.id] ?? State()
            if state.visible == false && candidate.visible {
                state.exposed = true
                state.idle = 0
            }
            state.visible = candidate.visible
            states[candidate.id] = state
        }
        let eligible = candidates.filter {
            let state = states[$0.id] ?? State()
            if suspendOccluded && !$0.visible && !$0.needsImage { return false }
            let foregroundDue = paceForegroundIdle && state.idle > 0 ? state.last + 1.0 / 30 : -.infinity
            let backgroundFloor = state.last + ($0.visible ? 0.125 : 0.8)
            return state.retry <= now && (($0.id == foreground && foregroundDue <= now) || $0.needsImage || state.exposed ||
                (state.due <= now && backgroundFloor <= now))
        }
        func oldest(_ items: [Candidate]) -> Candidate? {
            items.min { (states[$0.id]?.last ?? -.infinity) < (states[$1.id]?.last ?? -.infinity) }
        }
        if let input = interaction {
            if input.expires < now || !live.contains(input.id) || input.id != foreground {
                interaction = nil; interactionPending = false
            } else if interactionPending, let selected = eligible.first(where: { $0.id == input.id }) {
                let backgroundWaiting = eligible.contains { $0.id != foreground }
                let initialOrExposedWaiting = eligible.contains { $0.needsImage || states[$0.id]?.exposed == true }
                if foregroundStreak < 6, !interactionDebt {
                    interactionPending = false
                    foregroundStreak += 1
                    return selected.id
                }
                if prioritizeInteraction, !interactionDebt, backgroundWaiting, !initialOrExposedWaiting {
                    interactionPending = false
                    interactionDebt = true
                    if borrowedInteractionSlots < Int.max { borrowedInteractionSlots += 1 }
                    foregroundStreak += 1
                    return selected.id
                }
            }
        }
        // First images/resizes must not wait behind repeats. Failed windows
        // have a retry deadline so they cannot monopolize this priority lane.
        if let first = oldest(eligible.filter { $0.needsImage || states[$0.id]?.exposed == true }) {
            if first.id != foreground { interactionDebt = false }
            foregroundStreak = 0
            return first.id
        }
        let front = eligible.first { $0.id == foreground }
        let background = oldest(eligible.filter { $0.id != foreground })
        if interactionDebt, let background {
            interactionDebt = false
            foregroundStreak = 0
            return background.id
        }
        let foregroundBudget = interaction?.id == foreground && interaction != nil ? 6 : 4
        if let front, foregroundStreak < foregroundBudget || background == nil {
            foregroundStreak = min(foregroundBudget, foregroundStreak + 1)
            return front.id
        }
        if let background {
            interactionDebt = false
            foregroundStreak = 0
            return background.id
        }
        return nil
    }

    mutating func completed(_ id: Int, unchanged: Bool, visible: Bool, now: Double) {
        var state = states[id] ?? State()
        state.last = now
        state.retry = -.infinity
        state.visible = visible
        state.exposed = false
        state.idle = unchanged ? min(6, state.idle + 1) : 0
        // Changing background windows stay responsive; stationary ones back
        // off. Foreground bypasses this delay, preserving animation/input.
        let cap = visible ? 1.0 : 3.0
        state.due = now + min(cap, 0.1 * pow(2, Double(state.idle)))
        states[id] = state
    }

    mutating func failed(_ id: Int, now: Double) {
        var state = states[id] ?? State()
        state.last = now
        state.retry = now + 0.5
        states[id] = state
    }
}
