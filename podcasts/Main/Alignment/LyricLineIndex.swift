#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// The one function that turns a lyric position into a line. Station detail and full-screen lyrics
/// both call it, so the same position always highlights the same line (ADR 0005).
enum LyricLineIndex {
    /// The last line whose timestamp is at or before `position`. Lines with equal timestamps resolve
    /// to the last of them. Nil before the first line or for an empty list. `lines` must be sorted by
    /// timestamp.
    static func index(in lines: [LyricLine], at position: TimeInterval) -> Int? {
        var lo = 0, hi = lines.count - 1
        var match: Int?
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].timestamp <= position {
                match = mid
                lo = mid + 1
            } else {
                hi = mid - 1
            }
        }
        return match
    }
}
#endif
