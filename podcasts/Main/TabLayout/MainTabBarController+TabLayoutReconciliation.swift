import PocketCastsUtils
import UIKit

/// M12.3 §4 — live reconciliation of promoted playlist slots.
///
/// Design §6 splits the layout into *structure* and *content*, governed
/// differently. Structure — how many slots there are and what order they sit in
/// — is frozen for the session and changes only through a controlled rebuild,
/// because changing the slot count moves `selectedIndex` under whatever is on
/// screen and corrupts the `lastTabOpenedID` write. Content is live.
///
/// A playlist renamed or deleted on another device arrives as
/// `Constants.Notifications.playlistChanged`, posted by
/// `ServerSyncManager.playlistChanged()` on sync and by `PlaylistManager` on
/// local edits. Everything below updates titles, icons, and at most the *root*
/// of one navigation stack. **The slot count never changes here.**
extension MainTabBarController {

    @objc func playlistsDidChange() {
        // Every poster goes through `NotificationCenter.postOnMainThread`, so
        // this should already be on the main queue. The hop is here because the
        // cost of being wrong is mutating the view hierarchy off-thread, and
        // the cost of being right is one already-satisfied branch.
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [weak self] in
                self?.playlistsDidChange()
            }
            return
        }

        reconcilePlaylistSlots()
    }

    /// Re-resolves every `.playlist` slot in the bar against the database.
    ///
    /// Internal rather than private so the tests can drive it without posting a
    /// notification and waiting on the run loop.
    func reconcilePlaylistSlots() {
        let controllers = viewControllers ?? []

        for (index, destination) in renderedDestinations.enumerated() {
            guard case .playlist = destination,
                  let navController = controllers[safe: index] as? UINavigationController,
                  // Carried through rather than re-read: a navigation
                  // controller's item resolves through its root view
                  // controller, so replacing the root loses it.
                  let item = navController.tabBarItem else {
                continue
            }

            if destination.playlist != nil {
                restore(navController, to: destination, item: item)
            } else {
                markUnavailable(navController, for: destination, item: item)
            }
        }

        refreshOverflowRows()
    }

    // MARK: - The two cases

    /// The playlist still exists. Retitle in place, and put the real screen
    /// back if a previous pass had replaced it with the placeholder — a
    /// playlist can come back, either by an undo locally or by a sync that
    /// resurrects it.
    private func restore(_ navController: UINavigationController,
                         to destination: TabDestination,
                         item: UITabBarItem) {
        if navController.viewControllers.first is MissingPlaylistViewController {
            replaceRoot(of: navController, with: destination.makeRootViewController(), carrying: item)
        }

        apply(title: destination.title(), image: destination.icon(), to: item)
    }

    /// The playlist is gone. The slot is **kept** (design §6): dropping it would
    /// change the slot count, which is exactly what this path is not allowed to
    /// do. So the item is retitled and the stack's root becomes a placeholder
    /// that explains the situation and offers a way into tab settings.
    private func markUnavailable(_ navController: UINavigationController,
                                 for destination: TabDestination,
                                 item: UITabBarItem) {
        if !(navController.viewControllers.first is MissingPlaylistViewController) {
            let placeholder = MissingPlaylistViewController()
            placeholder.tabDestinationID = destination.id

            replaceRoot(of: navController, with: placeholder, carrying: item)

            FileLog.shared.addMessage("MainTabBarController: playlist slot \(destination.id) lost its playlist, slot kept and retitled")
        }

        apply(title: MissingPlaylistViewController.tabTitle,
              image: UIImage(systemName: "exclamationmark.triangle"),
              to: item)
    }

    // MARK: - Mechanics

    /// Swaps the root of a stack while leaving anything pushed above it alone.
    ///
    /// Deliberately not `setViewControllers([root])`: screens pushed from the
    /// old root belong to the user's current task. Replacing only index 0 means
    /// they finish what they were doing and meet the new root when they pop
    /// back, instead of being thrown out of it mid-gesture.
    private func replaceRoot(of navController: UINavigationController,
                             with root: UIViewController,
                             carrying item: UITabBarItem) {
        root.tabBarItem = item

        var stack = navController.viewControllers
        guard !stack.isEmpty else {
            navController.setViewControllers([root], animated: false)
            return
        }

        stack[0] = root
        navController.setViewControllers(stack, animated: false)
    }

    private func apply(title: String, image: UIImage?, to item: UITabBarItem) {
        if item.title != title {
            item.title = title
        }

        item.image = image
    }

    /// Overflow renders each row's title by asking the destination at draw
    /// time, so a reload is the whole update. A *truncated* playlist slot lives
    /// there rather than in the bar, and it gets renamed just the same.
    private func refreshOverflowRows() {
        guard let navController = viewControllers?.last as? UINavigationController,
              navController.tabDestinationID == TabOverflow.id,
              let overflow = navController.viewControllers.first as? OverflowViewController else {
            return
        }

        overflow.refreshRows()
    }
}
