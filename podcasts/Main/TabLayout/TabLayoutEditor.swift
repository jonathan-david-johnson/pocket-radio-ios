import Foundation

/// One row of the tab bar settings list.
enum TabSettingsRow: Identifiable, Equatable {
    /// A destination the user can drag, above or below `.more`.
    case destination(TabDestination)

    /// The derived "More" tab, shown at the position it actually occupies in
    /// the bar. Everything below it is inside that tab.
    case more

    var id: String {
        switch self {
        case .destination(let destination):
            return destination.id
        case .more:
            return "__more__"
        }
    }
}

/// The editing model behind the tab bar settings screen.
///
/// The screen is one ordered list with a fixed **More** row in it. Items above
/// that row are the tab bar, in bar order; items below it are the contents of
/// the More tab. Dragging across the row is the same gesture as reordering,
/// which is the whole point — promote, demote and reorder stop being three
/// different interactions.
///
/// `bar` is the only ordered, user-controlled array here. Everything below the
/// More row is **derived**, in the order the real More tab will use, because
/// `TabLayout` cannot store an order for it: an unpromoted core destination is
/// represented by its *absence* from the layout rather than by a slot. That is
/// why rows below More are not reorderable, and why `belowMore` mirrors
/// `TabRenderPlan.overflowDestinations` — truncated slots first, then the
/// unpromoted core.
///
/// See `docs/ios/milestones/milestone_12.2.md` §2 and
/// `docs/ios/architecture/configurable-tab-bar.md` §8.
final class TabLayoutEditor: ObservableObject {
    /// How many tab items the bar can render, counting More itself.
    let capacity: Int

    /// The tab bar, in bar order. Never empty.
    @Published private(set) var bar: [TabDestination] = []

    /// Every non-core destination the user has added, in the order they were
    /// added.
    ///
    /// A playlist or Up Next exists in the layout only by being here. Core
    /// destinations are always in the list somewhere and can never be deleted,
    /// only moved below More — which is what makes "the layout can never be
    /// emptied" structural rather than a refusal the user has to discover.
    @Published private(set) var extras: [TabDestination] = []

    init(layout: TabLayout, capacity: Int) {
        // At least one real tab plus More.
        self.capacity = max(2, capacity)

        // Reuse the render plan rather than re-deriving the split: whatever the
        // bar is showing right now is exactly what this screen should open on.
        //
        // `isAvailable` is deliberately *not* passed. It drops a `.playlist`
        // slot whose playlist has been deleted, and dropping it here would mean
        // opening this screen and saving silently discards the slot — design §6
        // keeps it instead, so the bar never changes behind the user's back. The
        // row renders as a deleted playlist and they can remove it themselves.
        let plan = layout.renderPlan(capacity: self.capacity)
        let everything = plan.visibleDestinations + plan.overflowDestinations

        bar = Self.deduplicated(plan.visibleDestinations)
        extras = Self.deduplicated(everything.filter { !$0.isCore })

        normalize()
    }

    // MARK: - Derived state

    /// The contents of the More tab, in the order it will actually list them.
    var belowMore: [TabDestination] {
        let inBar = Set(bar)

        return extras.filter { !inBar.contains($0) }
            + TabDestination.core.filter { !inBar.contains($0) }
    }

    /// Whether a More tab exists at all. It does if and only if it would have
    /// something in it, which is the same rule the bar itself applies.
    var needsMoreRow: Bool {
        !belowMore.isEmpty
    }

    /// How many of the user's own items fit in the bar. One less than
    /// `capacity` whenever More is shown, because More occupies a tab slot of
    /// its own — the constraint the old two-section screen hid.
    var barCapacity: Int {
        max(1, needsMoreRow ? capacity - 1 : capacity)
    }

    /// The flat list the screen renders.
    var rows: [TabSettingsRow] {
        bar.map(TabSettingsRow.destination)
            + (needsMoreRow ? [.more] : [])
            + belowMore.map(TabSettingsRow.destination)
    }

    /// Non-core destinations can be deleted outright. A core destination has
    /// nowhere to go, so it is only ever moved below More.
    func canDelete(_ row: TabSettingsRow) -> Bool {
        guard case .destination(let destination) = row else { return false }
        return !destination.isCore
    }

    /// The layout to hand to `TabLayoutApplier.apply(_:source:)`. `updatedAt`
    /// is stamped there, not here.
    ///
    /// Core destinations below More are written as absences, not slots; extras
    /// below More are written as slots past the visible cut, which is how
    /// `renderPlan` puts them in the More tab in the order shown here.
    var currentLayout: TabLayout {
        let inBar = Set(bar)
        let belowExtras = extras.filter { !inBar.contains($0) }

        return TabLayout(slots: (bar + belowExtras).map(TabSlot.init))
    }

    // MARK: - Editing

    /// Moves a row, which is also how the user promotes and demotes: the drop
    /// position relative to the More row decides which.
    ///
    /// Refuses a demotion that would empty the bar, and refuses to move the
    /// More row itself.
    func move(fromRows source: IndexSet, toRow destination: Int) {
        let currentRows = rows

        guard let sourceRow = source.first,
              sourceRow < currentRows.count,
              case .destination(let moved) = currentRows[sourceRow] else { return }

        let moreRow = currentRows.firstIndex(of: .more)
        let landsAboveMore = moreRow.map { destination <= $0 } ?? true

        // The bar may never go empty.
        if !landsAboveMore, bar.count <= 1, bar.contains(moved) { return }

        let previousBarIndex = bar.firstIndex(of: moved)
        var updated = bar
        updated.removeAll { $0 == moved }

        if landsAboveMore {
            // Above More, a row index and a bar index are the same number.
            // `destination` is in the pre-move index space, so a row that came
            // from higher up in the bar shifts the target down by one.
            var insertAt = destination
            if let previousBarIndex, previousBarIndex < insertAt {
                insertAt -= 1
            }
            updated.insert(moved, at: min(max(insertAt, 0), updated.count))
        }

        bar = updated

        if !landsAboveMore, !moved.isCore, !extras.contains(moved) {
            extras.append(moved)
        }

        // A drag into a full bar has to push something out. Never the row the
        // user just dropped, or the gesture would silently undo itself.
        normalize(protecting: landsAboveMore ? moved : nil)
    }

    /// Deletes non-core rows. Core rows are undeletable, and a delete that
    /// would empty the bar is refused.
    func delete(atRows offsets: IndexSet) {
        let currentRows = rows

        let targets = offsets.compactMap { index -> TabDestination? in
            guard index < currentRows.count,
                  case .destination(let destination) = currentRows[index],
                  !destination.isCore else { return nil }
            return destination
        }

        guard !targets.isEmpty else { return }

        let remaining = bar.filter { !targets.contains($0) }
        guard !remaining.isEmpty else { return }

        bar = remaining
        extras.removeAll { targets.contains($0) }

        normalize()
    }

    /// Adds a playlist or Up Next.
    ///
    /// It lands in the More tab rather than the bar. Dropping it straight into
    /// a full bar would have to evict something in the same motion, and the
    /// user has not said which — so the add is shown, and the promotion is left
    /// as a separate drag they can see the consequence of.
    @discardableResult
    func add(_ destination: TabDestination) -> Bool {
        guard !destination.isCore,
              !extras.contains(destination),
              !bar.contains(destination) else { return false }

        extras.append(destination)
        normalize()

        return true
    }

    // MARK: - Invariants

    /// Re-establishes everything the rest of the type promises: no duplicates,
    /// no core destination in `extras`, a non-empty bar, and a bar that fits.
    private func normalize(protecting protected: TabDestination? = nil) {
        bar = Self.deduplicated(bar)
        extras = Self.deduplicated(extras).filter { !$0.isCore }

        if bar.isEmpty {
            bar = [TabDestination.core.first ?? .podcasts]
        }

        // `barCapacity` shrinks the moment something lands below More, so this
        // can need more than one pass. It terminates because `bar` only shrinks.
        while bar.count > barCapacity, bar.count > 1 {
            bar.remove(at: demotionIndex(protecting: protected))
        }
    }

    /// Which bar row to evict when the bar is over capacity. The last one,
    /// unless that is the row the user just dropped there.
    private func demotionIndex(protecting protected: TabDestination?) -> Int {
        if let protected, bar.last == protected, bar.count > 1 {
            return bar.count - 2
        }

        return bar.count - 1
    }

    private static func deduplicated(_ destinations: [TabDestination]) -> [TabDestination] {
        var seen = Set<TabDestination>()
        return destinations.filter { seen.insert($0).inserted }
    }
}
