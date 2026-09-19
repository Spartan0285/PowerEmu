import Foundation
import Darwin

/// One .poweremu package on disk:
///
///     Name.poweremu/
///         config.plist
///         Disks/     hard disks and disc images
///         ROMs/      ATI option ROMs (user supplied)
///         Logs/      console, QEMU output, GPU trace
///
@MainActor
final class VirtualMachine: ObservableObject, Identifiable {
    let url: URL
    @Published var config: VMConfig
    @Published private(set) var state: RunState = .stopped
    @Published private(set) var lastError: String?

    enum RunState: Equatable {
        case stopped, starting, running, stopping
    }

    nonisolated var id: URL { url }

    var disksURL: URL { url.appendingPathComponent("Disks", isDirectory: true) }
    var romsURL: URL { url.appendingPathComponent("ROMs", isDirectory: true) }
    var logsURL: URL { url.appendingPathComponent("Logs", isDirectory: true) }
    var configURL: URL { url.appendingPathComponent("config.plist") }

    private var runner: VMRunner?

    init(url: URL) throws {
        self.url = url
        let data = try Data(contentsOf: url.appendingPathComponent("config.plist"))
        config = try PropertyListDecoder().decode(VMConfig.self, from: data)
    }

    init(url: URL, config: VMConfig) {
        self.url = url
        self.config = config
    }

    func save() throws {
        let enc = PropertyListEncoder()
        enc.outputFormat = .xml
        try enc.encode(config).write(to: configURL, options: .atomic)
    }

    // MARK: running

    func start() {
        guard state == .stopped else { return }
        lastError = nil
        let r = VMRunner(vm: self)
        runner = r
        state = .starting
        do {
            if config.bootChime { Chime.play() }
            try r.launch { [weak self] status in
                Task { @MainActor in self?.processEnded(status: status) }
            }
            state = .running
        } catch {
            state = .stopped
            runner = nil
            lastError = error.localizedDescription
        }
    }

    /// Like pressing a real Mac's power key: the guest asks whether to shut
    /// down, restart or sleep.  (Fully automatic shutdown comes with the
    /// guest tools.)
    func requestShutDown() {
        guard state == .running else { return }
        runner?.pressPowerKey()
    }

    /// Pull the plug.  Mac OS X's disk may need repair afterwards.
    func forcePowerOff() {
        guard state == .running || state == .stopping else { return }
        state = .stopping
        runner?.terminate()
    }

    private func processEnded(status: Int32) {
        state = .stopped
        runner = nil
        if status != 0 {
            let log = (try? String(contentsOf: logsURL.appendingPathComponent("qemu.log"), encoding: .utf8)) ?? ""
            let tail = log.split(separator: "\n").suffix(3).joined(separator: "\n")
            lastError = "The virtual Mac stopped unexpectedly (status \(status)).\(tail.isEmpty ? "" : "\n" + tail)"
        }
    }
}

enum PackageError: LocalizedError {
    case exists(String)
    case missing(String)

    var errorDescription: String? {
        switch self {
        case .exists(let n): return "A virtual Mac named “\(n)” already exists."
        case .missing(let what): return "\(what) could not be found."
        }
    }
}

/// Copy a file as an APFS clone when possible: instant, and no extra space
/// until either copy changes.
func cloneOrCopy(_ src: URL, to dst: URL) throws {
    if clonefile(src.path, dst.path, 0) == 0 { return }
    try FileManager.default.copyItem(at: src, to: dst)
}
