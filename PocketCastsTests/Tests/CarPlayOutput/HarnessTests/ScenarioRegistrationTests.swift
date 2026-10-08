import XCTest

/// Discovery-only validation for the 15 approved M13.2 scenarios. These checks inspect contracts and
/// XCTest registration; they never execute a generated scenario method.
final class ScenarioRegistrationTests: HarnessScenarioCase {
    private struct FeatureOwner {
        let testCase: FeatureTestCase.Type
        let scenarios: Set<String>
    }

    private var owners: [FeatureOwner] {
        [
            FeatureOwner(testCase: NowPlayingSmokeTests.self, scenarios: [
                "The first song shows its title, artist, album and artwork",
            ]),
            FeatureOwner(testCase: CarPlayArtworkTests.self, scenarios: [
                "A second song without station detail does not keep the previous artwork",
                "A second song with station detail open shows its matching artwork",
                "A tracklist one song behind lends neither its album nor its artwork",
                "A matching track without artwork uses the iTunes fallback",
                "A song without artwork anywhere shows the logo instead of previous artwork",
            ]),
            FeatureOwner(testCase: CarPlayLifecycleTests.self, scenarios: [
                "Pausing and resuming keeps the current song's artwork",
                "A cached tracklist at playback start keeps the artwork",
                "Stopping and replaying the same song resolves its artwork again",
            ]),
            FeatureOwner(testCase: CarPlayRaceTests.self, scenarios: [
                "Slow artwork for an earlier song never replaces the current song's artwork",
                "Switching stations prevents the old station's artwork from publishing",
                "Switching to a podcast prevents radio artwork from publishing over it",
            ]),
            FeatureOwner(testCase: CarPlayPolicyTests.self, scenarios: [
                "An ad frame leaves the current title artist and artwork unchanged",
                "CarPlay suppresses lyric album writes and disconnect restores the real album",
                "Live music markers survive initial metadata artwork and rebuild writes",
            ]),
        ]
    }

    private func parsedFeature(for owner: FeatureOwner) throws -> FeatureFile {
        try FeatureParser.parse(path: owner.testCase.featurePath)
    }

    func testContractsContainExactlyTheApproved15ScenarioIdentities() throws {
        let discovered = try owners.flatMap { owner in
            try parsedFeature(for: owner).scenarios.map(\.name)
        }
        let expected = owners.flatMap(\.scenarios)

        XCTAssertEqual(discovered.count, 15, "Unexpected scenario count or duplicate identity: \(discovered)")
        XCTAssertEqual(Set(discovered).count, discovered.count, "Scenario identities must be globally unique")
        XCTAssertEqual(Set(discovered), Set(expected), "A contract scenario is missing, new, or misspelled")
        XCTAssertEqual(Set(expected).count, 15, "The approved identity list itself must contain 15 unique names")
    }

    func testEveryScenarioHasIOSAndCarPlayTagsAndOnlyS7IsIOSOnly() throws {
        let all = try owners.flatMap { owner in
            try parsedFeature(for: owner).scenarios
        }
        let s7Name = "CarPlay suppresses lyric album writes and disconnect restores the real album"

        for scenario in all {
            XCTAssertEqual(Set(scenario.tags).count, scenario.tags.count,
                           "Duplicate tags on '\(scenario.name)': \(scenario.tags)")
            XCTAssertTrue(scenario.tags.contains("ios"), "Missing @ios on '\(scenario.name)'")
            XCTAssertTrue(scenario.tags.contains("carplay"), "Missing @carplay on '\(scenario.name)'")
            XCTAssertEqual(scenario.tags.contains("ios-only"), scenario.name == s7Name,
                           "Only the iOS-specific S7 scenario should carry @ios-only: '\(scenario.name)'")
        }
        XCTAssertEqual(all.filter { $0.tags.contains("ios-only") }.map(\.name), [s7Name])
    }

    func testEachScenarioIsRegisteredOnceSelectableAndOnItsExpectedFeatureClass() throws {
        var registeredIdentities: [String] = []

        for owner in owners {
            let feature = try parsedFeature(for: owner)
            let suite = owner.testCase.defaultTestSuite
            let tests = try XCTUnwrap(suite.tests as? [XCTestCase])
            XCTAssertEqual(tests.count, feature.scenarios.count,
                           "\(owner.testCase) suite registration count must match its feature")

            var selectors: [String] = []
            for test in tests {
                let selector = try XCTUnwrap(test.invocation?.selector,
                                             "Every generated test must have a stable invocation selector")
                let selectorName = NSStringFromSelector(selector)
                selectors.append(selectorName)
                XCTAssertTrue(owner.testCase.instancesRespond(to: selector),
                              "\(selectorName) must be selectable as an XCTest method on \(owner.testCase)")
                XCTAssertEqual(ObjectIdentifier(type(of: test)), ObjectIdentifier(owner.testCase),
                               "\(selectorName) registered an instance of the wrong feature class")

                let matchingScenarios = feature.scenarios.filter {
                    FeatureTestCase.testMethodName(for: $0) == selectorName
                }
                XCTAssertEqual(matchingScenarios.count, 1,
                               "\(selectorName) must resolve to exactly one contract scenario")
                if let scenario = matchingScenarios.first {
                    registeredIdentities.append(scenario.name)
                }
            }

            XCTAssertEqual(Set(selectors).count, selectors.count,
                           "Generated selectors must be unique within \(owner.testCase)")
            let expectedSelectors = Set(feature.scenarios.map { FeatureTestCase.testMethodName(for: $0) })
            XCTAssertEqual(Set(selectors), expectedSelectors,
                           "Every scenario selector must be registered exactly once")
        }

        XCTAssertEqual(registeredIdentities.count, 15, "All 15 scenario tests must be registered")
        XCTAssertEqual(Set(registeredIdentities).count, 15, "No scenario may be registered more than once")
        XCTAssertEqual(Set(registeredIdentities), Set(owners.flatMap(\.scenarios)),
                       "Registered test identities must exactly match the approved scenario set")
    }
}
