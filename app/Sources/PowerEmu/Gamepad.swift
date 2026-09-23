import Foundation
import GameController

/*
 * A game controller of this Mac, given to the virtual Mac as a plain USB
 * gamepad.
 *
 * The controller itself stays on this Mac: an Xbox or PlayStation pad
 * speaks its own language over Bluetooth, which Mac OS X 10.4 knows
 * nothing about, and macOS already understands all of them.  PowerEmu
 * reads it here and sends the stick and button positions to the emulator,
 * which presents an ordinary USB gamepad to the guest -- the kind any Mac
 * of that age recognises with no driver at all.
 *
 * The emulator's gamepad connects to this socket and reads reports: a
 * fixed-size packet whenever anything moves, and one every so often
 * regardless, so a guest that polls always has something recent.
 */
@MainActor
final class GamepadServer: ObservableObject {
    /// What the guest is shown: nil when no controller is connected here.
    @Published private(set) var controllerName: String?

    let socketPath: String
    private var listenFD: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var conn: Int32 = -1
    private var watch: [NSObjectProtocol] = []
    private var current = GamepadReport()

    init(socketPath: String) {
        self.socketPath = socketPath
    }

    // MARK: this Mac's controllers

    func start() throws {
        try listen()
        let c = NotificationCenter.default
        watch.append(c.addObserver(forName: .GCControllerDidConnect, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.adopt(n.object as? GCController) }
        })
        watch.append(c.addObserver(forName: .GCControllerDidDisconnect, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropped() }
        })
        GCController.controllers().forEach(adopt)
        GCController.startWirelessControllerDiscovery {}
    }

    func stop() {
        watch.forEach(NotificationCenter.default.removeObserver)
        watch.removeAll()
        if conn >= 0 { close(conn); conn = -1 }
        acceptSource?.cancel()
        acceptSource = nil
        if listenFD >= 0 { close(listenFD); listenFD = -1 }
        unlink(socketPath)
        controllerName = nil
    }

    private func adopt(_ c: GCController?) {
        guard let c, let pad = c.extendedGamepad else { return }
        controllerName = c.vendorName ?? "Game Controller"
        pad.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated { self?.changed(pad) }
        }
        changed(pad)
    }

    private func dropped() {
        guard GCController.controllers().isEmpty else { return }
        controllerName = nil
        current = GamepadReport()          // sticks centred, nothing held
        send()
    }

    private func changed(_ pad: GCExtendedGamepad) {
        current = GamepadReport(pad)
        send()
    }

    // MARK: the socket

    private func listen() throws {
        unlink(socketPath)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(socketPath.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: addr.sun_path) else { close(fd); throw POSIXError(.ENAMETOOLONG) }
        withUnsafeMutableBytes(of: &addr.sun_path) { buf in for (i, b) in bytes.enumerated() { buf[i] = b } }
        let ok = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard ok == 0, Foundation.listen(fd, 2) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listenFD = fd
        let src = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        src.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept() } }
        src.resume()
        acceptSource = src
    }

    private func accept() {
        let fd = Foundation.accept(listenFD, nil, nil)
        guard fd >= 0 else { return }
        if conn >= 0 { close(conn) }
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        conn = fd
        send()                              // the guest starts from where the pad is
    }

    private func send() {
        guard conn >= 0 else { return }
        let d = current.bytes
        let n = d.withUnsafeBytes { write(conn, $0.baseAddress, $0.count) }
        if n < 0 && errno != EAGAIN && errno != EINTR {
            close(conn)
            conn = -1
        }
    }
}

/*
 * One reading of the controller, in the shape the emulated gamepad sends
 * to the guest: sticks and triggers as bytes with 128 in the middle, a
 * hat for the direction pad, and one bit per button.
 */
struct GamepadReport {
    var lx: UInt8 = 128, ly: UInt8 = 128
    var rx: UInt8 = 128, ry: UInt8 = 128
    var lt: UInt8 = 0, rt: UInt8 = 0
    var hat: UInt8 = 15                     // 15: nothing pressed
    var buttons: UInt16 = 0

    init() {}

    init(_ pad: GCExtendedGamepad) {
        lx = Self.axis(pad.leftThumbstick.xAxis.value)
        ly = Self.axis(-pad.leftThumbstick.yAxis.value)     // down is larger
        rx = Self.axis(pad.rightThumbstick.xAxis.value)
        ry = Self.axis(-pad.rightThumbstick.yAxis.value)
        lt = UInt8(max(0, min(255, pad.leftTrigger.value * 255)))
        rt = UInt8(max(0, min(255, pad.rightTrigger.value * 255)))
        let up = pad.dpad.up.isPressed, down = pad.dpad.down.isPressed
        let left = pad.dpad.left.isPressed, right = pad.dpad.right.isPressed
        hat = Self.hat(up: up, right: right, down: down, left: left)
        var b: UInt16 = 0
        func set(_ bit: Int, _ on: Bool) { if on { b |= UInt16(1) << bit } }
        set(0, pad.buttonA.isPressed)
        set(1, pad.buttonB.isPressed)
        set(2, pad.buttonX.isPressed)
        set(3, pad.buttonY.isPressed)
        set(4, pad.leftShoulder.isPressed)
        set(5, pad.rightShoulder.isPressed)
        set(6, pad.leftTrigger.isPressed)
        set(7, pad.rightTrigger.isPressed)
        set(8, pad.buttonOptions?.isPressed ?? false)
        set(9, pad.buttonMenu.isPressed)
        set(10, pad.leftThumbstickButton?.isPressed ?? false)
        set(11, pad.rightThumbstickButton?.isPressed ?? false)
        // The direction pad again, as buttons: some games of the age read
        // only buttons and would miss the hat entirely.
        set(12, up)
        set(13, right)
        set(14, down)
        set(15, left)
        buttons = b
    }

    /// -1...1 to a byte with the middle at 128, with a small dead zone so a
    /// worn stick doesn't drift in the guest.
    private static func axis(_ v: Float) -> UInt8 {
        let dead: Float = 0.08
        let x = abs(v) < dead ? 0 : (v - (v > 0 ? dead : -dead)) / (1 - dead)
        return UInt8(max(0, min(255, (x + 1) * 127.5)))
    }

    /// The direction pad as a hat: 0 is up, then clockwise in eighths.
    private static func hat(up: Bool, right: Bool, down: Bool, left: Bool) -> UInt8 {
        switch (up, right, down, left) {
        case (true, false, false, false):  return 0
        case (true, true, false, false):   return 1
        case (false, true, false, false):  return 2
        case (false, true, true, false):   return 3
        case (false, false, true, false):  return 4
        case (false, false, true, true):   return 5
        case (false, false, false, true):  return 6
        case (true, false, false, true):   return 7
        default:                           return 15
        }
    }

    /// What goes down the socket, and on to the guest.
    var bytes: Data {
        Data([lx, ly, rx, ry, lt, rt, hat,
              UInt8(buttons & 0xFF), UInt8(buttons >> 8)])
    }
}
