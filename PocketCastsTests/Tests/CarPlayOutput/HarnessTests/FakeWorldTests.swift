import Kingfisher
import XCTest
@testable import podcasts

final class FakeWorldTests: XCTestCase {
    private var world: FakeWorld!

    private var originalTimeout: TimeInterval = 0

    override func setUpWithError() throws {
        originalTimeout = KingfisherManager.shared.downloader.downloadTimeout
        world = try FakeWorld()
        try world.start()
    }

    override func tearDown() {
        world.stop()
        world = nil
    }

    private func get(_ urlString: String) async throws -> (Data, HTTPURLResponse) {
        let (data, response) = try await URLSession.shared.data(from: URL(string: urlString)!)
        return (data, response as! HTTPURLResponse)
    }

    private let red = FakeWorld.FakeSong(title: "Red Song", artist: "Red Artist", album: "Red Album", art: "red")
    private let nullArt = FakeWorld.FakeSong(title: "Quiet Song", artist: "Quiet Artist", album: "Quiet Album", art: nil, itunesArt: "green")
    private let blue = FakeWorld.FakeSong(title: "Blue Song", artist: "Blue Artist", album: "Blue Album", art: "blue")

    // BEHAVIOR 2: the real parser and resolver read the fake's tracklist and iTunes fixtures.
    func testTracklistContractParsesScriptedEntriesAndSkipsBreak() async throws {
        let songs = [red, nullArt, blue]
        world.setTracklist(songs, includeBreakRow: true)
        let station = try world.makeStation()
        let entries = try await RadioTracklistService(urlSession: .shared)
            .fetch(stationId: station.stationId, url: station.tracklistUrl!)

        XCTAssertEqual(entries.count, 3, "BREAK row must be omitted: \(entries)")
        // BREAK occupies row 0, so scripted song i is at row i + 1.
        for (i, s) in songs.enumerated() {
            XCTAssertEqual(entries[i].title, s.title)
            XCTAssertEqual(entries[i].artist, s.artist)
            XCTAssertEqual(entries[i].album, s.album)
            XCTAssertEqual(entries[i].playedAt, FakeWorld.playedAt(index: i + 1))
            if s.art == nil {
                XCTAssertNil(entries[i].albumArtURL)
            } else {
                XCTAssertEqual(entries[i].albumArtURL?.host, "127.0.0.1")
            }
        }

        let resolver = TrackArtworkResolver(session: .shared) // the resolver's callback holds self weakly: keep it alive
        let url: URL? = await withCheckedContinuation { c in
            resolver.artworkURL(for: entries[1], station: station) { c.resume(returning: $0) }
        }
        withExtendedLifetime(resolver) {}
        XCTAssertEqual(url?.host, "127.0.0.1")
        XCTAssertTrue(url?.path.hasSuffix("green-600x600bb.png") ?? false, "got \(String(describing: url))")
        XCTAssertFalse(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "song" })?.value?.isEmpty ?? true, "artwork URLs carry song identity")
    }

    func testITunesReturnsEmptyResultWhenNothingMatches() async throws {
        world.setTracklist([red])
        let url = TrackArtworkResolver.itunesSearchURL(artist: "Nobody", title: "Nothing")!
        let (data, _) = try await get(url.absoluteString)
        XCTAssertNil(TrackArtworkResolver.parseITunesArtworkURL(from: data))
    }

    // BEHAVIOR 3: rewrite. Requests to real hosts reach the fake.
    func testTracklistAndITunesRequestsAreServedByTheFake() async throws {
        world.setTracklist([red])
        let (body, resp) = try await get("https://tracklist-api.kcrw.com/Music/all/1?page_size=10")
        XCTAssertEqual(resp.statusCode, 200)
        XCTAssertTrue(String(decoding: body, as: UTF8.self).contains("Red Song"))

        let (_, resp2) = try await get("https://itunes.apple.com/search?term=x&entity=song&limit=1")
        XCTAssertEqual(resp2.statusCode, 200)

        XCTAssertEqual(world.served.map(\.host), ["tracklist-api.kcrw.com", "itunes.apple.com"])
        XCTAssertNil(world.unexpectedRequestReport())
    }

    func testKingfisherLoadsWorldArtwork() async throws {
        world.setTracklist([blue])
        let entries = try await RadioTracklistService(urlSession: .shared)
            .fetch(stationId: "kf", url: FakeWorld.kcrwTracklistURL)
        let artURL = try XCTUnwrap(entries.first?.albumArtURL)
        let image = try await withCheckedThrowingContinuation { (c: CheckedContinuation<UIImage, Error>) in
            KingfisherManager.shared.retrieveImage(
                with: artURL,
                options: [.forceRefresh, .targetCache(ImageCache(name: "fakeworld-\(UUID().uuidString)"))]
            ) { result in c.resume(with: result.map(\.image)) }
        }
        XCTAssertEqual(ImageProbe.name(of: image), "blue")
    }

    // BEHAVIOR 4: anything else is blocked and reported.
    func testUnknownHostIsBlockedFromURLSessionAndKingfisher() async throws {
        XCTAssertNil(world.unexpectedRequestReport())
        do {
            _ = try await get("https://example.invalid/x")
            XCTFail("request should have been blocked")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("Harness blocked request to host example.invalid"), "\(error.localizedDescription)")
        }
        let kfFailed = await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            KingfisherManager.shared.retrieveImage(
                with: URL(string: "https://example.invalid/y.png")!,
                options: [.forceRefresh, .targetCache(ImageCache(name: "fakeworld-\(UUID().uuidString)"))]
            ) { result in
                if case .failure = result { c.resume(returning: true) } else { c.resume(returning: false) }
            }
        }
        XCTAssertTrue(kfFailed)
        let report = try XCTUnwrap(world.unexpectedRequestReport())
        XCTAssertTrue(report.contains("example.invalid"))
        XCTAssertTrue(report.contains("/x"))
        XCTAssertTrue(report.contains("/y.png"))
    }

    // Control API
    func testLatencyDelaysTracklistResponse() async throws {
        world.setLatency(.tracklist, seconds: 1.0)
        let start = Date()
        _ = try await get(FakeWorld.kcrwTracklistURL)
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.9)
    }

    func testFailAndClearFailures() async throws {
        world.setTracklist([red])
        let service = RadioTracklistService(urlSession: .shared)
        world.fail(.tracklist, status: 500)
        do {
            _ = try await service.fetch(stationId: "f", url: FakeWorld.kcrwTracklistURL)
            XCTFail("expected throw")
        } catch RadioTracklistError.http(let code) {
            XCTAssertEqual(code, 500)
        }
        world.clearFailures()
        let entries = try await service.fetch(stationId: "f", url: FakeWorld.kcrwTracklistURL)
        XCTAssertEqual(entries.count, 1)
    }

    func testStationMustBeLoopback() throws {
        XCTAssertThrowsError(try world.makeStation(streamUrl: "http://stream.kcrw.com/live")) {
            XCTAssertTrue("\($0)".contains("non-loopback"))
        }
        let station = try world.makeStation()
        XCTAssertEqual(station.streamUrl, "http://127.0.0.1:\(world.icy.port)/stream")
        XCTAssertEqual(station.stationId, "6238f5e8-a9ee-4c88-9713-2d1ab4112ac9")
    }

    func testPlaySetsUnspacedKCRWTitle() {
        XCTAssertEqual(FakeWorld.icyTitle(red), "Red Song-Red Artist-Red Album")
    }

    func testStopUninstallsAndIsIdempotent() {
        XCTAssertTrue(NetworkGuard.isInstalled)
        XCTAssertEqual(KingfisherManager.shared.downloader.downloadTimeout, 60)
        world.stop()
        world.stop()
        XCTAssertFalse(NetworkGuard.isInstalled)
        XCTAssertEqual(KingfisherManager.shared.downloader.downloadTimeout, originalTimeout, "stop() restores the Kingfisher timeout")
        XCTAssertFalse((KingfisherManager.shared.downloader.sessionConfiguration.protocolClasses ?? []).contains { $0 == NetworkGuard.self })
    }

    // Opus review finding 1: a delayed fixture must not outlive its world and refill a later scenario's cache.
    func testDelayedResponseIsDroppedAfterStop() async throws {
        world.setTracklist([red])
        world.setLatency(.tracklist, seconds: 0.8)
        let service = RadioTracklistService(urlSession: .shared)
        let url = "https://tracklist-api.kcrw.com/Music/all/1?page_size=10"
        let task = Task { try await service.fetch(stationId: "late-station", url: url) }
        try await Task.sleep(nanoseconds: 200_000_000)
        world.stop()
        do {
            _ = try await task.value
            XCTFail("a response delivered after stop() must be dropped")
        } catch {
            // expected: the request fails instead of being served late
        }
        XCTAssertNil(service.cached(stationId: "late-station"))
    }
}
