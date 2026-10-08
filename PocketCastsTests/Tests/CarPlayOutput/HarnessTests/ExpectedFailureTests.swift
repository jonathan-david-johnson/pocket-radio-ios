import XCTest

private let syntheticDiagnostic = "artwork policy: expected blue, observed red"
private let syntheticBug = KnownBug(bugID: "synthetic-bug-1", symptom: "wrong artwork",
                                    stepText: "synthetic artwork is blue", assertionDiagnostic: syntheticDiagnostic)

/// Explicitly run by self-tests only. No network, playback, or real known-bug mapping.
class RunnerExpectedFailureFixtureCase: FeatureTestCase {
    enum Behavior {
        case knownFailure, passing, unrelatedOutput, genericError, precondition, undefined, ambiguous
        case laterAssertion, network, reset, teardown, directAssertion, twoKnownFailures
    }

    var behavior = Behavior.knownFailure
    var reachedLaterStep = false
    var issueSink: ((XCTIssue, Bool) -> Void)?
    private var forwardNextReport = false

    override func report(_ issue: XCTIssue) {
        issueSink?(issue, forwardNextReport)
        forwardNextReport = false
    }
    override class var isFixture: Bool { true }
    override class var featurePath: String { FeatureRunnerTests.fixture("runner_expected_failure.feature") }
    override class var knownBugs: KnownBugs.Table { ["Synthetic artwork policy": [syntheticBug]] }

    override func setUpWithError() throws {
        try super.setUpWithError()
        if behavior == .reset { throw StepFailure(message: "synthetic reset failed") }
    }

    override func tearDown() {
        super.tearDown()
        if behavior == .teardown { XCTFail("synthetic teardown failed") }
    }

    override func registerSteps(_ registry: StepLibrary) {
        registry.add("synthetic playback is ready") { _ in
            if self.behavior == .precondition {
                throw StepFailure(message: syntheticDiagnostic)
            }
        }
        if behavior != .undefined {
            registry.add("synthetic artwork is blue") { _ in
                switch self.behavior {
                case .passing: return
                case .unrelatedOutput:
                    throw StepFailure.outputAssertion(diagnostic: "unrelated title policy", message: syntheticDiagnostic)
                case .genericError:
                    // Even identical message text must not match without explicit output classification.
                    throw StepFailure(message: syntheticDiagnostic)
                case .network:
                    throw NSError(domain: "synthetic network", code: 500, userInfo: [NSLocalizedDescriptionKey: syntheticDiagnostic])
                case .directAssertion:
                    XCTFail("synthetic direct assertion is ordinary")
                    fallthrough
                default:
                    self.forwardNextReport = true
                    throw StepFailure.outputAssertion(diagnostic: syntheticDiagnostic, message: "last display: red; \(syntheticDiagnostic)")
                }
            }
        }
        if behavior == .ambiguous { registry.add("synthetic artwork is (.*)") { _ in } }
        registry.add("synthetic live marker is present") { _ in
            self.reachedLaterStep = true
            if self.behavior == .laterAssertion { throw StepFailure(message: "synthetic later assertion failed") }
            if self.behavior == .twoKnownFailures {
                self.forwardNextReport = true
                throw StepFailure.outputAssertion(diagnostic: "live marker missing", message: "synthetic live marker missing")
            }
        }
    }
}

final class RunnerTwoExpectedFailuresFixtureCase: RunnerExpectedFailureFixtureCase {
    override class var knownBugs: KnownBugs.Table {
        ["Synthetic artwork policy": [syntheticBug,
            KnownBug(bugID: "synthetic-bug-2", symptom: "missing live marker", stepText: "synthetic live marker is present",
                     assertionDiagnostic: "live marker missing")]]
    }
}

final class RunnerStaleKnownBugFixtureCase: CollectingFeatureCase {
    override class var isFixture: Bool { true }
    override class var featurePath: String { RunnerExpectedFailureFixtureCase.featurePath }
    override class var knownBugs: KnownBugs.Table { ["stale name": [syntheticBug]] }
}

final class RunnerDuplicateKnownBugFixtureCase: CollectingFeatureCase {
    override class var isFixture: Bool { true }
    override class var featurePath: String { FeatureRunnerTests.fixture("runner_duplicate_titles.feature") }
    override class var knownBugs: KnownBugs.Table {
        ["A song is missing its artwork and the title is long enough to collide": [syntheticBug]]
    }
}

private final class ExpectedFailureObserver: NSObject, XCTestObservation {
    let test: XCTestCase
    var expected: [XCTExpectedFailure] = []
    var ordinary: [XCTIssue] = []

    init(test: XCTestCase) { self.test = test }

    func testCase(_ testCase: XCTestCase, didRecord expectedFailure: XCTExpectedFailure) {
        if testCase === test { expected.append(expectedFailure) }
    }

    func testCase(_ testCase: XCTestCase, didRecord issue: XCTIssue) {
        if testCase === test { ordinary.append(issue) }
    }
}

final class ExpectedFailureTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HarnessReset.isEnabled, HarnessReset.skipMessage)
    }

    private struct FixtureResult {
        let totalFailureCount: Int
        var failureCount: Int { totalFailureCount }
        var hasSucceeded: Bool { totalFailureCount == 0 }
    }

    private var collectingFixture = false
    private var fixtureIssues: [XCTIssue] = []

    override func record(_ issue: XCTIssue) {
        // Strict unexpected passes are emitted by XCTest itself, not the runner's report hook.
        // Collect deliberate negative-fixture issues without starting a nested XCTest run (unsupported
        // by Xcode's IDE session). Assertions in the self-test itself still use normal recording.
        if collectingFixture { fixtureIssues.append(issue) } else { super.record(issue) }
    }

    private func run(_ behavior: RunnerExpectedFailureFixtureCase.Behavior,
                     fixture: RunnerExpectedFailureFixtureCase.Type = RunnerExpectedFailureFixtureCase.self) throws
        -> (RunnerExpectedFailureFixtureCase, FixtureResult, ExpectedFailureObserver) {
        FeatureTestCase.allowFixtureSuites = true
        defer { FeatureTestCase.allowFixtureSuites = false }
        let test = try XCTUnwrap(fixture.defaultTestSuite.tests.first as? RunnerExpectedFailureFixtureCase)
        test.behavior = behavior
        let observer = ExpectedFailureObserver(test: self)
        XCTestObservationCenter.shared.addTestObserver(observer)
        defer { XCTestObservationCenter.shared.removeTestObserver(observer) }
        fixtureIssues = []
        collectingFixture = true
        defer { collectingFixture = false }
        test.issueSink = { [unowned self] issue, isIntendedOutput in
            if isIntendedOutput {
                // Only this synthetic classified output goes through XCTest's real expectation matcher.
                self.collectingFixture = false
                self.record(issue)
                self.collectingFixture = true
            } else {
                self.record(issue)
            }
        }
        if behavior == .reset {
            do { try test.setUpWithError() } catch {
                record(XCTIssue(type: .system, compactDescription: "synthetic reset failed: \(error)"))
            }
        } else {
            test.perform(try XCTUnwrap(test.invocation).selector)
        }
        if behavior == .teardown { test.tearDown() }
        observer.ordinary = fixtureIssues
        return (test, FixtureResult(totalFailureCount: fixtureIssues.count), observer)
    }

    func testIntendedOutputFailureIsExpectedAndContinuesWithLocations() throws {
        let (test, run, observer) = try run(.knownFailure)
        XCTAssertTrue(run.hasSucceeded)
        XCTAssertEqual(observer.expected.count, 1)
        XCTAssertTrue(observer.ordinary.isEmpty)
        XCTAssertTrue(test.reachedLaterStep)
        let expected = try XCTUnwrap(observer.expected.first)
        let reason = try XCTUnwrap(expected.failureReason)
        XCTAssertTrue(reason.contains("synthetic-bug-1"))
        XCTAssertTrue(reason.contains("wrong artwork"))
        let issue = expected.issue
        XCTAssertTrue(issue.compactDescription.contains("step definition:"))
        XCTAssertTrue(issue.compactDescription.contains("ExpectedFailureTests.swift:"))
        let location = try XCTUnwrap(issue.sourceCodeContext.location)
        XCTAssertTrue(location.fileURL.path.hasSuffix("runner_expected_failure.feature"))
        XCTAssertEqual(location.lineNumber, 5)
    }

    func testMultipleOutputMarkersUseIndependentExpectations() throws {
        let (test, run, observer) = try run(.twoKnownFailures, fixture: RunnerTwoExpectedFailuresFixtureCase.self)
        XCTAssertTrue(run.hasSucceeded)
        XCTAssertEqual(observer.expected.count, 2)
        XCTAssertTrue(observer.ordinary.isEmpty)
        XCTAssertTrue(test.reachedLaterStep)
        XCTAssertEqual(observer.expected.compactMap { $0.issue.sourceCodeContext.location?.lineNumber }, [5, 6])
    }

    func testInvalidTablesYieldOneOrdinaryDiscoveryIssue() throws {
        FeatureTestCase.allowFixtureSuites = true
        defer { FeatureTestCase.allowFixtureSuites = false }
        for (fixture, diagnostic) in [(RunnerStaleKnownBugFixtureCase.self as CollectingFeatureCase.Type, "stale scenario name"),
                                      (RunnerDuplicateKnownBugFixtureCase.self as CollectingFeatureCase.Type, "duplicate scenario name")] {
            let suite = fixture.defaultTestSuite
            XCTAssertEqual(suite.tests.count, 1)
            let test = try XCTUnwrap(suite.tests.first as? CollectingFeatureCase)
            test.perform(try XCTUnwrap(test.invocation).selector)
            XCTAssertEqual(test.issues.count, 1)
            let issue = try XCTUnwrap(test.issues.first)
            XCTAssertTrue(issue.compactDescription.contains(diagnostic), issue.compactDescription)
            XCTAssertEqual(issue.type, .assertionFailure)
            XCTAssertEqual(issue.sourceCodeContext.location?.fileURL.path, fixture.featurePath)
        }
    }

    func testUnexpectedlyPassingMarkedOutputFailsStrictly() throws {
        let (test, run, observer) = try run(.passing)
        XCTAssertFalse(run.hasSucceeded)
        XCTAssertEqual(run.failureCount, 1)
        XCTAssertTrue(observer.expected.isEmpty)
        XCTAssertEqual(observer.ordinary.first?.type, .unmatchedExpectedFailure)
        let issue = try XCTUnwrap(observer.ordinary.first)
        XCTAssertTrue(issue.compactDescription.contains("synthetic-bug-1"))
        XCTAssertTrue(issue.compactDescription.contains("runner_expected_failure.feature:5"))
        XCTAssertTrue(issue.compactDescription.contains("step definition: PocketCastsTests/ExpectedFailureTests.swift:"))
        XCTAssertTrue(test.reachedLaterStep)
    }

    private func assertOrdinary(_ behavior: RunnerExpectedFailureFixtureCase.Behavior,
                                contains text: String, file: StaticString = #filePath, line: UInt = #line) throws {
        let (test, run, observer) = try run(behavior)
        XCTAssertFalse(run.hasSucceeded, file: file, line: line)
        XCTAssertEqual(run.totalFailureCount, 1, file: file, line: line)
        XCTAssertTrue(observer.expected.isEmpty, file: file, line: line)
        XCTAssertTrue(observer.ordinary.first?.compactDescription.contains(text) == true,
                      "\(observer.ordinary.map(\.compactDescription))", file: file, line: line)
        XCTAssertFalse(test.reachedLaterStep, file: file, line: line)
    }

    func testUnrelatedOutputDiagnosticRemainsOrdinary() throws {
        try assertOrdinary(.unrelatedOutput, contains: syntheticDiagnostic)
    }

    func testIdenticalGenericErrorMessageRemainsOrdinary() throws {
        try assertOrdinary(.genericError, contains: syntheticDiagnostic)
    }

    func testPlaybackPreconditionRemainsOrdinary() throws {
        try assertOrdinary(.precondition, contains: "Given synthetic playback is ready")
    }

    func testNetworkErrorRemainsOrdinary() throws {
        try assertOrdinary(.network, contains: "synthetic network")
    }

    func testUndefinedDesignatedStepRemainsOrdinary() throws {
        try assertOrdinary(.undefined, contains: "UNDEFINED STEP")
    }

    func testAmbiguousDesignatedStepRemainsOrdinary() throws {
        try assertOrdinary(.ambiguous, contains: "AMBIGUOUS STEP")
    }

    func testResetErrorRemainsOrdinary() throws {
        try assertOrdinary(.reset, contains: "synthetic reset failed")
    }

    func testLaterAssertionIsNotSwallowedByExpectedFailure() throws {
        let (test, run, observer) = try run(.laterAssertion)
        XCTAssertFalse(run.hasSucceeded)
        XCTAssertEqual(run.totalFailureCount, 1)
        XCTAssertEqual(observer.expected.count, 1)
        XCTAssertTrue(observer.ordinary.first?.compactDescription.contains("synthetic later assertion failed") == true)
        XCTAssertTrue(test.reachedLaterStep)
    }

    func testTeardownRemainsOrdinaryAfterExpectedFailure() throws {
        let (_, run, observer) = try run(.teardown)
        XCTAssertFalse(run.hasSucceeded)
        XCTAssertEqual(run.totalFailureCount, 1)
        XCTAssertEqual(observer.expected.count, 1)
        XCTAssertTrue(observer.ordinary.first?.compactDescription.contains("synthetic teardown failed") == true)
    }

    func testDirectAssertionInsideOutputHandlerRemainsOrdinary() throws {
        let (_, run, observer) = try run(.directAssertion)
        XCTAssertFalse(run.hasSucceeded)
        XCTAssertEqual(run.totalFailureCount, 1)
        XCTAssertEqual(observer.expected.count, 1)
        XCTAssertTrue(observer.ordinary.first?.compactDescription.contains("synthetic direct assertion is ordinary") == true)
    }

    // MARK: Table validation, independent of XCTest issue matching

    private func feature() throws -> FeatureFile {
        try FeatureParser.parse(path: RunnerExpectedFailureFixtureCase.featurePath)
    }

    func testStaleScenarioNameRejected() throws {
        XCTAssertThrowsError(try KnownBugs.validate(["renamed scenario": [syntheticBug]], in: feature())) {
            XCTAssertTrue("\($0)".contains("stale scenario name"))
        }
    }

    func testDuplicateScenarioNamesRejectedForMarkedFeature() throws {
        let duplicate = try FeatureParser.parse(path: FeatureRunnerTests.fixture("runner_duplicate_titles.feature"))
        XCTAssertThrowsError(try KnownBugs.validate([duplicate.scenarios[0].name: [syntheticBug]], in: duplicate)) {
            XCTAssertTrue("\($0)".contains("duplicate scenario name"))
        }
        XCTAssertNoThrow(try KnownBugs.validate([:], in: duplicate), "plain unmarked duplicate-title behavior is preserved")
    }

    func testStaleOutputStepRejected() throws {
        let marker = KnownBug(bugID: "synthetic", symptom: "stale step", stepText: "renamed output", assertionDiagnostic: syntheticDiagnostic)
        XCTAssertThrowsError(try KnownBugs.validate(["Synthetic artwork policy": [marker]], in: feature()))
    }

    func testDuplicateOutputMarkersRejected() throws {
        XCTAssertThrowsError(try KnownBugs.validate(["Synthetic artwork policy": [syntheticBug, syntheticBug]], in: feature()))
    }

    func testPreconditionCannotBeDesignatedAsOutput() throws {
        let marker = KnownBug(bugID: "synthetic", symptom: "not output", stepText: "synthetic playback is ready", assertionDiagnostic: syntheticDiagnostic)
        XCTAssertThrowsError(try KnownBugs.validate(["Synthetic artwork policy": [marker]], in: feature()))
    }

    func testRepeatedDesignatedStepRejected() throws {
        let original = try feature()
        let scenario = original.scenarios[0]
        let repeated = FeatureScenario(name: scenario.name, tags: [], line: scenario.line, featurePath: scenario.featurePath,
                                       steps: scenario.steps + [scenario.steps[1]])
        let feature = FeatureFile(name: original.name, path: original.path, scenarios: [repeated])
        XCTAssertThrowsError(try KnownBugs.validate(RunnerExpectedFailureFixtureCase.knownBugs, in: feature))
    }

    func testEmptySymptomAndDiagnosticRejected() throws {
        let marker = KnownBug(bugID: "synthetic", symptom: "", stepText: syntheticBug.stepText, assertionDiagnostic: "")
        XCTAssertThrowsError(try KnownBugs.validate(["Synthetic artwork policy": [marker]], in: feature()))
    }

    func testMatchingRequiresExactStepAndDiagnosticAndClassification() throws {
        let scenario = try feature().scenarios[0]
        let registry = StepLibrary()
        registry.add("synthetic artwork is blue") { _ in
            throw StepFailure.outputAssertion(diagnostic: syntheticDiagnostic, message: "snapshot details may vary")
        }
        var failure = try XCTUnwrap(FeatureExecution.run(step: scenario.steps[1], scenario: scenario, steps: registry))
        XCTAssertTrue(syntheticBug.matches(failure))
        failure.stepText += " extra"
        XCTAssertFalse(syntheticBug.matches(failure))
        failure.stepText = syntheticBug.stepText
        failure.outputAssertionDiagnostic = syntheticDiagnostic + " extra"
        XCTAssertFalse(syntheticBug.matches(failure))
        failure.outputAssertionDiagnostic = syntheticDiagnostic
        failure.kind = .undefinedStep
        XCTAssertFalse(syntheticBug.matches(failure))
        failure.kind = .stepFailed
        failure.keyword = "Given"
        XCTAssertFalse(syntheticBug.matches(failure))
    }
}
