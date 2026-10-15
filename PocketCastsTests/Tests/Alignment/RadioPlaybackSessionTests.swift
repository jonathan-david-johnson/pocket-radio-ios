import AVFoundation
import MediaPlayer
import StreamSession
import XCTest

@testable import podcasts

/// The Observe-only session: no early selection, explicit
/// unavailable states, same-item and generation guards, lifecycle, and nothing published.
@MainActor
final class RadioPlaybackSessionTests: XCTestCase {
    // MARK: - Harness

    private final class Harness {
        var lines: [String] = []
        var callback: ((CMTime) -> Void)?
        var statusHandler: ((AVPlayer.TimeControlStatus) -> Void)?
        var installs = 0
        var removes = 0
        var flushes = 0
        var now: TimeInterval = 1000
        var skew = 160.0
        var snapshots: [RadioAlignmentSnapshot] = []
        var sessions: [RadioPlaybackSession] = []
    }

    private final class Gate {
        var continuation: CheckedContinuation<AlignmentFeedResult, Never>?
        var started = 0
        var cancelled = false
    }

    private let generation = UUID(uuidString: "ABCDEF12-3456-7890-ABCD-EF1234567890")!
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let endpoint = URL(string: "https://user:pw@streams.kcrw.com/e24_aac/playlist.m3u8?token=secret")!
    private var harness = Harness()
    private var item = AVPlayerItem(asset: AVMutableComposition())
    private var player = AVPlayer()

    override func setUp() {
        super.setUp()
        harness = Harness()
        item = AVPlayerItem(asset: AVMutableComposition())
        player = AVPlayer(playerItem: item)
    }

    override func tearDown() {
        for session in harness.sessions { session.stop() }
        harness.sessions = []
        super.tearDown()
    }

    private func failureResult(_ reason: String = "HTTP 500") -> AlignmentFeedResult {
        AlignmentFeedResult(entries: [], statusCode: 500, cacheAgeSeconds: nil, failure: reason)
    }

    private func feed(_ rows: [(title: String, artist: String, playedAt: Date)], age: Double? = nil) -> AlignmentFeedResult {
        let entries = rows.map {
            OccurrenceInput(station: "kcrw", providerID: nil, kind: "trackplay", title: $0.title, artist: $0.artist,
                            album: nil, artworkURL: nil, playedAt: $0.playedAt)
        }
        return AlignmentFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: age, failure: nil)
    }

    private func parkedFetch() -> RadioPlaybackSession.Fetch {
        { [failure = failureResult()] in
            try? await Task.sleep(nanoseconds: 3_600_000_000_000)
            return failure
        }
    }

    private func gatedFetch(_ gate: Gate) -> RadioPlaybackSession.Fetch {
        { [failure = failureResult("cancelled")] in
            gate.started += 1
            return await withTaskCancellationHandler {
                await withCheckedContinuation { gate.continuation = $0 }
            } onCancel: {
                Task { @MainActor in
                    gate.cancelled = true
                    gate.continuation?.resume(returning: failure)
                    gate.continuation = nil
                }
            }
        }
    }

    private func makeSession(startsPoller: Bool = false,
                             profile: AlignmentProfile = AlignmentProfiles.kcrw,
                             wallNow: @escaping () -> Date = Date.init,
                             generation: UUID? = nil,
                             item: AVPlayerItem? = nil,
                             fetch: RadioPlaybackSession.Fetch? = nil) -> RadioPlaybackSession {
        let harness = self.harness
        let session = RadioPlaybackSession(
            player: player,
            item: item ?? self.item,
            generation: generation ?? UUID(),
            endpoint: endpoint,
            profile: profile,
            now: { harness.now },
            wallNow: wallNow,
            emit: { harness.lines.append($0) },
            flush: { harness.flushes += 1 },
            fetch: fetch ?? parkedFetch(),
            install: { _, callback in
                harness.installs += 1
                harness.callback = callback
                return NSObject()
            },
            remove: { _, _ in harness.removes += 1 },
            observeStatus: { _, handler in
                harness.statusHandler = handler
                return NSObject()
            },
            skew: { _ in harness.skew },
            startsPoller: startsPoller)
        session.onSnapshot = { harness.snapshots.append($0) }
        harness.sessions.append(session)
        return session
    }

    /// One valid, advancing paired sample. `elapsed` is seconds since the session started.
    private func tick(_ session: RadioPlaybackSession, elapsed: TimeInterval, media: Double, program: Date?,
                      status: AVPlayer.TimeControlStatus = .playing, rate: Float = 1) {
        harness.now = 1000 + elapsed
        session.sample(currentItem: session.item, rate: rate, status: status, mediaSeconds: media, programDate: program)
    }

    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<400 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return condition()
    }

    // MARK: - B4 No early selection

    func testFeedAloneYieldsNoCandidateAndOnlyPlayerSampleSelects() {
        let session = makeSession()
        harness.now = 1000
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)

        XCTAssertNil(session.snapshot.candidate)
        XCTAssertNil(session.snapshot.candidateID)
        XCTAssertEqual(session.snapshot.historyCount, 1)
        XCTAssertEqual(session.snapshot.feedTop, "Song A — Artist A")

        tick(session, elapsed: 10, media: 50, program: base.addingTimeInterval(190))

        XCTAssertEqual(session.snapshot.candidate, "Song A — Artist A")
        XCTAssertEqual(try XCTUnwrap(session.snapshot.songSeconds), 30, accuracy: 0.001)
        XCTAssertTrue(session.snapshot.clockValid)
        XCTAssertEqual(session.snapshot.trigger, .playerSample)
    }

    func testLaterFeedReceiptDoesNotChangeCandidateUntilNextSample() {
        let session = makeSession()
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: base.addingTimeInterval(190))
        let selected = session.snapshot.candidateID
        XCTAssertNotNil(selected)

        // B's estimated start (base + 25 + 160) is before the player's program date, so the
        // next sample would select it. The receipt alone must not.
        session.accept(feed([("Song B", "Artist B", base.addingTimeInterval(25)), ("Song A", "Artist A", base)]),
                       requestedElapsed: 10.5, receivedElapsed: 10.8)

        XCTAssertEqual(session.snapshot.candidateID, selected)
        XCTAssertEqual(session.snapshot.candidate, "Song A — Artist A")
        XCTAssertEqual(session.snapshot.historyCount, 2)
        XCTAssertEqual(session.snapshot.feedTop, "Song B — Artist B")
        XCTAssertEqual(session.snapshot.trigger, .feedUpdate)

        tick(session, elapsed: 11, media: 51, program: base.addingTimeInterval(191))

        XCTAssertEqual(session.snapshot.candidate, "Song B — Artist B")
    }

    // MARK: - B5 Unavailable is explicit

    func testNilProgramDateGivesPlayerClockReasonAndNoCandidateDespiteHistory() {
        let session = makeSession()
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)

        tick(session, elapsed: 10, media: 50, program: nil)

        XCTAssertTrue(session.snapshot.reason.hasPrefix("player clock:"), session.snapshot.reason)
        XCTAssertNil(session.snapshot.candidate)
        XCTAssertNil(session.snapshot.candidateID)
        XCTAssertNil(session.snapshot.songSeconds)
        XCTAssertFalse(session.snapshot.clockValid)
        // The feed top is evidence only; it is never a fallback candidate.
        XCTAssertEqual(session.snapshot.feedTop, "Song A — Artist A")
        XCTAssertEqual(session.snapshot.historyCount, 1)
    }

    func testNoHistoryGivesAlignmentUnavailableNoHistory() {
        let session = makeSession()

        tick(session, elapsed: 10, media: 50, program: base.addingTimeInterval(190))

        XCTAssertEqual(session.snapshot.reason, "alignment unavailable: noHistory")
        XCTAssertNil(session.snapshot.candidate)
        XCTAssertTrue(session.snapshot.clockValid)
    }

    func testFailedFeedLeavesNoCandidateAndRecordsStatus() {
        let session = makeSession()
        session.accept(failureResult("HTTP 503"), requestedElapsed: 1, receivedElapsed: 2)

        XCTAssertNil(session.snapshot.candidate)
        XCTAssertEqual(session.snapshot.feedStatus, "HTTP 503")
    }

    // MARK: - B6 Guards

    func testSampleFromAnotherItemIsIgnored() {
        let session = makeSession()
        let before = session.snapshot
        let callbacks = harness.snapshots.count
        let lines = harness.lines.count

        session.sample(currentItem: AVPlayerItem(asset: AVMutableComposition()), rate: 1, status: .playing,
                       mediaSeconds: 5, programDate: base)
        session.sample(currentItem: nil, rate: 1, status: .playing, mediaSeconds: 5, programDate: base)

        XCTAssertEqual(session.snapshot, before)
        XCTAssertEqual(harness.snapshots.count, callbacks)
        XCTAssertEqual(harness.lines.count, lines)
        XCTAssertTrue(session.monitorSamples.isEmpty)
    }

    func testTickAfterPlayerMovedToAnotherItemIsIgnored() {
        let session = makeSession()
        player.replaceCurrentItem(with: AVPlayerItem(asset: AVMutableComposition()))
        let lines = harness.lines.count

        harness.callback?(.zero)

        XCTAssertEqual(harness.lines.count, lines)
        XCTAssertTrue(session.monitorSamples.isEmpty)
    }

    func testSampleAndFeedAfterStopAreIgnored() {
        let session = makeSession()
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)
        session.stop()
        let before = session.snapshot
        let callbacks = harness.snapshots.count
        let lines = harness.lines.count

        session.accept(feed([("Song B", "Artist B", base)]), requestedElapsed: 5, receivedElapsed: 6)
        tick(session, elapsed: 10, media: 50, program: base.addingTimeInterval(190))
        harness.callback?(.zero)

        XCTAssertEqual(session.snapshot, before)
        XCTAssertEqual(harness.snapshots.count, callbacks)
        XCTAssertEqual(harness.lines.count, lines)
    }

    func testInFlightFeedResultDeliveredAfterStopIsDropped() async {
        let gate = Gate()
        let session = makeSession(startsPoller: true, fetch: gatedFetch(gate))
        let started = await waitUntil { gate.started == 1 && gate.continuation != nil }
        XCTAssertTrue(started)
        let before = session.snapshot
        let callbacks = harness.snapshots.count

        session.stop()
        gate.continuation?.resume(returning: feed([("Late", "Late", base)]))
        gate.continuation = nil
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(session.snapshot, before)
        XCTAssertEqual(harness.snapshots.count, callbacks)
        XCTAssertFalse(harness.lines.contains { $0.hasPrefix("[align] poll n=1") && $0.contains(" ok ") })
    }

    // MARK: - B7 Lifecycle

    func testStopTwiceRemovesObserverOnceLogsOneStopAndClearsActive() {
        let session = makeSession()
        XCTAssertTrue(RadioPlaybackSession.active === session)
        XCTAssertEqual(harness.installs, 1)

        session.stop()
        session.stop(reason: "again")

        XCTAssertEqual(harness.removes, 1)
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] session stop") }.count, 1)
        XCTAssertEqual(harness.flushes, 1)
        XCTAssertNil(RadioPlaybackSession.active)
        XCTAssertTrue(session.isStopped)
        XCTAssertNil(session.onSnapshot)
    }

    func testStopCancelsTheTimerPoller() async {
        let gate = Gate()
        let session = makeSession(startsPoller: true, fetch: gatedFetch(gate))
        let started = await waitUntil { gate.started == 1 && gate.continuation != nil }
        XCTAssertTrue(started)

        session.stop()

        let cancelled = await waitUntil { gate.cancelled }
        XCTAssertTrue(cancelled)
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(session.snapshot.feedStatus, "not requested")
    }

    func testSecondSessionHasNewGenerationAndEmptyClock() {
        let first = makeSession()
        first.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(first, elapsed: 10, media: 50, program: base.addingTimeInterval(190))
        XCTAssertTrue(first.snapshot.clockValid)
        first.stop()

        let second = makeSession()

        XCTAssertNotEqual(first.generation, second.generation)
        XCTAssertTrue(RadioPlaybackSession.active === second)
        XCTAssertFalse(second.snapshot.clockValid)
        XCTAssertNil(second.snapshot.mediaSeconds)
        XCTAssertNil(second.snapshot.candidate)
        XCTAssertEqual(second.snapshot.historyCount, 0)
        XCTAssertTrue(second.monitorSamples.isEmpty)
        XCTAssertTrue(second.monitorPolls.isEmpty)
    }

    // MARK: - The media-time clock (a stream with no program date, KEXP)

    func testAMediaTimeClockAnchorsWhenPlaybackFirstAdvancesAndThenFollowsMedia() {
        let wall = Date(timeIntervalSince1970: 1_700_000_100)
        let session = makeSession(profile: AlignmentProfiles.kexp, wallNow: { wall })

        XCTAssertNil(session.programDate(media: 0, advancing: false), "no date before playback advances")
        XCTAssertNil(session.programDate(media: nil, advancing: true))
        XCTAssertNil(session.programDate(media: .nan, advancing: true))

        // Playback first advances at media 5 s, which is wall time `wall`: position 0 was 5 s earlier.
        XCTAssertEqual(session.programDate(media: 5, advancing: true), wall)
        XCTAssertEqual(session.programDate(media: 65, advancing: true), wall.addingTimeInterval(60),
                       "the date follows media time, whatever the wall clock says")
    }

    func testAMediaTimeClockStopsWithAStallSoTheSkewDoesNotMove() {
        var wall = Date(timeIntervalSince1970: 1_700_000_100)
        let session = makeSession(profile: AlignmentProfiles.kexp, wallNow: { wall })
        XCTAssertEqual(session.programDate(media: 10, advancing: true), wall)
        // A 40 s stall: the wall clock moves, media time does not.
        wall = wall.addingTimeInterval(40)
        XCTAssertEqual(session.programDate(media: 10, advancing: false), Date(timeIntervalSince1970: 1_700_000_100),
                       "the date is where the audio is, not where the wall clock is")
        XCTAssertEqual(session.programDate(media: 11, advancing: true), Date(timeIntervalSince1970: 1_700_000_101))
    }

    func testEachSessionOfAMediaTimeStreamHasItsOwnAnchor() {
        let first = makeSession(profile: AlignmentProfiles.kexp, wallNow: { Date(timeIntervalSince1970: 1_700_000_000) })
        let second = makeSession(profile: AlignmentProfiles.kexp, wallNow: { Date(timeIntervalSince1970: 1_700_000_500) })
        XCTAssertEqual(first.programDate(media: 3, advancing: true), Date(timeIntervalSince1970: 1_700_000_000))
        XCTAssertEqual(second.programDate(media: 3, advancing: true), Date(timeIntervalSince1970: 1_700_000_500),
                       "a restart is a new item, so it takes a new anchor and needs a new heal")
    }

    func testAProgramDateStreamReadsTheItemsOwnDate() {
        let session = makeSession(profile: AlignmentProfiles.kcrw, wallNow: { Date(timeIntervalSince1970: 1) })
        XCTAssertNil(session.programDate(media: 5, advancing: true), "an item with no program date has none, and the wall clock is not used")
    }

    func testAKEXPSessionSelectsTheSongFromTheMediaTimeClockAndTheSkew() throws {
        harness.skew = 0
        let wall = Date(timeIntervalSince1970: 1_700_000_300)
        let session = makeSession(profile: AlignmentProfiles.kexp, wallNow: { wall })
        // The feed stamps a song 100 s before the wall time of the first sample.
        let row = OccurrenceInput(station: "kexp", providerID: "1", kind: "trackplay", title: "Song A", artist: "Artist A",
                                  album: nil, artworkURL: nil, playedAt: base.addingTimeInterval(200))
        session.accept(AlignmentFeedResult(entries: [row], statusCode: 200, cacheAgeSeconds: nil, failure: nil),
                       requestedElapsed: 1, receivedElapsed: 2)
        let date = try XCTUnwrap(session.programDate(media: 20, advancing: true))
        tick(session, elapsed: 10, media: 20, program: date)

        XCTAssertEqual(session.snapshot.candidate, "Song A — Artist A")
        XCTAssertEqual(session.snapshot.songSeconds ?? -1, 100, accuracy: 0.001, "skew 0: the song began where the feed stamped it")
        XCTAssertEqual(session.appliedSkew, 0)
    }

    // MARK: - The trace lines

    private func row(_ id: String, _ title: String, stampedAt offset: TimeInterval) -> OccurrenceInput {
        OccurrenceInput(station: "kexp", providerID: id, kind: "trackplay", title: title, artist: "Artist", album: nil,
                        artworkURL: nil, playedAt: base.addingTimeInterval(offset))
    }

    private func feedResult(_ rows: [OccurrenceInput]) -> AlignmentFeedResult {
        AlignmentFeedResult(entries: rows, statusCode: 200, cacheAgeSeconds: nil, failure: nil)
    }

    func testTheFirstPollIsTracedWithTheNewestRowsAgeAndLaterNewRowsWithTheirLag() {
        var wall = base.addingTimeInterval(1000)
        let session = makeSession(profile: AlignmentProfiles.kexp, wallNow: { wall })
        session.accept(feedResult([row("2", "Song B", stampedAt: 900), row("1", "Song A", stampedAt: 700)]),
                       requestedElapsed: 1, receivedElapsed: 2)
        let first = harness.lines.filter { $0.hasPrefix("[trace] feed") }
        XCTAssertEqual(first.count, 1)
        XCTAssertTrue(first[0].contains("first poll rows=2 newest=\"Song B\""), first[0])
        XCTAssertTrue(first[0].contains("age=100.0"), "the newest row was already 100 s old when the feed first showed it: \(first[0])")

        wall = base.addingTimeInterval(1030)
        session.accept(feedResult([row("3", "Song C", stampedAt: 940), row("2", "Song B", stampedAt: 900), row("1", "Song A", stampedAt: 700)]),
                       requestedElapsed: 31, receivedElapsed: 32)
        let later = harness.lines.filter { $0.hasPrefix("[trace] feed new") }
        XCTAssertEqual(later.count, 1, "only the new row, not the old ones again: \(later)")
        XCTAssertTrue(later[0].contains("id=3") && later[0].contains("title=\"Song C\""), later[0])
        XCTAssertTrue(later[0].contains("lag=90.0"), "listed 90 s after its stamp: \(later[0])")
        XCTAssertTrue(later[0].contains("stamp=2023-11-14T22:29:00.000Z"), later[0])
    }

    func testTimedMetadataIsTracedWithItsMediaTimeStreamDateAndWallTime() {
        let wall = Date(timeIntervalSince1970: 1_700_000_100)
        let session = makeSession(profile: AlignmentProfiles.kexp, wallNow: { wall })
        _ = session.programDate(media: 0, advancing: true)   // anchors the media-time clock at the wall time
        session.trace(metadata: [TraceMetadata(id: "icy/StreamTitle", value: "Artist - \"Song\"\nTwo", start: 12.34),
                                 TraceMetadata(id: "icy/StreamUrl", value: "Album", start: 12.34)])

        let lines = harness.lines.filter { $0.hasPrefix("[trace] meta") }
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].contains("id=icy/StreamTitle value=\"Artist - 'Song' Two\" applies=12.3"), "quotes and newlines are cleaned: \(lines[0])")
        XCTAssertTrue(lines[0].contains("program=2023-11-14T22:15:00.000Z"), lines[0])
        XCTAssertTrue(lines[0].contains("wall=2023-11-14T22:15:00.000Z"), lines[0])
        XCTAssertTrue(lines[1].contains("value=\"Album\""))
    }

    func testNothingIsTracedAfterTheSessionStops() {
        let session = makeSession(profile: AlignmentProfiles.kexp)
        session.stop()
        session.trace(metadata: [TraceMetadata(id: "x", value: "y", start: 0)])
        XCTAssertFalse(harness.lines.contains { $0.hasPrefix("[trace] meta") })
    }

    func testTheTraceHelpers() {
        XCTAssertEqual(StreamTrace.iso(Date(timeIntervalSince1970: 1_700_000_000.123)), "2023-11-14T22:13:20.123Z")
        XCTAssertEqual(StreamTrace.iso(nil), "nil")
        XCTAssertEqual(StreamTrace.seconds(1.25), "1.2")
        XCTAssertEqual(StreamTrace.seconds(.nan), "nil")
        XCTAssertEqual(StreamTrace.clip("a\"b\nc"), "a'b c")
        XCTAssertEqual(StreamTrace.clip(String(repeating: "x", count: 130)).count, 121)
    }

    func testStartLineHasHostAndPathOnly() {
        _ = makeSession(generation: generation)

        XCTAssertEqual(harness.lines.first,
                       "[align] session start gen=ABCDEF12 endpoint=streams.kcrw.com/e24_aac/playlist.m3u8")
        for line in harness.lines {
            XCTAssertFalse(line.contains("secret"))
            XCTAssertFalse(line.contains("pw"))
            XCTAssertFalse(line.contains("?"))
        }
    }

    func testTimerDriverFetchesImmediatelyOnceAndTicksDoNotStartPolls() async {
        let gate = Gate()
        let session = makeSession(startsPoller: true, fetch: gatedFetch(gate))
        let started = await waitUntil { gate.started == 1 }
        XCTAssertTrue(started)

        for _ in 0..<60 {
            harness.now += 1
            harness.callback?(.zero)
        }
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(session.monitorPolls.count, 1)
    }

    func testPollResultsAreLoggedAndCountedAsAttempts() async {
        let ok = feed([("Song A", "Artist A", base)], age: 4)
        let okSession = makeSession(startsPoller: true, fetch: { ok })
        _ = await waitUntil { okSession.snapshot.historyCount == 1 }
        XCTAssertTrue(harness.lines.contains("[align] poll n=1 t=0.0 ok entries=1 age=4.0"), harness.lines.joined(separator: "\n"))
        XCTAssertEqual(okSession.monitorPolls, [AlignmentMonitorPoll(elapsed: 0, succeeded: true)])
        XCTAssertEqual(okSession.snapshot.lastPollElapsed, 0)
        okSession.stop()

        harness.lines = []
        let failure = failureResult("HTTP 500")
        let failSession = makeSession(startsPoller: true, fetch: { failure })
        _ = await waitUntil { failSession.snapshot.feedStatus == "HTTP 500" }
        XCTAssertTrue(harness.lines.contains("[align] poll n=1 t=0.0 fail reason=HTTP 500"), harness.lines.joined(separator: "\n"))
        XCTAssertEqual(failSession.monitorPolls, [AlignmentMonitorPoll(elapsed: 0, succeeded: false)])
        XCTAssertEqual(failSession.summary(endElapsed: 1).pollAttempts, 1)
        XCTAssertEqual(failSession.summary(endElapsed: 1).pollFailures, 1)
    }

    // MARK: - Decision, status, and monitor lines

    func testDecisionLineIsLoggedOnCandidateOrReasonChangeOnly() {
        let session = makeSession()
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)

        tick(session, elapsed: 10, media: 50, program: base.addingTimeInterval(190))
        tick(session, elapsed: 11, media: 51, program: base.addingTimeInterval(191))

        let decisions = harness.lines.filter { $0.hasPrefix("[align] decision") }
        XCTAssertEqual(decisions.count, 1)
        XCTAssertEqual(decisions.first, "[align] decision t=10.0 candidate=\"Song A — Artist A\" songSec=30.0 reason=estimated from the skew; not verified audible")
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] clock") }.count, 1)
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] probe gen=") }.count, 2)

        tick(session, elapsed: 12, media: 52, program: nil)
        let after = harness.lines.filter { $0.hasPrefix("[align] decision") }
        XCTAssertEqual(after.last, "[align] decision t=12.0 candidate=none songSec=nil reason=player clock: missingPair")
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] clock") }.count, 2)
    }

    func testStallIntervalsAndAudioStopped() {
        let session = makeSession()
        tick(session, elapsed: 0, media: 0, program: nil, status: .waitingToPlayAtSpecifiedRate, rate: 0)
        for t in 1...10 { tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(Double(t))) }
        XCTAssertTrue(session.stallIntervals.isEmpty, "waiting before the first playing sample is not a stall")

        harness.now = 1011
        session.statusChanged(.waitingToPlayAtSpecifiedRate)
        harness.now = 1014
        session.statusChanged(.playing)
        XCTAssertEqual(session.stallIntervals, [11 ... 14])
        XCTAssertFalse(session.audioStopped)

        harness.now = 1020
        session.statusChanged(.paused)
        XCTAssertTrue(session.audioStopped)
        harness.now = 1025
        session.stop()

        XCTAssertEqual(session.stallIntervals, [11 ... 14, 20 ... 25])
        XCTAssertTrue(harness.lines.contains("[align] status waiting t=11.0"))
        XCTAssertTrue(harness.lines.contains("[align] status playing t=14.0"))
        XCTAssertTrue(harness.lines.contains("[align] status paused t=20.0"))
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] status") }.count, 5)
    }

    func testStatusHandlerFromObserverDrivesStatusChanges() {
        let session = makeSession()
        tick(session, elapsed: 1, media: 1, program: nil)
        harness.now = 1002
        harness.statusHandler?(.paused)

        XCTAssertTrue(harness.lines.contains("[align] status paused t=2.0"))
        _ = session
    }

    func testSummaryAndVerdictAtStopAndEvery300Seconds() {
        let session = makeSession()
        for t in 0...301 {
            tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(Double(t)))
        }

        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] verdict passed=") }.count, 1)
        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] summary samples=301") }.count, 1)
        XCTAssertEqual(session.monitorSamples.count, 302)

        harness.now = 1305
        session.stop(reason: "teardown")

        XCTAssertEqual(harness.lines.filter { $0.hasPrefix("[align] verdict passed=") }.count, 2)
        let verdict = harness.lines.last { $0.hasPrefix("[align] verdict passed=") } ?? ""
        XCTAssertTrue(verdict.hasPrefix("[align] verdict passed=false failures="), verdict)
        // No polls in a 305 s run, so the attempt-count failure appears as a separate line.
        XCTAssertTrue(harness.lines.contains { $0.hasPrefix("[align] verdict - poll attempts 0 below 58") })
        let stopIndex = harness.lines.lastIndex { $0.hasPrefix("[align] session stop gen=") }
        XCTAssertEqual(stopIndex.map { harness.lines[$0].contains(" reason=teardown ") }, true)
        XCTAssertEqual(stopIndex, harness.lines.count - 1)
        XCTAssertEqual(harness.flushes, 1)
        // Stopped at teardown, not a failure of liveness.
        XCTAssertFalse(harness.lines.contains { $0.contains("session not alive at end") })
    }

    func testMonitorSamplesAreCappedAtSixHours() {
        let session = makeSession()
        for t in 0..<(21_600 + 5) {
            tick(session, elapsed: Double(t), media: Double(t), program: nil)
        }

        XCTAssertEqual(session.monitorSamples.count, 21_600)
        XCTAssertEqual(session.monitorSamples.first?.elapsed, 5)
    }

    func testSummaryAndVerdictUseRecordedSamples() {
        let session = makeSession()
        for t in 0...10 { tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(Double(t))) }

        let summary = session.summary(endElapsed: 10)

        XCTAssertEqual(summary.sampleCount, 11)
        XCTAssertEqual(summary.minRate, 1)
        XCTAssertEqual(session.lockedRunVerdict(endElapsed: 10).passed, false)
        XCTAssertFalse(session.lockedRunVerdict(endElapsed: 10).failures.contains("session not alive at end"))
        session.stop()
        XCTAssertTrue(session.lockedRunVerdict(endElapsed: 10).failures.contains("session not alive at end"))
    }

    // MARK: - B9 Nothing published

    func testFullSequencePublishesNothing() throws {
        let before = MPNowPlayingInfoCenter.default().nowPlayingInfo as NSDictionary?
        let session = makeSession()
        session.accept(feed([("Song A", "Artist A", base)]), requestedElapsed: 1, receivedElapsed: 2)
        for t in 1...5 { tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(190 + Double(t))) }
        session.statusChanged(.paused)
        session.stop()

        let after = MPNowPlayingInfoCenter.default().nowPlayingInfo as NSDictionary?
        XCTAssertEqual(before, after)
    }

    func testAlignmentSourcesDoNotReferenceTheNowPlayingWriter() throws {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("podcasts/Main/Alignment")
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            throw XCTSkip("source tree not readable from the test host")
        }
        let sources = files.filter { $0.pathExtension == "swift" }
        XCTAssertFalse(sources.isEmpty)
        for file in sources {
            let text = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(text.contains("MPNowPlayingInfoCenter"), file.lastPathComponent)
            XCTAssertFalse(text.contains("nowPlayingInfo"), file.lastPathComponent)
        }
    }

    func testFirstPauseAfterPlayingLogsAtPauseVerdictBeforeAudioStops() {
        let session = makeSession()
        for t in 0...10 {
            tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(Double(t)))
        }
        harness.now = 1011
        session.statusChanged(.paused)
        harness.now = 1012
        session.statusChanged(.playing)
        harness.now = 1013
        session.statusChanged(.paused)

        let atPause = harness.lines.filter { $0.hasPrefix("[align] verdict passed=") && $0.hasSuffix(" kind=at-pause") }
        XCTAssertEqual(atPause.count, 1)
        let failures = harness.lines.filter { $0.hasPrefix("[align] verdict - ") }
        XCTAssertFalse(failures.contains { $0.contains("audio stopped") }, failures.joined(separator: "\n"))
        XCTAssertTrue(session.audioStopped)
    }

    func testVerdictLinesNameTheirKind() {
        let session = makeSession()
        for t in 0...301 {
            tick(session, elapsed: Double(t), media: Double(t), program: base.addingTimeInterval(Double(t)))
        }
        harness.now = 1305
        session.stop()

        let kinds = harness.lines.filter { $0.hasPrefix("[align] verdict passed=") }.compactMap { $0.components(separatedBy: " kind=").last }
        XCTAssertEqual(kinds, ["checkpoint", "stop"])
    }
}
