import Foundation
import CoreServices

/// Tells the guest when a shared folder changes on this Mac.
///
/// Tiger's Finder notices changes on a WebDAV volume by checking each open
/// folder's modification date, and webdavfs answers that from a cache that
/// lasts about half a minute -- so a file added here took up to 30 s to
/// appear there. On each change PowerEmu Agent (1.1+) re-reads the folder in
/// the guest, which refreshes that cache, and Finder shows the change within
/// a second (see `changed:` in guest/src/PEAgent.m).
final class SharedFolderWatcher {
    /// Called on the main queue with "NAME\tPATH" lines: the folders that
    /// changed, PATH relative to the share ("" for its top).
    private let onChange: (String) -> Void
    private var stream: FSEventStreamRef?
    private var roots: [(name: String, path: String)] = []

    init(onChange: @escaping (String) -> Void) {
        self.onChange = onChange
    }

    deinit { stop() }

    func watch(_ shares: [SharedFolder]) {
        stop()
        // realpath, not resolvingSymlinksInPath: FSEvents reports /private/tmp,
        // which Foundation would shorten to /tmp.
        roots = shares.map { s in (s.name, realpath(s.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? s.path) }
        guard !roots.isEmpty else { return }
        var ctx = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        let cb: FSEventStreamCallback = { _, info, count, paths, _, _ in
            guard let info else { return }
            let me = Unmanaged<SharedFolderWatcher>.fromOpaque(info).takeUnretainedValue()
            let list = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
            me.handle(Array(list.prefix(count)))
        }
        // File-level events, so the guest's own .DS_Store writes can be told
        // apart (refreshing on those could make Finder write it again).
        let flags = UInt32(kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagFileEvents
                           | kFSEventStreamCreateFlagNoDefer)
        guard let s = FSEventStreamCreate(nil, cb, &ctx, roots.map(\.path) as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 0.3, flags) else { return }
        FSEventStreamSetDispatchQueue(s, .main)
        FSEventStreamStart(s)
        stream = s
    }

    func stop() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func handle(_ paths: [String]) {
        var lines: [String] = []
        for p in paths {
            let name = (p as NSString).lastPathComponent
            if name == ".poweremu-guest.DS_Store" || name.hasPrefix(".poweremu-upload-") { continue }
            let dir = (p as NSString).deletingLastPathComponent
            for r in roots where dir == r.path || dir.hasPrefix(r.path + "/") {
                let rel = dir == r.path ? "" : String(dir.dropFirst(r.path.count + 1))
                let line = "\(r.name)\t\(rel)"
                if !lines.contains(line) { lines.append(line) }
            }
        }
        if !lines.isEmpty { onChange(lines.joined(separator: "\n")) }
    }
}
