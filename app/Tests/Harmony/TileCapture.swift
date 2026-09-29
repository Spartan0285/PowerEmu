import Foundation
import CoreGraphics

@main struct TileCaptureRegression {
    static func main() throws {
        let bytes = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        var offset = 0, run = 0, tileMS: [Double] = [], fullMS: [Double] = []
        func packet() -> Data {
            let n = (0..<4).reduce(0) { ($0 << 8) | Int(bytes[offset + $1]) }; offset += 4
            defer { offset += n }; return Data(bytes[offset..<offset+n])
        }
        while offset < bytes.count {
            let baseData = packet(), deltaData = packet(), fullData = packet()
            let base = HarmonyWindowFrame.decode(baseData)!
            let basePixels = base.image.dataProvider!.data! as Data
            let full = HarmonyWindowFrame.decode(fullData)!
            let delta = HarmonyWindowFrame.decode(deltaData, base: base)!
            precondition((delta.image.dataProvider!.data! as Data) == (full.image.dataProvider!.data! as Data))
            precondition((base.image.dataProvider!.data! as Data) == basePixels)
            let header = String(decoding: deltaData.prefix(80).split(separator: 10)[0], as: UTF8.self).split(separator: " ")
            precondition(Int(header[3]) == (run < 10 ? 4 : 1), "unexpected fallback in run \(run)")
            if run < 10 {
                for _ in 0..<20 {
                    autoreleasepool {
                        var start = ProcessInfo.processInfo.systemUptime
                        let d = HarmonyWindowFrame.decode(deltaData, base: base)!
                        tileMS.append((ProcessInfo.processInfo.systemUptime - start)*1000)
                        start = ProcessInfo.processInfo.systemUptime
                        let f = HarmonyWindowFrame.decode(fullData)!
                        fullMS.append((ProcessInfo.processInfo.systemUptime - start)*1000)
                        precondition((d.image.dataProvider!.data! as Data) == (f.image.dataProvider!.data! as Data))
                    }
                }
            }
            run += 1
        }
        tileMS.sort();fullMS.sort()
        print("PASS: \(run) actual Tiger capture triples; sparse updates, dense/resize/stale-base/legacy negotiation fallbacks; immutable bases")
        print(String(format:"Host decode median: tileMS=%.3f fullMS=%.3f",tileMS[tileMS.count/2],fullMS[fullMS.count/2]))
    }
}
