#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import UIKit

/// What the call sites that show or write the current radio song ask when an Apply session may be
/// live for the station. Every answer is "no Apply session" (and so today's behavior) unless
/// `AlignedNowPlayingState.shared.isApplying(stationId:)` says otherwise. See ADR 0004.
///
/// `AlignedNowPlayingState` is main-actor isolated. These readers can be reached from a
/// notification posted on another thread, so each one reads on the main actor: directly when
/// already on the main thread, otherwise by a synchronous hop to main (safe only while main never
/// waits on the calling thread; no current caller does).
enum AlignedConsumers {
    // MARK: - State readers

    static func isApplying(stationId: String) -> Bool {
        onMain { AlignedNowPlayingState.shared.isApplying(stationId: stationId) }
    }

    /// The aligned song as a history entry. Nil when unavailable, empty, or not applying.
    static func entry(for stationId: String) -> TracklistEntry? {
        onMain {
            let state = AlignedNowPlayingState.shared
            return state.isApplying(stationId: stationId) ? state.entry(for: stationId) : nil
        }
    }

    /// The occurrence the player's clock selected right now, nil when unavailable or not applying.
    static func currentOccurrenceID(stationId: String) -> String? {
        onMain {
            let state = AlignedNowPlayingState.shared
            guard state.isApplying(stationId: stationId),
                  case .song(let song)? = state.current, song.stationId == stationId else { return nil }
            return song.occurrenceID
        }
    }

    /// The stored image for the current aligned occurrence, for a full Now Playing rebuild.
    static func artworkForRebuild(stationId: String) -> UIImage? {
        onMain {
            let state = AlignedNowPlayingState.shared
            guard state.isApplying(stationId: stationId),
                  case .song(let song)? = state.current, song.stationId == stationId,
                  let stored = state.artwork, stored.occurrenceID == song.occurrenceID else { return nil }
            return stored.image
        }
    }

    /// Stores resolved artwork for `occurrenceID`. False when that is no longer the current occurrence,
    /// so a late image for an earlier song is never painted.
    static func storeArtwork(_ image: UIImage, occurrenceID: String) -> Bool {
        onMain { AlignedNowPlayingState.shared.setArtwork(image, occurrenceID: occurrenceID) }
    }

    // MARK: - Station detail

    /// Station detail's view of the aligned state: the labels and the history row to mark.
    struct StationDisplay: Equatable {
        let title: String
        let artist: String
        /// Nil when unavailable (no row is marked).
        let markedEntry: TracklistEntry?
    }

    /// Nil when this station is not applying. While applying: the aligned song, the station name when
    /// unavailable, or empty labels before the session has published.
    static func stationDisplay(stationId: String, stationName: String) -> StationDisplay? {
        onMain {
            let state = AlignedNowPlayingState.shared
            guard state.isApplying(stationId: stationId) else { return nil }
            switch state.current {
            case .song(let song)? where song.stationId == stationId:
                return StationDisplay(title: song.title, artist: song.artist, markedEntry: state.entry(for: stationId))
            case .unavailable(let id, _)? where id == stationId:
                return StationDisplay(title: stationName, artist: "", markedEntry: nil)
            default:
                return StationDisplay(title: "", artist: "", markedEntry: nil)
            }
        }
    }

    /// The history row for the aligned song, in feed order. Matches on `playedAt` when both sides
    /// have one, else on title and artist (case-insensitive). Nil when there is no aligned song or no match.
    static func markedRow(in entries: [TracklistEntry], aligned: TracklistEntry?) -> Int? {
        guard let aligned else { return nil }
        func sameSong(_ e: TracklistEntry) -> Bool {
            e.title.lowercased() == aligned.title.lowercased() && e.artist.lowercased() == aligned.artist.lowercased()
        }
        if let playedAt = aligned.playedAt,
           let index = entries.firstIndex(where: { $0.playedAt == playedAt && sameSong($0) }) {
            return index
        }
        return entries.firstIndex(where: sameSong)
    }

    // MARK: - PlaybackManager radio handler

    /// What `PlaybackManager.handleRadioTrackChanged` writes to the Now Playing record.
    struct TrackWrite: Equatable {
        let title: String
        let artist: String
        let album: String?
    }

    /// Decides the track write for a `.radioStationNowPlayingDidChange` notification. While applying,
    /// only an aligned post is honored (ICY and anything else is ignored), and the album comes from
    /// the notification alone: never from the cached tracklist top. Otherwise, today's rule: the cached
    /// tracklist top only fills the artist and album that ICY left empty, and an aligned post is stale.
    /// Returns nil when nothing may be written.
    static func trackWrite(applying: Bool, aligned: Bool, title: String, artist: String,
                           icyAlbum: String?, tracklistTop: TracklistEntry?) -> TrackWrite? {
        guard applying == aligned else { return nil }
        if applying {
            return TrackWrite(title: title, artist: artist, album: icyAlbum)
        }
        return TrackWrite(title: title,
                          artist: artist.isEmpty ? (tracklistTop?.artist ?? "") : artist,
                          album: icyAlbum ?? tracklistTop?.album)
    }

    static func isAligned(_ userInfo: [AnyHashable: Any]?) -> Bool {
        (userInfo?[RadioMetadataNotificationKey.aligned] as? Bool) == true
    }

    // MARK: - Main-actor hop

    private static func onMain<T>(_ body: @MainActor () -> T) -> T {
        if Thread.isMainThread {
            return MainActor.assumeIsolated(body)
        }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }
}
#endif
