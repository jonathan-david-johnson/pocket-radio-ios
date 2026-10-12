#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils

/// Runs the self-healing offset: calibrates with a short burst of anchors when a session starts, then re-anchors
/// every few minutes, and in Apply mode moves the session's offset to the learned correction. Debug only. See the
/// ShazamKit experiment.
///
/// One `step()` makes one decision, so a test can drive it without a real clock. The loop only calls `step` and sleeps.
@MainActor
final class SelfHealController: ObservableObject {
    static let shared = SelfHealController()

    struct Timing {
        /// Between anchors while calibrating.
        var calibrationGap: TimeInterval = 5
        /// Between anchors once calibrated.
        var steadyInterval: TimeInterval = 180
        /// Next anchor after an outlier, to confirm or dismiss a possible real change quickly.
        var burstGap: TimeInterval = 20
        /// How often the loop looks when there is nothing to do.
        var poll: TimeInterval = 5
        var maxBackoff: TimeInterval = 60
    }

    @Published private(set) var phase = "Off"

    private let probe: ShazamAnchorProbe
    private let mode: @MainActor () -> SelfHealMode
    private let session: @MainActor () -> UUID?
    private let skew: @MainActor () -> Double
    private let correction: AlignmentCorrection
    private let now: () -> TimeInterval
    private let emit: (String) -> Void
    private let timing: Timing
    private let minAnchors: Int

    private var loop: Task<Void, Never>?
    private var lastGeneration: UUID?
    private var lastSkew: Double?
    private var lastAnchorAt: TimeInterval?
    private var failures = 0
    private var lastRejected = 0
    private var quickNext = false

    /// The Debug skew moves the app's model by up to ±15 s on top of the real offset, so the learner may need to
    /// reach further than the ±10 s a real offset would ask for.
    static let experimentLearnerConfig = OffsetLearnerConfig(maxCorrection: 20)

    init(probe: ShazamAnchorProbe? = nil,
         mode: @escaping @MainActor () -> SelfHealMode = { ObserveSwitchStore.shared.selfHeal },
         session: @escaping @MainActor () -> UUID? = { RadioPlaybackSession.active.flatMap { $0.mode == .apply ? $0.generation : nil } },
         skew: @escaping @MainActor () -> Double = { ObserveSwitchStore.shared.feedSkew },
         correction: AlignmentCorrection = .shared,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         timing: Timing = Timing(),
         minAnchors: Int = OffsetLearnerConfig().minAnchors) {
        self.probe = probe ?? ShazamAnchorProbe(learnerConfig: Self.experimentLearnerConfig)
        self.mode = mode
        self.session = session
        self.skew = skew
        self.correction = correction
        self.now = now
        self.emit = emit
        self.timing = timing
        self.minAnchors = minAnchors
    }

    /// The probe, so the Debug screen shows the same anchors.
    var anchorProbe: ShazamAnchorProbe { probe }

    func ensureRunning() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let wait = await self.step()
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            }
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
    }

    /// One decision. Returns how long to wait before the next.
    @discardableResult
    func step() async -> TimeInterval {
        let current = mode()
        guard current != .off else {
            phase = "Off"
            return timing.poll
        }
        guard let generation = session() else {
            phase = "Waiting for a KCRW session in Apply"
            lastGeneration = nil
            return timing.poll
        }
        let skewNow = skew()
        if generation != lastGeneration {
            // A new session: the stream's offset is measured again, from zero.
            lastGeneration = generation
            lastSkew = skewNow
            probe.resetLearning()
            correction.reset()
            lastAnchorAt = nil
            failures = 0
            lastRejected = 0
            quickNext = false
            emit("[selfheal] new session: calibrating (\(current.rawValue))")
        } else if skewNow != lastSkew {
            // The skew moved the app's model, so what was learned no longer describes it. Keep the applied
            // correction and learn again.
            lastSkew = skewNow
            probe.resetLearning()
            lastAnchorAt = nil
            lastRejected = 0
            emit("[selfheal] skew changed to \(String(format: "%+.1f", skewNow)) s: calibrating again")
        }

        let calibrating = probe.learnerAnchorCount < minAnchors
        let gap = calibrating ? timing.calibrationGap : (quickNext ? timing.burstGap : timing.steadyInterval)
        if let last = lastAnchorAt, now() - last < gap {
            phase = describe(calibrating: calibrating, mode: current)
            return timing.poll
        }

        phase = "Listening…"
        let measurement = await probe.anchorNow()
        lastAnchorAt = now()
        // The session can end or restart while the mic listens. An anchor read for an earlier session must not
        // set a correction for the one that has started since (the next step resets and calibrates again).
        guard session() == generation else {
            emit("[selfheal] discarded an anchor: the session changed while listening")
            return timing.poll
        }
        guard measurement != nil else {
            failures += 1
            phase = describe(calibrating: calibrating, mode: current)
            return min(timing.maxBackoff, timing.poll * Double(1 << min(failures, 4)))
        }
        failures = 0

        let rejected = probe.learnerRejectedCount
        quickNext = rejected > lastRejected
        lastRejected = rejected

        if current == .apply, let next = CorrectionGate.next(applied: correction.current, learned: probe.learnedCorrection) {
            correction.set(next, generation: generation)
            emit("[selfheal] applied correction \(String(format: "%+.1f", next)) s")
        }
        phase = describe(calibrating: probe.learnerAnchorCount < minAnchors, mode: current)
        return timing.poll
    }

    private func describe(calibrating: Bool, mode: SelfHealMode) -> String {
        if calibrating { return "Calibrating (\(probe.learnerAnchorCount)/\(minAnchors))" }
        let learned = probe.learnedCorrection.map { String(format: "%+.1f s", $0) } ?? "none"
        return mode == .apply
            ? "Tracking: learned \(learned), applied \(String(format: "%+.1f s", correction.current))"
            : "Measuring: learned \(learned), not applied"
    }
}
#endif
