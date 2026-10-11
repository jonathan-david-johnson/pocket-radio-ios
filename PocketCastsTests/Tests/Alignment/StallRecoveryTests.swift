import AVFoundation
import CoreMedia
import XCTest
@testable import podcasts

final class StallRecoveryTests: XCTestCase {
    func test_liveRadioResumesWithoutSeeking() {
        XCTAssertTrue(StallRecovery.resumesWithoutSeeking(streamingHLS: false, liveRadio: true))
    }

    func test_hlsPodcastStillResumesWithoutSeeking() {
        XCTAssertTrue(StallRecovery.resumesWithoutSeeking(streamingHLS: true, liveRadio: false))
    }

    func test_aPlainEpisodeKeepsTheOldRecovery() {
        XCTAssertFalse(StallRecovery.resumesWithoutSeeking(streamingHLS: false, liveRadio: false))
    }

    private func range(_ start: Double, _ duration: Double) -> CMTimeRange {
        CMTimeRange(start: CMTime(seconds: start, preferredTimescale: 600), duration: CMTime(seconds: duration, preferredTimescale: 600))
    }

    func test_forwardBuffer_isTheLoadedRangeEndMinusThePlayhead() {
        let buffer = AlignmentProbeLog.forwardBuffer(loadedRanges: [range(0, 5), range(10, 20)],
                                                     current: CMTime(seconds: 12, preferredTimescale: 600))
        XCTAssertEqual(buffer ?? -1, 18, accuracy: 0.001)
    }

    func test_forwardBuffer_isNilWhenThePlayheadIsInNoRange() {
        XCTAssertNil(AlignmentProbeLog.forwardBuffer(loadedRanges: [range(0, 5)], current: CMTime(seconds: 7, preferredTimescale: 600)))
        XCTAssertNil(AlignmentProbeLog.forwardBuffer(loadedRanges: [], current: CMTime(seconds: 1, preferredTimescale: 600)))
        XCTAssertNil(AlignmentProbeLog.forwardBuffer(loadedRanges: [range(0, 5)], current: .invalid))
    }

    func test_probeLine_addsTheBufferOnlyWhenKnown() {
        let id = UUID(uuidString: "ABCDEF12-0000-0000-0000-000000000000")!
        let plain = AlignmentProbeLog.line(generation: id, elapsed: 1, media: 1, date: nil, rate: 1, status: .playing)
        XCTAssertFalse(plain.contains("buf="))
        XCTAssertFalse(plain.contains("keepUp="))
        let full = AlignmentProbeLog.line(generation: id, elapsed: 1, media: 1, date: nil, rate: 1, status: .playing,
                                          buffer: 12.34, likelyToKeepUp: true)
        XCTAssertTrue(full.hasSuffix(" buf=12.3 keepUp=1"), full)
    }
}
