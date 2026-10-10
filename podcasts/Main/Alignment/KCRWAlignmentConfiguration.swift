#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsDataModel
import StreamSession

/// Eligibility and frozen policies for the KCRW Eclectic24 alignment experiment.
/// Ported from the menubar's `StreamExperimentConfiguration`.
enum KCRWAlignmentConfiguration {
    static let measuredEndpoint = URL(string: "https://streams.kcrw.com/e24_aac/playlist.m3u8")!
    static let selectionPolicy = OccurrenceSelectionPolicy(feedToProgramOffset: 160,
                                                           maxSelectedAge: 1200,
                                                           maxFeedSilence: 120)
    static let historyPolicy = OccurrenceHistoryPolicy(maxOccurrences: 100,
                                                       maxHistoryAge: 6 * 60 * 60,
                                                       correctionWindow: 120)
    static let clockPolicy = MediaClockPolicy(correlationTolerance: 2, progressionTolerance: 2)

    /// Restricts the override to the measured Eclectic24 stream, not another station whose
    /// name happens to contain KCRW. The reasons are stable strings for diagnosing
    /// radio-browser records. Never log the URL itself: it may carry credentials.
    static func ineligibilityReason(name: String?, streamURL: String?) -> String? {
        guard let name, name.lowercased().contains("kcrw") else {
            return "station name does not identify KCRW"
        }
        guard let streamURL,
              let url = URL(string: streamURL),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "station stream URL is invalid"
        }
        guard components.query == nil, components.fragment == nil,
              components.user == nil, components.password == nil else {
            return "station stream URL contains credentials, query, or fragment"
        }
        guard ["https", "http"].contains(components.scheme?.lowercased() ?? "") else {
            return "station stream scheme is unsupported"
        }
        guard components.host?.lowercased() == "streams.kcrw.com" else {
            return "station stream host is not the measured host"
        }
        // These are identity matches only. Observe still plays the measured HLS playlist.
        guard ["/e24_mp3", "/e24_aac", "/e24_aac/playlist.m3u8"].contains(components.path) else {
            return "station stream path is not the known Eclectic24 variant"
        }
        return nil
    }

    static func isEligible(name: String?, streamURL: String?) -> Bool {
        ineligibilityReason(name: name, streamURL: streamURL) == nil
    }

    /// The measured HLS endpoint, only when the mode is Observe or Apply and the episode is an
    /// eligible radio station. The player may receive a SQLite `Episode` shim instead of the
    /// `RadioStation`, so a station lookup by uuid backs the direct cast. The saved stream URL is
    /// never changed.
    static func endpointOverride(
        for episode: BaseEpisode,
        mode: AlignmentMode,
        stationLookup: (String) -> RadioStation? = { RadioStationRegistry.shared.station(for: $0) }
    ) -> URL? {
        guard mode != .off else { return nil }
        guard let station = (episode as? RadioStation) ?? stationLookup(episode.uuid) else { return nil }
        guard isEligible(name: station.title, streamURL: station.streamUrl) else { return nil }
        return measuredEndpoint
    }

    /// Bool form for callers that only know whether alignment is on. Treated as Observe.
    static func endpointOverride(
        for episode: BaseEpisode,
        observeOn: Bool,
        stationLookup: (String) -> RadioStation? = { RadioStationRegistry.shared.station(for: $0) }
    ) -> URL? {
        endpointOverride(for: episode, mode: observeOn ? .observe : .off, stationLookup: stationLookup)
    }
}
#endif
