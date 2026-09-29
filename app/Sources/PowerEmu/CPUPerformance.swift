import Foundation

/// Rates for each emulated CPU's host thread. Guest idle loops still consume
/// host CPU time; these are not guest scheduler busy percentages.
struct CPUPerformance {
    struct Reading {
        let index: Int
        let percent: Double?
    }
    private var epoch: Double?
    private var time: Double?
    private var counters: [Int: Double] = [:]
    private(set) var count = 0
    private(set) var shared = false

    mutating func reset() { self = CPUPerformance() }

    mutating func sample(_ fields: [String: Double]) -> [Reading] {
        guard let n = fields["cpu_count"], n.isFinite,
              n >= 1, n <= 64, n.rounded() == n,
              let stamp = fields["cpu_sample_ns"], stamp.isFinite,
              let identity = fields["cpu_epoch"], identity.isFinite else {
            reset()
            return []
        }
        let nextCount = Int(n)
        let nextShared = fields["cpu_shared"] == 1
        if epoch != identity || count != nextCount || shared != nextShared {
            reset()
        }
        count = nextCount
        shared = nextShared
        epoch = identity
        let dt = time.map { stamp - $0 }
        var current: [Int: Double] = [:]
        let readings = (0..<count).map { index -> Reading in
            guard !shared, let value = fields["cpu\(index)_ns"],
                  value.isFinite, value >= 0 else {
                return Reading(index: index, percent: nil)
            }
            current[index] = value
            guard let previous = counters[index], let dt, dt > 0,
                  value >= previous else {
                return Reading(index: index, percent: nil)
            }
            return Reading(index: index,
                           percent: min(100, max(0, (value - previous) / dt * 100)))
        }
        counters = current
        time = stamp
        return readings
    }
}
