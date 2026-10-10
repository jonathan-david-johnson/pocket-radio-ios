#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Resolves an artwork URL for a `TracklistEntry`. Preference chain:
/// 1. The entry's own `albumArtURL` (set by `RadioTracklistService.parseKCRW`
///    from KCRW's `albumImageLarge` / `albumImage` fields, both Spotify-CDN
///    URLs).
/// 2. iTunes Search API:
///    `https://itunes.apple.com/search?term=<artist+title>&entity=song&limit=1`
///    The first result's `artworkUrl100` (100x100 JPEG) is upgraded to
///    `600x600bb` for high-res.
/// 3. nil → caller (player VC / NowPlayingHelper) falls back to the station
///    logo.
///
/// Caches resolved URLs by `(artist, title)` key in an `NSCache` so the
/// system auto-purges on memory pressure. iTunes lookups are issued via
/// `URLSession.shared`; a new lookup for a different `(artist, title)`
/// supersedes any in-flight request, so stale results never overwrite the
/// newest track.
final class TrackArtworkResolver {

    static let shared = TrackArtworkResolver()

    // Sentinel for "iTunes returned nothing" so we don't re-hit the API
    // repeatedly for tracks the iTunes catalogue genuinely lacks.
    private static let negativeSentinel = URL(string: "x-pocketradio://no-artwork")!

    private let session: URLSession
    private let cache = NSCache<NSString, NSURL>()
    private let lockQueue = DispatchQueue(label: "TrackArtworkResolver.lock")
    // Tracks the most recently requested key, so completions from older
    // requests can be discarded.
    private var currentKey: String?
    private var currentTask: URLSessionDataTask?

    init(session: URLSession = .shared) {
        self.session = session
        cache.countLimit = 100
    }

    #if DEBUG
    // CarPlay harness seam (M13.1): resolver key, in-flight task and cache.
    func _resetForTesting() {
        lockQueue.sync { currentTask?.cancel(); currentTask = nil; currentKey = nil }
        cache.removeAllObjects()
    }
    var _currentKeyForTesting: String? { lockQueue.sync { currentKey } }
    #endif

    /// Resolve the artwork URL for `entry`. `station` is currently unused
    /// (the caller owns the station-logo fallback), but kept in the signature
    /// to keep the call sites symmetric and future-proof.
    func artworkURL(for entry: TracklistEntry,
                    station: RadioStation,
                    completion: @escaping (URL?) -> Void) {
        // 1. Tracklist-provided art wins. Cache it too so a re-resolve for the
        //    same (artist, title) is free.
        if let direct = entry.albumArtURL {
            let key = Self.cacheKey(artist: entry.artist, title: entry.title)
            cache.setObject(direct as NSURL, forKey: key as NSString)
            setCurrentKey(key, task: nil)
            DispatchQueue.main.async { completion(direct) }
            return
        }

        let key = Self.cacheKey(artist: entry.artist, title: entry.title)

        if let cached = cache.object(forKey: key as NSString) as URL? {
            setCurrentKey(key, task: nil)
            let value: URL? = (cached == Self.negativeSentinel) ? nil : cached
            DispatchQueue.main.async { completion(value) }
            return
        }

        // 2. iTunes fallback.
        guard let url = Self.itunesSearchURL(artist: entry.artist, title: entry.title) else {
            DispatchQueue.main.async { completion(nil) }
            return
        }

        // Cancel any in-flight task for a different key.
        cancelInFlightIfDifferent(newKey: key)

        let task = session.dataTask(with: url) { [weak self] data, _, _ in
            guard let self else { return }
            let resolved = data.flatMap(Self.parseITunesArtworkURL)

            // Drop result if a newer request has superseded us.
            guard self.isCurrent(key) else { return }

            if let resolved {
                self.cache.setObject(resolved as NSURL, forKey: key as NSString)
                DispatchQueue.main.async { completion(resolved) }
            } else {
                self.cache.setObject(Self.negativeSentinel as NSURL, forKey: key as NSString)
                DispatchQueue.main.async { completion(nil) }
            }
        }
        setCurrentKey(key, task: task)
        task.resume()
    }

    // MARK: - Helpers

    /// Picks the best `TracklistEntry` to resolve artwork for, given the
    /// (possibly empty / unparseable) ICY artist+title. Preference:
    /// 1. Cached tracklist entry whose (artist, title) matches ICY exactly.
    /// 2. Cached tracklist's top entry (treat tracklist as source of truth
    ///    when ICY artist is empty or ICY title doesn't appear in cache —
    ///    e.g. KCRW ICY emits `Title-Artist-Album` with no spaces, which
    ///    `RadioMetadataObserver.parseStreamTitle` cannot split).
    /// 3. Synthesized entry from raw ICY values (last resort; no albumArtURL).
    /// Returns nil only when there's nothing at all to resolve from.
    static func bestResolveEntry(stationId: String,
                                 icyArtist: String,
                                 icyTitle: String) -> TracklistEntry? {
        // An Apply session owns the station's song: the aligned entry, or nil when unavailable.
        // Never the cached tracklist top and never ICY.
        if AlignedConsumers.isApplying(stationId: stationId) {
            return AlignedConsumers.entry(for: stationId)
        }
        let cached = RadioTracklistService.shared.cached(stationId: stationId)
        let trimmedArtist = icyArtist.trimmingCharacters(in: .whitespaces)
        let trimmedTitle = icyTitle.trimmingCharacters(in: .whitespaces)

        if !trimmedArtist.isEmpty, !trimmedTitle.isEmpty,
           let match = cached?.first(where: {
               $0.artist.lowercased() == trimmedArtist.lowercased() &&
               $0.title.lowercased() == trimmedTitle.lowercased()
           }) {
            return match
        }

        if let top = cached?.first {
            return top
        }

        if !trimmedTitle.isEmpty {
            return TracklistEntry(title: trimmedTitle, artist: trimmedArtist, album: nil, albumArtURL: nil, playedAt: nil)
        }
        return nil
    }

    private static func cacheKey(artist: String, title: String) -> String {
        return "\(artist.lowercased())\u{1F}\(title.lowercased())"
    }

    static func itunesSearchURL(artist: String, title: String) -> URL? {
        var components = URLComponents(string: "https://itunes.apple.com/search")
        let term = "\(artist) \(title)".trimmingCharacters(in: .whitespaces)
        guard !term.isEmpty else { return nil }
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "1")
        ]
        return components?.url
    }

    /// Decodes an iTunes Search response and returns the high-res artwork URL
    /// (`artworkUrl100` → `600x600bb`). Exposed `static` so tests can exercise
    /// the parsing path without a network round-trip.
    static func parseITunesArtworkURL(from data: Data) -> URL? {
        struct Response: Decodable {
            struct Result: Decodable { let artworkUrl100: String? }
            let results: [Result]
        }
        guard let decoded = try? JSONDecoder().decode(Response.self, from: data),
              let raw = decoded.results.first?.artworkUrl100, !raw.isEmpty else {
            return nil
        }
        let upgraded = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: upgraded)
    }

    private func setCurrentKey(_ key: String?, task: URLSessionDataTask?) {
        lockQueue.sync {
            currentKey = key
            currentTask = task
        }
    }

    private func isCurrent(_ key: String) -> Bool {
        lockQueue.sync { currentKey == key }
    }

    private func cancelInFlightIfDifferent(newKey: String) {
        lockQueue.sync {
            if currentKey != newKey {
                currentTask?.cancel()
            }
        }
    }
}
#endif
