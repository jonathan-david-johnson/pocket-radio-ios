import XCTest

/// Playback lifecycle checks; resets happen only between scenarios.
final class CarPlayLifecycleTests: FeatureTestCase {
    override class var featurePath: String { contractsFeature("now_playing/carplay_lifecycle.feature") }
    override class var knownBugs: KnownBugs.Table { KnownBugs.lifecycle }

    override func registerSteps(_ registry: StepLibrary) {
        let steps = NowPlayingSteps(world: world)
        steps.lifecycleTraceEnabled = true
        steps.retainUntilTeardown(of: self)
        steps.register(in: registry)
    }
}
