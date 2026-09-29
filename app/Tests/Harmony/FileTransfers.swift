import Foundation

@main struct FileTransferTests {
    static func main() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("PE-transfer-test-" + UUID().uuidString)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("Résumé & notes\nfolder")
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Document")
        try Data("content".utf8).write(to: file)
        try Data("classic resource fork".utf8).write(to: URL(fileURLWithPath: file.path + "/..namedfork/rsrc"))
        let zip = root.appendingPathComponent("test.zip"), dest = root.appendingPathComponent("received")
        try FileTransferArchive.pack(source, to: zip)
        try FileTransferArchive.unpack(zip, name: source.lastPathComponent, to: dest)
        let data = try Data(contentsOf: dest.appendingPathComponent("Document")); precondition(data == Data("content".utf8))
        let fork = try Data(contentsOf: URL(fileURLWithPath: dest.path + "/Document/..namedfork/rsrc")); precondition(fork == Data("classic resource fork".utf8))
        do { try FileTransferArchive.unpack(zip, name: source.lastPathComponent, to: dest); fatalError("overwrote destination") } catch {}
        let singleZip = root.appendingPathComponent("single.zip"), single = root.appendingPathComponent("single")
        try FileTransferArchive.pack(file, to: singleZip)
        try FileTransferArchive.unpack(singleZip, name: file.lastPathComponent, to: single)
        let singleFork = try Data(contentsOf: URL(fileURLWithPath: single.path + "/..namedfork/rsrc"))
        precondition(singleFork == Data("classic resource fork".utf8))
        let link = root.appendingPathComponent("link")
        try fm.createSymbolicLink(at: link, withDestinationURL: file)
        do { try FileTransferArchive.pack(link, to: root.appendingPathComponent("link.zip")); fatalError("accepted link") } catch {}
        if CommandLine.arguments.count > 1 {
            let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
            for name in ["parent", "absolute", "symlink", "local-mismatch", "truncated"] {
                do { try FileTransferArchive.validate(fixtures.appendingPathComponent(name + ".zip"), name: "safe"); fatalError("accepted \(name)") } catch {}
            }
        }
        if CommandLine.arguments.count == 4 {
            let returned = root.appendingPathComponent("guest-return")
            try FileTransferArchive.unpack(URL(fileURLWithPath: CommandLine.arguments[2]), name: CommandLine.arguments[3], to: returned)
            let data = try Data(contentsOf: returned.appendingPathComponent("Document"))
            let fork = try Data(contentsOf: URL(fileURLWithPath: returned.path + "/Document/..namedfork/rsrc"))
            precondition(data == Data("host to Tiger data".utf8))
            precondition(fork == Data("resource fork round trip".utf8))
            print("PASS: Tiger ZIP extraction, original data and resource fork returned intact")
        }
        print("PASS: directory, Unicode/newline names, data/resource forks, collision refusal, symlink refusal, malformed archives")
    }
}
