#if !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation

/// One timed metadata item the stream delivered, reduced to plain values.
struct TraceMetadata: Equatable {
    let id: String
    let value: String
    /// The media time the metadata applies from, in seconds.
    let start: Double
}

/// Helpers for the `[trace]` log lines. They record what a stream actually does, so a new station can be understood
/// from one session's log (`tools/stream-timeline.py` reads them). Every time is UTC with milliseconds, on the same
/// clock as the feed's stamps and the anchors' `start=`.
enum StreamTrace {
    static func iso(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Short enough for a log line, with quotes and newlines out of the way.
    static func clip(_ text: String, limit: Int = 120) -> String {
        let flat = text.replacingOccurrences(of: "\"", with: "'").replacingOccurrences(of: "\n", with: " ")
        return flat.count > limit ? String(flat.prefix(limit)) + "…" : flat
    }

    static func seconds(_ value: Double?) -> String {
        guard let value, value.isFinite else { return "nil" }
        return String(format: "%.1f", value)
    }
}

/// Receives every timed metadata item of a player item (ICY `StreamTitle` and `StreamUrl`, ID3, ad markers) and hands it
/// on as plain values. It only listens: it never changes playback.
final class StreamTraceDelegate: NSObject, AVPlayerItemMetadataOutputPushDelegate {
    let output = AVPlayerItemMetadataOutput(identifiers: nil)
    private let handler: ([TraceMetadata]) -> Void

    /// `handler` runs on the main queue.
    init(handler: @escaping ([TraceMetadata]) -> Void) {
        self.handler = handler
        super.init()
        output.setDelegate(self, queue: .main)
    }

    func attach(to item: AVPlayerItem) { item.add(output) }
    func detach(from item: AVPlayerItem) { item.remove(output) }

    func metadataOutput(_ output: AVPlayerItemMetadataOutput,
                        didOutputTimedMetadataGroups groups: [AVTimedMetadataGroup],
                        from track: AVPlayerItemTrack?) {
        var found: [TraceMetadata] = []
        for group in groups {
            for item in group.items {
                let id = item.identifier?.rawValue ?? (item.key as? String) ?? "unknown"
                let value = item.stringValue ?? item.dataValue.map { "<\($0.count) bytes>" } ?? "nil"
                found.append(TraceMetadata(id: id, value: value, start: group.timeRange.start.seconds))
            }
        }
        if !found.isEmpty { handler(found) }
    }
}
#endif
