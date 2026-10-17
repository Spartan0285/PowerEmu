import Foundation
import Darwin

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Data?
    func set(_ data: Data?) { lock.lock(); stored = data; lock.unlock() }
    var value: Data? { lock.lock(); defer { lock.unlock() }; return stored }
}

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}

private func pair() -> (Int32, Int32) {
    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { fatalError("socketpair failed: \(errno)") }
    return (fds[0], fds[1])
}

private func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func readExactly(_ fd: Int32, count: Int, timeout: TimeInterval = 3) -> Data? {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while result.count < count {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { return nil }
        let remaining = Int32(max(1, min(Int64(Int32.max), Int64((deadline - now + 999_999) / 1_000_000))))
        var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, remaining)
        if ready < 0 && errno == EINTR { continue }
        guard ready > 0, pfd.revents & Int16(POLLIN) != 0 else { return nil }
        let n = Darwin.read(fd, &buffer, min(buffer.count, count - result.count))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return nil }
        result.append(contentsOf: buffer[0..<n])
    }
    return result
}

private func waitForFDClosed(_ fd: Int32) -> Bool {
    waitFor({ fcntl(fd, F_GETFD) < 0 && errno == EBADF }, timeout: 2)
}

private func readAvailable(_ fd: Int32) -> Data {
    let oldFlags = fcntl(fd, F_GETFL)
    if oldFlags >= 0 { _ = fcntl(fd, F_SETFL, oldFlags | O_NONBLOCK) }
    var result = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    while true {
        let n = Darwin.read(fd, &buffer, buffer.count)
        if n > 0 { result.append(contentsOf: buffer[0..<n]); continue }
        if n < 0 && errno == EINTR { continue }
        break
    }
    return result
}

// The single writer preserves complete frame order.
do {
    let (host, peer) = pair()
    let closes = Counter()
    let connection = AgentConnection(fd: host, onMessage: { _, _ in }, onClose: { closes.increment() })
    let first = Data("ONE 3\nabc".utf8)
    let second = Data("TWO 3\ndef".utf8)
    connection.send("ONE", Data("abc".utf8))
    connection.send("TWO", Data("def".utf8))
    let received = readExactly(peer, count: first.count + second.count)
    check(received == first + second, "writer preserves FIFO framing")
    connection.close()
    check(waitFor({ closes.value == 1 }), "close notifies once")
    connection.close()
    check(closes.value == 1, "repeated close is idempotent")
    Darwin.close(peer)
}

// A stalled reader cannot block send's caller and the frame deadline closes
// the stream instead of allowing later frames after an incomplete write.
do {
    let (host, peer) = pair()
    var smallBuffer: Int32 = 4096
    _ = setsockopt(host, SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
    let closes = Counter()
    let connection = AgentConnection(fd: host, writeTimeout: 0.25, onMessage: { _, _ in }, onClose: { closes.increment() })
    let began = DispatchTime.now().uptimeNanoseconds
    connection.send("BULK", Data(repeating: 0x41, count: 2 * 1024 * 1024))
    let enqueueMillis = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000
    check(enqueueMillis < 100, "send returns promptly under socket backpressure")
    connection.send("LATE", Data("must not follow partial frame".utf8))
    check(waitFor({ closes.value == 1 }, timeout: 2), "stalled frame hits bounded write deadline")
    check(closes.value == 1, "late send does not notify twice")
    let buffered = readAvailable(peer)
    check(String(decoding: buffered, as: UTF8.self).hasPrefix("BULK 2097152\n"), "partial frame begins with its header")
    check(buffered.range(of: Data("LATE".utf8)) == nil, "queued frame does not follow a partial timed-out frame")
    Darwin.close(peer)
}

// The frame-count bound also limits allocations from many tiny messages.
do {
    let (host, peer) = pair()
    var smallBuffer: Int32 = 4096
    _ = setsockopt(host, SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
    let closes = Counter()
    let connection = AgentConnection(fd: host, writeTimeout: 1.0, maxQueuedFrames: 2,
                                     onMessage: { _, _ in }, onClose: { closes.increment() })
    connection.send("BULK", Data(repeating: 0x43, count: 2 * 1024 * 1024))
    connection.send("ONE", Data())
    connection.send("TWO", Data())
    check(waitFor({ closes.value == 1 }), "frame-count bound closes overflowed queue")
    Darwin.close(peer)
}

// A queued frame keeps the deadline from its enqueue time. The peer starts
// draining the first frame late, then stops; the second frame must expire on
// its original budget instead of receiving a fresh timeout after the first.
do {
    let (host, peer) = pair()
    var smallBuffer: Int32 = 4096
    _ = setsockopt(host, SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
    let closes = Counter()
    let firstRead = DataBox()
    let connection = AgentConnection(fd: host, writeTimeout: 1.0, onMessage: { _, _ in }, onClose: { closes.increment() })
    let firstPayload = Data(repeating: 0x44, count: 1024 * 1024)
    let firstFrame = Data("FIRST \(firstPayload.count)\n".utf8) + firstPayload
    let began = DispatchTime.now().uptimeNanoseconds
    connection.send("FIRST", firstPayload)
    connection.send("SECOND", Data(repeating: 0x45, count: 2 * 1024 * 1024))
    DispatchQueue.global().async {
        usleep(650_000)
        firstRead.set(readExactly(peer, count: firstFrame.count, timeout: 2))
    }
    check(waitFor({ closes.value == 1 }, timeout: 1.5), "queued frame expires on its enqueue-time deadline")
    let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1_000_000_000
    check(elapsed < 1.4, "queued frame does not receive a fresh full write timeout")
    check(waitFor({ firstRead.value != nil }), "first frame completed before queued-frame expiry")
    check(firstRead.value == firstFrame, "first frame remains intact before queued-frame expiry")
    Darwin.close(peer)
}

// Closing the peer after a partial write closes the whole framed connection.
do {
    let (host, peer) = pair()
    var smallBuffer: Int32 = 4096
    _ = setsockopt(host, SOL_SOCKET, SO_SNDBUF, &smallBuffer, socklen_t(MemoryLayout<Int32>.size))
    let closes = Counter()
    let connection = AgentConnection(fd: host, writeTimeout: 1.0, onMessage: { _, _ in }, onClose: { closes.increment() })
    connection.send("PARTIAL", Data(repeating: 0x42, count: 2 * 1024 * 1024))
    usleep(30_000)
    Darwin.close(peer)
    check(waitFor({ closes.value == 1 }), "partial write failure closes once")
}

// Malformed input, EOF and explicit close all converge on one close callback.
do {
    let (host, peer) = pair()
    let closes = Counter()
    let messages = Counter()
    let connection = AgentConnection(fd: host, onMessage: { _, _ in messages.increment() }, onClose: { closes.increment() })
    let malformed = Array("BROKEN\n".utf8)
    _ = malformed.withUnsafeBytes { Darwin.write(peer, $0.baseAddress!, $0.count) }
    check(waitFor({ closes.value == 1 }), "malformed frame closes")
    connection.close()
    Darwin.close(peer)
    check(closes.value == 1 && messages.value == 0, "malformed and explicit close notify exactly once")
}

// A late send after cancellation must not target a newly reused descriptor.
do {
    let (host, peer) = pair()
    let closes = Counter()
    let connection = AgentConnection(fd: host, onMessage: { _, _ in }, onClose: { closes.increment() })
    connection.close()
    check(waitFor({ closes.value == 1 }), "close callback delivered")
    check(waitForFDClosed(host), "fd closes after source and writer finish")
    var held: [(Int32, Int32)] = []
    var reused: (Int32, Int32)?
    for _ in 0..<128 {
        let candidate = pair()
        if candidate.0 == host || candidate.1 == host { reused = candidate; break }
        held.append(candidate)
    }
    connection.send("STALE", Data("must not hit reused fd".utf8))
    if let reused {
        var pfd = pollfd(fd: reused.0 == host ? reused.1 : reused.0, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, 100)
        check(ready == 0, "late send cannot write to a reused descriptor")
        Darwin.close(reused.0); Darwin.close(reused.1)
    }
    Darwin.close(peer)
    for (a, b) in held { Darwin.close(a); Darwin.close(b) }
}

print("PASS: FIFO frames, prompt bounded enqueue, timeout and partial-failure closure, malformed input, one-shot callbacks, and late sends after fd reuse")
