import Foundation
import WidgetKit

struct PocketRadioProvider: TimelineProvider {
    typealias Entry = PocketRadioEntry

    func placeholder(in context: Context) -> PocketRadioEntry {
        loadEntry()
    }

    func getSnapshot(in context: Context, completion: @escaping (PocketRadioEntry) -> Void) {
        completion(loadEntry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<Entry>) -> Void) {
        let entry = loadEntry()
        // Same policy as NowPlayingProvider — if nothing is playing, never reload
        // automatically (the app pokes WidgetCenter when state changes).
        let policy: TimelineReloadPolicy = entry.nowPlaying == nil && !entry.isLive ? .never : .atEnd
        completion(Timeline(entries: [entry], policy: policy))
    }

    private func loadEntry() -> PocketRadioEntry {
        let widgetData = WidgetData.shared
        widgetData.reload()

        let nowPlaying = widgetData.nowPlayingEpisode
        nowPlaying?.loadImageData()

        let defaults = UserDefaults(suiteName: SharedConstants.GroupUserDefaults.groupContainerId)

        let isLive = defaults?.bool(forKey: SharedConstants.GroupUserDefaults.pocketRadioIsLiveStream) ?? false
        let isMuted = defaults?.bool(forKey: SharedConstants.GroupUserDefaults.pocketRadioIsMuted) ?? false

        let liveTrack: WidgetLiveTrack? = {
            guard let data = defaults?.data(forKey: SharedConstants.GroupUserDefaults.pocketRadioLiveTrack) else {
                return nil
            }
            return try? JSONDecoder().decode(WidgetLiveTrack.self, from: data)
        }()

        let favorites = Self.loadFavorites(defaults: defaults)

        // "Last podcast" tile (bottom row slot 1):
        // - When a podcast is playing, the first Up Next item IS that podcast.
        // - When live radio is playing, the radio shim *may or may not* survive
        //   `publishUpNextInfo` — `DataManager.findBaseEpisode` returns nil for
        //   the shim, in which case the radio is silently dropped from the
        //   published `upNextItems` JSON. We can't rely on a fixed offset, so
        //   pick the first entry whose uuid isn't the currently-playing
        //   station id.
        let upNext = widgetData.upNextEpisodes ?? []
        let lastPodcast: WidgetEpisode? = {
            if isLive {
                let activeStationId = liveTrack?.stationId
                let candidate = upNext.first(where: { $0.episodeUuid != activeStationId })
                candidate?.loadImageData()
                return candidate
            }
            return nowPlaying
        }()

        return PocketRadioEntry(
            date: Date(),
            nowPlaying: nowPlaying,
            isLive: isLive,
            liveTrack: liveTrack,
            liveArtworkData: isLive ? liveTrack?.loadArtworkData() : nil,
            isPlaying: widgetData.isPlaying,
            isMuted: isMuted,
            favorites: favorites,
            lastPodcast: lastPodcast
        )
    }

    /// Returns exactly 3 favorites, padding with `WidgetFavoriteStation.placeholder`.
    private static func loadFavorites(defaults: UserDefaults?) -> [WidgetFavoriteStation] {
        let decoded: [WidgetFavoriteStation] = {
            guard let data = defaults?.data(forKey: SharedConstants.GroupUserDefaults.pocketRadioFavorites) else {
                return []
            }
            return (try? JSONDecoder().decode([WidgetFavoriteStation].self, from: data)) ?? []
        }()

        var trimmed = Array(decoded.prefix(3))
        while trimmed.count < 3 {
            trimmed.append(.placeholder)
        }
        return trimmed
    }
}
