import Foundation

/*
 * Fetching an install disc from a link.
 *
 * Most readers will have a Mac OS X disc or a disc image already, and the
 * Installation Assistant takes those.  Someone who doesn't can give
 * PowerEmu a link to one instead, and it downloads it here, keeps it, and
 * hands it to the same installer.
 *
 * PowerEmu deliberately offers no list of places to get Mac OS X from.
 * Apple has never given anyone permission to redistribute it, so the
 * choice of where a copy comes from belongs to the reader, not to this
 * program.  What is kept is only what they typed themselves.
 */
@MainActor
final class MediaDownload: ObservableObject {
    @Published private(set) var received: Int64 = 0
    @Published private(set) var expected: Int64 = 0
    @Published private(set) var running = false
    @Published private(set) var problem: String?
    /// Where the finished file is, once it has arrived.
    @Published private(set) var file: URL?

    private var task: URLSessionDownloadTask?
    private var delegate: Delegate?

    /// Where downloaded discs are kept, so a second machine doesn't fetch
    /// the same gigabytes again.
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Installers", isDirectory: true)
    }

    /// Links the reader has used before, most recent first. Their own, not
    /// ours: PowerEmu suggests nothing.
    static var remembered: [String] {
        get { UserDefaults.standard.stringArray(forKey: "InstallerLinks") ?? [] }
        set { UserDefaults.standard.set(Array(newValue.prefix(8)), forKey: "InstallerLinks") }
    }

    static func remember(_ link: String) {
        var all = remembered.filter { $0 != link }
        all.insert(link, at: 0)
        remembered = all
    }

    /// A file already downloaded from this link, if it is still there.
    static func existing(for link: String) -> URL? {
        guard let name = name(for: link) else { return nil }
        let u = folder.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    /// What to call the file: the last part of the link, with a sensible
    /// extension, and nothing a path could hide in.
    static func name(for link: String) -> String? {
        guard let url = URL(string: link), let host = url.host, !host.isEmpty else { return nil }
        var last = url.lastPathComponent.removingPercentEncoding ?? url.lastPathComponent
        last = last.replacingOccurrences(of: "/", with: "-")
        if last.isEmpty || last == "-" { last = "Install Disc" }
        let known = ["iso", "dmg", "cdr", "toast", "img"]
        if !known.contains(url.pathExtension.lowercased()) { last += ".iso" }
        return last
    }

    func start(link: String) {
        problem = nil
        file = nil
        guard let url = URL(string: link), url.scheme == "https" || url.scheme == "http",
              let name = Self.name(for: link) else {
            problem = "That doesn’t look like a link to a file."
            return
        }
        if let already = Self.existing(for: link) {
            file = already
            return
        }
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let dest = Self.folder.appendingPathComponent(name)
        running = true
        received = 0
        expected = 0
        let d = Delegate(dest: dest) { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                self.running = false
                switch result {
                case .success(let u):
                    self.file = u
                    Self.remember(link)
                case .failure(let e):
                    self.problem = e.localizedDescription
                }
            }
        } progress: { [weak self] got, total in
            Task { @MainActor in
                self?.received = got
                self?.expected = total
            }
        }
        delegate = d
        task = d.begin(url)
    }

    func cancel() {
        task?.cancel()
        delegate?.invalidate()
        running = false
        received = 0
    }

    /// "1.2 of 3.5 GB", or just what has arrived when the size is unknown.
    var progressText: String {
        let gb = { (n: Int64) in String(format: "%.1f GB", Double(n) / 1_073_741_824) }
        return expected > 0 ? "\(gb(received)) of \(gb(expected))" : gb(received)
    }

    var fraction: Double? {
        expected > 0 ? min(1, Double(received) / Double(expected)) : nil
    }

    // MARK: the download itself

    private final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        private let dest: URL
        private let done: (Result<URL, Error>) -> Void
        private let progress: (Int64, Int64) -> Void
        private var session: URLSession?

        init(dest: URL, done: @escaping (Result<URL, Error>) -> Void,
             progress: @escaping (Int64, Int64) -> Void) {
            self.dest = dest
            self.done = done
            self.progress = progress
        }

        func begin(_ url: URL) -> URLSessionDownloadTask {
            let s = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            session = s
            let t = s.downloadTask(with: url)
            t.resume()
            return t
        }

        func invalidate() { session?.invalidateAndCancel() }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            progress(totalBytesWritten, max(0, totalBytesExpectedToWrite))
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            let fm = FileManager.default
            do {
                if let http = downloadTask.response as? HTTPURLResponse, http.statusCode >= 400 {
                    throw InstallError.failed("The server answered \(http.statusCode).")
                }
                try? fm.removeItem(at: dest)
                try fm.moveItem(at: location, to: dest)
                done(.success(dest))
            } catch {
                done(.failure(error))
            }
            session.finishTasksAndInvalidate()
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error, (error as NSError).code != NSURLErrorCancelled {
                done(.failure(error))
            }
        }
    }
}
