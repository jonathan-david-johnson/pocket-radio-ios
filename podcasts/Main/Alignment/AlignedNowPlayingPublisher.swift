#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils
import StreamSession

/// Turns an Apply session's snapshots into the one aligned Now Playing publication. The gate is
/// fail-closed, as the menubar's `RadioApplySelection` is: only a player-sample decision for this
/// session's generation can publish, and a song only when the selected row is a complete track.
/// A feed receipt never publishes. See ADR 0004.
@MainActor
final class AlignedNowPlayingPublisher {
    typealias Post = ([AnyHashable: Any]) -> Void

    /// What was last published, compared so only a change posts.
    private enum Published: Equatable {
        case song(AlignedSong)
        case unavailable
    }

    let stationId: String
    let generation: UUID
    private let state: AlignedNowPlayingState
    private let post: Post
    private let emit: (String) -> Void
    private var last: Published?

    init(stationId: String,
         generation: UUID,
         state: AlignedNowPlayingState = .shared,
         post: @escaping Post = { userInfo in
             NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: userInfo)
         },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) }) {
        self.stationId = stationId
        self.generation = generation
        self.state = state
        self.post = post
        self.emit = emit
    }

    func receive(_ snapshot: RadioAlignmentSnapshot) {
        guard snapshot.generation == generation,
              state.isOwner(stationId: stationId, generation: generation),
              snapshot.trigger == .playerSample else { return }

        guard let song = Self.song(from: snapshot, stationId: stationId) else {
            let reason = snapshot.candidateID == nil ? snapshot.reason : "selected row is not a song"
            publishUnavailable(reason: reason)
            return
        }
        // Whole-song comparison: a feed correction to the current song's fields republishes it.
        guard last != .song(song) else { return }
        guard state.publish(.song(song), stationId: stationId, generation: generation) else { return }
        last = .song(song)
        emit("[align] publish song=\(song.title) — \(song.artist) occ=\(song.occurrenceID)")
        var userInfo: [AnyHashable: Any] = [
            RadioMetadataNotificationKey.stationId: stationId,
            RadioMetadataNotificationKey.title: song.title,
            RadioMetadataNotificationKey.artist: song.artist,
            RadioMetadataNotificationKey.aligned: true
        ]
        if let album = song.album, !album.isEmpty {
            userInfo[RadioMetadataNotificationKey.album] = album
        }
        post(userInfo)
    }

    private func publishUnavailable(reason: String) {
        guard last != .unavailable else { return }
        guard state.publish(.unavailable(stationId: stationId, reason: reason),
                            stationId: stationId, generation: generation) else { return }
        last = .unavailable
        emit("[align] publish unavailable reason=\(reason)")
        post([
            RadioMetadataNotificationKey.stationId: stationId,
            RadioMetadataNotificationKey.title: "",
            RadioMetadataNotificationKey.artist: "",
            RadioMetadataNotificationKey.aligned: true
        ])
    }

    /// The fail-closed gate: nil unless the snapshot is a complete, paired, selected track.
    static func song(from snapshot: RadioAlignmentSnapshot, stationId: String) -> AlignedSong? {
        guard snapshot.trigger == .playerSample,
              snapshot.programDate != nil,
              let occurrence = snapshot.selectedOccurrence,
              occurrence.id == snapshot.candidateID,
              occurrence.kind == "trackplay",
              let title = occurrence.title, !title.isEmpty,
              let artist = occurrence.artist, !artist.isEmpty,
              let seconds = snapshot.songSeconds, seconds.isFinite, seconds >= 0 else { return nil }
        return AlignedSong(stationId: stationId,
                           occurrenceID: occurrence.id.rawValue,
                           title: title,
                           artist: artist,
                           album: occurrence.album,
                           artworkURL: occurrence.artworkURL.flatMap(URL.init(string:)),
                           generation: snapshot.generation,
                           playedAt: occurrence.playedAt)
    }
}
#endif
