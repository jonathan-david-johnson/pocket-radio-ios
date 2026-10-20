#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// A tracklist row the heal can match a heard song against: what the feed said, and when it stamped it.
struct SkewCandidate: Equatable {
    let title: String
    let artist: String
    /// When the feed says the song played. Wall clock.
    let playedAt: Date
}

/// What the app could read at the instant a heal anchor came back: the stream's program date, the rows the feed
/// returned, the skew in use, and which session this belongs to.
struct HealContext: Equatable {
    let generation: UUID
    let stationId: String
    /// The stream's program date at the moment of the read. The player's clock, not the phone's.
    let programDate: Date
    let candidates: [SkewCandidate]
    let currentSkew: Double
}

/// One anchor read against the tracklist. `skew` is the feed-to-stream offset this anchor implies.
///
/// ShazamKit says which song is playing and where in it (`predictedOffset`). The program date `P` is the stream's
/// clock now, so the song began in the stream at `P - predictedOffset`. The feed stamped that row `T`. So
/// `skew = P - predictedOffset - T`. It does not depend on the skew in use, so a heal can start from any value.
struct SkewMeasurement: Equatable {
    let shazam: AnchorMatch
    let entry: SkewCandidate
    let programDate: Date
    let skew: Double
    /// The skew in use when the anchor was read.
    let currentSkew: Double
    /// Rows that matched the heard song. More than one means the song played twice in the feed's window.
    let matchingRows: Int

    /// When the song began in the stream, on the same clock as the stamps: the program date minus ShazamKit's position.
    var startedInStream: Date { programDate.addingTimeInterval(-shazam.predictedOffset) }

    /// What the anchor asks for: how far the skew in use is from the one it implies. Positive: the stream is later
    /// against the feed than the app assumes, so the screen is ahead of the audio.
    var change: Double { skew - currentSkew }

    func logLine() -> String {
        let confidence = shazam.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        return "[anchor] heard=\"\(shazam.title) — \(shazam.artist)\" predicted=\(String(format: "%.1f", shazam.predictedOffset)) "
            + "conf=\(confidence) row=\"\(entry.title)\" rows=\(matchingRows) "
            + "skew=\(String(format: "%.1f", skew)) inUse=\(String(format: "%.1f", currentSkew)) change=\(String(format: "%+.1f", change)) "
            + "at=\(StreamTrace.iso(programDate)) start=\(StreamTrace.iso(startedInStream)) stamp=\(StreamTrace.iso(entry.playedAt)) "
            + "sid=\(shazam.shazamID ?? "-") isrc=\(shazam.isrc ?? "-") cands=\(shazam.candidates.count)"
    }
}

/// Turns one heard song into a skew by finding it in the feed's rows. Pure.
enum SkewSolver {
    enum Solution: Equatable {
        case measured(SkewMeasurement)
        /// The song is in the feed, but as another version (a remix or a radio edit, say). ShazamKit's position is
        /// for its own recording, which can be seconds or minutes off the broadcast, so it can't set the timing.
        case differentVersion(feedTitle: String)
        case notInFeed
    }

    /// The skew the anchor implies. When the song played twice in the window, the row that gives the skew nearest
    /// the one in use wins, so a good starting value settles it.
    static func solve(match: AnchorMatch, programDate: Date, candidates: [SkewCandidate],
                      currentSkew: Double) -> Solution {
        let matching = candidates.filter {
            AnchorIdentity.matches(alignedTitle: $0.title, alignedArtist: $0.artist,
                                   shazamTitle: match.title, shazamArtist: match.artist)
        }
        guard !matching.isEmpty else { return .notInFeed }
        let sameVersion = matching.filter { AnchorIdentity.sameVersion($0.title, match.title) }
        guard !sameVersion.isEmpty else { return .differentVersion(feedTitle: matching[0].title) }
        let startedInStream = programDate.timeIntervalSince1970 - match.predictedOffset
        let scored = sameVersion.map { (row: $0, skew: startedInStream - $0.playedAt.timeIntervalSince1970) }
        guard let best = scored.min(by: { abs($0.skew - currentSkew) < abs($1.skew - currentSkew) }) else { return .notInFeed }
        return .measured(SkewMeasurement(shazam: match, entry: best.row, programDate: programDate, skew: best.skew,
                                         currentSkew: currentSkew, matchingRows: sameVersion.count))
    }
}

/// Does ShazamKit's song name the song the app is showing? A wrong-song match must never move the offset.
enum AnchorIdentity {
    static func matches(alignedTitle: String, alignedArtist: String, shazamTitle: String, shazamArtist: String) -> Bool {
        let t1 = normalize(alignedTitle), t2 = normalize(shazamTitle)
        guard !t1.isEmpty, !t2.isEmpty, related(t1, t2) else { return false }
        let a1 = normalize(alignedArtist), a2 = normalize(shazamArtist)
        // An artist the feed or ShazamKit omits can't contradict the title.
        guard !a1.isEmpty, !a2.isEmpty else { return true }
        return related(a1, a2) || sharesAToken(a1, a2)
    }

    /// Words that mark a different recording of the same song, whose timeline differs from the original's.
    static let versionWords: Set<String> = ["remix", "mix", "edit", "version", "live", "acoustic", "extended",
                                            "instrumental", "demo", "reprise"]

    /// The version words in a title: "Dreams (radio edit - clean)" gives `edit`. Plain words such as "clean" or
    /// "remastered" do not change the timing and are ignored. Any word of the title counts, not only a bracketed one,
    /// because feeds write the same version as "Song: Their Version" where ShazamKit writes "Song (Their Version)". A
    /// title that has such a word in its own name (the same word on both sides) still compares equal.
    static func versionMarkers(_ title: String) -> Set<String> {
        Set(title.lowercased().split { !$0.isLetter }.map(String.init)).intersection(versionWords)
    }

    /// Whether two titles name the same recording as far as the version words can tell.
    static func sameVersion(_ feedTitle: String, _ heardTitle: String) -> Bool {
        versionMarkers(feedTitle) == versionMarkers(heardTitle)
    }

    /// Lowercase, no diacritics, no bracketed or "feat." parts, no punctuation, single spaces.
    static func normalize(_ text: String) -> String {
        var s = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .init(identifier: "en_US"))
        s = s.replacingOccurrences(of: #"[\(\[][^\)\]]*[\)\]]"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\b(feat|featuring|ft|with)\b.*$"#, with: " ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"['’`´]"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"[^\p{L}\p{N}\s]"#, with: " ", options: .regularExpression)
        return s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func related(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let (short, long) = a.count <= b.count ? (a, b) : (b, a)
        return short.count >= 4 && long.contains(short)
    }

    private static func sharesAToken(_ a: String, _ b: String) -> Bool {
        let ta = Set(a.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        let tb = Set(b.split(separator: " ").map(String.init).filter { $0.count >= 4 })
        return !ta.isDisjoint(with: tb)
    }
}
#endif
