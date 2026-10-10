import Foundation
import WidgetKit

struct PocketRadioEntry: TimelineEntry {
    let date: Date
    let nowPlaying: WidgetEpisode?
    let isLive: Bool
    let liveTrack: WidgetLiveTrack?
    /// The live song's album art, loaded when the entry is built. Nil shows the station logo.
    let liveArtworkData: Data?
    let isPlaying: Bool
    let isMuted: Bool
    /// Always exactly 3 entries — pad with `WidgetFavoriteStation.placeholder` if
    /// the user has fewer than 3 favorites.
    let favorites: [WidgetFavoriteStation]
    /// First podcast in the Up Next queue, used for the bottom-row "last
    /// podcast" tile. For live radio sessions, `nowPlaying` is the radio shim,
    /// so this gives us the previously-loaded podcast instead.
    let lastPodcast: WidgetEpisode?
}
