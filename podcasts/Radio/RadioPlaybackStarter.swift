import Foundation

protocol RadioStationRegistering {
    func register(_ station: RadioStation)
}

protocol RadioEpisodeLoading {
    func currentEpisodeUuid() -> String?
    func load(station: RadioStation)
    func togglePlayPause()
}

private struct ProductionRadioEpisodeLoader: RadioEpisodeLoading {
    func currentEpisodeUuid() -> String? {
        PlaybackManager.shared.currentEpisode?.uuid
    }

    func load(station: RadioStation) {
        PlaybackManager.shared.load(episode: station, autoPlay: true, overrideUpNext: false)
    }

    func togglePlayPause() {
        // `PlaybackActionHelper` became `@MainActor` upstream, and this loader is
        // reached from off-main callers (intents, widget). Hop rather than assume.
        Task { @MainActor in
            PlaybackActionHelper.playPause()
        }
    }
}

extension RadioStationRegistry: RadioStationRegistering {}

/// Single entry point for starting live radio playback. Encapsulates the
/// register-before-load invariant (see `RadioStationRegistry`) plus the
/// optional tracklist prefetch and widget republish.
final class RadioPlaybackStarter {
    enum StartResult: Equatable {
        case startedPlayback
        case toggledPause
        case resumed
    }

    static let shared = RadioPlaybackStarter(
        registry: RadioStationRegistry.shared,
        episodeLoader: ProductionRadioEpisodeLoader(),
        resolveStation: { stationId in
            if let registered = RadioStationRegistry.shared.station(for: stationId) {
                return registered
            }
            if let browse = try? await RadioBrowserAPI.station(uuid: stationId) {
                return browse.toRadioStation()
            }
            return nil
        },
        tracklistPrefetcher: { station in
            guard let url = station.tracklistUrl else { return }
            Task {
                _ = try? await RadioTracklistService.shared.fetch(stationId: station.uuid, url: url)
            }
        },
        widgetRepublisher: {
            WidgetHelper.shared.republishAllPocketRadioState()
        }
    )

    private let registry: RadioStationRegistering
    private let episodeLoader: RadioEpisodeLoading
    private let resolveStation: (String) async -> RadioStation?
    private let tracklistPrefetcher: (RadioStation) -> Void
    private let widgetRepublisher: () -> Void

    init(
        registry: RadioStationRegistering,
        episodeLoader: RadioEpisodeLoading,
        resolveStation: @escaping (String) async -> RadioStation?,
        tracklistPrefetcher: @escaping (RadioStation) -> Void,
        widgetRepublisher: @escaping () -> Void
    ) {
        self.registry = registry
        self.episodeLoader = episodeLoader
        self.resolveStation = resolveStation
        self.tracklistPrefetcher = tracklistPrefetcher
        self.widgetRepublisher = widgetRepublisher
    }

    /// - Parameters:
    ///   - station: already-resolved station
    ///   - source: analytics source for `AnalyticsPlaybackHelper.currentSource`
    ///   - prefetchTracklist: kick a `RadioTracklistService` fetch so artist/title
    ///     populate before the first ICY frame (KCRW's ICY cadence lags 10–20s)
    ///   - republishWidgetState: force a `WidgetHelper` App Group write + reload
    /// - Returns: `.startedPlayback`, `.toggledPause`, or `.resumed`
    @discardableResult
    func play(
        station: RadioStation,
        source: AnalyticsSource,
        prefetchTracklist: Bool = true,
        republishWidgetState: Bool = true
    ) -> StartResult {
        AnalyticsPlaybackHelper.shared.currentSource = source

        if episodeLoader.currentEpisodeUuid() == station.uuid {
            episodeLoader.togglePlayPause()
            return .toggledPause
        }

        registerAndLoad(station: station, prefetchTracklist: prefetchTracklist, republishWidgetState: republishWidgetState)

        return .startedPlayback
    }

    /// Register + load unconditionally, skipping the "already current" toggle
    /// shortcut used by `play(station:...)`. For callers that already decide
    /// for themselves when a fresh reconnect is needed (e.g. resuming a
    /// paused-but-possibly-stale live stream, where a live radio connection
    /// can't be trusted to resume from a simple play/pause toggle).
    @discardableResult
    func reload(
        station: RadioStation,
        source: AnalyticsSource,
        prefetchTracklist: Bool = true,
        republishWidgetState: Bool = true
    ) -> StartResult {
        AnalyticsPlaybackHelper.shared.currentSource = source
        registerAndLoad(station: station, prefetchTracklist: prefetchTracklist, republishWidgetState: republishWidgetState)
        return .startedPlayback
    }

    private func registerAndLoad(station: RadioStation, prefetchTracklist: Bool, republishWidgetState: Bool) {
        registry.register(station)
        episodeLoader.load(station: station)

        if prefetchTracklist, let url = station.tracklistUrl, !url.isEmpty {
            tracklistPrefetcher(station)
        }

        if republishWidgetState {
            widgetRepublisher()
        }
    }

    /// Resolve then play. Registry first (instant), radio-browser by-UUID fallback.
    /// Returns nil if unresolvable.
    @discardableResult
    func play(
        stationId: String,
        source: AnalyticsSource,
        prefetchTracklist: Bool = true,
        republishWidgetState: Bool = true
    ) async -> StartResult? {
        guard let station = await resolveStation(stationId) else { return nil }
        return play(station: station, source: source, prefetchTracklist: prefetchTracklist, republishWidgetState: republishWidgetState)
    }
}
