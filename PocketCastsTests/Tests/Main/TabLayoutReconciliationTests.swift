import PocketCastsDataModel
import XCTest
@testable import podcasts

/// M12.3 §4 — live reconciliation of promoted playlist slots.
///
/// The rule under every assertion here: **the slot count never changes.**
/// Content is live, structure is frozen. A rename retitles, a deletion
/// retitles and swaps a root, and neither adds or removes a tab, because
/// changing the count moves `selectedIndex` under whatever is on screen.
final class TabLayoutReconciliationTests: XCTestCase {

    private static let keys = [
        Constants.UserDefaults.lastTabOpened,
        Constants.UserDefaults.lastTabOpenedMigratedM5,
        Constants.UserDefaults.lastTabOpenedID,
        Constants.UserDefaults.lastTabOpenedMigratedM12,
        Constants.UserDefaults.tabLayout
    ]

    private var createdPlaylists: [EpisodeFilter] = []

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        UserDefaults.standard.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM12)
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        createdPlaylists.forEach { DataManager.sharedManager.delete(playlist: $0) }
        createdPlaylists = []
        super.tearDown()
    }

    // MARK: - Rename

    func testRenamingAPromotedPlaylistRetitlesItsTabAndLeavesTheSlotCountAlone() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))
        let slotCount = controller.viewControllers?.count

        XCTAssertEqual(tabTitle(at: 1, in: controller), "New Releases")

        playlist.playlistName = "Fresh"
        DataManager.sharedManager.save(playlist: playlist)
        controller.reconcilePlaylistSlots()

        XCTAssertEqual(tabTitle(at: 1, in: controller), "Fresh")
        XCTAssertEqual(controller.viewControllers?.count, slotCount)
        XCTAssertEqual(controller.renderedDestinations.count, 2)
    }

    func testReconcilingLeavesTheRealPlaylistScreenInPlace() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))

        let rootBefore = navController(at: 1, in: controller)?.viewControllers.first
        controller.reconcilePlaylistSlots()

        XCTAssertTrue(navController(at: 1, in: controller)?.viewControllers.first === rootBefore,
                      "a rename must not rebuild the screen the user is looking at")
    }

    // MARK: - Deletion

    func testDeletingAPromotedPlaylistKeepsTheSlotAndSwapsInThePlaceholder() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))
        let slotCount = controller.viewControllers?.count

        deletePlaylist(playlist)
        controller.reconcilePlaylistSlots()

        XCTAssertEqual(controller.viewControllers?.count, slotCount,
                       "the slot is kept — dropping it would shift every index after it")
        XCTAssertEqual(controller.renderedDestinations[safe: 1], .playlist(uuid: playlist.uuid),
                       "and it still names the playlist that went away")
        XCTAssertTrue(navController(at: 1, in: controller)?.viewControllers.first is MissingPlaylistViewController)
        XCTAssertEqual(tabTitle(at: 1, in: controller), MissingPlaylistViewController.tabTitle)
    }

    /// Screens pushed above the playlist root belong to what the user is doing
    /// right now. Only index 0 is replaced, so they finish that and meet the
    /// placeholder when they pop back.
    func testDeletingAPromotedPlaylistLeavesPushedScreensOnTheStack() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))

        let pushed = UIViewController()
        navController(at: 1, in: controller)?.pushViewController(pushed, animated: false)

        deletePlaylist(playlist)
        controller.reconcilePlaylistSlots()

        let stack = navController(at: 1, in: controller)?.viewControllers
        XCTAssertEqual(stack?.count, 2)
        XCTAssertTrue(stack?.first is MissingPlaylistViewController)
        XCTAssertTrue(stack?.last === pushed, "the user is not thrown out of what they were reading")
    }

    func testReconcilingTwiceOverADeletedPlaylistDoesNotStackPlaceholders() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))

        deletePlaylist(playlist)
        controller.reconcilePlaylistSlots()
        let placeholder = navController(at: 1, in: controller)?.viewControllers.first
        controller.reconcilePlaylistSlots()

        XCTAssertEqual(navController(at: 1, in: controller)?.viewControllers.count, 1)
        XCTAssertTrue(navController(at: 1, in: controller)?.viewControllers.first === placeholder,
                      "the second pass is a no-op, not a second swap")
    }

    /// The placeholder keeps the slot's identity, so selection restoration and
    /// deep link resolution still find the tab by `destinationID`.
    func testThePlaceholderCarriesTheSlotsDestinationID() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))

        deletePlaylist(playlist)
        controller.reconcilePlaylistSlots()

        let placeholder = navController(at: 1, in: controller)?.viewControllers.first
        XCTAssertEqual(placeholder?.ownTabDestinationID, TabDestination.playlist(uuid: playlist.uuid).id)
    }

    // MARK: - The notification is actually wired up

    /// Everything above drives `reconcilePlaylistSlots()` directly. This one
    /// proves the observer registered in `viewDidLoad` reaches it, which is the
    /// only link the other tests cannot see.
    func testPostingPlaylistChangedRetitlesTheTabWithoutCallingReconcileDirectly() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.podcasts, .playlist(uuid: playlist.uuid)))

        playlist.playlistName = "Fresh"
        DataManager.sharedManager.save(playlist: playlist)
        NotificationCenter.default.post(name: Constants.Notifications.playlistChanged, object: nil)

        XCTAssertEqual(tabTitle(at: 1, in: controller), "Fresh")
    }

    // MARK: - Core slots are untouched

    func testReconcilingDoesNotTouchNonPlaylistSlots() {
        let controller = makeController(with: TabLayout.default)
        let roots = controller.viewControllers?.compactMap { ($0 as? UINavigationController)?.viewControllers.first }

        controller.reconcilePlaylistSlots()

        let after = controller.viewControllers?.compactMap { ($0 as? UINavigationController)?.viewControllers.first }
        XCTAssertEqual(roots?.count, after?.count)
        zip(roots ?? [], after ?? []).forEach { XCTAssertTrue($0 === $1) }
    }

    // MARK: - Helpers

    private func makePlaylist(named name: String) -> EpisodeFilter {
        let playlist = EpisodeFilter()
        playlist.uuid = UUID().uuidString
        playlist.playlistName = name
        DataManager.sharedManager.save(playlist: playlist)
        createdPlaylists.append(playlist)

        return playlist
    }

    private func deletePlaylist(_ playlist: EpisodeFilter) {
        DataManager.sharedManager.delete(playlist: playlist)
        createdPlaylists.removeAll { $0.uuid == playlist.uuid }
    }

    private func layout(_ destinations: TabDestination...) -> TabLayout {
        TabLayout(slots: destinations.map(TabSlot.init))
    }

    private func makeController(with layout: TabLayout) -> MainTabBarController {
        TabLayoutStore.shared.save(layout)

        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        return controller
    }

    private func navController(at index: Int, in controller: MainTabBarController) -> UINavigationController? {
        controller.viewControllers?[safe: index] as? UINavigationController
    }

    private func tabTitle(at index: Int, in controller: MainTabBarController) -> String? {
        navController(at: index, in: controller)?.tabBarItem?.title
    }
}
