import Foundation
import CoreGraphics

@main
struct FrameDecodeBenchmark {
    static func main() throws {
        let packet = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
        let expected = HarmonyWindowFrame.decode(packet)!
        let pixels = expected.image.dataProvider!.data! as Data
        var timings: [Double] = []
        for _ in 0..<100 {
            autoreleasepool {
                let began = CFAbsoluteTimeGetCurrent()
                let frame = HarmonyWindowFrame.decode(packet)!
                timings.append((CFAbsoluteTimeGetCurrent() - began) * 1000)
                precondition((frame.image.dataProvider!.data! as Data) == pixels)
            }
        }
        timings.sort()
        print(String(format: "PASS: host decode identical pixels, %dx%d medianMS=%.3f p95MS=%.3f", expected.image.width, expected.image.height, timings[50], timings[95]))
    }
}
