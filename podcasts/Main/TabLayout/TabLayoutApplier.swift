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

        TabLayoutStore.shared.save(layout)

        let slotIDs = layout.slots.map(\.destinationID)
        Analytics.track(.tabBarLayoutChanged, properties: ["source": source.rawValue,
                                                           "slots": slotIDs.joined(separator: ","),
                                                           "slot_count": slotIDs.count])

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
}
