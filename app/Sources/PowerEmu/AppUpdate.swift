//  AppUpdate.swift
//  Looking for a newer PowerEmu, fetching it, and putting it in place.
//
//  The check is a small JSON file on the web saying what the newest build
//  is and where to get it.  Nothing is installed without the reader saying
//  so, and nothing is installed that this Mac cannot prove came from the
//  same developer as the copy already running.

import Foundation
import AppKit
import CryptoKit

/// One release: the newest, or one that has been and gone.
struct ReleaseNote: Sendable, Identifiable {
    let version: String
    let build: Int
    let published: Date?
    let notes: String
    var id: Int { build }
}

/// What the feed says the newest build is.
struct AppUpdate: Sendable {
    let version: String            // "0.2", shown to the reader
    let build: Int                 // the number actually compared
    let notes: String
    let url: URL                   // a zip of PowerEmu.app
    let sha256: String?            // optional; the signature check is the real one
    let minimumSystem: String?     // "14.0"
    let published: Date?

    var isNewer: Bool { build > Updater.runningBuild }

    /// macOS being too old is worth saying plainly rather than letting the
    /// reader download something that will not open.
    var runsHere: Bool {
        guard let m = minimumSystem else { return true }
        let want = m.split(separator: ".").compactMap { Int($0) }
        let have = ProcessInfo.processInfo.operatingSystemVersion
        let mine = [have.majorVersion, have.minorVersion, have.patchVersion]
        for (i, w) in want.enumerated() where i < mine.count {
            if mine[i] != w { return mine[i] > w }
        }
        return true
    }
}

enum UpdateError: LocalizedError {
    case badFeed
    case notAnApp
    case unsigned(String)
    case differentDeveloper
    case checksum
    case machinesRunning([String])
    case couldNotReplace(String)

    var errorDescription: String? {
        switch self {
        case .badFeed:
            return "PowerEmu could not read the list of updates."
        case .notAnApp:
            return "What was downloaded is not a copy of PowerEmu."
        case .unsigned(let why):
            return "The downloaded copy of PowerEmu is not properly signed (\(why))."
        case .differentDeveloper:
            return "The downloaded copy of PowerEmu was signed by someone else, so it has not been installed."
        case .checksum:
            return "The download did not arrive intact."
        case .machinesRunning(let names):
            return names.count == 1
                ? "“\(names[0])” is still running. Shut it down or put it to sleep before updating."
                : "\(names.count) virtual Macs are still running. Shut them down or put them to sleep before updating."
        case .couldNotReplace(let why):
            return "PowerEmu could not put the new version in place (\(why))."
        }
    }
}

enum Updater {
    /// The repository PowerEmu is published from serves its own update
    /// feed: the file sits next to the source, and the download it points
    /// at is a release asset on the same repository.  Nothing else has to
    /// be kept up, and it is the same place anyone can get the source
    /// from, which is what the GPL asks of us anyway.
    static let defaultFeed =
        "https://raw.githubusercontent.com/Spartan0285/PowerEmu/main/appcast.json"

    /// Overridable without a rebuild, the same way the feedback endpoint is.
    static var feedURL: URL {
        let s = UserDefaults.standard.string(forKey: "PEUpdateFeed")
            ?? ProcessInfo.processInfo.environment["POWEREMU_UPDATE_FEED"]
            ?? defaultFeed
        return URL(string: s) ?? URL(string: defaultFeed)!
    }

    static var runningVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }
    static var runningBuild: Int {
        Int(Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0") ?? 0
    }

    // MARK: from the command line
    //
    // `PowerEmu.app/Contents/MacOS/PowerEmu --update-check` says what the
    // feed offers and stops.  `--update-install` goes through with it.  Both
    // are here so the update path can be tried without clicking through the
    // app, and so somebody can be asked what their copy thinks is current
    // without being walked through a menu.

    @MainActor
    static func runCommandLine(_ args: [String], library: VMLibrary?) -> Bool {
        let wantsCheck = args.contains("--update-check")
        let wantsInstall = args.contains("--update-install")
        let wantsNotes = args.contains("--whats-new")
        guard wantsCheck || wantsInstall || wantsNotes else { return false }

        @Sendable func say(_ s: String) {
            FileHandle.standardError.write((s + "\n").data(using: .utf8)!)
        }
        say("PowerEmu \(runningVersion) (\(runningBuild))")
        say("feed: \(feedURL.absoluteString)")

        if wantsNotes {
            say("last opened as build \(UserDefaults.standard.integer(forKey: lastRunBuildKey))")
            if let c = notesForRunningBuild() {
                say("")
                say("What's new in \(c.version):")
                for l in c.notes.components(separatedBy: .newlines) { say("  " + l) }
            } else {
                say("no notes held for this build yet")
            }
            let older = history().filter { $0.build < runningBuild }
            if !older.isEmpty {
                say("")
                say("Earlier: " + older.map { "\($0.version) (\($0.build))" }.joined(separator: ", "))
            }
            if !wantsCheck && !wantsInstall { exit(0) }
        }

        Task { @MainActor in
            do {
                guard let u = try await check() else {
                    say("up to date")
                    exit(0)
                }
                say("available: \(u.version) (\(u.build))")
                say("  from: \(u.url.absoluteString)")
                say("  runs on this Mac: \(u.runsHere ? "yes" : "no, needs macOS \(u.minimumSystem ?? "?")")")
                guard wantsInstall else { exit(0) }
                let zip = try await download(u) { p in
                    if p >= 1 { say("  downloaded") }
                }
                say("  checked: intact")
                _ = try install(zip, library: library)
                say("installed; opening the new one")
                exit(0)
            } catch {
                say("failed: \(error.localizedDescription)")
                exit(1)
            }
        }
        return true
    }

    // MARK: looking

    /// Ask the feed what the newest build is.  Returns nil when this copy is
    /// already it.
    static func check() async throws -> AppUpdate? {
        var r = URLRequest(url: feedURL)
        r.cachePolicy = .reloadIgnoringLocalCacheData
        r.timeoutInterval = 20
        r.setValue("PowerEmu/\(runningVersion) (\(runningBuild))", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: r)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateError.badFeed
        }
        guard let version = j["version"] as? String,
              let link = j["url"] as? String, let url = URL(string: link) else {
            throw UpdateError.badFeed
        }
        let build = (j["build"] as? Int) ?? Int(j["build"] as? String ?? "") ?? 0
        var published: Date?
        if let s = j["published"] as? String {
            published = ISO8601DateFormatter().date(from: s)
        }
        let u = AppUpdate(version: version, build: build,
                          notes: (j["notes"] as? String) ?? "",
                          url: url, sha256: j["sha256"] as? String,
                          minimumSystem: j["minimumSystem"] as? String,
                          published: published)
        UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        /*
         * Keep what came back, so What's New has something to show when a
         * reader asks for it -- including for the version they are running,
         * which is not the one the feed is offering.
         */
        cacheHistory(from: j, current: u)
        return u.isNewer ? u : nil
    }

    // MARK: what changed

    private static let historyKey = "PEUpdateHistory"
    private static let lastRunBuildKey = "PELastRunBuild"

    /// Every release the feed knows about, newest first.  The feed carries
    /// its own entry and the ones before it, so one fetch answers both
    /// "what is new" and "what was new".
    private static func cacheHistory(from j: [String: Any], current: AppUpdate) {
        var rows: [[String: Any]] = [["version": current.version,
                                      "build": current.build,
                                      "notes": current.notes,
                                      "published": (j["published"] as? String) ?? ""]]
        for h in (j["history"] as? [[String: Any]]) ?? [] {
            guard let v = h["version"] as? String else { continue }
            let b = (h["build"] as? Int) ?? Int(h["build"] as? String ?? "") ?? 0
            guard b != current.build else { continue }
            rows.append(["version": v, "build": b,
                         "notes": (h["notes"] as? String) ?? "",
                         "published": (h["published"] as? String) ?? ""])
        }
        UserDefaults.standard.set(rows, forKey: historyKey)
    }

    static func history() -> [ReleaseNote] {
        let rows = UserDefaults.standard.array(forKey: historyKey) as? [[String: Any]] ?? []
        let iso = ISO8601DateFormatter()
        return rows.compactMap { r in
            guard let v = r["version"] as? String, let b = r["build"] as? Int else { return nil }
            return ReleaseNote(version: v, build: b,
                               published: iso.date(from: (r["published"] as? String) ?? ""),
                               notes: (r["notes"] as? String) ?? "")
        }.sorted { $0.build > $1.build }
    }

    /// What this copy is, if the feed has ever mentioned it.
    static func notesForRunningBuild() -> ReleaseNote? {
        history().first { $0.build == runningBuild }
    }

    /// True the first time a newer PowerEmu than last time is opened, so
    /// what changed can be shown once.  A first-ever run says nothing:
    /// there is no "since" to talk about.
    static func justUpdated() -> Bool {
        let d = UserDefaults.standard
        let previous = d.integer(forKey: lastRunBuildKey)
        d.set(runningBuild, forKey: lastRunBuildKey)
        return previous != 0 && runningBuild > previous
    }

    private static let lastCheckKey = "PEUpdateLastCheck"
    private static let skipKey = "PEUpdateSkipBuild"
    static let automaticKey = "PEUpdateAutomatically"

    /// Checking at most once a day, and never for a build the reader has
    /// already said no to.
    static func checkInBackground(library: VMLibrary?) async {
        let d = UserDefaults.standard
        guard d.object(forKey: automaticKey) == nil || d.bool(forKey: automaticKey) else { return }
        if let last = d.object(forKey: lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        guard let u = try? await check(), u.runsHere, d.integer(forKey: skipKey) != u.build else { return }
        await MainActor.run { UpdateWindowController.present(u, library: library) }
    }

    static func skip(_ u: AppUpdate) {
        UserDefaults.standard.set(u.build, forKey: skipKey)
    }

    // MARK: fetching

    /// Download into the machine library's Updates folder, which already
    /// holds downloads of this size and is not cleaned out behind our back.
    static func download(_ u: AppUpdate,
                         progress: @escaping @Sendable (Double) -> Void) async throws -> URL {
        let dir = VMLibrary.applicationSupport.appendingPathComponent("Updates", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("PowerEmu-\(u.version)-\(u.build).zip")
        try? FileManager.default.removeItem(at: dest)

        let (bytes, response) = try await URLSession.shared.bytes(from: u.url)
        let total = response.expectedContentLength
        FileManager.default.createFile(atPath: dest.path, contents: nil)
        let h = try FileHandle(forWritingTo: dest)
        defer { try? h.close() }
        var buf = Data(); buf.reserveCapacity(1 << 20)
        var done: Int64 = 0
        var hasher = SHA256()
        for try await b in bytes {
            buf.append(b)
            if buf.count >= 1 << 20 {
                hasher.update(data: buf)
                try h.write(contentsOf: buf)
                done += Int64(buf.count); buf.removeAll(keepingCapacity: true)
                if total > 0 { progress(Double(done) / Double(total)) }
            }
        }
        if !buf.isEmpty {
            hasher.update(data: buf)
            try h.write(contentsOf: buf)
            done += Int64(buf.count)
        }
        progress(1)

        if let want = u.sha256?.lowercased(), !want.isEmpty {
            let got = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            guard got == want else {
                try? FileManager.default.removeItem(at: dest)
                throw UpdateError.checksum
            }
        }
        return dest
    }

    // MARK: putting it in place

    /// Unpack, check it really is PowerEmu and really is ours, then swap it
    /// for the running copy and start that one instead.
    @MainActor
    static func install(_ zip: URL, library: VMLibrary?) throws -> Never? {
        let busy = (library?.machines.filter { $0.state != .stopped } ?? []).map { $0.config.name }
        guard busy.isEmpty else { throw UpdateError.machinesRunning(busy) }

        let fm = FileManager.default
        let staging = zip.deletingLastPathComponent()
            .appendingPathComponent("unpacked-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // ditto rather than unzip: it keeps the bundle's symlinks and the
        // signature with them, and unzip does not.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", zip.path, staging.path]
        let err = Pipe(); p.standardError = err
        try p.run(); p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            throw UpdateError.couldNotReplace(
                String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "could not unpack")
        }

        guard let app = (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil))?
                .first(where: { $0.pathExtension == "app" }),
              Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.notAnApp
        }
        try verifySignature(of: app)

        /*
         * The copy being replaced goes to the Trash rather than being
         * deleted: if anything about the new one turns out to be wrong, the
         * old one is still there to drag back.  trashItem says where it put
         * it and does it now, which NSWorkspace's recycle does neither of --
         * and without knowing where it went there is no putting it back.
         */
        let current = Bundle.main.bundleURL
        var trashed: NSURL?
        do {
            try fm.trashItem(at: current, resultingItemURL: &trashed)
        } catch {
            throw UpdateError.couldNotReplace("the copy in use could not be moved aside: "
                                              + error.localizedDescription)
        }
        do {
            try fm.moveItem(at: app, to: current)
        } catch {
            // Put the old one back rather than leave this Mac without PowerEmu.
            if let t = trashed as URL? { try? fm.moveItem(at: t, to: current) }
            throw UpdateError.couldNotReplace(error.localizedDescription)
        }
        try? fm.removeItem(at: zip)

        let cfg = NSWorkspace.OpenConfiguration()
        cfg.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: current, configuration: cfg) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
        return nil
    }

    /// The real check: the new copy must be signed, and signed by whoever
    /// signed the copy running now.  A checksum from the same place as the
    /// download would only prove the download matched what that place said.
    private static func verifySignature(of app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw UpdateError.unsigned("it could not be read")
        }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, nil)
        guard status == errSecSuccess else {
            throw UpdateError.unsigned("check failed, error \(status)")
        }
        guard teamIdentifier(of: code) == runningTeamIdentifier(), teamIdentifier(of: code) != nil else {
            throw UpdateError.differentDeveloper
        }
    }

    private static func teamIdentifier(of code: SecStaticCode) -> String? {
        var info: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                == errSecSuccess,
              let d = info as? [String: Any] else { return nil }
        return d[kSecCodeInfoTeamIdentifier as String] as? String
    }

    private static func runningTeamIdentifier() -> String? {
        var me: SecCode?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me else { return nil }
        var still: SecStaticCode?
        guard SecCodeCopyStaticCode(me, [], &still) == errSecSuccess, let still else { return nil }
        return teamIdentifier(of: still)
    }
}
