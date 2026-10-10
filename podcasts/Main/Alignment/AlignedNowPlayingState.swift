#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import UIKit

/// One song the player's clock selected, for the station an Apply session drives. Built only by
/// `AlignedNowPlayingPublisher` from a player-sample decision.
struct AlignedSong: Equatable {
    let stationId: String
    /// The StreamSession occurrence id of the selected feed row.
    let occurrenceID: String
    let title: String
    let artist: String
    let album: String?
    let artworkURL: URL?
    let generation: UUID
    /// The feed row's play time, for matching the song in a history list.
    let playedAt: Date?

    init(stationId: String, occurrenceID: String, title: String, artist: String, album: String?,
         artworkURL: URL?, generation: UUID, playedAt: Date? = nil) {
        self.stationId = stationId
        self.occurrenceID = occurrenceID
        self.title = title
        self.artist = artist
        self.album = album
        self.artworkURL = artworkURL
        self.generation = generation
        self.playedAt = playedAt
    }
}

/// What an Apply session publishes: the selected song, or an explicit "no song" for the station.
/// `.unavailable` never falls back to the feed's newest row.
enum AlignedNowPlaying: Equatable {
    case song(AlignedSong)
    case unavailable(stationId: String, reason: String)
}

/// The aligned Now Playing state that players read. Written only by the Apply session's adapter
/// and lifecycle. Every write is scoped to the session generation that registered the station, so
/// a late callback or stop from an earlier session cannot change a newer one.
@MainActor
final class AlignedNowPlayingState {
    static let shared = AlignedNowPlayingState()

    /// The published state, nil when no Apply session has published (or none is live).
    private(set) var current: AlignedNowPlaying?
    /// Artwork for the current song only.
    private(set) var artwork: (occurrenceID: String, image: UIImage)?

    private var applying: [String: UUID] = [:]
    private var currentOwner: UUID?

    init() {}

    /// True while an Apply session for that station is live.
    func isApplying(stationId: String) -> Bool {
        applying[stationId] != nil
    }

    /// The aligned song as a history entry, nil when the state is unavailable, empty, or for another station.
    func entry(for stationId: String) -> TracklistEntry? {
        guard case .song(let song)? = current, song.stationId == stationId else { return nil }
        return TracklistEntry(title: song.title, artist: song.artist, album: song.album,
                              albumArtURL: song.artworkURL, playedAt: song.playedAt)
    }

    /// Accepts artwork only for the current song's occurrence. Returns whether it was stored.
    @discardableResult
    func setArtwork(_ image: UIImage, occurrenceID: String) -> Bool {
        guard case .song(let song)? = current, song.occurrenceID == occurrenceID else { return false }
        artwork = (occurrenceID, image)
        return true
    }

    // MARK: - Session seam

    /// Registers the station for a new Apply session. Whatever an earlier session published is cleared.
    func beginApplying(stationId: String, generation: UUID) {
        applying[stationId] = generation
        if currentOwner != generation { clearCurrent() }
    }

    /// Clears the station, `current` and `artwork`, but only if this generation still owns them.
    func endApplying(stationId: String, generation: UUID) {
        if applying[stationId] == generation { applying[stationId] = nil }
        if currentOwner == generation { clearCurrent() }
    }

    func isOwner(stationId: String, generation: UUID) -> Bool {
        applying[stationId] == generation
    }

    /// Adapter seam. Rejected unless this generation is the station's live Apply session.
    @discardableResult
    func publish(_ value: AlignedNowPlaying, stationId: String, generation: UUID) -> Bool {
        guard isOwner(stationId: stationId, generation: generation) else { return false }
        current = value
        currentOwner = generation
        if case .song(let song) = value, artwork?.occurrenceID == song.occurrenceID {
            return true
        }
        artwork = nil
        return true
    }

    private func clearCurrent() {
        current = nil
        artwork = nil
        currentOwner = nil
    }
}
#endif
