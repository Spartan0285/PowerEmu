import Foundation
import SystemConfiguration

/*
 * Putting a virtual Mac directly on to the network.
 *
 * With the ordinary private network the guest sits behind the emulator: it
 * can reach out, nothing can reach in, and Bonjour -- which is how Macs
 * find each other -- never crosses the boundary.  Bridged, the guest gets
 * its own address from the same router as this Mac and behaves like any
 * other machine on the network: it appears in other people's Finders, and
 * other Macs appear in its own.
 *
 * macOS only lets root attach to a network interface that way, so PowerEmu
 * does not do it itself.  A small helper does nothing but carry ethernet
 * frames between the network and a socket the emulator reads; it is the
 * only piece that runs with privilege, and it is asked for by name each
 * time a bridged machine starts.
 *
 * The private network stays alongside it, because PowerEmu Tools, shared
 * folders, the clipboard and the clock all reach this Mac over it.  The
 * guest therefore has two network cards: one to the world, one to here.
 */
@MainActor
final class NetBridge: ObservableObject {
    /// A network interface of this Mac that a guest could be bridged on to.
    struct Interface: Identifiable, Hashable {
        let bsdName: String         // "en0"
        let label: String           // "Wi-Fi"
        var id: String { bsdName }
    }

    @Published private(set) var running = false
    @Published private(set) var problem: String?
    /// The address the network gave us for the guest, so the guest's card
    /// and the bridge agree and the network sees one machine.
    @Published private(set) var macAddress: String?

    private var task: Process?

    /// What this Mac is connected to, as System Settings names it.
    static func interfaces() -> [Interface] {
        guard let all = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [] }
        return all.compactMap { i in
            guard let bsd = SCNetworkInterfaceGetBSDName(i) as String?,
                  let kind = SCNetworkInterfaceGetInterfaceType(i) as String? else { return nil }
            // Wired and wireless only: bridging a virtual interface makes
            // no sense, and Thunderbolt bridges confuse more than they help.
            guard kind == (kSCNetworkInterfaceTypeEthernet as String)
                    || kind == (kSCNetworkInterfaceTypeIEEE80211 as String) else { return nil }
            let label = (SCNetworkInterfaceGetLocalizedDisplayName(i) as String?) ?? bsd
            return Interface(bsdName: bsd, label: label)
        }
    }

    /// The helper that ships inside PowerEmu.
    static var helperURL: URL? {
        let inBundle = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/poweremu-netd")
        if FileManager.default.isExecutableFile(atPath: inBundle.path) { return inBundle }
        // Running from the repository, before the app has been packaged.
        let dev = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("build/poweremu-netd")
        return FileManager.default.isExecutableFile(atPath: dev.path) ? dev : nil
    }

    /*
     * Start the helper, as an administrator.
     *
     * macOS asks for the password: PowerEmu never sees it, and the helper
     * is named in the dialog. It is deliberately asked for each time a
     * bridged machine starts rather than installed as something that runs
     * for ever -- a background program with root and a network interface is
     * not something to leave lying about without the reader knowing.
     */
    func start(interface: String, helperSocket: String, emulatorSocket: String,
               done: @escaping @MainActor (String?) -> Void) {
        guard let helper = Self.helperURL else {
            problem = "PowerEmu's network helper is missing."
            done(problem)
            return
        }
        problem = nil
        macAddress = nil
        let script = "do shell script \"" +
            [helper.path, interface, helperSocket, emulatorSocket, String(getuid())]
                .map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }
                .joined(separator: " ") +
            " > /dev/null 2>&1 &\" with administrator privileges"
        DispatchQueue.global().async {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", script]
            let err = Pipe()
            p.standardError = err
            do {
                try p.run()
            } catch {
                Task { @MainActor in
                    self.problem = error.localizedDescription
                    done(self.problem)
                }
                return
            }
            let text = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            p.waitUntilExit()
            let ok = p.terminationStatus == 0
            /*
             * The helper leaves the address the network gave it in a file
             * beside its socket; the guest's card is given the same one.
             * It appears a moment after the helper starts, so wait briefly
             * rather than racing it.
             */
            var mac: String?
            for _ in 0..<40 where mac == nil {
                mac = try? String(contentsOfFile: helperSocket + ".mac", encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if mac?.isEmpty == true { mac = nil }
                if mac == nil { usleep(50_000) }
            }
            Task { @MainActor in
                if ok {
                    self.running = true
                    self.macAddress = mac
                    done(nil)
                } else {
                    // "User canceled" is the usual one, and is not a fault.
                    self.problem = text.contains("-128") ? "Bridged networking needs an administrator."
                                                         : text.trimmingCharacters(in: .whitespacesAndNewlines)
                    done(self.problem)
                }
            }
        }
    }

    /// The helper exits by itself when the socket goes, but say so plainly.
    func stop(helperSocket: String) {
        running = false
        macAddress = nil
        try? FileManager.default.removeItem(atPath: helperSocket)
        try? FileManager.default.removeItem(atPath: helperSocket + ".mac")
    }
}
