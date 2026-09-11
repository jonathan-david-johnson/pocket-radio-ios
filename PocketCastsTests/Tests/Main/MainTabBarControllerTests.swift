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

    /// M12: the default layout must render exactly the five destinations the app
    /// had before the layout became configurable, in the same order.
    func testTabBarHasFiveTabs() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.renderedDestinations, [.podcasts, .playlists, .discover, .streams, .profile])

        // Under Liquid Glass the mini player is added as a child of the tab bar
        // controller (a tab accessory), so it shows up in `viewControllers`
        // alongside the five tab navigation stacks. Count only the tab stacks.
        let tabStacks = controller.viewControllers?.filter { $0 is UINavigationController } ?? []
        XCTAssertEqual(tabStacks.count, 5)
    }

    func testDefaultLayoutNeedsNoOverflowTab() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertFalse(TabLayoutStore.shared.load().renderPlan(capacity: 5).needsOverflow)
        XCTAssertEqual(controller.viewControllers?.count, TabLayout.default.slots.count)
    }

    func testNavigateToUpNextSelectsFilterTabAndUpNextSegment() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        // Load the playlists tab host's view before navigating so viewDidLoad fires
        // and showChild(playlistsNav) establishes the initial child state.
        guard let playlistsIndex = controller.renderedDestinations.firstIndex(of: .playlists) else {
            return XCTFail("Playlists tab missing")
        }
        let nav = controller.viewControllers?[playlistsIndex] as? UINavigationController
        let host = nav?.viewControllers.first as? PlaylistsHostViewController
        host?.loadViewIfNeeded()

        controller.navigateToUpNext(false)

        XCTAssertEqual(controller.selectedIndex, playlistsIndex)
        XCTAssertGreaterThan(host?.children.count ?? 0, 0, "host should have child view controllers after loadViewIfNeeded")
        XCTAssertNotNil(host?.children.first as? UpNextViewController,
                        "navigateToUpNext should leave UpNextViewController visible inside host")
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
            let nav = controller.viewControllers?[index] as? UINavigationController
            XCTAssertEqual(nav?.viewControllers.first?.tabDestinationID, destination.id)
        }
    }
}
