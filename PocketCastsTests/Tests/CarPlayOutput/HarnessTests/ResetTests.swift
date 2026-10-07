import XCTest
@testable import podcasts

/// Behavior 5: scenario results do not depend on what ran before, because `HarnessReset` clears
/// process-wide state. Real playback through the real app; only the outside world is fake.
final class ResetTests: HarnessScenarioCase {
    private let songA = FakeWorld.FakeSong(title: "Song A", artist: "Artist A", album: "Album A", art: "red")
    /// X: B has no tracklist art, so artwork comes from the iTunes fixture.
    private let songBViaITunes = FakeWorld.FakeSong(title: "Song B", artist: "Artist B", album: "Album B", art: nil, itunesArt: "blue")
    /// Y: B's tracklist row carries green art directly.
    private let songBGreen = FakeWorld.FakeSong(title: "Song B", artist: "Artist B", album: "Album B", art: "green", itunesArt: "blue")

    private enum Kind: String { case x = "X", y = "Y" }

    private func play(_ station: RadioStation) {
        RadioPlaybackStarter.shared.play(station: station, source: .unknown, prefetchTracklist: true, republishWidgetState: false)
    }

    /// Runs one scenario on a fresh world. Returns the final artwork name (nil if it never matched), leaving state dirty.
    private func run(_ kind: Kind, file: StaticString = #filePath, line: UInt = #line) throws -> String? {
        let w = try FakeWorld(initial: kind == .x ? songA : songBGreen)
        try w.start()
        defer { w.stop() }
        let expected: String
        switch kind {
        case .x:
            w.setTracklist([songA, songBViaITunes]); expected = "blue"; w.setLatency(.tracklist, seconds: 2)
        case .y:
            w.setTracklist([songBGreen]); expected = "green"; w.setLatency(.tracklist, seconds: 2)
        }
        let station = try w.makeStation()
        play(station)
        let pm = PlaybackManager.shared
        XCTAssertTrue(spin(timeout: 30) { pm.isPlaying && !pm.isBuffering && pm.currentTime() > 1 }, "\(kind.rawValue): not playing in 30 s", file: file, line: line)
        if kind == .x {
            XCTAssertTrue(NowPlayingProbe.requireWaitUntil(.init(title: "Song A"), timeout: 45, file: file, line: line))
            w.play(songBViaITunes)
            NowPlayingProbe.requireWaitUntil(.init(title: "Song B"), timeout: 45, file: file, line: line)
        } else {
            NowPlayingProbe.requireWaitUntil(.init(title: "Song B"), timeout: 45, file: file, line: line)
        }
        let outcome = NowPlayingProbe.waitUntil(.init(artwork: expected), timeout: 8)
        if let m = outcome.failureMessage { XCTFail("\(kind.rawValue) expected \(expected): \(m)", file: file, line: line) }
        let art = NowPlayingProbe.snapshot().artwork
        XCTAssertEqual(art, expected, "\(kind.rawValue) artwork", file: file, line: line)
        XCTAssertNil(w.unexpectedRequestReport(), file: file, line: line)
        return art
    }

    func test_orderIndependence_XY_YX_XX_YY() throws {
        let orders: [[Kind]] = [[.x, .y], [.y, .x], [.x, .x], [.y, .y]]
        for order in orders {
            var results: [String?] = []
            for kind in order {
                HarnessReset.fullReset()
                results.append(try run(kind))
            }
            HarnessReset.fullReset()
            let label = order.map(\.rawValue).joined()
            HarnessLog.write("m13_1_reset.log", "ORDER \(label): \(results.map { $0 ?? "nil" })")
            XCTAssertEqual(results, order.map { $0 == .x ? "blue" : "green" }, "order \(label)")
        }
        XCTAssertFalse(NetworkGuard.isInstalled, "guard must be uninstalled")
    }

    func test_isClean_afterReset_dirtyAfterScenario_summaryNamesDirtyFields() throws {
        HarnessReset.fullReset()
        XCTAssertTrue(HarnessReset.isClean, HarnessReset.stateSummary())
        XCTAssertTrue(HarnessReset.stateSummary().hasSuffix("dirty=[]"), HarnessReset.stateSummary())

        _ = try run(.x)
        XCTAssertFalse(HarnessReset.isClean)
        let summary = HarnessReset.stateSummary()
        for field in ["currentEpisode", "registry", "lastResolvedRadioKey", "artworkResolverCurrentKey", "radioTrackStationId", "nowPlayingInfo"] {
            XCTAssertTrue(summary.contains("dirty=[") && summary.components(separatedBy: "dirty=[")[1].contains(field), "\(field) not named dirty in: \(summary)")
        }

        HarnessReset.fullReset()
        XCTAssertTrue(HarnessReset.isClean, HarnessReset.stateSummary())
    }
}
