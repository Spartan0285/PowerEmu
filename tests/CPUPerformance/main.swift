import Foundation

func fields(_ time: Double, _ a: Double, _ b: Double, epoch: Double = 1) -> [String: Double] {
    ["cpu_count": 2, "cpu_shared": 0, "cpu_epoch": epoch,
     "cpu_sample_ns": time, "cpu0_ns": a, "cpu1_ns": b]
}
var sampler = CPUPerformance()
assert(sampler.sample(fields(0, 0, 0)).allSatisfy { $0.percent == nil })
let asymmetric = sampler.sample(fields(1_000, 250, 750))
assert(asymmetric[0].percent == 25 && asymmetric[1].percent == 75)
assert(sampler.sample(fields(2_000, 100, 100, epoch: 2)).allSatisfy { $0.percent == nil })
var missing = fields(3_000, 600, 600, epoch: 2)
missing.removeValue(forKey: "cpu1_ns")
let partial = sampler.sample(missing)
assert(partial[0].percent == 50 && partial[1].percent == nil)
assert(sampler.sample(fields(4_000, 700, 700, epoch: 2))[1].percent == nil)
assert(sampler.sample(fields(4_000, 800, 800, epoch: 2)).allSatisfy { $0.percent == nil })
assert(sampler.sample(fields(5_000, 10, 10, epoch: 2)).allSatisfy { $0.percent == nil })
var shared = fields(6_000, 500, 500, epoch: 2)
shared["cpu_shared"] = 1
assert(sampler.sample(shared).allSatisfy { $0.percent == nil } && sampler.shared)
assert(sampler.sample([:]).isEmpty && sampler.count == 0)
var invalid = fields(7_000, 500, 500)
invalid["cpu_count"] = .nan
assert(sampler.sample(invalid).isEmpty)
sampler.reset()
_ = sampler.sample(fields(0, 0, 0))
assert(sampler.sample(fields(1_000, 2_000, 0))[0].percent == 100)
print("PASS: asymmetric rates, restart, missing counters, zero interval, counter reset, shared threads, legacy backend, invalid count, clamp")
