#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import XCTest
@testable import podcasts

final class KCRWSessionPinningTests: XCTestCase {
    // Shapes copied from the KCRW master playlist; every value is made up. 203.0.113.0/24 is for documentation.
    private let owner = "203.0.113.7:80"
    private var ownerField: String { Data(owner.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "!") }
    private var sessionID: String { "0000aaaa1111bbbb_222_FakeIdAA_\(ownerField)_000FakeTok" }
    private let base = URL(string: "https://streams.kcrw.com/e24_aac/playlist.m3u8")!

    private func master(variant: String) -> String {
        "#EXTM3U\r\n#EXT-X-STREAM-INF:BANDWIDTH=255000,CODECS=\"mp4a.40.2\"\r\n\(variant)\r\n"
    }

    private var variant: String {
        "https://streams.kcrw.com:443/1234_256.aac/playlist.m3u8?listeningSessionID=\(sessionID)&downloadSessionID=0"
    }

    func testDecodesTheOwningServerFromTheSessionID() {
        let server = KCRWSessionPinning.owningServer(sessionID: sessionID)
        XCTAssertEqual(server?.host, "203.0.113.7")
        XCTAssertEqual(server?.port, 80)
    }

    func testRejectsFieldsThatAreNotAnAddress() {
        XCTAssertNil(KCRWSessionPinning.owningServer(sessionID: "abc_def_ghi"))
        let notIP = Data("999.1.1.1:80".utf8).base64EncodedString()
        XCTAssertNil(KCRWSessionPinning.owningServer(sessionID: "x_\(notIP)_y"))
        let badPort = Data("203.0.113.7:0".utf8).base64EncodedString()
        XCTAssertNil(KCRWSessionPinning.owningServer(sessionID: "x_\(badPort)_y"))
        let hostname = Data("example.test:80".utf8).base64EncodedString()
        XCTAssertNil(KCRWSessionPinning.owningServer(sessionID: "x_\(hostname)_y"))
    }

    func testRewritesTheVariantToThePlainHTTPAddressOfItsOwnServer() throws {
        let result = KCRWSessionPinning.pin(master: master(variant: variant), base: base)
        XCTAssertTrue(result.pinned)
        let line = try XCTUnwrap(result.text.components(separatedBy: .newlines).first { $0.hasPrefix("http") })
        let url = try XCTUnwrap(URLComponents(string: line))
        XCTAssertEqual(url.scheme, "http")
        XCTAssertEqual(url.host, "203.0.113.7")
        XCTAssertNil(url.port, "port 80 is the default for http")
        XCTAssertEqual(url.path, "/1234_256.aac/playlist.m3u8")
        XCTAssertEqual(url.queryItems?.first { $0.name == "listeningSessionID" }?.value, sessionID, "the session is kept")
        XCTAssertTrue(result.text.contains("#EXT-X-STREAM-INF:BANDWIDTH=255000"), "tags are kept")
    }

    func testKeepsANonDefaultPort() throws {
        let other = Data("203.0.113.7:8000".utf8).base64EncodedString()
        let text = KCRWSessionPinning.pin(master: master(variant: variant.replacingOccurrences(of: ownerField, with: other)),
                                          base: base).text
        let line = try XCTUnwrap(text.components(separatedBy: .newlines).first { $0.hasPrefix("http") })
        XCTAssertEqual(URLComponents(string: line)?.port, 8000)
    }

    func testLeavesAMasterWithoutAnOwnerUnchanged() {
        let plain = master(variant: "https://streams.kcrw.com/1234_256.aac/playlist.m3u8?listeningSessionID=opaque")
        let result = KCRWSessionPinning.pin(master: plain, base: base)
        XCTAssertFalse(result.pinned)
        XCTAssertEqual(result.text, plain)
    }

    func testLeavesAVariantOnAnotherHostUnchanged() {
        let elsewhere = master(variant: variant.replacingOccurrences(of: "streams.kcrw.com:443", with: "cdn.example.test"))
        let result = KCRWSessionPinning.pin(master: elsewhere, base: base)
        XCTAssertFalse(result.pinned)
        XCTAssertEqual(result.text, elsewhere)
    }

    func testResolvesARelativeVariantAgainstTheMaster() throws {
        let relative = master(variant: "/1234_256.aac/playlist.m3u8?listeningSessionID=\(sessionID)")
        let result = KCRWSessionPinning.pin(master: relative, base: base)
        XCTAssertTrue(result.pinned)
        XCTAssertTrue(result.text.contains("http://203.0.113.7/1234_256.aac/playlist.m3u8?listeningSessionID="))
    }

    func testTheAssetURLRoundTripsToTheRealMaster() throws {
        let custom = try XCTUnwrap(KCRWSessionPinning.assetURL(for: base))
        XCTAssertEqual(custom.scheme, KCRWSessionPinning.scheme)
        XCTAssertEqual(KCRWSessionPinning.realURL(for: custom), base)
        XCTAssertNil(KCRWSessionPinning.realURL(for: base), "only the custom scheme is served by the loader")
    }

    func testTheLoaderIsRetainedByItsAsset() throws {
        weak var weakLoader: KCRWMasterPinningLoader?
        autoreleasepool {
            let asset = KCRWSessionPinning.makeAsset(master: base, userAgent: "test")
            weakLoader = asset?.resourceLoader.delegate as? KCRWMasterPinningLoader
            XCTAssertEqual(asset?.url.scheme, KCRWSessionPinning.scheme)
        }
        XCTAssertNil(weakLoader, "released with its asset")
        // The delegate is weak on the loader, so without the asset keeping it the delegate would already be gone.
        let kept = KCRWSessionPinning.makeAsset(master: base, userAgent: "test")
        XCTAssertNotNil(kept?.resourceLoader.delegate, "kept alive by its asset")
    }
}
#endif
