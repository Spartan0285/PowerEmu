import Foundation

/// Answers PowerEmu Clock in the guest (guest/src/PEClock.c): every
/// newline it sends gets this Mac's time back as "SECONDS.MICROSECONDS\n".  The guest reaches
/// it at 10.0.2.100:7701 through a guestfwd rule and `nc -U` (VMRunner).
final class ClockServer: @unchecked Sendable {
    let socketPath: String
    private var listenFD: Int32 = -1

    init(socketPath: String) { self.socketPath = socketPath }

    func start() throws {
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
        guard ok == 0, listen(fd, 4) == 0 else { close(fd); throw POSIXError(.EADDRINUSE) }
        listenFD = fd
        let t = Thread {
            while true {
                let c = accept(fd, nil, nil)
                if c < 0 { if errno == EINTR { continue }; return }
                // Each byte the guest sends is a request; answer at once.
                DispatchQueue.global(qos: .userInteractive).async {
                    var b: UInt8 = 0
                    while read(c, &b, 1) == 1 {
                        guard b == 0x0a else { continue }
                        var tv = timeval()
                        gettimeofday(&tv, nil)
                        let s = String(format: "%ld.%06d\n", tv.tv_sec, tv.tv_usec)
                        if s.withCString({ write(c, $0, strlen($0)) }) <= 0 { break }
                    }
                    close(c)
                }
            }
        }
        t.name = "PowerEmu Clock"
        t.start()
    }

    func stop() {
        if listenFD >= 0 { shutdown(listenFD, SHUT_RDWR); close(listenFD); listenFD = -1 }
        unlink(socketPath)
    }
}
