import PocketCastsDataModel
import XCTest
@testable import podcasts

final class RaceFixtureTests: HarnessScenarioCase {
    func testExactSongRequestStartAndCompletionAreDistinctAndBounded() throws {
        let a = FakeWorld.FakeSong(title: "A & B", artist: "C?D", art: "red", artDelay: 0.5)
        let b = FakeWorld.FakeSong(title: "A - B", artist: "C-D", art: "red")
        world.setTracklist([a, b])
        var feedFinished = false
        let feed = URLSession.shared.dataTask(with: URL(string: FakeWorld.kcrwTracklistURL)!) { _, _, _ in DispatchQueue.main.async { feedFinished = true } }
        feed.resume()
        XCTAssertTrue(spin(timeout: 5, until: { feedFinished }))
        let url = try XCTUnwrap(world.artworkURL(for: a.title, artist: a.artist))
        XCTAssertNotEqual(url, world.artworkURL(for: b.title, artist: b.artist))
        XCTAssertTrue(FakeWorld.isLoopbackURL(url.absoluteString))
        var clientFinished = false
        let download = URLSession.shared.dataTask(with: url) { data, _, error in
            XCTAssertNil(error)
            XCTAssertFalse(data?.isEmpty ?? true)
            DispatchQueue.main.async { clientFinished = true }
        }
        download.resume()
        XCTAssertTrue(spin(timeout: 5, until: { !self.world.artworkEvents(for: a.title, artist: a.artist).isEmpty }))
        let start = try XCTUnwrap(world.artworkEvents(for: a.title, artist: a.artist).first)
        XCTAssertEqual(start.kind, .requestStarted)
        XCTAssertFalse(clientFinished)
        XCTAssertTrue(world.artworkEvents(for: b.title, artist: b.artist).isEmpty)
        XCTAssertTrue(spin(timeout: 5, until: { clientFinished }))
        XCTAssertTrue(spin(timeout: 5, until: {
            self.world.artworkEvents(for: a.title, artist: a.artist).contains { $0.kind == .sendCompleted }
        }))
        let completion = try XCTUnwrap(world.artworkEvents(for: a.title, artist: a.artist).first { $0.kind == .sendCompleted })
        XCTAssertEqual(start.requestID, completion.requestID)
        XCTAssertGreaterThanOrEqual(completion.uptime - start.uptime, 0.45)
        XCTAssertGreaterThan(completion.bytes, 0)
        XCTAssertLessThanOrEqual(world.artwork.events.count, 240)
    }

    func testSecondStationKeepsSingleGuardAndDistinctTrackedIdentity() throws {
        let first = try world.makeStation()
        let other = try world.makeOtherStation()
        XCTAssertNotEqual(first.uuid, other.uuid)
        XCTAssertNotEqual(first.streamUrl, other.streamUrl)
        XCTAssertTrue(HarnessReset.trackedStationIds.contains(other.uuid))
        XCTAssertTrue(NetworkGuard.isInstalled)
        XCTAssertTrue(FakeWorld.isLoopbackURL(other.streamUrl))
        XCTAssertEqual(try world.makeOtherStation().uuid, other.uuid)
        XCTAssertNil(CuratedStationsLoader.enhancementsByUUID[other.uuid])
    }

    func testPollingRecordsTransientPostChangeRedEvenWhenFinalSnapshotIsGreen() {
        let start = ArtworkServer.Event(requestID: UUID(), target: "/art/red.png?song=A", kind: .requestStarted, uptime: 1, bytes: 0)
        let observation = ArtworkRaceObservation(song: FakeWorld.FakeSong(title: "A", artist: "Artist", art: "red"), started: start)
        observation.acceptSample(NowPlayingProbe.Snapshot(isEmpty: false, artwork: "red"), uptime: 1, afterIdentityChange: false)
        XCTAssertNil(observation.firstRed, "red is legitimate before identity changes")
        observation.acceptSample(NowPlayingProbe.Snapshot(isEmpty: false, artwork: "green"), uptime: 2, afterIdentityChange: true)
        observation.acceptSample(NowPlayingProbe.Snapshot(isEmpty: false, artwork: "red"), uptime: 2.02, afterIdentityChange: true)
        observation.acceptSample(NowPlayingProbe.Snapshot(isEmpty: false, artwork: "green"), uptime: 2.04, afterIdentityChange: true)
        XCTAssertNotNil(observation.firstRed, "a green final snapshot cannot erase transient stale art")
        for i in 0..<90 {
            observation.acceptSample(NowPlayingProbe.Snapshot(isEmpty: false, title: "\(i)", artwork: "green"), uptime: 3 + Double(i) * 0.02, afterIdentityChange: true)
        }
        XCTAssertLessThanOrEqual(observation.timeline.count, 80)
    }

    func testLocalPodcastFixtureUsesLoopbackMediaAndDeletesSyntheticRows() throws {
        let fixture = try LocalPodcastFixture(world: world)
        let episodeID = fixture.episode.uuid
        let podcastID = fixture.podcast.uuid
        XCTAssertTrue(FakeWorld.isLoopbackURL(fixture.mediaURL.absoluteString))
        XCTAssertNotNil(DataManager.sharedManager.findEpisode(uuid: episodeID))
        XCTAssertNotNil(DataManager.sharedManager.findPodcast(uuid: podcastID, includeUnsubscribed: true))
        XCTAssertTrue(fixture.cleanup())
        XCTAssertNil(DataManager.sharedManager.findEpisode(uuid: episodeID))
        XCTAssertNil(DataManager.sharedManager.findPodcast(uuid: podcastID, includeUnsubscribed: true))
        XCTAssertTrue(fixture.cleanup(), "cleanup is idempotent")
        XCTAssertThrowsError(try LocalPodcastFixture(world: world, mediaURL: "https://example.com/episode.mp3"))
    }

    func testPodcastMediaFixtureSupportsFiniteRangeRequests() throws {
        let fixture = try LocalPodcastFixture(world: world)
        defer { XCTAssertTrue(fixture.cleanup()) }
        var request = URLRequest(url: fixture.mediaURL)
        request.setValue("bytes=0-1023", forHTTPHeaderField: "Range")
        var finished = false
        let task = URLSession.shared.dataTask(with: request) { data, response, error in
            XCTAssertNil(error)
            XCTAssertEqual(data?.count, 1024)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 206)
            XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type"), "audio/mpeg")
            XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Range")?.hasPrefix("bytes 0-1023/") ?? false)
            DispatchQueue.main.async { finished = true }
        }
        task.resume()
        XCTAssertTrue(spin(timeout: 5, until: { finished }))
        XCTAssertNil(world.unexpectedRequestReport())
    }

    func testThreeRaceScenariosAreRegisteredWithOnlyEvidencedOutputMarkers() throws {
        let feature = try FeatureParser.parse(path: CarPlayRaceTests.featurePath)
        XCTAssertEqual(feature.scenarios.count, 3)
        XCTAssertEqual(Set(CarPlayRaceTests.knownBugs.keys), Set([
            "Switching stations prevents the old station's artwork from publishing",
            "Switching to a podcast prevents radio artwork from publishing over it"
        ]))
        try KnownBugs.validate(CarPlayRaceTests.knownBugs, in: feature)
        for marker in CarPlayRaceTests.knownBugs.values.flatMap({ $0 }) {
            XCTAssertEqual(marker.bugID, "bug_6")
            XCTAssertEqual(marker.assertionDiagnostic, "display.race.no-red-artwork")
        }
        let steps = NowPlayingSteps(world: world)
        defer { XCTAssertNoThrow(try steps.cleanup()) }
        let registry = StepLibrary()
        steps.register(in: registry)
        for scenario in feature.scenarios {
            for step in scenario.steps { XCTAssertEqual(registry.matches(step.text).count, 1, step.text) }
        }
    }

    func testNegativeAssertionCannotPassWithoutRequestAndIdentityChange() throws {
        let steps = NowPlayingSteps(world: world)
        defer { XCTAssertNoThrow(try steps.cleanup()) }
        XCTAssertThrowsError(try steps.observeOldArtworkCompletion(for: "Song A")) { error in
            XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic, "missing request evidence is a harness error, not a known output defect")
        }
        let start = ArtworkServer.Event(requestID: UUID(), target: "/art/red.png?song=A", kind: .requestStarted, uptime: 1, bytes: 0)
        steps.raceObservation = ArtworkRaceObservation(song: FakeWorld.FakeSong(title: "Song A", artist: "Artist A", art: "red"), started: start)
        XCTAssertThrowsError(try steps.observeOldArtworkCompletion(for: "Song A")) { error in
            XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic, "a started request without identity change is insufficient")
        }
    }

    func testLoopbackMediaURLRejectsExternalOrDisguisedHosts() {
        for value in ["https://example.com/a.mp3", "http://127.0.0.1.example.com/a.mp3",
                      "http://127.0.0.1@evil.example/a.mp3", "file://localhost/a.mp3", "ftp://127.0.0.1/a"] {
            XCTAssertFalse(FakeWorld.isLoopbackURL(value), value)
        }
        XCTAssertTrue(FakeWorld.isLoopbackURL("http://127.0.0.1:1234/media/episode.mp3"))
    }
}
