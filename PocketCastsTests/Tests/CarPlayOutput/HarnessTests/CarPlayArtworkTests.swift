import XCTest

/// Artwork policy checks; only evidenced iOS output defects carry strict markers.
final class CarPlayArtworkTests: FeatureTestCase {
    override class var featurePath: String { contractsFeature("now_playing/carplay_artwork.feature") }
    override class var knownBugs: KnownBugs.Table { KnownBugs.artwork }

    override func registerSteps(_ registry: StepLibrary) {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.register(in: registry)
    }
}
