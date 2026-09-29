import Foundation

@main
struct CaptureSchedulingRegression {
    static func main() {
        typealias Candidate = HarmonyCaptureScheduler.Candidate
        let normal = (1...4).map { Candidate(id: $0, needsImage: false) }
        var scheduler = HarmonyCaptureScheduler()
        // Always-changing windows: bounded foreground burst, no starvation.
        var counts: [Int: Int] = [:]
        var last: [Int: Double] = [:]
        var maxGap = 0.0
        for step in 0..<1000 {
            let now = Double(step) * 0.04
            let id = scheduler.next(normal, foreground: 1, now: now)!
            counts[id, default: 0] += 1
            if id != 1, let previous = last[id] { maxGap = max(maxGap, now - previous) }
            last[id] = now
            scheduler.completed(id, unchanged: false, visible: true, now: now + 0.04)
        }
        precondition(counts[1, default: 0] >= 740 && maxGap < 0.51)
        for id in 2...4 { precondition(counts[id, default: 0] >= 80) }

        // Stationary backgrounds back off; focused capture never sleeps.
        scheduler = HarmonyCaptureScheduler()
        var samples: [Int: Int] = [:]
        for step in 0..<1500 {
            let now = Double(step) * 0.04
            let id = scheduler.next(normal, foreground: 1, now: now)!
            scheduler.completed(id, unchanged: id != 1, visible: true, now: now + 0.04)
            if step >= 250 { samples[id, default: 0] += 1 }
        }
        precondition(samples[1, default: 0] > 1000)
        for id in 2...4 { precondition((40...65).contains(samples[id, default: 0])) }
        print("SIMULATION: fixed 40 ms captures, 1 active + 3 stationary visible windows, last 50 s: \(samples.sorted { $0.key < $1.key })")

        // Compare the previous 2:1 policy under exactly the same synthetic
        // workload. This is scheduler allocation, not a measured frame rate.
        var oldLast: [Int: Double] = [:], oldDue: [Int: Double] = [:]
        var oldStreak = 0, oldCounts: [Int: Int] = [:]
        for step in 0..<1500 {
            let now = Double(step) * 0.04
            let eligible = (1...4).filter { $0 == 1 || (oldDue[$0] ?? -.infinity) <= now }
            let oldest = eligible.min { (oldLast[$0] ?? -.infinity) < (oldLast[$1] ?? -.infinity) }!
            let id: Int
            if oldStreak < 2 { id = 1; oldStreak += 1 }
            else { id = oldest; oldStreak = 0 }
            oldLast[id] = now + 0.04
            oldDue[id] = now + 0.04 + (id == 1 ? 0.05 : 0.1)
            if step >= 250 { oldCounts[id, default: 0] += 1 }
        }
        precondition(samples[1, default: 0] > oldCounts[1, default: 0])
        print("SIMULATION previous policy, same workload: \(oldCounts.sorted { $0.key < $1.key })")
        var inactive = HarmonyCaptureScheduler()
        var inactiveCount = 0
        for step in 0..<6000 {
            let now = Double(step) * 0.01
            if let id = inactive.next(normal, foreground: nil, now: now) {
                inactive.completed(id, unchanged: true, visible: true, now: now + 0.04)
                if step >= 1000 { inactiveCount += 1 }
            }
        }
        precondition(inactiveCount < 250 && inactiveCount > 200)

        // Focus switch bypasses an existing idle delay immediately.
        var quiet = HarmonyCaptureScheduler()
        for _ in 0..<6 { quiet.completed(2, unchanged: true, visible: true, now: 10) }
        precondition(quiet.next([normal[1]], foreground: nil, now: 10.1) == nil)
        precondition(quiet.next([normal[1]], foreground: 2, now: 10.1) == 2)
        // Changed contents reset backoff; uncover invalidation does too.
        quiet.completed(2, unchanged: false, visible: true, now: 11)
        precondition(quiet.next([normal[1]], foreground: nil, now: 11.06) == 2)
        for _ in 0..<6 { quiet.completed(2, unchanged: true, visible: false, now: 12) }
        precondition(quiet.next([normal[1]], foreground: nil, now: 13) == nil)
        quiet.invalidate(2)
        precondition(quiet.next([normal[1]], foreground: nil, now: 13) == 2)

        // First images win; repeated capture errors don't monopolize priority.
        var failures = HarmonyCaptureScheduler()
        let first = Candidate(id: 5, needsImage: true)
        precondition(failures.next(normal + [first], foreground: 1, now: 0) == 5)
        failures.failed(5, now: 0)
        precondition(failures.next(normal + [first], foreground: 5, now: 0.1) != 5)
        precondition(failures.next(normal + [first], foreground: 1, now: 0.51) == 5)
        // Removing a window discards retry state before ID reuse.
        _ = failures.next(normal, foreground: 1, now: 0.2)
        precondition(failures.next([first], foreground: nil, now: 0.3) == 5)
        precondition(failures.next([], foreground: nil, now: 100) == nil)
        print("PASS: fairness, idle backoff, focus wake, changed/uncovered wake, first images, error retry and ID reuse")
    }
}
