import PocketCastsServer
import UIKit
@testable import podcasts

/// Retains the real detail screen. Reads its real table and service notifications; never seeds
/// the tracklist cache or writes Now Playing. Disappearance cancels the screen's refresh/lyric work.
final class StationDetailHarness {
    private(set) var controller: StationDetailViewController?
    private weak var disappearingController: StationDetailViewController?
    private var observers: [NSObjectProtocol] = []
    private let world: FakeWorld
    let stationId: String
    private(set) var requestsAtAnnouncement: [String: Int] = [:]
    private(set) var refreshedTitles: [String] = []
    private(set) var isVisible = false

    var tracklistRequestCount: Int { world.served.filter { $0.host == FakeWorld.tracklistHost }.count }
    var isReleased: Bool { controller == nil && disappearingController == nil }

    init(station: RadioStation, world: FakeWorld) throws {
        guard Thread.isMainThread, NetworkGuard.isInstalled else {
            throw StepFailure(message: "station detail requires the main thread and installed network guard")
        }
        // This suite requires its dedicated signed-out simulator. Do not fixture or tolerate
        // arbitrary account traffic (and do not modify ambient account state).
        guard ServerSettings.userId == nil else {
            throw StepFailure(message: "station detail requires the dedicated signed-out simulator")
        }
        self.world = world
        stationId = station.stationId
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: .radioStationNowPlayingDidChange, object: nil, queue: .main) { [weak self] n in
                guard let self, n.userInfo?[RadioMetadataNotificationKey.stationId] as? String == self.stationId,
                      let title = n.userInfo?[RadioMetadataNotificationKey.title] as? String else { return }
                self.requestsAtAnnouncement[title] = self.tracklistRequestCount
            },
            center.addObserver(forName: .radioTracklistDidRefresh, object: nil, queue: .main) { [weak self] n in
                guard let self, n.userInfo?[RadioMetadataNotificationKey.stationId] as? String == self.stationId,
                      let title = RadioTracklistService.shared.cached(stationId: self.stationId)?.first?.title else { return }
                self.refreshedTitles.append(title)
            }
        ]
        autoreleasepool {
            controller = StationDetailViewController(station: station)
            controller?.loadViewIfNeeded()
            controller?.beginAppearanceTransition(true, animated: false)
            controller?.endAppearanceTransition()
            isVisible = true
        }
    }

    private func labels(in view: UIView) -> [String] {
        (view as? UILabel).flatMap { $0.text }.map { [$0] } ?? view.subviews.flatMap { labels(in: $0) }
    }

    /// Ask the real table's data source for its first row. Works without a key window and does
    /// not inspect private properties or require visible-cell geometry on a headless simulator.
    var firstRowLabels: [String] {
        autoreleasepool {
            guard let controller, let table = controller.view.subviews.compactMap({ $0 as? UITableView }).first,
                  (table.dataSource?.tableView(table, numberOfRowsInSection: 0) ?? 0) > 0,
                  let cell = table.dataSource?.tableView(table, cellForRowAt: IndexPath(row: 0, section: 0)) else { return [] }
            return labels(in: cell.contentView)
        }
    }

    func hasRefreshedAfterAnnouncement(for title: String) -> Bool {
        guard let before = requestsAtAnnouncement[title] else { return false }
        return tracklistRequestCount > before && refreshedTitles.contains(title) && firstRowLabels.contains(title)
    }

    func stop() {
        autoreleasepool {
            guard let controller else { return }
            observers.forEach { NotificationCenter.default.removeObserver($0) }
            observers = []
            // The production screen leaves its ICY/theme selectors installed until deinit. Remove
            // them now so reset cannot reawaken the disappearing screen through those notifications.
            NotificationCenter.default.removeObserver(controller)
            controller.beginAppearanceTransition(false, animated: false)
            // Drain already-enqueued weak metadata handlers before viewDidDisappear cancels tasks.
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            controller.endAppearanceTransition()
            isVisible = false
            disappearingController = controller
            self.controller = nil
        }
    }

    /// Each pump drains UIKit's temporary Objective-C ownership, rather than keeping it alive
    /// in XCTest's outer autorelease pool until the synchronous test has already returned.
    func waitForRelease(timeout: TimeInterval = 5) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            autoreleasepool {
                RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
            }
            if isReleased { return true }
        }
        return isReleased
    }

    deinit { stop() }
}
