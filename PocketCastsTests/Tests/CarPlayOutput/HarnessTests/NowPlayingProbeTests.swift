import MediaPlayer
import XCTest
@testable import podcasts

/// A `HarnessScenarioCase`, so it resets the app first. On a device the app may already have a real episode
/// loaded that writes its own Now Playing info.
final class NowPlayingProbeTests: HarnessScenarioCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    override func tearDown() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        NowPlayingHelper._resetRadioStateForTesting()
        super.tearDown()
    }

    /// Production path used in E1: info first, then artwork, both hopped through main.
    private func writeLikeProduction(title: String = "Song", artist: String = "Band", album: String? = "LP", colour: UIColor) {
        DispatchQueue.main.async {
            NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: title, artist: artist, album: album, stationName: "Station")
            NowPlayingHelper.setArtworkImage(ImageProbe.solid(colour))
        }
    }

    // MARK: Behavior 6 — probe colour

    func testArtworkColoursReadBack() {
        for (name, colour) in [("red", UIColor.red), ("green", UIColor.green), ("blue", UIColor.blue)] {
            writeLikeProduction(colour: ImageProbe.named[name] ?? colour)
            let outcome = NowPlayingProbe.waitUntil(.init(artwork: name), timeout: 3)
            XCTAssertTrue(outcome.isMatched, outcome.failureMessage ?? "")
            XCTAssertEqual(NowPlayingProbe.snapshot().artwork, name)
        }
    }

    func testFieldsReadBackAsWritten() {
        writeLikeProduction(title: "Song", artist: "Band", album: "LP", colour: ImageProbe.named["red"]!)
        _ = NowPlayingProbe.waitUntil(.init(artwork: "red"), timeout: 3)
        let s = NowPlayingProbe.snapshot()
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.title, "Song")
        XCTAssertEqual(s.artist, "Band")
        XCTAssertEqual(s.album, "LP")
        XCTAssertEqual(s.isLiveStream, true)
        XCTAssertEqual(s.mediaType, MPMediaType.music.rawValue)
        XCTAssertEqual(s.nowPlayingMediaType, MPNowPlayingInfoMediaType.audio.rawValue)
    }

    func testNoArtworkIsNil() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let empty = NowPlayingProbe.snapshot()
        XCTAssertTrue(empty.isEmpty)
        XCTAssertNil(empty.artwork)

        NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "Song", artist: "Band", album: nil, stationName: "Station")
        let s = NowPlayingProbe.snapshot()
        XCTAssertFalse(s.isEmpty)
        XCTAssertEqual(s.title, "Song")
        XCTAssertNil(s.artwork)
    }

    // MARK: Behavior 7 — probe timeout

    func testWaitUntilTimesOutWithLastSnapshotAndDiff() throws {
        NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "Song", artist: "Band", album: "LP", stationName: "Station")
        let outcome = NowPlayingProbe.waitUntil(.init(title: "Other", artwork: "red"), timeout: 0.3)
        guard case let .timedOut(last, diff, waited) = outcome else { return XCTFail("expected timeout") }
        XCTAssertEqual(last, NowPlayingProbe.snapshot())
        XCTAssertGreaterThanOrEqual(waited, 0.3)
        XCTAssertEqual(diff, ["title: expected Other, got Song", "artwork: expected red, got nil"])
        let message = try XCTUnwrap(outcome.failureMessage)
        XCTAssertTrue(message.contains(last.description), message)
        XCTAssertTrue(message.contains("title: expected Other, got Song"), message)
    }

    func testPredicateWaitTimesOut() {
        let outcome = NowPlayingProbe.waitUntil("never", timeout: 0.2) { _ in false }
        XCTAssertNotNil(outcome.failureMessage)
        XCTAssertTrue(outcome.failureMessage?.contains("never") ?? false)
    }

    func testWaitUntilMatchesAfterDelayedWrite() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "Late", artist: "Band", album: nil, stationName: "Station")
        }
        let start = ProcessInfo.processInfo.systemUptime
        let outcome = NowPlayingProbe.waitUntil(.init(title: "Late"), timeout: 5)
        let took = ProcessInfo.processInfo.systemUptime - start
        XCTAssertTrue(outcome.isMatched, outcome.failureMessage ?? "")
        XCTAssertGreaterThanOrEqual(took, 0.25)
        XCTAssertLessThan(took, 2)
    }

    func testHoldsPassesForStableValue() {
        NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "Stable", artist: "Band", album: nil, stationName: "Station")
        XCTAssertTrue(NowPlayingProbe.holds(.init(title: "Stable"), for: 0.4).isMatched)
    }

    func testHoldsReportsViolatingSnapshot() {
        NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "Before", artist: "Band", album: nil, stationName: "Station")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "After", artist: "Band", album: nil, stationName: "Station")
        }
        let outcome = NowPlayingProbe.holds(.init(title: "Before"), for: 2)
        guard case let .timedOut(last, diff, waited) = outcome else { return XCTFail("expected violation") }
        XCTAssertEqual(last.title, "After")
        XCTAssertEqual(diff, ["title: expected Before, got After"])
        XCTAssertLessThan(waited, 1)
    }

    func testTimelineRecordsTitleThenArtworkChange() {
        let timeline = NowPlayingProbe.Timeline()
        timeline.start()
        defer { timeline.stop() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NowPlayingHelper.setRadioTrackInfo(stationId: "st", trackTitle: "One", artist: "Band", album: nil, stationName: "Station")
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            NowPlayingHelper.setArtworkImage(ImageProbe.solid(ImageProbe.named["blue"]!))
        }
        _ = NowPlayingProbe.waitUntil(.init(artwork: "blue"), timeout: 3)
        _ = NowPlayingProbe.holds(.init(artwork: "blue"), for: 0.25)
        timeline.stop()
        let joined = timeline.lines.joined(separator: "\n")
        let empty = joined.range(of: "Snapshot(empty)")
        let title = joined.range(of: "title='One'")
        let art = joined.range(of: "artwork=blue")
        XCTAssertNotNil(empty, joined)
        XCTAssertNotNil(title, joined)
        XCTAssertNotNil(art, joined)
        if let empty, let title, let art {
            XCTAssertLessThan(empty.lowerBound, title.lowerBound)
            XCTAssertLessThan(title.lowerBound, art.lowerBound)
        }
    }
}
