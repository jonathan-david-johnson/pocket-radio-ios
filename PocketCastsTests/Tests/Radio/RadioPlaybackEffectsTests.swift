import XCTest
@testable import podcasts

final class RadioPlaybackEffectsTests: XCTestCase {
    private func podcastEffects() -> PlaybackEffects {
        let effects = PlaybackEffects()
        effects.playbackSpeed = 1.1
        effects.trimSilence = .high
        effects.volumeBoost = true
        return effects
    }

    func testRadioIgnoresPodcastSpeedAndProcessingWithoutMutatingPreferences() {
        let configured = podcastEffects()
        let radio = PlaybackEffects.forPlayback(isRadio: true, configuredEffects: configured)
        XCTAssertEqual(radio.playbackSpeed, 1)
        XCTAssertEqual(radio.trimSilence, .off)
        XCTAssertFalse(radio.volumeBoost)
        XCTAssertFalse(radio.isGlobal)
        XCTAssertEqual(configured.playbackSpeed, 1.1)
        XCTAssertEqual(configured.trimSilence, .high)
        XCTAssertTrue(configured.volumeBoost)
    }

    func testRadioDoesNotReadConfiguredEffects() {
        func unexpectedRead() -> PlaybackEffects {
            XCTFail("radio must not read cached or persisted podcast effects")
            return podcastEffects()
        }
        let radio = PlaybackEffects.forPlayback(isRadio: true, configuredEffects: unexpectedRead())
        XCTAssertFalse(radio.effectsEnabled())
    }

    func testPodcastRadioPodcastRestoresTheSameConfiguredEffects() {
        let configured = podcastEffects()
        XCTAssertTrue(PlaybackEffects.forPlayback(isRadio: false, configuredEffects: configured) === configured)
        _ = PlaybackEffects.forPlayback(isRadio: true, configuredEffects: configured)
        let restored = PlaybackEffects.forPlayback(isRadio: false, configuredEffects: configured)
        XCTAssertTrue(restored === configured)
        XCTAssertEqual(restored.playbackSpeed, 1.1)
    }

    func testMutatingRadioEffectsCannotChangeNextReadOrPodcastPreferences() {
        let configured = podcastEffects()
        let radio = PlaybackEffects.forPlayback(isRadio: true, configuredEffects: configured)
        radio.playbackSpeed = 2
        radio.volumeBoost = true
        let next = PlaybackEffects.forPlayback(isRadio: true, configuredEffects: configured)
        XCTAssertFalse(next.effectsEnabled())
        XCTAssertEqual(configured.playbackSpeed, 1.1)
    }
}
