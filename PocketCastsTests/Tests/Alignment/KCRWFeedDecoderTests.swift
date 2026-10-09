#if !os(watchOS) && !APPCLIP && !os(tvOS)
import StreamSession
import XCTest

@testable import podcasts

final class KCRWFeedDecoderTests: XCTestCase {
    private let sample = """
    [
      {"id": 1001, "title": "Song A", "artist": "Artist A", "album": "Album A",
       "albumImageLarge": "", "albumImage": "https://img.example/a.jpg?token=secret#frag",
       "datetime": "2026-01-02T03:04:05.123456Z"},
      {"id": "abc-2", "title": " Song B\\u0007 ", "artist": "Artist B", "thumbnail_uri": "https://img.example/b.jpg",
       "datetime": "2026-01-02T03:04:10Z"},
      {"id": 3, "title": "[BREAK]", "artist": "", "datetime": "2026-01-02T03:05:00Z"},
      {"id": 4, "title": "Talk", "artist": "host [break]", "datetime": "2026-01-02T03:06:00Z"},
      {"id": 5, "title": null, "artist": "Artist C", "datetime": "2026-01-02T03:07:00Z"},
      {"id": 6, "title": "Song D", "artist": "   ", "datetime": "bogus"}
    ]
    """

    private func decode(_ string: String) throws -> [OccurrenceInput] {
        try KCRWFeedDecoder.decode(Data(string.utf8))
    }

    func testDecodesOrderedRowsWithoutDropping() throws {
        let rows = try decode(sample)
        XCTAssertEqual(rows.map(\.providerID), ["1001", "abc-2", "3", "4", "5", "6"])
        XCTAssertEqual(rows.map(\.kind), ["trackplay", "trackplay", "break", "break", "unknown", "unknown"])
        XCTAssertTrue(rows.allSatisfy { $0.station == "kcrw" })
    }

    func testTimestampsAreMillisecondSnapped() throws {
        let rows = try decode(sample)
        let base = ISO8601DateFormatter().date(from: "2026-01-02T03:04:05Z")!.timeIntervalSince1970
        XCTAssertEqual(rows[0].playedAt!.timeIntervalSince1970, base + 0.123, accuracy: 0.0001)
        XCTAssertEqual(rows[1].playedAt!.timeIntervalSince1970, base + 5, accuracy: 0.0001)
        XCTAssertNil(rows[5].playedAt)
    }

    func testTextAndArtworkCleaning() throws {
        let rows = try decode(sample)
        XCTAssertEqual(rows[0].artworkURL, "https://img.example/a.jpg")
        XCTAssertEqual(rows[1].artworkURL, "https://img.example/b.jpg")
        XCTAssertEqual(rows[1].title, "Song B")
        XCTAssertNil(rows[4].title)
        XCTAssertEqual(rows[5].artist, "")
        XCTAssertNil(rows[2].artworkURL)
    }

    func testTextIsCappedAt256() throws {
        let long = String(repeating: "x", count: 400)
        let rows = try decode("[{\"id\":1,\"title\":\"\(long)\",\"artist\":\"a\"}]")
        XCTAssertEqual(rows[0].title?.count, 256)
    }

    func testWrongShapeThrows() {
        XCTAssertThrowsError(try decode("{\"rows\": []}")) { XCTAssertEqual($0 as? KCRWFeedError, .badShape) }
        XCTAssertThrowsError(try decode("[1, 2]")) { XCTAssertEqual($0 as? KCRWFeedError, .badShape) }
    }

    func testBadValueTypesThrow() {
        XCTAssertThrowsError(try decode("[{\"id\":1,\"title\":5}]")) { XCTAssertEqual($0 as? KCRWFeedError, .badShape) }
        XCTAssertThrowsError(try decode("[{\"id\":[1],\"title\":\"a\"}]")) { XCTAssertEqual($0 as? KCRWFeedError, .badShape) }
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try decode("not json")) { XCTAssertEqual($0 as? KCRWFeedError, .badShape) }
    }
}
#endif
