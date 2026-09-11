import PocketCastsDataModel
import XCTest
@testable import podcasts

/// M12.1 — the derived Overflow tab and the `host(for:)` resolver.
///
/// The properties that matter: an unpromoted **core** destination always has a
/// home (nothing becomes unreachable), an unpromoted *extra* never clutters the
/// More list, and repeat deep links do not stack instances.
final class OverflowTabTests: XCTestCase {

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

    // MARK: - Which rows Overflow holds

    /// The core of ADR 0001: Overflow covers unpromoted *core* destinations,
    /// because for those the bar is the only entry point.
    func testOverflowHoldsUnpromotedCoreDestinations() {
        let plan = layout(.podcasts, .streams).renderPlan(capacity: 5)

        XCTAssertEqual(plan.overflowDestinations, [.playlists, .discover, .profile])
    }

    /// An *extra* has another home in the app, so leaving it unpromoted must not
    /// put it in the More list.
    func testOverflowNeverHoldsAnUnpromotedExtra() {
        let plan = TabLayout.default.renderPlan(capacity: 5)

        XCTAssertTrue(plan.overflowDestinations.isEmpty)
        XCTAssertFalse(plan.overflowDestinations.contains(.upNext))
    }

    func testOverflowHoldsNoExtraWhenEveryCoreDestinationIsPromoted() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .profile).renderPlan(capacity: 5)

        XCTAssertTrue(plan.overflowDestinations.isEmpty)
    }

    /// Truncation is the one case where an extra reaches Overflow: a truncated
    /// slot has no visible home in that render.
    func testTruncatedExtrasDoAppearInOverflow() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .profile,
                          .upNext, .playlist(uuid: "a")).renderPlan(capacity: 5)

        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .playlists, .discover, .streams])
        XCTAssertEqual(plan.overflowDestinations, [.profile, .upNext, .playlist(uuid: "a")])
    }

    /// Truncated slots lead, so More reads as the continuation of the bar.
    func testOverflowListsTruncatedSlotsBeforeTheComplement() {
        let plan = layout(.podcasts, .streams, .upNext, .playlist(uuid: "a"), .playlist(uuid: "b"), .playlist(uuid: "c")).renderPlan(capacity: 5)

        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .streams, .upNext, .playlist(uuid: "a")])
        XCTAssertEqual(plan.overflowDestinations,
                       [.playlist(uuid: "b"), .playlist(uuid: "c"), .playlists, .discover, .profile])
    }

    func testOverflowDestinationsAreEmptyWheneverNoOverflowIsNeeded() {
        for capacity in 1...6 {
            let plan = TabLayout.default.renderPlan(capacity: capacity)
            XCTAssertEqual(plan.needsOverflow, !plan.overflowDestinations.isEmpty,
                           "capacity \(capacity): needsOverflow and overflowDestinations disagree")
        }
    }

    /// The reserved id can never be written into a layout, because it does not
    /// resolve to a destination.
    func testOverflowIDIsNotADestination() {
        XCTAssertNil(TabDestination(id: TabOverflow.id))
        XCTAssertEqual(TabOverflow.id, "overflow")
    }

    // MARK: - Rendering

    func testDefaultLayoutRendersNoOverflowTab() {
        let controller = MainTabBarController()
        controller.loadViewIfNeeded()

        XCTAssertEqual(controller.viewControllers?.count, 5)
        XCTAssertNil(overflowNav(in: controller))
    }

    func testOverflowTabIsRenderedLastAndTitledMore() {
        let controller = makeController(with: layout(.podcasts, .streams))

        XCTAssertEqual(controller.renderedDestinations, [.podcasts, .streams])
        XCTAssertEqual(controller.viewControllers?.count, 3)

        guard let nav = controller.viewControllers?.last as? UINavigationController else {
            return XCTFail("Overflow tab missing")
        }
        XCTAssertEqual(nav.tabDestinationID, TabOverflow.id)

        guard let overflow = nav.viewControllers.first as? OverflowViewController else {
            return XCTFail("Overflow tab is not rooted by OverflowViewController")
        }
        overflow.loadViewIfNeeded()

        XCTAssertEqual(overflow.title, "More")
        XCTAssertEqual(overflow.destinations, [.playlists, .discover, .profile])
    }

    /// The render plan drops a slot whose payload has gone missing, rather than
    /// rendering a tab that cannot be built.
    func testLayoutWithAnUnresolvablePlaylistUUIDRendersWithoutItAndDoesNotCrash() {
        let controller = makeController(with: layout(.playlist(uuid: "no-such-playlist"), .streams))

        XCTAssertEqual(controller.renderedDestinations, [.streams])
        // Streams plus Overflow holding the four unpromoted core destinations.
        XCTAssertEqual(controller.viewControllers?.count, 2)
        XCTAssertEqual(overflowViewController(in: controller)?.destinations,
                       [.podcasts, .playlists, .discover, .profile])
    }

    /// Five slots plus Overflow would be six tab items, which is where UIKit
    /// would insert its own un-themeable More tab. The render rules must never
    /// allow it.
    func testRenderedTabCountNeverExceedsCapacity() {
        let controller = makeController(with: layout(.podcasts, .playlists, .discover, .streams, .profile, .upNext))

        XCTAssertEqual(controller.viewControllers?.count, 5)
        XCTAssertEqual(controller.renderedDestinations.count, 4)
    }

    // MARK: - Promoted playlist slots

    /// A promoted playlist roots the same screen the playlists list pushes, and
    /// takes its title from the live playlist.
    func testPromotedPlaylistSlotRootsThePlaylistDetailScreen() {
        let playlist = makePlaylist(named: "New Releases")
        let controller = makeController(with: layout(.playlist(uuid: playlist.uuid), .streams))

        XCTAssertEqual(controller.renderedDestinations, [.playlist(uuid: playlist.uuid), .streams])

        guard let nav = controller.viewControllers?.first as? UINavigationController else {
            return XCTFail("playlist tab missing")
        }

        let root = nav.viewControllers.first
        XCTAssertTrue(root is PlaylistDetailViewController,
                      "a promoted playlist must root the same detail screen showFilter pushes")
        XCTAssertEqual(root?.ownTabDestinationID, "playlist:\(playlist.uuid)")

        // Loads the fake nav bar, which is what the tab root adapts: the back
        // chevron has nothing to pop and must not be shown.
        root?.loadViewIfNeeded()
        XCTAssertTrue((root as? PlaylistTabRootViewController)?.backBtn.isHidden == true)
        XCTAssertEqual(TabDestination.playlist(uuid: playlist.uuid).title(), "New Releases")
    }

    /// The slot carries a UUID, not a name, so a rename shows up without any
    /// change to the stored layout.
    func testPromotedPlaylistTitleFollowsARename() {
        let playlist = makePlaylist(named: "New Releases")

        playlist.playlistName = "Fresh"
        DataManager.sharedManager.save(playlist: playlist)

        XCTAssertEqual(TabDestination.playlist(uuid: playlist.uuid).title(), "Fresh")
    }

    func testAPlaylistThatExistsIsAvailableAndOneThatDoesNotIsNot() {
        let playlist = makePlaylist(named: "New Releases")

        XCTAssertTrue(TabDestination.playlist(uuid: playlist.uuid).isAvailable)
        XCTAssertFalse(TabDestination.playlist(uuid: "no-such-playlist").isAvailable)
        XCTAssertTrue(TabDestination.core.allSatisfy(\.isAvailable))
        XCTAssertTrue(TabDestination.upNext.isAvailable)
    }

    /// The gap that let a dead end ship green: the row-data tests above assert
    /// *which* destinations Overflow holds, never what tapping one pushes.
    ///
    /// A truncated playlist slot lands in Overflow. The tab-root variant hides
    /// its back chevron because a tab root has nothing to pop — pushing that
    /// same instance onto the More stack would leave no way back.
    func testAPlaylistPushedFromOverflowKeepsItsBackChevron() {
        let playlist = makePlaylist(named: "New Releases")
        let destination = TabDestination.playlist(uuid: playlist.uuid)
        let controller = makeController(with: layout(.podcasts, .playlists, .discover,
                                                     .streams, .profile, destination))

        // 6 slots at capacity 5, so the playlist is truncated into Overflow.
        XCTAssertFalse(controller.renderedDestinations.contains(destination),
                       "playlist should not be promoted in this layout")

        let nav = controller.host(for: destination)

        XCTAssertGreaterThan(nav.viewControllers.count, 1,
                             "the playlist must be pushed on top of the More list")

        guard let pushed = nav.viewControllers.last as? PlaylistTabRootViewController else {
            return XCTFail("Overflow did not push the playlist detail screen")
        }

        pushed.loadViewIfNeeded()

        XCTAssertFalse(pushed.backBtn.isHidden,
                       "a playlist pushed from Overflow must keep the chevron that returns to More")
    }

    // MARK: - host(for:)

    func testHostForAPromotedDestinationSelectsItsOwnTab() {
        let controller = makeController(with: layout(.podcasts, .streams))

        let nav = controller.host(for: .streams)

        XCTAssertEqual(controller.selectedIndex, 1)
        XCTAssertEqual(nav.tabDestinationID, TabDestination.streams.id)
        XCTAssertEqual(nav.viewControllers.count, 1, "a promoted destination's stack is left alone")
    }

    func testHostForAnUnpromotedDestinationSelectsOverflowAndPushes() {
        let controller = makeController(with: layout(.podcasts, .streams))

        let nav = controller.host(for: .profile)

        XCTAssertEqual(controller.selectedIndex, 2, "Overflow is the last tab")
        XCTAssertEqual(nav.tabDestinationID, TabOverflow.id)
        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.first is OverflowViewController)
        XCTAssertTrue(nav.viewControllers.last is ProfileViewController)
        XCTAssertEqual(nav.viewControllers.last?.ownTabDestinationID, TabDestination.profile.id)
    }

    func testTwoConsecutiveHostCallsLeaveOneInstanceOnTheOverflowStack() {
        let controller = makeController(with: layout(.podcasts, .streams))

        _ = controller.host(for: .profile)
        let nav = controller.host(for: .profile)

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is ProfileViewController)
    }

    func testHostForADifferentUnpromotedDestinationReplacesTheFirst() {
        let controller = makeController(with: layout(.podcasts, .streams))

        _ = controller.host(for: .profile)
        let nav = controller.host(for: .playlists)

        XCTAssertEqual(nav.viewControllers.count, 2)
        XCTAssertTrue(nav.viewControllers.last is PlaylistsHostViewController)
    }

    // MARK: - Deep links through Overflow

    /// The Siri / notification / deep-link path that ADR 0001 exists to keep
    /// alive: hiding Discover must not orphan `navigateToDiscover(category:)`.
    func testNavigateToDiscoverCategoryResolvesThroughOverflowWhenDiscoverIsHidden() {
        let controller = makeController(with: layout(.podcasts, .streams))

        controller.navigateToDiscover(category: "news", animated: false)

        guard let nav = overflowNav(in: controller) else {
            return XCTFail("Overflow tab missing")
        }
        XCTAssertEqual(controller.selectedIndex, 2)
        XCTAssertTrue(nav.viewControllers.last is DiscoverDelegate)
    }

    func testNavigateToProfileResolvesThroughOverflowWhenProfileIsHidden() {
        let controller = makeController(with: layout(.podcasts, .streams))

        controller.navigateToProfile(animated: false)

        XCTAssertEqual(controller.selectedIndex, 2)
        XCTAssertTrue(overflowNav(in: controller)?.viewControllers.last is ProfileViewController)
    }

    /// The widget's `pktc://podcasts` tile, with Podcasts hidden.
    func testNavigateToPodcastListResolvesThroughOverflowWhenPodcastsIsHidden() {
        let controller = makeController(with: layout(.playlists, .streams))

        controller.navigateToPodcastList(false)

        guard let nav = overflowNav(in: controller) else {
            return XCTFail("Overflow tab missing")
        }
        XCTAssertEqual(controller.selectedIndex, 2)
        XCTAssertTrue(nav.viewControllers.first is OverflowViewController,
                      "the back button returns to the More list")
        XCTAssertTrue(nav.viewControllers.last is PodcastListViewController)
    }

    /// Up Next is an *extra*: it has no Overflow row, so it must still fall back
    /// to the Playlists host segment rather than going nowhere.
    func testNavigateToUpNextLandsOnThePlaylistsSegmentWhenUpNextIsUnpromoted() {
        let controller = makeController(with: layout(.playlists, .streams))

        guard let playlistsIndex = controller.renderedDestinations.firstIndex(of: .playlists),
              let nav = controller.viewControllers?[playlistsIndex] as? UINavigationController,
              let host = nav.viewControllers.first as? PlaylistsHostViewController else {
            return XCTFail("Playlists tab missing")
        }
        host.loadViewIfNeeded()

        controller.navigateToUpNext(false)

        XCTAssertEqual(controller.selectedIndex, playlistsIndex)
        XCTAssertNotNil(host.children.first as? UpNextViewController)
    }

    // MARK: - Selection persistence

    func testOverflowSelectionIsRestoredByItsReservedID() {
        UserDefaults.standard.set(TabOverflow.id, forKey: Constants.UserDefaults.lastTabOpenedID)

        let controller = makeController(with: layout(.podcasts, .streams))

        XCTAssertEqual(controller.selectedIndex, 2)
    }

    /// A stored Overflow selection has to degrade gracefully once the layout
    /// stops needing Overflow at all.
    func testStoredOverflowSelectionFallsBackToTheFirstTabWhenOverflowIsGone() {
        UserDefaults.standard.set(TabOverflow.id, forKey: Constants.UserDefaults.lastTabOpenedID)

        let controller = makeController(with: TabLayout.default)

        XCTAssertEqual(controller.selectedIndex, 0)
        XCTAssertNil(overflowNav(in: controller))
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
        guard let nav = controller.viewControllers?.last as? UINavigationController,
              nav.tabDestinationID == TabOverflow.id else {
            return nil
        }

        return nav
    }

    private func overflowViewController(in controller: MainTabBarController) -> OverflowViewController? {
        overflowNav(in: controller)?.viewControllers.first as? OverflowViewController
    }
}
