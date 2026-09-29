import Foundation
import CoreGraphics
import zlib

@main struct TileRegression {
    static func main() throws {
        let fixtures = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var offset = 0, count = 0
        func readWord() -> Int { defer { offset += 4 }; return (0..<4).reduce(0) { ($0 << 8) | Int(fixtures[offset + $1]) } }
        func take(_ n: Int) -> Data { defer { offset += n }; return Data(fixtures[offset..<offset+n]) }
        func packet(_ raw: Data, _ w: Int, _ h: Int, sequence: Int = 8) -> Data {
            var compressed = Data(count: Int(compressBound(uLong(raw.count))))
            var size = uLongf(compressed.count)
            let result = compressed.withUnsafeMutableBytes { out in raw.withUnsafeBytes { source in
                compress2(out.bindMemory(to: Bytef.self).baseAddress!, &size, source.bindMemory(to: Bytef.self).baseAddress!, uLong(raw.count), 1)
            } }
            precondition(result == Z_OK); compressed.count = Int(size)
            var p = Data("42 \(w) \(h) 4 \(sequence)\n".utf8)
            let n = UInt32(raw.count)
            p.append(contentsOf: [UInt8(truncatingIfNeeded: n >> 24), UInt8(truncatingIfNeeded: n >> 16), UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
            p.append(compressed); return p
        }
        while offset < fixtures.count {
            let w = readWord(), h = readWord(), n = readWord()
            let before = take(w*h*4), after = take(w*h*4), tiles = take(n)
            let base = HarmonyWindowFrame.decode(Data("42 \(w) \(h) 0 7\n".utf8) + before)!
            let p = packet(tiles,w,h)
            let decoded = HarmonyWindowFrame.decode(p,base:base)!
            precondition((decoded.image.dataProvider!.data! as Data) == after)
            precondition((base.image.dataProvider!.data! as Data) == before, "base must remain immutable")
            precondition(HarmonyWindowFrame.decode(p) == nil)
            precondition(HarmonyWindowFrame.decode(p,base:decoded) == nil)
            precondition(HarmonyWindowFrame.decode(p + Data([0]),base:base) == nil)
            precondition(HarmonyWindowFrame.decode(p.dropLast(),base:base) == nil)
            precondition(HarmonyWindowFrame.decode(packet(tiles,w+1,h),base:base) == nil)
            precondition(HarmonyWindowFrame.decode(packet(tiles,w,h,sequence:7),base:base) == nil)
            precondition(HarmonyWindowFrame.decode(p,base:.init(id:43,sequence:7,image:base.image)) == nil)
            var bad = tiles; bad[3] = 6
            precondition(HarmonyWindowFrame.decode(packet(bad,w,h),base:base) == nil)
            bad = tiles; bad[8] = 255 // out of bounds index
            precondition(HarmonyWindowFrame.decode(packet(bad,w,h),base:base) == nil)
            // No zero-count, duplicate or reordered tiles are accepted.
            bad = tiles; bad.replaceSubrange(4..<8, with: [0,0,0,0])
            precondition(HarmonyWindowFrame.decode(packet(bad,w,h),base:base) == nil)
            let tileCount = (0..<4).reduce(0) { ($0 << 8) | Int(tiles[4+$1]) }
            if tileCount > 1 {
                let first = (0..<4).reduce(0) { ($0 << 8) | Int(tiles[8+$1]) }
                let cols = (w+31)/32, x = first % cols * 32, y = first / cols * 32
                let secondOffset = 12 + min(32,w-x)*min(32,h-y)*4
                bad = tiles; bad.replaceSubrange(secondOffset..<secondOffset+4, with: tiles[8..<12])
                precondition(HarmonyWindowFrame.decode(packet(bad,w,h),base:base) == nil)
            }
            precondition(HarmonyWindowFrame.decode(packet(tiles + Data([0]),w,h),base:base) == nil)
            precondition(HarmonyWindowFrame.decode(packet(tiles.dropLast(),w,h),base:base) == nil)
            count += 1
        }
        print("PASS: \(count) cross-platform tile fixtures, exact pixels, immutable bases, stale/missing/wrong bases, resize and malformed payload rejection")
    }
}
