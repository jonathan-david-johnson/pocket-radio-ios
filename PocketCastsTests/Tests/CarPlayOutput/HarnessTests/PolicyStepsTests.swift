import MediaPlayer
import XCTest
@testable import podcasts

final class PolicyStepsTests: HarnessScenarioCase {
    func testAllThreePolicyScenariosResolveExactlyOnce() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        let registry = StepLibrary()
        steps.register(in: registry)
        let feature = try FeatureParser.parse(path: FeatureTestCase.contractsFeature("now_playing/carplay_policy.feature"))
        XCTAssertEqual(feature.scenarios.map(\.name), [CarPlayPolicyTests.adScenario, CarPlayPolicyTests.lyricScenario, CarPlayPolicyTests.markerScenario])
        XCTAssertEqual(CarPlayPolicyTests.defaultTestSuite.testCaseCount, 3)
        for scenario in feature.scenarios {
            for step in scenario.steps { XCTAssertEqual(registry.matches(step.text).count, 1, step.text) }
        }
        for phrase in ["CarPlay connects", "CarPlay disconnects",
                       "a lyric line \"A lyric that is not an album\" reaches the album publishing boundary",
                       "the display keeps the album \"Album A\" for 1 second"] {
            XCTAssertEqual(registry.matches(phrase).count, 1, phrase)
        }
    }

    func testSharedDisconnectActuallyRestoresPreConnectLyricAndCleansUp() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.rows = [.init(title: "Song A", artist: "Artist A", album: "Album A", art: "red")]
        world.setTracklist(steps.rows)
        world.setLatency(.tracklist, seconds: 2)
        try steps.startStation()
        try steps.announce(title: "Song A", artist: "Artist A", album: "Album A")
        let ready = NowPlayingProbe.waitUntil(.init(title: "Song A", artist: "Artist A", album: "Album A", artwork: "red"), timeout: 10)
        XCTAssertTrue(ready.isMatched, ready.failureMessage ?? "")
        let before = NowPlayingProbe.snapshot()
        try steps.publishLyric("Pre-connect lyric, NOT Album A")
        XCTAssertEqual(NowPlayingProbe.snapshot().album, "Pre-connect lyric, NOT Album A")
        try steps.connectCarPlay()
        let delegate = try XCTUnwrap(steps.carPlayDelegate)
        try steps.publishLyric("Blocked connected lyric")
        try steps.holdAlbum("Pre-connect lyric, NOT Album A", for: 1)
        // Unlike the shared scenario, album is definitely wrong BEFORE disconnect.
        // Removing the handler's restoration body makes this check fail.
        try steps.disconnectCarPlay()
        let after = NowPlayingProbe.snapshot()
        XCTAssertEqual(after.album, "Album A")
        XCTAssertEqual(after.title, before.title)
        XCTAssertEqual(after.artist, before.artist)
        XCTAssertEqual(after.artwork, before.artwork)
        XCTAssertFalse(CarPlaySceneDelegate.isConnected)
        XCTAssertNil(delegate.interfaceController)
        XCTAssertNil(steps.carPlayDelegate)
        try steps.cleanup()
        HarnessReset.fullReset()
        XCTAssertTrue(HarnessReset.isClean, HarnessReset.stateSummary())
    }

    func testConnectedCleanupRunsSharedHandlerAndUnconnectedCallsFailOrdinarily() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        XCTAssertThrowsError(try steps.disconnectCarPlay())
        XCTAssertThrowsError(try steps.connectCarPlay())
        XCTAssertThrowsError(try steps.publishLyric("no display"))
        XCTAssertThrowsError(try steps.holdAlbum("Album A", for: 0))
        steps.rows = [.init(title: "Song A", artist: "Artist A", album: "Album A", art: "red")]
        world.setTracklist(steps.rows)
        try steps.startStation()
        try steps.connectCarPlay()
        try steps.cleanup()
        XCTAssertFalse(CarPlaySceneDelegate.isConnected)
        XCTAssertNil(steps.carPlayDelegate)
    }

    func testUnsentWrongConnectionAndOutOfWindowAdAreHarnessFailures() throws {
        let observation = AdFrameObservation(baseline: .init(isEmpty: false), connections: [7],
                                             deliveryCheckpoint: 1, startedAt: 10)
        let old = IcyStreamServer.SentTitle(title: IcyStreamServer.adTitle, connection: 7, uptime: 11)
        for events in [[old], [old, .init(title: IcyStreamServer.adTitle, connection: 8, uptime: 11)],
                       [old, .init(title: "Song A", connection: 7, uptime: 11)],
                       [old, .init(title: IcyStreamServer.adTitle, connection: 7, uptime: 9)],
                       [old, .init(title: IcyStreamServer.adTitle, connection: 7, uptime: 13)]] {
            XCTAssertThrowsError(try observation.requireDelivery(events, endedAt: 12)) { error in
                XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic)
                XCTAssertTrue(String(describing: error).contains("ad-input.delivery"))
            }
        }
        let delivery = try observation.requireDelivery([old, .init(title: IcyStreamServer.adTitle, connection: 7, uptime: 11.5)], endedAt: 12)
        XCTAssertEqual(delivery.connection, 7)
        XCTAssertEqual(delivery.uptime, 11.5)
    }

    func testAdHoldWithoutInjectionIsHarnessFailure() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        XCTAssertThrowsError(try steps.holdDisplayAcrossAd(for: 0)) { error in
            XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic)
        }
        XCTAssertThrowsError(try steps.sendObservedAdFrame()) { error in
            XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic)
        }
        XCTAssertTrue(world.icy.deliveredAds.isEmpty)
    }

    func testMarkerObservationDoesNotLetLaterRepairHideEarlyViolation() {
        let observation = MarkerWriteObservation()
        observation.observe(.init(isEmpty: true))
        XCTAssertNil(observation.firstFailure)
        observation.observe(.init(isEmpty: false, isLiveStream: true, mediaType: MPMediaType.music.rawValue))
        XCTAssertEqual(observation.firstFailure?.outputAssertionDiagnostic, "display.live-music-markers")
        observation.observe(.init(isEmpty: false, isLiveStream: true, mediaType: MPMediaType.music.rawValue,
                                  nowPlayingMediaType: MPNowPlayingInfoMediaType.audio.rawValue))
        XCTAssertEqual(observation.changes.count, 2)
        XCTAssertNotNil(observation.firstFailure, "a later artwork/metadata write must not repair away baseline evidence")
    }

    func testMarkerComparisonRequiresAllThreeActualFields() throws {
        // Pure comparison inputs, never installed into MPNowPlayingInfoCenter.
        let valid = NowPlayingProbe.Snapshot(isEmpty: false, isLiveStream: true,
                                             mediaType: MPMediaType.music.rawValue,
                                             nowPlayingMediaType: MPNowPlayingInfoMediaType.audio.rawValue)
        try NowPlayingSteps.requireLiveMusicMarkers(valid)
        var missingLive = valid; missingLive.isLiveStream = nil
        var podcast = valid; podcast.mediaType = MPMediaType.podcast.rawValue
        var video = valid; video.nowPlayingMediaType = MPNowPlayingInfoMediaType.video.rawValue
        var missingAudio = valid; missingAudio.nowPlayingMediaType = nil
        for invalid in [missingLive, podcast, video, missingAudio] {
            XCTAssertThrowsError(try NowPlayingSteps.requireLiveMusicMarkers(invalid)) { error in
                XCTAssertEqual((error as? StepFailure)?.outputAssertionDiagnostic, "display.live-music-markers")
            }
        }
    }
}
