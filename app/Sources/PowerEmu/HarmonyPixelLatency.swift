import Foundation
import CoreGraphics

/// Opt-in own-fixture pixel oracle. No claims about arbitrary application paint.
struct HarmonyPixelLatency {
    let enabled: Bool
    init(enabled: Bool = ProcessInfo.processInfo.environment["POWEREMU_PIXEL_LATENCY"] == "1") { self.enabled = enabled }
    private var target: Int?
    private var targetIdentity: ObjectIdentifier?
    private var invalidated = false
    private var sent = 0
    private var pending: [Int: Double] = [:]
    private var rows: [(Int, Double)] = []
    private var skipped = 0
    private var unpaired = 0
    static func counter(_ image: CGImage) -> Int? {
        guard image.width == 640, (400...440).contains(image.height), image.bitsPerPixel == 32,
              let data = image.dataProvider?.data, CFDataGetLength(data) >= image.bytesPerRow * image.height,
              let p = CFDataGetBytePtr(data) else { return nil }
        func byte(_ y: Int) -> Int? {
            guard y >= 0 && y < image.height else { return nil }
            var value = 0
            for i in 0..<8 {
                let offset = y * image.bytesPerRow + (40 + 80*i)*4
                let rgb = [p[offset],p[offset+1],p[offset+2]]
                guard p[offset+3] == 255 else { return nil }
                let dark = rgb.allSatisfy { $0 < 20 }
                guard dark || rgb.allSatisfy({ $0 > 235 }) else { return nil }
                value = (value << 1) | (dark ? 1 : 0)
            }
            return value
        }
        var found = Set<Int>()
        for y in 0..<image.height where y < 48 || y >= image.height-48 {
            guard let magic = byte(y), magic == 0xa6 || magic == 0x59,
                  byte(y+1) == magic, byte(y+2) == magic else { continue }
            for body in [y-200,y+200] {
                guard let value = byte(body), byte(body+1) == value else { continue }
                let count = value ^ (magic == 0x59 ? 255 : 0)
                if count & 1 == (magic == 0x59 ? 1 : 0) { found.insert(count) }
            }
        }
        return found.count == 1 ? found.first : nil
    }
    mutating func click(id: Int, identity: ObjectIdentifier, now: Double) {
        guard enabled, !invalidated, target == id, targetIdentity == identity, sent < 64 else { return }
        sent += 1; pending[sent] = now
    }
    mutating func observe(id: Int, identity: ObjectIdentifier, image: CGImage, now: Double) {
        guard enabled, !invalidated, let count = Self.counter(image) else { return }
        if target == nil, count == 0 { target = id; targetIdentity = identity }
        guard target == id else { return }
        guard targetIdentity == identity else { invalidated = true; return }
        if let start = pending.removeValue(forKey: count) {
            rows.append((count, max(0, now-start)*1000))
            for old in pending.keys.filter({ $0 < count }) { pending.removeValue(forKey: old); skipped += 1 }
        } else if count > sent, unpaired < Int.max { unpaired += 1 }
    }
    mutating func finish() -> [String] {
        guard enabled else { return [] }
        let result = ["PEPIXELLATENCY target=\(target ?? 0) sent=\(sent) rows=\(rows.count) skipped=\(skipped) pending=\(pending.count) unpaired=\(unpaired) invalidated=\(invalidated ? 1 : 0)"] + rows.map {
            String(format:"PEPIXELLATENCY counter=%d hostInputDispatchToDecodedFixtureCounterMS=%.3f",$0.0,$0.1)
        }
        target = nil; targetIdentity = nil; invalidated = false; sent = 0; pending.removeAll(); rows.removeAll(); skipped = 0; unpaired = 0
        return result
    }
}
