import XCTest
@testable import podcasts

final class LifecycleStepsTests: HarnessScenarioCase {
    func testLifecyclePhrasesResolveExactlyOnce() throws {
        let steps = NowPlayingSteps(world: try FakeWorld())
        let registry = StepLibrary()
        steps.register(in: registry)
        for phrase in [
            "the station's tracklist is already cached before playback",
            "the listener pauses and resumes",
            "the listener stops and replays the same station"
        ] {
            XCTAssertEqual(registry.matches(phrase).count, 1, phrase)
        }
        try steps.cleanup()
    }

    func testCacheWarmUsesRealFetchWithoutPlaybackAndRejectsDirtySetup() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.rows = [FakeWorld.FakeSong(title: "Song A", artist: "Artist A", album: "Album A", art: "red")]
        world.setTracklist(steps.rows)
        let station = try world.makeStation()
        XCTAssertNil(RadioTracklistService.shared.cached(stationId: station.stationId))
        try steps.cacheTracklistBeforePlayback()
        let cached = try XCTUnwrap(RadioTracklistService.shared.cached(stationId: station.stationId))
        XCTAssertEqual(cached.map(\.title), ["Song A"])
        XCTAssertEqual(cached.first?.album, "Album A")
        XCTAssertEqual(cached.first?.albumArtURL?.host, "127.0.0.1")
        XCTAssertEqual(world.served.filter { $0.host == FakeWorld.tracklistHost }.count, 1)
        XCTAssertNil(PlaybackManager.shared.currentEpisode)
        XCTAssertTrue(NowPlayingProbe.snapshot().isEmpty)
        XCTAssertThrowsError(try steps.cacheTracklistBeforePlayback()) { error in
            XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic)
        }
    }

    func testCachedStartupReleasesActualContinuationAndCleanupCancelsUnusedArm() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.rows = [.init(title: "Song A", artist: "Artist A", album: "Album A", art: "red")]
        world.setTracklist(steps.rows)
        try steps.cacheTracklistBeforePlayback()
        try steps.startStation()
        XCTAssertTrue(RadioOutputTestHooks.shared.isIdle)
        XCTAssertNil(steps.startupTicket)
        XCTAssertTrue(steps.lifecycleTimeline.contains { $0.contains("actual startup rebuild pending") })
        XCTAssertTrue(steps.lifecycleTimeline.contains { $0.contains("real artwork published RED") })
        XCTAssertTrue(steps.lifecycleTimeline.contains { $0.contains("released unchanged actual startup rebuild") })
        let ticket = try RadioOutputTestHooks.shared.arm(stationID: "unused")
        XCTAssertTrue(RadioOutputTestHooks.shared.capture(stationID: "unused") { XCTFail("cleanup ran cancelled rebuild") })
        try steps.cleanup()
        XCTAssertTrue(RadioOutputTestHooks.shared.isIdle)
        XCTAssertThrowsError(try RadioOutputTestHooks.shared.release(ticket, currentStationID: { "unused" }))
        HarnessReset.fullReset()
        XCTAssertTrue(HarnessReset.isClean, HarnessReset.stateSummary())
    }

    func testPublicLifecycleControlsKeepScenarioStateAndRequireNewReplayICY() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.rows = [FakeWorld.FakeSong(title: "Song A", artist: "Artist A", art: "red")]
        world.setTracklist(steps.rows)
        world.setLatency(.tracklist, seconds: 2)
        try steps.startStation()
        try steps.announce(title: "Song A", artist: "Artist A")
        let red = NowPlayingProbe.waitUntil(.init(title: "Song A", artwork: "red"), timeout: 10)
        XCTAssertTrue(red.isMatched, red.failureMessage ?? "")
        let station = try world.makeStation()
        let cached = try XCTUnwrap(RadioTracklistService.shared.cached(stationId: station.stationId))
        let count = steps.announcements.count
        try steps.pauseAndResume()
        XCTAssertTrue(PlaybackManager.shared.isReadyToPlay)
        XCTAssertTrue(PlaybackManager.shared.isPlaying)
        XCTAssertEqual(steps.announcements.count, count, "resume must not inject metadata")
        try steps.stopAndReplay()
        XCTAssertEqual(steps.announcements.count, count + 1, "fresh observer receives the retained wire title on replay")
        XCTAssertEqual(steps.announcements.last?.title, "Song A")
        XCTAssertEqual(RadioTracklistService.shared.cached(stationId: station.stationId)?.map(\.title), cached.map(\.title))
        XCTAssertEqual(world.configuredTracklist, steps.rows)
        try steps.cleanup()
        XCTAssertTrue(steps.received(try XCTUnwrap(steps.announcements.last), after: count))
    }
}
