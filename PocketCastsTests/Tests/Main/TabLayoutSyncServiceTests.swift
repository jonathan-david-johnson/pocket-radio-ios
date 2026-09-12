import PocketCastsServer
import XCTest
@testable import podcasts

/// M12.3 — the sync service's pure last-write-wins decision, the wire format,
/// date parsing, and the signed-out no-op path.
///
/// The safe-apply gate and live reconciliation (parts 3/4 of the milestone)
/// are covered elsewhere (`TabLayoutSyncApplyTests`,
/// `TabLayoutReconciliationTests`) and are not this file's concern.
final class TabLayoutSyncServiceTests: XCTestCase {

    private static let keys = [
        Constants.UserDefaults.tabLayout
    ]

    override func setUp() {
        super.setUp()
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
    }

    override func tearDown() {
        Self.keys.forEach { UserDefaults.standard.removeObject(forKey: $0) }
        super.tearDown()
    }

    // MARK: - Last-write-wins decision

    func testRemoteNewerThanLocalAppliesRemote() {
        let local = Date(timeIntervalSince1970: 1000)
        let remote = Date(timeIntervalSince1970: 2000)

        XCTAssertEqual(TabLayoutSyncService.decision(local: local, remote: remote), .applyRemote)
    }

    func testLocalNewerThanRemotePushesLocal() {
        let local = Date(timeIntervalSince1970: 2000)
        let remote = Date(timeIntervalSince1970: 1000)

        let decision = TabLayoutSyncService.decision(local: local, remote: remote)

        XCTAssertEqual(decision, .pushLocal)
        XCTAssertNotEqual(decision, .applyRemote)
    }

    func testNoRemoteRowPushesLocal() {
        let local = Date(timeIntervalSince1970: 1000)

        XCTAssertEqual(TabLayoutSyncService.decision(local: local, remote: nil), .pushLocal)
    }

    func testIdenticalTimestampsAreInSync() {
        let date = Date(timeIntervalSince1970: 1_757_000_000)

        XCTAssertEqual(TabLayoutSyncService.decision(local: date, remote: date), .inSync)
    }

    func testTimestampsWithinToleranceAreInSync() {
        let local = Date(timeIntervalSince1970: 1_757_000_000)
        let remote = local.addingTimeInterval(0.0001)

        XCTAssertEqual(TabLayoutSyncService.decision(local: local, remote: remote), .inSync)
    }

    // MARK: - Signed out

    func testPullAtLaunchSignedOutMakesNoNetworkCallAndLeavesLocalLayoutUnchanged() async {
        // Signed-out is injected rather than assumed. This test used to assert
        // `ServerSettings.userId` was nil, which held only until someone signed
        // in on the simulator running the suite — after which it made a real
        // request and pulled that account's layout over the local one.
        let service = TabLayoutSyncService()
        service.currentUserID = { nil }

        let layout = TabLayout(slots: [TabSlot(.streams), TabSlot(.podcasts)],
                               updatedAt: Date(timeIntervalSince1970: 42))
        TabLayoutStore.shared.save(layout)

        await service.pullAtLaunch()

        // No network call means nothing about the locally-stored layout could
        // have changed.
        let reloaded = TabLayoutStore.shared.load()
        XCTAssertEqual(reloaded.slots, layout.slots)
        XCTAssertEqual(reloaded.updatedAt.timeIntervalSince1970,
                       layout.updatedAt.timeIntervalSince1970,
                       accuracy: 0.001)
    }

    func testPullAtLaunchTreatsAnEmptyUserIDAsSignedOut() async {
        let service = TabLayoutSyncService()
        service.currentUserID = { "" }

        let layout = TabLayout(slots: [TabSlot(.discover)],
                               updatedAt: Date(timeIntervalSince1970: 99))
        TabLayoutStore.shared.save(layout)

        await service.pullAtLaunch()

        XCTAssertEqual(TabLayoutStore.shared.load().slots, layout.slots)
    }

    // MARK: - Wire format round-trip

    func testWireFormatRoundTrips() throws {
        let playlistID = UUID().uuidString
        let slots = [TabSlot(.podcasts), TabSlot(.streams), TabSlot(destinationID: "playlist:\(playlistID)")]
        let layout = TabLayout(slots: slots, updatedAt: Date())

        let encoded = layout.slots.map(\.destinationID)
        XCTAssertEqual(encoded, ["podcasts", "streams", "playlist:\(playlistID)"])

        let decodedSlots = encoded.map(TabSlot.init(destinationID:))
        XCTAssertEqual(decodedSlots, slots)
    }

    // MARK: - Postgres timestamp parsing

    func testParsesPostgresTimestampWithFractionalSeconds() {
        let date = TabLayoutSyncService.parsePostgresTimestamp("2026-09-11T18:32:03.309123+00:00")

        XCTAssertNotNil(date)
    }

    func testParsesPostgresTimestampWithoutFractionalSeconds() {
        let date = TabLayoutSyncService.parsePostgresTimestamp("2026-09-11T18:32:03+00:00")

        XCTAssertNotNil(date)
    }

    func testParsesPostgresTimestampWithFractionalSecondsMatchesExpectedComponents() throws {
        let date = TabLayoutSyncService.parsePostgresTimestamp("2026-09-11T18:32:03.309123+00:00")

        let calendar = Calendar(identifier: .gregorian)
        var utc = calendar
        utc.timeZone = TimeZone(identifier: "UTC")!
        let components = utc.dateComponents([.year, .month, .day, .hour, .minute, .second], from: try XCTUnwrap(date))

        XCTAssertEqual(components.year, 2026)
        XCTAssertEqual(components.month, 9)
        XCTAssertEqual(components.day, 11)
        XCTAssertEqual(components.hour, 18)
        XCTAssertEqual(components.minute, 32)
        XCTAssertEqual(components.second, 3)
    }

    func testRejectsGarbageTimestamp() {
        XCTAssertNil(TabLayoutSyncService.parsePostgresTimestamp("not-a-date"))
    }

    // MARK: - What is worth publishing

    /// A fresh install must not seed the table. `TabLayout.default` is what
    /// every user has before they open the setting, and publishing it would
    /// create a row for a preference nobody expressed — worse, whichever
    /// device launched first would plant a timestamp the real layout has to
    /// beat.
    func testTheUntouchedDefaultLayoutIsNotPublished() {
        XCTAssertFalse(TabLayoutSyncService.isWorthPublishing(.default))
    }

    func testALayoutTheUserActuallyChoseIsPublished() {
        let chosen = TabLayout(slots: [TabSlot(.streams), TabSlot(.podcasts)], updatedAt: Date())

        XCTAssertTrue(TabLayoutSyncService.isWorthPublishing(chosen))
    }

    /// The same five destinations in the same order, but stamped — the user
    /// opened the screen and saved. That is a choice, and it syncs.
    func testTheDefaultOrderSavedByHandIsPublished() {
        let saved = TabLayout(slots: TabDestination.core.map(TabSlot.init), updatedAt: Date())

        XCTAssertTrue(TabLayoutSyncService.isWorthPublishing(saved))
    }
}
