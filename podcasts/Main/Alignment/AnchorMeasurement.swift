#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// The app's view of the song at the instant an anchor was read.
struct AlignedMoment: Equatable {
    let title: String
    let artist: String
    let occurrenceID: String
    /// The app's song position now, with the feed skew and any correction already applied.
    let songSeconds: Double
}

/// One anchor set against what the app showed at the same moment.
///
/// `delta = shazam.predictedOffset − aligned.songSeconds`. Positive means the audio is ahead of the app.
/// `trueOffset` is the feed-to-program offset that would have made `delta` zero: the offset in use minus delta.
/// It stays the same whatever the Debug feed skew is, which is how the skew knob is checked.
struct AnchorMeasurement: Equatable {
    let aligned: AlignedMoment
    let shazam: AnchorMatch
    /// The feed-to-program offset in use when the anchor was read, in seconds.
    let effectiveOffset: Double
    let feedSkew: Double

    var delta: Double { shazam.predictedOffset - aligned.songSeconds }
    var trueOffset: Double { effectiveOffset - delta }
    /// `delta` against the frozen `+160 s` alone: the Debug feed skew taken out. This is what the learner learns,
    /// so a skew set for the experiment shows up as a change in the offset to find, not as noise.
    var deltaVersusFrozenOffset: Double { delta - feedSkew }
    var identityMatches: Bool {
        AnchorIdentity.matches(alignedTitle: aligned.title, alignedArtist: aligned.artist,
                               shazamTitle: shazam.title, shazamArtist: shazam.artist)
    }

    func logLine() -> String {
        let confidence = shazam.confidence.map { String(format: "%.2f", $0) } ?? "n/a"
        return "[anchor] aligned=\"\(aligned.title) — \(aligned.artist)\" songSec=\(String(format: "%.1f", aligned.songSeconds)) "
            + "shazam=\"\(shazam.title) — \(shazam.artist)\" predicted=\(String(format: "%.1f", shazam.predictedOffset)) "
            + "matchOffset=\(String(format: "%.1f", shazam.matchOffset)) conf=\(confidence) skewHz=\(String(format: "%.4f", shazam.frequencySkew)) "
            + "delta=\(String(format: "%+.1f", delta)) offset=\(String(format: "%.1f", effectiveOffset)) "
            + "feedSkew=\(String(format: "%+.1f", feedSkew)) trueOffset=\(String(format: "%.1f", trueOffset)) "
            + "identity=\(identityMatches ? "match" : "MISMATCH")"
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
