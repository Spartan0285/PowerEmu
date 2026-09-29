import AppKit
import Foundation
import Darwin

func harmonyDebug(_ message: String) {}

@main
struct HarmonyTransportRegression {
    @MainActor static func main() async throws {
        let path = NSTemporaryDirectory() + "pe-agent-test-" + UUID().uuidString
        let agent = GuestAgent(socketPath: path)
        agent.shareClipboard = false
        try agent.start()
        defer { agent.stop() }
        func connectClient() -> Int32 {
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
            withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array((path + "\0").utf8)) }
            let result = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
            }
            precondition(result == 0)
            return fd
        }
        func send(_ fd: Int32, _ verb: String, _ payload: String) {
            let packet = Data("\(verb) \(payload.utf8.count)\n\(payload)".utf8)
            let sent = packet.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            precondition(sent == packet.count)
        }
        let control = connectClient(); defer { close(control) }
        send(control, "HELLO", "2.8\t10.4.11\ttest")
        for _ in 0..<200 where !agent.connected { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(agent.connected)
        var bytes = [UInt8](repeating: 0, count: 1024)
        let size = recv(control, &bytes, bytes.count, MSG_DONTWAIT)
        precondition(size > 0)
        let reply = String(decoding: bytes.prefix(size), as: UTF8.self)
        let session = reply.split(separator: " ").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(UUID(uuidString: session) != nil)
        var frames = 0, focus = 0, fullscreen = 0, menuFocus = 0
        agent.onMenuFocus = { token, id in precondition(token == "test-menu" && id == 42); menuFocus += 1 }
        agent.onWindowFrame = { _ in frames += 1 }
        agent.onGuestFullscreen = { fullscreen += 1 }
        agent.onFocused = { _ in focus += 1 }
        let image = connectClient(); defer { close(image) }
        send(image, "FRAMEHELLO", session)
        send(image, "WINDOWFRAME", "42 0 0 0 1\n")
        send(control, "FOCUSED", "42")
        for _ in 0..<200 where frames < 1 || focus < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(frames == 1 && focus == 1 && agent.connected, "frame connection must preserve control")
        send(image, "WINDOWFRAME", "42 0 0 0 2\n")
        for _ in 0..<200 where frames < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(frames == 2, "image connection must persist")
        send(image, "FULLSCREEN", "captured")
        send(control, "FULLSCREEN", "unknown")
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(fullscreen == 0, "only recognized control reports may exit Harmony")
        send(control, "FULLSCREEN", "captured")
        for _ in 0..<200 where fullscreen < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(fullscreen == 1)
        send(image, "MENUFOCUS", "test-menu 42")
        send(control, "MENUFOCUS", "test-menu -1")
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(menuFocus == 0)
        send(control, "MENUFOCUS", "test-menu 42")
        for _ in 0..<200 where menuFocus < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(menuFocus == 1)
        var fileResults = 0, disconnects = 0
        agent.onFileTransfer = { fields in
            precondition(fields["request"] as? String == "transfer-test")
            precondition(fields["name"] as? String == "Résumé\nfile")
            fileResults += 1
        }
        agent.onDisconnect = { disconnects += 1 }
        let plist = try PropertyListSerialization.data(fromPropertyList: ["request": "transfer-test", "name": "Résumé\nfile"], format: .xml, options: 0)
        let xml = String(decoding: plist, as: UTF8.self)
        send(image, "FILERESULT", xml)
        send(control, "FILERESULT", "malformed")
        try await Task.sleep(nanoseconds: 50_000_000)
        precondition(fileResults == 0)
        send(control, "FILERESULT", xml)
        for _ in 0..<200 where fileResults < 1 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(fileResults == 1)
        let foreign = connectClient()
        send(foreign, "FRAMEHELLO", UUID().uuidString)
        send(foreign, "WINDOWFRAME", "42 0 0 0 3\n")
        try await Task.sleep(nanoseconds: 100_000_000)
        close(foreign)
        precondition(frames == 2 && agent.connected, "reject a stale frame session without dropping control")
        var dragIDs: Set<Int> = []
        var geometrySawDecoration = false
        agent.onDragWindows = { dragIDs = $0 }
        agent.onWindows = { _ in geometrySawDecoration = dragIDs == [321] }
        send(control, "DRAGWINDOWS", "321;-1;bad;")
        send(control, "WINDOWS", "321,10,10,32,32,10,10,32,32;")
        for _ in 0..<200 where !geometrySawDecoration { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(geometrySawDecoration, "drag decoration classification must arrive before proxy geometry")
        send(control, "DRAGWINDOWS", "")
        for _ in 0..<200 where !dragIDs.isEmpty { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(dragIDs.isEmpty, "ending a drag clears decoration IDs")
        print("PASS: drag image classification precedes geometry; invalid IDs rejected; dismissal clears IDs")
        let replacement = connectClient(); defer { close(replacement) }
        send(replacement, "HELLO", "2.8\t10.4.11\treconnected")
        try await Task.sleep(nanoseconds: 100_000_000)
        let replacementSize = recv(replacement, &bytes, bytes.count, MSG_DONTWAIT)
        precondition(replacementSize > 0 && agent.connected, "control reconnect must survive the retired connection's close callback")
        let replacementReply = String(decoding: bytes.prefix(replacementSize), as: UTF8.self)
        let replacementSession = replacementReply.split(separator: " ").last!.trimmingCharacters(in: .whitespacesAndNewlines)
        precondition(replacementSession != session && UUID(uuidString: replacementSession) != nil)
        send(replacement, "FOCUSED", "43")
        for _ in 0..<200 where focus < 2 { try await Task.sleep(nanoseconds: 5_000_000) }
        precondition(focus == 2 && agent.connected)
        precondition(disconnects == 1, "transfer cancellation must run on control replacement")
        print("PASS: persistent image transport, simultaneous control, stale session rejection, control reconnect")
    }
}
