import AppKit
import Foundation
import Darwin

func harmonyDebug(_ message: String) {}

/// Exercises the production promise delegate and coordinator through the real
/// framed control socket. Finder invokes this same delegate after a drop.
@main struct FilePromiseTests {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let fm = FileManager.default, root = fm.temporaryDirectory.appendingPathComponent("PE-promises-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let name = "Document.txt", source = root.appendingPathComponent(name), archive = root.appendingPathComponent("source.zip")
        try Data("promised contents".utf8).write(to: source)
        try FileTransferArchive.pack(source, to: archive)
        let path = "/tmp/pe-promise-" + UUID().uuidString
        let agent = GuestAgent(socketPath: path); agent.shareClipboard = false; try agent.start()
        defer { agent.stop() }
        let transfers = GuestFileTransfer(root: root.appendingPathComponent("share")); transfers.agent = agent
        agent.onFileTransfer = { transfers.receive($0) }; agent.onDisconnect = { transfers.disconnected() }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array((path + "\0").utf8)) }
        let connected = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        precondition(connected == 0)
        let share = transfers.root
        DispatchQueue.global().async {
            defer { close(fd) }
            func send(_ verb: String, _ data: Data) {
                let packet = Data("\(verb) \(data.count)\n".utf8) + data
                packet.withUnsafeBytes { bytes in
                    var offset = 0
                    while offset < bytes.count {
                        let written = Darwin.send(fd, bytes.baseAddress! + offset, bytes.count - offset, 0)
                        precondition(written > 0)
                        offset += written
                    }
                }
            }
            send("HELLO", Data("2.14\t10.4.11\ttest".utf8))
            var buffer = Data(), exportCount = 0
            while true {
                var bytes = [UInt8](repeating: 0, count: 4096)
                let received = recv(fd, &bytes, bytes.count, 0)
                guard received > 0 else { return }
                buffer.append(contentsOf: bytes.prefix(received))
                while let nl = buffer.firstIndex(of: 10) {
                    let header = String(decoding: buffer.prefix(upTo: nl), as: UTF8.self).split(separator: " ")
                    let count = Int(header[1])!, start = nl + 1
                    guard buffer.count >= start + count else { break }
                    let data = buffer.subdata(in: start..<start+count)
                    buffer.removeSubrange(0..<start+count)
                    guard header[0] == "FILETRANSFER", let fields = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { continue }
                    var reply: [String: Any] = ["request": fields["request"]!]
                    if fields["action"] as? String == "selection" {
                        reply["entries"] = [["name": name, "directory": false], ["name": name, "directory": false]]
                    } else if fields["action"] as? String == "export" {
                        exportCount += 1
                        if exportCount > 2 { return }
                        let dir = share.appendingPathComponent(fields["token"] as! String)
                        try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                        try! FileManager.default.copyItem(at: archive, to: dir.appendingPathComponent("\(fields["index"] as! Int).zip"))
                    }
                    send("FILERESULT", try! PropertyListSerialization.data(fromPropertyList: reply, format: .xml, options: 0))
                }
            }
        }
        for _ in 0..<200 where !agent.connected { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(transfers.available)
        func prepare() async -> [NSDraggingItem] {
            await withCheckedContinuation { done in transfers.prepareDrag(window: 42) { done.resume(returning: $0) } }
        }
        func writePromises(_ items: [NSDraggingItem], prefix: String) async -> [Error?] {
            let expected = items.count
            return await withCheckedContinuation { done in
                var results = [Error?](repeating: nil, count: expected), completed = 0
                for (i, item) in items.enumerated() {
                    let provider = item.item as! NSFilePromiseProvider
                    precondition(provider.delegate?.filePromiseProvider(provider, fileNameForType: provider.fileType) == name)
                    provider.delegate!.filePromiseProvider(provider, writePromiseTo: root.appendingPathComponent("\(prefix)-\(i).txt")) { error in
                        MainActor.assumeIsolated {
                            results[i] = error; completed += 1
                            if completed == expected { done.resume(returning: results) }
                        }
                    }
                }
            }
        }
        let items = await prepare()
        precondition(items.count == 2)
        let success = await writePromises(items, prefix: "received")
        precondition(success.allSatisfy { $0 == nil })
        for i in 0..<2 { let data = try Data(contentsOf: root.appendingPathComponent("received-\(i).txt")); precondition(data == Data("promised contents".utf8)) }
        let interrupted = await prepare()
        let errors = await writePromises(interrupted, prefix: "interrupted")
        precondition(errors.count == 2 && errors.allSatisfy { $0 != nil })
        print("PASS: native promise delegates, receiver-selected names, serialized exports, active + queued disconnect completion")
    }
}
