import PocketCastsDataModel
import StreamSession
import XCTest

@testable import podcasts

/// Which stations align, under which profile, and how a profile's clock and skew key behave (ADR 0010).
@MainActor
final class AlignmentProfileTests: XCTestCase {
    private func radio(_ name: String, _ url: String, id: String = "id") -> RadioStation {
        RadioStation(stationId: id, name: name, streamUrl: url)
    }

    // MARK: Eligibility

    func testKCRWStreamsUseTheKCRWProfile() {
        for url in ["https://streams.kcrw.com/e24_mp3", "https://streams.kcrw.com/e24_aac", "https://streams.kcrw.com/e24_aac/playlist.m3u8"] {
            XCTAssertEqual(AlignmentProfiles.profile(name: "KCRW Eclectic 24", streamURL: url)?.key, "kcrw-e24", url)
        }
        XCTAssertNil(AlignmentProfiles.profile(name: "KCRW Live", streamURL: "https://streams.kcrw.com/kcrw_live"))
    }

    func testKEXPStreamsUseTheKEXPProfile() {
        XCTAssertEqual(AlignmentProfiles.profile(name: "KEXP", streamURL: "https://kexp.streamguys1.com/kexp160.aac")?.key, "kexp")
        XCTAssertEqual(AlignmentProfiles.profile(name: "KEXP 90.3 FM", streamURL: "https://kexp-mp3-128.streamguys1.com/kexp128.mp3")?.key, "kexp")
    }

    func testOtherStationsAndOddURLsHaveNoProfile() {
        XCTAssertNil(AlignmentProfiles.profile(name: "NPR Hourly", streamURL: "https://npr-ice.streamguys1.com/live.mp3"))
        XCTAssertNil(AlignmentProfiles.profile(name: "KEXP", streamURL: "https://other.example/stream"), "the host has to be KEXP's")
        XCTAssertNil(AlignmentProfiles.profile(name: "Some Station", streamURL: "https://kexp.streamguys1.com/kexp160.aac"), "the name has to say KEXP")
        XCTAssertNil(AlignmentProfiles.profile(name: "KEXP", streamURL: "https://user:pw@kexp.streamguys1.com/kexp160.aac"))
        XCTAssertNil(AlignmentProfiles.profile(name: "KEXP", streamURL: "https://kexp.streamguys1.com/kexp160.aac?token=x"))
        XCTAssertNil(AlignmentProfiles.profile(name: "KEXP", streamURL: "ftp://kexp.streamguys1.com/kexp160.aac"))
        XCTAssertNil(AlignmentProfiles.profile(name: nil, streamURL: nil))
    }

    func testAnEpisodeGetsAProfileOnlyWhenAlignmentIsOn() {
        let kexp = radio("KEXP", "https://kexp.streamguys1.com/kexp160.aac", id: "kexp-1")
        XCTAssertNil(AlignmentProfiles.profile(for: kexp, mode: .off, stationLookup: { _ in nil }))
        XCTAssertEqual(AlignmentProfiles.profile(for: kexp, mode: .on, stationLookup: { _ in nil })?.key, "kexp")
    }

    func testAShimEpisodeIsFoundThroughTheStationLookup() {
        let station = radio("KEXP", "https://kexp.streamguys1.com/kexp160.aac", id: "kexp-1")
        let shim = Episode()
        shim.uuid = "kexp-1"
        XCTAssertEqual(AlignmentProfiles.profile(for: shim, mode: .on, stationLookup: { $0 == "kexp-1" ? station : nil })?.key, "kexp")
        XCTAssertNil(AlignmentProfiles.profile(for: shim, mode: .on, stationLookup: { _ in nil }))
    }

    func testKCRWPlaysItsMeasuredStreamAndKEXPPlaysItsOwn() {
        XCTAssertEqual(AlignmentProfiles.kcrw.streamOverride, KCRWAlignmentConfiguration.measuredEndpoint)
        XCTAssertNil(AlignmentProfiles.kexp.streamOverride)
    }

    func testTheProfilesDifferInClockAndSeed() {
        XCTAssertEqual(AlignmentProfiles.kcrw.clock, .programDate)
        XCTAssertEqual(AlignmentProfiles.kcrw.seedSkew, 160)
        XCTAssertEqual(AlignmentProfiles.kexp.clock, .mediaTime)
        XCTAssertEqual(AlignmentProfiles.kexp.seedSkew, 0)
    }

    // MARK: The skew key

    func testEveryListEntryForOneStreamSharesOneSkew() {
        // Seen on the device: the KCRW MP3 entry started at the seed, not at the skew saved for the AAC entry.
        let registry = RadioStationRegistry.shared
        let mp3 = radio("KCRW Eclectic 24", "https://streams.kcrw.com/e24_mp3", id: "test-kcrw-mp3")
        let aac = radio("KCRW Eclectic 24", "https://streams.kcrw.com/e24_aac", id: "test-kcrw-aac")
        let kexp = radio("KEXP", "https://kexp.streamguys1.com/kexp160.aac", id: "test-kexp")
        [mp3, aac, kexp].forEach(registry.register)
        defer { ["test-kcrw-mp3", "test-kcrw-aac", "test-kexp"].forEach(registry.remove(uuid:)) }

        XCTAssertEqual(AlignmentSkewStore.productionKey("test-kcrw-mp3"), "kcrw-e24")
        XCTAssertEqual(AlignmentSkewStore.productionKey("test-kcrw-aac"), "kcrw-e24")
        XCTAssertEqual(AlignmentSkewStore.productionKey("test-kexp"), "kexp")
        XCTAssertEqual(AlignmentSkewStore.productionKey("unknown-station"), "unknown-station", "an unknown station keeps its own id")
    }

    func testTheSeedFollowsTheKey() {
        XCTAssertEqual(AlignmentSkewStore.productionSeed("kcrw-e24"), 160)
        XCTAssertEqual(AlignmentSkewStore.productionSeed("kexp"), 0)
        XCTAssertEqual(AlignmentSkewStore.productionSeed("anything-else"), 0)
    }

    func testTwoEntriesWithOneKeyReadAndWriteOneSkew() {
        let suite = "AlignmentProfileTests.shared"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AlignmentSkewStore(defaults: defaults, seed: { $0 == "kcrw-e24" ? 160 : 0 },
                                       key: { $0.hasPrefix("kcrw") ? "kcrw-e24" : $0 }, center: NotificationCenter())
        XCTAssertEqual(store.skew(for: "kcrw-aac"), 160)
        store.set(156.8, for: "kcrw-aac")
        XCTAssertEqual(store.skew(for: "kcrw-mp3"), 156.8, "the other entry reads the skew the first one saved")
        XCTAssertEqual(store.nudge(by: 0.5, for: "kcrw-mp3"), 157.3)
        XCTAssertEqual(store.skew(for: "kcrw-aac"), 157.3)
        XCTAssertEqual(store.skew(for: "kexp-1"), 0, "another stream is separate")
        store.reset(stationId: "kcrw-mp3")
        XCTAssertEqual(store.skew(for: "kcrw-aac"), 160)
    }
}

// MARK: - KEXP's feed

final class KEXPFeedDecoderTests: XCTestCase {
    private let sample = """
    {"next": null, "previous": null, "results": [
      {"id": 3719533, "airdate": "2026-10-14T17:13:46-07:00", "image_uri": "", "thumbnail_uri": "", "play_type": "airbreak"},
      {"id": 3719532, "airdate": "2026-10-14T17:10:39-07:00",
       "image_uri": "https://coverartarchive.org/release/81d/251-500.jpg?x=1", "thumbnail_uri": "https://coverartarchive.org/release/81d/251-250.jpg",
       "song": "It\u{2019}s a Shame", "artist": "The Spinners", "album": "2nd Time Around", "play_type": "trackplay"},
      {"id": 3719531, "airdate": "2026-10-14T17:07:38.250-07:00", "thumbnail_uri": "https://example.test/t.jpg",
       "song": "VHS", "artist": "The Physics", "play_type": "trackplay"},
      {"id": 3719530, "airdate": "2026-10-14T17:04:33-07:00", "play_type": "mystery"},
      {"id": 3719529, "play_type": "trackplay", "song": "", "artist": ""}
    ]}
    """

    private func decode(_ string: String) throws -> [OccurrenceInput] {
        try KEXPFeedDecoder.decode(Data(string.utf8))
    }

    func testKeepsRowsInSourceOrderWithTheirKinds() throws {
        let rows = try decode(sample)
        XCTAssertEqual(rows.map(\.providerID), ["3719533", "3719532", "3719531", "3719530", "3719529"])
        XCTAssertEqual(rows.map(\.kind), ["break", "trackplay", "trackplay", "unknown", "unknown"])
        XCTAssertTrue(rows.allSatisfy { $0.station == "kexp" })
    }

    func testReadsTitleArtistAlbumArtworkAndTime() throws {
        let rows = try decode(sample)
        XCTAssertEqual(rows[1].title, "It\u{2019}s a Shame")
        XCTAssertEqual(rows[1].artist, "The Spinners")
        XCTAssertEqual(rows[1].album, "2nd Time Around")
        XCTAssertEqual(rows[1].artworkURL, "https://coverartarchive.org/release/81d/251-500.jpg", "the large image, query stripped")
        XCTAssertEqual(rows[2].artworkURL, "https://example.test/t.jpg", "falls back to the thumbnail")
        XCTAssertNil(rows[0].artworkURL)
        let iso = ISO8601DateFormatter()
        XCTAssertEqual(rows[1].playedAt, iso.date(from: "2026-10-14T17:10:39-07:00"))
        XCTAssertEqual(rows[2].playedAt?.timeIntervalSince1970 ?? 0,
                       (iso.date(from: "2026-10-14T17:07:38-07:00")?.timeIntervalSince1970 ?? 0) + 0.25, accuracy: 0.0001)
        XCTAssertNil(rows[4].playedAt)
    }

    func testABadShapeThrows() {
        XCTAssertThrowsError(try decode("[]"))
        XCTAssertThrowsError(try decode("{\"results\": 3}"))
        XCTAssertThrowsError(try decode("{\"results\": [1]}"))
        XCTAssertThrowsError(try decode("not json"))
        XCTAssertThrowsError(try decode("{\"results\": [{\"id\": true}]}"))
    }

    func testTheClientDecodesWithTheKEXPDecoderAndURL() async {
        let response = HTTPURLResponse(url: AlignmentFeedClient.kexpURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
        var requested: URL?
        let client = AlignmentFeedClient(url: AlignmentFeedClient.kexpURL, decode: KEXPFeedDecoder.decode,
                                         fetchData: { request in requested = request.url; return (Data(self.sample.utf8), response) })
        let result = await client.fetch()
        XCTAssertNil(result.failure)
        XCTAssertEqual(result.entries.count, 5)
        XCTAssertEqual(requested, AlignmentFeedClient.kexpURL)
    }
}
