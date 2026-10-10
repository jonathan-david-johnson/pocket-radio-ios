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
        var snapshots: [RadioAlignmentSnapshot] = []
        var sessions: [RadioPlaybackSession] = []
    }

    private final class Gate {
        var continuation: CheckedContinuation<KCRWFeedResult, Never>?
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

    private func failureResult(_ reason: String = "HTTP 500") -> KCRWFeedResult {
        KCRWFeedResult(entries: [], statusCode: 500, cacheAgeSeconds: nil, failure: reason)
    }

    private func feed(_ rows: [(title: String, artist: String, playedAt: Date)], age: Double? = nil) -> KCRWFeedResult {
        let entries = rows.map {
            OccurrenceInput(station: "kcrw", providerID: nil, kind: "trackplay", title: $0.title, artist: $0.artist,
                            album: nil, artworkURL: nil, playedAt: $0.playedAt)
        }
        return KCRWFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: age, failure: nil)
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

    private func makeSession(driver: AlignmentPollDriver = .playbackTicks,
                             generation: UUID? = nil,
                             item: AVPlayerItem? = nil,
                             fetch: RadioPlaybackSession.Fetch? = nil) -> RadioPlaybackSession {
        let harness = self.harness
        let session = RadioPlaybackSession(
            player: player,
            item: item ?? self.item,
            generation: generation ?? UUID(),
            endpoint: endpoint,
            driver: driver,
            now: { harness.now },
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
            })
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
        let session = makeSession(driver: .timer, fetch: gatedFetch(gate))
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
        let session = makeSession(driver: .timer, fetch: gatedFetch(gate))
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

    func testStartLineHasHostAndPathOnly() {
        _ = makeSession(generation: generation)

        XCTAssertEqual(harness.lines.first,
                       "[align] session start gen=ABCDEF12 endpoint=streams.kcrw.com/e24_aac/playlist.m3u8 driver=ticks mode=observe")
        for line in harness.lines {
            XCTAssertFalse(line.contains("secret"))
            XCTAssertFalse(line.contains("pw"))
            XCTAssertFalse(line.contains("?"))
        }
    }

    func testTickDriverStartsExactlyOneRequestWhileNeverReturning() async {
        let gate = Gate()
        let session = makeSession(driver: .playbackTicks, fetch: gatedFetch(gate))
        for _ in 0..<60 {
            harness.now += 1
            harness.callback?(.zero)
        }
        let started = await waitUntil { gate.started >= 1 }
        XCTAssertTrue(started)
        try? await Task.sleep(nanoseconds: 50_000_000)

        XCTAssertEqual(gate.started, 1)
        XCTAssertEqual(session.monitorPolls.count, 1)
    }

    func testTickDriverStartsNextPollOnThirtiethTickAfterCompletion() async {
        let gate = Gate()
        let session = makeSession(driver: .playbackTicks, fetch: gatedFetch(gate))
        harness.callback?(.zero)
        _ = await waitUntil { gate.continuation != nil }
        gate.continuation?.resume(returning: feed([("Song A", "Artist A", base)]))
        gate.continuation = nil
        _ = await waitUntil { session.snapshot.historyCount == 1 }
        XCTAssertEqual(session.monitorPolls.count, 1)

        for _ in 2..<30 { harness.now += 1; harness.callback?(.zero) }
        XCTAssertEqual(session.monitorPolls.count, 1)
        harness.now += 1
        harness.callback?(.zero)

        XCTAssertEqual(session.monitorPolls.count, 2)
    }

    func testTimerDriverFetchesImmediatelyOnceAndTicksDoNotStartPolls() async {
        let gate = Gate()
        let session = makeSession(driver: .timer, fetch: gatedFetch(gate))
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
        let okSession = makeSession(driver: .timer, fetch: { ok })
        _ = await waitUntil { okSession.snapshot.historyCount == 1 }
        XCTAssertTrue(harness.lines.contains("[align] poll n=1 t=0.0 ok entries=1 age=4.0"), harness.lines.joined(separator: "\n"))
        XCTAssertEqual(okSession.monitorPolls, [AlignmentMonitorPoll(elapsed: 0, succeeded: true)])
        XCTAssertEqual(okSession.snapshot.lastPollElapsed, 0)
        okSession.stop()

        harness.lines = []
        let failure = failureResult("HTTP 500")
        let failSession = makeSession(driver: .timer, fetch: { failure })
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
        XCTAssertEqual(decisions.first, "[align] decision t=10.0 candidate=\"Song A — Artist A\" songSec=30.0 reason=estimated +160s; not verified audible")
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

    // MARK: - Poll driver setting

    func testPollDriverDefaultsToTimerAndRoundTripsThroughInjectedSuite() throws {
        let suite = "RadioPlaybackSessionTests.pollDriver"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = ObserveSwitchStore(defaults: defaults)

        XCTAssertEqual(store.pollDriver, .timer)
        #if DEBUG
        store.pollDriver = .playbackTicks
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.pollDriver"), "ticks")
        XCTAssertEqual(store.pollDriver, .playbackTicks)
        store.pollDriver = .timer
        XCTAssertEqual(defaults.string(forKey: "PocketRadio.alignment.pollDriver"), "timer")
        XCTAssertEqual(store.pollDriver, .timer)
        #endif
    }

    // The first pause after playback records a verdict for the run before the pause counts as "audio stopped".
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
