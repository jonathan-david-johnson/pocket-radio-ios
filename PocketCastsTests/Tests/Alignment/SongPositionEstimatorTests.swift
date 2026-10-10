import XCTest

@testable import podcasts

/// Song seconds between player samples, for lyrics (ADR 0005). Pure value type; the clock is injected
/// and the wall clock is never read.
final class SongPositionEstimatorTests: XCTestCase {
    private final class Clock {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        func advance(_ seconds: TimeInterval) { date.addTimeInterval(seconds) }
    }

    private let clock = Clock()

    private func make() -> SongPositionEstimator {
        SongPositionEstimator(now: { [clock] in clock.date })
    }

    // MARK: - 1 Session position

    func testPositionAtTheSampleEqualsTheSessionsSongSeconds() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 42.5, playing: true)

        XCTAssertEqual(estimator.position(forOccurrence: "occ-a"), 42.5)
    }

    func testANewSampleReplacesTheAnchor() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 42.5, playing: true)
        clock.advance(1)
        estimator.record(occurrenceID: "occ-a", songSeconds: 40, playing: true)

        XCTAssertEqual(estimator.position(forOccurrence: "occ-a"), 40, "the player's sample wins over the extrapolation")
    }

    // MARK: - 2 Pause holds the line

    func testWhilePlayingThePositionIsTheAnchorPlusTheTimeSinceIt() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        clock.advance(3)

        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 13, accuracy: 0.0001)
    }

    func testPauseHoldsTheLineAndResumeContinuesFromWhereItWas() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        clock.advance(2)
        estimator.recordPlaying(false)
        clock.advance(20)

        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 12, accuracy: 0.0001, "frozen at the paused value")

        estimator.recordPlaying(true)
        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 12, accuracy: 0.0001, "the pause is not replayed")
        clock.advance(3)
        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 15, accuracy: 0.0001)
    }

    func testASampleTakenWhileNotPlayingDoesNotAdvance() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: false)
        clock.advance(30)

        XCTAssertEqual(estimator.position(forOccurrence: "occ-a"), 10)
    }

    func testRepeatedStatusReportsDoNotReanchorOrDoubleCount() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        clock.advance(2)
        estimator.recordPlaying(true)
        clock.advance(2)
        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 14, accuracy: 0.0001)

        estimator.recordPlaying(false)
        clock.advance(5)
        estimator.recordPlaying(false)
        clock.advance(5)
        XCTAssertEqual(estimator.position(forOccurrence: "occ-a") ?? -1, 14, accuracy: 0.0001)
    }

    func testAStatusChangeBeforeAnySampleDoesNothing() {
        var estimator = make()
        estimator.recordPlaying(true)
        clock.advance(5)
        XCTAssertNil(estimator.position(forOccurrence: "occ-a"))
    }

    // MARK: - 3 Clock fault hold

    private func at(_ estimator: SongPositionEstimator) -> Double? { estimator.position(forOccurrence: "occ-a") }

    func testAFaultKeepsExtrapolatingFromTheLastValidSampleWhilePlaying() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        clock.advance(2)
        estimator.recordFault(playing: true)
        clock.advance(2)

        XCTAssertEqual(at(estimator) ?? -1, 14, accuracy: 0.0001, "no re-anchor: still the last sample plus time")
    }

    func testAFaultDoesNotExpireOnItsOwn() {
        // The 5 s rule belongs to the publisher, which resets this estimator when it lets go.
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        estimator.recordFault(playing: true)
        clock.advance(60)

        XCTAssertEqual(at(estimator) ?? -1, 70, accuracy: 0.0001)
    }

    func testPauseDuringAFaultHoldsThePositionAndResumeContinues() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        estimator.recordFault(playing: true)
        clock.advance(3)
        estimator.recordPlaying(false)
        clock.advance(60)
        XCTAssertEqual(at(estimator) ?? -1, 13, accuracy: 0.0001, "held while paused, however long")

        estimator.recordPlaying(true)
        clock.advance(2)
        XCTAssertEqual(at(estimator) ?? -1, 15, accuracy: 0.0001)
    }

    func testAFaultTakenWhileNotPlayingDoesNotAdvance() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        clock.advance(1)
        estimator.recordFault(playing: false)
        clock.advance(30)
        XCTAssertEqual(at(estimator) ?? -1, 11, accuracy: 0.0001)
    }

    func testAValidSampleAfterTheFaultReanchorsAndEndsTheHold() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        estimator.recordFault(playing: true)
        clock.advance(4)
        estimator.record(occurrenceID: "occ-a", songSeconds: 8, playing: true)
        XCTAssertEqual(at(estimator) ?? -1, 8, accuracy: 0.0001, "the repaired clock's value")

        clock.advance(20)
        XCTAssertEqual(at(estimator) ?? -1, 28, accuracy: 0.0001)
    }

    // MARK: - 8 Unavailable is explicit

    func testNoSampleYetIsNil() {
        var estimator = make()
        XCTAssertNil(at(estimator))
        estimator.recordFault(playing: true)
        clock.advance(1)
        XCTAssertNil(at(estimator), "a fault before any sample has nothing to hold")
    }

    func testAnotherOccurrenceIsNil() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)

        XCTAssertNil(estimator.position(forOccurrence: "occ-b"))
        XCTAssertNil(estimator.position(forOccurrence: ""))
    }

    func testASampleForANewOccurrenceDropsTheOldOne() {
        var estimator = make()
        estimator.record(occurrenceID: "occ-a", songSeconds: 10, playing: true)
        estimator.record(occurrenceID: "occ-b", songSeconds: 1, playing: true)

        XCTAssertNil(estimator.position(forOccurrence: "occ-a"))
        XCTAssertEqual(estimator.position(forOccurrence: "occ-b"), 1)
    }
}
