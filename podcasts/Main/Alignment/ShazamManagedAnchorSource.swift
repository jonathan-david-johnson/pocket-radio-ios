#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import ShazamKit

/// Asks ShazamKit's managed session for the first match. On the phone this heard the app's own playback, not the room: a
/// heal matched the station's song with the phone in a drawer, the headphone volume at zero, and a different song playing
/// loudly nearby, and the audio session stayed on playback with no input. So the offset it reports is the stream's timeline
/// before the output, without any speaker or Bluetooth delay (ADR 0010).
final class ShazamManagedAnchorSource: OffsetAnchorSource {
    private var session: SHManagedSession?

    func anchor() async -> AnchorOutcome {
        let session = SHManagedSession()
        self.session = session
        defer { self.session = nil }
        switch await session.result() {
        case .match(let match):
            guard let item = match.mediaItems.first else { return .noMatch }
            let confidence: Double?
            if #available(iOS 18.4, *) { confidence = Double(item.confidence) } else { confidence = nil }
            return .matched(AnchorMatch(title: item.title ?? "",
                                        artist: item.artist ?? "",
                                        matchOffset: item.matchOffset,
                                        predictedOffset: item.predictedCurrentMatchOffset,
                                        confidence: confidence,
                                        frequencySkew: Double(item.frequencySkew)))
        case .noMatch:
            return .noMatch
        case .error(let error, _):
            return .error(String(describing: error))
        }
    }

    func cancel() {
        session?.cancel()
    }
}
#endif
