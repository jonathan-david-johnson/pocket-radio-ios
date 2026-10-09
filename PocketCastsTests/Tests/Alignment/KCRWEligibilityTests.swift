import XCTest

@testable import podcasts

/// Only the measured Eclectic24 variants are eligible, and every
/// rejection has a stable reason.
final class KCRWEligibilityTests: XCTestCase {
    private let stationName = "KCRW Eclectic 24"

    func testKnownVariantsAreEligible() {
        let urls = [
            "https://streams.kcrw.com/e24_mp3",
            "https://streams.kcrw.com/e24_aac",
            "https://streams.kcrw.com/e24_aac/playlist.m3u8",
            "http://streams.kcrw.com/e24_mp3",
            "http://streams.kcrw.com/e24_aac",
            "http://streams.kcrw.com/e24_aac/playlist.m3u8"
        ]
        for url in urls {
            XCTAssertNil(KCRWAlignmentConfiguration.ineligibilityReason(name: stationName, streamURL: url), url)
            XCTAssertTrue(KCRWAlignmentConfiguration.isEligible(name: stationName, streamURL: url), url)
        }
    }

    func testNameMatchIsCaseInsensitive() {
        XCTAssertTrue(KCRWAlignmentConfiguration.isEligible(name: "kcrw eclectic24", streamURL: "https://streams.kcrw.com/e24_aac"))
    }

    func testRejectionsHaveStableReasons() {
        let good = "https://streams.kcrw.com/e24_aac"
        let table: [(station: String?, url: String?, reason: String)] = [
            ("NPR Hourly", good, "station name does not identify KCRW"),
            (nil, good, "station name does not identify KCRW"),
            (stationName, "not a url ::", "station stream URL is invalid"),
            (stationName, nil, "station stream URL is invalid"),
            (stationName, "https://example.com/e24_aac", "station stream host is not the measured host"),
            (stationName, "https://streams.kcrw.com/kcrw_live", "station stream path is not the known Eclectic24 variant"),
            (stationName, "https://user:pw@streams.kcrw.com/e24_aac", "station stream URL contains credentials, query, or fragment"),
            (stationName, "https://streams.kcrw.com/e24_aac?token=abc", "station stream URL contains credentials, query, or fragment"),
            (stationName, "https://streams.kcrw.com/e24_aac#frag", "station stream URL contains credentials, query, or fragment"),
            (stationName, "ftp://streams.kcrw.com/e24_aac", "station stream scheme is unsupported")
        ]
        for row in table {
            XCTAssertEqual(KCRWAlignmentConfiguration.ineligibilityReason(name: row.station, streamURL: row.url),
                           row.reason, "\(row.station ?? "nil") \(row.url ?? "nil")")
            XCTAssertFalse(KCRWAlignmentConfiguration.isEligible(name: row.station, streamURL: row.url))
        }
    }

    func testFrozenPolicies() {
        XCTAssertEqual(KCRWAlignmentConfiguration.measuredEndpoint.absoluteString,
                       "https://streams.kcrw.com/e24_aac/playlist.m3u8")
        XCTAssertEqual(KCRWAlignmentConfiguration.selectionPolicy.feedToProgramOffset, 160)
        XCTAssertEqual(KCRWAlignmentConfiguration.selectionPolicy.maxSelectedAge, 1200)
        XCTAssertEqual(KCRWAlignmentConfiguration.selectionPolicy.maxFeedSilence, 120)
        XCTAssertEqual(KCRWAlignmentConfiguration.historyPolicy.maxOccurrences, 100)
        XCTAssertEqual(KCRWAlignmentConfiguration.historyPolicy.maxHistoryAge, 6 * 60 * 60)
        XCTAssertEqual(KCRWAlignmentConfiguration.historyPolicy.correctionWindow, 120)
        XCTAssertEqual(KCRWAlignmentConfiguration.clockPolicy.correlationTolerance, 2)
        XCTAssertEqual(KCRWAlignmentConfiguration.clockPolicy.progressionTolerance, 2)
    }
}
