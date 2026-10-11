#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// How `DefaultPlayer` resumes after `AVPlayerItemPlaybackStalled`.
///
/// Recovering with `play()` seeks to the episode's saved position. A live radio station keeps a saved
/// position like any episode, so a stall sent the live HLS item back to a stale point, up to about 80 s
/// behind: the buffer was flushed, the audio dropped out for several seconds, and the previous song
/// played again. A live stream has no position to return to, so it resumes without seeking, as an HLS
/// podcast already does. See ADR 0007.
enum StallRecovery {
    static func resumesWithoutSeeking(streamingHLS: Bool, liveRadio: Bool) -> Bool {
        streamingHLS || liveRadio
    }
}
#endif
