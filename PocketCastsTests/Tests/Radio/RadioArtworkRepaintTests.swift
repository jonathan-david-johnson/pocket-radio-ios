import XCTest
@testable import podcasts

final class RadioArtworkRepaintTests: XCTestCase {
    private func entry(_ title: String, _ artist: String) -> TracklistEntry {
        TracklistEntry(title: title, artist: artist, album: nil, albumArtURL: nil, playedAt: nil)
    }

    func test_songKey_isNil_withoutAnEntry() {
        XCTAssertNil(RadioArtworkRepaint.songKey(stationId: "kcrw", entry: nil, occurrenceID: "o1"))
    }

    func test_songKey_ignoresCase() {
        let a = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Simetachin", "Cut Chemist"), occurrenceID: nil)
        let b = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("SIMETACHIN", "cut chemist"), occurrenceID: nil)
        XCTAssertEqual(a, b)
    }

    func test_songKey_differsByStation() {
        let a = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: nil)
        let b = RadioArtworkRepaint.songKey(stationId: "kexp", entry: entry("Song", "Artist"), occurrenceID: nil)
        XCTAssertNotEqual(a, b)
    }

    func test_songKey_differsByOccurrence_soARepeatedSongRepaints() {
        let a = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: "o1")
        let b = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: "o2")
        XCTAssertNotEqual(a, b)
    }

    func test_isPainted_whenTheSlotShowsThisSong_leavesItAlone() {
        let key = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: "o1")
        XCTAssertTrue(RadioArtworkRepaint.isPainted(key, displayed: key))
    }

    func test_isPainted_whenTheSlotShowsAnotherSongOrTheLogo_repaints() {
        let current = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: "o2")
        let earlier = RadioArtworkRepaint.songKey(stationId: "kcrw", entry: entry("Song", "Artist"), occurrenceID: "o1")
        XCTAssertFalse(RadioArtworkRepaint.isPainted(current, displayed: earlier))
        XCTAssertFalse(RadioArtworkRepaint.isPainted(current, displayed: nil))
    }

    func test_isPainted_withNoSongToResolve_repaints() {
        XCTAssertFalse(RadioArtworkRepaint.isPainted(nil, displayed: "anything"))
        XCTAssertFalse(RadioArtworkRepaint.isPainted(nil, displayed: nil))
    }
}
