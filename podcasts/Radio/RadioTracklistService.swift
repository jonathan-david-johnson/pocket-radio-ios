import Foundation

enum RadioTracklistError: Error {
    case invalidURL
    case unknownStation
    case parse(Error)
    case http(Int)
    case network(Error)
}

final class RadioTracklistService {
    static let shared = RadioTracklistService()

    private let urlSession: URLSession
    private var cache: [String: [TracklistEntry]] = [:]
    private let cacheQueue = DispatchQueue(label: "RadioTracklistService.cache", attributes: .concurrent)
    private var toastedStations: Set<String> = []
    private let toastQueue = DispatchQueue(label: "RadioTracklistService.toasts")

    init(urlSession: URLSession = .shared) {
        self.urlSession = urlSession
    }

    /// Returns the most recent successfully-fetched tracklist for the
    /// station, or nil if none has been fetched this app session.
    func cached(stationId: String) -> [TracklistEntry]? {
        cacheQueue.sync { cache[stationId] }
    }

    #if DEBUG
    /// Test-only: seed the in-memory cache without going through `fetch`.
    /// Lets unit tests exercise `TrackArtworkResolver.bestResolveEntry` and
    /// observers that read from the shared cache.
    func _seedCacheForTesting(stationId: String, entries: [TracklistEntry]) {
        cacheQueue.async(flags: .barrier) { [stationId] in
            self.cache[stationId] = entries
        }
        cacheQueue.sync(flags: .barrier) {}
    }

    // CarPlay harness seam (M13.1): cache and failure-toast dedupe, all stations.
    func _resetForTesting() {
        cacheQueue.async(flags: .barrier) { self.cache.removeAll() }
        cacheQueue.sync(flags: .barrier) {}
        toastQueue.sync { toastedStations.removeAll() }
    }

    func _clearCacheForTesting(stationId: String) {
        cacheQueue.async(flags: .barrier) { [stationId] in
            self.cache.removeValue(forKey: stationId)
        }
        cacheQueue.sync(flags: .barrier) {}
    }
    #endif

    /// Returns true if the caller should show a failure toast for this station.
    /// Subsequent calls within the same app session return false until the next
    /// successful fetch resets the dedupe state.
    func shouldShowFailureToast(stationId: String) -> Bool {
        toastQueue.sync {
            if toastedStations.contains(stationId) { return false }
            toastedStations.insert(stationId)
            return true
        }
    }

    /// Fetch the most recent plays for a curated station.
    /// - Parameter stationId: used as the cache key and dedupe key.
    /// - Parameter url: the station's tracklist endpoint. Parser is selected
    ///   by URL host (kcrw / kexp); unknown hosts return an empty array (no throw).
    /// Returns up to ~10 entries, most recent first.
    func fetch(stationId: String, url: String) async throws -> [TracklistEntry] {
        guard let requestURL = URL(string: url) else { throw RadioTracklistError.invalidURL }

        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await urlSession.data(from: requestURL)
        } catch {
            throw RadioTracklistError.network(error)
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            throw RadioTracklistError.http(http.statusCode)
        }

        let host = requestURL.host?.lowercased() ?? ""
        let result: [TracklistEntry]
        if host.contains("kcrw") {
            result = try parseKCRW(data: data)
        } else if host.contains("kexp") {
            result = try parseKEXP(data: data)
        } else {
            result = []
        }

        if !result.isEmpty {
            cacheQueue.async(flags: .barrier) { [stationId] in
                self.cache[stationId] = result
            }
            // Observers (mini/big player) touch UIKit synchronously on the
            // posting thread. `fetch` runs on a cooperative async thread, so
            // hop to main before posting.
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: .radioTracklistDidRefresh,
                    object: nil,
                    userInfo: [RadioMetadataNotificationKey.stationId: stationId]
                )
            }
        }
        toastQueue.async { [stationId] in
            self.toastedStations.remove(stationId)
        }
        return result
    }

    // MARK: - KCRW
    // The KCRW tracklist API (https://tracklist-api.kcrw.com/Music/all/1?page_size=10)
    // returns a flat JSON array of track objects. Captured shape (M7.2):
    //   {
    //     "title": "Song Title",
    //     "artist": "Artist Name",
    //     "album": "Album",
    //     "albumImage":      "https://i.scdn.co/image/abc123",   // 300x300, Spotify CDN, OFTEN NULL
    //     "albumImageLarge": "https://i.scdn.co/image/def456",   // 640x640, Spotify CDN, OFTEN NULL
    //     "datetime": "2026-05-18T16:32:00-07:00"
    //   }
    // Both `albumImage` and `albumImageLarge` are nullable (~50% of tracks have neither).
    // We prefer `albumImageLarge` when available, falling back to `albumImage`; both nil
    // → `TracklistEntry.albumArtURL` is nil and the artwork resolver falls through
    // to iTunes Search → station logo.

    private struct KCRWTrack: Decodable {
        let title: String?       // can be null on [BREAK] rows
        let artist: String?      // also nullable defensively
        let album: String?
        let albumImage: String?
        let albumImageLarge: String?
        let datetime: String?
    }

    func parseKCRW(data: Data) throws -> [TracklistEntry] {
        do {
            let tracks = try JSONDecoder().decode([KCRWTrack].self, from: data)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return tracks.compactMap { t in
                // Skip [BREAK] rows and anything missing title or artist.
                guard let title = t.title, !title.isEmpty else { return nil }
                guard let artist = t.artist, !artist.isEmpty, artist != "[BREAK]" else { return nil }
                let imageString = t.albumImageLarge ?? t.albumImage
                return TracklistEntry(
                    title: title,
                    artist: artist,
                    album: t.album,
                    albumArtURL: imageString.flatMap(URL.init(string:)),
                    playedAt: t.datetime.flatMap(iso.date(from:))
                )
            }
        } catch {
            throw RadioTracklistError.parse(error)
        }
    }

    // MARK: - KEXP
    // The KEXP plays API returns { "results": [...] }.
    // Observed fields: play_type, song, artist, album, thumbnail_uri, airdate (ISO-8601 with offset)

    private struct KEXPResponse: Decodable {
        struct Play: Decodable {
            let play_type: String
            let song: String?
            let artist: String?
            let album: String?
            let thumbnail_uri: String?
            let airdate: String?
        }
        let results: [Play]
    }

    func parseKEXP(data: Data) throws -> [TracklistEntry] {
        do {
            let response = try JSONDecoder().decode(KEXPResponse.self, from: data)
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            return response.results.compactMap { play in
                guard play.play_type == "trackplay" else { return nil }
                guard let song = play.song, let artist = play.artist else { return nil }
                return TracklistEntry(
                    title: song,
                    artist: artist,
                    album: play.album,
                    albumArtURL: play.thumbnail_uri.flatMap(URL.init(string:)),
                    playedAt: play.airdate.flatMap(iso.date(from:))
                )
            }
        } catch {
            throw RadioTracklistError.parse(error)
        }
    }
}
