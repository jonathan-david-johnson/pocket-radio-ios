import XCTest
@testable import podcasts

// MARK: - Fixture subclasses (discovered by XCTest too; their `report` collects, so they pass)

class CollectingFeatureCase: FeatureTestCase {
    /// The abstract collector has no feature path; only its concrete subclasses are discovered.
    override class var isFixture: Bool { self == CollectingFeatureCase.self }
    var issues: [XCTIssue] = []
    override func report(_ issue: XCTIssue) { issues.append(issue) }
    override func registerSteps(_ registry: StepLibrary) {
        registry.add("step (.*)") { _ in }
    }
}

final class RunnerUndefinedFixtureCase: CollectingFeatureCase {
    override class var featurePath: String { FeatureRunnerTests.fixture("runner_undefined.feature") }
    override func registerSteps(_ registry: StepLibrary) {
        registry.add("step one") { _ in }
        registry.add("step two") { _ in }
        registry.add("step four") { _ in }
    }
}

final class RunnerMissingFileFixtureCase: CollectingFeatureCase {
    override class var featurePath: String { "/nonexistent/dir/runner_missing.feature" }
}

final class RunnerDuplicateTitlesFixtureCase: CollectingFeatureCase {
    override class var featurePath: String { FeatureRunnerTests.fixture("runner_duplicate_titles.feature") }
}

final class FeatureRunnerTests: XCTestCase {
    static func fixture(_ name: String, filePath: String = #filePath) -> String {
        URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/\(name)").path
    }

    private func parse(_ name: String) throws -> FeatureFile { try FeatureParser.parse(path: Self.fixture(name)) }

    /// Runs the single test of a collecting fixture class and returns the instance.
    private func runTest(_ cls: CollectingFeatureCase.Type, at index: Int = 0) throws -> CollectingFeatureCase {
        let tests = cls.defaultTestSuite.tests
        let test = try XCTUnwrap(tests[index] as? CollectingFeatureCase)
        test.perform(try XCTUnwrap(test.invocation).selector)
        return test
    }

    // MARK: Parser

    func testParserPrependsBackgroundToEveryScenario() throws {
        let f = try parse("runner_parser.feature")
        XCTAssertEqual(f.name, "Parser fixture")
        XCTAssertEqual(f.scenarios.count, 2)
        for s in f.scenarios {
            XCTAssertEqual(s.steps.prefix(2).map(\.text), ["the world is up", "the radio is tuned"])
        }
        XCTAssertEqual(f.scenarios[1].steps.map(\.text), ["the world is up", "the radio is tuned", "the title is \"Beta\""])
    }

    func testParserTagsAttachToNextScenarioOnly() throws {
        let f = try parse("runner_parser.feature")
        XCTAssertEqual(f.scenarios[0].tags, ["ios", "carplay"])
        XCTAssertEqual(f.scenarios[1].tags, [])
    }

    func testParserAndButInheritPreviousKeyword() throws {
        let s = try parse("runner_parser.feature").scenarios[0]
        XCTAssertEqual(s.steps.map(\.keyword), ["Given", "Given", "When", "When", "When", "Then"])
    }

    func testParserLineNumbersAreOneBasedAndCommentsBlankLinesIgnored() throws {
        let f = try parse("runner_parser.feature")
        XCTAssertEqual(f.scenarios[0].line, 11)
        XCTAssertEqual(f.scenarios[0].steps.map(\.line), [6, 8, 12, 13, 14, 15])
        XCTAssertEqual(f.scenarios[1].line, 17)
        XCTAssertEqual(f.scenarios[1].steps.last?.line, 18)
        XCTAssertEqual(f.scenarios[0].featurePath, Self.fixture("runner_parser.feature"))
    }

    // MARK: Step library

    func testCapturesFromRegexPatterns() throws {
        let lib = StepLibrary()
        lib.add(#"the title is "(.*)" for (\d+) seconds"#) { _ in }
        let (_, captures) = try XCTUnwrap(lib.match(#"the title is "Alpha" for 30 seconds"#))
        XCTAssertEqual(captures, ["Alpha", "30"])
        XCTAssertNil(lib.match("the title is"))
    }

    func testFirstMatchWins() throws {
        let lib = StepLibrary()
        var hit = ""
        lib.add("a (.*)") { _ in hit = "first" }
        lib.add("a thing") { _ in hit = "second" }
        let (d, _) = try XCTUnwrap(lib.match("a thing"))
        try d.handler([])
        XCTAssertEqual(hit, "first")
    }

    // MARK: Core execution

    private func scenario(_ texts: [String]) -> FeatureScenario {
        FeatureScenario(name: "S", tags: [], line: 1, featurePath: "/x/y/core.feature",
                        steps: texts.enumerated().map { FeatureStep(keyword: "Given", text: $1, line: 10 + $0) })
    }

    func testPassingScenarioReturnsNil() {
        let lib = StepLibrary()
        lib.add(".*") { _ in }
        XCTAssertNil(FeatureExecution.run(scenario: scenario(["a", "b"]), steps: lib))
    }

    func testUnmarkedClassifiedOutputFailureRemainsOrdinaryAndStopsRun() throws {
        let lib = StepLibrary()
        var reachedLater = false
        lib.add("output") { _ in
            throw StepFailure.outputAssertion(diagnostic: "synthetic policy mismatch", message: "actual display differs")
        }
        lib.add("after") { _ in reachedLater = true }
        let failure = try XCTUnwrap(FeatureExecution.run(scenario: scenario(["output", "after"]), steps: lib))
        XCTAssertEqual(failure.kind, .stepFailed)
        XCTAssertEqual(failure.outputAssertionDiagnostic, "synthetic policy mismatch")
        XCTAssertEqual(failure.errorText, "actual display differs")
        XCTAssertFalse(reachedLater)
    }

    func testUndefinedStepStopsRunAndNamesStepAndLocation() throws {
        let f = try parse("runner_undefined.feature")
        var ran: [String] = []
        let lib = StepLibrary()
        for t in ["step one", "step two", "step four"] { lib.add(t) { _ in ran.append(t) } }
        let failure = try XCTUnwrap(FeatureExecution.run(scenario: f.scenarios[0], steps: lib))
        XCTAssertEqual(failure.kind, .undefinedStep)
        XCTAssertEqual(failure.stepText, "nobody defined this step")
        XCTAssertEqual(failure.keyword, "Then")
        XCTAssertEqual(failure.line, 6)
        XCTAssertTrue(failure.message.contains("nobody defined this step"), failure.message)
        XCTAssertTrue(failure.message.contains("runner_undefined.feature:6"), failure.message)
        XCTAssertEqual(ran, ["step one", "step two"], "earlier steps run, later steps do not")
    }

    func testUndefinedStepEndToEndReportsAtFeatureLine() throws {
        let test = try runTest(RunnerUndefinedFixtureCase.self)
        let issue = try XCTUnwrap(test.issues.first)
        XCTAssertEqual(test.issues.count, 1)
        XCTAssertTrue(issue.compactDescription.contains("UNDEFINED STEP"), issue.compactDescription)
        XCTAssertTrue(issue.compactDescription.contains("nobody defined this step"))
        let location = try XCTUnwrap(issue.sourceCodeContext.location)
        XCTAssertTrue(location.fileURL.path.hasSuffix("runner_undefined.feature"), location.fileURL.path)
        XCTAssertEqual(location.lineNumber, 6)
    }

    func testHandlerThatThrowsYieldsStepFailedWithDefinitionLocation() throws {
        struct Boom: Error, CustomStringConvertible { var description: String { "boom!" } }
        let lib = StepLibrary()
        let defLine = #line + 1
        lib.add("explode") { _ in throw Boom() }
        let s = FeatureScenario(name: "S", tags: [], line: 1, featurePath: "/x/y/core.feature",
                                steps: [FeatureStep(keyword: "When", text: "explode", line: 7),
                                        FeatureStep(keyword: "Then", text: "after", line: 8)])
        let failure = try XCTUnwrap(FeatureExecution.run(scenario: s, steps: lib))
        XCTAssertEqual(failure.kind, .stepFailed)
        XCTAssertEqual(failure.line, 7)
        XCTAssertEqual(failure.errorText, "boom!")
        XCTAssertNil(failure.outputAssertionDiagnostic, "generic errors must never be classified as known output defects")
        XCTAssertEqual(failure.definitionLine, UInt(defLine))
        XCTAssertTrue(failure.definitionFile?.hasSuffix("FeatureRunnerTests.swift") == true, failure.definitionFile ?? "nil")
        XCTAssertTrue(failure.message.contains("boom!"))
    }

    func testAmbiguousStepIsReportedNamingBothDefinitions() throws {
        let lib = StepLibrary()
        var ran = false
        let l1 = #line + 1
        lib.add("a (.*)") { _ in ran = true }
        let l2 = #line + 1
        lib.add("a thing") { _ in ran = true }
        let failure = try XCTUnwrap(FeatureExecution.run(scenario: scenario(["a thing"]), steps: lib))
        XCTAssertEqual(failure.kind, .ambiguousStep)
        XCTAssertFalse(ran)
        XCTAssertTrue(failure.message.contains("FeatureRunnerTests.swift:\(l1)"), failure.message)
        XCTAssertTrue(failure.message.contains("FeatureRunnerTests.swift:\(l2)"), failure.message)
    }

    // MARK: Loud missing file

    func testMissingFeatureFileYieldsOneFailingTestNotEmptySuite() throws {
        let suite = RunnerMissingFileFixtureCase.defaultTestSuite
        XCTAssertEqual(suite.tests.count, 1)
        XCTAssertEqual(suite.tests[0].name.components(separatedBy: " ").last?.dropLast(), "scenario_feature_file_unreadable")
        let test = try runTest(RunnerMissingFileFixtureCase.self)
        let issue = try XCTUnwrap(test.issues.first)
        XCTAssertTrue(issue.compactDescription.contains("/nonexistent/dir/runner_missing.feature"), issue.compactDescription)
        XCTAssertTrue(issue.compactDescription.lowercased().contains("cannot read") || issue.compactDescription.lowercased().contains("unreadable"),
                      issue.compactDescription)
    }

    // MARK: Unique names

    func testIdenticalTitlesGetDifferentMethodNamesAndKeepTags() throws {
        let names = RunnerDuplicateTitlesFixtureCase.defaultTestSuite.tests.map { ($0 as! XCTestCase).invocation!.selector.description }
        XCTAssertEqual(names.count, 2)
        XCTAssertEqual(Set(names).count, 2, "\(names)")
        XCTAssertTrue(names[0].hasPrefix("scenario_L4_h1_a_song_is_missing"), names[0])
        XCTAssertTrue(names[1].hasPrefix("scenario_L8_h1_a_song_is_missing"), names[1])
    }

    func testSelectorsAreRegisteredOnTheClassForOnlyTesting() {
        for t in RunnerDuplicateTitlesFixtureCase.defaultTestSuite.tests {
            let sel = (t as! XCTestCase).invocation!.selector
            XCTAssertTrue(RunnerDuplicateTitlesFixtureCase.instancesRespond(to: sel))
            XCTAssertTrue(t.name.hasPrefix("-[RunnerDuplicateTitlesFixtureCase scenario_L"), t.name)
        }
    }

    // MARK: contracts path

    func testContractsFeaturePathArithmetic() {
        let p = FeatureTestCase.contractsFeature(
            "carplay/now_playing.feature",
            filePath: "/a/b/pocket-radio-ios-carplay/PocketCastsTests/Tests/CarPlayOutput/HarnessTests/X.swift")
        XCTAssertEqual(p, "/a/b/contracts/features/carplay/now_playing.feature")
    }
}
