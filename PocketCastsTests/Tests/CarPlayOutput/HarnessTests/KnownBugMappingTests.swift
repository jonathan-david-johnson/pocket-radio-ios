import XCTest

/// Checks the real iOS table and the production step diagnostics, not a catch-all xfail.
final class KnownBugMappingTests: HarnessScenarioCase {
    private let suites: [FeatureTestCase.Type] = [CarPlayArtworkTests.self, CarPlayLifecycleTests.self, CarPlayRaceTests.self]

    private func failure(_ marker: KnownBug, keyword: String = "Then", diagnostic: String?) -> FeatureFailure {
        FeatureFailure(kind: .stepFailed, keyword: keyword, stepText: marker.stepText,
                       featurePath: "fixture.feature", line: 2, outputAssertionDiagnostic: diagnostic)
    }

    func testActualTablesHaveUniqueValidDesignatedOutputChecks() throws {
        var scenarioNames = Set<String>()
        var markerCount = 0
        for suite in suites {
            let feature = try FeatureParser.parse(path: suite.featurePath)
            try KnownBugs.validate(suite.knownBugs, in: feature)
            for (name, markers) in suite.knownBugs {
                XCTAssertTrue(scenarioNames.insert(name).inserted)
                let scenario = try XCTUnwrap(feature.scenarios.first { $0.name == name })
                for marker in markers {
                    markerCount += 1
                    XCTAssertEqual(scenario.steps.filter { $0.keyword == "Then" && $0.text == marker.stepText }.count, 1)
                    XCTAssertTrue(["bug_4", "bug_5", "bug_6"].contains(marker.bugID))
                    XCTAssertTrue(marker.matches(failure(marker, diagnostic: marker.assertionDiagnostic)))
                }
            }
        }
        XCTAssertEqual(scenarioNames.count, 7)
        XCTAssertEqual(markerCount, 9)
        XCTAssertTrue(CarPlayPolicyTests.knownBugs.isEmpty)
        XCTAssertTrue(NowPlayingSmokeTests.knownBugs.isEmpty)
    }

    func testOnlyTheEvidencedChecksAreDesignated() {
        let expected: [String: Set<String>] = [
            "A second song without station detail does not keep the previous artwork": ["display.artwork.station-logo"],
            "A tracklist one song behind lends neither its album nor its artwork": ["display.album.not-equal", "display.artwork.station-logo"],
            "Pausing and resuming keeps the current song's artwork": ["display.title-artwork.artwork"],
            "A cached tracklist at playback start keeps the artwork": ["display.title-artwork.artwork", "display.sustained-artwork.artwork"],
            "Stopping and replaying the same song resolves its artwork again": ["display.title-artwork.artwork"],
            "Switching stations prevents the old station's artwork from publishing": ["display.race.no-red-artwork"],
            "Switching to a podcast prevents radio artwork from publishing over it": ["display.race.no-red-artwork"]
        ]
        let actual = suites.reduce(into: [String: Set<String>]()) { result, suite in
            for (name, markers) in suite.knownBugs { result[name] = Set(markers.map(\.assertionDiagnostic)) }
        }
        XCTAssertEqual(actual, expected)
    }

    func testActualTablesRejectStaleNamesAndStepsAndDuplicateMarkers() throws {
        for suite in suites {
            let feature = try FeatureParser.parse(path: suite.featurePath)
            let name = try XCTUnwrap(suite.knownBugs.keys.sorted().first)
            let marker = try XCTUnwrap(suite.knownBugs[name]?.first)
            XCTAssertThrowsError(try KnownBugs.validate([name + " renamed": [marker]], in: feature))
            let renamed = KnownBug(bugID: marker.bugID, symptom: marker.symptom,
                                   stepText: marker.stepText + " renamed", assertionDiagnostic: marker.assertionDiagnostic)
            XCTAssertThrowsError(try KnownBugs.validate([name: [renamed]], in: feature))
            XCTAssertThrowsError(try KnownBugs.validate([name: [marker, marker]], in: feature))
            let duplicate = FeatureFile(name: feature.name, path: feature.path, scenarios: feature.scenarios + [feature.scenarios[0]])
            XCTAssertThrowsError(try KnownBugs.validate(suite.knownBugs, in: duplicate))
        }
    }

    func testEveryMarkerRejectsUnrelatedTitleAndGenericSetupNetworkTeardownFailures() {
        for suite in suites {
            for marker in suite.knownBugs.values.flatMap({ $0 }) {
                for diagnostic in [nil, "display.title", "display.title-artwork", "display.sustained-artwork.title", "network", "reset", "teardown"] as [String?] {
                    XCTAssertFalse(marker.matches(failure(marker, diagnostic: diagnostic)))
                }
                XCTAssertFalse(marker.matches(failure(marker, keyword: "Given", diagnostic: marker.assertionDiagnostic)))
                XCTAssertFalse(marker.matches(failure(marker, keyword: "When", diagnostic: marker.assertionDiagnostic)))
            }
        }
    }

    func testCompoundArtworkDiagnosticRequiresCorrectNonemptyTitleAndWrongArtwork() {
        for diagnostic in ["display.title-artwork.artwork", "display.sustained-artwork.artwork"] {
            func classify(title: String?, art: String?, empty: Bool = false) -> String? {
                let snapshot = NowPlayingProbe.Snapshot(isEmpty: empty, title: title, artwork: art)
                let outcome = NowPlayingProbe.Outcome.timedOut(last: snapshot, diff: [], waited: 0)
                return NowPlayingSteps.artworkOnlyDiagnostic(outcome, title: "Song A", artwork: "red", diagnostic: diagnostic)
            }
            XCTAssertEqual(classify(title: "Song A", art: "logo"), diagnostic)
            XCTAssertEqual(classify(title: "Song A", art: nil), diagnostic)
            XCTAssertNil(classify(title: "WRONG TITLE", art: "logo"))
            XCTAssertNil(classify(title: nil, art: "logo"))
            XCTAssertNil(classify(title: "Song A", art: "red"))
            XCTAssertNil(classify(title: "Song A", art: "logo", empty: true))
            XCTAssertNil(NowPlayingSteps.artworkOnlyDiagnostic(.matched(.init(isEmpty: false, title: "Song A", artwork: "red")),
                                                             title: "Song A", artwork: "red", diagnostic: diagnostic))
        }
    }

    func testPlainAndRebuiltPhrasesResolveOnceAndMissingTitleFailsOrdinarily() throws {
        let steps = NowPlayingSteps(world: world)
        steps.displayTimeout = 0
        steps.retainUntilTeardown(of: self)
        let registry = StepLibrary()
        steps.register(in: registry)
        let marker = try XCTUnwrap(KnownBugs.lifecycle["Pausing and resuming keeps the current song's artwork"]?.first)
        for phrase in ["the display shows the title \"Song A\" with red artwork", marker.stepText] {
            XCTAssertEqual(registry.matches(phrase).count, 1)
            let step = FeatureStep(keyword: "Then", text: phrase, line: 2)
            let scenario = FeatureScenario(name: "wrong title", tags: [], line: 1, steps: [step])
            let output = try XCTUnwrap(FeatureExecution.run(scenario: scenario, steps: registry))
            XCTAssertEqual(output.outputAssertionDiagnostic, "display.title-artwork")
            XCTAssertFalse(marker.matches(output))
        }
    }

    func testSustainedArtworkWithoutCheckedTitleIdentityIsOrdinary() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        let registry = StepLibrary()
        steps.register(in: registry)
        let step = FeatureStep(keyword: "Then", text: "the display keeps red artwork for 2 seconds", line: 2)
        let scenario = FeatureScenario(name: "no identity", tags: [], line: 1, steps: [step])
        let output = try XCTUnwrap(FeatureExecution.run(scenario: scenario, steps: registry))
        XCTAssertNil(output.outputAssertionDiagnostic)
        XCTAssertTrue(output.errorText?.contains("checked title and announced playing station identity") == true)
    }
}
