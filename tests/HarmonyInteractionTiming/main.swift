import Foundation
func check(_ yes: Bool) { if !yes { fputs("FAIL interaction timing\n", stderr); exit(1) } }
var t = HarmonyInteractionTiming(enabled: true)
t.dispatched(id: 1, sequence: 7, now: 1)
t.published(id: 1, sequence: 7, now: 1.1) // pre-input outstanding capture
check(t.rows.isEmpty)
t.published(id: 2, sequence: 8, now: 1.2)
check(t.rows.isEmpty)
t.published(id: 1, sequence: 9, now: 1.25)
check(t.rows == [250])
t.dispatched(id: 1, sequence: 10, now: 2)
t.dispatched(id: 2, sequence: 11, now: 3)
check(t.superseded == 1)
_ = t.finish()
t.published(id: 2, sequence: 12, now: 4)
check(t.rows.isEmpty) // no cross-session match
for i in 0..<257 { t.dispatched(id: 1, sequence: i, now: 0); t.published(id: 1, sequence: i+1, now: 1) }
check(t.rows.count == 256 && t.dropped == 1)
var off = HarmonyInteractionTiming(enabled: false)
off.dispatched(id: 1, sequence: 0, now: 0); off.published(id: 1, sequence: 1, now: 1)
check(off.rows.isEmpty && off.finish().isEmpty)
print("PASS interaction timing: post-request identity, session reset, bounded capacity, disabled")
