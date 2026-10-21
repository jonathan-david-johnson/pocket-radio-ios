import Foundation
@testable import podcasts

/// A station the heal is run against: a feed of songs stamped by the feed, and a stream that plays each of them
/// `trueSkew` seconds after its stamp. All times are seconds on one clock, the stream's program time, so the program
/// date the app reads at any instant is just that number.
struct SimulatedFeed {
    struct Song {
        let title: String
        let artist: String
        /// The feed's stamp.
        let stamp: Double
        let duration: Double
    }

    static let origin = 1_700_000_000.0

    let trueSkew: Double
    let songs: [Song]
    /// The feed lists every title as an edit, "Song 3 (radio edit)", while ShazamKit names the plain recording.
    let listedAsEdit: Bool
    /// The feed lists a play this many seconds after its stamp (KEXP's takes about two minutes).
    let publishDelay: Double
    /// The feed shows rows up to this far ahead of what is audible: the feed runs ahead of the stream. A row is
    /// listed once the live station has played it, which is `trueSkew` seconds before the listener hears it.
    static let liveLead = 6.0

    /// `repeatEvery`: a song whose title repeats this many songs later. 0 means every title is unique.
    init(seed: UInt64, trueSkew: Double, count: Int = 60, repeatEvery: Int = 0, listedAsEdit: Bool = false, publishDelay: Double = 0) {
        var random = SeededRandom(seed: seed)
        var songs: [Song] = []
        var stamp = Self.origin
        for i in 0..<count {
            let n = repeatEvery > 0 ? i % repeatEvery : i
            let duration = 150 + random.uniform() * 250
            songs.append(Song(title: "Song \(n)", artist: "Artist \(n)", stamp: stamp, duration: duration))
            stamp += duration
        }
        self.trueSkew = trueSkew
        self.songs = songs
        self.listedAsEdit = listedAsEdit
        self.publishDelay = publishDelay
    }

    /// The song audible at program time `p`, and how far into it.
    func audible(at p: Double) -> (song: Song, position: Double)? {
        songs.first { $0.stamp + trueSkew <= p && p < $0.stamp + trueSkew + $0.duration }
            .map { ($0, p - $0.stamp - trueSkew) }
    }

    /// The most recent rows the feed returns while the stream is at program time `p`.
    func rows(at p: Double, limit: Int = 10) -> [SkewCandidate] {
        songs.filter { $0.stamp + publishDelay <= p + Self.liveLead }.suffix(limit).map {
            SkewCandidate(title: listedAsEdit ? "\($0.title) (radio edit)" : $0.title, artist: $0.artist,
                          playedAt: Date(timeIntervalSince1970: $0.stamp), rowKey: "row-\(Int($0.stamp))")
        }
    }
}

/// The phone in a simulated world: the stream's clock, a microphone that hears the audible song with some noise,
/// and a feed. The heal is run against it with the real probe and the real healer.
@MainActor
final class SkewWorld {
    let feed: SimulatedFeed
    let stationId = "sim"
    let generation = UUID()
    let store: AlignmentSkewStore
    var programTime: Double
    var random: SeededRandom
    /// Standard deviation of ShazamKit's position, in seconds.
    var noise = 0.4
    /// Share of anchors that name the right song but the wrong place in it, by 20 to 90 s.
    var wrongSectionRate = 0.0
    /// Share of anchors that name a song that is not in the feed at all.
    var unknownSongRate = 0.0
    /// Seconds the microphone listens before a result.
    var listenTime = 7.0
    private(set) var attempts = 0
    private(set) var lines: [String] = []

    init(feed: SimulatedFeed, startSkew: Double, seed: UInt64, programTime: Double? = nil, suite: String) {
        self.feed = feed
        random = SeededRandom(seed: seed &+ 77)
        // Somewhere inside the feed, past the first song, so a window of rows exists behind it.
        self.programTime = programTime ?? (SimulatedFeed.origin + feed.trueSkew + 1500 + Double(seed % 900))
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        store = AlignmentSkewStore(defaults: defaults, seed: { _ in 0 }, center: NotificationCenter())
        store.set(startSkew, for: stationId)
    }

    func context() -> HealContext? {
        HealContext(generation: generation, stationId: stationId, programDate: Date(timeIntervalSince1970: programTime),
                    candidates: feed.rows(at: programTime), currentSkew: store.skew(for: stationId))
    }

    /// What the microphone and ShazamKit report after listening for `listenTime` seconds.
    func outcome() -> AnchorOutcome {
        attempts += 1
        programTime += listenTime
        guard let (song, position) = feed.audible(at: programTime) else { return .noMatch }
        if random.uniform() < unknownSongRate {
            return .matched(AnchorMatch(title: "Not In The Feed", artist: "Nobody", matchOffset: 0, predictedOffset: 40,
                                        confidence: 0.9, frequencySkew: 0))
        }
        var predicted = position + random.gaussian() * noise
        if random.uniform() < wrongSectionRate {
            predicted += (random.uniform() < 0.5 ? -1 : 1) * (20 + random.uniform() * 70)
        }
        return .matched(AnchorMatch(title: song.title, artist: song.artist, matchOffset: max(0, predicted - listenTime),
                                    predictedOffset: predicted, confidence: 0.9, frequencySkew: 0))
    }

    var skew: Double { store.skew(for: stationId) }
}

/// A scripted source for the real probe, driven by the world.
final class WorldSource: OffsetAnchorSource {
    let produce: @MainActor () -> AnchorOutcome
    init(_ produce: @escaping @MainActor () -> AnchorOutcome) { self.produce = produce }
    func anchor() async -> AnchorOutcome { await produce() }
    func cancel() {}
}
