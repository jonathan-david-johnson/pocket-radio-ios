import XCTest
@testable import podcasts

@MainActor
final class StationDetailRecalibrateTests: XCTestCase {
    private let stationId = "heal-station"
    private let generation = UUID()
    private var state: AlignedNowPlayingState { .shared }

    override func setUp() {
        super.setUp()
        state.beginApplying(stationId: stationId, generation: generation)
    }

    override func tearDown() {
        state.endApplying(stationId: stationId, generation: generation)
        super.tearDown()
    }

    private func makeScreen(lyricSync: LyricSyncController? = nil) -> StationDetailViewController {
        let station = RadioStation(stationId: stationId, name: "KCRW", streamUrl: "https://example.test/stream",
                                   tracklistUrl: "https://example.test/tracklist")
        let vc = StationDetailViewController(station: station, lyricSync: lyricSync)
        vc.loadViewIfNeeded()
        vc.viewWillAppear(false)
        return vc
    }

    private func pump(_ seconds: TimeInterval = 0.1) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }

    func test_theButtonShowsWhileApplyingAndHidesWhenTheSessionEnds() {
        let vc = makeScreen()
        XCTAssertFalse(vc._healHiddenForTesting)
        state.endApplying(stationId: stationId, generation: generation)
        vc.viewWillAppear(false)
        XCTAssertTrue(vc._healHiddenForTesting)
    }

    func test_tappingShowsProgressInTheLyricHeaderAndThenTheResult() async {
        let vc = makeScreen()
        vc.calibrationResultHold = 60
        vc.recalibrationRunner = { report in
            report("Listening to the speaker… (1/3)")
            report("Audio is 3.0 s ahead of the screen (1/3)")
            report("Timing corrected by +3.0 s")
            return true
        }
        XCTAssertFalse(vc._showsHeaderForTesting, "no lyrics, so no header yet")

        vc._tapHealForTesting()
        await pump()

        XCTAssertEqual(vc._calibrationStatusForTesting, "Timing corrected by +3.0 s")
        XCTAssertEqual(vc._headerTextForTesting, "Timing corrected by +3.0 s")
        XCTAssertTrue(vc._showsHeaderForTesting, "the header row appears for the status even with no lyrics")
        XCTAssertFalse(vc._calibrationRunningForTesting)
    }

    func test_theLyricLineDoesNotOverwriteTheStatusWhileItShows() async {
        let sync = LyricSyncController(stationId: stationId, stationDisplayTitle: "KCRW")
        let vc = makeScreen(lyricSync: sync)
        vc.calibrationResultHold = 60
        vc.recalibrationRunner = { report in report("Listening to the speaker… (1/3)"); return true }
        vc._tapHealForTesting()
        await pump()

        vc.lyricSyncController(sync, didUpdateHeaderText: "♪ some lyric line")
        XCTAssertEqual(vc._headerTextForTesting, "Listening to the speaker… (1/3)")
    }

    func test_theHeaderHandsBackToTheLyricsAfterTheResultHold() async {
        let vc = makeScreen()
        vc.calibrationResultHold = 0.05
        vc.recalibrationRunner = { report in report("In sync (+0.4 s). No change."); return true }
        vc._tapHealForTesting()
        await pump(0.3)
        XCTAssertNil(vc._calibrationStatusForTesting)
        XCTAssertFalse(vc._showsHeaderForTesting)
    }

    func test_aSecondTapWhileRunningIsIgnored() async {
        let vc = makeScreen()
        vc.calibrationResultHold = 60
        var runs = 0
        vc.recalibrationRunner = { report in
            runs += 1
            report("Listening to the speaker… (1/3)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            return true
        }
        vc._tapHealForTesting()
        vc._tapHealForTesting()
        await pump(0.5)
        XCTAssertEqual(runs, 1)
    }

    func test_leavingTheScreenMidHealDoesNotCancelTheHeal() async {
        let vc = makeScreen()
        vc.calibrationResultHold = 60
        var finished = false
        vc.recalibrationRunner = { report in
            report("Listening to the speaker… (1/3)")
            try? await Task.sleep(nanoseconds: 300_000_000)
            finished = !Task.isCancelled
            report("Timing corrected by +3.0 s")
            return true
        }
        vc._tapHealForTesting()
        await pump(0.05)
        vc.viewDidDisappear(false)
        XCTAssertTrue(vc._calibrationRunningForTesting, "the heal is still running after the screen is left")
        await pump(0.5)
        XCTAssertTrue(finished, "it was not cancelled")
        XCTAssertFalse(vc._calibrationRunningForTesting)
    }

    func test_leavingTheScreenCancelsAnUnfinishedRecalibrationHold() async {
        let vc = makeScreen()
        vc.calibrationResultHold = 60
        vc.recalibrationRunner = { report in report("done"); return true }
        vc._tapHealForTesting()
        await pump()
        vc.viewDidDisappear(false)
        XCTAssertNil(vc._calibrationStatusForTesting)
    }
}
