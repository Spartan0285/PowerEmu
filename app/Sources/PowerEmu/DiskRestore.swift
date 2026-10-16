import Foundation
import Darwin
import Dispatch

enum DiskRestoreError: LocalizedError {
    case installerDisc
    case volumeImage
    case unsupported(String)
    case invalidImage(String)
    case backingFile
    case cancelled
    case process(String)
    case invalidName
    case packageExists(String)

    var errorDescription: String? {
        switch self {
        case .installerDisc: return "This looks like an installer disc. Choose an installed hard disk image here, or use the install-disc flow."
        case .volumeImage: return "This is a restorable volume image, not a complete disk. Sorbet Leopard DMGs must be restored onto an Apple Partition Map disk volume; that workflow is not available here yet."
        case .unsupported(let f): return "The disk image format “\(f)” is not supported for restore."
        case .invalidImage(let detail): return "PowerEmu could not read this as a hard disk image. \(detail)"
        case .backingFile: return "This disk image depends on external data, another image, or encryption metadata. Choose a self-contained, unencrypted image."
        case .cancelled: return "Disk restore was canceled."
        case .process(let detail): return detail
        case .invalidName: return "Choose a valid virtual Mac name."
        case .packageExists(let name): return "A virtual Mac named “\(name)” already exists."
        }
    }
}

/// The process box lets Cancel terminate qemu-img while the detached import is
/// waiting for it. Cancellation is checked again before the finished image is
/// moved into the new package.
final class DiskRestoreOperation: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    func install(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        self.process = process
        if cancelled, process.isRunning { process.terminate() }
    }

    func finish(_ process: Process) {
        lock.lock(); defer { lock.unlock() }
        if self.process === process { self.process = nil }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let active = process
        lock.unlock()
        if let active, active.isRunning { active.terminate() }
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}

enum DiskRestoreService {
    private static let supportedFormats: Set<String> = ["raw", "qcow2"]
    private static let installerExtensions: Set<String> = ["iso", "cdr", "toast", "cue", "bin"]
    private static let volumeRestoreExtensions: Set<String> = ["dmg"]

    /// Creates a new package and converts the selected disk to a standalone
    /// qcow2 file. The package is created exclusively and removed on failure.
    static func restore(image: URL, name: String, osName: String, in libraryFolder: URL,
                        qemuImg: URL, operation: DiskRestoreOperation) async throws -> VirtualMachine {
        let fm = FileManager.default
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty, !cleanName.contains("/"), !cleanName.contains("\0"), cleanName != ".", cleanName != ".." else {
            throw DiskRestoreError.invalidName
        }
        guard !installerExtensions.contains(image.pathExtension.lowercased()) else {
            throw DiskRestoreError.installerDisc
        }
        guard !volumeRestoreExtensions.contains(image.pathExtension.lowercased()) else {
            throw DiskRestoreError.volumeImage
        }
        let ext = image.pathExtension.lowercased()
        guard ["img", "raw", "qcow2"].contains(ext) else {
            throw DiskRestoreError.unsupported(ext.isEmpty ? "unknown" : ext)
        }
        guard fm.fileExists(atPath: image.path),
              (try? image.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            throw DiskRestoreError.invalidImage("Select a disk image file.")
        }

        let package = libraryFolder.appendingPathComponent(cleanName + ".poweremu", isDirectory: true)
        // POSIX mkdir is an atomic exclusive create. FileManager may treat an
        // existing directory as success on some OS releases.
        let mkdirResult = package.path.withCString { mkdir($0, mode_t(0o700)) }
        guard mkdirResult == 0 else {
            if errno == EEXIST { throw DiskRestoreError.packageExists(cleanName) }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        do {
            let infoData = try run(qemuImg, ["info", "--output=json", image.path], operation: operation)
            let info: ImageInfo
            do { info = try ImageInfo(data: infoData) }
            catch { throw DiskRestoreError.invalidImage("The disk tool returned incomplete image details.") }
            guard supportedFormats.contains(info.format) else { throw DiskRestoreError.unsupported(info.format) }
            guard (ext == "qcow2") == (info.format == "qcow2") else {
                throw DiskRestoreError.invalidImage("The filename extension does not match the image format.")
            }
            guard info.virtualSize > 0 else { throw DiskRestoreError.invalidImage("The image has no disk space.") }
            guard !hasExternalReferences(info.json) else { throw DiskRestoreError.backingFile }
            if ["img", "raw"].contains(ext), looksLikeISO(image) { throw DiskRestoreError.installerDisc }
            try checkCancelled(operation)

            let disks = package.appendingPathComponent("Disks", isDirectory: true)
            try fm.createDirectory(at: disks, withIntermediateDirectories: false)
            try fm.createDirectory(at: package.appendingPathComponent("ROMs", isDirectory: true), withIntermediateDirectories: false)
            try fm.createDirectory(at: package.appendingPathComponent("Logs", isDirectory: true), withIntermediateDirectories: false)
            let finalDisk = disks.appendingPathComponent("Restored Disk.qcow2")
            let staging = disks.appendingPathComponent(".restore-\(UUID().uuidString).qcow2")
            defer { try? fm.removeItem(at: staging) }
            _ = try run(qemuImg, ["convert", "-f", info.format, "-O", "qcow2", image.path, staging.path], operation: operation)
            try checkCancelled(operation)
            guard fm.fileExists(atPath: staging.path) else {
                throw DiskRestoreError.invalidImage("The disk tool did not create the restored disk.")
            }
            // The package is newly and exclusively created; this destination
            // cannot overwrite a pre-existing disk.
            try fm.moveItem(at: staging, to: finalDisk)
            try checkCancelled(operation)
            return try await MainActor.run {
                if operation.isCancelled { throw DiskRestoreError.cancelled }
                var config = VMConfig(name: cleanName)
                config.osName = osName
                let disk = DiskConfig(file: finalDisk.lastPathComponent, label: "Restored Disk")
                config.disks = [disk]
                config.startupDisk = disk.id
                let vm = VirtualMachine(url: package, config: config)
                try vm.save()
                return vm
            }
        } catch {
            try? fm.removeItem(at: package)
            throw error
        }
    }

    private struct ImageInfo {
        let format: String
        let virtualSize: Int64
        let json: [String: Any]
        init(data: Data) throws {
            guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let format = object["format"] as? String,
                  let size = object["virtual-size"] as? Int64 else {
                throw DiskRestoreError.invalidImage("The disk tool returned incomplete image details.")
            }
            self.format = format
            self.virtualSize = size
            self.json = object
        }
    }

    private static func checkCancelled(_ operation: DiskRestoreOperation) throws {
        if operation.isCancelled { throw DiskRestoreError.cancelled }
    }

    private static func run(_ executable: URL, _ arguments: [String],
                            operation: DiskRestoreOperation) throws -> Data {
        try checkCancelled(operation)
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        do { try process.run() }
        catch { throw DiskRestoreError.process("Could not start the disk image tool: \(error.localizedDescription)") }
        operation.install(process)
        let drainers = DispatchGroup()
        let stdoutCapture = PipeCapture(limit: 8 * 1024 * 1024)
        let stderrCapture = PipeCapture(limit: 64 * 1024)
        drainers.enter()
        DispatchQueue.global(qos: .utility).async {
            stdoutCapture.drain(output.fileHandleForReading)
            drainers.leave()
        }
        drainers.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrCapture.drain(errors.fileHandleForReading)
            drainers.leave()
        }
        process.waitUntilExit()
        drainers.wait()
        operation.finish(process)
        let data = stdoutCapture.data
        let errorData = stderrCapture.data
        if operation.isCancelled { throw DiskRestoreError.cancelled }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            throw DiskRestoreError.process("The disk image could not be restored.\(detail?.isEmpty == false ? " \(detail!)" : "")")
        }
        return data
    }

    private static func hasExternalReferences(_ json: [String: Any]) -> Bool {
        func containsDependency(_ value: Any) -> Bool {
            if let dictionary = value as? [String: Any] {
                return dictionary.contains { key, child in
                    let key = key.lowercased()
                    return key.contains("backing") || key.contains("data-file") || key.contains("encrypt") || key.contains("crypto") || key.contains("secret") || containsDependency(child)
                }
            }
            if let array = value as? [Any] { return array.contains(where: containsDependency) }
            return false
        }
        return containsDependency(json)
    }

    /// ISO-9660 primary volume descriptors begin at logical sector 16. This
    /// catches installer ISOs that have been renamed to .img.
    private static func looksLikeISO(_ image: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: image) else { return false }
        defer { try? handle.close() }
        guard (try? handle.seek(toOffset: 32_769)) != nil,
              let marker = try? handle.read(upToCount: 5) else { return false }
        return marker == Data("CD001".utf8)
    }
}

private final class PipeCapture: @unchecked Sendable {
    private let lock = NSLock()
    private let limit: Int
    private var captured = Data()
    init(limit: Int) { self.limit = limit }
    var data: Data { lock.lock(); defer { lock.unlock() }; return captured }
    func drain(_ handle: FileHandle) {
        while true {
            guard let chunk = try? handle.read(upToCount: 64 * 1024), !chunk.isEmpty else { break }
            lock.lock()
            let remaining = limit - captured.count
            if remaining > 0 { captured.append(chunk.prefix(remaining)) }
            lock.unlock()
        }
    }
}
