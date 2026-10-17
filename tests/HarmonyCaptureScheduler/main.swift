import Foundation
func check(_ value: Bool, _ message: String) {
    if !value { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let front = HarmonyCaptureScheduler.Candidate(id: 1, needsImage: false)
let background = HarmonyCaptureScheduler.Candidate(id: 2, needsImage: false)
let newWindow = HarmonyCaptureScheduler.Candidate(id: 3, needsImage: true)
var s = HarmonyCaptureScheduler()
s.interacted(1, now: 10)
check(s.next([newWindow, front], foreground: 1, now: 10) == 1, "input precedes unrelated first image")
s.completed(1, unchanged: false, visible: true, now: 10)
check(s.next([newWindow, front], foreground: 1, now: 10) == 3, "first image follows one-shot input refresh")
var busy = HarmonyCaptureScheduler()
for tick in 0..<6 {
    let now = Double(tick) * 0.05
    busy.interacted(1, now: now)
    check(busy.next([front, background], foreground: 1, now: now) == 1, "bounded six-frame interaction burst")
    busy.completed(1, unchanged: false, visible: true, now: now)
}
busy.interacted(1, now: 0.3)
check(busy.next([front, background], foreground: 1, now: 0.3) == 2, "continuous input does not starve background")
check(busy.borrowedInteractionSlots == 0, "default-off scheduler records no borrowed interaction slots")
busy.completed(2, unchanged: false, visible: true, now: 0.3)
check(busy.next([front, background], foreground: 1, now: 0.31) == 1, "active window resumes after fairness slot")
var urgent = HarmonyCaptureScheduler()
urgent.prioritizeInteraction = true
for tick in 0..<6 {
    let now = Double(tick) * 0.05
    urgent.interacted(1, now: now)
    check(urgent.next([front, background], foreground: 1, now: now) == 1, "candidate fills normal foreground burst")
    urgent.completed(1, unchanged: false, visible: true, now: now)
}
urgent.interacted(1, now: 0.30)
check(urgent.next([front, background], foreground: 1, now: 0.30) == 1,
      "candidate borrows one slot for the first post-budget interaction")
check(urgent.borrowedInteractionSlots == 1, "borrow counter records the candidate loan")
urgent.completed(1, unchanged: false, visible: true, now: 0.30)
check(urgent.next([front, background], foreground: 1, now: 0.31) == 2,
      "borrowed foreground slot is repaid by background before another capture")
urgent.completed(2, unchanged: false, visible: true, now: 0.31)
for tick in 0..<6 {
    let now = 0.32 + Double(tick) * 0.01
    urgent.interacted(1, now: now)
    _ = urgent.next([front, background], foreground: 1, now: now)
    urgent.completed(1, unchanged: false, visible: true, now: now)
}
urgent.interacted(1, now: 0.45)
check(urgent.next([front, background], foreground: 1, now: 0.45) == 1,
      "candidate permits another loan after background repayment and a fresh budget")
urgent.completed(1, unchanged: false, visible: true, now: 0.45)
urgent.interacted(1, now: 0.46)
check(urgent.next([front, background], foreground: 1, now: 0.46) == 2,
      "repeated input cannot borrow again before repayment")

var switchedDuringDebt = HarmonyCaptureScheduler()
switchedDuringDebt.prioritizeInteraction = true
for tick in 0..<6 {
    let now = Double(tick) * 0.05
    switchedDuringDebt.interacted(1, now: now)
    _ = switchedDuringDebt.next([front, background], foreground: 1, now: now)
    switchedDuringDebt.completed(1, unchanged: false, visible: true, now: now)
}
switchedDuringDebt.interacted(1, now: 0.30)
check(switchedDuringDebt.next([front, background], foreground: 1, now: 0.30) == 1,
      "focus-switch debt fixture establishes one borrowed slot")
switchedDuringDebt.completed(1, unchanged: false, visible: true, now: 0.30)
switchedDuringDebt.interacted(2, now: 0.31)
check(switchedDuringDebt.next([front, background], foreground: 2, now: 0.43) == 1,
      "focus change cannot let a new foreground interaction bypass outstanding debt")

var firstImageRepaysDebt = HarmonyCaptureScheduler()
firstImageRepaysDebt.prioritizeInteraction = true
for tick in 0..<6 {
    let now = Double(tick) * 0.05
    firstImageRepaysDebt.interacted(1, now: now)
    _ = firstImageRepaysDebt.next([front, background], foreground: 1, now: now)
    firstImageRepaysDebt.completed(1, unchanged: false, visible: true, now: now)
}
firstImageRepaysDebt.interacted(1, now: 0.30)
_ = firstImageRepaysDebt.next([front, background], foreground: 1, now: 0.30)
firstImageRepaysDebt.completed(1, unchanged: false, visible: true, now: 0.30)
let repaymentImage = HarmonyCaptureScheduler.Candidate(id: 3, needsImage: true)
check(firstImageRepaysDebt.next([front, background, repaymentImage], foreground: 1, now: 0.31) == 3,
      "first-image priority may repay an outstanding interaction loan")
firstImageRepaysDebt.completed(3, unchanged: false, visible: true, now: 0.31)
let initializedImage = HarmonyCaptureScheduler.Candidate(id: 3, needsImage: false)
for tick in 0..<6 {
    let now = 0.32 + Double(tick) * 0.02
    firstImageRepaysDebt.interacted(1, now: now)
    check(firstImageRepaysDebt.next([front, background, initializedImage], foreground: 1, now: now) == 1,
          "foreground budget can rebuild after first-image repayment")
    firstImageRepaysDebt.completed(1, unchanged: false, visible: true, now: now)
}
firstImageRepaysDebt.interacted(1, now: 0.45)
check(firstImageRepaysDebt.next([front, background, initializedImage], foreground: 1, now: 0.45) == 1,
      "servicing any non-foreground image clears outstanding interaction debt")

var urgentPriority = HarmonyCaptureScheduler()
urgentPriority.prioritizeInteraction = true
for tick in 0..<6 {
    let now = Double(tick) * 0.05
    urgentPriority.interacted(1, now: now)
    _ = urgentPriority.next([front, background], foreground: 1, now: now)
    urgentPriority.completed(1, unchanged: false, visible: true, now: now)
}
urgentPriority.interacted(1, now: 0.30)
check(urgentPriority.next([front, background, newWindow], foreground: 1, now: 0.30) == 3,
      "initial image keeps priority over an extra post-budget interaction slot")

var urgentFailed = HarmonyCaptureScheduler()
urgentFailed.prioritizeInteraction = true
urgentFailed.failed(1, now: 0)
urgentFailed.interacted(1, now: 0.1)
check(urgentFailed.next([front, background], foreground: 1, now: 0.1) == 2,
      "urgent interaction does not bypass active-window retry backoff")
var urgentHidden = HarmonyCaptureScheduler()
urgentHidden.prioritizeInteraction = true
urgentHidden.suspendOccluded = true
urgentHidden.completed(1, unchanged: false, visible: false, now: 0)
urgentHidden.interacted(1, now: 0.1)
check(urgentHidden.next([.init(id: 1, needsImage: false, visible: false), background], foreground: 1, now: 0.1) == 2,
      "urgent interaction does not bypass hidden-window suspension")
var expired = HarmonyCaptureScheduler()
expired.interacted(1, now: 0)
check(expired.next([newWindow, front], foreground: 1, now: 1) == 3, "expired input does not jump priority")
var failed = HarmonyCaptureScheduler()
failed.failed(1, now: 0)
failed.interacted(1, now: 0.1)
check(failed.next([front, background], foreground: 1, now: 0.1) == 2, "input preserves failed-window retry backoff")
print("Harmony interaction capture scheduling passed")
var paced = HarmonyCaptureScheduler()
paced.paceForegroundIdle = true
paced.completed(1, unchanged: true, visible: true, now: 20)
check(paced.next([front], foreground: 1, now: 20.001) == nil, "unchanged shortcuts cannot spin unbounded captures")
check(paced.next([front], foreground: 1, now: 20.034) == 1, "idle foreground resumes on frame budget")
paced.completed(1, unchanged: true, visible: true, now: 21)
paced.interacted(1, now: 21.001)
check(paced.next([front], foreground: 1, now: 21.001) == 1, "input bypasses idle pacing")
paced.completed(1, unchanged: false, visible: true, now: 22)
check(paced.next([front], foreground: 1, now: 22) == 1, "changing animations retain completion-driven captures")

var throttle = HarmonyCaptureScheduler()
let covered = HarmonyCaptureScheduler.Candidate(id: 2, needsImage: false, visible: false)
throttle.completed(2, unchanged: false, visible: true, now: 30)
check(throttle.next([background], foreground: nil, now: 30.124) == nil, "changing background limited to eight capture opportunities/sec")
check(throttle.next([background], foreground: nil, now: 30.126) == 2, "changing visible background remains eligible")
throttle.completed(2, unchanged: false, visible: false, now: 31)
check(throttle.next([covered], foreground: nil, now: 31.79) == nil, "covered window throttled")
check(throttle.next([background], foreground: nil, now: 31.80) == 2, "exposure bypasses background timer")
throttle.completed(2, unchanged: true, visible: false, now: 32)
_ = throttle.next([covered], foreground: nil, now: 32.01)
throttle.failed(2, now: 32.01)
check(throttle.next([background], foreground: nil, now: 32.02) == nil, "exposure preserves failure backoff")
check(throttle.next([background], foreground: nil, now: 32.52) == 2, "exposure serviced after retry")
var switched = HarmonyCaptureScheduler()
for tick in 0..<6 { switched.interacted(1, now: Double(tick)*0.02); _ = switched.next([front,background], foreground: 1, now: Double(tick)*0.02) }
switched.interacted(2, now: 0.13)
check(switched.next([front,background], foreground: 2, now: 0.13) == 2, "new focus gets prompt capture despite old foreground streak")
print("Active burst, background throttling, exposure, focus and retry checks passed")

var sleeping = HarmonyCaptureScheduler()
sleeping.suspendOccluded = true
sleeping.completed(2, unchanged: false, visible: false, now: 40)
for time in [40.1, 41.0, 45.0] {
    check(sleeping.next([front, covered], foreground: 1, now: time) == 1,
          "covered initialized window never consumes an active capture slot")
    sleeping.completed(1, unchanged: false, visible: true, now: time)
}
check(sleeping.next([covered], foreground: 2, now: 46) == nil,
      "a stale key-window identity cannot keep a covered window capturing")
let hiddenNew = HarmonyCaptureScheduler.Candidate(id: 3, needsImage: true, visible: false)
check(sleeping.next([hiddenNew, front, covered], foreground: 1, now: 47) == 3,
      "first image can still initialize a not-yet-ordered proxy")
sleeping.completed(3, unchanged: false, visible: false, now: 47)
check(sleeping.next([front, background], foreground: 1, now: 48) == 2,
      "exposure refreshes immediately despite active-window budget")
sleeping.failed(2, now: 48)
check(sleeping.next([covered], foreground: nil, now: 48.1) == nil,
      "covered failed windows remain asleep")
check(sleeping.next([background], foreground: nil, now: 48.2) == nil,
      "exposure does not bypass an actual failed-capture retry")
check(sleeping.next([background], foreground: nil, now: 48.6) == 2,
      "exposure retries after failure backoff")
sleeping.invalidate(2)
check(sleeping.next([.init(id: 2, needsImage: true, visible: false)], foreground: nil, now: 49) == 2,
      "recreated window identity can obtain its first image")
print("Occluded suspension, initial painting, exposure and failure lifecycle passed")
