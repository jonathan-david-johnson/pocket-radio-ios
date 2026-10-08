import Foundation
import Kingfisher
@testable import podcasts

/// M13.1 harness. One object that owns the fake outside world: ICY stream, artwork server,
/// and the tracklist / iTunes fixtures served through `NetworkGuard`.
final class FakeWorld {
    struct FakeSong: Equatable {
        var title: String
        var artist: String
        var album: String = "Album"
        /// Colour name for the tracklist's `albumImageLarge`. nil = JSON null.
        var art: String?
        /// Colour the iTunes fallback returns. nil = empty result.
        var itunesArt: String?
        var artDelay: TimeInterval = 0

        init(title: String, artist: String, album: String = "Album", art: String? = nil,
             itunesArt: String? = nil, artDelay: TimeInterval = 0) {
            self.title = title; self.artist = artist; self.album = album
            self.art = art; self.itunesArt = itunesArt; self.artDelay = artDelay
        }
    }

    enum Endpoint { case tracklist, itunes }

    struct WorldError: Error, CustomStringConvertible {
        let description: String
    }

    static let tracklistHost = "tracklist-api.kcrw.com"
    static let itunesHost = "itunes.apple.com"
    static let kcrwTracklistURL = "https://tracklist-api.kcrw.com/Music/all/1?page_size=10"
    /// Newest tracklist row; each older row is `rowSpacing` earlier.
    static let baseDate = Date(timeIntervalSince1970: 1_791_100_800) // 2026-10-04T08:00:00Z
    static let rowSpacing: TimeInterval = 180

    static func playedAt(index: Int) -> Date { baseDate.addingTimeInterval(-rowSpacing * Double(index)) }

    let icy: IcyStreamServer
    let artwork = ArtworkServer()
    private(set) var otherIcy: IcyStreamServer?
    let otherStationID = UUID().uuidString.lowercased()

    private let lock = NSLock()
    private var tracklist: [FakeSong] = []
    private var includeBreak = false
    private var latencies: [Endpoint: TimeInterval] = [:]
    private var failures: [Endpoint: Int] = [:]
    private var knownSongs: [FakeSong] = []
    private var servedITunesTerms: [String] = []
    private var songArtworkURLs: [String: URL] = [:]
    private var started = false
    private var savedTimeout: TimeInterval?

    init(initial song: FakeSong? = nil) throws {
        icy = try IcyStreamServer(initialTitle: song.map { Self.icyTitle($0) } ?? "")
        if let song { knownSongs = [song] }
    }

    /// Album-bearing KCRW triple, or the parser's artist/title pair with no album.
    static func icyTitle(_ song: FakeSong, includesAlbum: Bool = true) -> String {
        includesAlbum ? "\(song.title)-\(song.artist)-\(song.album)" : "\(song.artist) - \(song.title)"
    }

    // MARK: Lifecycle

    func start() throws {
        guard !started else { return }
        lock.lock(); servedITunesTerms = []; lock.unlock()
        try icy.start()
        try artwork.start()
        NetworkGuard.install(fixtures: [
            Self.tracklistHost: { [weak self] req in self?.serveTracklist(req) ?? (503, Data(), "text/plain") },
            Self.itunesHost: { [weak self] req in self?.serveITunes(req) ?? (503, Data(), "text/plain") }
        ], requestFixtures: [{ [weak self] request in self?.serveLyricsIfMatched(request) }])
        applyDelays()
        NetworkGuard.attachToKingfisher()
        savedTimeout = KingfisherManager.shared.downloader.downloadTimeout
        KingfisherManager.shared.downloader.downloadTimeout = 60
        started = true
    }

    func stop() {
        guard started else { return }
        started = false
        NetworkGuard.detachFromKingfisher()
        NetworkGuard.uninstall()
        if let savedTimeout { KingfisherManager.shared.downloader.downloadTimeout = savedTimeout }
        savedTimeout = nil
        icy.stop()
        otherIcy?.stop()
        otherIcy = nil
        artwork.stop()
    }

    deinit { stop() }

    // MARK: Scripting

    func play(_ song: FakeSong, includesAlbum: Bool = true) {
        lock.lock(); knownSongs.append(song); lock.unlock()
        icy.setTitle(Self.icyTitle(song, includesAlbum: includesAlbum))
    }

    /// First entry is the most recent. `includeBreakRow` adds a `[BREAK]` row on top.
    func setTracklist(_ entries: [FakeSong], includeBreakRow: Bool = false) {
        lock.lock(); tracklist = entries; includeBreak = includeBreakRow; knownSongs.append(contentsOf: entries); lock.unlock()
    }

    /// Current tracklist fixture for focused harness self-tests.
    var configuredTracklist: [FakeSong] {
        lock.lock(); defer { lock.unlock() }
        return tracklist
    }

    /// Adds a row to the current fixture without replacing earlier rows.
    func appendTracklist(_ entry: FakeSong) {
        lock.lock(); tracklist.append(entry); knownSongs.append(entry); lock.unlock()
    }

    /// Configures (or replaces) the iTunes artwork result for the matching song.
    func setITunesArtwork(_ colour: String?, for title: String, artist: String) {
        lock.lock()
        if let index = knownSongs.lastIndex(where: { $0.title == title && $0.artist == artist }) {
            knownSongs[index].itunesArt = colour
        } else {
            knownSongs.append(FakeSong(title: title, artist: artist, itunesArt: colour))
        }
        lock.unlock()
    }

    func wasITunesLookupServed(for title: String, artist: String) -> Bool {
        let expected = "\(artist) \(title)".trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock(); defer { lock.unlock() }
        return servedITunesTerms.contains(expected)
    }

    func setLatency(_ endpoint: Endpoint, seconds: TimeInterval) {
        lock.lock(); latencies[endpoint] = seconds; lock.unlock()
        applyDelays()
    }

    func fail(_ endpoint: Endpoint, status: Int) {
        lock.lock(); failures[endpoint] = status; lock.unlock()
    }

    func clearFailures() {
        lock.lock(); failures = [:]; lock.unlock()
    }

    func dropStream() { icy.dropStream() }
    func sendAdFrame() { icy.sendAdFrame() }

    // MARK: Station

    var streamURL: String { "http://127.0.0.1:\(icy.port)/stream" }

    static func isLoopback(_ host: String?) -> Bool {
        guard let host = host?.lowercased() else { return false }
        return host == "127.0.0.1" || host == "localhost" || host == "::1"
    }

    /// AVPlayer traffic bypasses `NetworkGuard`, so a non-loopback stream URL is rejected outright.
    func makeStation(name: String = "KCRW Eclectic 24",
                     streamUrl: String? = nil,
                     tracklistUrl: String? = FakeWorld.kcrwTracklistURL,
                     logoAsset: String? = "kcrw_logo") throws -> RadioStation {
        let stream = streamUrl ?? self.streamURL
        guard Self.isLoopbackURL(stream) else {
            throw WorldError(description: "FakeWorld refuses non-loopback stream URL '\(stream)': AVPlayer traffic bypasses NetworkGuard, so only 127.0.0.1/localhost/::1 is allowed")
        }
        return RadioStation(stationId: "6238f5e8-a9ee-4c88-9713-2d1ab4112ac9", name: name, streamUrl: stream,
                            tracklistUrl: tracklistUrl, logoAsset: logoAsset)
    }

    /// Exactly one world owns the process-wide guard, including both independent ICY servers.
    func makeOtherStation() throws -> RadioStation {
        guard started else { throw WorldError(description: "second station requires the guarded world to be started") }
        if otherIcy == nil {
            let server = try IcyStreamServer(initialTitle: "")
            try server.start()
            otherIcy = server
            HarnessReset.track(stationId: otherStationID)
        }
        return RadioStation(stationId: otherStationID, name: "Other Local Station",
                            streamUrl: "http://127.0.0.1:\(otherIcy!.port)/stream", tracklistUrl: nil, logoAsset: "kcrw_logo")
    }

    static func isLoopbackURL(_ value: String) -> Bool {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.user == nil, url.password == nil, isLoopback(url.host) else { return false }
        return true
    }

    /// The URL actually supplied in the tracklist, queried by exact song identity, not colour/path.
    func artworkURL(for title: String, artist: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return songArtworkURLs["\(title)\u{1F}\(artist)"]
    }

    func artworkEvents(for title: String, artist: String) -> [ArtworkServer.Event] {
        guard let url = artworkURL(for: title, artist: artist),
              let parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return [] }
        let target = parts.percentEncodedPath + (parts.percentEncodedQuery.map { "?" + $0 } ?? "")
        return artwork.events.filter { $0.target == target }
    }

    // MARK: Inspection

    /// One line naming each configured latency and failure with its host, for failure messages.
    var faultSummary: String {
        lock.lock(); defer { lock.unlock() }
        func host(_ e: Endpoint) -> String { e == .tracklist ? Self.tracklistHost : Self.itunesHost }
        var parts: [String] = []
        for (e, status) in failures.sorted(by: { host($0.key) < host($1.key) }) { parts.append("\(host(e)) fails with HTTP \(status)") }
        for (e, seconds) in latencies.sorted(by: { host($0.key) < host($1.key) }) where seconds > 0 { parts.append("\(host(e)) is delayed \(seconds) s") }
        return parts.isEmpty ? "faults: none" : "faults: " + parts.joined(separator: "; ")
    }

    var served: [NetworkGuard.Record] { NetworkGuard.records.filter { $0.outcome == .served } }
    var blocked: [NetworkGuard.Record] { NetworkGuard.records.filter { $0.outcome == .blocked } }

    /// Hosts that are still blocked but do not fail a scenario. Empty on the simulator. On a signed-in device
    /// (`CARPLAY_ON_DEVICE=1`) the real app talks to its account and favorites backends in the background.
    static var toleratedHosts: [String] {
        HarnessReset.isDeviceRun ? ["api.pocketcasts.com", "supabase.co"] : []
    }

    private static func isTolerated(_ host: String) -> Bool {
        toleratedHosts.contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// Requests that were blocked and tolerated (device runs only), for the log.
    var toleratedRequests: [NetworkGuard.Record] { blocked.filter { Self.isTolerated($0.host) } }

    func unexpectedRequestReport() -> String? {
        let hits = blocked.filter { !Self.isTolerated($0.host) }
        guard !hits.isEmpty else { return nil }
        var lines = ["Harness blocked \(hits.count) unexpected request(s):"]
        for r in hits {
            lines.append("  - host \(r.host) path \(r.path)" + (r.caller.map { " (caller: \($0))" } ?? ""))
        }
        return lines.joined(separator: "\n")
    }

    // MARK: Fixtures

    private func applyDelays() {
        lock.lock(); let t = latencies[.tracklist] ?? 0, i = latencies[.itunes] ?? 0; lock.unlock()
        NetworkGuard.setDelay(host: Self.tracklistHost, seconds: t)
        NetworkGuard.setDelay(host: Self.itunesHost, seconds: i)
    }

    private func artURL(_ colour: String, suffix: String, identity: String = "fixture", delay: TimeInterval = 0) -> String {
        var parts = URLComponents(string: "http://127.0.0.1:\(artwork.port)/art/\(colour)-\(suffix).png")!
        parts.queryItems = [URLQueryItem(name: "song", value: identity)]
        if delay > 0 { parts.queryItems?.append(URLQueryItem(name: "delay", value: "\(delay)")) }
        return parts.url!.absoluteString
    }

    private func serveTracklist(_ request: URLRequest) -> (Int, Data, String) {
        lock.lock(); let status = failures[.tracklist]; let songs = tracklist; let withBreak = includeBreak; lock.unlock()
        if let status { return (status, Data("{}".utf8), "application/json") }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        iso.timeZone = TimeZone(identifier: "UTC")
        var rows: [[String: Any]] = []
        if withBreak {
            rows.append(["title": "[BREAK]", "artist": "[BREAK]", "album": NSNull(), "albumImage": NSNull(),
                         "albumImageLarge": NSNull(), "datetime": iso.string(from: Self.playedAt(index: 0))])
        }
        for (i, s) in songs.enumerated() {
            let identity = "\(s.title)\u{1F}\(s.artist)"
            let url = s.art.map { artURL($0, suffix: "large", identity: identity, delay: s.artDelay) }
            lock.lock(); songArtworkURLs[identity] = url.flatMap(URL.init(string:)); lock.unlock()
            rows.append(["title": s.title, "artist": s.artist, "album": s.album, "albumImage": NSNull(),
                         "albumImageLarge": url ?? NSNull(),
                         "datetime": iso.string(from: Self.playedAt(index: i + (withBreak ? 1 : 0)))])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        return (200, data, "application/json")
    }

    /// The real detail controller may ask for lyrics, but only these scripted songs and exact
    /// read endpoints are fixtures. Unknown songs, paths and methods still fail the guard.
    private func serveLyricsIfMatched(_ request: URLRequest) -> (Int, Data, String)? {
        guard request.httpMethod == "GET", let url = request.url, url.host == "lrclib.net",
              ["/api/get", "/api/search"].contains(url.path),
              let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return nil }
        let allowed = url.path == "/api/get" ? ["artist_name", "track_name", "album_name"] : ["artist_name", "track_name"]
        guard query.allSatisfy({ allowed.contains($0.name) }), Set(query.map(\.name)).count == query.count else { return nil }
        let title = query.first { $0.name == "track_name" }?.value
        let artist = query.first { $0.name == "artist_name" }?.value
        let album = query.first { $0.name == "album_name" }?.value
        lock.lock(); let songs = knownSongs; lock.unlock()
        guard songs.contains(where: { $0.artist == artist && LyricsService.sanitize($0.title) == title &&
            (album == nil || LyricsService.sanitize($0.album) == album) }) else { return nil }
        return url.path == "/api/get" ? (404, Data("{}".utf8), "application/json") : (200, Data("[]".utf8), "application/json")
    }

    private func serveITunes(_ request: URLRequest) -> (Int, Data, String) {
        let term = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "term" }?.value?.lowercased() ?? ""
        lock.lock()
        let status = failures[.itunes], songs = knownSongs
        if request.url?.path == "/search", request.httpMethod == "GET", status == nil { servedITunesTerms.append(term) }
        lock.unlock()
        if let status { return (status, Data("{}".utf8), "application/json") }
        // Prefer the most recently configured matching song, so an updated fixture wins over stale history.
        let hit = songs.reversed().first { $0.itunesArt != nil && term == "\($0.artist) \($0.title)".trimmingCharacters(in: .whitespaces).lowercased() }
        let body: String
        if let hit, let colour = hit.itunesArt {
            body = #"{"resultCount":1,"results":[{"artworkUrl100":"\#(artURL(colour, suffix: "100x100bb", identity: "itunes-\(hit.title)-\(hit.artist)"))"}]}"#
        } else {
            body = #"{"resultCount":0,"results":[]}"#
        }
        return (200, Data(body.utf8), "application/json")
    }
}
