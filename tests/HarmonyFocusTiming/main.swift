import Foundation
var off = HarmonyFocusTiming(enabled: false)
off.begin(id: 1, sequence: 1, now: 0)
off.acknowledge(id: 1, sequence: 1, ok: true, queuedEvents: 1, now: 1)
precondition(off.finish().isEmpty)
var on = HarmonyFocusTiming(enabled: true)
on.begin(id: 1, sequence: 1, now: 1)
on.begin(id: 2, sequence: 2, now: 2)
on.acknowledge(id: 1, sequence: 1, ok: true, queuedEvents: 2, now: 3)
precondition(on.rows.isEmpty && on.superseded == 1)
on.acknowledge(id: 2, sequence: 2, ok: false, queuedEvents: 3, now: 2.125)
precondition(on.rows.count == 1 && on.rows[0].milliseconds == 125 && !on.rows[0].ok && on.rows[0].queuedEvents == 3)
for i in 0..<300 {
    on.begin(id: 2, sequence: i, now: Double(i))
    on.acknowledge(id: 2, sequence: i, ok: true, queuedEvents: 0, now: Double(i) + 0.001)
}
precondition(on.rows.count == 256 && on.dropped == 45)
precondition(on.finish().count == 257 && on.rows.isEmpty && on.dropped == 0)
print("PASS focus timing: disabled, identity, supersession, duration, bounded capacity, flush")
