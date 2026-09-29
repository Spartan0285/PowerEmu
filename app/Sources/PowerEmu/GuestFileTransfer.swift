import AppKit
import UniformTypeIdentifiers

@MainActor
final class GuestFileTransfer {
    weak var agent: GuestAgent?
    let root: URL
    private var pending: [String: (Result<[String: Any], Error>) -> Void] = [:]
    private let queue = DispatchQueue(label: "PowerEmu.file-transfer", qos: .utility)
    // Providers hold their delegate weakly. Keep it alive until the receiver
    // finishes writing, even after AppKit has ended the drag animation.
    private var promises: [UUID: GuestFilePromise] = [:]
    private var exports: [() -> Void] = []
    private var exporting = false
    private var importing = 0
    private var progressPanel: NSPanel?
    private func beginImport() {
        importing += 1
        guard progressPanel == nil else { return }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 330, height: 76),
                            styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.title = "PowerEmu File Transfer"
        panel.isReleasedWhenClosed = false
        let label = NSTextField(labelWithString: "Copying files to the guest…")
        label.frame = NSRect(x: 52, y: 28, width: 262, height: 20)
        let spinner = NSProgressIndicator(frame: NSRect(x: 20, y: 28, width: 20, height: 20))
        spinner.style = .spinning; spinner.startAnimation(nil)
        panel.contentView?.addSubview(label); panel.contentView?.addSubview(spinner)
        panel.center(); panel.orderFront(nil); progressPanel = panel
    }
    private func endImport() {
        importing = max(0, importing - 1)
        if importing == 0 { progressPanel?.close(); progressPanel = nil }
    }

    init(root: URL) { self.root = root }
    deinit {
        let directory = root
        queue.async { try? FileManager.default.removeItem(at: directory) }
    }

    var available: Bool {
        guard let version = agent?.info?.version else { return false }
        return version.compare("2.14", options: .numeric) != .orderedAscending
    }

    func disconnected() {
        let callbacks = Array(pending.values); pending.removeAll()
        for done in callbacks { done(.failure(FileTransferError("The guest disconnected during the file transfer. Check the destination before retrying."))) }
    }

    func receive(_ message: [String: Any]) {
        guard let id = message["request"] as? String, let done = pending.removeValue(forKey: id) else { return }
        if let error = message["error"] as? String { done(.failure(FileTransferError(error))) }
        else { done(.success(message)) }
    }

    private func request(_ fields: [String: Any], timeout: Double = 30,
                         completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard agent?.connected == true else { completion(.failure(FileTransferError("The guest is disconnected."))); return }
        guard available else { completion(.failure(FileTransferError("Install PowerEmu Tools 2.14 or newer to drag files between Macs."))); return }
        var fields = fields
        let id = UUID().uuidString; fields["request"] = id
        guard let data = try? PropertyListSerialization.data(fromPropertyList: fields, format: .xml, options: 0) else {
            completion(.failure(FileTransferError("The file transfer request could not be prepared.")))
            return
        }
        pending[id] = completion
        agent?.send("FILETRANSFER", data)
        DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { [weak self] in
            self?.pending.removeValue(forKey: id)?(.failure(FileTransferError("The guest did not finish the file transfer in time. Check the destination before retrying.")))
        }
    }

    func importFiles(_ urls: [URL], window: Int = 0, application: Int = 0) -> Bool {
        guard available, !urls.isEmpty, urls.count <= 256, urls.allSatisfy(\.isFileURL) else {
            Self.show(FileTransferError("Install PowerEmu Tools 2.14 or newer. Drag up to 256 files or folders at a time.")); return false
        }
        beginImport()
        let token = UUID().uuidString
        // Capture the destination at drop time, before a large host copy or
        // subsequent navigation could change the Finder window's folder.
        request(["action": "destination", "token": token, "window": window, "application": application]) { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure(let error): self.endImport(); Self.show(error)
            case .success:
                self.stageFiles(urls, token: token)
            }
        }
        return true
    }

    private func stageFiles(_ urls: [URL], token: String, cleanup: URL? = nil) {
        let dir = self.root.appendingPathComponent(token)
        let agent = self.agent
        self.queue.async {
            defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
            let staged = Result<[String], Error> {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                for (i, url) in urls.enumerated() {
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try FileTransferArchive.pack(url, to: dir.appendingPathComponent("\(i).zip"))
                }
                return urls.map(\.lastPathComponent)
            }
            DispatchQueue.main.async {
                guard self.agent === agent, self.available else {
                    try? FileManager.default.removeItem(at: dir)
                    self.endImport()
                    Self.show(FileTransferError("The guest disconnected before the files could be sent.")); return
                }
                switch staged {
                case .failure(let error):
                    try? FileManager.default.removeItem(at: dir); self.endImport(); Self.show(error)
                case .success(let names):
                    self.request(["action": "import", "token": token, "names": names], timeout: 900) { outcome in
                        self.endImport()
                        // On a timeout the guest may still be reading; keep its
                        // private staging until VM shutdown rather than deleting it.
                        switch outcome {
                        case .success: try? FileManager.default.removeItem(at: dir)
                        case .failure(let error): Self.show(error)
                        }
                    }
                }
            }
        }
    }

    func importPromises(_ receivers: [NSFilePromiseReceiver], window: Int) -> Bool {
        let count = receivers.reduce(0) { $0 + $1.fileNames.count }
        guard available, count > 0, count <= 256 else { return false }
        beginImport()
        let token = UUID().uuidString
        request(["action": "destination", "token": token, "window": window]) { [self] result in
            if case .failure(let error) = result { endImport(); Self.show(error); return }
            let staging = FileManager.default.temporaryDirectory.appendingPathComponent("PowerEmuIncoming-" + UUID().uuidString)
            var remaining = count, urls: [URL] = [], failed: Error?, finished = false
            var destinations: [URL] = []
            do {
                for i in receivers.indices {
                    let dir = staging.appendingPathComponent(String(i))
                    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    destinations.append(dir)
                }
            } catch { endImport(); Self.show(error); try? FileManager.default.removeItem(at: staging); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 900) { [self] in
                guard !finished else { return }; finished = true; endImport()
                Self.show(FileTransferError("The source application did not finish providing the dragged files."))
            }
            for (i, receiver) in receivers.enumerated() {
                receiver.receivePromisedFiles(atDestination: destinations[i], options: [:], operationQueue: .main) { url, error in
                    MainActor.assumeIsolated {
                        remaining -= 1
                        if let error { failed = error } else { urls.append(url) }
                        guard remaining == 0 else { return }
                        guard !finished else { try? FileManager.default.removeItem(at: staging); return }
                        finished = true
                        if let failed {
                            self.endImport(); Self.show(failed); try? FileManager.default.removeItem(at: staging)
                        } else { self.stageFiles(urls, token: token, cleanup: staging) }
                    }
                }
            }
        }
        return true
    }

    func armDrag(window: Int, point: CGPoint) {
        if available { agent?.send("FILEDRAGARM", "\(window) \(Int(point.x.rounded())) \(Int(point.y.rounded()))") }
    }

    func prepareDrag(window: Int, completion: @escaping ([NSDraggingItem]) -> Void) {
        let token = UUID().uuidString
        request(["action": "selection", "token": token, "window": window], timeout: 5) { [weak self] result in
            guard let self else { completion([]); return }
            guard case .success(let reply) = result, let entries = reply["entries"] as? [[String: Any]],
                  !entries.isEmpty, entries.count <= 256 else { completion([]); return }
            var items: [NSDraggingItem] = []
            for (index, entry) in entries.enumerated() {
                guard let name = entry["name"] as? String, FileTransferArchive.validName(name) else { completion([]); return }
                let type = (entry["directory"] as? Bool == true) ? UTType.folder : (UTType(filenameExtension: (name as NSString).pathExtension) ?? .data)
                let delegate = GuestFilePromise(name: name, owner: self, token: token, index: index)
                self.promises[delegate.id] = delegate
                // A canceled drag never invokes writePromise. Retain briefly for
                // late receiver requests, then release unused providers.
                DispatchQueue.main.asyncAfter(deadline: .now() + 120) { [weak self, weak delegate] in
                    if let delegate, !delegate.started { self?.promises[delegate.id] = nil }
                }
                let provider = NSFilePromiseProvider(fileType: type.identifier, delegate: delegate)
                let item = NSDraggingItem(pasteboardWriter: provider)
                let icon = NSWorkspace.shared.icon(for: type)
                item.setDraggingFrame(NSRect(x: 0, y: 0, width: 40, height: 40), contents: icon)
                items.append(item)
            }
            completion(items)
        }
    }

    fileprivate func write(_ promise: GuestFilePromise, to destination: URL, completion: @escaping (Error?) -> Void) {
        promise.started = true
        exports.append { [self] in
            performWrite(promise, to: destination) { [self] error in
                completion(error); exporting = false; nextExport()
            }
        }
        nextExport()
    }
    private func nextExport() {
        guard !exporting, !exports.isEmpty else { return }
        exporting = true; exports.removeFirst()()
    }
    private func performWrite(_ promise: GuestFilePromise, to destination: URL, completion: @escaping (Error?) -> Void) {
        promise.started = true
        let dir = root.appendingPathComponent(promise.token)
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        catch { promises[promise.id] = nil; completion(error); return }
        request(["action": "export", "token": promise.token, "index": promise.index], timeout: 900) { [self] result in
            switch result {
            case .failure(let error): promises[promise.id] = nil; completion(error)
            case .success:
                let index = promise.index, name = promise.name, id = promise.id
                queue.async {
                    let outcome = Result { try FileTransferArchive.unpack(dir.appendingPathComponent("\(index).zip"), name: name, to: destination) }
                    DispatchQueue.main.async {
                        self.promises[id] = nil
                        switch outcome {
                        case .success:
                            try? FileManager.default.removeItem(at: dir.appendingPathComponent("\(index).zip")); completion(nil)
                        case .failure(let error): completion(error)
                        }
                    }
                }
            }
        }
    }

    private static func show(_ error: Error) {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "File transfer could not finish"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

private final class GuestFilePromise: NSObject, NSFilePromiseProviderDelegate {
    let id = UUID()
    let name: String
    let token: String
    let index: Int
    weak var owner: GuestFileTransfer?
    var started = false // only touched on main
    init(name: String, owner: GuestFileTransfer, token: String, index: Int) {
        self.name = name; self.owner = owner; self.token = token; self.index = index
    }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, fileNameForType type: String) -> String { name }
    func filePromiseProvider(_ provider: NSFilePromiseProvider, writePromiseTo url: URL, completionHandler: @escaping (Error?) -> Void) {
        DispatchQueue.main.async {
            guard let owner = self.owner else { completionHandler(FileTransferError("The virtual Mac is no longer available.")); return }
            owner.write(self, to: url, completion: completionHandler)
        }
    }
}
