#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Song seconds between player samples, for lyrics. Pure value type; time comes only from the
/// injected `now`. See ADR 0005.
///
/// It never decides when a clock fault has lasted too long. That rule, 5 s of playing, lives only in
/// `AlignedNowPlayingPublisher`: when its hold ends it publishes unavailable, which resets this estimator,
/// so the title and the lyric position let go at the same moment.
struct SongPositionEstimator {
    private let now: () -> Date

    private var occurrenceID: String?
    /// Song seconds at `since`.
    private var base = 0.0
    /// Where the current stretch of `playing` or not playing began.
    private var since = Date.distantPast
    private var playing = false

    init(now: @escaping () -> Date) {
        self.now = now
    }

    /// A valid player sample: the player's own value replaces whatever was extrapolated.
    mutating func record(occurrenceID: String, songSeconds: Double, playing: Bool) {
        self.occurrenceID = occurrenceID
        base = songSeconds
        since = now()
        self.playing = playing
    }

    /// The clock is invalid: stop re-anchoring. The position keeps extrapolating from the last valid
    /// sample while the player plays. A later valid sample replaces it. Ignored before the first sample.
    mutating func recordFault(playing: Bool) {
        guard occurrenceID != nil else { return }
        fold()
        self.playing = playing
    }

    /// A status change with no sample. Freezes at the extrapolated value on pause, and continues
    /// from it on resume. Ignored before the first sample.
    mutating func recordPlaying(_ playing: Bool) {
        guard occurrenceID != nil, playing != self.playing else { return }
        fold()
        self.playing = playing
    }

    /// Nil for another occurrence and before any sample.
    func position(forOccurrence id: String) -> Double? {
        guard occurrenceID == id else { return nil }
        return base + playedSinceAnchor
    }

    /// Moves the time played so far into `base`, and starts a new stretch at now.
    private mutating func fold() {
        base += playedSinceAnchor
        since = now()
    }

    /// Seconds the player has advanced since `since`. Zero while not playing.
    private var playedSinceAnchor: TimeInterval {
        playing ? max(0, now().timeIntervalSince(since)) : 0
    }
}
#endif
