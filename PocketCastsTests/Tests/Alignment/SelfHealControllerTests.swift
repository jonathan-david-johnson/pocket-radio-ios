import XCTest
@testable import podcasts

final class CorrectionGateTests: XCTestCase {
    func test_aSmallDifferenceIsIgnored() {
        XCTAssertNil(CorrectionGate.next(applied: 3.0, learned: 3.6))
        XCTAssertNil(CorrectionGate.next(applied: 0, learned: 0.9))
    }

    func test_aBigEnoughDifferenceMovesTheCorrection() {
        XCTAssertEqual(CorrectionGate.next(applied: 0, learned: 3.1), 3.1)
        XCTAssertEqual(CorrectionGate.next(applied: 3.0, learned: 4.0), 4.0)
        XCTAssertEqual(CorrectionGate.next(applied: 3.0, learned: 2.0), 2.0)
    }

    func test_nothingLearnedMeansNothingChanges() {
        XCTAssertNil(CorrectionGate.next(applied: 3, learned: nil))
        XCTAssertNil(CorrectionGate.next(applied: 3, learned: .nan))
    }
}

/// The self-healing controller against a scripted world: a fixed truth, a session, and a clock the test moves.
@MainActor
final class SelfHealControllerTests: XCTestCase {
    private final class Scripted: OffsetAnchorSource {
        var outcomes: [AnchorOutcome] = []
        var provide: (() -> AnchorOutcome)?
        var calls = 0
        func anchor() async -> AnchorOutcome {
            calls += 1
            if let provide { return provide() }
            return outcomes.isEmpty ? .noMatch : outcomes.removeFirst()
        }
        func cancel() {}
    }

    @MainActor
    private final class World {
        var mode: SelfHealMode = .apply
        var session: UUID? = UUID()
        var skew = 0.0
        var now: TimeInterval = 1000
        var lines: [String] = []
        /// The correction the app needs, in seconds, with the skew at zero.
        var needed = 3.0
        let correction = AlignmentCorrection()
    }

    private let timing = SelfHealController.Timing()

    private func make(_ world: World, source: Scripted, config: OffsetLearnerConfig = OffsetLearnerConfig()) -> (SelfHealController, ShazamAnchorProbe) {
        // The audio sits at 100 s. The app is `needed - applied - skew` short of it, so delta = needed - applied + skew... see below.
        source.provide = { [unowned world] in
            .matched(AnchorMatch(title: "Fine", artist: "The Cardigans", matchOffset: 96, predictedOffset: 100,
                                 confidence: 1, frequencySkew: 0))
        }
        let probe = ShazamAnchorProbe(
            source: source,
            moment: { [unowned world] in
                // songSeconds grows by the applied correction and shrinks by the skew; 100 - needed is the uncorrected, unskewed app.
                AlignedMoment(title: "Fine", artist: "The Cardigans", occurrenceID: "occ",
                              songSeconds: 100 - world.needed + world.correction.current - world.skew)
            },
            feedSkew: { [unowned world] in world.skew },
            correction: { [unowned world] in world.correction.current },
            route: { "Speaker" },
            uptime: { [unowned world] in world.now },
            emit: { [unowned world] in world.lines.append($0) },
            timeout: 5, learnerConfig: config)
        let controller = SelfHealController(
            probe: probe,
            mode: { [unowned world] in world.mode },
            session: { [unowned world] in world.session },
            skew: { [unowned world] in world.skew },
            correction: world.correction,
            now: { [unowned world] in world.now },
            emit: { [unowned world] in world.lines.append($0) },
            timing: timing)
        return (controller, probe)
    }

    /// Runs steps, moving the clock by each returned wait, until `count` anchors have been taken.
    private func run(_ controller: SelfHealController, _ world: World, source: Scripted, anchors count: Int, maxSteps: Int = 400) async {
        var steps = 0
        let start = source.calls
        while source.calls - start < count, steps < maxSteps {
            let wait = await controller.step()
            world.now += max(wait, 1)
            steps += 1
        }
    }

    func test_offDoesNothing() async {
        let world = World(); world.mode = .off
        let source = Scripted()
        let (controller, _) = make(world, source: source)
        let wait = await controller.step()
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(wait, timing.poll)
        XCTAssertEqual(controller.phase, "Off")
    }

    func test_withoutASessionItWaits() async {
        let world = World(); world.session = nil
        let source = Scripted()
        let (controller, _) = make(world, source: source)
        _ = await controller.step()
        XCTAssertEqual(source.calls, 0)
        XCTAssertTrue(controller.phase.contains("Waiting"))
    }

    func test_calibrationTakesThreeAnchorsInAFewSecondsEach_thenApplyMovesTheOffset() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)

        await run(controller, world, source: source, anchors: 3)

        XCTAssertEqual(source.calls, 3)
        XCTAssertLessThan(world.now - 1000, 60, "calibration is quick, not minutes")
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001, "Apply moved the offset")
        XCTAssertTrue(world.lines.contains { $0.contains("[selfheal] applied correction +3.0") })
    }

    func test_measureLearnsButNeverApplies() async {
        let world = World(); world.mode = .measure
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 4)
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 0)
        XCTAssertTrue(controller.phase.contains("not applied"))
    }

    func test_onceTheCorrectionIsAppliedTheLearnerKeepsTheSameTarget() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 8)
        // Anchors after the correction see a residual of zero, yet the learned total stays at 3 s.
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001)
    }

    func test_steadyAnchorsComeEveryThreeMinutesAfterCalibration() async {
        let world = World()
        let source = Scripted()
        let (controller, _) = make(world, source: source)
        await run(controller, world, source: source, anchors: 3)
        let calls = source.calls

        world.now += 60
        _ = await controller.step()
        XCTAssertEqual(source.calls, calls, "not due yet")
        world.now += 130
        _ = await controller.step()
        XCTAssertEqual(source.calls, calls + 1, "due after the steady interval")
    }

    func test_aNewSessionStartsAgainFromZero() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 4)
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001)

        world.session = UUID()
        world.needed = 6.0   // the new session's stream is 3 s further off
        _ = await controller.step()
        XCTAssertTrue(world.lines.contains { $0.contains("[selfheal] new session") })
        XCTAssertEqual(probe.learnerAnchorCount, 1, "the old session's anchors are gone")
        await run(controller, world, source: source, anchors: 3)
        XCTAssertEqual(probe.learnedCorrection ?? -1, 6.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 6.0, accuracy: 0.001)
    }

    func test_aSkewInjectedIntoTheAppIsLearnedAndUndone() async {
        let world = World()
        world.skew = 6   // the experiment's perturbation
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 4)
        XCTAssertEqual(probe.learnedCorrection ?? -1, 9.0, accuracy: 0.001, "3 s needed plus the 6 s injected")
        XCTAssertEqual(world.correction.current, 9.0, accuracy: 0.001)
    }

    func test_changingTheSkewMidSessionCalibratesAgainAndHoldsTheCorrection() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 4)
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001)

        world.skew = 4
        _ = await controller.step()
        XCTAssertTrue(world.lines.contains { $0.contains("skew changed to +4.0") })
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001, "held until the new value is learned")
        await run(controller, world, source: source, anchors: 3)
        XCTAssertEqual(probe.learnedCorrection ?? -1, 7.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 7.0, accuracy: 0.001)
    }

    func test_aWrongAnchorIsHeldBackAndTriggersAQuickRecheck() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 3)
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001)

        // One bad match, 50 s off.
        source.provide = { .matched(AnchorMatch(title: "Fine", artist: "The Cardigans", matchOffset: 50, predictedOffset: 150,
                                                confidence: 1, frequencySkew: 0)) }
        world.now += 200
        _ = await controller.step()
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001, "the outlier did not move it")
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001)

        // The recheck is due after the burst gap, not three minutes.
        source.provide = { .matched(AnchorMatch(title: "Fine", artist: "The Cardigans", matchOffset: 96, predictedOffset: 100,
                                                confidence: 1, frequencySkew: 0)) }
        let calls = source.calls
        world.now += timing.burstGap + 1
        _ = await controller.step()
        XCTAssertEqual(source.calls, calls + 1)
    }

    func test_aRealStepIsFollowedAfterThreeAgreeingAnchors() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        await run(controller, world, source: source, anchors: 5)
        XCTAssertEqual(world.correction.current, 3.0, accuracy: 0.001)

        world.needed = 8.0   // the feed's latency really moved
        let changedAt = world.now
        var steps = 0
        while abs(world.correction.current - 8.0) > 0.01, steps < 400 {
            let wait = await controller.step()
            world.now += max(wait, 1)
            steps += 1
        }
        XCTAssertEqual(probe.learnedCorrection ?? -1, 8.0, accuracy: 0.001)
        XCTAssertEqual(world.correction.current, 8.0, accuracy: 0.001)
        // The first wrong anchor waits for the steady interval; the two that confirm it come after the quick recheck gap.
        XCTAssertLessThan(world.now - changedAt, 600, "followed within minutes, not an hour")
    }

    func test_theExperimentConfigReachesFurtherThanARealOffsetNeeds() async {
        // A +10 s skew on a 3 s real need asks for 13 s. The default clamp stops at 10, the experiment's at 20.
        let world = World(); world.skew = 10
        let source = Scripted()
        let (clamped, _) = make(world, source: source)
        await run(clamped, world, source: source, anchors: 4)
        XCTAssertEqual(world.correction.current, 10.0, accuracy: 0.001)

        let world2 = World(); world2.skew = 10
        let source2 = Scripted()
        let (wide, _) = make(world2, source: source2, config: SelfHealController.experimentLearnerConfig)
        await run(wide, world2, source: source2, anchors: 4)
        XCTAssertEqual(world2.correction.current, 13.0, accuracy: 0.001)
    }

    func test_anAnchorReadAcrossASessionChangeIsDiscarded() async {
        let world = World()
        let source = Scripted()
        let (controller, probe) = make(world, source: source)
        let original = source.provide
        source.provide = {
            world.session = UUID()   // the station restarted while the mic listened
            return original?() ?? .noMatch
        }
        await run(controller, world, source: source, anchors: 1)
        XCTAssertEqual(world.correction.current, 0, "nothing is applied for a session that has ended")
        XCTAssertTrue(world.lines.contains { $0.contains("discarded an anchor") })
        XCTAssertEqual(probe.learnerAnchorCount, 1, "the measurement was taken, and the next step starts the new session fresh")

        source.provide = original
        _ = await controller.step()
        XCTAssertEqual(probe.learnerAnchorCount, 1, "reset by the new session, then one anchor")
    }

    func test_failedAnchorsBackOffAndNeverApply() async {
        let world = World()
        let source = Scripted()
        source.outcomes = []
        let (controller, _) = make(world, source: source)
        // No match each time. `make` installed a provider; replace it.
        source.provide = { .noMatch }
        var waits: [TimeInterval] = []
        for _ in 0..<6 {
            waits.append(await controller.step())
            world.now += 120
        }
        XCTAssertEqual(world.correction.current, 0)
        XCTAssertGreaterThan(waits.last ?? 0, waits.first ?? 0, "backs off")
        XCTAssertLessThanOrEqual(waits.max() ?? 0, timing.maxBackoff)
    }
}
