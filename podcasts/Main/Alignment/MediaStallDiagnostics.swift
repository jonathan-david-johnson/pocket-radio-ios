#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils

/// Observes one aligned item without changing the player. Never logs URLs, server addresses or error descriptions.
final class MediaStallDiagnostics {
    private let item: AVPlayerItem
    private weak var player: AVPlayer?
    private let generation: String
    private let emit: (String) -> Void
    private var observers: [NSObjectProtocol] = []
    private var statusObserver: NSKeyValueObservation?
    /// Error events already logged, so each event is logged once, in order.
    private var errorEventsLogged = 0

    init(item: AVPlayerItem, player: AVPlayer, generation: String,
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) }) {
        self.item = item
        self.player = player
        self.generation = generation
        self.emit = emit
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .AVPlayerItemNewAccessLogEntry, object: item, queue: nil) { [weak self] _ in
                self?.captureAccess(trigger: "notification")
            },
            center.addObserver(forName: .AVPlayerItemNewErrorLogEntry, object: item, queue: nil) { [weak self] _ in
                self?.captureErrors(trigger: "notification")
            }
        ]
        statusObserver = player.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] player, _ in
            self?.log("status=\(Self.status(player.timeControlStatus)) wait=\(Self.waitReason(player.reasonForWaitingToPlay))")
        }
        log("attached")
        captureAccess(trigger: "attach")
        captureErrors(trigger: "attach")
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        statusObserver?.invalidate()
    }

    func seek(target: Double, origin: String) {
        log("seek origin=\(origin) from=\(Self.seconds(item.currentTime().seconds)) target=\(Self.seconds(target))")
    }

    func snapshot(trigger: String, error: Error? = nil) {
        let reason = Self.waitReason(player?.reasonForWaitingToPlay)
        log("snapshot trigger=\(trigger) wait=\(reason) media=\(Self.seconds(item.currentTime().seconds)) "
            + "empty=\(item.isPlaybackBufferEmpty) keepUp=\(item.isPlaybackLikelyToKeepUp) "
            + "preferred=\(Self.seconds(item.preferredForwardBufferDuration))")
        if let error { log("error trigger=\(trigger) \(Self.errorChain(error as NSError))") }
        if let error = item.error { log("itemError trigger=\(trigger) \(Self.errorChain(error as NSError))") }
        if let error = player?.error { log("playerError trigger=\(trigger) \(Self.errorChain(error as NSError))") }
        captureAccess(trigger: trigger)
        captureErrors(trigger: trigger)
    }

    private func log(_ line: String) { emit("[media-diag] gen=\(generation) \(line)") }

    private func captureAccess(trigger: String) {
        // Synchronous APIs remain available for the deployment target; capture before teardown.
        guard let log = item.accessLog() else { self.log("access trigger=\(trigger) unavailable"); return }
        guard let event = log.events.last else { self.log("access trigger=\(trigger) events=0"); return }
        self.log("access trigger=\(trigger) events=\(log.events.count) requests=\(event.numberOfMediaRequests) "
                 + "stalls=\(event.numberOfStalls) bytes=\(event.numberOfBytesTransferred) "
                 + "transfer=\(Self.seconds(event.transferDuration)) observed=\(Self.seconds(event.observedBitrate)) "
                 + "indicated=\(Self.seconds(event.indicatedBitrate))")
    }

    private func captureErrors(trigger: String) {
        guard let log = item.errorLog() else { self.log("errorLog trigger=\(trigger) unavailable"); return }
        let events = log.events
        guard events.count > errorEventsLogged else {
            self.log("errorLog trigger=\(trigger) events=\(events.count) new=0")
            return
        }
        // Bounded, so a burst of errors can't flood the log; the count still says how many there were.
        let new = events[errorEventsLogged...]
        for (offset, event) in new.suffix(Self.maximumErrorEventsPerCapture).enumerated() {
            let index = events.count - min(new.count, Self.maximumErrorEventsPerCapture) + offset + 1
            let status = Self.httpStatus(comment: event.errorComment)
            self.log("errorLog trigger=\(trigger) event=\(index)/\(events.count) "
                     + "domain=\(Self.safeDomain(event.errorDomain)) code=\(event.errorStatusCode) "
                     + "httpFromComment=\(status.map(String.init) ?? "unknown") "
                     + "resource=\(Self.resourceType(event.uri)) date=\(StreamTrace.iso(event.date)) "
                     + "comment=\"\(Self.redactedComment(event.errorComment))\"")
        }
        errorEventsLogged = events.count
    }

    static let maximumErrorEventsPerCapture = 5

    /// Keeps AVPlayer's wording ("No response for media file in 5.99s", "HTTP 404: File Not Found") but removes
    /// URLs, file names, addresses and long tokens, and caps the length.
    static func redactedComment(_ comment: String?) -> String {
        guard var text = comment, !text.isEmpty else { return "" }
        let patterns = [
            #"[A-Za-z][A-Za-z0-9+.-]*://\S+"#,          // URLs of any scheme
            #"\S+\.(?i:m3u8|aac|ts|m4s|mp4|mp3)\S*"#,    // resource names
            #"\b\d{1,3}(?:\.\d{1,3}){3}(?::\d+)?\b"#,    // IPv4 addresses
            #"\b[0-9A-Fa-f:]{2,}:[0-9A-Fa-f:]{2,}\b"#,    // IPv6 addresses
            #"[A-Za-z0-9_\-=!]{20,}"#                     // session ids and other long tokens
        ]
        for pattern in patterns {
            text = text.replacingOccurrences(of: pattern, with: "<redacted>", options: .regularExpression)
        }
        text = text.replacingOccurrences(of: "\"", with: "'")
        return text.count > 120 ? String(text.prefix(120)) + "…" : text
    }

    /// Reports only explicitly labelled HTTP codes; unrelated numbers may be media or OS error codes.
    static func httpStatus(comment: String?) -> Int? {
        guard let comment else { return nil }
        let pattern = #"(?i)\b(?:http(?:/\d(?:\.\d)?)?\s+(?:status\s*(?:code)?\s*[:=]?\s*)?|http\s*[:=]\s*)([1-5]\d{2})\b"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: comment, range: NSRange(comment.startIndex..., in: comment)),
              let range = Range(match.range(at: 1), in: comment) else { return nil }
        return Int(comment[range])
    }

    /// Never returns a URL component. Unknown paths are not assumed to be media segments.
    static func resourceType(_ raw: String?) -> String {
        guard let raw, let components = URLComponents(string: raw) else { return "unknown" }
        let ext = (components.path as NSString).pathExtension.lowercased()
        switch ext {
        case "m3u8": return "playlist"
        case "ts", "aac", "m4s", "mp4": return "media"
        default: return "other"
        }
    }

    static func errorChain(_ error: NSError) -> String {
        var current: NSError? = error
        var values: [String] = []
        for _ in 0..<8 {
            guard let error = current else { break }
            values.append("\(safeDomain(error.domain)):\(error.code)")
            current = error.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return "chain=" + values.joined(separator: ">")
    }

    static func safeDomain(_ domain: String?) -> String {
        guard let domain else { return "nil" }
        switch domain {
        case NSURLErrorDomain, NSCocoaErrorDomain, NSPOSIXErrorDomain, AVFoundationErrorDomain,
             "CoreMediaErrorDomain", "NSOSStatusErrorDomain": return domain
        default: return "other"
        }
    }

    static func seconds(_ value: Double) -> String {
        value.isFinite ? String(format: "%.2f", value) : "unknown"
    }

    static func waitReason(_ reason: AVPlayer.WaitingReason?) -> String {
        switch reason {
        case .toMinimizeStalls: return "minimizeStalls"
        case .evaluatingBufferingRate: return "evaluatingBufferingRate"
        case .noItemToPlay: return "noItem"
        case nil: return "none"
        default: return "other"
        }
    }

    static func status(_ status: AVPlayer.TimeControlStatus) -> String {
        switch status {
        case .paused: return "paused"
        case .waitingToPlayAtSpecifiedRate: return "waiting"
        case .playing: return "playing"
        @unknown default: return "unknown"
        }
    }
}
#endif
