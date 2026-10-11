#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import StreamSession

/// The feed-to-program offset the session actually uses: the frozen `+160 s`, plus a Debug feed skew that
/// mimics a feed running late or early, minus a learned correction (zero until the self-healing offset
/// exists). A positive correction means the audio is ahead of the app, so the offset gets smaller.
enum AlignmentOffset {
    static func effective(base: Double, skew: Double, correction: Double = 0) -> Double {
        base + skew - correction
    }

    static func policy(skew: Double, correction: Double = 0) -> OccurrenceSelectionPolicy {
        let frozen = KCRWAlignmentConfiguration.selectionPolicy
        return OccurrenceSelectionPolicy(
            feedToProgramOffset: effective(base: frozen.feedToProgramOffset, skew: skew, correction: correction),
            maxSelectedAge: frozen.maxSelectedAge,
            maxFeedSilence: frozen.maxFeedSilence)
    }
}
#endif
