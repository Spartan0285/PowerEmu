import AVFoundation

/// A startup chime in the spirit of the PowerPC Macs': a bright F-major
/// chord that rings out.  Synthesized here - Apple's recording is theirs.
enum Chime {
    private static var player: AVAudioPlayer?

    static func play() {
        if player == nil, let data = makeWAV() {
            player = try? AVAudioPlayer(data: data)
        }
        player?.currentTime = 0
        player?.play()
    }

    private static func makeWAV() -> Data? {
        let rate = 44_100.0, seconds = 2.6
        let n = Int(rate * seconds)
        // F3 C4 F4 A4 C5, slightly detuned pairs for a chorus shimmer.
        let notes: [Double] = [174.61, 261.63, 349.23, 440.00, 523.25]
        var samples = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            let t = Double(i) / rate
            let attack = min(1, t / 0.012)
            let decay = exp(-t * 1.55)
            var l = 0.0, r = 0.0
            for (k, f) in notes.enumerated() {
                let amp = [0.30, 0.26, 0.22, 0.16, 0.12][k]
                for (h, ha) in [(1.0, 1.0), (2.0, 0.28), (3.0, 0.10)] {
                    let det = 1.0 + 0.0012 * Double(k % 2 == 0 ? 1 : -1)
                    l += amp * ha * sin(2 * .pi * f * h * t)
                    r += amp * ha * sin(2 * .pi * f * h * det * t)
                }
            }
            let g = 0.33 * attack * decay
            samples[2 * i] = Int16(max(-1, min(1, l * g)) * 32_000)
            samples[2 * i + 1] = Int16(max(-1, min(1, r * g)) * 32_000)
        }
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        let payload = samples.count * 2
        d.append("RIFF".data(using: .ascii)!); u32(UInt32(36 + payload)); d.append("WAVE".data(using: .ascii)!)
        d.append("fmt ".data(using: .ascii)!); u32(16); u16(1); u16(2); u32(UInt32(rate)); u32(UInt32(rate) * 4); u16(4); u16(16)
        d.append("data".data(using: .ascii)!); u32(UInt32(payload))
        samples.withUnsafeBytes { d.append(contentsOf: $0) }
        return d
    }
}
