#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import ShazamKit

/// Listens to the microphone through ShazamKit and reports the first match. The mic hears the speaker, so
/// the offset it reports includes the output delay. It works only where the mic can hear the audio: the phone's
/// own speaker or a car cabin. See the ShazamKit experiment.
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
