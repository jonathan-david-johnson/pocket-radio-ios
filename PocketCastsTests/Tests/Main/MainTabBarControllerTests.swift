import XCTest
@testable import podcasts

final class MainTabBarControllerTests: XCTestCase {

    private static let keys = [
        Constants.UserDefaults.lastTabOpened,
        Constants.UserDefaults.lastTabOpenedMigratedM5,
        Constants.UserDefaults.lastTabOpenedID,
        Constants.UserDefaults.lastTabOpenedMigratedM12,
        Constants.UserDefaults.tabLayout
    ]

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    /// Four content destinations plus More fill the default bar.
    func testTabBarHasFiveTabs() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.renderedDestinations, [.podcasts, .playlists, .discover, .streams])

        // Under Liquid Glass the mini player is added as a child of the tab bar
        // controller (a tab accessory), so it shows up in `viewControllers`
        // alongside the five tab navigation stacks. Count only the tab stacks.
        let tabStacks = controller.viewControllers?.filter { $0 is UINavigationController } ?? []
        XCTAssertEqual(tabStacks.count, 5)
    }

    func testDefaultLayoutIncludesOverflowTab() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertTrue(TabLayoutStore.shared.load().renderPlan(capacity: 5).needsOverflow)
        XCTAssertEqual(controller.tabBar.items?.count, 5)
        XCTAssertEqual(controller.tabViewControllers.count, 5)
    }

    func testNavigateToUpNextSelectsMoreAndPushesUpNext() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()
        controller.navigateToUpNext(false)
        XCTAssertEqual(controller.selectedViewController?.tabDestinationID, TabOverflow.id)
        XCTAssertTrue(controller.overflowNavigationController?.topViewController is UpNextViewController)
    }

    func testLastTabOpenedMigrationRemapsOldUpNextIndex() {
        // Pre-M5 layout: [.podcasts, .filter, .discover, .upNext, .streams, .profile]
        // Old upNext raw index = 3.
        UserDefaults.standard.set(3, forKey: Constants.UserDefaults.lastTabOpened)

        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        // After both migrations, opening old upNext should land on the playlists tab.
        XCTAssertEqual(UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID),
                       TabDestination.playlists.id)
        XCTAssertEqual(controller.selectedIndex, controller.renderedDestinations.firstIndex(of: .playlists))
    }

    /// Selection is restored by identity, so a reordered layout still opens the
    /// destination the user last used rather than whatever now sits at that index.
    func testSelectedTabIsRestoredByDestinationIDNotIndex() {
        UserDefaults.standard.set(TabDestination.streams.id, forKey: Constants.UserDefaults.lastTabOpenedID)
        UserDefaults.standard.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM12)

        let reordered = TabLayout(slots: [TabSlot(.streams), TabSlot(.podcasts), TabSlot(.playlists),
                                          TabSlot(.discover), TabSlot(.profile)])
        TabLayoutStore.shared.save(reordered)

        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.renderedDestinations.first, .streams)
        XCTAssertEqual(controller.selectedIndex, 0)
    }

    /// `tabBarItem.tag` no longer carries meaning; identity lives on the
    /// destination id instead.
    func testRootViewControllersCarryTheirDestinationID() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        for (index, destination) in controller.renderedDestinations.enumerated() {
            let nav = controller.tabViewControllers[safe: index] as? UINavigationController
            XCTAssertEqual(nav?.viewControllers.first?.tabDestinationID, destination.id)
        }
    }
}
