#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// The self-healing correction the running alignment session applies, in seconds. In memory only: it belongs to one
/// session and is re-learned for the next, because the stream's real offset differs from one session to the next.
/// A positive value means the audio runs ahead of the app, so the feed-to-program offset gets smaller by that much.
/// Always zero in Release, where nothing sets it. See the ShazamKit experiment.
@MainActor
final class AlignmentCorrection {
    static let shared = AlignmentCorrection()

    private var stored = 0.0
    private var owner: UUID?

    /// The live value, whichever session set it.
    var current: Double { stored }

    /// The value for a session: zero unless that session's generation set it.
    func value(for generation: UUID) -> Double { owner == generation ? stored : 0 }

    func set(_ seconds: Double, generation: UUID) {
        guard seconds.isFinite else { return }
        stored = seconds
        owner = generation
    }

    func reset() {
        stored = 0
        owner = nil
    }
}

/// When to move the applied correction. A small difference is ignored so a title or lyric line never lurches for
/// a fraction of a second.
enum CorrectionGate {
    static let deadband = 1.0

    /// The correction to apply, or nil to leave the one in use.
    static func next(applied: Double, learned: Double?, deadband: Double = CorrectionGate.deadband) -> Double? {
        guard let learned, learned.isFinite else { return nil }
        return abs(learned - applied) >= deadband ? learned : nil
    }
}
#endif
