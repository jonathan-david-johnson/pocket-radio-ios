import AVFoundation
import XCTest

@testable import podcasts

/// Observe switch and readout: the view model's persistence and formatting.
@MainActor
final class AlignmentObserveViewModelTests: XCTestCase {
    private let suiteName = "AlignmentObserveViewModelTests"
    private var defaults: UserDefaults!
    private var store: AlignmentSwitchStore!
    private var now: TimeInterval = 1000
    private var session: RadioPlaybackSession?
    private var provided: RadioPlaybackSession?
    private let utc = TimeZone(identifier: "UTC")!
    private let endpoint = URL(string: "https://user:pw@streams.kcrw.com/e24_aac/playlist.m3u8?token=secret")!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
        store = AlignmentSwitchStore(defaults: defaults)
        now = 1000
        session = nil
        provided = nil
    }

    override func tearDown() {
        session?.stop()
        defaults.removePersistentDomain(forName: suiteName)
        super.tearDown()
    }

    private let alignedState = AlignedNowPlayingState()

    private func makeModel() -> AlignmentObserveViewModel {
        AlignmentObserveViewModel(store: store, sessionProvider: { [unowned self] in provided },
                                  alignedState: alignedState, timeZone: utc)
    }

    private func makeSession() -> RadioPlaybackSession {
        let item = AVPlayerItem(asset: AVMutableComposition())
        let s = RadioPlaybackSession(
            player: AVPlayer(playerItem: item), item: item, endpoint: endpoint,
            now: { [unowned self] in now }, emit: { _ in }, flush: {},
            fetch: { AlignmentFeedResult(entries: [], statusCode: 500, cacheAgeSeconds: nil, failure: "x") },
            install: { _, _ in NSObject() }, remove: { _, _ in }, observeStatus: { _, _ in NSObject() },
            skew: { _ in 160 }, startsPoller: false)
        session = s
        provided = s
        return s
    }

    private func value(_ rows: [AlignmentObserveViewModel.Row], _ label: String) -> String? {
        rows.first { $0.label == label }?.value
    }

    func testModeDefaultsOffAndPersistsInSuite() {
        let model = makeModel()
        XCTAssertEqual(model.mode, .off)
        model.mode = .on
        let reread = AlignmentSwitchStore(defaults: UserDefaults(suiteName: suiteName)!)
        XCTAssertEqual(reread.mode, .on)
        XCTAssertTrue(reread.isOn)
    }

    func testNoActiveSession() {
        let model = makeModel()
        model.refresh()
        XCTAssertEqual(model.statusText, "No active session")
        XCTAssertTrue(model.sessionRows.isEmpty)
        XCTAssertTrue(model.monitorRows.isEmpty)
    }

    func testFreshSessionShowsNilFieldsAsNone() {
        _ = makeSession()
        let model = makeModel()
        model.refresh()
        XCTAssertNil(model.statusText)
        XCTAssertEqual(value(model.sessionRows, "Endpoint"), "streams.kcrw.com/e24_aac/playlist.m3u8")
        XCTAssertEqual(value(model.sessionRows, "Clock"), "invalid")
        XCTAssertEqual(value(model.sessionRows, "Program date"), "none")
        XCTAssertEqual(value(model.sessionRows, "Media seconds"), "none")
        XCTAssertEqual(value(model.sessionRows, "Candidate"), "none")
        XCTAssertEqual(value(model.sessionRows, "Song seconds"), "none")
        XCTAssertEqual(value(model.sessionRows, "Cache age"), "none")
        XCTAssertEqual(value(model.sessionRows, "Last poll"), "none")
        XCTAssertEqual(value(model.sessionRows, "Feed top (evidence only)"), "none")
        XCTAssertEqual(value(model.sessionRows, "History count"), "0")
        XCTAssertEqual(value(model.sessionRows, "Feed status"), "not requested")
        XCTAssertEqual(value(model.sessionRows, "Generation")?.count, 8)
    }

    func testProgramDateFormatsLocalAndUTC() {
        let model = makeModel()
        let date = Date(timeIntervalSince1970: 1_700_000_000) // 22:13:20 UTC
        XCTAssertEqual(model.formatProgramDate(date), "22:13:20 UTC")
        XCTAssertEqual(model.formatProgramDate(nil), "none")
        let pst = AlignmentObserveViewModel(store: store, sessionProvider: { nil },
                                            timeZone: TimeZone(identifier: "America/Los_Angeles")!)
        XCTAssertEqual(pst.formatProgramDate(date), "14:13:20 local / 22:13:20 UTC")
    }

    func testSampledSessionShowsClockMediaAndMonitor() {
        let s = makeSession()
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        for i in 0 ..< 3 {
            now = 1000 + Double(i)
            s.sample(currentItem: s.item, rate: 1, status: .playing, mediaSeconds: 50 + Double(i), programDate: date)
        }
        let model = makeModel()
        model.refresh()
        XCTAssertEqual(value(model.sessionRows, "Clock"), "valid")
        XCTAssertEqual(value(model.sessionRows, "Media seconds"), "52.0")
        XCTAssertEqual(value(model.monitorRows, "Samples"), "3")
        XCTAssertEqual(value(model.monitorRows, "Poll attempts / failures"), "0 / 0")
        XCTAssertEqual(value(model.monitorRows, "Rate range"), "1.00-1.00")
        XCTAssertEqual(value(model.monitorRows, "Longest sample gap"), "1.0 s")
        XCTAssertEqual(value(model.monitorRows, "Verdict"), "FAIL")
        XCTAssertTrue(model.verdictLines.contains { $0.contains("poll attempts 0 below 58") })
    }

    func testReadoutShowsPublishedStateNoneSongAndUnavailable() {
        _ = makeSession()
        let model = makeModel()
        model.refresh()
        XCTAssertEqual(value(model.sessionRows, "Published"), "none")

        let gen = UUID()
        alignedState.beginApplying(stationId: "st", generation: gen)
        alignedState.publish(.unavailable(stationId: "st", reason: "no history"), stationId: "st", generation: gen)
        model.refresh()
        XCTAssertEqual(value(model.sessionRows, "Published"), "unavailable: no history")

        let song = AlignedSong(stationId: "st", occurrenceID: "o1", title: "T", artist: "A", album: nil,
                               artworkURL: nil, generation: gen)
        alignedState.publish(.song(song), stationId: "st", generation: gen)
        model.refresh()
        XCTAssertEqual(value(model.sessionRows, "Published"), "song: T — A")
    }
}
