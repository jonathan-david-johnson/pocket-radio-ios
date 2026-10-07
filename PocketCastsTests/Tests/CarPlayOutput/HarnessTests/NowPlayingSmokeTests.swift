import XCTest
@testable import podcasts

/// M13.1 smoke scenario: `contracts/features/now_playing/smoke.feature`, run by the harness through the
/// real playback path. Needs the shell checkout next to the worktree (`../contracts`).
final class NowPlayingSmokeTests: FeatureTestCase {
    override class var featurePath: String { contractsFeature("now_playing/smoke.feature") }

    override func registerSteps(_ registry: StepLibrary) {
        NowPlayingSteps(world: world).register(in: registry)
    }
}

/// The same steps against a fixture whose tracklist returns HTTP 500. It must fail, and the failure must
/// name the endpoint and show the last Now Playing snapshot. The fixture class is excluded from normal
/// discovery (`isFixture`), so only the test below runs it.
final class SmokeTracklistFaultFixtureCase: FeatureTestCase {
    var issues: [XCTIssue] = []
    override class var isFixture: Bool { true }
    override class var featurePath: String {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/smoke_tracklist_500.feature").path
    }
    override func report(_ issue: XCTIssue) { issues.append(issue) }
    override func registerSteps(_ registry: StepLibrary) {
        let steps = NowPlayingSteps(world: world)
        steps.displayTimeout = 5
        steps.register(in: registry)
    }
}

final class NowPlayingSmokeFaultTests: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HarnessReset.isEnabled, HarnessReset.skipMessage)
    }

    func testFailingTracklistFailsNamingEndpointAndLastSnapshot() throws {
        HarnessReset.fullReset()
        FeatureTestCase.allowFixtureSuites = true
        defer { FeatureTestCase.allowFixtureSuites = false }
        let test = try XCTUnwrap(SmokeTracklistFaultFixtureCase.defaultTestSuite.tests.first as? SmokeTracklistFaultFixtureCase)
        test.perform(try XCTUnwrap(test.invocation).selector)
        defer { HarnessReset.fullReset(); test.world.stop() }

        let issue = try XCTUnwrap(test.issues.first, "a failing tracklist must fail the scenario")
        XCTAssertEqual(test.issues.count, 1)
        let text = issue.compactDescription
        XCTAssertTrue(text.contains("tracklist-api.kcrw.com"), "names the endpoint: \(text)")
        XCTAssertTrue(text.contains("HTTP 500"), text)
        XCTAssertTrue(text.contains("title='Song 1'"), "shows the last Now Playing snapshot: \(text)")
        XCTAssertTrue(text.contains("artwork: expected red"), "shows the diff: \(text)")
        let location = try XCTUnwrap(issue.sourceCodeContext.location)
        XCTAssertTrue(location.fileURL.path.hasSuffix("smoke_tracklist_500.feature"), location.fileURL.path)
        XCTAssertEqual(location.lineNumber, 12, "points at the 'red artwork' step")
    }
}
