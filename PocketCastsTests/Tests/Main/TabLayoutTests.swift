import XCTest
@testable import podcasts

/// M12 — the tab layout model and the pure render rules.
///
/// These are pure-function tests: no view controllers, no UserDefaults. The
/// property that matters most is `testDefaultLayoutNeedsNoOverflow` — it is
/// what keeps the bar identical to the pre-M12 hard-coded one.
final class TabLayoutTests: XCTestCase {

    // MARK: - Destination identity
    //
    // These id strings are persisted in UserDefaults and synced to Supabase.
    // If this test ever needs "updating", something is wrong.

    func testDestinationIDsAreStable() {
        XCTAssertEqual(TabDestination.podcasts.id, "podcasts")
        XCTAssertEqual(TabDestination.playlists.id, "playlists")
        XCTAssertEqual(TabDestination.discover.id, "discover")
        XCTAssertEqual(TabDestination.streams.id, "streams")
        XCTAssertEqual(TabDestination.profile.id, "profile")
        XCTAssertEqual(TabDestination.upNext.id, "upNext")
        XCTAssertEqual(TabDestination.playlist(uuid: "abc-123").id, "playlist:abc-123")
    }

    func testDestinationRoundTripsThroughID() {
        let all: [TabDestination] = [.podcasts, .playlists, .discover, .streams, .profile, .upNext, .playlist(uuid: "abc-123")]

        for destination in all {
            XCTAssertEqual(TabDestination(id: destination.id), destination, "\(destination.id) did not round-trip")
        }
    }

    func testUnrecognisedIDDoesNotResolve() {
        XCTAssertNil(TabDestination(id: ""))
        XCTAssertNil(TabDestination(id: "nope"))
        XCTAssertNil(TabDestination(id: "playlist:"), "an empty playlist uuid is not a destination")
        XCTAssertNil(TabDestination(id: "Podcasts"), "ids are case sensitive")
    }

    func testCoreDestinations() {
        XCTAssertEqual(TabDestination.core, [.podcasts, .playlists, .discover, .streams, .profile])

        for destination in TabDestination.core {
            XCTAssertTrue(destination.isCore, "\(destination.id) should be core")
        }

        XCTAssertFalse(TabDestination.upNext.isCore)
        XCTAssertFalse(TabDestination.playlist(uuid: "abc-123").isCore)
    }

    // MARK: - Capacity

    func testCapacityIsFiveForEveryDevice() {
        XCTAssertEqual(TabLayout.capacity(for: UITraitCollection.current), 5)
        XCTAssertEqual(TabLayout.capacity(for: UITraitCollection()), 5)

        if #available(iOS 17.0, *) {
            let compact = UITraitCollection { traits in traits.horizontalSizeClass = .compact }
            let regularPad = UITraitCollection { traits in
                traits.horizontalSizeClass = .regular
                traits.userInterfaceIdiom = .pad
            }
            XCTAssertEqual(TabLayout.capacity(for: compact), 5)
            XCTAssertEqual(TabLayout.capacity(for: regularPad), 5)
        }
    }

    // MARK: - Default layout

    func testDefaultLayoutIsTodaysFiveDestinations() {
        XCTAssertEqual(TabLayout.default.slots.map(\.destinationID),
                       ["podcasts", "playlists", "discover", "streams", "profile"])
    }

    func testDefaultLayoutRendersExactlyTheFiveCurrentDestinations() {
        let plan = TabLayout.default.renderPlan(capacity: 5)

        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .playlists, .discover, .streams, .profile])
        XCTAssertTrue(plan.truncated.isEmpty)
        XCTAssertTrue(plan.complement.isEmpty)
    }

    /// The property that keeps the bar identical to the pre-M12 one.
    func testDefaultLayoutNeedsNoOverflow() {
        XCTAssertFalse(TabLayout.default.renderPlan(capacity: 5).needsOverflow)
    }

    // MARK: - needsOverflow truth table

    func testNeedsOverflowIsFalseWhenComplementAndTruncationAreBothEmpty() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .profile).renderPlan(capacity: 5)

        XCTAssertTrue(plan.complement.isEmpty)
        XCTAssertTrue(plan.truncated.isEmpty)
        XCTAssertFalse(plan.needsOverflow)
    }

    func testNeedsOverflowIsTrueWhenComplementIsEmptyButSlotsAreTruncated() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .profile, .upNext).renderPlan(capacity: 5)

        XCTAssertTrue(plan.complement.isEmpty)
        XCTAssertFalse(plan.truncated.isEmpty)
        XCTAssertTrue(plan.needsOverflow)
    }

    func testNeedsOverflowIsTrueWhenComplementIsNonEmptyWithNoTruncation() {
        let plan = layout(.podcasts, .playlists, .discover, .streams).renderPlan(capacity: 5)

        XCTAssertEqual(plan.complement, [.profile])
        XCTAssertTrue(plan.truncated.isEmpty)
        XCTAssertTrue(plan.needsOverflow)
    }

    func testNeedsOverflowIsTrueWhenComplementAndTruncationAreBothNonEmpty() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .upNext,
                          .playlist(uuid: "a"), .playlist(uuid: "b")).renderPlan(capacity: 5)

        XCTAssertEqual(plan.complement, [.profile])
        XCTAssertFalse(plan.truncated.isEmpty)
        XCTAssertTrue(plan.needsOverflow)
    }

    func testNeedsOverflowMatchesItsDefinition() {
        let layouts: [TabLayout] = [
            .default,
            layout(.podcasts),
            layout(.podcasts, .playlists, .discover, .streams, .profile, .upNext),
            layout(.podcasts, .playlists, .discover, .streams),
            layout(.playlist(uuid: "a"), .streams)
        ]

        for candidate in layouts {
            for capacity in 1...6 {
                let plan = candidate.renderPlan(capacity: capacity)
                XCTAssertEqual(plan.needsOverflow, !(plan.complement.isEmpty && plan.truncated.isEmpty))
            }
        }
    }

    // MARK: - Truncation

    func testSevenSlotsAtCapacityFiveGivesFourVisibleAndThreeTruncated() {
        let plan = layout(.podcasts, .playlists, .discover, .streams, .profile,
                          .upNext, .playlist(uuid: "a")).renderPlan(capacity: 5)

        XCTAssertEqual(plan.visible.count, 4)
        XCTAssertEqual(plan.truncated.count, 3)
        XCTAssertTrue(plan.needsOverflow)
        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .playlists, .discover, .streams])
        XCTAssertEqual(plan.truncated.map(\.destinationID), ["profile", "upNext", "playlist:a"])
    }

    func testUnrecognisedSlotsAreDroppedFromTheRenderPlan() {
        let candidate = TabLayout(slots: [TabSlot(.podcasts), TabSlot(destinationID: "from_the_future"), TabSlot(.streams)])
        let plan = candidate.renderPlan(capacity: 5)

        XCTAssertEqual(plan.visibleDestinations, [.podcasts, .streams])
        XCTAssertEqual(plan.visible.count, plan.visibleDestinations.count)
    }

    // MARK: - Codable

    func testLayoutRoundTripsThroughCodableIncludingAPlaylistSlot() throws {
        let original = TabLayout(slots: [TabSlot(.streams), TabSlot(.playlist(uuid: "uuid-1")), TabSlot(.upNext)],
                                 updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TabLayout.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.slots.map(\.destinationID), ["streams", "playlist:uuid-1", "upNext"])
    }

    func testDefaultLayoutRoundTripsThroughCodable() throws {
        let data = try JSONEncoder().encode(TabLayout.default)
        XCTAssertEqual(try JSONDecoder().decode(TabLayout.self, from: data), TabLayout.default)
    }

    // MARK: - Helpers

    private func layout(_ destinations: TabDestination...) -> TabLayout {
        TabLayout(slots: destinations.map(TabSlot.init))
    }
}
