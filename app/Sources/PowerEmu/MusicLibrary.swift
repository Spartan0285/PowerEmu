import Foundation
import CryptoKit

/*
 * PowerMusic, inside PowerEmu.
 *
 * This Mac holds the music and does the playing: Apple's music can only be
 * decrypted by a modern browser signed in to an Apple Music subscription,
 * so a page on this Mac is the gramophone.  Everything else -- the queue,
 * what is playing, searching the catalogue, the artwork -- is served from
 * here, to old Macs that could never speak to Apple themselves.
 *
 * This file is the half that talks to Apple and remembers what is playing.
 * MusicServer.swift is the half the old Macs talk to.
 *
 * The API is the one the PowerPC controller already speaks, kept exactly as
 * it was when a Node server answered it, so nothing on the old Mac has to
 * change.
 */

// MARK: - Talking to Apple

/// Signs the developer token Apple's API wants, and asks it things.
///
/// The token is an ES256 JWT signed with the private key from the Apple
/// Developer portal.  It lasts six months, which is Apple's maximum, and is
/// made again when it is close to running out.
final class AppleMusicAPI: @unchecked Sendable {
    struct Settings {
        var teamID: String
        var keyID: String
        var keyPath: String
        var storefront: String
    }

    private let lock = NSLock()
    private var settings: Settings
    private var token: (value: String, expires: Date)?
    private var userToken: String?
    /// A whole library is thousands of songs and several seconds of asking;
    /// an old Mac opening its library twice should not pay for it twice.
    private var librarySongs: (data: [[String: Any]], at: Date)?
    private var stations: (data: [[String: Any]], at: Date)?
    private static let libraryCacheTTL: TimeInterval = 300
    private static let stationCacheTTL: TimeInterval = 3600

    init(_ s: Settings) { settings = s }

    func update(_ s: Settings) {
        lock.lock(); defer { lock.unlock() }
        if s.teamID != settings.teamID || s.keyID != settings.keyID || s.keyPath != settings.keyPath {
            token = nil                      // signed with what has just changed
        }
        if s.storefront != settings.storefront { stations = nil }
        settings = s
    }

    var storefront: String { lock.lock(); defer { lock.unlock() }; return settings.storefront }

    // MARK: the user's own token

    /// The player page sends this after the reader authorises Apple Music in
    /// it; it is what makes "my library" mean anything.  Kept in memory
    /// only: it is a credential, and a short-lived one.
    func setUserToken(_ t: String) { lock.lock(); userToken = t; lock.unlock() }
    var hasUserToken: Bool { lock.lock(); defer { lock.unlock() }; return userToken != nil }

    // MARK: the developer token

    enum MusicError: LocalizedError {
        case noKey(String)
        case badKey(String)
        case needsUserToken
        case apple(Int, String)

        var errorDescription: String? {
            switch self {
            case .noKey(let p): return "No Apple Music key at \(p)."
            case .badKey(let why): return "The Apple Music key could not be read: \(why)"
            case .needsUserToken: return "Music User Token not set. Authorize on the Player page first."
            case .apple(let code, _): return "Apple Music answered \(code)."
            }
        }
    }

    func developerToken() throws -> String {
        lock.lock(); defer { lock.unlock() }
        if let t = token, t.expires > Date().addingTimeInterval(300) { return t.value }
        let s = settings
        guard let pem = try? String(contentsOfFile: s.keyPath, encoding: .utf8) else {
            throw MusicError.noKey(s.keyPath)
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pem)
        } catch {
            throw MusicError.badKey(error.localizedDescription)
        }
        let now = Date()
        let exp = now.addingTimeInterval(60 * 60 * 24 * 180)     // Apple's maximum
        let header = ["alg": "ES256", "kid": s.keyID]
        let payload: [String: Any] = ["iss": s.teamID,
                                      "iat": Int(now.timeIntervalSince1970),
                                      "exp": Int(exp.timeIntervalSince1970)]
        let signingInput = Self.b64url(try JSONSerialization.data(withJSONObject: header))
            + "." + Self.b64url(try JSONSerialization.data(withJSONObject: payload))
        // rawRepresentation is r||s, which is what JWS wants; the DER form
        // Apple's own examples produce has to be unwrapped, and CryptoKit
        // saves us that.
        let sig = try key.signature(for: Data(signingInput.utf8))
        let jwt = signingInput + "." + Self.b64url(sig.rawRepresentation)
        token = (jwt, exp)
        return jwt
    }

    private static func b64url(_ d: Data) -> String {
        d.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    // MARK: asking

    private func get(_ url: String, user: Bool = false) throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.setValue("Bearer " + (try developerToken()), forHTTPHeaderField: "Authorization")
        if user {
            lock.lock(); let ut = userToken; lock.unlock()
            guard let ut else { throw MusicError.needsUserToken }
            req.setValue(ut, forHTTPHeaderField: "Music-User-Token")
        }
        req.timeoutInterval = 30
        // Deliberately synchronous: every caller is already on a connection's
        // own thread, one request at a time, and the shape of the Node server
        // this replaces was the same.
        let sem = DispatchSemaphore(value: 0)
        var out: Data?, status = 0, failure: Error?
        URLSession.shared.dataTask(with: req) { d, r, e in
            out = d; status = (r as? HTTPURLResponse)?.statusCode ?? 0; failure = e
            sem.signal()
        }.resume()
        sem.wait()
        if let failure { throw failure }
        guard (200..<300).contains(status) else {
            throw MusicError.apple(status, String(decoding: out ?? Data(), as: UTF8.self))
        }
        return (try? JSONSerialization.jsonObject(with: out ?? Data())) as? [String: Any] ?? [:]
    }

    private func escaped(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private var base: String { "https://api.music.apple.com/v1" }

    // MARK: the catalogue

    func searchSongs(_ q: String, limit: Int = 25) throws -> [[String: Any]] {
        let s = storefront
        let d = try get("\(base)/catalog/\(s)/search?term=\(escaped(q))&types=songs&limit=\(limit)")
        let songs = ((d["results"] as? [String: Any])?["songs"] as? [String: Any])?["data"] as? [[String: Any]] ?? []
        return songs.map(Self.song)
    }

    func searchCollections(_ q: String, limit: Int = 25) throws -> [[String: Any]] {
        let s = storefront
        let d = try get("\(base)/catalog/\(s)/search?term=\(escaped(q))&types=playlists,albums&limit=\(limit)")
        let results = d["results"] as? [String: Any] ?? [:]
        var out: [[String: Any]] = []
        for p in (results["playlists"] as? [String: Any])?["data"] as? [[String: Any]] ?? [] {
            let a = p["attributes"] as? [String: Any] ?? [:]
            out.append(["id": p["id"] as? String ?? "",
                        "name": a["name"] as? String ?? "Untitled",
                        "curatorName": a["curatorName"] as? String ?? "",
                        "description": (a["description"] as? [String: Any])?["short"] as? String ?? "",
                        "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                        "trackCount": NSNull(),
                        "kind": "playlist"])
        }
        for al in (results["albums"] as? [String: Any])?["data"] as? [[String: Any]] ?? [] {
            let a = al["attributes"] as? [String: Any] ?? [:]
            out.append(["id": al["id"] as? String ?? "",
                        "name": a["name"] as? String ?? "Untitled",
                        "curatorName": a["artistName"] as? String ?? "",
                        "description": "",
                        "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                        "trackCount": a["trackCount"] as Any? ?? NSNull(),
                        "kind": "album"])
        }
        return out
    }

    func collectionTracks(_ id: String, kind: String) throws -> [[String: Any]] {
        let s = storefront
        let resource = kind == "playlist" ? "playlists" : "albums"
        let d = try get("\(base)/catalog/\(s)/\(resource)/\(id)/tracks?limit=100")
        return (d["data"] as? [[String: Any]] ?? []).map(Self.song)
    }

    // MARK: the reader's own library

    func libraryClearCache() { lock.lock(); librarySongs = nil; lock.unlock() }

    func librarySongs(offset: Int) throws -> [[String: Any]] {
        if offset == 0 {
            lock.lock()
            let c = librarySongs
            lock.unlock()
            if let c, Date().timeIntervalSince(c.at) < Self.libraryCacheTTL { return c.data }
        }
        var all: [[String: Any]] = []
        var at = offset
        let page = 100
        while true {
            let d = try get("\(base)/me/library/songs?limit=\(page)&offset=\(at)", user: true)
            let items = (d["data"] as? [[String: Any]] ?? []).map(Self.librarySong)
            all += items
            guard d["next"] != nil, items.count == page else { break }
            at += page
        }
        if offset == 0 {
            lock.lock(); librarySongs = (all, Date()); lock.unlock()
        }
        return all
    }

    func libraryPlaylists() throws -> [[String: Any]] {
        try pagedCollections("\(base)/me/library/playlists", kind: "playlist")
    }

    func libraryAlbums() throws -> [[String: Any]] {
        try pagedCollections("\(base)/me/library/albums", kind: "album")
    }

    private func pagedCollections(_ url: String, kind: String) throws -> [[String: Any]] {
        var all: [[String: Any]] = []
        var at = 0
        let page = 100
        while true {
            let d = try get("\(url)?limit=\(page)&offset=\(at)", user: true)
            let items = (d["data"] as? [[String: Any]] ?? []).map { item -> [String: Any] in
                let a = item["attributes"] as? [String: Any] ?? [:]
                return ["id": item["id"] as? String ?? "",
                        "name": a["name"] as? String ?? "Untitled",
                        "curatorName": kind == "album" ? (a["artistName"] as? String ?? "") : "",
                        "description": (a["description"] as? [String: Any])?["standard"] as? String ?? "",
                        "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                        "trackCount": kind == "album" ? (a["trackCount"] as Any? ?? NSNull()) : NSNull(),
                        "kind": kind]
            }
            all += items
            guard d["next"] != nil, items.count == page else { break }
            at += page
        }
        return all
    }

    func libraryPlaylistTracks(_ id: String) throws -> [[String: Any]] {
        let d = try get("\(base)/me/library/playlists/\(id)/tracks?limit=100", user: true)
        return (d["data"] as? [[String: Any]] ?? []).map(Self.librarySong)
    }

    func recentlyPlayed(limit: Int = 10) throws -> [[String: Any]] {
        let d = try get("\(base)/me/recent/played?limit=\(limit)", user: true)
        return (d["data"] as? [[String: Any]] ?? []).compactMap(Self.recentItem)
    }

    func heavyRotation(limit: Int = 10) throws -> [[String: Any]] {
        let d = try get("\(base)/me/history/heavy-rotation?limit=\(limit)", user: true)
        return (d["data"] as? [[String: Any]] ?? []).compactMap(Self.recentItem)
    }

    func recommendations(limit: Int = 10) throws -> [[String: Any]] {
        let d = try get("\(base)/me/recommendations?limit=\(limit)", user: true)
        return (d["data"] as? [[String: Any]] ?? []).map { rec in
            let a = rec["attributes"] as? [String: Any] ?? [:]
            let contents = (rec["relationships"] as? [String: Any])?["contents"] as? [String: Any]
            return ["id": rec["id"] as? String ?? "",
                    "title": (a["title"] as? [String: Any])?["stringForDisplay"] as? String ?? "For You",
                    "items": (contents?["data"] as? [[String: Any]] ?? []).compactMap(Self.recentItem)]
        }
    }

    // MARK: radio

    func radioStations(limit: Int = 50) throws -> [[String: Any]] {
        lock.lock(); let c = stations; lock.unlock()
        if let c, Date().timeIntervalSince(c.at) < Self.stationCacheTTL { return c.data }

        let s = storefront
        let genresDoc = try get("\(base)/catalog/\(s)/station-genres")
        let genres = (genresDoc["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        var seen = Set<String>()
        var out: [[String: Any]] = []
        for g in genres {
            // One bad genre should not cost the reader the whole list.
            guard let d = try? get("\(base)/catalog/\(s)/station-genres/\(g)/stations?limit=\(limit)") else { continue }
            for st in d["data"] as? [[String: Any]] ?? [] {
                guard let id = st["id"] as? String, !seen.contains(id) else { continue }
                seen.insert(id)
                let a = st["attributes"] as? [String: Any] ?? [:]
                out.append(["id": id,
                            "name": a["name"] as? String ?? "Station",
                            "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                            "isLive": a["isLive"] as? Bool ?? false])
            }
        }
        lock.lock(); stations = (out, Date()); lock.unlock()
        return out
    }

    // MARK: what Apple's answers look like here

    private static func song(_ s: [String: Any]) -> [String: Any] {
        let a = s["attributes"] as? [String: Any] ?? [:]
        let ms = a["durationInMillis"] as? Double ?? 0
        return ["id": s["id"] as? String ?? "",
                "title": a["name"] as? String ?? "Unknown",
                "artist": a["artistName"] as? String ?? "Unknown",
                "album": a["albumName"] as? String ?? "",
                "durationSeconds": Int((ms / 1000).rounded()),
                "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull()]
    }

    /// A song in the reader's library plays by its catalogue identifier, not
    /// by the library's own; the player would find nothing with the latter.
    private static func librarySong(_ s: [String: Any]) -> [String: Any] {
        let a = s["attributes"] as? [String: Any] ?? [:]
        let ms = a["durationInMillis"] as? Double ?? 0
        let catalogID = (a["playParams"] as? [String: Any])?["catalogId"] as? String ?? s["id"] as? String ?? ""
        return ["id": catalogID,
                "title": a["name"] as? String ?? "Unknown",
                "artist": a["artistName"] as? String ?? "Unknown",
                "album": a["albumName"] as? String ?? "",
                "durationSeconds": Int((ms / 1000).rounded()),
                "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull()]
    }

    private static func recentItem(_ item: [String: Any]) -> [String: Any]? {
        let a = item["attributes"] as? [String: Any] ?? [:]
        switch item["type"] as? String ?? "" {
        case "songs", "library-songs":
            return song(item)
        case "albums", "library-albums":
            return ["id": item["id"] as? String ?? "",
                    "name": a["name"] as? String ?? "Untitled",
                    "curatorName": a["artistName"] as? String ?? "",
                    "description": "",
                    "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                    "trackCount": a["trackCount"] as Any? ?? NSNull(),
                    "kind": "album"]
        case "playlists", "library-playlists":
            return ["id": item["id"] as? String ?? "",
                    "name": a["name"] as? String ?? "Untitled",
                    "curatorName": a["curatorName"] as? String ?? "",
                    "description": (a["description"] as? [String: Any])?["short"] as? String ?? "",
                    "artworkUrl": (a["artwork"] as? [String: Any])?["url"] as Any? ?? NSNull(),
                    "trackCount": NSNull(),
                    "kind": "playlist"]
        default:
            return nil                      // stations and the rest
        }
    }
}

// MARK: - What is playing

/// The queue and the playing state, shared by every device looking at it.
///
/// One of the connected devices is the player -- the page on this Mac that
/// actually makes the sound -- and it claims that role; the rest are
/// controllers, and what they do here is what the player then does.
final class MusicStore: @unchecked Sendable {
    private let lock = NSLock()
    private let file: URL

    private var currentTrackID: String?
    private var queue: [String] = []
    private var meta: [String: [String: Any]] = [:]
    private var playing = false
    private var position: Double = 0
    private var duration: Double?
    private var volume: Double = 1
    private var repeatMode = "off"
    private var shuffle = false
    private var playerID: String?
    private var playerMeta: [String: Any]?

    /// Told whenever anything changes, so the server can tell the devices.
    var onChange: (@Sendable () -> Void)?

    init(file: URL) {
        self.file = file
        restore()
        if queue.isEmpty { adoptEarlierQueue() }
    }

    /// The queue PowerMusic kept when it was a separate server, taken over
    /// the first time PowerEmu runs it: a reader who has been using it
    /// should not find their evening's queue gone.  Read once, and only
    /// when there is nothing here to lose.
    private func adoptEarlierQueue() {
        let old = URL(fileURLWithPath: NSHomeDirectory() + "/PowerMusic/data/state.json")
        guard let d = try? Data(contentsOf: old),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
              let q = j["queue"] as? [String], !q.isEmpty else { return }
        currentTrackID = j["currentTrackId"] as? String
        queue = q
        meta = j["trackMeta"] as? [String: [String: Any]] ?? [:]
        volume = j["volume"] as? Double ?? 1
        repeatMode = j["repeatMode"] as? String ?? "off"
        shuffle = j["shuffle"] as? Bool ?? false
        position = j["positionSeconds"] as? Double ?? 0
        persist()
    }

    // MARK: reading

    func snapshot() -> [String: Any] {
        lock.lock(); defer { lock.unlock() }
        return unlockedSnapshot()
    }

    private func unlockedSnapshot() -> [String: Any] {
        ["currentTrackId": currentTrackID as Any? ?? NSNull(),
         "queue": queue,
         "trackMeta": meta,
         "isPlaying": playing,
         "positionSeconds": position,
         "durationSeconds": duration as Any? ?? NSNull(),
         "volume": volume,
         "repeatMode": repeatMode,
         "shuffle": shuffle,
         "activePlayerId": playerID as Any? ?? NSNull(),
         "activePlayerMeta": playerMeta as Any? ?? NSNull()]
    }

    // MARK: keeping it

    private func restore() {
        guard let d = try? Data(contentsOf: file),
              let j = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return }
        currentTrackID = j["currentTrackId"] as? String
        queue = j["queue"] as? [String] ?? []
        meta = j["trackMeta"] as? [String: [String: Any]] ?? [:]
        volume = j["volume"] as? Double ?? 1
        repeatMode = j["repeatMode"] as? String ?? "off"
        shuffle = j["shuffle"] as? Bool ?? false
        position = j["positionSeconds"] as? Double ?? 0
        playing = false                     // nothing is playing at a standing start
    }

    /// Only what should outlive PowerEmu: not who the player was, nor
    /// whether sound was coming out of it.
    private func persist() {
        let j: [String: Any] = ["currentTrackId": currentTrackID as Any? ?? NSNull(),
                                "queue": queue,
                                "trackMeta": meta,
                                "volume": volume,
                                "repeatMode": repeatMode,
                                "shuffle": shuffle,
                                "positionSeconds": position]
        guard let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted]) else { return }
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? d.write(to: file, options: .atomic)
    }

    /// Changed, saved, and everyone told.
    private func changed() {
        persist()
        let cb = onChange
        lock.unlock()
        cb?()
        lock.lock()
    }

    // MARK: who is playing

    func claimPlayer(id: String, device: String, ip: String, userAgent: String, force: Bool) -> (granted: Bool, meta: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        if !force, playerID != nil, !staleUnlocked() {
            return (false, playerMeta)
        }
        playerID = id
        playerMeta = ["deviceName": device, "ip": ip, "userAgent": userAgent,
                      "lastSeen": Date().timeIntervalSince1970 * 1000]
        changed()
        return (true, playerMeta)
    }

    func clearPlayer(ifID id: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let id, playerID != id { return }
        guard playerID != nil || playerMeta != nil else { return }
        playerID = nil
        playerMeta = nil
        changed()
    }

    func isPlayer(_ id: String) -> Bool { lock.lock(); defer { lock.unlock() }; return playerID == id }

    func heartbeat(_ id: String) {
        lock.lock(); defer { lock.unlock() }
        guard playerID == id, var m = playerMeta else { return }
        m["lastSeen"] = Date().timeIntervalSince1970 * 1000
        playerMeta = m
    }

    /// A player that has not been heard from for ten seconds has gone: a
    /// closed tab says nothing, and without this the role would be held for
    /// ever by a device that is no longer there.
    private func staleUnlocked() -> Bool {
        guard let m = playerMeta, let seen = m["lastSeen"] as? Double else { return true }
        return Date().timeIntervalSince1970 * 1000 - seen > 10_000
    }

    func dropStalePlayer() {
        lock.lock(); defer { lock.unlock() }
        guard playerID != nil, staleUnlocked() else { return }
        playerID = nil
        playerMeta = nil
        changed()
    }

    // MARK: position

    /// Sent several times a second by the player: told to the others, but
    /// not written to disk each time.
    func updatePosition(_ seconds: Double, duration d: Double?) {
        lock.lock()
        position = seconds
        if let d { duration = d }
        let cb = onChange
        lock.unlock()
        cb?()
    }

    // MARK: the queue

    func add(_ id: String, meta m: [String: Any]?) {
        lock.lock(); defer { lock.unlock() }
        queue.append(id)
        if let m { meta[id] = m }
        if currentTrackID == nil {
            currentTrackID = id
            position = 0
            duration = m?["durationSeconds"] as? Double
        }
        changed()
    }

    func remove(at index: Int) {
        lock.lock(); defer { lock.unlock() }
        guard index >= 0, index < queue.count else { return }
        let removed = queue.remove(at: index)
        if currentTrackID == removed {
            if queue.isEmpty {
                currentTrackID = nil; position = 0; duration = nil; playing = false
            } else {
                let next = index < queue.count ? index : 0
                currentTrackID = queue[next]
                position = 0
                duration = meta[queue[next]]?["durationSeconds"] as? Double
            }
        }
        cleanMeta()
        changed()
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        queue = []; meta = [:]; currentTrackID = nil
        playing = false; position = 0; duration = nil
        changed()
    }

    /// Anything no longer in the queue is no longer worth remembering: a
    /// long evening of searching would otherwise keep every track ever
    /// queued in memory and on disk.
    private func cleanMeta() {
        var inUse = Set(queue)
        if let c = currentTrackID { inUse.insert(c) }
        meta = meta.filter { inUse.contains($0.key) }
    }

    /// An album or playlist replaces the queue wholesale, rather than being
    /// appended to it.
    func setContext(_ tracks: [[String: Any]], start: String) {
        lock.lock(); defer { lock.unlock() }
        queue = tracks.compactMap { $0["id"] as? String }
        meta = [:]
        for t in tracks { if let id = t["id"] as? String { meta[id] = t } }
        currentTrackID = start
        position = 0
        duration = meta[start]?["durationSeconds"] as? Double
        playing = true
        changed()
    }

    // MARK: the controls

    func play(_ id: String?) {
        lock.lock(); defer { lock.unlock() }
        if let id {
            if !queue.contains(id) { queue.append(id) }
            currentTrackID = id
            position = 0
            duration = meta[id]?["durationSeconds"] as? Double
        }
        if currentTrackID != nil { playing = true }
        changed()
    }

    func pause() {
        lock.lock(); defer { lock.unlock() }
        playing = false
        changed()
    }

    func next() {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return }
        let current = currentTrackID.flatMap { queue.firstIndex(of: $0) } ?? -1
        var next: Int
        if repeatMode == "one" {
            next = current >= 0 ? current : 0
        } else if shuffle {
            if queue.count <= 1 {
                next = 0
            } else {
                repeat { next = Int.random(in: 0..<queue.count) } while next == current
            }
        } else {
            next = current + 1
            if next >= queue.count {
                if repeatMode == "all" {
                    next = 0
                } else {
                    playing = false
                    changed()
                    return
                }
            }
        }
        currentTrackID = queue[next]
        position = 0
        duration = meta[queue[next]]?["durationSeconds"] as? Double
        changed()
    }

    /// Back, or back to the beginning of this one: pressing it a few seconds
    /// in means "start this again", as it does on every other music player.
    func previous() {
        lock.lock(); defer { lock.unlock() }
        guard !queue.isEmpty else { return }
        if position > 3 {
            position = 0
            changed()
            return
        }
        let current = currentTrackID.flatMap { queue.firstIndex(of: $0) } ?? 0
        var prev = current - 1
        if prev < 0 { prev = repeatMode == "all" ? queue.count - 1 : 0 }
        currentTrackID = queue[prev]
        position = 0
        duration = meta[queue[prev]]?["durationSeconds"] as? Double
        changed()
    }

    func seek(_ seconds: Double) {
        lock.lock(); defer { lock.unlock() }
        position = max(0, seconds)
        changed()
    }

    func setVolume(_ v: Double) {
        lock.lock(); defer { lock.unlock() }
        volume = min(1, max(0, v))
        changed()
    }

    func setRepeat(_ mode: String) {
        lock.lock(); defer { lock.unlock() }
        repeatMode = mode
        changed()
    }

    func setShuffle(_ on: Bool) {
        lock.lock(); defer { lock.unlock() }
        shuffle = on
        changed()
    }
}
