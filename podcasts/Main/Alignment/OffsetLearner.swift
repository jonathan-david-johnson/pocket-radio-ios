#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// One measurement of a number that should be constant, taken at one instant. In the heal it is the skew an anchor
/// implies. `delta` keeps the name from when the number was a correction.
/// `time` is any monotonic clock, in seconds.
struct OffsetAnchor: Equatable {
    let time: TimeInterval
    let delta: Double
}

/// Tuning for `OffsetLearner`. The defaults come from the simulated sweep in `OffsetLearnerTests`
/// (`testParameterSweep`): a window of 7, a 2 s outlier threshold and a run of 3 gave the lowest error in
/// every simulated world with no flip-flops.
struct OffsetLearnerConfig: Equatable {
    init(maxCorrection: Double = 10) { self.maxCorrection = maxCorrection }

    /// Anchors kept for the median.
    var window = 7
    /// Anchors needed before the first correction is reported. Three let a median outvote one wrong anchor.
    var minAnchors = 3
    /// The correction is clamped to ±this many seconds.
    var maxCorrection = 10.0
    /// An anchor this far from the current median is held back as an outlier, not added to the window.
    var outlierThreshold = 2.0
    /// This many consecutive held-back anchors that agree with each other replace the window: the offset really moved.
    var stepRun = 3
    /// "Agree with each other": the spread of the run is at most this.
    var stepAgreement = 1.0
    /// Anchors older than this are dropped when a new one arrives.
    var maxAge: TimeInterval = 30 * 60
}

/// Learns a constant, such as the skew, from a stream of anchors. Pure: no clock, no I/O. It is built to resist the three ways an anchor goes wrong: noise
/// (a median over a window), a wrong-song or bad match (held back as an outlier), and a real change in
/// the feed's latency (a run of agreeing outliers replaces the window). See ADR 0010.
struct OffsetLearner {
    let config: OffsetLearnerConfig
    private(set) var anchors: [OffsetAnchor] = []
    private var heldBack: [OffsetAnchor] = []
    private var lastReported: Double?
    /// Anchors held back as outliers over the learner's life, for diagnostics.
    private(set) var rejectedCount = 0
    /// Times the window was replaced because the offset moved.
    private(set) var stepCount = 0

    init(config: OffsetLearnerConfig = OffsetLearnerConfig()) {
        self.config = config
    }

    /// The correction to add to the song position, clamped. Nil until the first `minAnchors` anchors
    /// have arrived. After that it never goes back to nil: while the window refills after a long gap or a
    /// step, the last reported value is held.
    var correction: Double? {
        let computed = anchors.count >= config.minAnchors ? Self.median(anchors.map(\.delta)) : nil
        guard let value = computed ?? lastReported else { return nil }
        return min(config.maxCorrection, max(-config.maxCorrection, value))
    }

    /// True when the unclamped estimate is beyond `maxCorrection`, which usually means something else is wrong.
    var isSaturated: Bool {
        guard anchors.count >= config.minAnchors else { return false }
        return abs(Self.median(anchors.map(\.delta))) > config.maxCorrection
    }

    mutating func add(_ anchor: OffsetAnchor) {
        guard anchor.delta.isFinite, anchor.time.isFinite else { return }
        anchors.removeAll { anchor.time - $0.time > config.maxAge }
        remember()

        if anchors.count >= config.minAnchors {
            let median = Self.median(anchors.map(\.delta))
            if abs(anchor.delta - median) > config.outlierThreshold {
                heldBack.append(anchor)
                rejectedCount += 1
                if heldBack.count >= config.stepRun, Self.spread(heldBack.suffix(config.stepRun).map(\.delta)) <= config.stepAgreement {
                    anchors = Array(heldBack.suffix(config.stepRun))
                    heldBack = []
                    stepCount += 1
                    remember()
                }
                return
            }
        }
        heldBack = []
        anchors.append(anchor)
        if anchors.count > config.window { anchors.removeFirst(anchors.count - config.window) }
        remember()
    }

    mutating func reset() {
        anchors = []
        heldBack = []
        lastReported = nil
        rejectedCount = 0
        stepCount = 0
    }

    private mutating func remember() {
        if anchors.count >= config.minAnchors { lastReported = Self.median(anchors.map(\.delta)) }
    }

    static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    static func spread(_ values: [Double]) -> Double {
        guard let low = values.min(), let high = values.max() else { return 0 }
        return high - low
    }
}
#endif
