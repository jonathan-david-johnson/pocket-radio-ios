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
/// this device, because it depends on this device and its speaker. Every list entry for one aligned stream shares one
/// skew (see `AlignmentProfile.key`). A stream never saved starts at its seed, which is 0 unless the stream is known.
final class AlignmentSkewStore {
    static let shared = AlignmentSkewStore(defaults: runtimeDefaults(), seed: AlignmentSkewStore.productionSeed,
                                           key: AlignmentSkewStore.productionKey)

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

    /// A station that belongs to an aligned stream saves its skew under that stream's key, so the MP3, AAC and HLS
    /// list entries for one KCRW stream share a skew. Any other station is keyed by its own id.
    static func productionKey(_ stationId: String) -> String {
        AlignmentProfiles.profile(forStationId: stationId)?.key ?? stationId
    }

    /// The seed for a key: the profile's, or 0 for a stream the app does not know.
    static func productionSeed(_ key: String) -> Double {
        AlignmentProfiles.all.first { $0.key == key }?.seedSkew ?? 0
    }

    private let defaults: UserDefaults
    private let seed: (String) -> Double
    private let keyFor: (String) -> String
    private let center: NotificationCenter

    /// `seed` and the notification's station id work on the key this station's `key` closure returns.
    init(defaults: UserDefaults, seed: @escaping (String) -> Double, key: @escaping (String) -> String = { $0 },
         center: NotificationCenter = .default) {
        self.defaults = defaults
        self.seed = seed
        self.keyFor = key
        self.center = center
    }

    /// The saved skew, or the station's seed when none was saved.
    func skew(for stationId: String) -> Double {
        saved(for: stationId) ?? seed(keyFor(stationId))
    }

    /// The saved skew, nil for a station never healed or nudged.
    func saved(for stationId: String) -> Double? {
        let name = defaultsName(stationId)
        guard defaults.object(forKey: name) != nil else { return nil }
        let value = defaults.double(forKey: name)
        return value.isFinite ? value : nil
    }

    /// Saves a skew. Returns false, and keeps the old one, for a value that is not finite or is beyond `limit`.
    @discardableResult
    func set(_ value: Double, for stationId: String) -> Bool {
        guard !stationId.isEmpty, value.isFinite, abs(value) <= Self.limit else { return false }
        defaults.set((value * 10).rounded() / 10, forKey: defaultsName(stationId))
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
        defaults.removeObject(forKey: defaultsName(stationId))
        post(stationId)
    }

    private func defaultsName(_ stationId: String) -> String { Self.keyPrefix + keyFor(stationId) }

    private func post(_ stationId: String) {
        center.post(name: .alignmentSkewDidChange, object: self, userInfo: [Self.stationIdKey: stationId])
    }
}
#endif
