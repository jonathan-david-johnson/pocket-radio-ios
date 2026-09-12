import PocketCastsDataModel
import XCTest
@testable import podcasts

/// M12.3 §3 — the safe-apply gate.
///
/// A layout arriving from another device is not a layout the user asked for in
/// this moment, so it may only replace the live bar when there is nothing to
/// lose: no modal up, every stack at root. Otherwise it is persisted and left
/// to render at next launch, with no prompt.
@MainActor
final class TabLayoutSyncApplyTests: XCTestCase {

    private static let keys = [
        Constants.UserDefaults.lastTabOpened,
        Constants.UserDefaults.lastTabOpenedMigratedM5,
        Constants.UserDefaults.lastTabOpenedID,
        Constants.UserDefaults.lastTabOpenedMigratedM12,
        Constants.UserDefaults.tabLayout
    ]

    private var window: UIWindow?

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM12)
    }

    override func tearDown() {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Applied

    func testALayoutArrivingWithEverythingAtRestIsAppliedImmediately() {
        let controller = makeController(with: TabLayout.default)
        XCTAssertTrue(controller.isSafeToRebuild)

        let applied = TabLayoutApplier.applyFromSync(layout(.streams, .podcasts), to: controller)

        XCTAssertTrue(applied)
        XCTAssertEqual(controller.renderedDestinations.prefix(2).map(\.id), ["streams", "podcasts"])
    }

    // MARK: - Deferred

    func testALayoutArrivingWhileAModalIsPresentedIsPersistedButNotApplied() {
        let controller = makeController(with: TabLayout.default)
        present(UIViewController(), from: controller)
        XCTAssertFalse(controller.isSafeToRebuild)

        let applied = TabLayoutApplier.applyFromSync(layout(.streams, .podcasts), to: controller)

        XCTAssertFalse(applied, "nothing may be torn down from under a presented screen")
        XCTAssertEqual(controller.renderedDestinations, TabDestination.core,
                       "the live bar is untouched")
        XCTAssertEqual(TabLayoutStore.shared.load().slots.map(\.destinationID), ["streams", "podcasts"],
                       "but the layout is persisted, so it renders at next launch")
    }

    func testALayoutArrivingWhileATabHasSomethingPushedIsPersistedButNotApplied() {
        let controller = makeController(with: TabLayout.default)

        guard let navController = controller.viewControllers?.first as? UINavigationController else {
            return XCTFail("every tab should be wrapped in a navigation controller")
        }
        navController.pushViewController(UIViewController(), animated: false)
        XCTAssertFalse(controller.isSafeToRebuild)

        let applied = TabLayoutApplier.applyFromSync(layout(.streams, .podcasts), to: controller)

        XCTAssertFalse(applied)
        XCTAssertEqual(controller.renderedDestinations, TabDestination.core)
        XCTAssertEqual(TabLayoutStore.shared.load().slots.map(\.destinationID), ["streams", "podcasts"])
    }

    func testAModalPresentedFromInsideATabAlsoBlocksTheRebuild() {
        let controller = makeController(with: TabLayout.default)

        guard let navController = controller.viewControllers?.first as? UINavigationController else {
            return XCTFail("every tab should be wrapped in a navigation controller")
        }
        present(UIViewController(), from: navController, window: controller)

        XCTAssertFalse(controller.isSafeToRebuild,
                       "a sheet put up by a tab is just as presented as one put up by the bar")
    }

    func testNoLiveControllerPersistsWithoutApplying() {
        let applied = TabLayoutApplier.applyFromSync(layout(.streams), to: nil)

        XCTAssertFalse(applied)
        XCTAssertEqual(TabLayoutStore.shared.load().slots.map(\.destinationID), ["streams"])
    }

    // MARK: - Last-write-wins depends on the stamp surviving

    /// `apply` stamps `updatedAt` because the user just made the change here.
    /// `applyFromSync` must not: re-stamping would make this device look like
    /// the newer writer and bounce the layout back at whoever changed it.
    func testApplyingFromSyncKeepsTheRemoteTimestamp() {
        let controller = makeController(with: TabLayout.default)
        let remoteStamp = Date(timeIntervalSince1970: 1_700_000_000)

        TabLayoutApplier.applyFromSync(TabLayout(slots: [TabSlot(.streams)], updatedAt: remoteStamp),
                                       to: controller)

        XCTAssertEqual(TabLayoutStore.shared.load().updatedAt.timeIntervalSince1970,
                       remoteStamp.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    // MARK: - Capacity differences between devices

    /// A layout written on a device that could show six slots has to degrade,
    /// not error: five tab positions, one of which Overflow claims.
    func testALayoutWrittenAtCapacitySixRendersAsFourVisiblePlusOverflow() {
        let sixSlots = layout(.podcasts, .playlists, .discover, .streams, .profile, .upNext)

        let plan = sixSlots.renderPlan(capacity: 5)

        XCTAssertTrue(plan.needsOverflow)
        XCTAssertEqual(plan.visibleDestinations.count, 4)
        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .playlists, .discover, .streams])
        XCTAssertEqual(plan.overflowDestinations, [.profile, .upNext])
    }

    // MARK: - Helpers

    private func layout(_ destinations: TabDestination...) -> TabLayout {
        TabLayout(slots: destinations.map(TabSlot.init))
    }

    private func makeController(with layout: TabLayout) -> MainTabBarController {
        TabLayoutStore.shared.save(layout)

        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        return controller
    }

    /// Presentation needs a window: `presentedViewController` is only set for a
    /// controller that is actually in a hierarchy.
    private func present(_ presented: UIViewController,
                         from presenter: UIViewController,
                         window root: UIViewController? = nil) {
        let hostWindow = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        hostWindow.rootViewController = root ?? presenter
        hostWindow.makeKeyAndVisible()
        window = hostWindow

        presenter.present(presented, animated: false)
    }
}
