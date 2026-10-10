#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

final class LyricLineIndexTests: XCTestCase {
    private func lines(_ stamps: [TimeInterval]) -> [LyricLine] {
        stamps.enumerated().map { LyricLine(timestamp: $1, text: "L\($0)") }
    }

    func testEmptyListHasNoIndex() {
        XCTAssertNil(LyricLineIndex.index(in: [], at: 10))
    }

    func testBeforeTheFirstLineHasNoIndex() {
        XCTAssertNil(LyricLineIndex.index(in: lines([5, 10]), at: 4.99))
        XCTAssertNil(LyricLineIndex.index(in: lines([0, 10]), at: -1))
    }

    func testAtAndAfterATimestampPicksThatLine() {
        let list = lines([0, 5, 12])
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 0), 0)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 4.9), 0)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 5), 1)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 11.99), 1)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 12), 2)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 9_999), 2)
    }

    func testEqualTimestampsPickTheLastOfThem() {
        let list = lines([0, 5, 5, 5, 9])
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 5), 3)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 8), 3)
        XCTAssertEqual(LyricLineIndex.index(in: list, at: 4.9), 0)
    }

    func testTheServiceUsesTheSameIndex() {
        let list = lines([0, 5, 5, 9])
        let result = LyricsResult(lines: list, plain: nil)
        for position in [-1.0, 0, 4.9, 5, 6, 9, 20] {
            let expected = LyricLineIndex.index(in: list, at: position).map { list[$0] }
            XCTAssertEqual(LyricsService.shared.currentLine(in: result, at: position)?.text, expected?.text)
        }
        XCTAssertEqual(LyricsService.shared.currentLine(in: result, at: 5)?.text, "L2")
    }
}
#endif
