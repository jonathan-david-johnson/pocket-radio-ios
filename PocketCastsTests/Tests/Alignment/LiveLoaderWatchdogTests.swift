#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

final class LiveLoaderWatchdogTests: XCTestCase {
    /// Feeds one sample per second from `start` for `seconds`, with the loaded end given by `end(t)`.
    private func run(_ watchdog: inout LiveLoaderWatchdog, from start: TimeInterval, seconds: Int, playing: Bool = true,
                     end: (TimeInterval) -> Double?) -> [LiveLoaderWatchdog.Verdict] {
        (0..<seconds).map { step in
            let now = start + TimeInterval(step)
            return watchdog.sample(now: now, playing: playing, loadedEnd: end(now))
        }
    }

    func testAHealthyLiveWindowThatGrowsOneSegmentEverySixSecondsNeverCountsAsStopped() {
        var watchdog = LiveLoaderWatchdog()
        let verdicts = run(&watchdog, from: 0, seconds: 300) { 115 + 6 * floor($0 / 6) }
        XCTAssertTrue(verdicts.allSatisfy { $0 == .healthy })
    }

    func testALoadedEndThatStopsGrowingCountsAsStoppedAfterTheThreshold() {
        var watchdog = LiveLoaderWatchdog()
        let verdicts = run(&watchdog, from: 0, seconds: 40) { _ in 115 }
        let firstStopped = verdicts.firstIndex { $0 != .healthy }
        XCTAssertEqual(firstStopped, Int(LiveLoaderWatchdog.stallThreshold))
        XCTAssertEqual(verdicts.last, .stopped(for: 39))
    }

    func testGrowthBelowTheMinimumDoesNotRestartTheCount() {
        var watchdog = LiveLoaderWatchdog()
        let verdicts = run(&watchdog, from: 0, seconds: 25) { 115 + 0.01 * $0 }
        XCTAssertEqual(verdicts.last, .stopped(for: 24))
    }

    func testPausedSamplesNeverCountAndRestartTheCount() {
        var watchdog = LiveLoaderWatchdog()
        _ = run(&watchdog, from: 0, seconds: 15) { _ in 115 }
        let paused = run(&watchdog, from: 15, seconds: 60, playing: false) { _ in 115 }
        XCTAssertTrue(paused.allSatisfy { $0 == .healthy })
        let resumed = run(&watchdog, from: 75, seconds: 15) { _ in 115 }
        XCTAssertTrue(resumed.allSatisfy { $0 == .healthy }, "the count starts again when playback resumes")
    }

    func testAGapBetweenSamplesRestartsTheCount() {
        var watchdog = LiveLoaderWatchdog()
        _ = run(&watchdog, from: 0, seconds: 15) { _ in 115 }
        // A periodic time observer stops calling back while paused, so a long gap must not add to the count.
        let afterGap = run(&watchdog, from: 100, seconds: 15) { _ in 115 }
        XCTAssertTrue(afterGap.allSatisfy { $0 == .healthy })
    }

    func testNothingLoadedYetIsHealthy() {
        var watchdog = LiveLoaderWatchdog()
        let verdicts = run(&watchdog, from: 0, seconds: 40) { _ in nil }
        XCTAssertTrue(verdicts.allSatisfy { $0 == .healthy })
    }

    func testALoadedEndThatMovesBackRestartsTheCount() {
        var watchdog = LiveLoaderWatchdog()
        _ = run(&watchdog, from: 0, seconds: 15) { _ in 300 }
        let afterJump = run(&watchdog, from: 15, seconds: 15) { _ in 200 }
        XCTAssertTrue(afterJump.allSatisfy { $0 == .healthy })
    }

    func testResetStartsOver() {
        var watchdog = LiveLoaderWatchdog()
        _ = run(&watchdog, from: 0, seconds: 30) { _ in 115 }
        watchdog.reset()
        let verdicts = run(&watchdog, from: 30, seconds: 15) { _ in 115 }
        XCTAssertTrue(verdicts.allSatisfy { $0 == .healthy })
    }
}

final class KCRWReconnectBudgetTests: XCTestCase {
    func testAllowsTheFirstReplacement() {
        XCTAssertTrue(KCRWReconnectBudget().allows(now: 0))
    }

    func testRequiresTheMinimumIntervalBetweenReplacements() {
        var budget = KCRWReconnectBudget()
        budget.record(now: 100)
        XCTAssertFalse(budget.allows(now: 100 + KCRWReconnectBudget.minimumInterval - 1))
        XCTAssertTrue(budget.allows(now: 100 + KCRWReconnectBudget.minimumInterval))
    }

    func testStopsAtTheMaximumPerPlay() {
        var budget = KCRWReconnectBudget()
        for n in 0..<KCRWReconnectBudget.maximumPerPlay {
            budget.record(now: TimeInterval(n) * 1000)
        }
        XCTAssertEqual(budget.used, KCRWReconnectBudget.maximumPerPlay)
        XCTAssertFalse(budget.allows(now: 1_000_000))
    }
}

final class KCRWLoaderRecoveryTests: XCTestCase {
    private func makeRecovery(replaceResult: Bool = true) -> (KCRWLoaderRecovery, () -> Int, () -> [String]) {
        var calls = 0
        var lines: [String] = []
        let recovery = KCRWLoaderRecovery(emit: { lines.append($0) }, replace: {
            calls += 1
            return replaceResult
        })
        return (recovery, { calls }, { lines })
    }

    private func feed(_ recovery: KCRWLoaderRecovery, from start: TimeInterval, seconds: Int, end: Double = 115) {
        for step in 0..<seconds {
            recovery.sample(now: start + TimeInterval(step), playing: true, loadedEnd: end, bufferAhead: 100)
        }
    }

    func testAStoppedLoaderReplacesTheItemOnce() {
        let (recovery, calls, lines) = makeRecovery()
        feed(recovery, from: 0, seconds: 40)
        XCTAssertEqual(calls(), 1)
        XCTAssertTrue(lines().contains { $0.contains("[recovery] loader stopped") && $0.contains("replace n=1/3") })
    }

    func testAnotherStopWithinTheIntervalWaitsThenReplaces() {
        let (recovery, calls, lines) = makeRecovery()
        feed(recovery, from: 0, seconds: 21)
        XCTAssertEqual(calls(), 1)
        // The new item's loader stops too, before the minimum interval has passed.
        feed(recovery, from: 21, seconds: 30, end: 500)
        XCTAssertEqual(calls(), 1, "replacements are at least the minimum interval apart")
        XCTAssertEqual(lines().filter { $0.contains("waiting for the interval") }.count, 1, "logged once, not every sample")
        feed(recovery, from: 51, seconds: 35, end: 500)
        XCTAssertEqual(calls(), 2)
    }

    func testTheBudgetRunsOutAndSaysSoOnce() {
        let (recovery, calls, lines) = makeRecovery()
        for round in 0..<5 {
            feed(recovery, from: TimeInterval(round) * 100, seconds: 30, end: Double(round) * 1000)
        }
        XCTAssertEqual(calls(), KCRWReconnectBudget.maximumPerPlay)
        XCTAssertEqual(lines().filter { $0.contains("budget used") }.count, 2, "once for each later stop")
    }

    func testARefusedReplacementDoesNotSpendTheBudget() {
        let (recovery, calls, _) = makeRecovery(replaceResult: false)
        feed(recovery, from: 0, seconds: 40)
        XCTAssertEqual(calls(), 1, "a refusal is not retried on every sample")
        XCTAssertEqual(recovery.budget.used, 0)
    }

    func testInvalidatedRecoveryDoesNothing() {
        let (recovery, calls, _) = makeRecovery()
        recovery.invalidate()
        feed(recovery, from: 0, seconds: 40)
        XCTAssertEqual(calls(), 0)
    }
}
#endif
