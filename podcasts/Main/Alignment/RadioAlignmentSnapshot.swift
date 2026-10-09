#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import StreamSession

/// Same-item decision and retained evidence for the Observe readout. Value type; nothing here
/// is published to the listener. An unavailable state carries an explicit `reason` and no
/// candidate: the feed top is shown as evidence only and is never used as a fallback.
struct RadioAlignmentSnapshot: Equatable {
    let generation: UUID
    /// Host and path only.
    let endpoint: String
    let feedTop: String?
    let candidate: String?
    let candidateID: OccurrenceID?
    let songSeconds: Double?
    let mediaSeconds: Double?
    let programDate: Date?
    let reason: String
    let feedStatus: String
    let cacheAgeSeconds: Double?
    let historyCount: Int
    let lastPollElapsed: TimeInterval?
    let clockValid: Bool
    let trigger: DecisionTrigger?

    static let initialReason = "waiting for paired player clock and feed"
}
#endif
