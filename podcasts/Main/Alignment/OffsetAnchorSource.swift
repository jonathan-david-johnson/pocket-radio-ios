#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// What an audio-based identification says about the song that is audible now. `predictedOffset` is the
/// timecode in the reference recording that matches the audio at the moment the result was read.
struct AnchorMatch: Equatable {
    let title: String
    let artist: String
    /// Timecode in the reference that matches the start of the captured audio, in seconds.
    let matchOffset: Double
    /// Timecode in the reference that matches the audio now, in seconds.
    let predictedOffset: Double
    /// 0 to 1 where the framework reports it (iOS 18.4 and later), else nil.
    let confidence: Double?
    /// 0 means the heard audio plays at the reference's speed.
    let frequencySkew: Double
    /// Which recording ShazamKit matched, for the log. Two matches of one song to different recordings can sit seconds
    /// apart in time, so a changed ID explains a jump. `candidates` are the IDs of every item the match returned.
    var shazamID: String? = nil
    var isrc: String? = nil
    var candidates: [String] = []
}

enum AnchorOutcome: Equatable {
    case matched(AnchorMatch)
    case noMatch
    case error(String)
}

/// A source of ground truth about what is audible. Production asks ShazamKit, which hears the phone's own playback;
/// tests script it. See ADR 0010.
protocol OffsetAnchorSource {
    func anchor() async -> AnchorOutcome
    func cancel()
}
#endif
