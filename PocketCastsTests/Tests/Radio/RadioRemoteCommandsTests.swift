import MediaPlayer
import XCTest
@testable import podcasts

final class RadioRemoteCommandsTests: XCTestCase {
    func test_podcast_hasSkip_noStop() {
        let plan = RadioRemoteCommands.plan(liveStream: false, stoppedStation: false)
        XCTAssertTrue(plan.skipAndTrack)
        XCTAssertFalse(plan.stop)
        XCTAssertTrue(plan.play && plan.pause && plan.togglePlayPause)
    }

    func test_liveStream_hasStop_noSkip() {
        let plan = RadioRemoteCommands.plan(liveStream: true, stoppedStation: false)
        XCTAssertFalse(plan.skipAndTrack)
        XCTAssertTrue(plan.stop)
        XCTAssertTrue(plan.play && plan.pause && plan.togglePlayPause)
    }

    func test_stoppedStation_offersPlayOnly() {
        let plan = RadioRemoteCommands.plan(liveStream: false, stoppedStation: true)
        XCTAssertTrue(plan.play)
        XCTAssertTrue(plan.togglePlayPause)
        XCTAssertFalse(plan.pause, "nothing is playing to pause")
        XCTAssertFalse(plan.stop)
        XCTAssertFalse(plan.skipAndTrack)
    }

    func test_stoppedEntry_isAStoppedLiveStreamNamedForTheStation() {
        let info = NowPlayingHelper.stoppedRadioInfo(stationName: "KCRW Eclectic 24")
        XCTAssertEqual(info[MPMediaItemPropertyTitle] as? String, "KCRW Eclectic 24")
        XCTAssertEqual((info[MPNowPlayingInfoPropertyPlaybackRate] as? NSNumber)?.doubleValue, 0)
        XCTAssertEqual((info[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue, true)
        XCTAssertEqual((info[MPMediaItemPropertyPlaybackDuration] as? NSNumber)?.doubleValue, 0)
    }
}
