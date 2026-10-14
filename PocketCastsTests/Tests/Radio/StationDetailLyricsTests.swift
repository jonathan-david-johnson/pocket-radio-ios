#if !os(watchOS) && !APPCLIP && !os(tvOS)
import MediaPlayer
import XCTest
@testable import podcasts

/// Station detail's lyrics when aligned: the aligned song, one clock and one skew that survive
/// opening full-screen lyrics. The loader, the ticks and the saved-offset store are fakes; the
/// aligned state is in memory. Nothing touches the network, `UserDefaults.standard` or `lyric_offsets`.
@MainActor
final class StationDetailLyricsTests: XCTestCase {
    private final class Loader: @unchecked Sendable {
        private let lock = NSLock()
        private var titles: [String] = []
        var requested: [String] { lock.withLock { titles } }
        func load(artist: String, title: String, album: String?) async -> LyricsResult? {
            lock.withLock { titles.append(title) }
            return LyricsResult(lines: [LyricLine(timestamp: 0, text: "Line 1"),
                                        LyricLine(timestamp: 5, text: "Line 2"),
                                        LyricLine(timestamp: 12, text: "Line 3")], plain: nil, duration: 100)
        }
    }

    /// Saved skews for the test, so nothing reads or writes the device's real ones.
    private final class SkewBox {
        private(set) var values: [String: Double] = [:]
        private(set) var nudges: [Double] = []
        var adjuster: SkewAdjuster {
            SkewAdjuster(current: { [self] in values[$0] ?? 160 },
                         nudge: { [self] id, delta in
                             nudges.append(delta)
                             values[id] = (values[id] ?? 160) + delta
                             return values[id] ?? 160
                         })
        }
    }

    private final class Ticks {
        private(set) var started = 0
        private(set) var cancelled = 0
        private var handler: (() -> Void)?
        private var active = false
        var isRunning: Bool { active }
        func schedule(_ handler: @escaping () -> Void) -> () -> Void {
            started += 1
            self.handler = handler
            active = true
            return { [weak self] in self?.cancelled += 1; self?.active = false }
        }
        func fire() { if active { handler?() } }
    }

    private let applying = "kcrw-lyrics-station"
    private let other = "other-lyrics-station"
    private let generation = UUID()
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private var loader = Loader()
    private var skews = SkewBox()
    private var ticks = Ticks()
    private var savedInfo: [String: Any]?
    private var navs: [UINavigationController] = []

    override func setUp() {
        super.setUp()
        savedInfo = MPNowPlayingInfoCenter.default().nowPlayingInfo
        RadioTracklistService.shared._resetForTesting()
        AlignedNowPlayingState.shared.beginApplying(stationId: applying, generation: generation)
    }

    override func tearDown() {
        navs.forEach { NotificationCenter.default.removeObserver($0.viewControllers.first as Any) }
        navs = []
        AlignedNowPlayingState.shared.endApplying(stationId: applying, generation: generation)
        RadioTracklistService.shared._resetForTesting()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = savedInfo
        super.tearDown()
    }

    // MARK: Helpers

    private func entry(_ title: String, at: TimeInterval) -> TracklistEntry {
        TracklistEntry(title: title, artist: "Artist", album: nil, albumArtURL: nil, playedAt: base.addingTimeInterval(at))
    }

    private func publishSong(_ title: String, occ: String, at: TimeInterval) {
        let song = AlignedSong(stationId: applying, occurrenceID: occ, title: title, artist: "Artist", album: nil,
                               artworkURL: nil, generation: generation, playedAt: base.addingTimeInterval(at))
        XCTAssertTrue(AlignedNowPlayingState.shared.publish(.song(song), stationId: applying, generation: generation))
    }

    private func samplePosition(_ seconds: Double, occ: String) {
        AlignedNowPlayingState.shared.recordSongSample(occurrenceID: occ, songSeconds: seconds, playing: false,
                                                       stationId: applying, generation: generation)
    }

    private func postAligned(stationId: String? = nil) async {
        NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil, userInfo: [
            RadioMetadataNotificationKey.stationId: stationId ?? applying,
            RadioMetadataNotificationKey.title: "",
            RadioMetadataNotificationKey.artist: "",
            RadioMetadataNotificationKey.aligned: true
        ])
        // The screen reacts on the next main-queue turn; a nested run loop would not let it run.
        try? await Task.sleep(nanoseconds: 200_000_000)
    }

    private func makeDetail(_ stationId: String) -> (vc: StationDetailViewController, lyrics: LyricSyncController) {
        let lyrics = LyricSyncController(
            stationId: stationId, stationDisplayTitle: "KCRW",
            loader: { [loader] artist, title, album in await loader.load(artist: artist, title: title, album: album) },
            scheduleTicks: { [ticks] in ticks.schedule($0) },
            skew: skews.adjuster)
        let station = RadioStation(stationId: stationId, name: "KCRW", streamUrl: "https://example.test/stream")
        let vc = StationDetailViewController(station: station, lyricSync: lyrics)
        let nav = UINavigationController(rootViewController: vc)
        nav.loadViewIfNeeded()
        vc.loadViewIfNeeded()
        navs.append(nav)
        return (vc, lyrics)
    }

    private func seedFeed(_ stationId: String, _ entries: [TracklistEntry]) {
        RadioTracklistService.shared._seedCacheForTesting(stationId: stationId, entries: entries)
    }

    // MARK: Which song the lyrics are for

    func testApplyLoadsTheAlignedSongNotTheFeedTop() async {
        seedFeed(applying, [entry("Feed Top", at: 300), entry("Aligned", at: 200)])
        publishSong("Aligned", occ: "occ-1", at: 200)
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        XCTAssertEqual(loader.requested, ["Aligned"])
        XCTAssertEqual(lyrics.currentOccurrenceID, "occ-1")
    }

    func testApplyReloadsWhenTheAlignedSongChanges() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        publishSong("Song B", occ: "occ-2", at: 200)
        await postAligned()
        await lyrics.waitForFetch()

        XCTAssertEqual(loader.requested, ["Song A", "Song B"])
        XCTAssertEqual(lyrics.currentOccurrenceID, "occ-2")
    }

    func testApplyReloadsARepeatPlayOfTheSameSong() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        publishSong("Song A", occ: "occ-2", at: 400)
        await postAligned()
        await lyrics.waitForFetch()

        XCTAssertEqual(loader.requested, ["Song A", "Song A"])
        XCTAssertEqual(lyrics.currentOccurrenceID, "occ-2")
    }

    func testApplyUnavailableShowsNoLyricsAndNoTimedHighlight() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        XCTAssertTrue(lyrics.hasLyrics)
        XCTAssertTrue(ticks.isRunning)

        XCTAssertTrue(AlignedNowPlayingState.shared.publish(.unavailable(stationId: applying, reason: "no clock"),
                                                            stationId: applying, generation: generation))
        await postAligned()

        XCTAssertFalse(lyrics.hasLyrics)
        XCTAssertNil(lyrics.currentOccurrenceID)
        XCTAssertFalse(ticks.isRunning)
    }

    func testApplyWithNoSongYetLoadsNothing() async {
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        XCTAssertEqual(loader.requested, [])
        XCTAssertFalse(lyrics.hasLyrics)
    }

    func testComingBackMidSongReloadsWhenTheControllerHasNone() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        lyrics.stop()
        XCTAssertFalse(lyrics.hasLyrics)

        vc.viewWillAppear(false)
        await lyrics.waitForFetch()

        XCTAssertTrue(lyrics.hasLyrics)
        XCTAssertEqual(lyrics.currentOccurrenceID, "occ-1")
    }

    func testANudgeMovesOnlyTheStationSkew() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        samplePosition(1, occ: "occ-1")
        let (_, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        lyrics.adjustOffset(by: 0.5)

        XCTAssertEqual(skews.values, [applying: 159.5])
    }

    // MARK: Leaving station detail

    func testApplyKeepsTheClockAndSkewWhileFullScreenLyricsIsOpen() async throws {
        seedFeed(applying, [entry("Feed Top", at: 300), entry("Aligned", at: 200)])
        publishSong("Aligned", occ: "occ-1", at: 200)
        samplePosition(6, occ: "occ-1")
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        lyrics.adjustOffset(by: 0.5)
        let before = lyrics.alignedPosition()

        vc._selectRowForTesting(1)
        vc.viewDidDisappear(false)   // what pushing a full-screen screen does to the screen beneath it

        XCTAssertEqual(before, 6)
        XCTAssertTrue(ticks.isRunning, "no second timer and the first one keeps running")
        XCTAssertEqual(ticks.started, 1)
        XCTAssertEqual(lyrics.currentSkew, 159.5)
        XCTAssertEqual(lyrics.alignedPosition(), 6)
        XCTAssertEqual(lyrics.currentOccurrenceID, "occ-1")
    }

    func testApplyStopsWhenLeavingWithNoFullScreenLyricsOpen() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        samplePosition(6, occ: "occ-1")
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        vc.viewDidDisappear(false)

        XCTAssertFalse(ticks.isRunning)
        XCTAssertNil(lyrics.alignedPosition())
        XCTAssertFalse(lyrics.hasLyrics)
    }

    func testStationDetailDeallocationStopsTheClock() async {
        publishSong("Song A", occ: "occ-1", at: 100)
        let lyrics: LyricSyncController
        do {
            let made = makeDetail(applying)
            lyrics = made.lyrics
            await lyrics.waitForFetch()
            XCTAssertTrue(ticks.isRunning)
            made.vc._selectRowForTesting(0)
            navs.removeAll()
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(ticks.isRunning, "a screen that goes away while full-screen lyrics was open must not leak the timer")
    }

    func testOffAndObserveStillStopOnDisappear() async {
        seedFeed(other, [entry("Feed Top", at: 300)])
        let (vc, lyrics) = makeDetail(other)
        vc._reloadLyricsForTesting()
        await lyrics.waitForFetch()
        XCTAssertEqual(lyrics.currentSongKey, "artist|feed top")

        vc._selectRowForTesting(0)
        vc.viewDidDisappear(false)

        XCTAssertNil(lyrics.currentSongKey)
        XCTAssertFalse(ticks.isRunning)
        XCTAssertNil(lyrics.currentOccurrenceID)
    }

    // MARK: Opening full-screen lyrics

    func testApplyOpensTheAlignedRowWithTheSharedClock() async throws {
        seedFeed(applying, [entry("Feed Top", at: 300), entry("Aligned", at: 200)])
        publishSong("Aligned", occ: "occ-1", at: 200)
        samplePosition(6, occ: "occ-1")
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        vc._selectRowForTesting(1)
        let nav = try XCTUnwrap(vc.navigationController)
        let lyricsScreen = try XCTUnwrap(nav.topViewController as? LyricsViewController)

        XCTAssertTrue(lyricsScreen._isCurrentSongForTesting)
        let clock = try XCTUnwrap(lyricsScreen.alignedClock)
        XCTAssertEqual(clock.occurrenceID, "occ-1")
        XCTAssertEqual(clock.position(), 6)
    }

    func testApplyOpensTheFeedTopRowAsNotCurrentWithNoClock() async throws {
        seedFeed(applying, [entry("Feed Top", at: 300), entry("Aligned", at: 200)])
        publishSong("Aligned", occ: "occ-1", at: 200)
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()

        vc._selectRowForTesting(0)
        let lyricsScreen = try XCTUnwrap(vc.navigationController?.topViewController as? LyricsViewController)

        XCTAssertFalse(lyricsScreen._isCurrentSongForTesting)
        XCTAssertNil(lyricsScreen.alignedClock)
        XCTAssertEqual(lyricsScreen._initialOffsetForTesting, 0)
    }

    func testOffOpensRowZeroOnTheWallClockAsBefore() async throws {
        seedFeed(other, [entry("Feed Top", at: 300), entry("Older", at: 200)])
        let (vc, lyrics) = makeDetail(other)
        vc._reloadLyricsForTesting()
        await lyrics.waitForFetch()

        vc._selectRowForTesting(0)
        let lyricsScreen = try XCTUnwrap(vc.navigationController?.topViewController as? LyricsViewController)
        XCTAssertTrue(lyricsScreen._isCurrentSongForTesting)
        XCTAssertNil(lyricsScreen.alignedClock)
    }

    func testTheFullScreenNudgeMovesTheStationSkew() async throws {
        seedFeed(applying, [entry("Aligned", at: 200)])
        publishSong("Aligned", occ: "occ-1", at: 200)
        samplePosition(6, occ: "occ-1")
        let (vc, lyrics) = makeDetail(applying)
        await lyrics.waitForFetch()
        vc._selectRowForTesting(0)
        let lyricsScreen = try XCTUnwrap(vc.navigationController?.topViewController as? LyricsViewController)

        let clock = try XCTUnwrap(lyricsScreen.alignedClock)
        XCTAssertEqual(clock.adjust(0.5), 159.5)

        XCTAssertEqual(lyrics.currentSkew, 159.5)
        XCTAssertEqual(skews.values, [applying: 159.5])
    }
}
#endif
