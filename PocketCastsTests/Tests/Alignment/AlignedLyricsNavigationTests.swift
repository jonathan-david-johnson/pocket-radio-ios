#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

/// The pure decisions behind station detail and full-screen lyrics sharing one clock in Apply.
final class AlignedLyricsNavigationTests: XCTestCase {
    private func entry(_ title: String, _ artist: String = "Artist", at: TimeInterval? = nil) -> TracklistEntry {
        TracklistEntry(title: title, artist: artist, album: nil, albumArtURL: nil,
                       playedAt: at.map { Date(timeIntervalSince1970: 1_700_000_000 + $0) })
    }

    // MARK: Which entry the lyrics load for

    func testApplyLoadsTheAlignedEntryNotTheFeedTop() {
        let aligned = entry("Aligned")
        let load = AlignedLyricsPolicy.lyricLoad(applying: true, aligned: aligned, occurrenceID: "occ-1",
                                                 feedTop: entry("Feed Top"))
        XCTAssertEqual(load, .aligned(aligned, occurrenceID: "occ-1"))
    }

    func testApplyWithoutAnAlignedSongOrOccurrenceLoadsNothing() {
        XCTAssertEqual(AlignedLyricsPolicy.lyricLoad(applying: true, aligned: nil, occurrenceID: "occ-1",
                                                     feedTop: entry("Feed Top")), .none)
        XCTAssertEqual(AlignedLyricsPolicy.lyricLoad(applying: true, aligned: entry("A"), occurrenceID: nil,
                                                     feedTop: entry("Feed Top")), .none)
    }

    func testOffLoadTheFeedTopOnTheWallClock() {
        let top = entry("Feed Top")
        XCTAssertEqual(AlignedLyricsPolicy.lyricLoad(applying: false, aligned: entry("A"), occurrenceID: "occ-1",
                                                     feedTop: top), .wallClock(top))
        XCTAssertEqual(AlignedLyricsPolicy.lyricLoad(applying: false, aligned: nil, occurrenceID: nil,
                                                     feedTop: nil), .wallClock(nil))
    }

    // MARK: Whether station detail stops its lyrics when it disappears

    func testApplyKeepsTheLyricsWhileFullScreenLyricsIsPushedOnTop() {
        XCTAssertFalse(AlignedLyricsPolicy.shouldStopOnDisappear(applying: true, lyricsScreenOpen: true,
                                                                 isMovingFromParent: false, isBeingDismissed: false))
    }

    func testApplyStopsWhenTheScreenIsReallyLeaving() {
        XCTAssertTrue(AlignedLyricsPolicy.shouldStopOnDisappear(applying: true, lyricsScreenOpen: true,
                                                                isMovingFromParent: true, isBeingDismissed: false))
        XCTAssertTrue(AlignedLyricsPolicy.shouldStopOnDisappear(applying: true, lyricsScreenOpen: true,
                                                                isMovingFromParent: false, isBeingDismissed: true))
    }

    func testApplyStopsWhenNoFullScreenLyricsIsOpen() {
        XCTAssertTrue(AlignedLyricsPolicy.shouldStopOnDisappear(applying: true, lyricsScreenOpen: false,
                                                                isMovingFromParent: false, isBeingDismissed: false))
    }

    func testOffAlwaysStopOnDisappear() {
        for open in [false, true] {
            for moving in [false, true] {
                XCTAssertTrue(AlignedLyricsPolicy.shouldStopOnDisappear(applying: false, lyricsScreenOpen: open,
                                                                        isMovingFromParent: moving, isBeingDismissed: false))
            }
        }
    }

    // MARK: Which row is the current song

    func testApplyCurrentSongIsTheMarkedRowNotRowZero() {
        let entries = [entry("Feed Top", at: 300), entry("Aligned", at: 200), entry("Older", at: 100)]
        let aligned = entry("Aligned", at: 200)
        func current(_ row: Int, wall: Bool = false) -> Bool {
            AlignedLyricsPolicy.isCurrentSong(applying: true, row: row, entries: entries, aligned: aligned, wallClockCurrent: wall)
        }
        XCTAssertFalse(current(0, wall: true), "the wall-clock answer is ignored in Apply")
        XCTAssertTrue(current(1))
        XCTAssertFalse(current(2))
    }

    func testApplyWithoutAnAlignedSongHasNoCurrentRow() {
        XCTAssertFalse(AlignedLyricsPolicy.isCurrentSong(applying: true, row: 0, entries: [entry("A")], aligned: nil,
                                                         wallClockCurrent: true))
    }

    func testOffKeepTheWallClockAnswer() {
        let entries = [entry("A"), entry("B")]
        XCTAssertTrue(AlignedLyricsPolicy.isCurrentSong(applying: false, row: 0, entries: entries, aligned: entry("B"),
                                                        wallClockCurrent: true))
        XCTAssertFalse(AlignedLyricsPolicy.isCurrentSong(applying: false, row: 1, entries: entries, aligned: entry("B"),
                                                         wallClockCurrent: false))
    }

    // MARK: Line and status at a position

    private let lines = [LyricLine(timestamp: 0, text: "L0"), LyricLine(timestamp: 5, text: "L1"), LyricLine(timestamp: 12, text: "L2")]

    func testLineStateUsesTheSharedLineIndex() {
        let state = AlignedLyricsPolicy.lineState(lines: lines, duration: 100, position: 6)
        XCTAssertEqual(state.index, 1)
        XCTAssertFalse(state.betweenTracks)
        XCTAssertEqual(AlignedLyricsPolicy.lineState(lines: lines, duration: 100, position: 5).index,
                       LyricLineIndex.index(in: lines, at: 5))
    }

    func testLineStateIntroWindowHasNoLineButIsNotBetweenTracks() {
        let late = [LyricLine(timestamp: 10, text: "A"), LyricLine(timestamp: 20, text: "B")]
        let inIntro = AlignedLyricsPolicy.lineState(lines: late, duration: 100, position: 8)
        XCTAssertNil(inIntro.index)
        XCTAssertFalse(inIntro.betweenTracks)
        XCTAssertTrue(AlignedLyricsPolicy.lineState(lines: late, duration: 100, position: 6.9).betweenTracks)
    }

    func testLineStateEndWindowUsesDurationThenLastLinePlusTwiceTheGrace() {
        XCTAssertFalse(AlignedLyricsPolicy.lineState(lines: lines, duration: 100, position: 112).betweenTracks)
        XCTAssertTrue(AlignedLyricsPolicy.lineState(lines: lines, duration: 100, position: 112.1).betweenTracks)
        XCTAssertFalse(AlignedLyricsPolicy.lineState(lines: lines, duration: nil, position: 36).betweenTracks)
        XCTAssertTrue(AlignedLyricsPolicy.lineState(lines: lines, duration: nil, position: 36.1).betweenTracks)
    }

    func testBetweenTracksHasNoHighlightedLine() {
        XCTAssertNil(AlignedLyricsPolicy.lineState(lines: lines, duration: 100, position: 500).index)
    }

    func testNoLinesIsBetweenTracksWithNoLine() {
        let state = AlignedLyricsPolicy.lineState(lines: [], duration: nil, position: 3)
        XCTAssertNil(state.index)
        XCTAssertTrue(state.betweenTracks)
    }
}
#endif
