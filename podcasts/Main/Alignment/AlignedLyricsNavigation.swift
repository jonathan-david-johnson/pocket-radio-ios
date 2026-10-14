#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// The decisions that let station detail and full-screen lyrics read one media clock
/// (ADR 0005). All pure; the screens only act on the answers.
enum AlignedLyricsPolicy {
    /// What station detail's lyric controller should load.
    enum LyricLoad: Equatable {
        /// The aligned song and its occurrence.
        case aligned(TracklistEntry, occurrenceID: String)
        /// Off: the feed's newest row, on the wall clock, as before.
        case wallClock(TracklistEntry?)
        /// Aligned with no song or occurrence: no lyrics and no timed highlight.
        case none
    }

    /// While applying, the lyrics are the aligned song's, never the feed's top row (the feed runs
    /// ahead of the audio).
    static func lyricLoad(applying: Bool, aligned: TracklistEntry?, occurrenceID: String?,
                          feedTop: TracklistEntry?) -> LyricLoad {
        guard applying else { return .wallClock(feedTop) }
        guard let aligned, let occurrenceID else { return .none }
        return .aligned(aligned, occurrenceID: occurrenceID)
    }

    /// Whether station detail stops its lyrics (timer) when it disappears. While aligned
    /// it keeps them while full-screen lyrics is pushed on top, so the clock
    /// survives. Leaving for real, and any other station, stop as before.
    static func shouldStopOnDisappear(applying: Bool, lyricsScreenOpen: Bool,
                                      isMovingFromParent: Bool, isBeingDismissed: Bool) -> Bool {
        guard applying else { return true }
        return !lyricsScreenOpen || isMovingFromParent || isBeingDismissed
    }

    /// Whether the tapped row is the song the lyrics follow. In Apply that is the aligned song's
    /// row, not row zero; otherwise `wallClockCurrent` is today's answer, unchanged.
    static func isCurrentSong(applying: Bool, row: Int, entries: [TracklistEntry], aligned: TracklistEntry?,
                              wallClockCurrent: Bool) -> Bool {
        guard applying else { return wallClockCurrent }
        return AlignedConsumers.markedRow(in: entries, aligned: aligned) == row
    }

    static let introGrace: TimeInterval = 3
    static let endGrace: TimeInterval = 12

    struct LineState: Equatable {
        /// The highlighted line, from the shared `LyricLineIndex`. Nil: no timed highlight.
        let index: Int?
        let betweenTracks: Bool
    }

    /// The line and presentation for a corrected position: the same windows as station detail, and
    /// no highlight while between tracks.
    static func lineState(lines: [LyricLine], duration: TimeInterval?, position: TimeInterval) -> LineState {
        guard let first = lines.first, let last = lines.last else { return LineState(index: nil, betweenTracks: true) }
        let songEnd = duration ?? (last.timestamp + endGrace)
        if position < first.timestamp - introGrace || position > songEnd + endGrace {
            return LineState(index: nil, betweenTracks: true)
        }
        return LineState(index: LyricLineIndex.index(in: lines, at: position), betweenTracks: false)
    }
}

/// What full-screen lyrics reads when aligned instead of a clock of its own: station detail's position,
/// the station's skew and one-second tick, for one occurrence. Every closure answers for that occurrence only,
/// so a full screen left open across a song change shows no timed highlight and cannot nudge the new song.
struct AlignedLyricsClock {
    let occurrenceID: String
    /// The media-clock song position. Nil when there is no valid position.
    let position: () -> TimeInterval?
    /// The station's skew, in seconds.
    let skew: () -> TimeInterval
    /// Moves the station's skew by the delta and returns the new skew.
    let adjust: (TimeInterval) -> TimeInterval
    /// Calls the handler after each tick of the shared clock; returns the function that unsubscribes.
    let subscribe: (@escaping () -> Void) -> () -> Void
}

extension LyricSyncController {
    func lyricsClock(occurrenceID: String) -> AlignedLyricsClock {
        AlignedLyricsClock(
            occurrenceID: occurrenceID,
            position: { [weak self] in
                guard let self, self.currentOccurrenceID == occurrenceID else { return nil }
                return self.alignedPosition()
            },
            skew: { [weak self] in
                guard let self, self.currentOccurrenceID == occurrenceID else { return 0 }
                return self.currentSkew
            },
            adjust: { [weak self] delta in
                guard let self, self.currentOccurrenceID == occurrenceID else { return 0 }
                return self.adjustOffset(by: delta)
            },
            subscribe: { [weak self] handler in
                self?.observeTicks(handler) ?? {}
            }
        )
    }
}
#endif
