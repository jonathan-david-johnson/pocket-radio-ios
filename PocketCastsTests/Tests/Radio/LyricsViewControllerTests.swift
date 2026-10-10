#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

/// Full-screen lyrics in Apply reads station detail's clock: the same position, the same line and
/// the same correction, with no timer or `Date()` of its own. The loader and the clock are fakes.
@MainActor
final class LyricsViewControllerTests: XCTestCase {
    /// A stand-in for station detail's clock that the test moves by hand.
    private final class FakeClock {
        var position: TimeInterval?
        var correction: TimeInterval = 0
        private var subscribers: [Int: () -> Void] = [:]
        private var nextID = 0
        private(set) var adjustCalls = 0

        var subscriberCount: Int { subscribers.count }

        init(position: TimeInterval?) { self.position = position }

        func tick() { subscribers.values.forEach { $0() } }

        var clock: AlignedLyricsClock {
            AlignedLyricsClock(
                occurrenceID: "occ-1",
                position: { [unowned self] in self.position.map { $0 + self.correction } },
                correction: { [unowned self] in self.correction },
                adjust: { [unowned self] delta in
                    self.adjustCalls += 1
                    self.correction += delta
                    return self.correction
                },
                subscribe: { [unowned self] handler in
                    let id = self.nextID
                    self.nextID += 1
                    self.subscribers[id] = handler
                    return { [weak self] in self?.subscribers[id] = nil }
                })
        }
    }

    private final class Delegate: LyricsViewControllerDelegate {
        var calls: [TimeInterval] = []
        var handler: (TimeInterval) -> TimeInterval = { _ in 0 }
        func lyricsViewController(_ viewController: LyricsViewController, adjustLyricOffsetBy delta: TimeInterval) -> TimeInterval {
            calls.append(delta)
            return handler(delta)
        }
    }

    private func lines(_ stamps: [TimeInterval] = [0, 5, 12]) -> LyricsResult {
        LyricsResult(lines: stamps.enumerated().map { LyricLine(timestamp: $1, text: "Line \($0)") }, plain: nil, duration: 100)
    }

    private func makeScreen(clock: FakeClock?, result: LyricsResult? = nil, isCurrentSong: Bool = true,
                            offset: TimeInterval = 0) async -> LyricsViewController {
        let entry = TracklistEntry(title: "Song", artist: "Artist", album: nil, albumArtURL: nil, playedAt: nil)
        let vc = LyricsViewController(entry: entry, stationName: "KCRW", offset: offset, isCurrentSong: isCurrentSong)
        let result = result ?? lines()
        vc.lyricLoader = { _, _, _ in result }
        vc.alignedClock = clock?.clock
        vc.loadViewIfNeeded()
        for _ in 0..<200 where !vc._hasLyricRowsForTesting {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return vc
    }

    // MARK: Same position, same line

    func testAlignedScreenHighlightsTheLineForTheSharedPosition() async {
        let clock = FakeClock(position: 6)
        let vc = await makeScreen(clock: clock, offset: 99)   // the old initial offset is ignored
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertEqual(vc._highlightedRowForTesting, LyricLineIndex.index(in: lines().lines, at: 6))
    }

    func testAlignedScreenPicksTheLastOfEqualTimestamps() async {
        let vc = await makeScreen(clock: FakeClock(position: 5), result: lines([0, 5, 5, 9]))
        XCTAssertEqual(vc._highlightedRowForTesting, 2)
    }

    func testAlignedScreenFollowsTheSharedTickWithoutATimerOfItsOwn() async {
        let clock = FakeClock(position: 1)
        let vc = await makeScreen(clock: clock)
        vc.viewDidAppear(false)

        XCTAssertEqual(clock.subscriberCount, 1)
        XCTAssertFalse(vc._hasOwnTimerForTesting, "no second timer")
        XCTAssertEqual(vc._highlightedRowForTesting, 0)

        clock.position = 13
        clock.tick()
        XCTAssertEqual(vc._highlightedRowForTesting, 2)
    }

    func testAlignedScreenWithNoPositionShowsNoHighlightAndTheStationName() async {
        let clock = FakeClock(position: nil)
        let vc = await makeScreen(clock: clock)
        vc.viewDidAppear(false)

        XCTAssertNil(vc._highlightedRowForTesting)
        XCTAssertEqual(vc._statusForTesting.text, "\u{266A} KCRW")
        XCTAssertFalse(vc._statusForTesting.hidden)

        clock.position = 6
        clock.tick()
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertTrue(vc._statusForTesting.hidden)

        clock.position = nil
        clock.tick()
        XCTAssertNil(vc._highlightedRowForTesting, "a lost clock clears the highlight; there is no wall-clock fallback")
    }

    func testAlignedScreenBetweenTracksHasNoHighlight() async {
        let clock = FakeClock(position: 500)
        let vc = await makeScreen(clock: clock)
        XCTAssertNil(vc._highlightedRowForTesting)
        XCTAssertFalse(vc._statusForTesting.hidden)
    }

    // MARK: The shared correction

    func testNudgeAdjustsTheSharedCorrectionAndTheLabelShowsIt() async {
        let clock = FakeClock(position: 4.5)
        let vc = await makeScreen(clock: clock)
        let delegate = Delegate()
        delegate.handler = { clock.clock.adjust($0) }
        vc.delegate = delegate
        XCTAssertEqual(vc._highlightedRowForTesting, 0)
        XCTAssertEqual(vc._offsetLabelForTesting, "+0s")

        vc._nudgeForTesting(1)

        XCTAssertEqual(delegate.calls, [1])
        XCTAssertEqual(clock.correction, 1)
        XCTAssertEqual(vc._offsetLabelForTesting, "+1s")
        XCTAssertEqual(vc._highlightedRowForTesting, 1, "the nudge moves the line at once")

        vc._nudgeForTesting(-2)
        XCTAssertEqual(vc._offsetLabelForTesting, "-1s")
        XCTAssertEqual(vc._highlightedRowForTesting, 0)
    }

    func testReturningToTheScreenKeepsPositionAndCorrection() async {
        let clock = FakeClock(position: 4.5)
        clock.correction = 1
        let vc = await makeScreen(clock: clock)
        vc.viewDidAppear(false)
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertEqual(vc._offsetLabelForTesting, "+1s")

        vc.viewDidDisappear(false)
        XCTAssertEqual(clock.subscriberCount, 0, "closing the screen unsubscribes")

        vc.viewDidAppear(false)
        XCTAssertEqual(clock.subscriberCount, 1)
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertEqual(vc._offsetLabelForTesting, "+1s")
        XCTAssertEqual(clock.adjustCalls, 0)
    }

    func testAppearingAgainShowsTheLineForTheNewPosition() async {
        let clock = FakeClock(position: 1)
        let vc = await makeScreen(clock: clock)
        vc.viewDidAppear(false)
        vc.viewDidDisappear(false)
        clock.position = 13
        vc.viewDidAppear(false)
        XCTAssertEqual(vc._highlightedRowForTesting, 2)
    }

    // MARK: Off, Observe and rows that are not the current song

    func testWithoutAClockTheCurrentSongKeepsItsOwnTimer() async {
        let vc = await makeScreen(clock: nil, isCurrentSong: true, offset: 6)
        XCTAssertEqual(vc._highlightedRowForTesting, 1, "initialOffset still sets the starting line")
        vc.viewDidAppear(false)
        XCTAssertTrue(vc._hasOwnTimerForTesting)
        vc.viewDidDisappear(false)
        XCTAssertFalse(vc._hasOwnTimerForTesting)
    }

    func testAHistoryRowHasNoTimerAndNoClock() async {
        let clock = FakeClock(position: 6)
        let vc = await makeScreen(clock: clock, isCurrentSong: false)
        vc.viewDidAppear(false)
        XCTAssertFalse(vc._hasOwnTimerForTesting)
        XCTAssertEqual(clock.subscriberCount, 0, "a history row never subscribes to the clock")
        XCTAssertTrue(vc._offsetControlsHiddenForTesting)
    }

    func testWithoutAClockTheNudgeKeepsTheLocalCopy() async {
        let vc = await makeScreen(clock: nil, isCurrentSong: true, offset: 4)
        vc._nudgeForTesting(2)
        XCTAssertEqual(vc._offsetLabelForTesting, "+2s")
    }
}
#endif
