#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

extension Notification.Name {
    /// Posted after a station's skew changes. `userInfo[AlignmentSkewStore.stationIdKey]` is the station id.
    static let alignmentSkewDidChange = Notification.Name("PocketRadio.alignmentSkewDidChange")
}

/// The one timing number for a station: the skew, the difference between the stream's timeline and the tracklist's,
/// in seconds. A song the feed stamps at `T` starts in the stream at `T + skew`. The session's title selection, the
/// song position behind the lyrics, the lock screen and the widget all read it, so one change moves them together.
///
/// A heal replaces it. The `+` and `−` on the lyrics page add or subtract `nudgeStep`. It is saved per station on
/// this device, because it depends on this device and its speaker. A station never saved starts at its seed, which
/// is 0 unless the station is known.
final class AlignmentSkewStore {
    static let shared = AlignmentSkewStore(defaults: runtimeDefaults(), seed: AlignmentSkewStore.productionSeed)

    static let stationIdKey = "stationId"
    static let keyPrefix = "PocketRadio.alignment.skew."
    /// A skew beyond this many seconds is rejected: it means something other than latency is wrong.
    static let limit = 600.0
    /// What one tap of `+` or `−` moves the skew.
    static let nudgeStep = 0.5

    /// Under XCTest the host app is the test target, so a skew saved on a simulator must not reach host tests.
    static func runtimeDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard environment["XCTestConfigurationFilePath"] != nil else { return .standard }
        let name = "PocketRadio.alignment.skewTestHost"
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }

    /// Only KCRW is known today, so it is the only station with a seed. Any other station starts at 0.
    static func productionSeed(_ stationId: String) -> Double {
        guard let station = RadioStationRegistry.shared.station(for: stationId),
              KCRWAlignmentConfiguration.isEligible(name: station.title, streamURL: station.streamUrl) else { return 0 }
        return KCRWAlignmentConfiguration.seedSkew
    }

    private let defaults: UserDefaults
    private let seed: (String) -> Double
    private let center: NotificationCenter

    init(defaults: UserDefaults, seed: @escaping (String) -> Double, center: NotificationCenter = .default) {
        self.defaults = defaults
        self.seed = seed
        self.center = center
    }

    /// The saved skew, or the station's seed when none was saved.
    func skew(for stationId: String) -> Double {
        saved(for: stationId) ?? seed(stationId)
    }

    /// The saved skew, nil for a station never healed or nudged.
    func saved(for stationId: String) -> Double? {
        guard defaults.object(forKey: Self.key(stationId)) != nil else { return nil }
        let value = defaults.double(forKey: Self.key(stationId))
        return value.isFinite ? value : nil
    }

    /// Saves a skew. Returns false, and keeps the old one, for a value that is not finite or is beyond `limit`.
    @discardableResult
    func set(_ value: Double, for stationId: String) -> Bool {
        guard !stationId.isEmpty, value.isFinite, abs(value) <= Self.limit else { return false }
        defaults.set((value * 10).rounded() / 10, forKey: Self.key(stationId))
        post(stationId)
        return true
    }

    /// Adds `delta` to the skew in use and saves it. Returns the new skew, or the old one when it would pass `limit`.
    @discardableResult
    func nudge(by delta: Double, for stationId: String) -> Double {
        let current = skew(for: stationId)
        return set(current + delta, for: stationId) ? skew(for: stationId) : current
    }

    /// Forgets the saved skew, so the station is back at its seed.
    func reset(stationId: String) {
        defaults.removeObject(forKey: Self.key(stationId))
        post(stationId)
    }

    private static func key(_ stationId: String) -> String { keyPrefix + stationId }

    private func post(_ stationId: String) {
        center.post(name: .alignmentSkewDidChange, object: self, userInfo: [Self.stationIdKey: stationId])
    }
}
#endif
