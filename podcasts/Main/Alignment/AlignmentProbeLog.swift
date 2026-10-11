#if !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import CoreMedia
import Foundation
import PocketCastsUtils

/// Formats the per-tick `[align]` probe line. Pure, so the format is testable without a player.
enum AlignmentProbeLog {
    private static let dateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    static func shortID(_ generation: UUID) -> String {
        String(generation.uuidString.prefix(8))
    }

    static func line(generation: UUID,
                     elapsed: TimeInterval,
                     media: TimeInterval?,
                     date: Date?,
                     rate: Float,
                     status: AVPlayer.TimeControlStatus?,
                     buffer: TimeInterval? = nil,
                     likelyToKeepUp: Bool? = nil) -> String {
        let mediaText = media.flatMap { $0.isFinite ? String(format: "%.1f", $0) : nil } ?? "nil"
        let dateText = date.map { dateFormatter.string(from: $0) } ?? "nil"
        var text = "[align] probe gen=\(shortID(generation)) t=\(String(format: "%.1f", elapsed)) "
            + "media=\(mediaText) date=\(dateText) rate=\(String(format: "%.2f", rate)) status=\(statusText(status))"
        // Forward buffer: seconds of audio loaded ahead of the playhead. Only logged when known.
        if let buffer, buffer.isFinite { text += String(format: " buf=%.1f", buffer) }
        if let likelyToKeepUp { text += " keepUp=\(likelyToKeepUp ? 1 : 0)" }
        return text
    }

    /// Seconds of audio already loaded ahead of `current`, from the loaded ranges. Nil when the playhead
    /// is outside every range, which means nothing is buffered there.
    static func forwardBuffer(loadedRanges: [CMTimeRange], current: CMTime) -> TimeInterval? {
        guard current.isValid, current.seconds.isFinite else { return nil }
        for range in loadedRanges where range.isValid && range.containsTime(current) {
            return max(0, range.end.seconds - current.seconds)
        }
        return nil
    }

    static func statusText(_ status: AVPlayer.TimeControlStatus?) -> String {
        switch status {
        case .playing: return "playing"
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        default: return "?"
        }
    }

    /// Host and path only. The query and credentials can carry tokens and never reach the log.
    static func safeEndpoint(_ url: URL) -> String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return "invalid" }
        return (components.host ?? "") + components.path
    }
}
#endif
