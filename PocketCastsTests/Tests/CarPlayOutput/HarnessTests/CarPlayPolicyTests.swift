import XCTest

/// All three shared, unmarked policy scenarios. Real step cleanup precedes reset.
final class CarPlayPolicyTests: FeatureTestCase {
    static let adScenario = "An ad frame leaves the current title artist and artwork unchanged"
    static let markerScenario = "Live music markers survive initial metadata artwork and rebuild writes"
    static let lyricScenario = "CarPlay suppresses lyric album writes and disconnect restores the real album"

    override class var featurePath: String { contractsFeature("now_playing/carplay_policy.feature") }

    override func registerSteps(_ registry: StepLibrary) {
        let steps = NowPlayingSteps(world: world)
        steps.lifecycleTraceEnabled = true
        if currentScenario?.name == Self.markerScenario { steps.markerObservation = MarkerWriteObservation() }
        steps.retainUntilTeardown(of: self)
        steps.register(in: registry)
    }
}
