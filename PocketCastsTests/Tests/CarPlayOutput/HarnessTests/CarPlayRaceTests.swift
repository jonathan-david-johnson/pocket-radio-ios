import XCTest

/// Late-artwork checks; the song-to-song guard remains unmarked.
final class CarPlayRaceTests: FeatureTestCase {
    override class var featurePath: String { contractsFeature("now_playing/carplay_races.feature") }
    override class var knownBugs: KnownBugs.Table { KnownBugs.races }

    override func registerSteps(_ registry: StepLibrary) {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        steps.register(in: registry)
    }
}
