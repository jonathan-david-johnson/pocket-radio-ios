import XCTest
@testable import podcasts

final class NowPlayingStepsTests: HarnessScenarioCase {
    func testOrdinaryFeaturePhrasesResolveExactlyOnce() {
        let steps = StepLibrary()
        NowPlayingSteps(world: try! FakeWorld()).register(in: steps)
        let phrases = [
            "the station's tracklist lists only \"Song A\" by \"Artist A\" from album \"Album A\" with red artwork",
            "the station's tracklist also lists \"Song B\" by \"Artist B\" with green artwork",
            "the station's tracklist lists \"Song A\" by \"Artist A\" with red artwork that takes 20 seconds to download",
            "the station's tracklist lists only \"Song A\" by \"Artist A\" from album \"Album A\" without artwork",
            "iTunes finds blue artwork for \"Song A\" by \"Artist A\"",
            "the display shows the title \"Song A\" with red artwork",
            "the display shows the album \"Album A\"",
            "the display does not show the album \"Album A\"",
            "the display shows the station logo",
            "the display keeps red artwork for 2 seconds",
            "the display keeps the current title artist and artwork for 8 seconds",
            "the iTunes lookup for \"Song A\" by \"Artist A\" was served",
            "the stream sends an ad frame"
        ]
        for phrase in phrases {
            XCTAssertEqual(steps.matches(phrase).count, 1, "expected exactly one definition for: \(phrase)")
        }
    }

    func testArtFixtureUsesCapturePositionAndRejectsUnknownColours() throws {
        let world = try FakeWorld()
        let steps = StepLibrary()
        NowPlayingSteps(world: world).register(in: steps)

        let valid = FeatureStep(keyword: "Given", text: "the station's tracklist lists only \"red song\" by \"red artist\" from album \"Album\" with blue artwork", line: 2)
        let validScenario = FeatureScenario(name: "fixture", tags: [], line: 1, featurePath: "fixture.feature", steps: [valid])
        XCTAssertNil(FeatureExecution.run(scenario: validScenario, steps: steps))
        XCTAssertEqual(world.configuredTracklist.first?.art, "blue")

        let invalid = FeatureStep(keyword: "Given", text: "the station's tracklist lists only \"Song\" by \"Artist\" with purple artwork", line: 3)
        let invalidScenario = FeatureScenario(name: "fixture", tags: [], line: 1, featurePath: "fixture.feature", steps: [invalid])
        let failure = try XCTUnwrap(FeatureExecution.run(scenario: invalidScenario, steps: steps))
        XCTAssertNil(failure.outputAssertionDiagnostic, "fixture configuration errors must remain ordinary step failures")
        XCTAssertTrue(failure.errorText?.contains("unknown artwork colour 'purple'") == true)
    }

    func testForbiddenAlbumAllowsAbsentEmptyAndDifferentAlbums() {
        let allowed: [String?] = [nil, "", "Album B"]
        for album in allowed {
            let snapshot = NowPlayingProbe.Snapshot(isEmpty: false, title: "Song B", artist: "Artist B", album: album)
            XCTAssertNoThrow(try NowPlayingSteps.requireAlbumNotEqual("Album A", snapshot: snapshot,
                                                                      expectedTitle: "Song B", expectedArtist: "Artist B"))
        }
        let forbidden = NowPlayingProbe.Snapshot(isEmpty: false, title: "Song B", artist: "Artist B", album: "Album A")
        XCTAssertThrowsError(try NowPlayingSteps.requireAlbumNotEqual("Album A", snapshot: forbidden,
                                                                     expectedTitle: "Song B", expectedArtist: "Artist B")) { error in
            XCTAssertEqual((error as? StepFailure)?.outputAssertionDiagnostic, "display.album.not-equal")
        }
    }

    func testForbiddenAlbumRejectsMissingOrWrongDisplayIdentityAsOrdinaryFailure() {
        let invalid = [
            NowPlayingProbe.Snapshot(isEmpty: true),
            NowPlayingProbe.Snapshot(isEmpty: false, title: "Song A", artist: "Artist B"),
            NowPlayingProbe.Snapshot(isEmpty: false, title: "Song B", artist: "Artist A")
        ]
        for snapshot in invalid {
            XCTAssertThrowsError(try NowPlayingSteps.requireAlbumNotEqual("Album A", snapshot: snapshot,
                                                                         expectedTitle: "Song B", expectedArtist: "Artist B")) { error in
                XCTAssertNil((error as? StepFailure)?.outputAssertionDiagnostic)
            }
        }
    }

    func testOutputAssertionCarriesStableExpectationDiagnosticOnly() {
        let registry = StepLibrary()
        registry.add("the output assertion fails") { _ in
            throw StepFailure.outputAssertion(diagnostic: "display.title-artwork", message: "snapshot mismatch")
        }
        let scenario = FeatureScenario(name: "synthetic", tags: [], line: 1, featurePath: "synthetic.feature",
                                       steps: [FeatureStep(keyword: "Then", text: "the output assertion fails", line: 2)])
        let failure = FeatureExecution.run(scenario: scenario, steps: registry)
        XCTAssertEqual(failure?.outputAssertionDiagnostic, "display.title-artwork")
        XCTAssertEqual(failure?.kind, .stepFailed)

        let precondition = StepLibrary()
        precondition.add("the precondition fails") { _ in throw StepFailure(message: "not ready") }
        let preconditionScenario = FeatureScenario(name: "synthetic", tags: [], line: 1, featurePath: "synthetic.feature",
                                                  steps: [FeatureStep(keyword: "Then", text: "the precondition fails", line: 2)])
        XCTAssertNil(FeatureExecution.run(scenario: preconditionScenario, steps: precondition)?.outputAssertionDiagnostic)
    }
}
