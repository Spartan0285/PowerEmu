import AppKit
import Foundation

/*
 * Feedback, in the shape the shared Cytrus Software endpoint expects.
 *
 * The contract is written down in "Garden OSX/docs/ADDING-AN-APP.md"; this is
 * the PowerEmu client for it. One endpoint serves every app in the family and
 * "poweremu" is already a key in its APPS table, so nothing had to be
 * deployed for this.
 *
 * Two rules from that document drive most of what follows:
 *
 *   Show what you send, before you send it. Every field in a report appears
 *   in the window, including the picture. Nothing is gathered that cannot be
 *   shown.
 *
 *   Never lose what someone wrote. If the endpoint cannot be reached the
 *   report goes to an outbox on disk and is sent at the next launch. Somebody
 *   who types three paragraphs and gets "could not connect" does not type
 *   them again.
 */

struct FeedbackReport {
    /// Stable for the life of the report, including retries: this is what
    /// stops one report becoming two issues. It is also the only thing
    /// protecting the screenshot, which is served unauthenticated from
    /// /api/shot/<app>/<id>.png -- hence arc4random rather than random(),
    /// which is unseeded and returns the same first value on every machine.
    let id: String
    var topic: String
    var summary: String
    var message: String
    var email: String
    /// Where they were. For an emulator that means the guest and how it is
    /// configured -- the first thing worth knowing when a report arrives.
    var page: String
    var system: [String: Any]
    /// Base64 PNG, or empty.
    var screenshot: String

    static func newID() -> String {
        let stamp = DateFormatter.feedbackStamp.string(from: Date())
        return String(format: "%@-%08x%08x", stamp, arc4random(), arc4random())
    }

    var json: [String: Any] {
        [
            "id": id,
            "app": "poweremu",
            "version": Feedback.version,
            "build": Feedback.build,
            "topic": topic,
            "summary": summary,
            "message": message,
            "email": email,
            "page": page,
            "system": system,
            "screenshot": screenshot,
        ]
    }
}

private extension DateFormatter {
    static let feedbackStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd'T'HHmmss"
        f.timeZone = TimeZone(identifier: "UTC")
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

enum FeedbackResult {
    /// Accepted (or already had it): drop the queued copy.
    case sent(issue: Int?)
    /// Malformed. It will never succeed, so do not keep it.
    case refused(String)
    /// Could not be delivered now. Keep it and try again later.
    case deferred(String)
}

enum Feedback {
    /// Overridable without a rebuild, per the client checklist.
    static var endpoint: URL {
        let s = UserDefaults.standard.string(forKey: "PEFeedbackBase")
            ?? ProcessInfo.processInfo.environment["POWEREMU_FEEDBACK_BASE"]
            ?? "https://www.cytrusretro.com/api/feedback"
        return URL(string: s) ?? URL(string: "https://www.cytrusretro.com/api/feedback")!
    }

    /// The endpoint checks this against a single configured value shared by
    /// every app in the family, not one token per app -- a per-app token is
    /// answered with 403 "unknown client". Verified against the deployed
    /// endpoint on 2026-09-21.
    private static let clientToken = "garden-client-1"

    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
    }

    static var build: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    /// "Alpha", or empty once it is not one. Set in one place, in build-app.sh.
    static var stage: String {
        (Bundle.main.object(forInfoDictionaryKey: "PEBuildStage") as? String) ?? ""
    }

    static var versionLine: String {
        let s = stage.isEmpty ? "" : " \(stage)"
        return "Version \(version) (build \(build))\(s)"
    }

    // MARK: - What travels with a report

    /// The host, and the emulator's own state. Named values only: anything
    /// here is listed in the window in plain words before it is sent.
    @MainActor
    static func systemInfo() -> [String: Any] {
        let p = ProcessInfo.processInfo
        var info: [String: Any] = [
            // operatingSystemVersionString is "Version 26.6.1 (Build 25G76)",
            // which reads badly inside the sentence shown to the reader.
            "os": "macOS \(p.operatingSystemVersion.majorVersion)."
                + "\(p.operatingSystemVersion.minorVersion)."
                + "\(p.operatingSystemVersion.patchVersion)",
            "osBuild": p.operatingSystemVersionString,
            "arch": machineArch(),
            "model": sysctlString("hw.model"),
            "memoryMB": Int(p.physicalMemory / (1024 * 1024)),
            "screen": screenDescription(),
        ]
        if let vm = VMWindowController.key?.vm {
            info["guestOS"] = vm.config.osName
            info["guestMemoryMB"] = vm.config.memoryMB
            info["guestVRAMMB"] = vm.config.vramMB
        }
        return info
    }

    /// The report's `page`: which guest, and the parts of its configuration
    /// that explain most reports.
    @MainActor
    static func currentPage() -> String {
        guard let vm = VMWindowController.key?.vm else {
            return "no virtual Mac open"
        }
        let c = vm.config
        return "\(c.osName) — \(c.memoryMB) MB RAM, \(c.vramMB) MB VRAM, "
             + "mouse \(c.mouseMode)"
    }

    /// A human sentence naming everything that travels besides the message,
    /// with the actual values in it. "Diagnostic information" tells nobody
    /// anything; this is the same list the report carries.
    @MainActor
    static func disclosure() -> String {
        let s = systemInfo()
        var bits = ["PowerEmu \(version) (build \(build))"]
        bits.append(s["os"] as? String ?? "macOS")
        bits.append("\(s["model"] as? String ?? "this Mac") (\(s["arch"] as? String ?? "?"))")
        bits.append("\(s["memoryMB"] as? Int ?? 0) MB memory")
        bits.append(currentPage())
        return bits.joined(separator: ", ") + "."
    }

    private static func machineArch() -> String {
        #if arch(arm64)
        return "Apple silicon (arm64)"
        #else
        return "Intel (x86_64)"
        #endif
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buf)
    }

    private static func screenDescription() -> String {
        guard let s = NSScreen.main else { return "?" }
        let r = s.frame
        return "\(Int(r.width))x\(Int(r.height))"
    }

    // MARK: - The picture

    /// A PNG of one of PowerEmu's own windows: the guest's window when one is
    /// open, because that is what a graphics report is about, otherwise the
    /// front window. Returns nil rather than an empty image if the window
    /// cannot be read, so the checkbox can simply be disabled.
    @MainActor
    static func windowSnapshot() -> NSImage? {
        // The guest first, because that is what a graphics report is about.
        // Then the main window rather than the key one: by the time this is
        // called the key window may be a panel the reader just opened, and a
        // picture of the About box helps nobody.
        let window = VMWindowController.key?.window
            ?? NSApp.mainWindow
            ?? NSApp.keyWindow
            ?? NSApp.windows.first { $0.isVisible }
        guard let window, window.windowNumber > 0 else { return nil }
        guard let cg = CGWindowListCreateImage(
            .null,
            .optionIncludingWindow,
            CGWindowID(window.windowNumber),
            [.boundsIgnoreFraming, .nominalResolution]
        ) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func pngBase64(_ image: NSImage) -> String {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return "" }
        return png.base64EncodedString()
    }

    // MARK: - Sending, and the outbox

    private static var outboxDir: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask)[0]
            .appendingPathComponent("PowerEmu/Feedback Outbox", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }

    /// Send one report. On anything but a refusal or success the report is
    /// queued, so the caller can always tell the person it will go later.
    static func send(_ report: FeedbackReport) async -> FeedbackResult {
        let result = await post(report.json)
        switch result {
        case .sent:
            remove(id: report.id)
        case .refused:
            remove(id: report.id)
        case .deferred:
            queue(report)
        }
        return result
    }

    private static func post(_ body: [String: Any]) async -> FeedbackResult {
        guard let data = try? JSONSerialization.data(withJSONObject: body) else {
            return .refused("The report could not be encoded.")
        }
        var req = URLRequest(url: endpoint)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "content-type")
        req.setValue(clientToken, forHTTPHeaderField: "X-Feedback-Client")
        req.httpBody = data
        req.timeoutInterval = 30

        do {
            let (rdata, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else {
                return .deferred("No reply from the server.")
            }
            let obj = try? JSONSerialization.jsonObject(with: rdata) as? [String: Any]
            switch http.statusCode {
            case 200:
                return .sent(issue: obj?["issue"] as? Int)
            case 400:
                return .refused(obj?["error"] as? String ?? "The server would not accept it.")
            default:
                // 413, 429, 5xx: keep it and try later. `stored` may say the
                // server kept a copy, but the document is explicit that we
                // must not assume it did.
                return .deferred(obj?["error"] as? String ?? "The server is busy (\(http.statusCode)).")
            }
        } catch {
            return .deferred(error.localizedDescription)
        }
    }

    private static func queue(_ report: FeedbackReport) {
        let url = outboxDir.appendingPathComponent("\(report.id).json")
        guard let data = try? JSONSerialization.data(withJSONObject: report.json) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func remove(id: String) {
        try? FileManager.default.removeItem(at: outboxDir.appendingPathComponent("\(id).json"))
    }

    /// Called once at launch. Queued reports keep their original id, so a
    /// report that was in fact delivered before the app quit comes back as a
    /// duplicate rather than as a second issue.
    static func flushOutbox() {
        Task.detached(priority: .background) {
            let fm = FileManager.default
            let files = (try? fm.contentsOfDirectory(at: outboxDir,
                                                     includingPropertiesForKeys: nil)) ?? []
            for file in files where file.pathExtension == "json" {
                guard let data = try? Data(contentsOf: file),
                      let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    try? fm.removeItem(at: file)     // not a report we can read
                    continue
                }
                switch await post(body) {
                case .sent, .refused:
                    try? fm.removeItem(at: file)
                case .deferred:
                    return                            // still down; stop for now
                }
            }
        }
    }

    static var queuedCount: Int {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: outboxDir, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.count
    }
}
