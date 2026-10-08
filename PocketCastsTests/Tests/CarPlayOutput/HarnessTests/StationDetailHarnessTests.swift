import UIKit
import XCTest
@testable import podcasts

final class StationDetailHarnessTests: HarnessScenarioCase {
    private let a = FakeWorld.FakeSong(title: "Helper Song A", artist: "Helper Artist A", album: "Helper Album A", art: "red")
    private let b = FakeWorld.FakeSong(title: "Helper Song B", artist: "Helper Artist B", album: "Helper Album B", art: "green")

    private func announce(_ song: FakeWorld.FakeSong, stationId: String) {
        autoreleasepool {
            NotificationCenter.default.post(name: .radioStationNowPlayingDidChange, object: nil,
                                            userInfo: [RadioMetadataNotificationKey.stationId: stationId,
                                                       RadioMetadataNotificationKey.title: song.title,
                                                       RadioMetadataNotificationKey.artist: song.artist])
        }
    }

    override func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            let matched = autoreleasepool {
                if condition() { return true }
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
                return false
            }
            if matched { return true }
        }
        return autoreleasepool { condition() }
    }

    func testRealAppearanceFetchAndICYRefreshThenDisappearanceStopsNotifications() throws {
        world.setTracklist([a])
        let station = try world.makeStation()
        let helper = try StationDetailHarness(station: station, world: world)
        defer { helper.stop() }
        XCTAssertTrue(helper.isVisible)
        XCTAssertTrue(spin(timeout: 5, until: { helper.firstRowLabels.contains(self.a.title) && helper.refreshedTitles.contains(self.a.title) }))
        XCTAssertFalse(helper.hasRefreshedAfterAnnouncement(for: b.title))
        world.setTracklist([b])
        announce(b, stationId: station.stationId)
        XCTAssertTrue(spin(timeout: 7, until: { helper.hasRefreshedAfterAnnouncement(for: self.b.title) }))
        XCTAssertTrue(helper.firstRowLabels.contains(b.artist))
        XCTAssertTrue(helper.firstRowLabels.contains(b.album))
        weak var controller = helper.controller
        helper.stop()
        helper.stop()
        XCTAssertFalse(helper.isVisible)
        XCTAssertTrue(helper.waitForRelease())
        XCTAssertNil(controller)
        let requests = helper.tracklistRequestCount
        announce(a, stationId: station.stationId)
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 2.3))
        XCTAssertEqual(helper.tracklistRequestCount, requests, "stopped screen must not refresh on reset/later ICY")
    }

    func testDisappearanceCancelsInFlightFetchBeforeResetAndReleasesController() throws {
        world.setTracklist([a])
        world.setLatency(.tracklist, seconds: 3)
        let station = try world.makeStation()
        let helper = try StationDetailHarness(station: station, world: world)
        XCTAssertTrue(spin(timeout: 2, until: { helper.tracklistRequestCount == 1 }))
        helper.stop()
        XCTAssertTrue(helper.waitForRelease(), "cancelled task must release the real controller before reset")
        var requestCompleted = false
        URLSession.shared.getAllTasks { tasks in
            DispatchQueue.main.async {
                requestCompleted = !tasks.contains { $0.originalRequest?.url?.host == FakeWorld.tracklistHost }
            }
        }
        XCTAssertTrue(spin(timeout: 2, until: { requestCompleted }), "cancelled URLSession request must complete before reset")
        HarnessReset.fullReset() // guard is still installed throughout cancellation and reset
        RunLoop.current.run(until: Date(timeIntervalSinceNow: 3.2))
        XCTAssertNil(RadioTracklistService.shared.cached(stationId: station.stationId), "late response must not refill reset cache")
        XCTAssertTrue(NetworkGuard.isInstalled)
    }

    func testRefreshedArrivalStepFetchesThroughActualServiceAndParser() throws {
        let steps = NowPlayingSteps(world: world)
        steps.retainUntilTeardown(of: self)
        let registry = StepLibrary()
        steps.register(in: registry)
        let phrase = "the station's tracklist lists only \"Song B\" by \"Artist B\" from album \"Album B\" without artwork"
        let scenario = FeatureScenario(name: "refresh fixture", tags: [], line: 1, featurePath: "helper.feature", steps: [
            FeatureStep(keyword: "When", text: phrase, line: 2),
            FeatureStep(keyword: "When", text: "the station's refreshed tracklist has arrived", line: 3)
        ])
        XCTAssertNil(FeatureExecution.run(scenario: scenario, steps: registry))
        let station = try world.makeStation()
        let row = try XCTUnwrap(RadioTracklistService.shared.cached(stationId: station.stationId)?.first)
        XCTAssertEqual(row.title, "Song B")
        XCTAssertEqual(row.artist, "Artist B")
        XCTAssertEqual(row.album, "Album B")
        XCTAssertNil(row.albumArtURL)
        XCTAssertEqual(world.served.filter { $0.host == FakeWorld.tracklistHost }.count, 1)
    }

    func testExplicitTestcaseCleanupOutlivesStepLibraryAndRunsBeforeReset() throws {
        world.setTracklist([a])
        let steps = NowPlayingSteps(world: world)
        var registry: StepLibrary? = StepLibrary()
        steps.register(in: registry!)
        let open = FeatureScenario(name: "open", tags: [], line: 1, featurePath: "helper.feature", steps: [
            FeatureStep(keyword: "When", text: "the listener opens station detail", line: 2)
        ])
        steps.rows = [a]
        XCTAssertNil(FeatureExecution.run(scenario: open, steps: registry!))
        let helper = try XCTUnwrap(steps.stationDetail)
        weak var controller = helper.controller
        // LIFO: validation runs after cleanup, but before HarnessScenarioCase.tearDown resets.
        addTeardownBlock {
            XCTAssertTrue(NetworkGuard.isInstalled)
            XCTAssertNotNil(RadioTracklistService.shared.cached(stationId: helper.stationId), "cleanup precedes cache reset")
            XCTAssertTrue(helper.isReleased)
            XCTAssertNil(controller)
            let count = steps.announced.count
            self.announce(self.b, stationId: helper.stationId)
            XCTAssertEqual(steps.announced.count, count, "step observer was explicitly removed")
        }
        steps.retainUntilTeardown(of: self)
        registry = nil
        XCTAssertNotNil(controller, "controller survives the local registry until testcase teardown")
    }
}
