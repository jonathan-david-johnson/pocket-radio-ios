import UIKit

/// One entry in the user's layout: a reference to a `TabDestination`.
struct TabSlot: Codable, Equatable, Hashable {
    /// Stable across reorders and app versions.
    let destinationID: String

    init(destinationID: String) {
        self.destinationID = destinationID
    }

    init(_ destination: TabDestination) {
        destinationID = destination.id
    }

    /// `nil` when this build does not recognise the id.
    var destination: TabDestination? {
        TabDestination(id: destinationID)
    }
}

/// The user's ordered list of slots — the single persisted, synced artifact.
///
/// Overflow is never stored here; it is derived at render time by
/// `renderPlan(capacity:)`.
struct TabLayout: Codable, Equatable {
    var slots: [TabSlot]
    var updatedAt: Date

    init(slots: [TabSlot], updatedAt: Date = Date()) {
        self.slots = slots
        self.updatedAt = updatedAt
    }

    /// Today's five tabs, in today's order. A user who never opens the setting
    /// sees exactly this.
    static let `default` = TabLayout(slots: TabDestination.core.map(TabSlot.init),
                                     updatedAt: Date(timeIntervalSince1970: 0))

    /// How many tab items the current device can render.
    ///
    /// `5` everywhere: this fork forces the iPhone-style bottom bar on iPad, so
    /// screen size changes item *width*, never item *count* (design §7). This is
    /// the single source of truth — do not inline the literal elsewhere.
    static func capacity(for traitCollection: UITraitCollection) -> Int {
        5
    }

    /// Everything the tab bar needs in order to render, derived from the layout.
    ///
    /// - Parameter isAvailable: whether a resolved destination can actually be
    ///   built. Defaults to "everything can", which keeps this a pure function;
    ///   `MainTabBarController` passes `TabDestination.isAvailable` so that a
    ///   `.playlist` slot whose UUID no longer resolves is dropped at build time
    ///   rather than rendered as a dead tab.
    func renderPlan(capacity: Int, isAvailable: (TabDestination) -> Bool = { _ in true }) -> TabRenderPlan {
        let capacity = max(1, capacity)

        // Slots this build cannot resolve (written by a newer version), and
        // slots whose payload has gone missing, are not renderable — so they
        // take no part in the plan.
        let resolvable = slots.filter { slot in
            guard let destination = slot.destination else { return false }
            return isAvailable(destination)
        }

        let promoted = Set(resolvable.compactMap(\.destination))
        let complement = TabDestination.core.filter { !promoted.contains($0) }

        // Try the no-overflow render first. If it leaves nothing behind, that is
        // the answer; otherwise Overflow claims the last slot and we re-split.
        let needsOverflow = !(complement.isEmpty && resolvable.count <= capacity)
        let visibleCount = min(resolvable.count, needsOverflow ? capacity - 1 : capacity)

        return TabRenderPlan(visible: Array(resolvable.prefix(visibleCount)),
                             truncated: Array(resolvable.dropFirst(visibleCount)),
                             complement: complement)
    }
}

/// The result of applying the render rules to a layout at a given capacity.
struct TabRenderPlan: Equatable {
    /// Slots that get a tab item of their own, in bar order.
    let visible: [TabSlot]

    /// Slots pushed past capacity. Not an error — they fall into Overflow.
    let truncated: [TabSlot]

    /// Unpromoted core destinations. The main input to Overflow.
    let complement: [TabDestination]

    /// Overflow exists if and only if it would be non-empty.
    var needsOverflow: Bool {
        !(complement.isEmpty && truncated.isEmpty)
    }

    /// `visible`, resolved. Same order, same count — `renderPlan(capacity:)`
    /// drops unresolvable slots before splitting.
    var visibleDestinations: [TabDestination] {
        visible.compactMap(\.destination)
    }

    /// The Overflow rows, in list order, or empty when no Overflow is needed.
    ///
    /// Truncated slots come first: Overflow reads as the continuation of the
    /// bar, and a slot the user explicitly promoted ranks above one they never
    /// chose. Then the complement, in core order.
    ///
    /// The two can never overlap — the complement is by definition the core
    /// destinations that have no slot at all.
    var overflowDestinations: [TabDestination] {
        guard needsOverflow else { return [] }

        return truncated.compactMap(\.destination) + complement
    }
}
