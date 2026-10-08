import XCTest
@testable import podcasts

final class WireAlbumStepsTests: HarnessScenarioCase {
    func testWireShapesAndRealParserAlbumSemantics() throws {
        let observer = RadioMetadataObserver(stationId: "fixture")
        let song = FakeWorld.FakeSong(title: "Song A", artist: "Artist A", album: "Album A")
        XCTAssertEqual(FakeWorld.icyTitle(song), "Song A-Artist A-Album A")
        XCTAssertEqual(FakeWorld.icyTitle(song, includesAlbum: false), "Artist A - Song A")
        XCTAssertEqual(observer.parseStreamTitle(FakeWorld.icyTitle(song))?.album, "Album A")
        let pair = try XCTUnwrap(observer.parseStreamTitle(FakeWorld.icyTitle(song, includesAlbum: false)))
        XCTAssertEqual(pair.title, "Song A")
        XCTAssertEqual(pair.artist, "Artist A")
        XCTAssertNil(pair.album)
        XCTAssertEqual(FakeWorld.icyTitle(FakeWorld.FakeSong(title: "Song", artist: "Artist")), "Song-Artist-Album")
    }

    func testAnnouncementPhrasesResolveExactlyOnce() throws {
        let steps = NowPlayingSteps(world: try FakeWorld())
        let registry = StepLibrary()
        steps.register(in: registry)
        for phrase in [
            "the stream announces \"Song A\" by \"Artist A\"",
            "the stream announces \"Song A\" by \"Artist A\" from album \"Album A\"",
            "the stream announces \"Song A\" by \"Artist A\" without an album"
        ] {
            XCTAssertEqual(registry.matches(phrase).count, 1, phrase)
        }
        try steps.cleanup()
    }

    func testAllThreePhrasesTravelThroughRealICYAndIgnoreOldNotifications() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        let registry = StepLibrary()
        steps.register(in: registry)
        func execute(_ phrase: String) -> FeatureFailure? {
            let scenario = FeatureScenario(name: "wire albums", tags: [], line: 1, featurePath: "wire.feature",
                                           steps: [FeatureStep(keyword: "When", text: phrase, line: 2)])
            return FeatureExecution.run(scenario: scenario, steps: registry)
        }
        XCTAssertNil(execute("the listener starts the station"))
        XCTAssertNil(execute("the stream announces \"Song A\" by \"Artist A\" from album \"Album A\""))
        XCTAssertEqual(steps.announcements.last?.album, "Album A")
        XCTAssertNil(execute("the stream announces \"Song B\" by \"Artist B\" without an album"))
        XCTAssertNil(steps.announcements.last?.album)
        XCTAssertNil(execute("the stream announces \"Song C\" by \"Artist C\""))
        XCTAssertEqual(steps.announcements.last?.album, "Album")
        XCTAssertTrue(world.icy.sent.contains { $0.title == "Song A-Artist A-Album A" })
        XCTAssertTrue(world.icy.sent.contains { $0.title == "Artist B - Song B" })
        XCTAssertTrue(world.icy.sent.contains { $0.title == "Song C-Artist C-Album" })

        let checkpoint = steps.announcements.count
        let last = try XCTUnwrap(steps.announcements.last)
        XCTAssertFalse(steps.received(last, after: checkpoint), "prior matching notifications cannot satisfy a new step")
        steps.titleTimeout = 0.2
        let failure = try XCTUnwrap(execute("the stream announces \"Song C\" by \"Artist C\""))
        XCTAssertNil(failure.outputAssertionDiagnostic, "missing new metadata is setup failure, not a known output bug")
        XCTAssertTrue(failure.errorText?.contains("no NEW ICY notification") == true)
    }
}
