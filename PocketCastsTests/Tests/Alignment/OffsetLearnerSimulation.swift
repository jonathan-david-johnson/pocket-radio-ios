import Foundation
@testable import podcasts

/// Deterministic random numbers, so a simulated run is the same every time.
struct SeededRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E3779B97F4A7C15 }

    mutating func nextUInt64() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }

    /// Uniform in [0, 1).
    mutating func uniform() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }

    /// Standard normal, Box–Muller.
    mutating func gaussian() -> Double {
        let u1 = max(uniform(), 1e-12), u2 = uniform()
        return (-2 * log(u1)).squareRoot() * cos(2 * .pi * u2)
    }
}

/// A world the learner is run against. `truth(t)` is the real offset between feed and audio at time `t`.
/// Anchors arrive every `interval`, each measured with Gaussian `noise`. A fraction `outlierRate` are wrong
/// (a bad match), off by a random 8 to 20 s. Anchors inside `gaps` are never delivered.
struct SimulatedWorld {
    var truth: (TimeInterval) -> Double
    var interval: TimeInterval = 120
    var noise = 0.4
    var outlierRate = 0.0
    var gaps: [ClosedRange<TimeInterval>] = []
    var seed: UInt64 = 1

    struct Step {
        let time: TimeInterval
        let truth: Double
        /// The learner's correction after this step; nil before the first.
        let correction: Double?
        let anchorDelivered: Bool
    }

    func run(config: OffsetLearnerConfig, duration: TimeInterval) -> [Step] {
        var random = SeededRandom(seed: seed)
        var learner = OffsetLearner(config: config)
        var steps: [Step] = []
        var t = interval
        while t <= duration {
            let real = truth(t)
            let inGap = gaps.contains { $0.contains(t) }
            if !inGap {
                var measured = real + noise * random.gaussian()
                if random.uniform() < outlierRate {
                    let sign: Double = random.uniform() < 0.5 ? -1 : 1
                    measured += sign * (8 + 12 * random.uniform())
                }
                learner.add(OffsetAnchor(time: t, delta: measured))
            }
            steps.append(Step(time: t, truth: real, correction: learner.correction, anchorDelivered: !inGap))
            t += interval
        }
        return steps
    }
}

/// What a run is judged on.
struct RunMetrics {
    /// Number of anchors delivered before the first correction.
    let anchorsToFirstCorrection: Int?
    /// Largest absolute error, in seconds, after the correction was first reported.
    let worstError: Double
    /// 95th percentile of the absolute error after the correction was first reported.
    let p95Error: Double
    /// Times the correction moved by more than `flipThreshold` (a visible lurch, 1 s) against its previous direction.
    let flipFlops: Int

    init(_ steps: [Step], from: TimeInterval = 0, flipThreshold: Double = 1.0) {
        let relevant = steps.filter { $0.time >= from }
        let errors = relevant.compactMap { s in s.correction.map { abs($0 - s.truth) } }
        anchorsToFirstCorrection = steps.firstIndex { $0.correction != nil }.map { $0 + 1 }
        worstError = errors.max() ?? .infinity
        let sorted = errors.sorted()
        p95Error = sorted.isEmpty ? .infinity : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        var flips = 0
        var lastDirection = 0.0
        var previous: Double?
        for step in relevant {
            guard let value = step.correction else { continue }
            if let previous {
                let move = value - previous
                if abs(move) > flipThreshold {
                    if lastDirection != 0, move.sign != lastDirection.sign { flips += 1 }
                    lastDirection = move
                }
            }
            previous = value
        }
        flipFlops = flips
    }

    typealias Step = SimulatedWorld.Step
}
