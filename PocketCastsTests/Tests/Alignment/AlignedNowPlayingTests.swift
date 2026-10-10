import AVFoundation
import StreamSession
import UIKit
import XCTest

@testable import podcasts

/// The Apply publication adapter and its state: nothing before a player sample, fail-closed
/// gate, generation guards, explicit unavailable state, and lifecycle. Clock, feed, state and
/// notification boundaries are injected; nothing touches the network or the system Now Playing record.
@MainActor
final class AlignedNowPlayingTests: XCTestCase {
    private final class Harness {
        var lines: [String] = []
        var posts: [[AnyHashable: Any]] = []
        var now: TimeInterval = 1000
        /// The state's injected clock for the lyric position. Tests move it by hand.
        var wall = Date(timeIntervalSince1970: 3_000_000_000)
        var sessions: [RadioPlaybackSession] = []
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let endpoint = URL(string: "https://streams.kcrw.com/e24_aac/playlist.m3u8")!
    private let station = "station-1"
    private var harness = Harness()
    private var state = AlignedNowPlayingState()
    private var item = AVPlayerItem(asset: AVMutableComposition())
    private var player = AVPlayer()

    override func setUp() {
        super.setUp()
        harness = Harness()
        state = AlignedNowPlayingState(now: { [harness] in harness.wall })
        item = AVPlayerItem(asset: AVMutableComposition())
        player = AVPlayer(playerItem: item)
    }

    override func tearDown() {
        for session in harness.sessions { session.stop() }
        harness.sessions = []
        super.tearDown()
    }

    // MARK: - Harness helpers

    private typealias Row = (title: String?, artist: String?, album: String?, art: String?, kind: String, playedAt: Date)

    private func song(_ title: String, _ artist: String, album: String? = nil, art: String? = nil, at: Date) -> Row {
        (title, artist, album, art, "trackplay", at)
    }

    private func feed(_ rows: [Row]) -> KCRWFeedResult {
        let entries = rows.map {
            OccurrenceInput(station: "kcrw", providerID: nil, kind: $0.kind, title: $0.title, artist: $0.artist,
                            album: $0.album, artworkURL: $0.art, playedAt: $0.playedAt)
        }
        return KCRWFeedResult(entries: entries, statusCode: 200, cacheAgeSeconds: nil, failure: nil)
    }

    private func makeSession(mode: AlignmentMode = .apply,
                             stationId: String? = nil,
                             generation: UUID = UUID()) -> RadioPlaybackSession {
        let harness = self.harness
        let session = RadioPlaybackSession(
            player: player, item: item, generation: generation, endpoint: endpoint, driver: .playbackTicks,
            mode: mode, stationId: stationId ?? station, alignedState: state,
            post: { harness.posts.append($0) },
            now: { harness.now },
            emit: { harness.lines.append($0) },
            flush: {},
            fetch: { KCRWFeedResult(entries: [], statusCode: 500, cacheAgeSeconds: nil, failure: "parked") },
            install: { _, _ in NSObject() },
            remove: { _, _ in },
            observeStatus: { _, _ in NSObject() })
        harness.sessions.append(session)
        return session
    }

    private func tick(_ session: RadioPlaybackSession, elapsed: TimeInterval, media: Double, program: Date?) {
        harness.now = 1000 + elapsed
        session.sample(currentItem: session.item, rate: 1, status: .playing, mediaSeconds: media, programDate: program)
    }

    /// Song A's estimated start (base + 160) is 30 s before this program date.
    private var songAProgram: Date { base.addingTimeInterval(190) }

    private func title(_ post: [AnyHashable: Any]) -> String? { post[RadioMetadataNotificationKey.title] as? String }

    private func publishedSong() -> AlignedSong? {
        if case .song(let song)? = state.current { return song }
        return nil
    }

    private func snapshot(generation: UUID, trigger: DecisionTrigger?, occurrence: Occurrence?, programDate: Date? = nil,
                          songSeconds: Double? = 5, reason: String = "r") -> RadioAlignmentSnapshot {
        RadioAlignmentSnapshot(generation: generation, endpoint: "e", feedTop: nil,
                               candidate: occurrence?.title, candidateID: occurrence?.id, selectedOccurrence: occurrence,
                               songSeconds: songSeconds, mediaSeconds: 1, programDate: programDate ?? base,
                               reason: reason, feedStatus: "s", cacheAgeSeconds: nil, historyCount: 1,
                               lastPollElapsed: nil, clockValid: true, trigger: trigger)
    }

    /// A real selected occurrence, taken from a session that observed one row.
    private func realOccurrence(kind: String = "trackplay", title: String? = "T", artist: String? = "A") throws -> Occurrence {
        let observer = makeSession(mode: .observe, stationId: "other")
        observer.accept(feed([(title, artist, nil, nil, kind, base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(observer, elapsed: 10, media: 50, program: songAProgram)
        return try XCTUnwrap(observer.snapshot.selectedOccurrence)
    }

    // MARK: - 2 No early publication

    func testNothingPostsUntilPlayerSampleThenExactlyOnePost() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", album: "Album A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
        XCTAssertTrue(state.isApplying(stationId: station))

        tick(session, elapsed: 10, media: 50, program: songAProgram)

        XCTAssertEqual(harness.posts.count, 1)
        let post = try XCTUnwrap(harness.posts.first)
        XCTAssertEqual(post[RadioMetadataNotificationKey.stationId] as? String, station)
        XCTAssertEqual(post[RadioMetadataNotificationKey.title] as? String, "Song A")
        XCTAssertEqual(post[RadioMetadataNotificationKey.artist] as? String, "Artist A")
        XCTAssertEqual(post[RadioMetadataNotificationKey.album] as? String, "Album A")
        XCTAssertEqual(post[RadioMetadataNotificationKey.aligned] as? Bool, true)
        let published = try XCTUnwrap(publishedSong())
        XCTAssertEqual(published.title, "Song A")
        XCTAssertEqual(published.generation, session.generation)
        XCTAssertEqual(state.entry(for: station)?.album, "Album A")
        XCTAssertTrue(harness.lines.contains { $0.hasPrefix("[align] publish song=Song A — Artist A occ=") })
    }

    func testLaterFeedReceiptWithNewerRowDoesNotPostUntilNextSample() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertEqual(harness.posts.count, 1)

        session.accept(feed([song("Song B", "Artist B", at: base.addingTimeInterval(25)), song("Song A", "Artist A", at: base)]),
                       requestedElapsed: 10.5, receivedElapsed: 10.8)

        XCTAssertEqual(harness.posts.count, 1)
        XCTAssertEqual(state.entry(for: station)?.title, "Song A")

        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts[safe: 1].flatMap(title), "Song B")
        XCTAssertEqual(state.entry(for: station)?.title, "Song B")
    }

    // A feed correction to the selected song's fields republishes it on the next sample.
    func testCorrectionToTheCurrentSongRepublishes() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertEqual(harness.posts.count, 1)

        session.accept(feed([song("Song A", "Artist A", album: "Album A", at: base)]), requestedElapsed: 10.5, receivedElapsed: 10.8)
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts[safe: 1]?[RadioMetadataNotificationKey.album] as? String, "Album A")
        XCTAssertEqual(state.entry(for: station)?.album, "Album A")
    }

    // A plain pause keeps the session and its clock, so the published song stays.
    func testPausedSampleKeepsThePublishedSong() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        harness.now = 1020
        session.sample(currentItem: session.item, rate: 0, status: .paused, mediaSeconds: 50, programDate: songAProgram)

        XCTAssertEqual(harness.posts.count, 1)
        XCTAssertEqual(publishedSong()?.title, "Song A")
        XCTAssertTrue(state.isApplying(stationId: station))
    }

    func testUnchangedSongAcrossSamplesDoesNotPostAgain() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        for t in 10...14 {
            tick(session, elapsed: Double(t), media: Double(40 + t), program: songAProgram.addingTimeInterval(Double(t - 10)))
        }
        XCTAssertEqual(harness.posts.count, 1)
    }

    func testAlbumIsOmittedWhenMissingOrEmpty() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", album: "", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        let post = try XCTUnwrap(harness.posts.first)
        XCTAssertNil(post[RadioMetadataNotificationKey.album])
    }

    func testArtworkURLCarriesToStateEntry() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", art: "https://example.com/a.jpg", at: base)]),
                       requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertEqual(state.entry(for: station)?.albumArtURL, URL(string: "https://example.com/a.jpg"))
        XCTAssertNil(state.entry(for: "another-station"))
    }

    // MARK: - Gate

    func testFeedTriggeredSnapshotNeverPublishesEvenWhenEverythingElseIsValid() throws {
        let occurrence = try realOccurrence()
        let generation = UUID()
        state.beginApplying(stationId: station, generation: generation)
        let publisher = AlignedNowPlayingPublisher(stationId: station, generation: generation, state: state,
                                                   post: { [harness] in harness.posts.append($0) }, emit: { _ in })

        publisher.receive(snapshot(generation: generation, trigger: .feedUpdate, occurrence: occurrence))
        publisher.receive(snapshot(generation: generation, trigger: nil, occurrence: occurrence))

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)

        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))
        XCTAssertEqual(harness.posts.count, 1)
    }

    func testGateRejectsNonSongRowsAndBadSongSecondsAsUnavailable() throws {
        let breakRow = try realOccurrence(kind: "break")
        let noArtist = try realOccurrence(artist: "")
        let noTitle = try realOccurrence(title: nil)
        let good = try realOccurrence()
        let generation = UUID()
        state.beginApplying(stationId: station, generation: generation)
        let publisher = AlignedNowPlayingPublisher(stationId: station, generation: generation, state: state,
                                                   post: { [harness] in harness.posts.append($0) }, emit: { _ in })

        for bad in [snapshot(generation: generation, trigger: .playerSample, occurrence: breakRow),
                    snapshot(generation: generation, trigger: .playerSample, occurrence: noArtist),
                    snapshot(generation: generation, trigger: .playerSample, occurrence: noTitle),
                    snapshot(generation: generation, trigger: .playerSample, occurrence: good, songSeconds: -1),
                    snapshot(generation: generation, trigger: .playerSample, occurrence: good, songSeconds: .infinity),
                    snapshot(generation: generation, trigger: .playerSample, occurrence: good, songSeconds: nil)] {
            XCTAssertNil(AlignedNowPlayingPublisher.song(from: bad, stationId: station))
            publisher.receive(bad)
        }
        // Not a song: one explicit unavailable post, never a song.
        XCTAssertEqual(harness.posts.count, 1)
        XCTAssertEqual(harness.posts[safe: 0].flatMap(title), "")
        XCTAssertEqual(state.current, .unavailable(stationId: station, reason: "selected row is not a song"))
    }

    // MARK: - Short hold through a brief clock fault (bug: title and art blinked to the logo)

    private final class HoldHarness {
        var date = Date(timeIntervalSince1970: 2_000_000_000)
        var fire: (@MainActor () -> Void)?
        var scheduled: [TimeInterval] = []
        var cancelled = 0
        var playing = true
    }

    private func holdPublisher(_ hold: HoldHarness, generation: UUID) -> AlignedNowPlayingPublisher {
        state.beginApplying(stationId: station, generation: generation)
        let publisher = AlignedNowPlayingPublisher(
            stationId: station, generation: generation, holdDuration: 5,
            now: { hold.date },
            schedule: { delay, fire in
                hold.scheduled.append(delay)
                hold.fire = fire
                return { hold.cancelled += 1; hold.fire = nil }
            },
            state: state, post: { [harness] in harness.posts.append($0) }, emit: { [harness] in harness.lines.append($0) })
        publisher.isPlayerPlaying = { hold.playing }
        return publisher
    }

    private func faulty(_ generation: UUID, reason: String = "player clock: backwardJump") -> RadioAlignmentSnapshot {
        snapshot(generation: generation, trigger: .playerSample, occurrence: nil, songSeconds: nil, reason: reason)
    }

    func testBriefClockFaultKeepsTheSongAndPostsNothing() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))
        XCTAssertEqual(harness.posts.count, 1)

        publisher.receive(faulty(generation))
        hold.date.addTimeInterval(2)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))

        XCTAssertEqual(harness.posts.count, 1, "same song after the fault: no unavailable post, no repost")
        XCTAssertEqual(hold.scheduled, [5])
        XCTAssertEqual(hold.cancelled, 1, "the timer is cancelled once the clock re-pairs")
        if case .song? = state.current {} else { XCTFail("the song stays published") }
    }

    func testDifferentSongAfterTheFaultReplacesTheHeldOne() throws {
        let first = try realOccurrence(title: "First")
        let second = try realOccurrence(title: "Second")
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: first))

        publisher.receive(faulty(generation, reason: "player clock: correlationDiscontinuity"))
        hold.date.addTimeInterval(1)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: second))

        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts.last.flatMap(title), "Second")
    }

    func testFaultThatOutlastsTheHoldPublishesUnavailable_onASampleOrWhenTheTimerFires() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))

        publisher.receive(faulty(generation))
        hold.date.addTimeInterval(4.9)
        publisher.receive(faulty(generation))
        XCTAssertEqual(harness.posts.count, 1, "still inside the hold")
        hold.date.addTimeInterval(0.2)
        publisher.receive(faulty(generation))
        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts.last.flatMap(title), "")
        XCTAssertEqual(state.current, .unavailable(stationId: station, reason: "player clock: backwardJump"))

        // Samples can stop while the player waits. The timer then ends the hold.
        let generation2 = UUID(), hold2 = HoldHarness()
        let timed = holdPublisher(hold2, generation: generation2)
        timed.receive(snapshot(generation: generation2, trigger: .playerSample, occurrence: occurrence))
        timed.receive(faulty(generation2))
        let before = harness.posts.count
        hold2.fire?()
        XCTAssertEqual(harness.posts.count, before + 1)
        XCTAssertEqual(state.current, .unavailable(stationId: station, reason: "player clock: backwardJump"))
    }

    func testHoldDoesNotRunOutWhilePaused_thenCountsAgainOnceItPlays() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))
        publisher.receive(faulty(generation, reason: "player clock: mediaProgressionDiscontinuity"))

        // The user paused. The timer fires and a sample arrives long after 5 s, with the song still up.
        hold.playing = false
        hold.date.addTimeInterval(8)
        hold.fire?()
        publisher.receive(faulty(generation, reason: "player clock: mediaProgressionDiscontinuity"))
        XCTAssertEqual(harness.posts.count, 1, "a paused song is not replaced by the logo")
        XCTAssertEqual(hold.scheduled.count, 2, "the hold started again")

        // Playing again with the clock still invalid: the fresh hold now runs out.
        hold.playing = true
        hold.date.addTimeInterval(5.1)
        publisher.receive(faulty(generation, reason: "player clock: mediaProgressionDiscontinuity"))
        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts.last.flatMap(title), "")
    }

    func testOtherReasonsAndNoSongYetAreNotHeld() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)

        // Nothing is showing yet, so there is nothing to hold.
        publisher.receive(faulty(generation, reason: "player clock: missingPair"))
        XCTAssertEqual(harness.posts.count, 1)
        XCTAssertTrue(hold.scheduled.isEmpty)

        // A song is up, but this is not a transient fault.
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))
        publisher.receive(faulty(generation, reason: "alignment unavailable: noHistory"))
        XCTAssertEqual(harness.posts.count, 3)
        XCTAssertTrue(hold.scheduled.isEmpty)
    }

    func testEndedGenerationIgnoresAFiringHoldTimer() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))
        publisher.receive(faulty(generation))
        state.endApplying(stationId: station, generation: generation)
        let posts = harness.posts.count

        hold.fire?()

        XCTAssertEqual(harness.posts.count, posts)
        XCTAssertNil(state.current)
    }

    // MARK: - 3 Guards

    func testSnapshotFromAnotherGenerationIsRejected() throws {
        let occurrence = try realOccurrence()
        let generation = UUID()
        state.beginApplying(stationId: station, generation: generation)
        let publisher = AlignedNowPlayingPublisher(stationId: station, generation: generation, state: state,
                                                   post: { [harness] in harness.posts.append($0) }, emit: { _ in })

        publisher.receive(snapshot(generation: UUID(), trigger: .playerSample, occurrence: occurrence))

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
    }

    func testSampleAndSnapshotAfterStopDoNotPostOrChangeState() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        session.stop()

        tick(session, elapsed: 10, media: 50, program: songAProgram)
        session.accept(feed([song("Song B", "Artist B", at: base)]), requestedElapsed: 11, receivedElapsed: 12)

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
        XCTAssertFalse(state.isApplying(stationId: station))
    }

    func testPublisherAfterItsGenerationWasEndedPostsNothing() throws {
        let occurrence = try realOccurrence()
        let generation = UUID()
        state.beginApplying(stationId: station, generation: generation)
        let publisher = AlignedNowPlayingPublisher(stationId: station, generation: generation, state: state,
                                                   post: { [harness] in harness.posts.append($0) }, emit: { _ in })
        state.endApplying(stationId: station, generation: generation)

        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence))

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
    }

    func testStoppingAnOlderSessionDoesNotClearANewerOne() throws {
        let older = makeSession()
        let newer = makeSession()
        newer.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(newer, elapsed: 10, media: 50, program: songAProgram)
        let published = try XCTUnwrap(state.current)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        XCTAssertTrue(state.setArtwork(image, occurrenceID: try XCTUnwrap(publishedSong()).occurrenceID))
        XCTAssertEqual(harness.posts.count, 1)

        older.stop()

        XCTAssertTrue(state.isApplying(stationId: station))
        XCTAssertEqual(state.current, published)
        XCTAssertNotNil(state.artwork)
    }

    func testOlderSessionSampleCannotPublishOverANewerSession() {
        let older = makeSession()
        let newer = makeSession()
        older.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)

        tick(older, elapsed: 10, media: 50, program: songAProgram)

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
        XCTAssertTrue(state.isApplying(stationId: station))
        newer.stop()
    }

    // MARK: - 6 Unavailable

    func testNoHistoryPostsUnavailableOnceAndEntryIsNil() throws {
        let session = makeSession()

        tick(session, elapsed: 10, media: 50, program: songAProgram)
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        XCTAssertEqual(harness.posts.count, 1)
        let post = try XCTUnwrap(harness.posts.first)
        XCTAssertEqual(post[RadioMetadataNotificationKey.stationId] as? String, station)
        XCTAssertEqual(post[RadioMetadataNotificationKey.title] as? String, "")
        XCTAssertEqual(post[RadioMetadataNotificationKey.artist] as? String, "")
        XCTAssertEqual(post[RadioMetadataNotificationKey.aligned] as? Bool, true)
        XCTAssertNil(post[RadioMetadataNotificationKey.album])
        XCTAssertEqual(state.current, .unavailable(stationId: station, reason: "alignment unavailable: noHistory"))
        XCTAssertNil(state.entry(for: station))
        XCTAssertTrue(harness.lines.contains("[align] publish unavailable reason=alignment unavailable: noHistory"))
    }

    func testNilClockPostsUnavailableThenSongWhenClockArrives() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)

        tick(session, elapsed: 5, media: 45, program: nil)
        XCTAssertEqual(harness.posts.count, 1)
        XCTAssertEqual(harness.posts[safe: 0].flatMap(title), "")
        XCTAssertNil(state.entry(for: station))

        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts[safe: 1].flatMap(title), "Song A")
    }

    func testObserveSessionNeverPostsAndNeverSetsState() {
        let session = makeSession(mode: .observe)
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertNotNil(session.snapshot.candidate)
        tick(session, elapsed: 11, media: 51, program: nil)

        XCTAssertTrue(harness.posts.isEmpty)
        XCTAssertNil(state.current)
        XCTAssertFalse(state.isApplying(stationId: station))
        session.stop()
        XCTAssertFalse(state.isApplying(stationId: station))
        XCTAssertFalse(harness.lines.contains { $0.hasPrefix("[align] publish") })
    }

    // MARK: - 7 Lifecycle

    func testStopClearsApplyingCurrentAndArtwork() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        XCTAssertTrue(state.setArtwork(image, occurrenceID: try XCTUnwrap(publishedSong()).occurrenceID))
        XCTAssertNotNil(state.artwork)

        session.stop()

        XCTAssertFalse(state.isApplying(stationId: station))
        XCTAssertNil(state.current)
        XCTAssertNil(state.artwork)
        XCTAssertNil(state.entry(for: station))
    }

    func testNewSessionHasNewGenerationAndRepublishesTheSameSong() throws {
        let first = makeSession()
        first.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(first, elapsed: 10, media: 50, program: songAProgram)
        first.stop()
        XCTAssertEqual(harness.posts.count, 1)

        let second = makeSession()
        XCTAssertNotEqual(first.generation, second.generation)
        second.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        XCTAssertEqual(harness.posts.count, 1)
        tick(second, elapsed: 10, media: 50, program: songAProgram)

        XCTAssertEqual(harness.posts.count, 2)
        XCTAssertEqual(harness.posts[safe: 1].flatMap(title), "Song A")
        XCTAssertEqual(try XCTUnwrap(publishedSong()).generation, second.generation)
    }

    // MARK: - Artwork

    func testArtworkSetterAcceptsOnlyTheCurrentOccurrence() throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        XCTAssertFalse(state.setArtwork(image, occurrenceID: "anything"))
        XCTAssertNil(state.artwork)

        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        let current = try XCTUnwrap(publishedSong()).occurrenceID

        XCTAssertFalse(state.setArtwork(image, occurrenceID: "earlier-song"))
        XCTAssertNil(state.artwork)
        XCTAssertTrue(state.setArtwork(image, occurrenceID: current))
        XCTAssertEqual(state.artwork?.occurrenceID, current)
    }

    func testArtworkIsDroppedWhenTheSelectedSongChanges() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        let first = try XCTUnwrap(publishedSong()).occurrenceID
        let image = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2)).image { _ in }
        XCTAssertTrue(state.setArtwork(image, occurrenceID: first))

        session.accept(feed([song("Song B", "Artist B", at: base.addingTimeInterval(25)), song("Song A", "Artist A", at: base)]),
                       requestedElapsed: 10.5, receivedElapsed: 10.8)
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        XCTAssertNil(state.artwork)
        XCTAssertFalse(state.setArtwork(image, occurrenceID: first))
    }

    // MARK: - Lyric position on the player's clock

    private func lyricSeconds(_ stationId: String? = nil) -> (occurrenceID: String, seconds: Double)? {
        state.lyricPosition(stationId: stationId ?? station)
    }

    /// 1 Session position
    func testLyricPositionIsTheSessionsSongSecondsForTheCurrentOccurrence() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)

        let published = try XCTUnwrap(publishedSong())
        let position = try XCTUnwrap(lyricSeconds())
        XCTAssertEqual(position.occurrenceID, published.occurrenceID)
        let sessionSeconds = try XCTUnwrap(session.snapshot.songSeconds)
        XCTAssertEqual(position.seconds, sessionSeconds, accuracy: 0.001)
        XCTAssertEqual(position.seconds, 30, accuracy: 0.001, "song A starts 30 s before this program date")
    }

    func testLyricPositionFollowsTheNextSampleNotTheWallClock() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        // A second sample whose program date jumped ahead by 1 s while the injected clock stood still.
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        let position = try XCTUnwrap(lyricSeconds())
        XCTAssertEqual(position.seconds, 31, accuracy: 0.001)
    }

    /// 2 Pause holds the line
    func testPauseHoldsTheLyricPositionAndResumeContinuesFromIt() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 30, accuracy: 0.001)

        harness.wall.addTimeInterval(4)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 34, accuracy: 0.001, "playing: extrapolates between samples")

        session.statusChanged(.paused)
        harness.wall.addTimeInterval(15)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 34, accuracy: 0.001, "paused: the line holds")

        session.statusChanged(.playing)
        harness.wall.addTimeInterval(2)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 36, accuracy: 0.001, "resumed: continues from where it was")
    }

    func testBufferingAlsoHoldsTheLyricPosition() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)

        session.statusChanged(.waitingToPlayAtSpecifiedRate)
        harness.wall.addTimeInterval(8)

        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 30, accuracy: 0.001)
    }

    func testASampleAfterAPauseReanchorsAtThePlayersValue() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        session.statusChanged(.paused)
        harness.wall.addTimeInterval(15)

        // The next sample is the player's own value; it wins over the held one. Media time stood
        // still through the pause, so the session's clock stays consistent.
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))

        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 31, accuracy: 0.001)
    }

    /// Both clocks of the hold harness move together: the publisher's and the state's.
    private func advance(_ hold: HoldHarness, _ seconds: TimeInterval) {
        hold.date.addTimeInterval(seconds)
        harness.wall.addTimeInterval(seconds)
    }

    /// 3 Clock fault hold
    func testClockFaultKeepsExtrapolatingForFiveSecondsOfPlayingThenIsNil() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence, songSeconds: 20))
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 20, accuracy: 0.001)

        publisher.receive(faulty(generation))
        advance(hold, 4)
        publisher.receive(faulty(generation))
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 24, accuracy: 0.001, "held from the last valid sample")
        XCTAssertEqual(harness.posts.count, 1, "the title hold is unchanged")

        advance(hold, 1.2)
        publisher.receive(faulty(generation))
        XCTAssertNil(lyricSeconds(), "past 5 s of playing: no timed highlight, same moment the title lets go")
        XCTAssertEqual(harness.posts.count, 2, "unavailable was published")
    }

    func testPausedTimeDoesNotCountAgainstTheLyricHold_andTheLyricAndTitleLetGoTogether() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence, songSeconds: 20))
        publisher.receive(faulty(generation))
        advance(hold, 3)

        hold.playing = false
        publisher.playerStatusChanged(playing: false)
        advance(hold, 40)
        publisher.receive(faulty(generation))
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 23, accuracy: 0.001, "held while paused")
        XCTAssertEqual(harness.posts.count, 1, "the title is held too: the hold started again")

        hold.playing = true
        publisher.playerStatusChanged(playing: true)
        advance(hold, 1.5)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 24.5, accuracy: 0.001)
        XCTAssertEqual(harness.posts.count, 1)

        // The publisher's fresh hold ends after 5 s of playing. The lyric position goes with it.
        advance(hold, 4)
        publisher.receive(faulty(generation))
        XCTAssertNil(lyricSeconds(), "unavailable was published, so the position is gone")
        XCTAssertEqual(harness.posts.count, 2)
    }

    func testRepairedClockAfterAFaultTakesThePlayersValueAgain() throws {
        let occurrence = try realOccurrence()
        let generation = UUID(), hold = HoldHarness()
        let publisher = holdPublisher(hold, generation: generation)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence, songSeconds: 20))
        publisher.receive(faulty(generation))
        advance(hold, 3)
        publisher.receive(snapshot(generation: generation, trigger: .playerSample, occurrence: occurrence, songSeconds: 17))

        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 17, accuracy: 0.001)
        advance(hold, 10)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 27, accuracy: 0.001)
    }

    // MARK: - 8 Unavailable is explicit

    func testLyricPositionIsNilWithNoSelectedSong() {
        let session = makeSession()
        XCTAssertNil(lyricSeconds(), "before any publication")

        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        XCTAssertNil(lyricSeconds(), "a feed receipt alone gives no position")

        tick(session, elapsed: 10, media: 50, program: nil)
        XCTAssertNil(lyricSeconds(), "no paired clock, no song")
    }

    func testLyricPositionIsNilForASongPublishedWithNoValidSampleYet() {
        let generation = UUID()
        state.beginApplying(stationId: station, generation: generation)
        let published = AlignedSong(stationId: station, occurrenceID: "occ-x", title: "T", artist: "A", album: nil,
                                    artworkURL: nil, generation: generation)
        XCTAssertTrue(state.publish(.song(published), stationId: station, generation: generation))

        XCTAssertNil(lyricSeconds())
    }

    func testLyricPositionIsNilAfterUnavailableAndForAnotherStation() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertNotNil(lyricSeconds())
        XCTAssertNil(lyricSeconds("another-station"))

        // A non-transient fault fails closed at once.
        tick(session, elapsed: 11, media: 51, program: nil)
        XCTAssertNil(lyricSeconds())
        XCTAssertNil(lyricSeconds("another-station"))
    }

    func testLyricPositionIsNilForASessionThatIsNotApplying() {
        let observer = makeSession(mode: .observe)
        observer.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(observer, elapsed: 10, media: 50, program: songAProgram)

        XCTAssertNil(lyricSeconds())
        XCTAssertFalse(state.isApplying(stationId: station))
    }

    func testLyricPositionIsNilOnceTheGenerationEnds() {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        XCTAssertNotNil(lyricSeconds())

        session.stop()

        XCTAssertNil(lyricSeconds())
    }

    func testAnEndedGenerationCannotFeedANewerSessionsPosition() throws {
        let older = UUID(), newer = UUID()
        state.beginApplying(stationId: station, generation: older)
        state.beginApplying(stationId: station, generation: newer)
        let published = AlignedSong(stationId: station, occurrenceID: "occ-x", title: "T", artist: "A", album: nil,
                                    artworkURL: nil, generation: newer)
        XCTAssertTrue(state.publish(.song(published), stationId: station, generation: newer))

        state.recordSongSample(occurrenceID: "occ-x", songSeconds: 99, playing: true, stationId: station, generation: older)
        state.recordPlaying(false, stationId: station, generation: older)
        XCTAssertNil(lyricSeconds(), "the older generation's sample is dropped")

        state.recordSongSample(occurrenceID: "occ-x", songSeconds: 5, playing: true, stationId: station, generation: newer)
        XCTAssertEqual(try XCTUnwrap(lyricSeconds()).seconds, 5, accuracy: 0.001)
    }

    func testANewSongStartsFromItsOwnSampleNotTheOldOnesPosition() throws {
        let session = makeSession()
        session.accept(feed([song("Song A", "Artist A", at: base)]), requestedElapsed: 1, receivedElapsed: 2)
        tick(session, elapsed: 10, media: 50, program: songAProgram)
        let first = try XCTUnwrap(lyricSeconds())

        session.accept(feed([song("Song B", "Artist B", at: base.addingTimeInterval(25)), song("Song A", "Artist A", at: base)]),
                       requestedElapsed: 10.5, receivedElapsed: 10.8)
        tick(session, elapsed: 11, media: 51, program: songAProgram.addingTimeInterval(1))
        let second = try XCTUnwrap(lyricSeconds())

        XCTAssertNotEqual(second.occurrenceID, first.occurrenceID)
        let sessionSeconds = try XCTUnwrap(session.snapshot.songSeconds)
        XCTAssertEqual(second.seconds, sessionSeconds, accuracy: 0.001)
    }
}
