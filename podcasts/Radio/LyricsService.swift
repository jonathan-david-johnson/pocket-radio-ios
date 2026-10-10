import Foundation

struct LyricLine {
    let timestamp: TimeInterval
    let text: String
}

struct LyricsResult {
    let lines: [LyricLine]
    let plain: String?
    /// Track length in seconds from lrclib, used to detect "between tracks".
    let duration: TimeInterval?

    init(lines: [LyricLine], plain: String?, duration: TimeInterval? = nil) {
        self.lines = lines
        self.plain = plain
        self.duration = duration
    }

    var hasSynced: Bool { !lines.isEmpty }
}

final class LyricsService {
    static let shared = LyricsService()

    private let cache = LRUCache<LyricsResult>(maxBytes: 2 * 1024 * 1024, ttl: 7 * 24 * 3600)

    private init() {}

    func fetch(artist: String, title: String, album: String?) async -> LyricsResult? {
        let key = cacheKey(artist: artist, title: title)
        if let cached = cache.get(key) { return cached }

        let cleanTitle = Self.sanitize(title)
        let cleanAlbum = album.map(Self.sanitize)

        // 1. Exact get with cleaned title + album.
        var result = await getExact(artist: artist, title: cleanTitle, album: cleanAlbum)
        // 2. Retry without album — radio tracklist albums are often decorated/mismatched.
        if result?.hasSynced != true, cleanAlbum?.isEmpty == false {
            result = await getExact(artist: artist, title: cleanTitle, album: nil)
        }
        // 3. Fuzzy search fallback.
        if result?.hasSynced != true {
            if let searched = await search(artist: artist, title: cleanTitle) {
                result = searched
            }
        }

        if let result {
            let cost = result.lines.reduce(0) { $0 + $1.text.utf8.count + 16 } + (result.plain?.utf8.count ?? 0)
            cache.set(key, value: result, cost: max(cost, 64))
        }
        return result
    }

    private func getExact(artist: String, title: String, album: String?) async -> LyricsResult? {
        var components = URLComponents(string: "https://lrclib.net/api/get")!
        var items: [URLQueryItem] = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        if let album, !album.isEmpty {
            items.append(URLQueryItem(name: "album_name", value: album))
        }
        components.queryItems = items
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            return Self.parseRecord(json)
        } catch {
            return nil
        }
    }

    /// Fuzzy search: pick the first result that has synced lyrics, else first plain.
    private func search(artist: String, title: String) async -> LyricsResult? {
        var components = URLComponents(string: "https://lrclib.net/api/search")!
        components.queryItems = [
            URLQueryItem(name: "artist_name", value: artist),
            URLQueryItem(name: "track_name", value: title),
        ]
        guard let url = components.url else { return nil }

        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return nil }
            guard let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
            let records = arr.compactMap { Self.parseRecord($0) }
            return records.first(where: { $0.hasSynced }) ?? records.first
        } catch {
            return nil
        }
    }

    private static func parseRecord(_ json: [String: Any]) -> LyricsResult {
        let synced = json["syncedLyrics"] as? String
        let plain = json["plainLyrics"] as? String
        let duration = json["duration"] as? Double
        let lines = synced.map { LyricsService.shared.parseLRC($0) } ?? []
        return LyricsResult(lines: lines, plain: plain, duration: duration)
    }

    /// Strip trailing qualifier groups like "(Edit)", "(CLEAN)", "[Explicit]",
    /// "- Remastered 2010" that break lrclib's exact match.
    static func sanitize(_ raw: String) -> String {
        let qualifiers = ["edit", "clean", "explicit", "remaster", "radio", "version",
                          "mono", "stereo", "remix", "mix", "live", "bonus", "deluxe",
                          "single", "feat", "ft.", "album version"]
        var s = raw
        // Remove (...) / [...] groups that contain a known qualifier word.
        let pattern = "\\s*[\\(\\[][^\\)\\]]*[\\)\\]]"
        if let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) {
            let ns = s as NSString
            var removeRanges: [NSRange] = []
            regex.enumerateMatches(in: s, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
                guard let m = match else { return }
                let group = ns.substring(with: m.range).lowercased()
                if qualifiers.contains(where: { group.contains($0) }) {
                    removeRanges.append(m.range)
                }
            }
            for range in removeRanges.reversed() {
                s = (s as NSString).replacingCharacters(in: range, with: "")
            }
        }
        // Remove "- Remastered ..." style dash suffixes carrying a qualifier.
        if let dashRange = s.range(of: " - "), qualifiers.contains(where: {
            s[dashRange.upperBound...].lowercased().contains($0)
        }) {
            s = String(s[..<dashRange.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }

    func currentLine(in result: LyricsResult, at offset: TimeInterval) -> LyricLine? {
        LyricLineIndex.index(in: result.lines, at: offset).map { result.lines[$0] }
    }

    // MARK: - LRC parser

    private func parseLRC(_ raw: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for line in raw.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("[") else { continue }
            guard let close = trimmed.firstIndex(of: "]") else { continue }
            let tagContent = String(trimmed[trimmed.index(after: trimmed.startIndex)..<close])
            let text = String(trimmed[trimmed.index(after: close)...]).trimmingCharacters(in: .whitespaces)
            if let ts = parseTimestamp(tagContent) {
                lines.append(LyricLine(timestamp: ts, text: text))
            }
        }
        return lines.sorted { $0.timestamp < $1.timestamp }
    }

    // Parses "mm:ss.xx" → TimeInterval in seconds
    private func parseTimestamp(_ s: String) -> TimeInterval? {
        let parts = s.split(separator: ":", maxSplits: 1)
        guard parts.count == 2,
              let minutes = Double(parts[0]),
              let seconds = Double(parts[1]) else { return nil }
        return minutes * 60 + seconds
    }

    private func cacheKey(artist: String, title: String) -> String {
        "\(artist.lowercased())|\(title.lowercased())"
    }

    func clearCache() {
        cache.removeAll()
    }
}

// MARK: - LRU cache

private final class LRUCache<Value> {
    private struct Entry {
        var value: Value
        var cost: Int
        var lastAccessed: Date
    }

    private var store: [String: Entry] = [:]
    private var order: [String] = []   // front = LRU, back = MRU
    private var totalCost: Int = 0
    let maxBytes: Int
    let ttl: TimeInterval
    private let lock = NSLock()

    init(maxBytes: Int, ttl: TimeInterval) {
        self.maxBytes = maxBytes
        self.ttl = ttl
    }

    func get(_ key: String) -> Value? {
        lock.lock(); defer { lock.unlock() }
        guard var entry = store[key] else { return nil }
        if -entry.lastAccessed.timeIntervalSinceNow > ttl {
            _remove(key); return nil
        }
        entry.lastAccessed = Date()
        store[key] = entry
        order.removeAll { $0 == key }
        order.append(key)
        return entry.value
    }

    func set(_ key: String, value: Value, cost: Int) {
        lock.lock(); defer { lock.unlock() }
        if let old = store[key] {
            totalCost -= old.cost
            order.removeAll { $0 == key }
        }
        store[key] = Entry(value: value, cost: cost, lastAccessed: Date())
        order.append(key)
        totalCost += cost
        while totalCost > maxBytes, let lru = order.first { _remove(lru) }
    }

    func removeAll() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll(); order.removeAll(); totalCost = 0
    }

    private func _remove(_ key: String) {
        if let e = store.removeValue(forKey: key) { totalCost -= e.cost }
        order.removeAll { $0 == key }
    }
}
