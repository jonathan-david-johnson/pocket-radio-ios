import XCTest
@testable import podcasts

final class MainTabBarControllerTests: XCTestCase {

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastTabOpened)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastTabOpenedMigratedM5)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastTabOpened)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastTabOpenedMigratedM5)
        super.tearDown()
    }

    func testTabBarHasFiveTabs() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()
        XCTAssertEqual(controller.pcTabs.count, 5)

        // Under Liquid Glass the mini player is added as a child of the tab bar
        // controller (a tab accessory), so it shows up in `viewControllers`
        // alongside the five tab navigation stacks. Count only the tab stacks.
        let tabStacks = controller.viewControllers?.filter { $0 is UINavigationController } ?? []
        XCTAssertEqual(tabStacks.count, 5)
    }

    func testNavigateToUpNextSelectsFilterTabAndUpNextSegment() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        // Load the filter tab host's view before navigating so viewDidLoad fires
        // and showChild(playlistsNav) establishes the initial child state.
        guard let filterIndex = controller.pcTabs.firstIndex(of: .filter) else {
            return XCTFail("Filter tab missing")
        }
        let nav = controller.viewControllers?[filterIndex] as? UINavigationController
        let host = nav?.viewControllers.first as? PlaylistsHostViewController
        host?.loadViewIfNeeded()

        controller.navigateToUpNext(false)

        XCTAssertEqual(controller.selectedIndex, filterIndex)
        XCTAssertGreaterThan(host?.children.count ?? 0, 0, "host should have child view controllers after loadViewIfNeeded")
        XCTAssertNotNil(host?.children.first as? UpNextViewController,
                        "navigateToUpNext should leave UpNextViewController visible inside host")
    }

    func testLastTabOpenedMigrationRemapsOldUpNextIndex() {
        // Pre-M5 layout: [.podcasts, .filter, .discover, .upNext, .streams, .profile]
        // Old upNext raw index = 3.
        UserDefaults.standard.set(3, forKey: Constants.UserDefaults.lastTabOpened)
        UserDefaults.standard.removeObject(forKey: Constants.UserDefaults.lastTabOpenedMigratedM5)
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()
        // After migration, opening old upNext should land on filter tab.
        XCTAssertEqual(controller.selectedIndex, controller.pcTabs.firstIndex(of: .filter))
    }
}
