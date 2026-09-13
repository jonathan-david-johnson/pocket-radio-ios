import MediaPlayer
import XCTest
import PocketCastsDataModel
@testable import podcasts

/// M7.1: For live radio streams we replace skip-back / skip-forward with mute + stop.
/// These tests verify the `PlaybackManager` policy that toggles which lock-screen
/// `MPRemoteCommandCenter` commands are enabled per item type, and the in-app mute
/// state machine. UI swap is covered by manual smoke (UIKit + XIB outlets).
final class RadioPlaybackControlsTests: XCTestCase {
    private var manager: PlaybackManager!

    override func setUp() {
        super.setUp()
        manager = PlaybackManager()
    }

    override func tearDown() {
        // Leave the shared command center in a permissive state for sibling tests:
        // re-enable the skip commands (the default for podcasts) and disable stop.
        manager.updateRemoteCommandEnabledState(for: nil)
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.skipBackwardCommand.isEnabled = true
        commandCenter.skipForwardCommand.isEnabled = true
        commandCenter.previousTrackCommand.isEnabled = true
        commandCenter.nextTrackCommand.isEnabled = true
        commandCenter.stopCommand.isEnabled = false
        manager = nil
        super.tearDown()
    }

    private func makeRadioStation() -> RadioStation {
        let station = RadioStation(
            stationId: "test-station",
            name: "Test Radio",
            streamUrl: "https://example.test/stream"
        )
        // `PlaybackManager.isLiveStream(_:)` consults `RadioStationRegistry` (not the
        // runtime type) so the predicate survives the `load(episode:)` round-trip
        // through SQLite that turns a `RadioStation` into an `Episode` shim.
        RadioStationRegistry.shared.register(station)
        return station
    }

    /// Mirrors the real-world bug: `load(episode:)` saves the RadioStation into the
    /// SQLite episode table, so subsequent `currentEpisode()` reads return an
    /// `Episode` with the radio uuid, not the original `RadioStation`. The predicate
    /// must still recognise it via the registry.
    private func makeShimEpisodeForRegisteredRadio() -> Episode {
        let station = makeRadioStation()
        let shim = Episode()
        shim.uuid = station.uuid
        shim.title = station.title
        return shim
    }

    private func makePodcastEpisode() -> Episode {
        let episode = Episode()
        episode.uuid = "test-episode"
        episode.title = "Test Episode"
        return episode
    }

    // MARK: - Remote command policy

    func testRadioStationDisablesAllSkipStyleRemoteCommandsAndEnablesStop() {
        manager.updateRemoteCommandEnabledState(for: makeRadioStation())

        let commandCenter = MPRemoteCommandCenter.shared()
        XCTAssertFalse(commandCenter.skipBackwardCommand.isEnabled, "skipBackwardCommand must be disabled for radio")
        XCTAssertFalse(commandCenter.skipForwardCommand.isEnabled, "skipForwardCommand must be disabled for radio")
        XCTAssertFalse(commandCenter.previousTrackCommand.isEnabled, "previousTrackCommand must be disabled for radio")
        XCTAssertFalse(commandCenter.nextTrackCommand.isEnabled, "nextTrackCommand must be disabled for radio")
        XCTAssertTrue(commandCenter.stopCommand.isEnabled, "stopCommand must be enabled for radio")
    }

    func testRegularEpisodeEnablesSkipStyleRemoteCommandsAndDisablesStop() {
        // Prime with the radio state first to confirm we actually flip back.
        manager.updateRemoteCommandEnabledState(for: makeRadioStation())
        manager.updateRemoteCommandEnabledState(for: makePodcastEpisode())

        let commandCenter = MPRemoteCommandCenter.shared()
        XCTAssertTrue(commandCenter.skipBackwardCommand.isEnabled, "skipBackwardCommand must be enabled for a podcast episode")
        XCTAssertTrue(commandCenter.skipForwardCommand.isEnabled, "skipForwardCommand must be enabled for a podcast episode")
        XCTAssertTrue(commandCenter.previousTrackCommand.isEnabled, "previousTrackCommand must be enabled for a podcast episode")
        XCTAssertTrue(commandCenter.nextTrackCommand.isEnabled, "nextTrackCommand must be enabled for a podcast episode")
        XCTAssertFalse(commandCenter.stopCommand.isEnabled, "stopCommand must remain disabled for podcasts — upstream UX regression risk")
    }

    func testShimEpisodeForRegisteredRadioIsTreatedAsLiveStream() {
        // The real bug this milestone hit: PlaybackManager.load(episode:) saves the
        // RadioStation into SQLite, so currentEpisode() later returns a plain Episode
        // shim with the same uuid. `is RadioStation` fails; the registry-based
        // predicate must still flag it as a live stream.
        let shim = makeShimEpisodeForRegisteredRadio()
        XCTAssertFalse(shim is RadioStation, "Sanity: the shim must not be a RadioStation, otherwise this test proves nothing")
        XCTAssertTrue(manager.isLiveStream(shim), "Shim Episode with a registered radio uuid must be recognised as a live stream")

        manager.updateRemoteCommandEnabledState(for: shim)
        let commandCenter = MPRemoteCommandCenter.shared()
        XCTAssertFalse(commandCenter.skipBackwardCommand.isEnabled, "skip commands must be disabled for a radio shim")
        XCTAssertTrue(commandCenter.stopCommand.isEnabled, "stopCommand must be enabled for a radio shim")
    }

    func testNilEpisodeBehavesLikeRegularEpisodeForCommandState() {
        manager.updateRemoteCommandEnabledState(for: makeRadioStation())
        manager.updateRemoteCommandEnabledState(for: nil)

        let commandCenter = MPRemoteCommandCenter.shared()
        XCTAssertTrue(commandCenter.skipBackwardCommand.isEnabled)
        XCTAssertFalse(commandCenter.stopCommand.isEnabled)
    }

    func testRegisteredRadioShimReceivesNeutralEffects() {
        let configured = PlaybackEffects()
        configured.playbackSpeed = 1.1
        configured.volumeBoost = true
        let shim = makeShimEpisodeForRegisteredRadio()
        let effective = PlaybackEffects.forPlayback(isRadio: manager.isLiveStream(shim), configuredEffects: configured)
        XCTAssertEqual(effective.playbackSpeed, 1)
        XCTAssertFalse(effective.effectsEnabled())
        XCTAssertEqual(configured.playbackSpeed, 1.1)
    }

    // MARK: - shouldUseMuteControls (M7.2)

    func testShouldUseMuteControlsTrueForLiveRadioWithoutPlayer() {
        // No AVPlayer attached → `player?.duration() ?? -1` is -1 which is ≤ 0,
        // so a registered live radio station correctly qualifies for the mute
        // swap. Mirrors the live-stream case (indefinite duration).
        XCTAssertTrue(manager.shouldUseMuteControls(for: makeRadioStation()))
    }

    func testShouldUseMuteControlsFalseForRegularPodcastEpisode() {
        XCTAssertFalse(manager.shouldUseMuteControls(for: makePodcastEpisode()))
    }

    // MARK: - Mute state

    func testToggleMuteFlipsIsMuted() {
        XCTAssertFalse(manager.isMuted)
        manager.toggleMute()
        XCTAssertTrue(manager.isMuted)
        manager.toggleMute()
        XCTAssertFalse(manager.isMuted)
    }

    func testCurrentlyPlayingEpisodeUpdatedResetsMuteState() {
        manager.toggleMute()
        XCTAssertTrue(manager.isMuted)

        // The PlaybackManager listens on `currentlyPlayingEpisodeUpdated`. Posting it
        // exercises the same reset path the player triggers on every item change,
        // so mute does not bleed across items (radio → podcast or radio → nothing).
        let expectation = XCTNSNotificationExpectation(name: Constants.Notifications.playbackMuteChanged)
        NotificationCenter.default.post(name: Constants.Notifications.currentlyPlayingEpisodeUpdated, object: nil)
        wait(for: [expectation], timeout: 1.0)

        XCTAssertFalse(manager.isMuted, "Mute must reset on every item change")
    }
}
