import AVFoundation
import XCTest

@testable import podcasts

/// Probe log — the `[align]` line format. Lifecycle tests live in `RadioPlaybackSessionTests`.
final class AlignmentProbeLogTests: XCTestCase {
    private let generation = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!

    // MARK: - Line format

    func testLineWithAllValues() {
        let date = Date(timeIntervalSince1970: 1_700_000_000.25)
        let line = AlignmentProbeLog.line(generation: generation, elapsed: 12.04, media: 11.96, date: date,
                                          rate: 1.0, status: .playing)
        XCTAssertEqual(line, "[align] probe gen=ABCDEF12 t=12.0 media=12.0 date=2023-11-14T22:13:20.250Z rate=1.00 status=playing")
    }

    func testLineWithNilDateAndMedia() {
        let line = AlignmentProbeLog.line(generation: generation, elapsed: 1, media: nil, date: nil,
                                          rate: 0, status: .waitingToPlayAtSpecifiedRate)
        XCTAssertEqual(line, "[align] probe gen=ABCDEF12 t=1.0 media=nil date=nil rate=0.00 status=waiting")
    }

    func testNonFiniteMediaIsNilAndUnknownStatusIsQuestionMark() {
        let line = AlignmentProbeLog.line(generation: generation, elapsed: 2, media: .nan, date: nil,
                                          rate: 1, status: nil)
        XCTAssertEqual(line, "[align] probe gen=ABCDEF12 t=2.0 media=nil date=nil rate=1.00 status=?")
    }

    func testPausedStatus() {
        let line = AlignmentProbeLog.line(generation: generation, elapsed: 3, media: 0, date: nil,
                                          rate: 0, status: .paused)
        XCTAssertTrue(line.hasSuffix("status=paused"), line)
    }

    // MARK: - Endpoint

    func testSafeEndpointHasHostAndPathOnly() {
        let url = URL(string: "https://user:pw@streams.kcrw.com/e24_aac/playlist.m3u8?token=secret#frag")!
        let text = AlignmentProbeLog.safeEndpoint(url)
        XCTAssertEqual(text, "streams.kcrw.com/e24_aac/playlist.m3u8")
        XCTAssertFalse(text.contains("secret"))
        XCTAssertFalse(text.contains("pw"))
    }

    func testShortIDIsFirstEightCharacters() {
        XCTAssertEqual(AlignmentProbeLog.shortID(generation), "ABCDEF12")
    }
}
