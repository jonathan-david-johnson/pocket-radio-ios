import PocketCastsDataModel
import XCTest
@testable import podcasts

/// M12.2 — the controlled rebuild.
///
/// The properties that matter: the user stays where they were across a rebuild
/// (by destination *identity*, never by index), a layout that drops the selected
/// destination falls back rather than crashing or landing nowhere, Overflow
/// appears and disappears with the layout that implies it, and the persisted
/// selection agrees with what is actually on screen afterwards.
final class TabBarRebuildTests: XCTestCase {

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
        // Skip the first-launch remap so a stored selection is honoured as-is.
        UserDefaults.standard.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM12)
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        createdPlaylists.forEach { DataManager.sharedManager.delete(playlist: $0) }
        createdPlaylists = []
        super.tearDown()
    }

    private var createdPlaylists: [EpisodeFilter] = []

    // MARK: - Selection survives a reorder

    /// The headline requirement: reordering slots moves the user's destination
    /// to a different index, and the rebuild has to follow the destination, not
    /// the index it used to sit at.
    func testReorderThenRebuildRestoresTheSameSelectedDestination() {
        let controller = makeController(with: TabLayout.default)

        guard let discoverIndex = controller.renderedDestinations.firstIndex(of: .discover) else {
            XCTFail("Discover should be promoted in the default layout")
            return
        }
        controller.selectedIndex = discoverIndex

        // Discover moves from index 2 to index 0.
        controller.rebuildTabs(from: layout(.discover, .podcasts, .playlists, .streams, .profile), animated: false)

        XCTAssertEqual(controller.renderedDestinations, [.discover, .podcasts, .playlists, .streams])
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.renderedDestinations[safe: controller.selectedIndex], .discover)
    }

    /// Selection is restored by id, so it must survive even when the
    /// destination's index is unchanged but the identity at that index differs.
    func testRebuildFollowsTheDestinationRatherThanHoldingTheIndex() {
        let controller = makeController(with: layout(.podcasts, .streams))

        controller.selectedIndex = 1
        XCTAssertEqual(controller.renderedDestinations[safe: 1], .streams)

        // Streams stays promoted but something else now occupies index 1.
        controller.rebuildTabs(from: layout(.podcasts, .discover, .streams), animated: false)

        XCTAssertEqual(controller.renderedDestinations[safe: controller.selectedIndex], .streams)
        XCTAssertEqual(controller.selectedIndex, 2)
    }

    // MARK: - Losing the selected destination

    func testRemovingTheSelectedDestinationFallsBackToTheFirstSlot() {
        let controller = makeController(with: TabLayout.default)

        guard let streamsIndex = controller.renderedDestinations.firstIndex(of: .streams) else {
            XCTFail("Streams should be promoted in the default layout")
            return
        }
        controller.selectedIndex = streamsIndex

        controller.rebuildTabs(from: layout(.podcasts, .playlists), animated: false)

        XCTAssertFalse(controller.renderedDestinations.contains(.streams))
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(controller.renderedDestinations.first, .podcasts)
    }

    /// A dropped destination is not gone from the app — it falls into Overflow —
    /// but it no longer has a *tab*, so the selection cannot follow it there.
    /// First slot, not the Overflow row that now lists it.
    func testRemovingTheSelectedDestinationDoesNotSelectOverflow() {
        let controller = makeController(with: layout(.profile, .podcasts, .streams))

        guard let profileIndex = controller.renderedDestinations.firstIndex(of: .profile) else {
            XCTFail("Profile should be promoted in this layout")
            return
        }
        controller.selectedIndex = profileIndex

        controller.rebuildTabs(from: layout(.podcasts, .streams), animated: false)

        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertNotEqual(controller.selectedViewController?.tabDestinationID, TabOverflow.id)
        XCTAssertEqual(overflowViewController(in: controller)?.destinations, [.playlists, .discover, .profile, .upNext])
    }

    // MARK: - Rebuilding Overflow

    func testRebuildingIntoASmallerLayoutUpdatesOverflow() {
        let controller = makeController(with: TabLayout.default)

        XCTAssertNotNil(overflowNav(in: controller), "six required destinations need More")
        XCTAssertEqual(controller.tabViewControllers.count, 5)

        controller.rebuildTabs(from: layout(.podcasts, .streams), animated: false)

        XCTAssertEqual(controller.renderedDestinations, [.podcasts, .streams])
        // Two promoted slots plus the derived Overflow tab.
        XCTAssertEqual(controller.tabViewControllers.count, 3)
        XCTAssertNotNil(overflowNav(in: controller))
        XCTAssertEqual(overflowViewController(in: controller)?.destinations, [.playlists, .discover, .profile, .upNext])
    }

    func testRebuildingIntoDefaultKeepsRequiredDestinationsInOverflow() {
        let controller = makeController(with: layout(.podcasts, .streams))

        XCTAssertNotNil(overflowNav(in: controller))
        XCTAssertEqual(controller.tabViewControllers.count, 3)

        controller.rebuildTabs(from: TabLayout.default, animated: false)

        XCTAssertEqual(controller.renderedDestinations, [.podcasts, .playlists, .discover, .streams])
        XCTAssertEqual(controller.tabViewControllers.count, 5)
        XCTAssertEqual(overflowViewController(in: controller)?.destinations, [.profile, .upNext])
    }

    /// Overflow's id names a position, not a destination. Sitting on Overflow
    /// and rebuilding into a layout that still needs it must stay on Overflow —
    /// at its new index.
    func testSelectionOnOverflowSurvivesARebuildThatKeepsOverflow() {
        let controller = makeController(with: layout(.podcasts, .streams))

        controller.selectedIndex = 2
        XCTAssertEqual((controller.viewControllers?[2])?.tabDestinationID, TabOverflow.id)

        controller.rebuildTabs(from: layout(.podcasts), animated: false)

        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(controller.selectedViewController?.tabDestinationID, TabOverflow.id)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID),
                       TabOverflow.id)
    }

    /// Default still has More; selection follows its new index.
    func testSelectionOnOverflowSurvivesRebuildingToDefault() {
        let controller = makeController(with: layout(.podcasts, .streams))

        controller.selectedIndex = 2

        controller.rebuildTabs(from: TabLayout.default, animated: false)

        XCTAssertNotNil(overflowNav(in: controller))
        XCTAssertEqual(controller.selectedIndex, 4)
        XCTAssertEqual(UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID),
                       TabOverflow.id)
    }

    // MARK: - The persisted selection

    /// `lastTabOpenedID` is written after the rebuild, not before, so it always
    /// describes what is on screen rather than what was asked for.
    func testLastTabOpenedIDAfterRebuildMatchesTheVisibleSelection() {
        let controller = makeController(with: TabLayout.default)

        guard let playlistsIndex = controller.renderedDestinations.firstIndex(of: .playlists) else {
            XCTFail("Playlists should be promoted in the default layout")
            return
        }
        controller.selectedIndex = playlistsIndex

        controller.rebuildTabs(from: layout(.streams, .playlists, .podcasts), animated: false)

        let storedID = UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID)
        XCTAssertEqual(storedID, TabDestination.playlists.id)
        XCTAssertEqual(storedID, controller.renderedDestinations[safe: controller.selectedIndex]?.id)
    }

    /// The fallback case is the one that would go wrong if the write happened
    /// first: the stored id would name a destination with no tab.
    func testLastTabOpenedIDRecordsTheFallbackWhenTheSelectedDestinationIsDropped() {
        UserDefaults.standard.set(TabDestination.discover.id, forKey: Constants.UserDefaults.lastTabOpenedID)

        let controller = makeController(with: TabLayout.default)
        XCTAssertEqual(controller.renderedDestinations[safe: controller.selectedIndex], .discover)

        controller.rebuildTabs(from: layout(.streams, .podcasts), animated: false)

        XCTAssertEqual(UserDefaults.standard.string(forKey: Constants.UserDefaults.lastTabOpenedID),
                       TabDestination.streams.id)
        XCTAssertEqual(controller.renderedDestinations[safe: controller.selectedIndex], .streams)
    }

    // MARK: - Structural integrity after a rebuild

    /// `viewControllers[i]` roots `renderedDestinations[i]` — the invariant every
    /// lookup in `MainTabBarController` depends on.
    func testRebuiltTabsCarryTheirDestinationID() {
        let controller = makeController(with: TabLayout.default)

        controller.rebuildTabs(from: layout(.streams, .podcasts), animated: false)

        XCTAssertEqual(controller.tabViewControllers.count, controller.renderedDestinations.count + 1)

        for (index, destination) in controller.renderedDestinations.enumerated() {
            let nav = controller.viewControllers?[index] as? UINavigationController
            XCTAssertEqual(nav?.viewControllers.first?.tabDestinationID, destination.id)
        }
    }

    /// A playlist slot is the reason slot ids are strings. Promoting one in a
    /// rebuild must root the playlist screen, and the selection must follow the
    /// playlist rather than the ordinal.
    func testRebuildCanPromoteAPlaylistSlotAndKeepSelectionOnIt() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.playlist(uuid: playlist.uuid), .streams))

        controller.selectedIndex = 0

        controller.rebuildTabs(from: layout(.streams, .playlist(uuid: playlist.uuid)), animated: false)

        XCTAssertEqual(controller.renderedDestinations, [.streams, .playlist(uuid: playlist.uuid)])
        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertNotNil((controller.viewControllers?[1] as? UINavigationController)?
            .viewControllers.first as? PlaylistTabRootViewController)
    }

    /// Nothing in the layout can produce an empty bar: with no slots at all the
    /// complement is every core destination, so Overflow alone renders.
    func testRebuildingFromAnEmptyLayoutRendersOverflowAlone() {
        let controller = makeController(with: TabLayout.default)

        controller.rebuildTabs(from: TabLayout(slots: []), animated: false)

        XCTAssertTrue(controller.renderedDestinations.isEmpty)
        XCTAssertEqual(controller.tabViewControllers.count, 1)
        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertEqual(overflowViewController(in: controller)?.destinations, TabDestination.core)
    }

    /// The ⌘1–⌘N bindings are positional over the visible slots, so they have to
    /// be re-installed or they keep the pre-rebuild titles and indices.
    func testRebuildReinstallsThePositionalTabShortcuts() {
        let controller = makeController(with: TabLayout.default)

        XCTAssertEqual(controller.tabKeyCommands.count, 4)

        controller.rebuildTabs(from: layout(.streams, .podcasts), animated: false)

        XCTAssertEqual(controller.tabKeyCommands.count, 2)
        XCTAssertEqual(controller.tabKeyCommands.first?.title, TabDestination.streams.title())
        XCTAssertEqual(controller.tabKeyCommands.first?.input, "1")
    }

    /// Under Liquid Glass the mini player is a child of the tab bar controller
    /// so it can serve as the bottom accessory, which puts it in
    /// `viewControllers` beside the tabs. Replacing the tabs must leave it
    /// attached and playback untouched. `setupMiniPlayer()` runs once, from
    /// `viewDidLoad`.
    func testMiniPlayerSurvivesARebuild() {
        let controller = makeController(with: TabLayout.default)

        guard let miniPlayer = NavigationManager.sharedManager.miniPlayer else {
            XCTFail("the tab bar controller should have installed a mini player")
            return
        }

        controller.rebuildTabs(from: layout(.streams, .podcasts), animated: false)

        XCTAssertTrue(NavigationManager.sharedManager.miniPlayer === miniPlayer,
                      "a rebuild must not replace the mini player")
        XCTAssertTrue(miniPlayer.parent === controller,
                      "a rebuild must leave the mini player attached")
        XCTAssertFalse(controller.tabViewControllers.contains(miniPlayer),
                       "the mini player is attached beside the tabs, not as one of them")
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

    private func layout(_ destinations: TabDestination...) -> TabLayout {
        TabLayout(slots: destinations.map(TabSlot.init))
    }

    private func makeController(with layout: TabLayout) -> MainTabBarController {
        TabLayoutStore.shared.save(layout)

        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        return controller
    }

    private func overflowNav(in controller: MainTabBarController) -> UINavigationController? {
        guard let nav = controller.tabViewControllers.last as? UINavigationController,
              nav.tabDestinationID == TabOverflow.id else {
            return nil
        }

        return nav
    }

    private func overflowViewController(in controller: MainTabBarController) -> OverflowViewController? {
        overflowNav(in: controller)?.viewControllers.first as? OverflowViewController
    }
}
