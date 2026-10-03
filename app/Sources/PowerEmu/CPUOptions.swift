import Foundation
import CryptoKit

/// Capability record shipped only with the tested SMP backend/firmware pair.
struct SMPCapabilities: Codable {
    let version: Int
    let backendSHA256: String
    let firmwareSHA256: String

    static func recordURL(helper: URL) -> URL {
        helper.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources").appendingPathComponent(helper.lastPathComponent + ".smp.json")
    }

    static func load(helper: URL?) -> SMPCapabilities? {
        guard let helper,
              let data = try? Data(contentsOf: recordURL(helper: helper)),
              let value = try? JSONDecoder().decode(Self.self, from: data), value.version == 1,
              [value.backendSHA256, value.firmwareSHA256].allSatisfy({
                  $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
              }) else { return nil }
        return value
    }

    func verify(helper: URL) throws {
        for (path, expected) in [
            ("Contents/MacOS/qemu-system-ppc", backendSHA256),
            ("Contents/Resources/firmware/openbios-ppc", firmwareSHA256)
        ] {
            guard let data = try? Data(contentsOf: helper.appendingPathComponent(path), options: .mappedIfSafe),
                  SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expected else {
                throw CPUOptions.Failure("The experimental emulator and firmware do not match this build. Restore the matching helper before starting the virtual Mac.")
            }
        }
    }
}

enum CPUOptions {
    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static func arguments(count: Int, smpCapable: Bool) throws -> [String] {
        /*
         * One, two or four.  KeyLargo's OpenPIC addresses four CPUs
         * (KEYLARGO_MAX_CPU) and mac99 now allows them; no real Core99 Mac
         * was more than dual, so four is past the hardware and whether a
         * guest enumerates them all is the guest's business.
         */
        guard [1, 2, 4].contains(count) else {
            throw Failure("Choose one, two or four CPUs for this virtual Mac.")
        }
        guard count == 1 || smpCapable else {
            throw Failure("More than one CPU requires the experimental emulator build. Choose one CPU to use this helper.")
        }
        var args = ["-smp", "cpus=\(count),sockets=\(count),cores=1,threads=1",
                    "-accel", count > 1 ? "tcg,thread=multi,tb-size=512" : "tcg,tb-size=512"]
        if smpCapable { args += ["-cpu", "7400"] }
        return args
    }
}
