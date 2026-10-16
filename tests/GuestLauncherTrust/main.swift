import AppKit
import Foundation
import Darwin

@main
enum GuestLauncherTrustChecks {
    static func main() {
        do { try runChecks() }
        catch { fail("\(error)") }
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        exit(EXIT_FAILURE)
    }

    private static func runChecks() throws {
        guard CommandLine.arguments.count == 4 else {
            fail("usage: GuestLauncherTrustChecks <signed-template.app> <signed-host.app> <result-file>")
        }
        let template = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let host = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let resultURL = URL(fileURLWithPath: CommandLine.arguments[3])
        let sourceHash = try GuestLauncherTrust.verifyTemplate(templateURL: template, hostApplicationURL: host)
        let app = Bundle.main.bundleURL.standardizedFileURL.resolvingSymlinksInPath()
        let stableID = "0123456789abcdef0123456789abcdef"
        guard Bundle.main.bundleIdentifier == "com.spartan0285.poweremu.guestapp." + stableID else {
            fail("test must run from its unique locally generated app bundle")
        }

        let receipt = try GuestLauncherTrust.makeReceipt(applicationURL: app,
            installedApplicationURL: app, stableIdentifier: stableID, sourceCDHash: sourceHash)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("GuestLauncherTrust-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }

        let forgedTemplate = root.appendingPathComponent("ForgedTemplate.app", isDirectory: true)
        try FileManager.default.copyItem(at: template, to: forgedTemplate)
        try signAdHoc(forgedTemplate, identifier: GuestLauncherTrust.templateIdentifier)
        expectTemplateRejected(forgedTemplate, host: host, label: "ad-hoc template with forged role identifier")
        let unsignedTemplate = root.appendingPathComponent("UnsignedTemplate.app", isDirectory: true)
        try FileManager.default.copyItem(at: template, to: unsignedTemplate)
        try FileManager.default.removeItem(at: unsignedTemplate.appendingPathComponent("Contents/_CodeSignature"))
        expectTemplateRejected(unsignedTemplate, host: host, label: "unsigned template")

        let sidecar = root.appendingPathComponent(stableID, isDirectory: true)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try GuestLauncherTrust.saveReceipt(receipt, to: sidecar)
        let loaded = try GuestLauncherTrust.loadReceipt(from: sidecar, applicationURL: app,
            stableIdentifier: stableID, sourceCDHash: sourceHash)
        guard loaded == receipt,
              GuestLauncherTrust.validatesInstalledBundle(applicationURL: app, receipt: loaded) else {
            fail("valid ad-hoc app or owner-only receipt did not validate")
        }
        guard GuestLauncherTrust.validates(processIdentifier: getpid(), receipt: loaded) else {
            fail("the exact live ad-hoc process did not validate")
        }
        let wrongProcessReceipt = GuestLauncherTrust.Receipt(version: loaded.version,
            stableID: loaded.stableID, executablePath: loaded.executablePath,
            bundleIdentifier: loaded.bundleIdentifier, sourceCDHash: loaded.sourceCDHash,
            cdHash: Data(repeating: 0x55, count: loaded.cdHash.count))
        guard !GuestLauncherTrust.validates(processIdentifier: getpid(), receipt: wrongProcessReceipt) else {
            fail("live PID was accepted with the wrong CDHash")
        }

        do {
            _ = try GuestLauncherTrust.loadReceipt(from: sidecar, applicationURL: app,
                stableIdentifier: "fedcba9876543210fedcba9876543210", sourceCDHash: sourceHash)
            fail("receipt was accepted for a different stable identity")
        } catch { }
        do {
            _ = try GuestLauncherTrust.loadReceipt(from: sidecar, applicationURL: app,
                stableIdentifier: stableID, sourceCDHash: Data(repeating: 0x55, count: sourceHash.count))
            fail("receipt was accepted for a different source template")
        } catch is GuestLauncherTrust.TrustError { }

        let receiptURL = sidecar.appendingPathComponent(GuestLauncherTrust.receiptFilename)
        try FileManager.default.removeItem(at: receiptURL)
        try FileManager.default.createSymbolicLink(at: receiptURL, withDestinationURL: app)
        do {
            _ = try GuestLauncherTrust.loadReceipt(from: sidecar, applicationURL: app,
                stableIdentifier: stableID, sourceCDHash: sourceHash)
            fail("symlink receipt was accepted")
        } catch is GuestLauncherTrust.TrustError { }
        try FileManager.default.removeItem(at: receiptURL)
        try GuestLauncherTrust.saveReceipt(receipt, to: sidecar)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: receiptURL.path)
        do {
            _ = try GuestLauncherTrust.loadReceipt(from: sidecar, applicationURL: app,
                stableIdentifier: stableID, sourceCDHash: sourceHash)
            fail("group/world-readable receipt was accepted")
        } catch is GuestLauncherTrust.TrustError { }

        let result = "PASS: Developer ID template, ad-hoc app receipt, live PID/CDHash, identity binding, permissions, and symlink rejection\n"
        try result.write(to: resultURL, atomically: true, encoding: .utf8)
        print(result, terminator: "")
    }

    private static func signAdHoc(_ app: URL, identifier: String) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        process.arguments = ["--force", "--sign", "-", "--options", "runtime", "--identifier", identifier, app.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { fail("could not sign isolated negative fixture") }
    }

    private static func expectTemplateRejected(_ candidate: URL, host: URL, label: String) {
        do {
            _ = try GuestLauncherTrust.verifyTemplate(templateURL: candidate, hostApplicationURL: host)
            fail("accepted \(label)")
        } catch { }
    }
}
