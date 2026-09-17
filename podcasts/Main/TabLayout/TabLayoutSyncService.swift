import Foundation
import PocketCastsServer
import PocketCastsUtils

/// The result of comparing local and remote `updatedAt` timestamps. Pure and
/// separately testable — the network paths that produce its inputs are not.
/// See `TabLayoutSyncService.decision(local:remote:)`.
enum TabLayoutSyncDecision: Equatable {
    case applyRemote
    case pushLocal
    case inSync
}

/// Syncs the tab bar layout through Supabase's `nav_layout` table — M12.3.
///
/// See `docs/ios/milestones/milestone_12.3.md` §2 and
/// `docs/ios/adr/0002-supabase-for-nav-layout-sync.md` for why this exists and
/// why it is a separate table rather than riding Pocket Casts' own sync.
///
/// `TabLayoutStore` (local `UserDefaults`) stays the render source of truth.
/// This service is a background reconcile on top of it, following the same
/// `RadioSupabase.client()` / `RadioFavoritesManager` shape already
/// established for `radio_favorites` and `lyric_offsets`.
final class TabLayoutSyncService {
    static let shared = TabLayoutSyncService()

    init() {}

    /// How the service learns who is signed in.
    ///
    /// Injectable because the signed-out path is otherwise untestable: the test
    /// host is the app itself, so `ServerSettings.userId` reflects whoever
    /// happens to be signed in on that simulator. That is not a hypothetical —
    /// signing in to the simulator by hand made the signed-out test pull the
    /// real remote layout and write it over the local one. A unit test must not
    /// be able to reach the network at all, let alone depend on the machine's
    /// sign-in state.
    var currentUserID: () -> String? = { ServerSettings.userId }

    /// Tolerance for treating two timestamps as equal. A value round-tripped
    /// through Postgres and back should not read as "changed" just because
    /// fractional-second precision was rounded somewhere along the way.
    private static let tolerance: TimeInterval = 0.001

    /// Last-write-wins, and the only place that decision is made (see
    /// `TabLayoutApplier.applyFromSync` doc comment — it deliberately trusts
    /// the caller rather than re-checking).
    ///
    /// - `remote == nil`: no row yet for this user, so the local layout is the
    ///   only copy that exists — push it.
    /// - `remote` newer than `local` (beyond tolerance): the other device
    ///   wrote more recently — apply it.
    /// - `local` newer than `remote` (beyond tolerance): this device wrote
    ///   more recently — push it.
    /// - otherwise: the two already agree — do nothing.
    static func decision(local: Date, remote: Date?) -> TabLayoutSyncDecision {
        guard let remote else { return .pushLocal }

        let delta = remote.timeIntervalSince(local)
        if delta > tolerance {
            return .applyRemote
        }
        if delta < -tolerance {
            return .pushLocal
        }
        return .inSync
    }

    /// Guards against concurrent pulls stacking Supabase queries — mirrors
    /// `RadioFavoritesService.inFlight`. A second caller awaits the first's
    /// in-flight task rather than starting its own.
    private var inFlightPull: Task<Void, Never>?

    // MARK: - Wire format

    /// The row shape in `nav_layout`. `slots` is a flat ordered array of
    /// `TabDestination` id strings — never a serialized `TabLayout` or
    /// `[TabSlot]`. This is the wire contract the migration's leading comment
    /// documents; encoding anything richer here would silently break it.
    private struct NavLayoutRow: Codable {
        let user_uuid: String
        let slots: [String]
        let updated_at: String
    }

    /// Selecting by user only needs `slots` and `updated_at`, but Supabase's
    /// Swift client decodes the whole row shape either way.
    private struct NavLayoutSelectRow: Codable {
        let slots: [String]
        let updated_at: String
    }

    // MARK: - Push

    /// Upserts the local layout to `nav_layout`. Never throws out: any
    /// failure is logged once and swallowed, except signing-out
    /// (`RadioError.notLoggedIn`), which is the normal signed-out path and
    /// logs nothing at all.
    func push(_ layout: TabLayout) async {
        guard Self.isWorthPublishing(layout) else { return }

        do {
            let userId = try signedInUserID()
            let db = try RadioSupabase.client()
            let row = NavLayoutRow(
                user_uuid: userId,
                slots: layout.slots.map(\.destinationID),
                updated_at: Self.iso8601String(from: layout.updatedAt)
            )
            try await db
                .from("nav_layout")
                .upsert(row)
                .execute()
        } catch RadioError.notLoggedIn {
            // The normal signed-out path, not a failure. Silent by design:
            // this runs on every save, and a signed-out user would otherwise
            // fill the log with it.
        } catch {
            FileLog.shared.addMessage("TabLayoutSyncService: push failed: \(error)")
        }
    }

    // MARK: - Pull

    /// Pulls the remote layout at launch, off the critical path, and applies
    /// the last-write-wins decision. Never throws out; signed-out users make
    /// no network call.
    func pullAtLaunch() async {
        if let inFlightPull {
            return await inFlightPull.value
        }

        let task = Task<Void, Never> { [weak self] in
            await self?.performPull()
        }
        inFlightPull = task
        await task.value
        inFlightPull = nil
    }

    private func performPull() async {
        do {
            let userId = try signedInUserID()
            let db = try RadioSupabase.client()
            let rows: [NavLayoutSelectRow] = try await db
                .from("nav_layout")
                .select("slots,updated_at")
                .eq("user_uuid", value: userId)
                .execute()
                .value

            let local = TabLayoutStore.shared.load()

            guard let remoteRow = rows.first else {
                await handle(decision: .pushLocal, local: local, remote: nil)
                return
            }

            guard let remoteDate = Self.parsePostgresTimestamp(remoteRow.updated_at) else {
                FileLog.shared.addMessage("TabLayoutSyncService: could not parse remote updated_at \"\(remoteRow.updated_at)\", skipping pull")
                return
            }

            let remoteLayout = TabLayout(
                slots: remoteRow.slots.map(TabSlot.init(destinationID:)),
                updatedAt: remoteDate
            )

            let decision = Self.decision(local: local.updatedAt, remote: remoteDate)
            await handle(decision: decision, local: local, remote: remoteLayout)
        } catch RadioError.notLoggedIn {
            // The normal signed-out path. See `push`.
        } catch {
            FileLog.shared.addMessage("TabLayoutSyncService: pull failed: \(error)")
        }
    }

    @MainActor
    private func handle(decision: TabLayoutSyncDecision, local: TabLayout, remote: TabLayout?) async {
        switch decision {
        case .applyRemote:
            guard let remote else { return }
            // `applyFromSync` preserves `remote.updatedAt` as-is and applies
            // through the safe-apply gate; it does not repeat this
            // last-write-wins comparison.
            TabLayoutApplier.applyFromSync(remote)
        case .pushLocal:
            await push(local)
        case .inSync:
            break
        }
    }

    // MARK: - Helpers

    /// Whether a layout represents a choice the user actually made.
    ///
    /// `TabLayout.default` carries `updatedAt` of the Unix epoch, and
    /// `TabLayoutApplier.apply` stamps `Date()` on every real change — so the
    /// epoch is an exact marker for "never configured". A fresh install must
    /// not publish that: it would create a row for a user who has expressed no
    /// preference, and a device that launches before the one holding the real
    /// layout would seed the table with a stamp nothing can lose to.
    static func isWorthPublishing(_ layout: TabLayout) -> Bool {
        layout.updatedAt > TabLayout.default.updatedAt
    }

    private func signedInUserID() throws -> String {
        guard let userId = currentUserID(), !userId.isEmpty else {
            throw RadioError.notLoggedIn
        }
        return userId
    }

    private static func iso8601String(from date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    /// Postgres `timestamptz` round-trips as e.g.
    /// `2026-09-11T18:32:03.309123+00:00` — fractional seconds plus an
    /// offset. A default `ISO8601DateFormatter` (no fractional-seconds option)
    /// fails to parse that. Try the fractional-seconds shape first, then fall
    /// back to plain `.withInternetDateTime` for a timestamp with none.
    static func parsePostgresTimestamp(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) {
            return date
        }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
