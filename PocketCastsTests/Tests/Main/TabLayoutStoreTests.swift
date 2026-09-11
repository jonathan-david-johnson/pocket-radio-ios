import XCTest
@testable import podcasts

/// M12 — persistence of the layout, and the index-to-identity migration of
/// `lastTabOpened`.
final class TabLayoutStoreTests: XCTestCase {

    private let suiteName = "TabLayoutStoreTests"
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = UserDefaults(suiteName: suiteName)
        defaults.removePersistentDomain(forName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        super.tearDown()
    }

    // MARK: - Store

    func testReturnsDefaultLayoutWhenNothingIsStored() {
        let store = TabLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load(), TabLayout.default)
    }

    func testReturnsDefaultLayoutWhenStoredJSONIsCorrupt() {
        defaults.set(Data("{ this is not json".utf8), forKey: Constants.UserDefaults.tabLayout)
        let store = TabLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load(), TabLayout.default)
    }

    func testReturnsDefaultLayoutWhenStoredValueIsNotData() {
        defaults.set("not data", forKey: Constants.UserDefaults.tabLayout)
        let store = TabLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load(), TabLayout.default)
    }

    func testReturnsDefaultLayoutWhenStoredLayoutHasNoUsableSlots() {
        let store = TabLayoutStore(defaults: defaults)
        store.save(TabLayout(slots: []))

        XCTAssertEqual(store.load(), TabLayout.default)
    }

    func testSavedLayoutIsReadBack() {
        let store = TabLayoutStore(defaults: defaults)
        let layout = TabLayout(slots: [TabSlot(.streams), TabSlot(.playlist(uuid: "uuid-1"))],
                               updatedAt: Date(timeIntervalSince1970: 1_700_000_000))

        store.save(layout)

        XCTAssertEqual(store.load(), layout)
    }

    func testUnrecognisedSlotsAreDroppedOnLoad() throws {
        let layout = TabLayout(slots: [TabSlot(.podcasts), TabSlot(destinationID: "from_the_future")],
                               updatedAt: Date(timeIntervalSince1970: 1_700_000_000))
        defaults.set(try JSONEncoder().encode(layout), forKey: Constants.UserDefaults.tabLayout)

        let store = TabLayoutStore(defaults: defaults)

        XCTAssertEqual(store.load().slots.map(\.destinationID), ["podcasts"])
    }

    // MARK: - M12 migration

    func testMigrationMapsOldIndexThroughTheOldTabOrder() {
        let expected: [Int: String] = [0: "podcasts", 1: "playlists", 2: "discover", 3: "streams", 4: "profile"]

        for (index, id) in expected {
            defaults.removePersistentDomain(forName: suiteName)
            defaults.set(index, forKey: Constants.UserDefaults.lastTabOpened)

            TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)

            XCTAssertEqual(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID), id)
            XCTAssertTrue(defaults.bool(forKey: Constants.UserDefaults.lastTabOpenedMigratedM12))
        }
    }

    func testMigrationIsIdempotent() {
        defaults.set(3, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID), "streams")

        // Something changes the selection after the migration has run once...
        defaults.set(TabDestination.profile.id, forKey: Constants.UserDefaults.lastTabOpenedID)

        // ...and a second run must not stomp on it.
        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID), "profile")
    }

    func testMigrationRunningTwiceInARowProducesOneResult() {
        defaults.set(2, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)
        let first = defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID)

        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)
        let second = defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID)

        XCTAssertEqual(first, "discover")
        XCTAssertEqual(second, first)
    }

    /// A fresh install has never written `lastTabOpened`. The migration must not
    /// invent a selection, because the absence of a stored selection is what
    /// drives the "podcasts or discover" first-launch choice in `viewDidAppear`.
    func testMigrationWritesNothingWhenThereIsNoStoredSelection() {
        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)

        XCTAssertNil(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID))
        XCTAssertTrue(defaults.bool(forKey: Constants.UserDefaults.lastTabOpenedMigratedM12),
                      "the flag must still be set so the migration never runs again")
    }

    func testMigrationClampsAnOutOfRangeStoredIndex() {
        defaults.set(99, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID), "profile")
    }

    func testMigrationLeavesTheOldKeyInPlace() {
        defaults.set(1, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: Constants.UserDefaults.lastTabOpened), 1)
    }

    // MARK: - M5 migration (unchanged semantics, now testable)

    func testM5MigrationRemapsOldUpNextIndexOntoPlaylists() {
        defaults.set(3, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM5IfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.integer(forKey: Constants.UserDefaults.lastTabOpened), 1)
        XCTAssertTrue(defaults.bool(forKey: Constants.UserDefaults.lastTabOpenedMigratedM5))
    }

    func testM5MigrationThenM12MigrationLandsOnPlaylists() {
        defaults.set(3, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM5IfNeeded(defaults: defaults)
        TabSelectionMigration.migrateM12IfNeeded(defaults: defaults)

        XCTAssertEqual(defaults.string(forKey: Constants.UserDefaults.lastTabOpenedID), TabDestination.playlists.id)
    }

    func testM5MigrationIsIdempotent() {
        defaults.set(5, forKey: Constants.UserDefaults.lastTabOpened)

        TabSelectionMigration.migrateM5IfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: Constants.UserDefaults.lastTabOpened), 4)

        TabSelectionMigration.migrateM5IfNeeded(defaults: defaults)
        XCTAssertEqual(defaults.integer(forKey: Constants.UserDefaults.lastTabOpened), 4)
    }
}
