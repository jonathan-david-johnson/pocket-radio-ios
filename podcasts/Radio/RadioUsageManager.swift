import Foundation
import Supabase
import PocketCastsServer
import PocketCastsUtils

struct ListenTimeRecord: Codable {
    let user_uuid: String
    let station_id: String
    let seconds: Double
}

struct DonationRecord: Codable {
    let user_uuid: String
    let station_id: String
    let amount_dollars: Double
    let created_at: String?
}

struct ListenTimeUpsert: Encodable {
    let user_uuid: String
    let station_id: String
    let seconds: Double
}

struct DonationUpsert: Encodable {
    let user_uuid: String
    let station_id: String
    let amount_dollars: Double
}

/// Supabase manager for listen time and donation data.
class RadioUsageManager {
    static let shared = RadioUsageManager()

    // MARK: - Listen Time

    func loadListenTime() async throws -> [ListenTimeRecord] {
        guard let userId = ServerSettings.userId else { throw RadioError.notLoggedIn }
        let db = try RadioSupabase.client()
        return try await db
            .from("listen_time")
            .select()
            .eq("user_uuid", value: userId)
            .execute()
            .value
    }

    func syncListenTimeTotals(_ totals: [String: TimeInterval]) async {
        guard let userId = ServerSettings.userId else { return }
        do {
            let db = try RadioSupabase.client()
            for (stationId, totalSeconds) in totals {
                try await db
                    .from("listen_time")
                    .upsert(
                        ListenTimeUpsert(user_uuid: userId, station_id: stationId, seconds: totalSeconds)
                    )
                    .execute()
            }
        } catch {
            FileLog.shared.addMessage("[RadioUsageManager] Listen time sync failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Donations

    func loadDonations() async throws -> [DonationRecord] {
        guard let userId = ServerSettings.userId else { throw RadioError.notLoggedIn }
        let db = try RadioSupabase.client()
        return try await db
            .from("donations")
            .select()
            .eq("user_uuid", value: userId)
            .execute()
            .value
    }

    func saveDonation(stationId: String, amount: Double) async throws {
        guard let userId = ServerSettings.userId else { throw RadioError.notLoggedIn }
        let db = try RadioSupabase.client()
        try await db
            .from("donations")
            .upsert(
                DonationUpsert(user_uuid: userId, station_id: stationId, amount_dollars: amount)
            )
            .execute()
    }
}
