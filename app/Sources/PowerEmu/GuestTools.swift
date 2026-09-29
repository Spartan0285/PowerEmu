import Foundation

/// What PowerEmu knows about the copy of PowerEmu Tools inside a virtual Mac:
/// which version is installed, which one this copy of PowerEmu carries, and
/// therefore whether it is worth offering an update.
enum GuestTools {
    /// The version on the Tools disc inside this app.  Kept in step with
    /// PE_AGENT_VERSION in guest/src/PEAgent.m -- scripts/build-app.sh refuses
    /// to build if the two ever drift apart.
    static let shippedVersion = "2.20"

    /// How the guest's tools compare with the ones this app carries.
    enum State: Equatable {
        case notInstalled
        case upToDate(String)
        case updateAvailable(installed: String, shipped: String)

        var needsAttention: Bool { self != .upToDate(GuestTools.shippedVersion) }
    }

    /// `installed` is what the agent said hello with, or nil if none answered.
    static func state(installed: String?) -> State {
        guard let installed, !installed.isEmpty, installed != "?" else { return .notInstalled }
        if compare(installed, shippedVersion) < 0 {
            return .updateAvailable(installed: installed, shipped: shippedVersion)
        }
        return .upToDate(installed)
    }

    /// Compare dotted versions a and b numerically: -1, 0 or 1.
    static func compare(_ a: String, _ b: String) -> Int {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }
        let y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l < r ? -1 : 1 }
        }
        return 0
    }
}
