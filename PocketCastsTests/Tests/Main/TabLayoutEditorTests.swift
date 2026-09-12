import XCTest
@testable import podcasts

/// M12.2 — the editing rules behind the tab bar settings screen.
///
/// The screen is one ordered list with a fixed More row in it, so promoting,
/// demoting and reordering are all `move(fromRows:toRow:)`. Row indices below
/// are indices into `editor.rows`, More included.
final class TabLayoutEditorTests: XCTestCase {
    private let capacity = 5

    private func editor(_ destinations: [TabDestination]) -> TabLayoutEditor {
        TabLayoutEditor(layout: TabLayout(slots: destinations.map(TabSlot.init)), capacity: capacity)
    }

    private func ids(_ destinations: [TabDestination]) -> [String] {
        destinations.map(\.id)
    }

    // MARK: - The two rules the milestone names

    func testRefusesASixthTabInTheBar() {
        let editor = self.editor([.podcasts, .playlists, .discover, .streams, .playlist(uuid: "abc")])

        // More is shown, so it owns a slot and the bar holds four.
        XCTAssertTrue(editor.needsMoreRow)
        XCTAssertEqual(editor.barCapacity, 4)
        XCTAssertEqual(editor.bar.count, 4)

        // Dragging a fifth item above More evicts the last one rather than
        // growing the bar past what the device can render.
        let moreRow = editor.rows.firstIndex(of: .more)
        XCTAssertEqual(moreRow, 4)
        editor.move(fromRows: IndexSet(integer: 5), toRow: 0)

        XCTAssertEqual(editor.bar.count, 4, "the bar can never exceed its capacity")
        XCTAssertEqual(ids(editor.bar), ["playlist:abc", "podcasts", "playlists", "discover"])
        XCTAssertEqual(ids(editor.belowMore), ["streams", "profile"])
    }

    func testRefusesToEmptyTheBar() {
        let editor = self.editor([.streams])
        XCTAssertEqual(ids(editor.bar), ["streams"])

        // rows == [streams, .more, podcasts, playlists, discover, profile]
        editor.move(fromRows: IndexSet(integer: 0), toRow: 3)

        XCTAssertEqual(ids(editor.bar), ["streams"], "demoting the only bar item is refused")
    }

    // MARK: - The single-list interaction

    func testOpensOnWhatTheBarIsCurrentlyShowing() {
        let editor = self.editor([.playlist(uuid: "new-releases"), .streams])

        XCTAssertEqual(ids(editor.bar), ["playlist:new-releases", "streams"])
        XCTAssertEqual(ids(editor.belowMore), ["podcasts", "playlists", "discover", "profile"])
        XCTAssertEqual(editor.rows.count, 7, "two bar rows, the More row, four rows inside More")
    }

    func testDraggingBelowMoreDemotesACoreDestination() {
        let editor = self.editor(TabDestination.core)
        XCTAssertFalse(editor.needsMoreRow, "five core destinations fit exactly, so there is no More")

        // No More row yet, so the only way to demote is to drop past the end.
        editor.move(fromRows: IndexSet(integer: 0), toRow: 5)
        XCTAssertEqual(ids(editor.bar), ["playlists", "discover", "streams", "profile", "podcasts"],
                       "a drop past the end with no More row is still a reorder")

        // With a playlist added there is a More row to drag across.
        editor.add(.playlist(uuid: "abc"))
        XCTAssertTrue(editor.needsMoreRow)
        let moreRow = editor.rows.firstIndex(of: .more)
        XCTAssertNotNil(moreRow)
        editor.move(fromRows: IndexSet(integer: 0), toRow: moreRow! + 1)

        XCTAssertFalse(editor.bar.contains(.playlists))
        XCTAssertTrue(editor.belowMore.contains(.playlists))
    }

    func testDraggingAboveMoreAbsorbsTheLastMoreItemAndRetiresTheMoreRow() {
        let editor = self.editor([.podcasts, .playlists, .discover, .streams])
        XCTAssertEqual(ids(editor.belowMore), ["profile"])

        // rows == [podcasts, playlists, discover, streams, .more, profile]
        editor.move(fromRows: IndexSet(integer: 5), toRow: 0)

        XCTAssertEqual(ids(editor.bar), ["profile", "podcasts", "playlists", "discover", "streams"])
        XCTAssertFalse(editor.needsMoreRow, "nothing is left inside More, so the row goes away")
        XCTAssertEqual(editor.barCapacity, 5, "and the bar gets its fifth slot back")
    }

    func testAddedPlaylistLandsInsideMoreRatherThanTheBar() {
        let editor = self.editor(TabDestination.core)

        XCTAssertTrue(editor.add(.playlist(uuid: "abc")))

        XCTAssertTrue(editor.needsMoreRow)
        XCTAssertEqual(editor.bar.count, 4, "More claimed a slot, so a core destination moved into it")
        XCTAssertEqual(ids(editor.belowMore), ["playlist:abc", "profile"])
    }

    func testUpNextCanBeAddedAndPromoted() {
        let editor = self.editor(TabDestination.core)

        XCTAssertTrue(editor.add(.upNext), "the design lets the user promote Up Next; §9 depends on it")
        XCTAssertTrue(editor.belowMore.contains(.upNext))

        let row = editor.rows.firstIndex(of: .destination(.upNext))
        XCTAssertNotNil(row)
        editor.move(fromRows: IndexSet(integer: row!), toRow: 0)

        XCTAssertEqual(editor.bar.first, .upNext)
    }

    // MARK: - Refusals and invariants

    func testCoreDestinationsCannotBeDeleted() {
        let editor = self.editor(TabDestination.core)

        editor.delete(atRows: IndexSet(integer: 0))

        XCTAssertEqual(ids(editor.bar), ids(TabDestination.core))
    }

    func testDeletingAPlaylistRemovesItFromTheListEntirely() {
        let editor = self.editor([.podcasts, .streams, .playlist(uuid: "abc")])
        let row = editor.rows.firstIndex(of: .destination(.playlist(uuid: "abc")))
        XCTAssertNotNil(row)

        editor.delete(atRows: IndexSet(integer: row!))

        XCTAssertFalse(editor.bar.contains(.playlist(uuid: "abc")))
        XCTAssertFalse(editor.belowMore.contains(.playlist(uuid: "abc")))
    }

    func testRefusesASecondSlotForTheSameDestination() {
        let editor = self.editor([.podcasts, .streams])

        XCTAssertTrue(editor.add(.playlist(uuid: "abc")))
        XCTAssertFalse(editor.add(.playlist(uuid: "abc")),
                       "the same playlist twice would render two identical tabs")
        XCTAssertFalse(editor.add(.podcasts), "core destinations are always already in the list")
    }

    func testDuplicateSlotsInAStoredLayoutAreDroppedOnLoad() {
        let editor = self.editor([.podcasts, .streams, .podcasts])

        XCTAssertEqual(ids(editor.bar), ["podcasts", "streams"])
    }

    // MARK: - The screen and the bar agree

    func testTheListMatchesWhatTheBarAndMoreTabWillActuallyRender() {
        let editor = self.editor([.podcasts, .playlists, .discover, .streams, .playlist(uuid: "abc")])

        // Promote the playlist, which evicts a core destination into More.
        let row = editor.rows.firstIndex(of: .destination(.playlist(uuid: "abc")))
        XCTAssertNotNil(row)
        editor.move(fromRows: IndexSet(integer: row!), toRow: 0)

        let plan = editor.currentLayout.renderPlan(capacity: capacity)

        XCTAssertEqual(ids(plan.visibleDestinations), ids(editor.bar),
                       "the rows above More are the tab bar, in order")
        XCTAssertEqual(ids(plan.overflowDestinations), ids(editor.belowMore),
                       "the rows below More are the More tab, in order")
        XCTAssertEqual(plan.visible.count + 1, capacity, "bar items plus More fill the bar exactly")
    }

    // MARK: - The two positions beside More

    /// Every index below is one this screen actually produced on an iOS 26.4
    /// simulator, read back out of a temporary log in `move(fromRows:toRow:)`.
    /// They are recorded because the interesting bug here was not arithmetic:
    /// the More row was `moveDisabled`, which makes it an illegal drop target
    /// as well as an immovable row, and UIKit silently refused any reorder
    /// whose final index was the one More occupied. `onMove` was never called
    /// for the two drops beside it, so the list just animated back. These
    /// tests pin the model against the real indices; only a device or
    /// simulator can prove the drops arrive at all.
    private func usersLayout() -> TabLayoutEditor {
        let editor = self.editor([.podcasts,
                                  .playlist(uuid: "a"),
                                  .playlist(uuid: "b"),
                                  .streams,
                                  .playlist(uuid: "c")])

        XCTAssertEqual(editor.rows.firstIndex(of: .more), 4)
        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a", "playlist:b", "streams"])
        XCTAssertEqual(ids(editor.belowMore), ["playlist:c", "playlists", "discover", "profile"])

        return editor
    }

    func testPromotingIntoTheLastBarSlotEvictsWhatWasThereRatherThanBeingRefused() {
        let editor = usersLayout()

        // Dropped just above More, so the destination is More's own index.
        editor.move(fromRows: IndexSet(integer: 5), toRow: 4)

        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a", "playlist:b", "playlist:c"],
                       "the dropped row takes the last slot")
        XCTAssertEqual(ids(editor.belowMore), ["playlists", "discover", "streams", "profile"],
                       "and the row it displaced falls into More")
    }

    func testDemotingToTheTopOfMoreIsHonoured() {
        let editor = usersLayout()
        editor.move(fromRows: IndexSet(integer: 5), toRow: 4)

        // rows == [podcasts, a, b, c, .more, playlists, discover, streams, profile]
        editor.move(fromRows: IndexSet(integer: 3), toRow: 5)

        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a", "playlist:b"])
        XCTAssertEqual(editor.belowMore.first, .playlist(uuid: "c"),
                       "a demotion to the first position inside More is still a demotion")
    }

    // MARK: - Dragging the More row moves the boundary

    func testDraggingMoreUpDemotesEverythingBelowItsNewPosition() {
        let editor = usersLayout()

        // More is at row 4; dropping it at row 2 leaves two rows above it.
        editor.move(fromRows: IndexSet(integer: 4), toRow: 2)

        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a"])
        XCTAssertEqual(ids(editor.belowMore),
                       ["playlist:b", "playlist:c", "playlists", "discover", "streams", "profile"])
    }

    func testDraggingMoreDownPromotesWhatItPassed() {
        let editor = self.editor([.podcasts])
        XCTAssertEqual(editor.rows.firstIndex(of: .more), 1)

        // Downwards, so the pre-move destination counts the More row itself.
        editor.move(fromRows: IndexSet(integer: 1), toRow: 3)

        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlists"],
                       "the row the line was dragged past is now a tab")
    }

    func testDraggingMoreToTheBottomPromotesOnlyWhatTheBarCanRender() {
        let editor = usersLayout()
        let rowCount = editor.rows.count

        editor.move(fromRows: IndexSet(integer: 4), toRow: rowCount)

        // Not a refusal — a clamp. Promoting everything would empty More, but
        // three core destinations cannot fit, so More survives, keeps its slot,
        // and the bar settles back at its capacity of four.
        XCTAssertEqual(editor.bar.count, editor.barCapacity)
        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a", "playlist:b", "streams"])
        XCTAssertTrue(editor.needsMoreRow)
    }

    func testDraggingMoreToTheTopIsRefusedRatherThanEmptyingTheBar() {
        let editor = usersLayout()

        editor.move(fromRows: IndexSet(integer: 4), toRow: 0)

        XCTAssertEqual(ids(editor.bar), ["podcasts", "playlist:a", "playlist:b", "streams"],
                       "the bar may never go empty, so the line does not move")
    }
}
