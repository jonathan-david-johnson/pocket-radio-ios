import XCTest

@testable import podcasts

/// The pure monitor summary and the locked-run verdict.
final class AlignmentMonitorSummaryTests: XCTestCase {
    private let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    private func sample(_ t: TimeInterval, media: TimeInterval? = nil, clock: Bool = true,
                        rate: Float = 1, playing: Bool = true) -> AlignmentMonitorSample {
        AlignmentMonitorSample(elapsed: t, mediaSeconds: media ?? t, programDate: clock ? epoch.addingTimeInterval(t) : nil,
                               rate: rate, isPlaying: playing)
    }

    private func compute(_ s: [AlignmentMonitorSample] = [], _ p: [AlignmentMonitorPoll] = [], end: TimeInterval = 0) -> AlignmentMonitorSummary {
        AlignmentMonitorSummary.compute(samples: s, polls: p, endElapsed: end)
    }

    func testEmptyInput() {
        let s = compute()
        XCTAssertEqual(s.sampleCount, 0)
        XCTAssertEqual(s.pollAttempts, 0)
        XCTAssertNil(s.firstValidClockElapsed)
        XCTAssertEqual(s.longestSampleGap, 0)
        XCTAssertEqual(s.tailSampleGap, 0)
        XCTAssertTrue(s.clockInvalidIntervals.isEmpty)
        XCTAssertNil(s.minRate)
        XCTAssertTrue(s.speedWindows.isEmpty)
    }

    func testOneSample() {
        let s = compute([sample(2)], end: 2)
        XCTAssertEqual(s.sampleCount, 1)
        XCTAssertEqual(s.longestSampleGap, 0)
        XCTAssertEqual(s.tailSampleGap, 0)
        XCTAssertEqual(s.firstValidClockElapsed, 0)
        XCTAssertEqual(s.minRate, 1)
    }

    func testGapsAndTailGaps() {
        let samples = [sample(0), sample(1), sample(2), sample(9), sample(10)]
        let polls = [AlignmentMonitorPoll(elapsed: 0, succeeded: true), AlignmentMonitorPoll(elapsed: 30, succeeded: true)]
        let s = compute(samples, polls, end: 70)
        XCTAssertEqual(s.longestSampleGap, 7)
        XCTAssertEqual(s.tailSampleGap, 60)
        XCTAssertEqual(s.longestPollAttemptGap, 30)
        XCTAssertEqual(s.tailPollGap, 40)
    }

    func testPollAttemptsIncludeFailuresAndFailuresCountedSeparately() {
        let polls = [true, false, true, false, false].enumerated().map { AlignmentMonitorPoll(elapsed: Double($0.offset) * 30, succeeded: $0.element) }
        let s = compute([], polls, end: 120)
        XCTAssertEqual(s.pollAttempts, 5)
        XCTAssertEqual(s.pollFailures, 3)
    }

    func testFirstValidClockDelay() {
        let samples = [sample(5, clock: false), sample(6, clock: false), sample(9), sample(10)]
        XCTAssertEqual(compute(samples, end: 10).firstValidClockElapsed, 4)
    }

    func testFirstValidClockIgnoresNonPlayingSamples() {
        let samples = [sample(0, playing: false), sample(1, clock: false, playing: true), sample(3)]
        XCTAssertEqual(compute(samples, end: 3).firstValidClockElapsed, 3)
    }

    func testNoValidClockIsNil() {
        XCTAssertNil(compute([sample(0, clock: false), sample(1, clock: false)], end: 1).firstValidClockElapsed)
    }

    // MARK: - Clock-invalid intervals

    func testClockInvalidRunWhilePlaying() {
        let samples = [sample(0), sample(1, clock: false), sample(2, clock: false), sample(3), sample(4, clock: false)]
        XCTAssertEqual(compute(samples, end: 4).clockInvalidIntervals, [1 ... 2, 4 ... 4])
    }

    func testNoClockInvalidIntervalWhilePaused() {
        let samples = [sample(0), sample(1, clock: false, playing: false), sample(2, clock: false, playing: false), sample(3)]
        XCTAssertTrue(compute(samples, end: 3).clockInvalidIntervals.isEmpty)
    }

    // MARK: - Rate

    func testRateMinMaxOnlyOverPlayingSamples() {
        let samples = [sample(0, rate: 1), sample(1, rate: 0, playing: false), sample(2, rate: 1.5), sample(3, rate: 0.9)]
        let s = compute(samples, end: 3)
        XCTAssertEqual(s.minRate, 0.9)
        XCTAssertEqual(s.maxRate, 1.5)
    }

    // MARK: - Speed windows

    func testSpeedWindowsExcludeStallPairs() {
        // Media stalls at 10...14 (not playing, media frozen), then resumes. Playing pairs advance 1:1.
        var samples: [AlignmentMonitorSample] = []
        for t in 0 ..< 10 { samples.append(sample(Double(t), media: Double(t))) }
        for t in 10 ..< 15 { samples.append(sample(Double(t), media: 10, playing: false)) }
        for t in 15 ..< 30 { samples.append(sample(Double(t), media: Double(t - 5))) }
        let w = compute(samples, end: 30).speedWindows
        XCTAssertEqual(w.count, 1)
        XCTAssertEqual(w[0].start, 0)
        XCTAssertEqual(w[0].elapsedSeconds, 9 + 14)
        XCTAssertEqual(w[0].mediaSeconds, 9 + 14)
        XCTAssertEqual(w[0].ratio ?? 0, 1.0, accuracy: 1e-9)
    }

    func testSpeedWindowsAcrossTwoWindows() {
        let samples = (0 ..< 600).map { sample(Double($0)) }
        let w = compute(samples, end: 600).speedWindows
        XCTAssertEqual(w.map(\.start), [0, 300])
        XCTAssertEqual(w.map(\.elapsedSeconds), [299, 299])
    }

    func testSpeedWindowWithNoContributionHasNilRatio() {
        let w = compute([sample(0), sample(1, playing: false)], end: 1).speedWindows
        XCTAssertTrue(w.isEmpty || w[0].ratio == nil)
    }

    func testSpeedWindowIgnoresNonFiniteMedia() {
        let samples = [sample(0), AlignmentMonitorSample(elapsed: 1, mediaSeconds: nil, programDate: nil, rate: 1, isPlaying: true), sample(2)]
        let w = compute(samples, end: 2).speedWindows
        XCTAssertTrue(w.isEmpty || w[0].elapsedSeconds == 0)
    }

    func testDriftingRatioIsReported() {
        let samples = (0 ..< 300).map { sample(Double($0), media: Double($0) * 1.05) }
        let w = compute(samples, end: 300).speedWindows
        XCTAssertEqual(w[0].ratio ?? 0, 1.05, accuracy: 1e-9)
    }

    // MARK: - Locked-run verdict

    private func cleanRun(dropSamples: Range<Int> = 0 ..< 0, dropPolls: Set<Int> = [], rate: (Int) -> Float = { _ in 1 },
                          clockLost: Range<Int> = 0 ..< 0, upTo seconds: Int = 1800, end: TimeInterval = 1800) -> AlignmentMonitorSummary {
        let samples = (0 ..< seconds).filter { !dropSamples.contains($0) }.map {
            sample(Double($0), clock: !clockLost.contains($0), rate: rate($0))
        }
        let polls = (0 ..< 60).filter { !dropPolls.contains($0) && $0 * 30 <= seconds }.map {
            AlignmentMonitorPoll(elapsed: Double($0) * 30, succeeded: $0 % 7 != 3)
        }
        return compute(samples, polls, end: end)
    }

    private func verdict(_ s: AlignmentMonitorSummary, alive: Bool = true, stalls: [ClosedRange<TimeInterval>] = []) -> LockedRunVerdict {
        s.evaluateLockedRun(sessionAliveAtEnd: alive, audioNeverStopped: true, loggedStallIntervals: stalls)
    }

    func testCleanThirtyMinuteRunPasses() {
        let v = verdict(cleanRun())
        XCTAssertEqual(v.failures, [])
        XCTAssertTrue(v.passed)
    }

    func testSampleGapFails() {
        let v = verdict(cleanRun(dropSamples: 100 ..< 119))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.failures, ["longest sample gap 20.0 s exceeds 5.0 s"])
    }

    func testPollGapFails() {
        let v = verdict(cleanRun(dropPolls: [10, 11]))
        XCTAssertEqual(v.failures, ["longest poll attempt gap 90.0 s exceeds 45.0 s"])
    }

    func testTooFewAttemptsFails() {
        let v = verdict(cleanRun(dropPolls: [59, 58, 57]))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains("poll attempts 57 below 58"), "\(v.failures)")
    }

    func testFailedAttemptsDoNotFailTheRun() {
        let s = cleanRun()
        XCTAssertGreaterThan(s.pollFailures, 0)
        XCTAssertTrue(verdict(s).passed)
    }

    func testSilentStopFailsOnTailGaps() {
        let v = verdict(cleanRun(upTo: 600))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.contains("tail sample gap 1201.0 s exceeds 5.0 s"), "\(v.failures)")
        XCTAssertTrue(v.failures.contains { $0.hasPrefix("tail poll gap") }, "\(v.failures)")
    }

    func testUnexplainedClockInvalidRunFails() {
        let v = verdict(cleanRun(clockLost: 500 ..< 510))
        XCTAssertEqual(v.failures, ["clock invalid 500.0-509.0 s not explained by a logged stall"])
    }

    // Changed expectation: old rule excused runs contained in a stall; such runs cannot exist (stalls are non-playing time).
    // New rule: run starts within the resync grace after a stall ends and is itself short.
    func testExcusedClockInvalidRunPasses() {
        let v = verdict(cleanRun(clockLost: 500 ..< 503), stalls: [490 ... 498])
        XCTAssertTrue(v.passed, "\(v.failures)")
    }

    // MARK: - Sample gap and clock resync rules

    private func startupRun() -> AlignmentMonitorSummary {
        var samples = [sample(0.1, clock: false, playing: false)]
        samples += stride(from: 6.5, through: 1800, by: 1).map { sample($0) }
        let polls = (0 ..< 60).map { AlignmentMonitorPoll(elapsed: Double($0) * 30, succeeded: true) }
        return compute(samples, polls, end: 1800.5)
    }

    func testA_StartupGapBeforeFirstPlayingSampleIsIgnored() {
        let s = startupRun()
        XCTAssertEqual(s.longestSampleGap, 1.0, accuracy: 1e-9)
        XCTAssertEqual(s.sampleCount, 1795)
        let v = verdict(s)
        XCTAssertTrue(v.passed, "\(v.failures)")
    }

    func testB_GapBetweenPlayingSamplesWithoutStallFails() {
        let v = verdict(cleanRun(dropSamples: 101 ..< 120))
        XCTAssertFalse(v.passed)
        XCTAssertEqual(v.failures, ["longest sample gap 20.0 s exceeds 5.0 s"])
    }

    func testC_GapCoveredByLoggedStallPasses() {
        let v = verdict(cleanRun(dropSamples: 101 ..< 120), stalls: [100 ... 120])
        XCTAssertTrue(v.passed, "\(v.failures)")
    }

    func testC2_GapCoveredWithinToleranceOfStallPasses() {
        let v = verdict(cleanRun(dropSamples: 101 ..< 120), stalls: [101 ... 119])
        XCTAssertTrue(v.passed, "\(v.failures)")
    }

    func testD_ClockInvalidRunSoonAfterStallPasses() {
        let v = verdict(cleanRun(clockLost: 111 ..< 114), stalls: [100 ... 110])
        XCTAssertTrue(v.passed, "\(v.failures)")
    }

    func testE_ClockInvalidRunTooLongAfterStallFails() {
        let v = verdict(cleanRun(clockLost: 118 ..< 120), stalls: [100 ... 110])
        XCTAssertEqual(v.failures, ["clock invalid 118.0-119.0 s not explained by a logged stall"])
    }

    func testF_LongClockInvalidRunAfterStallFails() {
        let v = verdict(cleanRun(clockLost: 111 ..< 119), stalls: [100 ... 110])
        XCTAssertEqual(v.failures, ["clock invalid 111.0-118.0 s not explained by a logged stall"])
    }

    func testG_ClockInvalidRunWithoutStallFails() {
        let v = verdict(cleanRun(clockLost: 111 ..< 114))
        XCTAssertFalse(v.passed)
    }

    func testPartiallyCoveredClockInvalidRunFails() {
        let v = verdict(cleanRun(clockLost: 500 ..< 510), stalls: [498 ... 505])
        XCTAssertFalse(v.passed)
    }

    func testRateOffOneFails() {
        let v = verdict(cleanRun(rate: { $0 == 700 ? 1.5 : 1 }))
        XCTAssertEqual(v.failures, ["rate range 1.00-1.50 is not exactly 1.0"])
    }

    func testSessionNotAliveFails() {
        let v = verdict(cleanRun(), alive: false)
        XCTAssertEqual(v.failures, ["session not alive at end"])
    }

    func testAudioStoppedFails() {
        let v = cleanRun().evaluateLockedRun(sessionAliveAtEnd: true, audioNeverStopped: false)
        XCTAssertEqual(v.failures, ["audio stopped during the run"])
    }

    func testDriftingSpeedWindowFailsVerdict() {
        let samples = (0 ..< 1800).map { sample(Double($0), media: Double($0) * 1.05) }
        let polls = (0 ..< 60).map { AlignmentMonitorPoll(elapsed: Double($0) * 30, succeeded: true) }
        let v = verdict(compute(samples, polls, end: 1800))
        XCTAssertFalse(v.passed)
        XCTAssertTrue(v.failures.first?.hasPrefix("speed window at 0 s ratio 1.050") == true, "\(v.failures)")
    }

    func testShortSpeedWindowIsNotJudged() {
        // 20 contributed seconds of drift: below the 60 s judging threshold.
        let samples = (0 ..< 21).map { sample(Double($0), media: Double($0) * 1.05) }
        let polls = (0 ..< 60).map { AlignmentMonitorPoll(elapsed: Double($0) * 30, succeeded: true) }
        XCTAssertTrue(verdict(compute(samples, polls, end: 20)).failures.allSatisfy { !$0.hasPrefix("speed window") })
    }

    func testFormattedLinesArePlainAndPrefixed() {
        let lines = cleanRun().formattedLines()
        XCTAssertFalse(lines.isEmpty)
        XCTAssertTrue(lines.allSatisfy { $0.hasPrefix("[align] summary ") && !$0.contains("http") })
        XCTAssertTrue(lines[0].contains("samples=1800"), lines[0])
        XCTAssertTrue(lines[0].contains("polls=60"), lines[0])
    }

    // A pair of playing samples that straddles a stall without ticks must not count toward speed.
    func testSpeedWindowSkipsPairsSpanningAMissingTickGap() {
        var samples = (0...100).map { sample(Double($0)) }
        // AVPlayer fired no tick for 10 s; media advanced only 1 s across the gap.
        samples += (110...200).map { sample(Double($0), media: Double($0) - 9) }
        let windows = compute(samples, end: 200).speedWindows

        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows.first?.ratio ?? 0, 1.0, accuracy: 0.0001)
        XCTAssertEqual(windows.first?.elapsedSeconds ?? 0, 190, accuracy: 0.0001)
    }
}
