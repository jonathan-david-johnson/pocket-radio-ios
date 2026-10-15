#if !os(watchOS) && !APPCLIP && !os(tvOS)
import XCTest
@testable import podcasts

// MARK: - Fakes

/// Records every call. Results are returned at once, or held until `release` for a gated title.
private final class FakeLyricLoader: @unchecked Sendable {
    struct Request: Equatable {
        let artist: String
        let title: String
        let album: String?
    }

    private let lock = NSLock()
    private var recorded: [Request] = []
    private var results: [String: LyricsResult] = [:]
    private var gatedTitles: Set<String> = []
    private var waiting: [(title: String, continuation: CheckedContinuation<LyricsResult?, Never>)] = []

    var requests: [Request] { lock.withLock { recorded } }

    func set(_ result: LyricsResult?, forTitle title: String) {
        lock.withLock { results[title] = result }
    }

    func gate(title: String) {
        lock.withLock { _ = gatedTitles.insert(title) }
    }

    func release(title: String, with result: LyricsResult?) {
        let match: CheckedContinuation<LyricsResult?, Never>? = lock.withLock {
            guard let index = waiting.firstIndex(where: { $0.title == title }) else { return nil }
            return waiting.remove(at: index).continuation
        }
        match?.resume(returning: result)
    }

    func load(artist: String, title: String, album: String?) async -> LyricsResult? {
        let isGated: Bool = lock.withLock {
            recorded.append(Request(artist: artist, title: title, album: album))
            return gatedTitles.contains(title)
        }
        if isGated {
            return await withCheckedContinuation { continuation in
                lock.withLock { waiting.append((title, continuation)) }
            }
        }
        return lock.withLock { results[title] }
    }

    func waitUntilRequested(_ count: Int) async {
        for _ in 0..<400 where requests.count < count {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private final class FakeOffsetStore: LyricOffsetStore, @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String: Int]
    private var fetches = 0
    private var reads = 0
    private var saves: [(stationId: String, seconds: Int)] = []

    init(saved: [String: Int] = [:]) { stored = saved }

    var fetchCount: Int { lock.withLock { fetches } }
    var readCount: Int { lock.withLock { reads } }
    var saved: [(stationId: String, seconds: Int)] { lock.withLock { saves } }

    func fetchOffsets() async -> [String: Int] {
        lock.withLock { fetches += 1; return stored }
    }

    func savedOffset(stationId: String) -> Int? {
        lock.withLock { reads += 1; return stored[stationId] }
    }

    func saveOffset(stationId: String, seconds: Int) async {
        lock.withLock { saves.append((stationId, seconds)) }
    }
}

/// Stands in for the saved skews. `nudge` adds to the station's skew, as the real store does.
private final class FakeSkew {
    let seed: Double
    private(set) var values: [String: Double] = [:]
    private(set) var nudges: [Double] = []

    init(seed: Double = 160) { self.seed = seed }

    func current(_ stationId: String) -> Double { values[stationId] ?? seed }

    func nudge(_ stationId: String, _ delta: Double) -> Double {
        nudges.append(delta)
        values[stationId] = current(stationId) + delta
        return values[stationId] ?? seed
    }

    var adjuster: SkewAdjuster {
        SkewAdjuster(current: { [self] in current($0) }, nudge: { [self] in nudge($0, $1) })
    }
}

private final class FakeClock {
    var now: Date
    private(set) var reads = 0
    init(_ now: Date) { self.now = now }
    func read() -> Date { reads += 1; return now }
}

private final class FakeTicks {
    private(set) var started = 0
    private(set) var cancelled = 0
    private var handler: (() -> Void)?
    private var active = false

    var isRunning: Bool { active }

    func schedule(_ handler: @escaping () -> Void) -> () -> Void {
        started += 1
        self.handler = handler
        active = true
        return { [weak self] in
            self?.cancelled += 1
            self?.active = false
        }
    }

    func fire() {
        if active { handler?() }
    }
}

private final class FakePosition {
    var value: (occurrenceID: String, seconds: Double)?
    var applying = false
    private(set) var reads = 0
    private(set) var askedStations: Set<String> = []

    func read(_ stationId: String) -> (occurrenceID: String, seconds: Double)? {
        reads += 1
        askedStations.insert(stationId)
        return applying ? value : nil
    }
}

private final class RecordingDelegate: LyricSyncControllerDelegate {
    enum Event: Equatable {
        case header(String)
        case status(LyricSyncController.LyricStatus)
        case album(String)
    }

    private(set) var events: [Event] = []

    var headers: [String] { events.compactMap { if case .header(let t) = $0 { return t } else { return nil } } }
    var albums: [String] { events.compactMap { if case .album(let t) = $0 { return t } else { return nil } } }
    var statuses: [LyricSyncController.LyricStatus] { events.compactMap { if case .status(let s) = $0 { return s } else { return nil } } }
    var lastHeader: String? { headers.last }

    func lyricSyncController(_ c: LyricSyncController, didUpdateHeaderText text: String) { events.append(.header(text)) }
    func lyricSyncController(_ c: LyricSyncController, didChangeStatus status: LyricSyncController.LyricStatus) { events.append(.status(status)) }
    func lyricSyncController(_ c: LyricSyncController, didUpdateNowPlayingAlbum text: String) { events.append(.album(text)) }
}

// MARK: - Rig

@MainActor
private final class Rig {
    static let stationId = "kcrw-eclectic24"
    static let stationTitle = "KCRW Eclectic24"
    static let epoch = Date(timeIntervalSince1970: 1_700_000_000)

    let loader = FakeLyricLoader()
    let store: FakeOffsetStore
    let skew = FakeSkew()
    let clock = FakeClock(Rig.epoch)
    let ticks = FakeTicks()
    let position = FakePosition()
    let delegate = RecordingDelegate()
    let controller: LyricSyncController

    init(savedOffsets: [String: Int] = [:], stationId: String = Rig.stationId) {
        store = FakeOffsetStore(saved: savedOffsets)
        let loader = self.loader
        let clock = self.clock
        let ticks = self.ticks
        let position = self.position
        let skew = self.skew
        controller = LyricSyncController(
            stationId: stationId,
            stationDisplayTitle: Rig.stationTitle,
            loader: { artist, title, album in await loader.load(artist: artist, title: title, album: album) },
            offsetStore: store,
            clock: { clock.read() },
            scheduleTicks: { ticks.schedule($0) },
            positionSource: { position.read($0) },
            isApplying: { _ in position.applying },
            skew: skew.adjuster
        )
        controller.delegate = delegate
    }

    func entry(_ title: String, artist: String = "Artist", album: String? = "Album", playedAt: Date? = nil) -> TracklistEntry {
        TracklistEntry(title: title, artist: artist, album: album, albumArtURL: nil, playedAt: playedAt)
    }

    static func synced(duration: TimeInterval? = nil) -> LyricsResult {
        LyricsResult(lines: [LyricLine(timestamp: 0, text: "Line 1"),
                             LyricLine(timestamp: 5, text: "Line 2"),
                             LyricLine(timestamp: 12, text: "Line 3")],
                     plain: nil, duration: duration)
    }

    /// Loads `title` and waits for its fetch to finish.
    func load(_ title: String, result: LyricsResult?, playedAt: Date? = nil, occurrenceID: String? = nil) async {
        loader.set(result, forTitle: title)
        controller.load(entry: entry(title, playedAt: playedAt), occurrenceID: occurrenceID)
        await controller.waitForFetch()
    }
}

// MARK: - Off: the wall-clock path

@MainActor
final class LyricSyncControllerWallClockTests: XCTestCase {
    func testLoadShowsFetchingAndAsksTheLoader() async {
        let rig = Rig()
        rig.loader.set(nil, forTitle: "Song")
        rig.controller.load(entry: rig.entry("Song"))

        XCTAssertEqual(rig.controller.status, .fetching)
        XCTAssertEqual(rig.delegate.events.prefix(2), [.status(.fetching), .header("Fetching…")])
        await rig.controller.waitForFetch()
        XCTAssertEqual(rig.loader.requests, [.init(artist: "Artist", title: "Song", album: "Album")])
    }

    func testNoResultIsNotFound() async {
        let rig = Rig()
        await rig.load("Song", result: nil)

        XCTAssertEqual(rig.controller.status, .notFound)
        XCTAssertEqual(rig.delegate.lastHeader, "No lyrics found")
    }

    func testPlainLyricsShowTheFirstNonEmptyLine() async {
        let rig = Rig()
        await rig.load("Song", result: LyricsResult(lines: [], plain: "\n  \nFirst words\nSecond"))

        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ First words")
        XCTAssertEqual(rig.ticks.started, 0)
    }

    func testSyncedLyricsStartFromPlayedAtOnTheWallClock() async {
        let rig = Rig()
        // Played 6 s ago: Line 2 (5 s) is current.
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch.addingTimeInterval(-6))

        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 2")
        XCTAssertEqual(rig.delegate.albums, ["Line 2"])
        XCTAssertEqual(rig.controller.lyricStartDate, Rig.epoch.addingTimeInterval(-6))
        XCTAssertEqual(rig.ticks.started, 1)
    }

    func testWithoutPlayedAtTheStartIsNow() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100))

        XCTAssertEqual(rig.controller.lyricStartDate, Rig.epoch)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 1")
    }

    func testTickFollowsTheWallClock() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)

        rig.clock.now = Rig.epoch.addingTimeInterval(5)
        rig.ticks.fire()
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 2")

        rig.clock.now = Rig.epoch.addingTimeInterval(13)
        rig.ticks.fire()
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 3")
        XCTAssertEqual(rig.delegate.albums, ["Line 1", "Line 2", "Line 3"])
    }

    func testSavedOffsetIsReadOnLoadAndShiftsTheLine() async {
        let rig = Rig(savedOffsets: [Rig.stationId: 6])
        // 6 s saved offset on a 0 s elapsed: position 6 is Line 2.
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)

        XCTAssertEqual(rig.store.fetchCount, 1)
        XCTAssertEqual(rig.store.readCount, 1)
        XCTAssertEqual(rig.controller.lyricOffset, 6)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 2")
    }

    func testIntroWindowShowsStationUntilTheFirstLine() async {
        let rig = Rig()
        let lines = LyricsResult(lines: [LyricLine(timestamp: 20, text: "Late"), LyricLine(timestamp: 30, text: "Later")],
                                 plain: nil, duration: 100)
        await rig.load("Song", result: lines, playedAt: Rig.epoch)

        XCTAssertEqual(rig.controller.status, .betweenTracks)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ \(Rig.stationTitle)")
        XCTAssertEqual(rig.delegate.albums, ["Album"], "off Apply, the album falls back to the entry album")

        // Inside the 3 s intro grace but before the first line: nothing changes.
        rig.clock.now = Rig.epoch.addingTimeInterval(18)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks)

        rig.clock.now = Rig.epoch.addingTimeInterval(20)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Late")
    }

    func testEndWindowUsesDurationPlusGrace() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)

        rig.clock.now = Rig.epoch.addingTimeInterval(112)
        rig.ticks.fire()
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 3")

        rig.clock.now = Rig.epoch.addingTimeInterval(113)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ \(Rig.stationTitle)")
    }

    func testEndWindowWithoutDurationIsLastLinePlusTwiceTheGrace() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(), playedAt: Rig.epoch)

        rig.clock.now = Rig.epoch.addingTimeInterval(36)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .found)

        rig.clock.now = Rig.epoch.addingTimeInterval(37)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks)
    }

    func testTheSameSongIsNotReloaded() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100))
        await rig.load("Song", result: Rig.synced(duration: 100))
        XCTAssertEqual(rig.loader.requests.count, 1)

        await rig.load("Other", result: nil)
        XCTAssertEqual(rig.loader.requests.count, 2)
        XCTAssertEqual(rig.controller.currentSongKey, "artist|other")
    }

    func testAdjustOffsetMovesTheLineAtOnceAndSavesAfterTheDebounce() async throws {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 1")

        XCTAssertEqual(rig.controller.adjustOffset(by: 5), 5)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 2")
        XCTAssertEqual(rig.controller.adjustOffset(by: 7), 12)
        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 3")
        XCTAssertTrue(rig.store.saved.isEmpty, "the write waits for the debounce")

        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertEqual(rig.store.saved.map(\.seconds), [12], "two nudges coalesce into one write")
        XCTAssertEqual(rig.store.saved.map(\.stationId), [Rig.stationId])
    }

    func testAdjustOffsetWithoutAStationIdDoesNotSave() async throws {
        let rig = Rig(stationId: "")
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)
        rig.controller.adjustOffset(by: 2)

        try await Task.sleep(nanoseconds: 1_000_000_000)
        XCTAssertTrue(rig.store.saved.isEmpty)
    }

    func testStopClearsEverythingAndEndsTheTimer() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)
        rig.controller.adjustOffset(by: 3)
        rig.controller.stop()

        XCTAssertEqual(rig.controller.status, .none)
        XCTAssertEqual(rig.controller.lyricOffset, 0)
        XCTAssertNil(rig.controller.currentSongKey)
        XCTAssertNil(rig.controller.lyricStartDate)
        XCTAssertFalse(rig.ticks.isRunning)
        XCTAssertFalse(rig.controller.hasLyrics)
    }

    func testPositionSourceIsNeverReadOffApplyEvenWhenOneIsPassed() async {
        let rig = Rig()
        rig.position.value = ("occ-1", 99)   // would be a different line if it were used
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)

        XCTAssertEqual(rig.delegate.lastHeader, "♪ Line 1")
        XCTAssertEqual(rig.position.reads, 0)
    }
}

// MARK: - Apply: the media clock

@MainActor
final class LyricSyncControllerApplyTests: XCTestCase {
    private func applyRig(position: Double = 0, occurrence: String = "occ-1") -> Rig {
        let rig = Rig(savedOffsets: [Rig.stationId: 40])
        rig.position.applying = true
        rig.position.value = (occurrence, position)
        return rig
    }

    func testApplyReadsTheMediaClockNotTheWallClock() async {
        let rig = applyRig(position: 6)
        // playedAt says 100 s ago (Line 3 on the wall clock); the media clock says 6 s (Line 2).
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch.addingTimeInterval(-100), occurrenceID: "occ-1")

        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} Line 2")
        XCTAssertEqual(rig.clock.reads, 0, "Apply never reads the wall clock")
        XCTAssertNil(rig.controller.lyricStartDate)
        XCTAssertEqual(rig.ticks.started, 1)
    }

    func testApplyTickFollowsThePositionAndHoldsWhileItHolds() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} Line 1")

        rig.position.value = ("occ-1", 13)
        rig.clock.now = rig.clock.now.addingTimeInterval(500)
        rig.ticks.fire()
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} Line 3")

        // A paused player reports the same seconds while the wall clock runs on.
        rig.clock.now = rig.clock.now.addingTimeInterval(500)
        rig.ticks.fire()
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} Line 3")
        XCTAssertEqual(rig.clock.reads, 0)
    }

    func testApplyKeepsTheIntroAndEndWindows() async {
        let rig = applyRig(position: 0)
        let lines = LyricsResult(lines: [LyricLine(timestamp: 20, text: "Late")], plain: nil, duration: 100)
        await rig.load("Song", result: lines, occurrenceID: "occ-1")
        XCTAssertEqual(rig.controller.status, .betweenTracks)

        rig.position.value = ("occ-1", 20)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .found)

        rig.position.value = ("occ-1", 113)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks)
    }

    func testApplyNeverReadsSavedOffsetsOnLoad() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")

        XCTAssertEqual(rig.store.fetchCount, 0, "no fetchLyricOffsets in Apply")
        XCTAssertEqual(rig.store.readCount, 0, "no read of lyricOffsets in Apply")
        XCTAssertEqual(rig.controller.lyricOffset, 0)
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} Line 1", "the saved 40 s offset is not applied")
    }

    func testApplyNeverWritesTheLockScreenAlbum() async {
        let rig = applyRig(position: 6)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.position.value = ("occ-1", 13)
        rig.ticks.fire()
        rig.position.value = nil
        rig.ticks.fire()

        XCTAssertEqual(rig.delegate.headers.last, "\u{266A} \(Rig.stationTitle)")
        XCTAssertEqual(rig.delegate.albums, [], "ADR 0005: no lyric text reaches the Now Playing album in Apply")
    }

    func testApplyPlainLyricsAreUnchanged() async {
        let rig = applyRig()
        await rig.load("Song", result: LyricsResult(lines: [], plain: "First words\nSecond"), occurrenceID: "occ-1")

        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, "\u{266A} First words")
        XCTAssertEqual(rig.ticks.started, 0)
    }

    func testApplyNoLyricsAreUnchanged() async {
        let rig = applyRig()
        await rig.load("Song", result: nil, occurrenceID: "occ-1")

        XCTAssertEqual(rig.controller.status, .notFound)
        XCTAssertEqual(rig.delegate.lastHeader, "No lyrics found")
    }
}

// MARK: - Apply: unavailable, skew, late results

@MainActor
final class LyricSyncControllerApplyStateTests: XCTestCase {
    private let note = "\u{266A} "

    private func applyRig(position: Double? = 0, occurrence: String = "occ-1") -> Rig {
        let rig = Rig()
        rig.position.applying = true
        rig.position.value = position.map { (occurrence, $0) }
        return rig
    }

    // MARK: Unavailable is explicit

    func testNoPositionShowsTheStationAndNeverTheWallClock() async {
        let rig = applyRig(position: nil)
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch.addingTimeInterval(-6), occurrenceID: "occ-1")

        XCTAssertEqual(rig.controller.status, .betweenTracks)
        XCTAssertEqual(rig.delegate.lastHeader, note + Rig.stationTitle)
        XCTAssertEqual(rig.clock.reads, 0)

        rig.position.value = ("occ-1", 6)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .found)
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 2")
    }

    func testAPositionForAnotherOccurrenceShowsNoTimedHighlight() async {
        let rig = applyRig(position: 6)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 2")

        rig.position.value = ("occ-2", 6)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks)
        XCTAssertEqual(rig.delegate.lastHeader, note + Rig.stationTitle)
        XCTAssertEqual(rig.delegate.albums, [])
    }

    func testASessionThatStoppedApplyingShowsNoTimedHighlight() async {
        let rig = applyRig(position: 6)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.controller.status, .found)

        rig.position.applying = false
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.status, .betweenTracks, "the same state the full-screen view shows on this clock")
        XCTAssertEqual(rig.delegate.lastHeader, note + Rig.stationTitle)
        XCTAssertNil(rig.controller.alignedPosition())
    }

    func testThePositionIsAskedForTheControllersStation() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.position.askedStations, [Rig.stationId])
    }

    // MARK: The nudge moves the station's skew

    func testANudgeOnAnAlignedStationNeverTouchesSavedOffsets() async throws {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.controller.adjustOffset(by: 1)
        try await Task.sleep(nanoseconds: 1_100_000_000)
        XCTAssertTrue(rig.store.saved.isEmpty, "the skew moved, not the saved lyric offset")
        XCTAssertEqual(rig.controller.lyricOffset, 0)
    }

    func testNudgeMovesTheStationSkewAndNotTheLockScreenAlbum() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 1")

        // + moves the song position forward, which means the skew goes down.
        XCTAssertEqual(rig.controller.adjustOffset(by: 0.5), 159.5)
        XCTAssertEqual(rig.controller.adjustOffset(by: 0.5), 159)
        XCTAssertEqual(rig.controller.currentSkew, 159)
        XCTAssertEqual(rig.skew.values[Rig.stationId], 159)
        XCTAssertEqual(rig.skew.nudges, [-0.5, -0.5])
        XCTAssertEqual(rig.delegate.albums, [])
    }

    func testTheLineFollowsThePositionTheSessionComputesFromTheNewSkew() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.controller.adjustOffset(by: 5)

        // The session takes the new skew and the song position moves with it. The controller adds nothing of its own.
        rig.position.value = ("occ-1", 6)
        rig.ticks.fire()
        XCTAssertEqual(rig.controller.alignedPosition(), 6)
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 2")
    }

    func testTheSkewSurvivesANewOccurrence() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.controller.adjustOffset(by: 5)

        rig.position.value = ("occ-2", 1)
        await rig.load("Other", result: Rig.synced(duration: 100), occurrenceID: "occ-2")
        XCTAssertEqual(rig.controller.currentSkew, 155, "the skew belongs to the station, not the song")
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 1")
    }

    func testARepeatPlayOfTheSameSongReloads() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")

        rig.position.value = ("occ-2", 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-2")
        XCTAssertEqual(rig.loader.requests.count, 2, "same artist and title, new occurrence: reload")
        XCTAssertEqual(rig.controller.currentOccurrenceID, "occ-2")
        XCTAssertEqual(rig.delegate.lastHeader, note + "Line 1")
    }

    func testANudgeWithNoMatchingPositionIsIgnored() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.position.applying = false

        XCTAssertEqual(rig.controller.adjustOffset(by: 3), 160, "not applying: nothing to nudge")
        XCTAssertTrue(rig.skew.nudges.isEmpty)
    }

    func testStopEndsTheAlignedPosition() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        rig.controller.stop()

        XCTAssertNil(rig.controller.alignedPosition())
        XCTAssertNil(rig.controller.currentOccurrenceID)
        XCTAssertFalse(rig.ticks.isRunning)
    }

    func testAlignedPositionIsNilWithoutAValidPosition() async {
        let rig = applyRig(position: 6)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertEqual(rig.controller.alignedPosition(), 6)

        rig.position.value = nil
        XCTAssertNil(rig.controller.alignedPosition())
    }

    // MARK: Late results are dropped

    func testALateFetchForAnEarlierOccurrenceIsDropped() async {
        let rig = applyRig(position: 1)
        rig.loader.gate(title: "Song")
        rig.controller.load(entry: rig.entry("Song"), occurrenceID: "occ-1")
        await rig.loader.waitUntilRequested(1)

        rig.position.value = ("occ-2", 1)
        rig.loader.set(LyricsResult(lines: [], plain: nil), forTitle: "Next")
        rig.controller.load(entry: rig.entry("Next"), occurrenceID: "occ-2")
        await rig.controller.waitForFetch()
        let before = rig.delegate.events
        XCTAssertEqual(rig.controller.status, .notFound)

        rig.loader.release(title: "Song", with: Rig.synced(duration: 100))
        for _ in 0..<20 { await Task.yield() }
        XCTAssertEqual(rig.delegate.events, before)
        XCTAssertEqual(rig.controller.status, .notFound)
        XCTAssertEqual(rig.ticks.started, 0)
    }

    func testALateFetchForARepeatPlayDoesNotReplaceTheNewOnesLines() async {
        let rig = applyRig(position: 1)
        rig.loader.gate(title: "Song")
        rig.controller.load(entry: rig.entry("Song"), occurrenceID: "occ-1")
        await rig.loader.waitUntilRequested(1)
        rig.position.value = ("occ-2", 1)
        rig.controller.load(entry: rig.entry("Song"), occurrenceID: "occ-2")
        await rig.loader.waitUntilRequested(2)

        let old = LyricsResult(lines: [LyricLine(timestamp: 0, text: "Old")], plain: nil, duration: 100)
        let new = LyricsResult(lines: [LyricLine(timestamp: 0, text: "New")], plain: nil, duration: 100)
        rig.loader.release(title: "Song", with: old)   // the oldest waiter is occ-1's request
        rig.loader.release(title: "Song", with: new)
        await rig.controller.waitForFetch()
        for _ in 0..<20 { await Task.yield() }

        XCTAssertFalse(rig.delegate.headers.contains(note + "Old"))
        XCTAssertEqual(rig.controller.currentOccurrenceID, "occ-2")
        XCTAssertEqual(rig.delegate.lastHeader, note + "New")
    }

    func testAFetchThatFinishesAfterApplyEndedIsDropped() async {
        let rig = applyRig(position: 1)
        rig.loader.gate(title: "Song")
        rig.controller.load(entry: rig.entry("Song"), occurrenceID: "occ-1")
        await rig.loader.waitUntilRequested(1)

        rig.position.applying = false
        rig.loader.release(title: "Song", with: Rig.synced(duration: 100))
        await rig.controller.waitForFetch()

        XCTAssertEqual(rig.controller.status, .fetching)
        XCTAssertEqual(rig.delegate.headers, ["Fetching\u{2026}"])
        XCTAssertEqual(rig.ticks.started, 0)
    }

    func testAFetchThatFinishesAfterStopIsDropped() async {
        let rig = applyRig(position: 1)
        rig.loader.gate(title: "Song")
        rig.controller.load(entry: rig.entry("Song"), occurrenceID: "occ-1")
        await rig.loader.waitUntilRequested(1)

        rig.controller.stop()
        rig.loader.release(title: "Song", with: Rig.synced(duration: 100))
        for _ in 0..<20 { await Task.yield() }

        XCTAssertEqual(rig.controller.status, .none)
        XCTAssertEqual(rig.ticks.started, 0)
    }
}

// MARK: - Apply: the clock full-screen lyrics shares

@MainActor
final class LyricSyncControllerSharedClockTests: XCTestCase {
    private func applyRig(position: Double? = 1, occurrence: String = "occ-1") -> Rig {
        let rig = Rig()
        rig.position.applying = true
        rig.position.value = position.map { (occurrence, $0) }
        return rig
    }

    func testClockReadsThePositionAndTheStationSkew() async {
        let rig = applyRig(position: 6)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        let clock = rig.controller.lyricsClock(occurrenceID: "occ-1")

        XCTAssertEqual(clock.position(), 6)
        XCTAssertEqual(clock.skew(), 160)
        XCTAssertEqual(clock.adjust(0.5), 159.5)
        XCTAssertEqual(rig.controller.currentSkew, 159.5, "the full-screen nudge moves the station's skew")
        XCTAssertEqual(clock.skew(), 159.5)
    }

    func testClockForAnEarlierOccurrenceHasNoPositionAndCannotNudge() async {
        let rig = applyRig(position: 6)
        await rig.load("Song A", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        let stale = rig.controller.lyricsClock(occurrenceID: "occ-1")
        rig.position.value = ("occ-2", 2)
        await rig.load("Song B", result: Rig.synced(duration: 100), occurrenceID: "occ-2")

        XCTAssertNil(stale.position())
        XCTAssertEqual(stale.skew(), 0)
        XCTAssertEqual(stale.adjust(0.5), 0)
        XCTAssertTrue(rig.skew.nudges.isEmpty, "a stale full screen cannot nudge the station")
    }

    func testClockHasNoPositionWhenTheControllerHasNone() async {
        let rig = applyRig(position: nil)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        XCTAssertNil(rig.controller.lyricsClock(occurrenceID: "occ-1").position())
    }

    func testSubscribersHearEveryApplyTickWithoutASecondTimer() async {
        let rig = applyRig(position: 1)
        await rig.load("Song", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        let clock = rig.controller.lyricsClock(occurrenceID: "occ-1")
        var heard = 0
        let unsubscribe = clock.subscribe { heard += 1 }

        XCTAssertEqual(rig.ticks.started, 1, "subscribing starts no timer")
        rig.ticks.fire()
        rig.ticks.fire()
        XCTAssertEqual(heard, 2)

        unsubscribe()
        rig.ticks.fire()
        XCTAssertEqual(heard, 2)
        XCTAssertTrue(rig.ticks.isRunning, "unsubscribing leaves the controller's clock running")
    }

    func testSubscribersSurviveTheControllerLoadingTheNextOccurrence() async {
        let rig = applyRig(position: 1)
        await rig.load("Song A", result: Rig.synced(duration: 100), occurrenceID: "occ-1")
        var heard = 0
        let unsubscribe = rig.controller.lyricsClock(occurrenceID: "occ-1").subscribe { heard += 1 }
        rig.position.value = ("occ-2", 1)
        await rig.load("Song B", result: Rig.synced(duration: 100), occurrenceID: "occ-2")

        rig.ticks.fire()
        XCTAssertEqual(heard, 1)
        unsubscribe()
    }

    func testOffTicksNeverReachSubscribers() async {
        let rig = Rig()
        await rig.load("Song", result: Rig.synced(duration: 100), playedAt: Rig.epoch)
        var heard = 0
        _ = rig.controller.lyricsClock(occurrenceID: "occ-1").subscribe { heard += 1 }
        rig.ticks.fire()
        XCTAssertEqual(heard, 0)
    }
}
#endif
