import XCTest
@testable import podcasts

final class ArtworkFixtureQueryTests: XCTestCase {
    private var world: FakeWorld!

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HarnessReset.isEnabled, HarnessReset.skipMessage)
        HarnessReset.fullReset()
        world = try FakeWorld()
        try world.start()
    }

    override func tearDown() {
        if HarnessReset.isEnabled {
            HarnessReset.fullReset()
            world?.stop()
            world = nil
        }
        super.tearDown()
    }

    func testLookupEvidenceMatchesActualTermIncludingMissNotAnotherConfiguredSong() async throws {
        let a = FakeWorld.FakeSong(title: "Song A", artist: "Artist A", itunesArt: "blue")
        let b = FakeWorld.FakeSong(title: "Song B", artist: "Artist B")
        world.setTracklist([a, b])
        let w = try XCTUnwrap(world)
        XCTAssertFalse(w.wasITunesLookupServed(for: a.title, artist: a.artist))
        let (aData, _) = try await URLSession.shared.data(from: TrackArtworkResolver.itunesSearchURL(artist: a.artist, title: a.title)!)
        XCTAssertNotNil(TrackArtworkResolver.parseITunesArtworkURL(from: aData))
        XCTAssertTrue(w.wasITunesLookupServed(for: a.title, artist: a.artist))
        XCTAssertFalse(w.wasITunesLookupServed(for: b.title, artist: b.artist), "A's /search is not evidence of B's miss")
        _ = try await URLSession.shared.data(from: URL(string: "https://itunes.apple.com/search?term=unrelated")!)
        XCTAssertFalse(w.wasITunesLookupServed(for: b.title, artist: b.artist))
        let (bData, _) = try await URLSession.shared.data(from: TrackArtworkResolver.itunesSearchURL(artist: b.artist, title: b.title)!)
        XCTAssertNil(TrackArtworkResolver.parseITunesArtworkURL(from: bData))
        XCTAssertTrue(w.wasITunesLookupServed(for: b.title, artist: b.artist), "an actual query-specific empty result counts")
        XCTAssertFalse(w.wasITunesLookupServed(for: b.title, artist: a.artist))
    }

    func testLyricsFixtureOnlyServesScriptedReadRequests() async throws {
        world.setTracklist([FakeWorld.FakeSong(title: "Fixture Song", artist: "Fixture Artist", album: "Fixture Album")])
        let w = try XCTUnwrap(world)
        let base = "https://lrclib.net/api/get?artist_name=Fixture%20Artist&track_name=Fixture%20Song&album_name=Fixture%20Album"
        let (_, response) = try await URLSession.shared.data(from: URL(string: base)!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 404)
        XCTAssertNil(w.unexpectedRequestReport())
        let invalid = [base.replacingOccurrences(of: "Fixture%20Song", with: "Unknown"),
                       base.replacingOccurrences(of: "/api/get", with: "/api/anything"), base + "&unexpected=1"]
        for url in invalid {
            do {
                _ = try await URLSession.shared.data(from: URL(string: url)!)
                XCTFail("unexpected lyric request was served: \(url)")
            } catch { XCTAssertTrue(error.localizedDescription.contains("Harness blocked request")) }
        }
        var post = URLRequest(url: URL(string: base)!)
        post.httpMethod = "POST"
        do {
            _ = try await URLSession.shared.data(for: post)
            XCTFail("lyric POST must be blocked")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Harness blocked request")) }
        // These intentionally blocked requests belong to this guard self-test, not scenario teardown.
        XCTAssertEqual(w.blocked.count, 4)
    }
}
