#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsDataModel
import StreamSession

/// Everything the aligned session needs to know about one family of stations: how to recognize it, where its
/// tracklist is, what clock the stream offers, and where its skew starts. KCRW's HLS stream and KEXP's ICY stream
/// are the two profiles so far (ADR 0010).
struct AlignmentProfile {
    enum Clock {
        /// The player reports a program date for what it is playing (HLS with `PROGRAM-DATE-TIME`). The skew is a
        /// property of the stream, so it holds across plays.
        case programDate
        /// The stream has no program date (an ICY stream). The clock is the media position plus the wall time at which
        /// playback first advanced. The skew then also holds this play's startup delay, so each new play needs a heal.
        case mediaTime
    }

    /// The skew is saved under this key, so every list entry for the same stream shares one skew.
    let key: String
    /// True when the feed's stamps differ from the stream by a different amount for each song (KEXP's DJs log plays by
    /// hand: skews of −31, 16, 19 and 3 s on consecutive songs). A heal then sets that song's own offset, and the stream
    /// skew is only the default for a song nobody has measured. False when one skew fits the stream (KCRW's stamps).
    let perSongOffsets: Bool
    let clock: Clock
    /// Where the skew starts for a station that was never healed or nudged.
    let seedSkew: Double
    /// The stream to play in place of the saved one, or nil to play the saved stream.
    let streamOverride: URL?
    let selectionPolicy: OccurrenceSelectionPolicy
    let historyPolicy: OccurrenceHistoryPolicy
    let clockPolicy: MediaClockPolicy
    let isEligible: (_ name: String?, _ streamURL: String?) -> Bool
    let makeFeed: () -> AlignmentFeed
}

enum AlignmentProfiles {
    static let kcrw = AlignmentProfile(
        key: "kcrw-e24",
        perSongOffsets: false,
        clock: .programDate,
        seedSkew: KCRWAlignmentConfiguration.seedSkew,
        streamOverride: KCRWAlignmentConfiguration.measuredEndpoint,
        selectionPolicy: KCRWAlignmentConfiguration.selectionPolicy,
        historyPolicy: KCRWAlignmentConfiguration.historyPolicy,
        clockPolicy: KCRWAlignmentConfiguration.clockPolicy,
        isEligible: KCRWAlignmentConfiguration.isEligible,
        makeFeed: { AlignmentFeedClient() })

    static let kexp = AlignmentProfile(
        key: "kexp",
        perSongOffsets: true,
        clock: .mediaTime,
        seedSkew: 0,
        streamOverride: nil,
        selectionPolicy: OccurrenceSelectionPolicy(feedToProgramOffset: 0, maxSelectedAge: 1200, maxFeedSilence: 120),
        historyPolicy: KCRWAlignmentConfiguration.historyPolicy,
        clockPolicy: KCRWAlignmentConfiguration.clockPolicy,
        isEligible: isKEXP,
        makeFeed: { AlignmentFeedClient(url: AlignmentFeedClient.kexpURL, decode: KEXPFeedDecoder.decode) })

    static let all = [kcrw, kexp]

    /// KEXP's streams are on StreamGuys hosts named for the station, and the station name says KEXP. Never log the URL: it may carry credentials.
    static func isKEXP(name: String?, streamURL: String?) -> Bool {
        guard let name, name.lowercased().contains("kexp"),
              let streamURL, let url = URL(string: streamURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil,
              ["https", "http"].contains(components.scheme?.lowercased() ?? ""),
              let host = components.host?.lowercased() else { return false }
        return host.contains("kexp")
    }

    /// The profile for a station, however it is listed.
    static func profile(name: String?, streamURL: String?) -> AlignmentProfile? {
        all.first { $0.isEligible(name, streamURL) }
    }

    /// The profile an episode plays under, only when alignment is On and the episode is an eligible radio station. The
    /// player may receive a SQLite `Episode` shim instead of the `RadioStation`, so a lookup by uuid backs the direct cast.
    static func profile(for episode: BaseEpisode,
                        mode: AlignmentMode,
                        stationLookup: (String) -> RadioStation? = { RadioStationRegistry.shared.station(for: $0) }) -> AlignmentProfile? {
        guard mode != .off else { return nil }
        guard let station = (episode as? RadioStation) ?? stationLookup(episode.uuid) else { return nil }
        return profile(name: station.title, streamURL: station.streamUrl)
    }

    /// The profile of a registered station, for the skew store. Needs no mode: the skew is the station's, On or not.
    static func profile(forStationId stationId: String,
                        stationLookup: (String) -> RadioStation? = { RadioStationRegistry.shared.station(for: $0) }) -> AlignmentProfile? {
        guard let station = stationLookup(stationId) else { return nil }
        return profile(name: station.title, streamURL: station.streamUrl)
    }
}
#endif
