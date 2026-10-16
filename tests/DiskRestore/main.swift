import Foundation

struct DiskConfig: Codable {
    var id = UUID()
    var file: String
    var label: String?
}
struct VMConfig: Codable {
    var name: String
    var osName = "Mac OS X 10.4 Tiger"
    var disks: [DiskConfig] = []
    var startupDisk: UUID?
    init(name: String) { self.name = name }
}
@MainActor final class VirtualMachine {
    let url: URL
    let config: VMConfig
    init(url: URL, config: VMConfig) { self.url = url; self.config = config }
    func save() throws {
        let data = try PropertyListEncoder().encode(config)
        try data.write(to: url.appendingPathComponent("config.plist"), options: .atomic)
    }
}

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError("FAIL: \(message)") }
}
func expectError(_ expected: String, _ action: () async throws -> Void) async {
    do { try await action(); fatalError("FAIL: expected \(expected)") }
    catch let error as DiskRestoreError {
        let actual: String
        switch error {
        case .installerDisc: actual = "installerDisc"
        case .volumeImage: actual = "volumeImage"
        case .unsupported: actual = "unsupported"
        case .invalidImage: actual = "invalidImage"
        case .backingFile: actual = "backingFile"
        case .cancelled: actual = "cancelled"
        case .process: actual = "process"
        case .invalidName: actual = "invalidName"
        case .packageExists: actual = "packageExists"
        }
        check(actual == expected, "expected \(expected), got \(actual)")
    } catch { fatalError("FAIL: expected \(expected), got \(error)") }
}

@main struct DiskRestoreTests {
    static func main() async throws {
        guard CommandLine.arguments.count == 2 else { fatalError("usage: tests <qemu-img>") }
        let qemuImg = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        let temp = fm.temporaryDirectory.appendingPathComponent("DiskRestoreTests-\(UUID().uuidString)")
        try fm.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? fm.removeItem(at: temp) }
        let library = temp.appendingPathComponent("VMs")
        try fm.createDirectory(at: library, withIntermediateDirectories: false)

        let raw = temp.appendingPathComponent("fixture.img")
        _ = try run(qemuImg, ["create", "-q", "-f", "raw", raw.path, "2M"])
        let restored = try await DiskRestoreService.restore(image: raw, name: "Restored", osName: "Sorbet test",
                                                           in: library, qemuImg: qemuImg,
                                                           operation: DiskRestoreOperation())
        check(restored.config.startupDisk == restored.config.disks.first?.id, "startup disk is assigned")
        let output = restored.url.appendingPathComponent("Disks/Restored Disk.qcow2")
        check(fm.fileExists(atPath: output.path), "restored disk exists")
        let outputInfo = try run(qemuImg, ["info", "--output=json", output.path])
        let outputObject = try JSONSerialization.jsonObject(with: outputInfo) as! [String: Any]
        check(outputObject["format"] as? String == "qcow2", "output is a self-contained qcow2")
        check(outputObject["backing-filename"] == nil, "output has no backing disk")
        let importedQCOW = try await DiskRestoreService.restore(image: output, name: "QCOW Source", osName: "Mac OS X",
                                                                in: library, qemuImg: qemuImg,
                                                                operation: DiskRestoreOperation())
        check(fm.fileExists(atPath: importedQCOW.url.appendingPathComponent("Disks/Restored Disk.qcow2").path), "plain qcow2 source is accepted")

        // An existing package is a hard collision. Deliberately pass a missing
        // qemu-img path so this proves the sentinel is rejected before reads or
        // conversion and remains byte-for-byte intact.
        let existing = library.appendingPathComponent("Existing.poweremu")
        try fm.createDirectory(at: existing, withIntermediateDirectories: false)
        let sentinel = existing.appendingPathComponent("sentinel")
        try Data("preserve me".utf8).write(to: sentinel)
        await expectError("packageExists") {
            _ = try await DiskRestoreService.restore(image: raw, name: "Existing", osName: "Mac OS X",
                                                    in: library, qemuImg: temp.appendingPathComponent("missing-qemu-img"),
                                                    operation: DiskRestoreOperation())
        }
        let sentinelData = try Data(contentsOf: sentinel)
        let existingContents = try fm.contentsOfDirectory(atPath: existing.path)
        check(sentinelData == Data("preserve me".utf8), "pre-existing package sentinel survives")
        check(existingContents == ["sentinel"], "collision did not alter package")

        let backingBase = temp.appendingPathComponent("base.qcow2")
        let backed = temp.appendingPathComponent("backed.qcow2")
        _ = try run(qemuImg, ["create", "-q", "-f", "qcow2", backingBase.path, "1M"])
        _ = try run(qemuImg, ["create", "-q", "-f", "qcow2", "-F", "qcow2", "-b", backingBase.path, backed.path])
        await expectError("backingFile") {
            _ = try await DiskRestoreService.restore(image: backed, name: "Backed", osName: "Mac OS X",
                                                    in: library, qemuImg: qemuImg, operation: DiskRestoreOperation())
        }
        check(!fm.fileExists(atPath: library.appendingPathComponent("Backed.poweremu").path), "backing image leaves no package")

        let dataFile = temp.appendingPathComponent("external-data.raw")
        let external = temp.appendingPathComponent("external-data.qcow2")
        _ = try run(qemuImg, ["create", "-q", "-f", "qcow2", "-o", "data_file=\(dataFile.path),data_file_raw=on", external.path, "1M"])
        await expectError("backingFile") {
            _ = try await DiskRestoreService.restore(image: external, name: "External", osName: "Mac OS X",
                                                    in: library, qemuImg: qemuImg, operation: DiskRestoreOperation())
        }
        check(!fm.fileExists(atPath: library.appendingPathComponent("External.poweremu").path), "external-data image leaves no package")

        let encrypted = temp.appendingPathComponent("encrypted.qcow2")
        _ = try run(qemuImg, ["create", "-q", "--object", "secret,id=restore-test,data=temporary-fixture-key",
                             "-f", "qcow2", "-o", "encrypt.format=luks,encrypt.key-secret=restore-test",
                             encrypted.path, "1M"])
        await expectError("backingFile") {
            _ = try await DiskRestoreService.restore(image: encrypted, name: "Encrypted", osName: "Mac OS X",
                                                    in: library, qemuImg: qemuImg, operation: DiskRestoreOperation())
        }
        check(!fm.fileExists(atPath: library.appendingPathComponent("Encrypted.poweremu").path), "encrypted image leaves no package")

        let vmdk = temp.appendingPathComponent("extent.vmdk")
        _ = try run(qemuImg, ["create", "-q", "-f", "vmdk", vmdk.path, "1M"])
        await expectError("unsupported") {
            _ = try await DiskRestoreService.restore(image: vmdk, name: "Extent", osName: "Mac OS X",
                                                    in: library, qemuImg: qemuImg, operation: DiskRestoreOperation())
        }

        let renamedISO = temp.appendingPathComponent("installer.img")
        var isoBytes = Data(repeating: 0, count: 40_000)
        isoBytes.replaceSubrange(32_769..<32_774, with: Data("CD001".utf8))
        try isoBytes.write(to: renamedISO)
        let fakeRawInfo = temp.appendingPathComponent("raw-info-qemu-img")
        try writeExecutable(fakeRawInfo, """
        #!/bin/sh
        if [ "$1" = info ]; then printf '{"format":"raw","virtual-size":40000}'; exit 0; fi
        exit 99
        """)
        await expectError("installerDisc") {
            _ = try await DiskRestoreService.restore(image: renamedISO, name: "Renamed ISO", osName: "Mac OS X",
                                                    in: library, qemuImg: fakeRawInfo, operation: DiskRestoreOperation())
        }
        check(!fm.fileExists(atPath: library.appendingPathComponent("Renamed ISO.poweremu").path), "renamed ISO leaves no package")

        // qemu-img info output exceeds ordinary pipe buffers, and conversion
        // diagnostics exceed the capture limit. Both streams must keep draining.
        let noisyTool = temp.appendingPathComponent("noisy-qemu-img")
        try writeExecutable(noisyTool, """
        #!/bin/sh
        if [ "$1" = info ]; then
          python3 -c 'import json; print(json.dumps({"format":"raw","virtual-size":2097152,"noise":"x"*2000000}))'
        else
          cp "$6" "$7"
        fi
        """)
        let noisy = try await DiskRestoreService.restore(image: raw, name: "Noisy", osName: "Mac OS X",
                                                         in: library, qemuImg: noisyTool, operation: DiskRestoreOperation())
        check(fm.fileExists(atPath: noisy.url.appendingPathComponent("Disks/Restored Disk.qcow2").path), "large info pipe is drained")

        let failureTool = temp.appendingPathComponent("failing-qemu-img")
        try writeExecutable(failureTool, """
        #!/bin/sh
        if [ "$1" = info ]; then
          printf '{"format":"raw","virtual-size":2097152}'
          exit 0
        fi
        i=0
        while [ "$i" -lt 512 ]; do printf '%4096s' x >&2; i=$((i+1)); done
        exit 9
        """)
        await expectError("process") {
            _ = try await DiskRestoreService.restore(image: raw, name: "Failure", osName: "Mac OS X",
                                                    in: library, qemuImg: failureTool, operation: DiskRestoreOperation())
        }
        check(!fm.fileExists(atPath: library.appendingPathComponent("Failure.poweremu").path), "conversion failure removes partial package")

        let slowTool = temp.appendingPathComponent("slow-qemu-img")
        let marker = temp.appendingPathComponent("convert-started")
        try writeExecutable(slowTool, """
        #!/bin/sh
        if [ "$1" = info ]; then printf '{"format":"raw","virtual-size":2097152}'; exit 0; fi
        : > '\(marker.path)'
        exec /bin/sleep 30
        """)
        let cancelOperation = DiskRestoreOperation()
        let pending = Task.detached {
            try await DiskRestoreService.restore(image: raw, name: "Canceled", osName: "Mac OS X",
                                                 in: library, qemuImg: slowTool, operation: cancelOperation)
        }
        let deadline = Date().addingTimeInterval(5)
        while !fm.fileExists(atPath: marker.path), Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        check(fm.fileExists(atPath: marker.path), "conversion process started for cancellation fixture")
        cancelOperation.cancel()
        do { _ = try await pending.value; fatalError("FAIL: expected cancellation") }
        catch let error as DiskRestoreError { check(error.localizedDescription.contains("canceled"), "cancel reports cancellation") }
        check(!fm.fileExists(atPath: library.appendingPathComponent("Canceled.poweremu").path), "cancel removes partial package")
        cancelOperation.cancel() // finished Process is no longer retained/terminated

        let dmg = temp.appendingPathComponent("Sorbet Leopard.dmg")
        try Data("volume image".utf8).write(to: dmg)
        await expectError("volumeImage") {
            _ = try await DiskRestoreService.restore(image: dmg, name: "Sorbet", osName: "Leopard",
                                                    in: library, qemuImg: qemuImg, operation: DiskRestoreOperation())
        }

        print("PASS: restore conversion, startup config, exclusive collision, backing/data/encryption rejection, VMDK narrowing, ISO detection, pipe draining, failure/cancel cleanup, and Sorbet DMG classification")
    }

    private static func run(_ executable: URL, _ args: [String]) throws -> Data {
        let process = Process()
        process.executableURL = executable
        process.arguments = args
        let output = Pipe(); let errors = Pipe()
        process.standardOutput = output; process.standardError = errors
        try process.run(); process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let error = errors.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else { throw NSError(domain: "Test", code: Int(process.terminationStatus), userInfo: [NSLocalizedDescriptionKey: String(decoding: error, as: UTF8.self)]) }
        return data
    }

    private static func writeExecutable(_ url: URL, _ contents: String) throws {
        try Data(contents.utf8).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}
