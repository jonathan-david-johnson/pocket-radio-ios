#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Decides whether a radio artwork slot needs repainting. The mini player repaints on many
/// triggers (rate changes, theme, embedded artwork). A repaint must not replace art that is
/// already showing for the same song with the station logo, because nothing re-resolves it
/// until the next song. See ADR 0005.
enum RadioArtworkRepaint {
    /// Names one song on one station. Includes the aligned occurrence when there is one, so a
    /// song played twice in a row counts as two. Nil when there is no song to resolve.
    static func songKey(stationId: String, entry: TracklistEntry?, occurrenceID: String?) -> String? {
        guard let entry else { return nil }
        var key = [stationId, entry.artist.lowercased(), entry.title.lowercased()].joined(separator: "\u{1F}")
        if let occurrenceID { key += "\u{1F}" + occurrenceID }
        return key
    }

    /// True when the slot already shows art for this song, so a repaint must leave it alone.
    static func isPainted(_ songKey: String?, displayed: String?) -> Bool {
        guard let songKey, let displayed else { return false }
        return songKey == displayed
    }
}
#endif
