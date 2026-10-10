#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils
import StreamSession

/// Turns an Apply session's snapshots into the one aligned Now Playing publication. The gate is
/// fail-closed, as the menubar's `RadioApplySelection` is: only a player-sample decision for this
/// session's generation can publish, and a song only when the selected row is a complete track.
/// A feed receipt never publishes. See ADR 0004.
///
/// One exception softens the fail-closed rule. When the player's clock goes invalid for a moment
/// (the program date jumps, or the pairing is lost) while a song is showing, the song stays up for
/// `holdDuration`. If the clock re-pairs in time, nothing changes on screen, or the new song replaces
/// the old one. If it doesn't, the unavailable state is published. See ADR 0005.
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

    /// How long a song stays up while the clock is briefly invalid.
    static let defaultHoldDuration: TimeInterval = 5
    /// Runs `fire` after `delay` and returns a closure that cancels it.
    typealias Schedule = (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void

    /// Whether the player is advancing. Time spent paused or buffering doesn't count against the hold,
    /// because a paused song is still the song. The session sets this after it is created.
    var isPlayerPlaying: () -> Bool = { true }

    private let holdDuration: TimeInterval
    private let now: () -> Date
    private let schedule: Schedule
    private var holdStart: Date?
    private var holdReason = ""
    private var cancelHoldTimer: (() -> Void)?

    init(stationId: String,
         generation: UUID,
         holdDuration: TimeInterval = AlignedNowPlayingPublisher.defaultHoldDuration,
         now: @escaping () -> Date = { Date() },
         schedule: @escaping Schedule = AlignedNowPlayingPublisher.defaultSchedule,
         state: AlignedNowPlayingState = .shared,
         post: @escaping Post = { userInfo in
             NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: userInfo)
         },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) }) {
        self.stationId = stationId
        self.generation = generation
        self.holdDuration = holdDuration
        self.now = now
        self.schedule = schedule
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
            if holdsSong(for: reason) { return }
            publishUnavailable(reason: reason)
            return
        }
        endHold()
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

    /// True while a showing song should stay up through a brief clock fault. Starts the hold on the
    /// first such sample, and gives up once it has lasted `holdDuration`.
    private func holdsSong(for reason: String) -> Bool {
        guard Self.isTransientClockFault(reason), case .song? = last else {
            endHold()
            return false
        }
        let started = holdStart ?? now()
        holdReason = reason
        if holdStart == nil {
            startHold(at: started, reason: reason)
        }
        guard now().timeIntervalSince(started) < holdDuration else {
            // The hold ran out. A player that isn't advancing gets a fresh hold instead: nothing is
            // playing, so the song on screen is still the right one.
            if !isPlayerPlaying() {
                startHold(at: now(), reason: reason)
                return true
            }
            endHold()
            return false
        }
        return true
    }

    private func startHold(at start: Date, reason: String) {
        cancelHoldTimer?()
        holdStart = start
        emit("[align] hold song reason=\(reason) for=\(holdDuration)s")
        cancelHoldTimer = schedule(holdDuration) { [weak self] in self?.holdExpired() }
    }

    /// The timer ran out with the clock still invalid and no new song selected.
    private func holdExpired() {
        guard holdStart != nil else { return }
        let reason = holdReason
        if !isPlayerPlaying() {
            startHold(at: now(), reason: reason)
            return
        }
        endHold()
        emit("[align] hold expired reason=\(reason)")
        publishUnavailable(reason: reason)
    }

    private func endHold() {
        cancelHoldTimer?()
        cancelHoldTimer = nil
        holdStart = nil
    }

    /// A clock fault that usually repairs itself within seconds. A missing pairing at session start
    /// is not one: there is no song to hold yet.
    static func isTransientClockFault(_ reason: String) -> Bool {
        reason == "player clock: backwardJump"
            || reason == "player clock: correlationDiscontinuity"
            || reason == "player clock: mediaProgressionDiscontinuity"
    }

    static func defaultSchedule(_ delay: TimeInterval, _ fire: @escaping @MainActor () -> Void) -> () -> Void {
        let task = Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            guard !Task.isCancelled else { return }
            fire()
        }
        return { task.cancel() }
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
