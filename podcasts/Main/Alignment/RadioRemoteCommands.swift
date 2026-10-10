#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Which lock-screen and headphone commands are on for live radio. Pure, so the rules are testable.
///
/// A live stream shows Stop instead of skip and pause, because a paused live stream resumes on stale
/// buffered audio. Stop ends the session. The lock screen must still offer Play afterwards, which
/// starts a fresh connection, so the stopped station keeps its Now Playing entry. See ADR 0006.
struct RadioRemoteCommands: Equatable {
    var skipAndTrack: Bool
    var stop: Bool
    var play: Bool
    var pause: Bool
    var togglePlayPause: Bool

    /// - Parameters:
    ///   - liveStream: the current item is a live stream with no duration.
    ///   - stoppedStation: there is no current item, and a live station was stopped from the lock screen.
    static func plan(liveStream: Bool, stoppedStation: Bool) -> RadioRemoteCommands {
        if stoppedStation {
            return RadioRemoteCommands(skipAndTrack: false, stop: false, play: true, pause: false, togglePlayPause: true)
        }
        return RadioRemoteCommands(skipAndTrack: !liveStream, stop: liveStream, play: true, pause: true, togglePlayPause: true)
    }
}
#endif
