import Foundation
import Darwin

/// Framed transport for one guest-agent socket.
///
/// Writes are queued off the caller's thread, kept in FIFO order, bounded to
/// 8 MiB of pending frames, and given one absolute deadline per frame. The
/// protocol accepts frames up to 70 MB when reading, but host control traffic
/// is intentionally limited to the smaller queue bound. A timed-out or
/// partial write closes the stream so no later frame can follow a truncated
/// one.
final class AgentConnection: @unchecked Sendable {
    private struct OutboundFrame {
        let bytes: Data
        let deadline: UInt64
    }

    let fd: Int32

    private let source: DispatchSourceRead
    private let readQueue: DispatchQueue
    private let writeQueue: DispatchQueue
    private let lock = NSLock()
    private let onMessage: @Sendable (String, Data) -> Void
    private let onClose: @Sendable () -> Void
    private let writeTimeout: TimeInterval
    private let maxQueuedBytes: Int
    private let maxQueuedFrames: Int

    // `inbox` is only touched by the source's serial read queue.
    private var inbox = Data()
    // The following state is protected by `lock`.
    private var closed = false
    private var queuedFrames: [OutboundFrame] = []
    private var queuedBytes = 0
    private var writerScheduled = false

    init(fd: Int32, writeTimeout: TimeInterval = 1.0, maxQueuedBytes: Int = 8 * 1024 * 1024,
         maxQueuedFrames: Int = 512,
         onMessage: @escaping @Sendable (String, Data) -> Void,
         onClose: @escaping @Sendable () -> Void) {
        self.fd = fd
        self.writeTimeout = max(0.01, writeTimeout)
        self.maxQueuedBytes = max(1, maxQueuedBytes)
        self.maxQueuedFrames = max(1, maxQueuedFrames)
        self.onMessage = onMessage
        self.onClose = onClose
        readQueue = DispatchQueue(label: "poweremu.agent.read.\(fd)")
        writeQueue = DispatchQueue(label: "poweremu.agent.write.\(fd)")

        let flags = fcntl(fd, F_GETFL)
        let nonblockingReady = flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))

        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: readQueue)
        // The cancel handler runs after any active read handler. Defer close
        // onto the writer queue too, after active writers/polls have exited;
        // the descriptor cannot be reused underneath a delayed writer.
        source.setCancelHandler { [writeQueue, fd, onClose] in
            writeQueue.async { Darwin.close(fd) }
            // Dispatch cancellation follows any active read handler, so all
            // frames it enqueued reach main before this one-shot disconnect.
            DispatchQueue.main.async { onClose() }
        }
        source.setEventHandler { [weak self] in self?.readAvailable() }
        if nonblockingReady {
            source.resume()
        } else {
            // Cancel before the read source can run with a blocking fd. Resume
            // afterward so DispatchSource can deliver its cancel handler.
            close()
            source.resume()
        }
    }

    deinit { close() }

    func send(_ verb: String, _ payload: Data) {
        guard !verb.isEmpty, !verb.contains(" "), !verb.contains("\n"), !verb.contains("\r") else {
            close(); return
        }
        var frame = Data("\(verb) \(payload.count)\n".utf8)
        frame.append(payload)

        lock.lock()
        guard !closed else { lock.unlock(); return }
        guard frame.count <= maxQueuedBytes, queuedBytes <= maxQueuedBytes - frame.count,
              queuedFrames.count < maxQueuedFrames else {
            lock.unlock()
            close()
            return
        }
        let deadline = DispatchTime.now().uptimeNanoseconds &+ UInt64(writeTimeout * 1_000_000_000)
        queuedFrames.append(OutboundFrame(bytes: frame, deadline: deadline))
        queuedBytes += frame.count
        let scheduleWriter = !writerScheduled
        if scheduleWriter { writerScheduled = true }
        lock.unlock()

        if scheduleWriter { writeQueue.async { [weak self] in self?.drainWrites() } }
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        queuedFrames.removeAll(keepingCapacity: false)
        queuedBytes = 0
        // Wake a read and a writer blocked in poll. O_NONBLOCK keeps every
        // actual socket operation short while the lock protects fd lifetime.
        _ = shutdown(fd, SHUT_RDWR)
        lock.unlock()

        source.cancel()
    }

    private func isClosed() -> Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    private func drainWrites() {
        while true {
            lock.lock()
            guard !closed else {
                queuedFrames.removeAll(keepingCapacity: false)
                queuedBytes = 0
                writerScheduled = false
                lock.unlock()
                return
            }
            guard let frame = queuedFrames.first else {
                writerScheduled = false
                lock.unlock()
                return
            }
            lock.unlock()

            guard writeFrame(frame) else { close(); return }

            lock.lock()
            guard !closed else {
                lock.unlock()
                return
            }
            queuedFrames.removeFirst()
            queuedBytes -= frame.bytes.count
            lock.unlock()
        }
    }

    private func writeFrame(_ frame: OutboundFrame) -> Bool {
        let deadline = frame.deadline
        return frame.bytes.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            var offset = 0
            while offset < raw.count {
                if isClosed() { return false }
                let current = DispatchTime.now().uptimeNanoseconds
                guard current < deadline else { return false }
                let remainingNanos = deadline - current
                let waitMillis = Int32(max(1, min(Int64(Int32.max),
                    Int64((remainingNanos + 999_999) / 1_000_000))))
                var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&descriptor, 1, waitMillis)
                if ready < 0 {
                    if errno == EINTR { continue }
                    return false
                }
                if ready == 0 { return false }
                if descriptor.revents & Int16(POLLERR | POLLHUP | POLLNVAL) != 0 { return false }
                guard descriptor.revents & Int16(POLLOUT) != 0 else { continue }
                // poll may return at the edge of the deadline; do not start
                // another syscall after the frame's absolute write budget.
                if DispatchTime.now().uptimeNanoseconds >= deadline { return false }

                lock.lock()
                guard !closed else { lock.unlock(); return false }
                guard DispatchTime.now().uptimeNanoseconds < deadline else { lock.unlock(); return false }
                let written = Darwin.write(fd, base.advanced(by: offset), raw.count - offset)
                let writeError = errno
                lock.unlock()
                if written > 0 { offset += written; continue }
                if written < 0 && (writeError == EINTR || writeError == EAGAIN || writeError == EWOULDBLOCK) { continue }
                return false
            }
            return true
        }
    }

    private func readAvailable() {
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            lock.lock()
            guard !closed else { lock.unlock(); return }
            let count = Darwin.read(fd, &buffer, buffer.count)
            let readError = errno
            lock.unlock()

            if count == 0 { close(); return }
            if count < 0 {
                if readError == EINTR { continue }
                if readError == EAGAIN || readError == EWOULDBLOCK { return }
                close(); return
            }
            inbox.append(contentsOf: buffer[0..<count])
            let parsed = frames()
            if isClosed() { return }
            for (verb, payload) in parsed {
                DispatchQueue.main.async { [onMessage] in onMessage(verb, payload) }
            }
        }
    }

    /// Complete frames in the inbox, removed from it.
    private func frames() -> [(String, Data)] {
        var result: [(String, Data)] = []
        while true {
            guard let newline = inbox.firstIndex(of: 0x0a) else {
                // The header is the only part with a small size limit. Once
                // its declared payload length is known, a fragmented payload
                // may legitimately leave more than 128 bytes buffered.
                if inbox.count > 128 { inbox.removeAll(); close() }
                return result
            }
            guard inbox.distance(from: inbox.startIndex, to: newline) <= 128 else {
                inbox.removeAll(); close(); return []
            }
            let head = String(decoding: inbox[inbox.startIndex..<newline], as: UTF8.self).split(separator: " ")
            guard head.count == 2, let size = Int(head[1]), (0...70_000_000).contains(size) else {
                inbox.removeAll(); close(); return []
            }
            if head[0] == "APPPATHICON", size > 4 * 1024 * 1024 + 4097 {
                inbox.removeAll(); close(); return []
            }
            let start = inbox.index(after: newline)
            guard inbox.distance(from: start, to: inbox.endIndex) >= size else { return result }
            let end = inbox.index(start, offsetBy: size)
            result.append((String(head[0]), Data(inbox[start..<end])))
            inbox = Data(inbox[end...])
        }
    }
}
