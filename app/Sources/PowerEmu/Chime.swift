import AVFoundation

/// Startup chimes, synthesized here in the spirit of the classic Macs'
/// (Apple's recordings are theirs), or a sound file of the user's own.
enum Chime {
    private static var player: AVAudioPlayer?

    /// The choices offered in the settings: (setting, title).
    static let choices: [(String, String)] = [
        ("g4", "Bright chord (Power Mac G3/G4 style)"),
        ("warm", "Warm chord (Macintosh II style)"),
        ("bell", "Soft bell"),
        ("custom", "Sound file…"),
    ]

    private struct Voice {
        let notes: [Double], amps: [Double], harmonics: [(Double, Double)]
        let seconds: Double, decay: Double
    }

    private static let voices: [String: Voice] = [
        // F3 C4 F4 A4 C5: a bright F-major chord that rings out.
        "g4": Voice(notes: [174.61, 261.63, 349.23, 440.00, 523.25], amps: [0.30, 0.26, 0.22, 0.16, 0.12],
                    harmonics: [(1, 1), (2, 0.28), (3, 0.10)], seconds: 2.6, decay: 1.55),
        // C3 G3 C4 E4 G4: rounder, fewer overtones, a slower fade.
        "warm": Voice(notes: [130.81, 196.00, 261.63, 329.63, 392.00], amps: [0.30, 0.24, 0.22, 0.18, 0.12],
                      harmonics: [(1, 1), (2, 0.12)], seconds: 3.0, decay: 1.1),
        // E5 B5 E6 with inharmonic partials: a small bell.
        "bell": Voice(notes: [659.25, 987.77, 1318.51], amps: [0.34, 0.20, 0.10],
                      harmonics: [(1, 1), (2.76, 0.25), (5.4, 0.08)], seconds: 2.4, decay: 2.2),
    ]

    private static var cache: [String: Data] = [:]

    /// Play the chosen chime; a custom file that can't be read falls back to
    /// the default.
    static func play(_ kind: String = "g4", file: String? = nil) {
        var p: AVAudioPlayer?
        if kind == "custom", let file {
            p = try? AVAudioPlayer(contentsOf: URL(fileURLWithPath: file))
        }
        if p == nil {
            let k = voices[kind] == nil ? "g4" : kind
            if cache[k] == nil { cache[k] = makeWAV(voices[k]!) }
            if let d = cache[k] { p = try? AVAudioPlayer(data: d) }
        }
        player?.stop()
        player = p
        player?.play()
    }

    private static func makeWAV(_ v: Voice) -> Data? {
        let rate = 44_100.0, seconds = v.seconds
        let n = Int(rate * seconds)
        let notes = v.notes
        var samples = [Int16](repeating: 0, count: n * 2)
        for i in 0..<n {
            let t = Double(i) / rate
            let attack = min(1, t / 0.012)
            let decay = exp(-t * v.decay)
            var l = 0.0, r = 0.0
            for (k, f) in notes.enumerated() {
                let amp = v.amps[k]
                for (h, ha) in v.harmonics {
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
