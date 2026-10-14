#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

/// Full-screen lyrics in Apply reads station detail's clock: the same position, the same line and
/// the same skew, with no timer or `Date()` of its own. The loader and the clock are fakes.
@MainActor
final class LyricsViewControllerTests: XCTestCase {
    /// A stand-in for station detail's clock that the test moves by hand.
    private final class FakeClock {
        var position: TimeInterval?
        var skew: TimeInterval = 160
        private var subscribers: [Int: () -> Void] = [:]
        private var nextID = 0
        private(set) var adjustCalls = 0

        var subscriberCount: Int { subscribers.count }

        init(position: TimeInterval?) { self.position = position }

        func tick() { subscribers.values.forEach { $0() } }

        var clock: AlignedLyricsClock {
            AlignedLyricsClock(
                occurrenceID: "occ-1",
                position: { [unowned self] in self.position.map { $0 - (self.skew - 160) } },
                skew: { [unowned self] in self.skew },
                adjust: { [unowned self] delta in
                    self.adjustCalls += 1
                    self.skew -= delta   // a later song position is a smaller skew
                    return self.skew
                },
                subscribe: { [unowned self] handler in
                    let id = self.nextID
                    self.nextID += 1
                    self.subscribers[id] = handler
                    return { [weak self] in self?.subscribers[id] = nil }
                })
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

    // MARK: The shared skew

    func testNudgeMovesTheSharedSkewAndTheLabelShowsIt() async {
        let clock = FakeClock(position: 4.5)
        let vc = await makeScreen(clock: clock)
        XCTAssertEqual(vc._highlightedRowForTesting, 0)
        XCTAssertEqual(vc._offsetLabelForTesting, "Skew 160.0 s")

        vc._nudgeForTesting(0.5)

        XCTAssertEqual(clock.adjustCalls, 1)
        XCTAssertEqual(clock.skew, 159.5, "+ moves the song position forward, so the skew goes down")
        XCTAssertEqual(vc._offsetLabelForTesting, "Skew 159.5 s")
        XCTAssertEqual(vc._highlightedRowForTesting, 1, "the nudge moves the line at once")

        vc._nudgeForTesting(-1)
        XCTAssertEqual(vc._offsetLabelForTesting, "Skew 160.5 s")
        XCTAssertEqual(vc._highlightedRowForTesting, 0)
    }

    func testReturningToTheScreenKeepsPositionAndSkew() async {
        let clock = FakeClock(position: 4.5)
        clock.skew = 159
        let vc = await makeScreen(clock: clock)
        vc.viewDidAppear(false)
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertEqual(vc._offsetLabelForTesting, "Skew 159.0 s")

        vc.viewDidDisappear(false)
        XCTAssertEqual(clock.subscriberCount, 0, "closing the screen unsubscribes")

        vc.viewDidAppear(false)
        XCTAssertEqual(clock.subscriberCount, 1)
        XCTAssertEqual(vc._highlightedRowForTesting, 1)
        XCTAssertEqual(vc._offsetLabelForTesting, "Skew 159.0 s")
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

    // MARK: Off and rows that are not the current song

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

    func testWithoutAClockThereIsNothingToNudge() async {
        let vc = await makeScreen(clock: nil, isCurrentSong: true, offset: 4)
        XCTAssertTrue(vc._offsetControlsHiddenForTesting, "Off has no skew, so no + and −")
        vc._nudgeForTesting(0.5)
        XCTAssertNil(vc._offsetLabelForTesting.flatMap { $0.isEmpty ? nil : $0 })
    }
}
#endif
