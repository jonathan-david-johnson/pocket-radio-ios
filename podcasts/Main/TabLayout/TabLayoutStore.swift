import Foundation
import PocketCastsUtils

/// Reads and writes the `TabLayout` as JSON in `UserDefaults`.
///
/// The local store is the render source of truth so the bar builds offline with
/// no latency. Sync (M12.3) writes through this, never around it.
class TabLayoutStore {
    static let shared = TabLayoutStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// Returns `.default` when nothing is stored, when the stored JSON cannot be
    /// decoded, or when what is stored has no slot this build can render.
    func load() -> TabLayout {
        guard let data = defaults.data(forKey: Constants.UserDefaults.tabLayout) else {
            return .default
        }

        guard var layout = try? JSONDecoder().decode(TabLayout.self, from: data) else {
            FileLog.shared.addMessage("TabLayoutStore: stored layout could not be decoded, falling back to the default")
            return .default
        }

        // Drop anything this build does not recognise, so the rendered bar and
        // the stored layout never disagree about how many slots there are.
        layout.slots = layout.slots.filter { $0.destination != nil }

        guard !layout.slots.isEmpty else { return .default }

        return layout
    }

    func save(_ layout: TabLayout) {
        guard let data = try? JSONEncoder().encode(layout) else {
            FileLog.shared.addMessage("TabLayoutStore: layout could not be encoded, not saving")
            return
        }

        defaults.set(data, forKey: Constants.UserDefaults.tabLayout)
    }
}

/// The `lastTabOpened` migrations.
///
/// Both are one-shot and idempotent, gated on their own flag key, per the
/// UserDefaults migration rule in `AGENTS.md`. `migrateM5IfNeeded` must run
/// before `migrateM12IfNeeded` — M5 leaves the stored *index* correct for the
/// post-M5 order, which is the order M12 maps through.
enum TabSelectionMigration {

    /// The tab order as it stands after the M5 migration and before M12.
    /// `[podcasts, filter, discover, streams, profile]`.
    static let oldTabOrder: [TabDestination] = [.podcasts, .playlists, .discover, .streams, .profile]

    /// M5: the pre-M5 layout had `.upNext` at raw index 3 and `.streams` /
    /// `.profile` at 4 / 5. Remap the stored index onto the post-M5 order.
    ///
    /// Semantics are unchanged from the block that used to live in
    /// `MainTabBarController.viewDidLoad`; it moved here to be testable and to
    /// keep the tab bar controller's diff small against upstream.
    static func migrateM5IfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Constants.UserDefaults.lastTabOpenedMigratedM5),
              defaults.object(forKey: Constants.UserDefaults.lastTabOpened) != nil else {
            return
        }

        let stored = defaults.integer(forKey: Constants.UserDefaults.lastTabOpened)
        let remapped: Int
        switch stored {
        case 3: // old .upNext → playlists
            remapped = oldTabOrder.firstIndex(of: .playlists) ?? stored
        case 4: // old .streams → new .streams
            remapped = oldTabOrder.firstIndex(of: .streams) ?? stored
        case 5: // old .profile → new .profile
            remapped = oldTabOrder.firstIndex(of: .profile) ?? stored
        default:
            remapped = min(stored, oldTabOrder.count - 1)
        }

        defaults.set(remapped, forKey: Constants.UserDefaults.lastTabOpened)
        defaults.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM5)
    }

    /// M12: the stored selection stops being an index and becomes a
    /// `destinationID`, because an index means nothing once slots reorder.
    ///
    /// The old key is left in place. Nothing is written when there is no stored
    /// selection — a fresh install must keep looking un-chosen, which is what
    /// drives the "podcasts or discover" first-launch choice in `viewDidAppear`.
    static func migrateM12IfNeeded(defaults: UserDefaults = .standard) {
        guard !defaults.bool(forKey: Constants.UserDefaults.lastTabOpenedMigratedM12) else { return }

        defer { defaults.set(true, forKey: Constants.UserDefaults.lastTabOpenedMigratedM12) }

        guard defaults.object(forKey: Constants.UserDefaults.lastTabOpened) != nil else { return }

        let stored = defaults.integer(forKey: Constants.UserDefaults.lastTabOpened)
        let clamped = min(max(stored, 0), oldTabOrder.count - 1)

        defaults.set(oldTabOrder[clamped].id, forKey: Constants.UserDefaults.lastTabOpenedID)
    }
}
