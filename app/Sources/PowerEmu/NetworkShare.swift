import Foundation

/*
 * Putting a virtual Mac on the local network.
 *
 * A virtual Mac talks to the world through the emulator, which gives it a
 * private address of its own: it can reach out, but nothing on the network
 * can reach it, and it never appears in anyone's Finder.  That is the
 * right default -- an old Mac OS X with old software should not be exposed
 * to a network by surprise -- but it makes a virtual Mac an island.
 *
 * With sharing turned on, PowerEmu does two things.  It forwards a handful
 * of ports from this Mac into the virtual one, so a connection from
 * anywhere on the network reaches it.  And it announces those services
 * over Bonjour in this Mac's name, so the virtual Mac appears in the
 * sidebar of every Mac on the network, the way a real one would.
 *
 * The services still have to be switched on inside Mac OS X (System
 * Preferences, Sharing); announcing a service the guest isn't running only
 * produces a connection that is refused.
 */
@MainActor
final class NetworkShare: ObservableObject {
    /// What a virtual Mac can offer the network.
    struct Service: Identifiable, Hashable {
        var id: String { bonjourType }
        /// What Mac OS X calls it in System Preferences → Sharing.
        var name: String
        /// The port inside the virtual Mac.
        var guestPort: Int
        /// Where PowerEmu prefers to listen on this Mac.
        var preferredHostPort: Int
        var bonjourType: String

        static let all: [Service] = [
            .init(name: "Personal File Sharing", guestPort: 548, preferredHostPort: 5548,
                  bonjourType: "_afpovertcp._tcp."),
            .init(name: "Remote Login", guestPort: 22, preferredHostPort: 2222,
                  bonjourType: "_ssh._tcp."),
            .init(name: "Apple Remote Desktop", guestPort: 5900, preferredHostPort: 5950,
                  bonjourType: "_rfb._tcp."),
            .init(name: "Personal Web Sharing", guestPort: 80, preferredHostPort: 8080,
                  bonjourType: "_http._tcp."),
        ]
    }

    /// The ports this Mac listens on, once the machine has started.
    @Published private(set) var open: [Service: Int] = [:]
    /// What other Macs will see this machine called.
    @Published private(set) var advertisedName: String = ""

    private var published: [NetService] = []

    /// Decide the ports before the machine starts: the emulator needs them
    /// on its command line, and nothing else on this Mac may have them.
    func choosePorts(avoiding taken: Set<Int>) -> [Service: Int] {
        var used = taken
        var chosen: [Service: Int] = [:]
        for s in Service.all {
            let p = VMRunner.freePort(from: s.preferredHostPort, avoiding: nil)
            let port = used.contains(p) ? VMRunner.freePort(from: p + 1, avoiding: nil) : p
            used.insert(port)
            chosen[s] = port
        }
        open = chosen
        return chosen
    }

    /// Tell the network the machine is here.  The name is the machine's
    /// own, so a reader with several virtual Macs can tell them apart.
    func advertise(machineNamed name: String) {
        stop()
        advertisedName = name
        for (service, port) in open {
            let s = NetService(domain: "local.", type: service.bonjourType,
                               name: name, port: Int32(port))
            /*
             * Bonjour's own limits: a name that is already taken gets a
             * number added by the system, which is what a second machine of
             * the same name should do.
             */
            s.publish()
            published.append(s)
        }
    }

    func stop() {
        published.forEach { $0.stop() }
        published.removeAll()
        advertisedName = ""
    }
}
