import XCTest
@testable import podcasts

/// The self-healing offset learner against simulated worlds. These are the criteria from the ShazamKit
/// experiment: converge fast, stay accurate, ignore bad anchors, follow a real change, never flip-flop.
final class OffsetLearnerTests: XCTestCase {
    private let twoHours: TimeInterval = 7200
    private let config = OffsetLearnerConfig()

    private func anchor(_ t: TimeInterval, _ delta: Double) -> OffsetAnchor { OffsetAnchor(time: t, delta: delta) }

    // MARK: - The unit

    func testNoCorrectionUntilThreeAnchors() {
        var learner = OffsetLearner()
        learner.add(anchor(0, 3)); learner.add(anchor(1, 3.1))
        XCTAssertNil(learner.correction)
        learner.add(anchor(2, 2.9))
        XCTAssertEqual(learner.correction ?? -1, 3.0, accuracy: 0.001)
    }

    func testAWrongFirstAnchorIsOutvotedByTheMedian() {
        var learner = OffsetLearner()
        [-15.0, 3.1, 2.9].enumerated().forEach { learner.add(anchor(Double($0.offset), $0.element)) }
        XCTAssertEqual(learner.correction ?? -1, 2.9, accuracy: 0.001)
    }

    func testTheCorrectionIsClampedAndFlaggedWhenSaturated() {
        var learner = OffsetLearner()
        (0..<3).forEach { learner.add(anchor(Double($0), 25)) }
        XCTAssertEqual(learner.correction, 10)
        XCTAssertTrue(learner.isSaturated)
        var negative = OffsetLearner()
        (0..<3).forEach { negative.add(anchor(Double($0), -25)) }
        XCTAssertEqual(negative.correction, -10)
    }

    func testAnOutlierIsHeldBackAndDoesNotMoveTheWindow() {
        var learner = OffsetLearner()
        (0..<3).forEach { learner.add(anchor(Double($0), 3)) }
        learner.add(anchor(10, 14))
        XCTAssertEqual(learner.correction ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(learner.rejectedCount, 1)
    }

    func testARunOfAgreeingOutliersReplacesTheWindow() {
        var learner = OffsetLearner()
        (0..<5).forEach { learner.add(anchor(Double($0), 3)) }
        [8.0, 8.2, 7.9].enumerated().forEach { learner.add(anchor(10 + Double($0.offset), $0.element)) }
        XCTAssertEqual(learner.correction ?? -1, 8.0, accuracy: 0.25)
        XCTAssertEqual(learner.stepCount, 1)
    }

    func testOutliersThatDisagreeDoNotMakeAStep() {
        var learner = OffsetLearner()
        (0..<5).forEach { learner.add(anchor(Double($0), 3)) }
        [14.0, -9.0, 20.0, 12.0].enumerated().forEach { learner.add(anchor(10 + Double($0.offset), $0.element)) }
        XCTAssertEqual(learner.correction ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(learner.stepCount, 0)
    }

    func testAnAgreeingAnchorBetweenOutliersBreaksTheRun() {
        var learner = OffsetLearner()
        (0..<5).forEach { learner.add(anchor(Double($0), 3)) }
        learner.add(anchor(10, 8)); learner.add(anchor(11, 8.1))
        learner.add(anchor(12, 3.1))
        learner.add(anchor(13, 8.0))
        XCTAssertEqual(learner.stepCount, 0)
        XCTAssertEqual(learner.correction ?? -1, 3, accuracy: 0.2)
    }

    func testNonFiniteAnchorsAreIgnored() {
        var learner = OffsetLearner()
        learner.add(anchor(0, .nan)); learner.add(anchor(.infinity, 3))
        XCTAssertTrue(learner.anchors.isEmpty)
    }

    func testRoutesLearnIndependently() {
        var store = OffsetLearnerStore()
        (0..<3).forEach { store.add(anchor(Double($0), 3), route: "speaker") }
        (0..<3).forEach { store.add(anchor(Double($0), 6), route: "car") }
        XCTAssertEqual(store.correction(route: "speaker") ?? -1, 3, accuracy: 0.001)
        XCTAssertEqual(store.correction(route: "car") ?? -1, 6, accuracy: 0.001)
        XCTAssertNil(store.correction(route: "headphones"))
        store.reset()
        XCTAssertNil(store.correction(route: "speaker"))
    }

    // MARK: - Simulated worlds

    func testConstantOffsetConvergesInThreeAnchorsAndStaysAccurate() {
        let steps = SimulatedWorld(truth: { _ in 3 }, noise: 0.4).run(config: config, duration: twoHours)
        let m = RunMetrics(steps)
        XCTAssertEqual(m.anchorsToFirstCorrection, 3)
        XCTAssertLessThan(m.p95Error, 0.6)
        XCTAssertLessThan(m.worstError, 1.0)
        XCTAssertEqual(m.flipFlops, 0)
    }

    func testAStepInTheFeedLatencyIsFollowedWithoutOvershoot() {
        let world = SimulatedWorld(truth: { $0 < 1800 ? 3 : 8 }, noise: 0.4)
        let steps = world.run(config: config, duration: twoHours)
        let afterStep = steps.filter { $0.time > 1800 }
        // Within five anchors of the step the correction is within 1 s of the new truth, and it stays there.
        let settled = afterStep.drop { $0.time <= 1800 + 5 * 120 }
        XCTAssertTrue(settled.allSatisfy { abs(($0.correction ?? .infinity) - 8) < 1.0 })
        // Never beyond the two true values, plus noise.
        XCTAssertTrue(steps.allSatisfy { ($0.correction ?? 3) > 2 && ($0.correction ?? 3) < 9 })
        XCTAssertEqual(RunMetrics(steps).flipFlops, 0)
    }

    func testASlowDriftIsTracked() {
        let world = SimulatedWorld(truth: { 3 + 0.3 * $0 / 600 }, noise: 0.3)
        let steps = world.run(config: config, duration: twoHours)
        XCTAssertLessThan(RunMetrics(steps).p95Error, 0.8)
    }

    func testTwentyPercentBadMatchesAreIgnored() {
        let world = SimulatedWorld(truth: { _ in 3 }, noise: 0.4, outlierRate: 0.2, seed: 7)
        let steps = world.run(config: config, duration: twoHours)
        let m = RunMetrics(steps, from: 720)
        XCTAssertLessThan(m.p95Error, 1.0)
        XCTAssertLessThan(m.worstError, 2.0)
        XCTAssertEqual(m.flipFlops, 0)
    }

    func testNoisyAnchorsStillConvergeWithinOneSecond() {
        let steps = SimulatedWorld(truth: { _ in 3 }, noise: 1.0, seed: 3).run(config: config, duration: twoHours)
        XCTAssertLessThan(RunMetrics(steps, from: 720).p95Error, 1.5)
    }

    func testALongGapHoldsTheCorrectionAndThenReconverges() {
        let world = SimulatedWorld(truth: { $0 < 3000 ? 3 : 6 }, noise: 0.3, gaps: [1000...3500])
        let steps = world.run(config: config, duration: twoHours)
        let duringGap = steps.filter { $0.time >= 1100 && $0.time <= 3500 }
        XCTAssertTrue(duringGap.allSatisfy { $0.correction != nil }, "the last value is held, never nil")
        let reconverged = steps.filter { $0.time >= 3500 + 4 * 120 }
        XCTAssertTrue(reconverged.allSatisfy { abs(($0.correction ?? .infinity) - 6) < 1.0 })
    }

    func testAnAbnormalOffsetSaturatesAtTheClamp() {
        let steps = SimulatedWorld(truth: { _ in 25 }, noise: 0.3).run(config: config, duration: 1800)
        XCTAssertEqual(steps.last?.correction, 10)
    }

    func testAnEmptyWorldNeverReportsACorrection() {
        let world = SimulatedWorld(truth: { _ in 3 }, gaps: [0...10_000])
        XCTAssertTrue(world.run(config: config, duration: twoHours).allSatisfy { $0.correction == nil })
    }

    // MARK: - Parameter sweep (only when asked)

    /// `TEST_RUNNER_OFFSET_SWEEP=1 make test_staging ONLY_TESTING=PocketCastsTests/OffsetLearnerTests/testParameterSweep`
    func testParameterSweep() throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["OFFSET_SWEEP"] == "1", "sweep is opt-in")
        let worlds: [(String, SimulatedWorld)] = [
            ("constant", SimulatedWorld(truth: { _ in 3 }, noise: 0.5, seed: 11)),
            ("step", SimulatedWorld(truth: { $0 < 3600 ? 3 : 8 }, noise: 0.5, seed: 12)),
            ("outliers20", SimulatedWorld(truth: { _ in 3 }, noise: 0.5, outlierRate: 0.2, seed: 13)),
            ("noisy1.0", SimulatedWorld(truth: { _ in 3 }, noise: 1.0, seed: 14)),
            ("drift", SimulatedWorld(truth: { 3 + 0.3 * $0 / 600 }, noise: 0.5, seed: 15))
        ]
        print("SWEEP window minAnchors threshold stepRun | world: p95 worst flips")
        for window in [3, 5, 7, 9] {
            for threshold in [1.0, 1.5, 2.0, 3.0] {
                for stepRun in [2, 3, 4] {
                    var c = OffsetLearnerConfig()
                    c.window = window; c.outlierThreshold = threshold; c.stepRun = stepRun
                    let cells = worlds.map { name, world -> String in
                        let m = RunMetrics(world.run(config: c, duration: 4 * 3600), from: 720)
                        return String(format: "%@ %.2f %.2f %d", name, m.p95Error, m.worstError, m.flipFlops)
                    }
                    print("SWEEP \(window) \(c.minAnchors) \(threshold) \(stepRun) | " + cells.joined(separator: " | "))
                }
            }
        }
    }
}
