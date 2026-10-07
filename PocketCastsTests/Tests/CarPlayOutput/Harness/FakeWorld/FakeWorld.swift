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

    private let lock = NSLock()
    private var tracklist: [FakeSong] = []
    private var includeBreak = false
    private var latencies: [Endpoint: TimeInterval] = [:]
    private var failures: [Endpoint: Int] = [:]
    private var knownSongs: [FakeSong] = []
    private var started = false
    private var savedTimeout: TimeInterval?

    init(initial song: FakeSong? = nil) throws {
        icy = try IcyStreamServer(initialTitle: song.map(Self.icyTitle) ?? "")
        if let song { knownSongs = [song] }
    }

    /// KCRW's unspaced shape: `Title-Artist-Album`.
    static func icyTitle(_ song: FakeSong) -> String { "\(song.title)-\(song.artist)-\(song.album)" }

    // MARK: Lifecycle

    func start() throws {
        guard !started else { return }
        try icy.start()
        try artwork.start()
        NetworkGuard.install(fixtures: [
            Self.tracklistHost: { [weak self] req in self?.serveTracklist(req) ?? (503, Data(), "text/plain") },
            Self.itunesHost: { [weak self] req in self?.serveITunes(req) ?? (503, Data(), "text/plain") }
        ])
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
        artwork.stop()
    }

    deinit { stop() }

    // MARK: Scripting

    func play(_ song: FakeSong) {
        lock.lock(); knownSongs.append(song); lock.unlock()
        icy.setTitle(Self.icyTitle(song))
    }

    /// First entry is the most recent. `includeBreakRow` adds a `[BREAK]` row on top.
    func setTracklist(_ entries: [FakeSong], includeBreakRow: Bool = false) {
        lock.lock(); tracklist = entries; includeBreak = includeBreakRow; knownSongs.append(contentsOf: entries); lock.unlock()
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
        guard Self.isLoopback(URL(string: stream)?.host) else {
            throw WorldError(description: "FakeWorld refuses non-loopback stream URL '\(stream)': AVPlayer traffic bypasses NetworkGuard, so only 127.0.0.1/localhost/::1 is allowed")
        }
        return RadioStation(stationId: "6238f5e8-a9ee-4c88-9713-2d1ab4112ac9", name: name, streamUrl: stream,
                            tracklistUrl: tracklistUrl, logoAsset: logoAsset)
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

    private func artURL(_ colour: String, suffix: String, delay: TimeInterval = 0) -> String {
        var s = "http://127.0.0.1:\(artwork.port)/art/\(colour)-\(suffix).png"
        if delay > 0 { s += "?delay=\(delay)" }
        return s
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
            rows.append(["title": s.title, "artist": s.artist, "album": s.album, "albumImage": NSNull(),
                         "albumImageLarge": s.art.map { artURL($0, suffix: "large", delay: s.artDelay) } ?? NSNull(),
                         "datetime": iso.string(from: Self.playedAt(index: i + (withBreak ? 1 : 0)))])
        }
        let data = (try? JSONSerialization.data(withJSONObject: rows)) ?? Data("[]".utf8)
        return (200, data, "application/json")
    }

    private func serveITunes(_ request: URLRequest) -> (Int, Data, String) {
        lock.lock(); let status = failures[.itunes]; let songs = knownSongs; lock.unlock()
        if let status { return (status, Data("{}".utf8), "application/json") }
        let term = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?.first { $0.name == "term" }?.value?.lowercased() ?? ""
        let hit = songs.first { $0.itunesArt != nil && term.contains($0.artist.lowercased()) && term.contains($0.title.lowercased()) }
        let body: String
        if let colour = hit?.itunesArt {
            body = #"{"resultCount":1,"results":[{"artworkUrl100":"\#(artURL(colour, suffix: "100x100bb"))"}]}"#
        } else {
            body = #"{"resultCount":0,"results":[]}"#
        }
        return (200, Data(body.utf8), "application/json")
    }
}
