import PocketCastsUtils
import UIKit

/// Why a layout is being applied.
///
/// There are exactly two legal reasons to change the bar mid-session (design
/// doc §6). The enum exists so a third caller has to declare itself rather than
/// quietly reusing one of the two.
enum TabLayoutChangeSource: String {
    /// The user saved the tab bar settings screen.
    case settings

    /// The safe sync-pull path — M12.3. Only when every stack is at root and
    /// nothing is presented; otherwise the layout is persisted and left to
    /// render at next launch.
    case sync
}

/// The one way to change the tab bar layout at runtime.
///
/// Callers hand over a layout and a reason; everything else — the write
/// through `TabLayoutStore`, the `updatedAt` stamp, the analytics event, and the
/// controlled rebuild — happens here in that order. No caller needs to know
/// that a rebuild exists, and nothing else should call
/// `MainTabBarController.rebuildTabs(from:animated:)` directly.
enum TabLayoutApplier {

    /// Persists `layout` and applies it to the live tab bar.
    ///
    /// Order is deliberate and is the whole point of the function:
    ///
    /// 1. Stamp `updatedAt`, so a later sync comparison has something to order
    ///    by.
    /// 2. Write `TabLayoutStore` **first**. The local store is the render source
    ///    of truth, so if anything after this fails the layout still comes back
    ///    at next launch.
    /// 3. Emit `tab_bar_layout_changed` with the ordered slot ids.
    /// 4. Rebuild the bar.
    ///
    /// The rebuild is deferred by one main-queue turn. The usual caller is a
    /// view controller living inside a navigation stack that the rebuild is
    /// about to discard — the settings screen itself — and letting its call
    /// stack unwind first means it is not deallocated from under its own action
    /// handler.
    static func apply(_ layout: TabLayout,
                      source: TabLayoutChangeSource,
                      animated: Bool = true) {
        var layout = layout
        layout.updatedAt = Date()

        persist(layout, source: source)

        // UserDefaults is written above, inside `persist`, before the upsert
        // fires — the local store must already have the layout in case the
        // network write never completes.
        if source == .settings {
            Task { await TabLayoutSyncService.shared.push(layout) }
        }

        DispatchQueue.main.async {
            guard let controller = SceneHelper.rootViewController(includeTopMost: false) as? MainTabBarController else {
                // Saved, just not rendered: the store is already written, so the
                // layout takes effect the next time the bar is built.
                FileLog.shared.addMessage("TabLayoutApplier: no live tab bar controller, \(source.rawValue) layout will render at next launch")
                return
            }

            controller.rebuildTabs(from: layout, animated: animated)
        }
    }

    /// Applies a layout pulled from sync, **or** persists it for next launch.
    ///
    /// Three things separate this from `apply(_:source:animated:)`:
    ///
    /// 1. `updatedAt` is **not** re-stamped. The remote stamp is the whole
    ///    basis of last-write-wins; overwriting it with `now` would make this
    ///    device look like the newer writer on its next push and bounce the
    ///    layout back at whichever device actually changed it.
    /// 2. The store is written whether or not the bar rebuilds. Local storage
    ///    is the render source of truth, so a deferred layout still arrives —
    ///    just at next launch instead of now.
    /// 3. The rebuild is gated on `MainTabBarController.isSafeToRebuild`, and
    ///    happens synchronously rather than a main-queue turn later. There is no
    ///    settings screen call stack to let unwind here, and deferring would
    ///    mean re-checking safety against a bar that may have changed in the
    ///    meantime.
    ///
    /// Whether the remote layout is actually newer than the local one is the
    /// caller's decision — `TabLayoutSyncService` owns that comparison, so
    /// last-write-wins has exactly one implementation. This function trusts it.
    ///
    /// - Returns: whether the live bar was rebuilt. `false` means persisted and
    ///   deferred, which is a normal outcome, not a failure.
    @MainActor
    @discardableResult
    static func applyFromSync(_ layout: TabLayout) -> Bool {
        applyFromSync(layout, to: SceneHelper.rootViewController(includeTopMost: false) as? MainTabBarController)
    }

    /// The seam the tests drive. Production callers use the one-argument form,
    /// which resolves the live controller through `SceneHelper` — something a
    /// unit test has no scene to provide.
    @MainActor
    @discardableResult
    static func applyFromSync(_ layout: TabLayout, to controller: MainTabBarController?) -> Bool {
        persist(layout, source: .sync)

        guard let controller else {
            FileLog.shared.addMessage("TabLayoutApplier: no live tab bar controller, synced layout will render at next launch")
            return false
        }

        guard controller.isSafeToRebuild else {
            // No prompt, by design. The user did not ask for this and is in the
            // middle of something; the layout is already saved.
            FileLog.shared.addMessage("TabLayoutApplier: synced layout deferred, the tab bar is not at rest")
            return false
        }

        controller.rebuildTabs(from: layout, animated: false)

        return true
    }

    /// Writes the layout through to local storage and records the change.
    ///
    /// The store write comes first everywhere: it is the render source of
    /// truth, so if anything after it fails the layout still comes back at next
    /// launch.
    private static func persist(_ layout: TabLayout, source: TabLayoutChangeSource) {
        TabLayoutStore.shared.save(layout)

        let slotIDs = layout.slots.map(\.destinationID)
        Analytics.track(.tabBarLayoutChanged, properties: ["source": source.rawValue,
                                                           "slots": slotIDs.joined(separator: ","),
                                                           "slot_count": slotIDs.count])
    }
}
