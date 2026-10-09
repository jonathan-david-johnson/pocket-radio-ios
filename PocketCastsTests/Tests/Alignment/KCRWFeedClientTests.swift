#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest

@testable import podcasts

final class KCRWFeedClientTests: XCTestCase {
    private struct Boom: Error, CustomStringConvertible {
        var description: String { "https://tracklist-api.kcrw.com/secret failed" }
    }

    private func response(_ code: Int, headers: [String: String] = [:]) -> URLResponse {
        HTTPURLResponse(url: KCRWFeedClient.feedURL, statusCode: code, httpVersion: nil, headerFields: headers)!
    }

    private func rows(_ count: Int) -> Data {
        let body = (0..<count).map { "{\"id\":\($0),\"title\":\"t\",\"artist\":\"a\"}" }.joined(separator: ",")
        return Data("[\(body)]".utf8)
    }

    private func fetch(_ data: Data, _ response: URLResponse) async -> KCRWFeedResult {
        await KCRWFeedClient(fetchData: { _ in (data, response) }).fetch()
    }

    private func assertNoURL(_ result: KCRWFeedResult, file: StaticString = #filePath, line: UInt = #line) {
        let text = result.failure ?? ""
        XCTAssertFalse(text.contains("http") || text.contains("kcrw") || text.contains("secret"), file: file, line: line)
    }

    func testSuccessParsesEntriesAndAge() async {
        let result = await fetch(rows(3), response(200, headers: ["Age": "42"]))
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.entries.count, 3)
        XCTAssertEqual(result.statusCode, 200)
        XCTAssertEqual(result.cacheAgeSeconds, 42)
    }

    func testInvalidAgeIsIgnored() async {
        for age in ["-1", "inf", "nan", "abc"] {
            let result = await fetch(rows(1), response(200, headers: ["Age": age]))
            XCTAssertNil(result.cacheAgeSeconds, age)
        }
    }

    func testServerErrorFailure() async {
        let result = await fetch(Data(), response(500))
        XCTAssertEqual(result.failure, "HTTP 500")
        XCTAssertEqual(result.statusCode, 500)
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testNonHTTPResponseFailure() async {
        let result = await fetch(Data(), URLResponse(url: KCRWFeedClient.feedURL, mimeType: nil,
                                                      expectedContentLength: 0, textEncodingName: nil))
        XCTAssertEqual(result.failure, "non-HTTP response")
        XCTAssertNil(result.statusCode)
    }

    func testBodyLimit() async {
        let result = await fetch(Data(repeating: 0x20, count: 256 * 1024 + 1), response(200))
        XCTAssertEqual(result.failure, "feed body limit exceeded")
        XCTAssertTrue(result.entries.isEmpty)
    }

    func testRowLimit() async {
        let result = await fetch(rows(101), response(200))
        XCTAssertEqual(result.failure, "feed row limit exceeded")
        let ok = await fetch(rows(100), response(200))
        XCTAssertNil(ok.failure)
    }

    func testDecodeFailureHasNoDetail() async {
        let result = await fetch(Data("{}".utf8), response(200))
        XCTAssertEqual(result.failure, "feed request or decode failed")
        assertNoURL(result)
    }

    func testTransportErrorHasNoURL() async {
        let result = await KCRWFeedClient(fetchData: { _ in throw Boom() }).fetch()
        XCTAssertEqual(result.failure, "feed request or decode failed")
        assertNoURL(result)
    }

    func testRequestSetup() async {
        var captured: URLRequest?
        let client = KCRWFeedClient(fetchData: { request in
            captured = request
            return (Data("[]".utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        })
        _ = await client.fetch()
        XCTAssertEqual(captured?.url, KCRWFeedClient.feedURL)
        XCTAssertEqual(captured?.timeoutInterval, 12)
        XCTAssertEqual(captured?.httpShouldHandleCookies, false)
    }
}
#endif
