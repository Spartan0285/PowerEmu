import Foundation
import AppKit
import Darwin

// GuestAgent only needs this value type from the larger Harmony menu system.
struct HarmonyMenuItem {
    let path: String
    let title: String
    let enabled: Bool
    let key: String
    let modifiers: Int
    let mark: String
    let hasSubmenu: Bool
}

// Test-only stubs for unrelated diagnostics and launch validation referenced
// by GuestAgent's complete source file.
func harmonyDebug(_ message: String) {}
enum GuestAppLaunchRequest {
    static func isValidGuestApplicationPath(_ path: String) -> Bool { path.hasPrefix("/") }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = 0
    func increment() { lock.lock(); stored += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return stored }
}

private func check(_ condition: Bool, _ message: String) {
    guard condition else { fputs("FAIL: \(message)\n", stderr); exit(EXIT_FAILURE) }
}

private func waitFor(_ predicate: () -> Bool, timeout: TimeInterval = 3) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return predicate()
}

private func connect(_ path: String) -> Int32 {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fputs("FAIL: socket failed: \(errno)\n", stderr); exit(EXIT_FAILURE) }
    var one: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8)
    guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else { fputs("FAIL: socket path too long\n", stderr); exit(EXIT_FAILURE) }
    withUnsafeMutableBytes(of: &address.sun_path) { buffer in
        for (index, byte) in bytes.enumerated() { buffer[index] = byte }
    }
    let status = withUnsafePointer(to: &address) {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard status == 0 else { Darwin.close(fd); fputs("FAIL: connect failed: \(errno)\n", stderr); exit(EXIT_FAILURE) }
    return fd
}

private func writeAll(_ fd: Int32, _ bytes: Data) {
    bytes.withUnsafeBytes { raw in
        guard let base = raw.baseAddress else { return }
        var offset = 0
        while offset < raw.count {
            let count = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { fputs("FAIL: write failed: \(errno)\n", stderr); exit(EXIT_FAILURE) }
            offset += count
        }
    }
}

private func sendFrame(_ fd: Int32, verb: String, payload: Data) {
    writeAll(fd, Data("\(verb) \(payload.count)\n".utf8) + payload)
}

private func readExactly(_ fd: Int32, count: Int, timeout: TimeInterval = 3) -> Data? {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while output.count < count {
        let now = DispatchTime.now().uptimeNanoseconds
        if now >= deadline { return nil }
        let remaining = Int32(max(1, min(100, Int64((deadline - now + 999_999) / 1_000_000))))
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&descriptor, 1, remaining)
        if ready < 0 && errno == EINTR { continue }
        if ready == 0 { continue }
        guard ready > 0, descriptor.revents & Int16(POLLIN) != 0 else { return nil }
        let n = Darwin.read(fd, &buffer, min(buffer.count, count - output.count))
        if n < 0 && errno == EINTR { continue }
        guard n > 0 else { return nil }
        output.append(contentsOf: buffer[0..<n])
    }
    return output
}

private func readFrame(_ fd: Int32, timeout: TimeInterval = 3) -> (String, Data)? {
    var header = Data()
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        guard let byte = readExactly(fd, count: 1, timeout: max(0.01, deadline.timeIntervalSinceNow))?.first else { return nil }
        if byte == 0x0a { break }
        header.append(byte)
        if header.count > 128 { return nil }
    }
    let pieces = String(decoding: header, as: UTF8.self).split(separator: " ")
    guard pieces.count == 2, let length = Int(pieces[1]), let payload = readExactly(fd, count: length, timeout: max(0.01, deadline.timeIntervalSinceNow)) else { return nil }
    return (String(pieces[0]), payload)
}

private func expectEOF(_ fd: Int32, timeout: TimeInterval = 2) -> Bool {
    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(timeout * 1_000_000_000)
    while DispatchTime.now().uptimeNanoseconds < deadline {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN | POLLHUP | POLLERR), revents: 0)
        let result = poll(&descriptor, 1, 10)
        if result < 0 && errno == EINTR { continue }
        if result > 0 {
            var byte: UInt8 = 0
            let n = Darwin.read(fd, &byte, 1)
            if n == 0 { return true }
            if n > 0 { return false }
            if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK { return false }
        }
    }
    return false
}

private func onIO<T>(_ work: @escaping () -> T) async -> T {
    await withCheckedContinuation { continuation in
        DispatchQueue.global(qos: .userInitiated).async { continuation.resume(returning: work()) }
    }
}

@MainActor
private func waitForAsync(_ predicate: @MainActor () -> Bool, timeout: TimeInterval = 3) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if predicate() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return predicate()
}

@MainActor
private func runIntegration() async throws {
    let socketPath = "/tmp/pe-agent-it-\(UUID().uuidString.prefix(8)).sock"
    let agent = GuestAgent(socketPath: socketPath)
    let disconnects = Counter()
    let screensReceived = Counter()
    agent.shareClipboard = false
    agent.onDisconnect = { disconnects.increment() }
    agent.onScreens = { _ in screensReceived.increment() }
    try agent.start()
    // An invalid first peer must be discarded without disturbing the listener.
    let malformed = connect(socketPath)
    writeAll(malformed, Data("NOT_A_FRAME\n".utf8))
    check(await onIO { expectEOF(malformed) }, "malformed first peer is closed")
    check(!agent.connected && disconnects.value == 0, "malformed peer does not create or disconnect a session")
    Darwin.close(malformed)

    // Split HELLO across header and payload writes to exercise real framing.
    let first = connect(socketPath)
    let firstPayload = Data("2.24\t10.4\tfirst-user".utf8)
    writeAll(first, Data("HEL".utf8))
    try await Task.sleep(for: .milliseconds(20))
    writeAll(first, Data("LO \(firstPayload.count)\n".utf8))
    let midpoint = firstPayload.count / 2
    writeAll(first, firstPayload.prefix(midpoint))
    try await Task.sleep(for: .milliseconds(20))
    check(!agent.connected, "partial payload is not delivered early")
    writeAll(first, firstPayload.dropFirst(midpoint))
    check(await waitForAsync({ agent.info?.user == "first-user" }), "complete first HELLO establishes session")
    guard let hello1 = await onIO({ readFrame(first) }), hello1.0 == "HELLO",
          String(decoding: hello1.1, as: UTF8.self).hasPrefix("PowerEmu 1 ") else {
        fputs("FAIL: host HELLO response missing\n", stderr); exit(EXIT_FAILURE)
    }

    // A known header may declare a payload larger than the header limit. Keep
    // it incomplete across reads after >128 bytes have arrived, then complete it.
    let screensPayload = Data(Array(repeating: "0,0,1728,1074", count: 24).joined(separator: ";").utf8)
    let screensFrame = Data("SCREENS \(screensPayload.count)\n".utf8) + screensPayload
    let headerEnd = screensFrame.firstIndex(of: 0x0a)! + 1
    let splitAt = headerEnd + 160
    writeAll(first, screensFrame.prefix(splitAt))
    try await Task.sleep(for: .milliseconds(80))
    check(agent.connected && disconnects.value == 0,
          "fragmented payload over 128 bytes does not close the control stream")
    writeAll(first, screensFrame.dropFirst(splitAt))
    check(await waitForAsync({ screensReceived.value == 1 }),
          "large fragmented payload is delivered after completion")

    let staleFrameChannel = connect(socketPath)
    sendFrame(staleFrameChannel, verb: "FRAMEHELLO", payload: Data("wrong-session".utf8))
    check(await onIO { expectEOF(staleFrameChannel) }, "mismatched frame session is rejected")
    check(agent.info?.user == "first-user" && disconnects.value == 0,
          "mismatched frame handshake leaves control session connected")
    Darwin.close(staleFrameChannel)

    // Reconnect establishes a new session and disconnects the old one once.
    let second = connect(socketPath)
    let secondPayload = Data("2.24\t10.4\tsecond-user".utf8)
    writeAll(second, Data("HELLO \(secondPayload.count)\n".utf8) + secondPayload)
    check(await waitForAsync({ agent.info?.user == "second-user" && disconnects.value == 1 }), "reconnect replaces the active session once")
    guard let hello2 = await onIO({ readFrame(second) }), hello2.0 == "HELLO" else { fputs("FAIL: second host HELLO response missing\n", stderr); exit(EXIT_FAILURE) }

    let staleFrameChannel2 = connect(socketPath)
    sendFrame(staleFrameChannel2, verb: "FRAMEHELLO", payload: Data("stale-session".utf8))
    check(await onIO { expectEOF(staleFrameChannel2) }, "mismatched frame session is rejected after reconnect")
    check(agent.info?.user == "second-user" && disconnects.value == 1,
          "mismatched frame handshake cannot replace the healthy control")
    Darwin.close(staleFrameChannel2)

    // The old socket's eventual close must not clear the new session.
    check(await onIO { expectEOF(first) }, "replaced first socket is closed")
    Darwin.close(first)
    check(await waitForAsync({ agent.info?.user == "second-user" }), "late old-session close leaves new session connected")
    check(disconnects.value == 1, "old-session close does not emit a second disconnect")

    // Only loss of the current connection disconnects the current session.
    Darwin.close(second)
    check(await waitForAsync({ !agent.connected && disconnects.value == 2 }), "active socket close disconnects exactly once")
    check(disconnects.value == 2, "active close callback remains one-shot")
    print("PASS: GuestAgent socket integration: malformed peer, split HELLO and >128-byte fragmented payload, reconnect ordering, mismatched FRAMEHELLO, and exactly-once active disconnect")
    agent.onDisconnect = nil
    agent.stop()
}

Task { @MainActor in
    do {
        try await runIntegration()
        exit(EXIT_SUCCESS)
    } catch {
        fputs("FAIL: \(error)\n", stderr)
        exit(EXIT_FAILURE)
    }
}
dispatchMain()
