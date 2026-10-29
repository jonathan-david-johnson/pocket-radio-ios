#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import XCTest
@testable import podcasts

final class MediaStallDiagnosticsTests: XCTestCase {
    func testErrorChainRetainsSafeDomainsAndCodesButNotSecrets() {
        let inner = NSError(domain: NSURLErrorDomain, code: -1001,
                            userInfo: [NSLocalizedDescriptionKey: "https://example.test/?token=secret"])
        let outer = NSError(domain: "CoreMediaErrorDomain", code: -12889,
                            userInfo: [NSUnderlyingErrorKey: inner, "secret": "password"])
        let result = MediaStallDiagnostics.errorChain(outer)
        XCTAssertEqual(result, "chain=CoreMediaErrorDomain:-12889>NSURLErrorDomain:-1001")
        XCTAssertFalse(result.contains("secret"))
        XCTAssertEqual(MediaStallDiagnostics.safeDomain("https://host/?token=secret"), "other")
    }

    func testErrorChainHasBoundedDepth() {
        var error = NSError(domain: NSPOSIXErrorDomain, code: 1)
        for _ in 0..<12 { error = NSError(domain: NSPOSIXErrorDomain, code: 2, userInfo: [NSUnderlyingErrorKey: error]) }
        XCTAssertEqual(MediaStallDiagnostics.errorChain(error).components(separatedBy: ">").count, 8)
    }

    func testHTTPStatusRequiresAnExplicitHTTPLabel() {
        XCTAssertEqual(MediaStallDiagnostics.httpStatus(comment: "HTTP 404 Not Found https://user:secret@host/secret"), 404)
        XCTAssertEqual(MediaStallDiagnostics.httpStatus(comment: "HTTP/1.1 503 Service Unavailable"), 503)
        XCTAssertEqual(MediaStallDiagnostics.httpStatus(comment: "HTTP status code: 403"), 403)
        XCTAssertEqual(MediaStallDiagnostics.httpStatus(comment: "HTTP: 404"), 404)
        XCTAssertNil(MediaStallDiagnostics.httpStatus(comment: "CoreMedia error -12889; segment 404"))
        XCTAssertNil(MediaStallDiagnostics.httpStatus(comment: "https://example.test/HTTP404?token=secret"))
        XCTAssertNil(MediaStallDiagnostics.httpStatus(comment: nil))
    }

    func testRedactedCommentKeepsAVPlayerWordingButNoIdentifiers() {
        XCTAssertEqual(MediaStallDiagnostics.redactedComment("No response for media file in 5.99s"),
                       "No response for media file in 5.99s")
        XCTAssertEqual(MediaStallDiagnostics.redactedComment("HTTP 404: File Not Found"), "HTTP 404: File Not Found")
        // Shapes copied from the KCRW stream; every value is made up. 203.0.113.0/24 is reserved for documentation.
        let noisy = "HTTP 404: https://host.test/1234_256.aac/x-1-2.aac?listeningSessionID=0000aaaa1111bbbb_222_FakeId"
            + " from 203.0.113.7:80 segment FakeSegName-123456789-5990.aac token MjAzLjAuMTEzLjc6ODA!_000FakeTok"
        let redacted = MediaStallDiagnostics.redactedComment(noisy)
        XCTAssertTrue(redacted.hasPrefix("HTTP 404:"))
        for secret in ["host.test", "listeningSessionID", "203.0", "FakeSegName", "MjAzLjAu", "0000aaaa1111bbbb"] {
            XCTAssertFalse(redacted.contains(secret), secret)
        }
        XCTAssertEqual(MediaStallDiagnostics.redactedComment(nil), "")
        XCTAssertLessThanOrEqual(MediaStallDiagnostics.redactedComment(String(repeating: "a b ", count: 100)).count, 121)
    }

    func testResourceClassificationDoesNotReturnAnyURLComponent() {
        XCTAssertEqual(MediaStallDiagnostics.resourceType("https://u:password@example.test/secret.M3U8?token=secret"), "playlist")
        XCTAssertEqual(MediaStallDiagnostics.resourceType("https://example.test/secret.ts?token=secret"), "media")
        XCTAssertEqual(MediaStallDiagnostics.resourceType("https://example.test/secret?token=.m3u8"), "other")
        XCTAssertEqual(MediaStallDiagnostics.resourceType(nil), "unknown")
    }

    func testStatusReasonAndNonFiniteValuesAreExplicit() {
        XCTAssertEqual(MediaStallDiagnostics.status(.waitingToPlayAtSpecifiedRate), "waiting")
        XCTAssertEqual(MediaStallDiagnostics.waitReason(.toMinimizeStalls), "minimizeStalls")
        XCTAssertEqual(MediaStallDiagnostics.waitReason(nil), "none")
        XCTAssertEqual(MediaStallDiagnostics.seconds(.nan), "unknown")
    }

    func testSeekAndSnapshotStayScopedToOneItemAndAvoidURLs() {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/private-secret-media"))
        let player = AVPlayer(playerItem: item)
        let lock = NSLock()
        var lines: [String] = []
        let diagnostics = MediaStallDiagnostics(item: item, player: player, generation: "test-gen") { line in
            lock.lock(); defer { lock.unlock() }
            lines.append(line)
        }
        diagnostics.seek(target: 42, origin: "test")
        diagnostics.snapshot(trigger: "test")
        lock.lock(); let output = lines.joined(separator: "\n"); lock.unlock()
        XCTAssertTrue(output.contains("gen=test-gen seek origin=test"))
        XCTAssertTrue(output.contains("snapshot trigger=test"))
        XCTAssertFalse(output.contains("secret"))
        XCTAssertFalse(output.contains("password"))
        XCTAssertFalse(output.contains("private-secret-media"))
    }

    func testNotificationsAreScopedToTheItemAndRemovedOnRelease() {
        let item = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/media-a"))
        let other = AVPlayerItem(url: URL(fileURLWithPath: "/tmp/media-b"))
        let player = AVPlayer(playerItem: item)
        var lines: [String] = []
        var diagnostics: MediaStallDiagnostics? = MediaStallDiagnostics(item: item, player: player, generation: "one") {
            lines.append($0)
        }
        XCTAssertNotNil(diagnostics)
        lines.removeAll()
        NotificationCenter.default.post(name: .AVPlayerItemNewErrorLogEntry, object: other)
        XCTAssertTrue(lines.isEmpty)
        NotificationCenter.default.post(name: .AVPlayerItemNewErrorLogEntry, object: item)
        XCTAssertTrue(lines.contains { $0.contains("errorLog trigger=notification") })
        diagnostics = nil
        lines.removeAll()
        NotificationCenter.default.post(name: .AVPlayerItemNewErrorLogEntry, object: item)
        XCTAssertTrue(lines.isEmpty)
    }
}
#endif
