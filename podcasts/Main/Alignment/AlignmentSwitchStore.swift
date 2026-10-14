#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Whether KCRW alignment runs. Off is the old behavior: the feed and ICY titles, no aligned session, no skew and
/// no heal. On plays the measured HLS stream and drives the lock screen and players from the aligned song.
enum AlignmentMode: String, CaseIterable, Equatable {
    case off
    case on
}

/// Debug-only alignment switch for the KCRW probe. Off by default. In Release builds it is always
/// off and cannot be set. Tests must inject `UserDefaults(suiteName:)`.
final class AlignmentSwitchStore {
    static let key = "PocketRadio.alignment.mode"

    /// The app's runtime store. Under XCTest it is an emptied private suite, because the test host
    /// is the app: a mode left on in the simulator must not change host-app tests.
    static let shared = AlignmentSwitchStore(defaults: runtimeDefaults())

    static func runtimeDefaults(environment: [String: String] = ProcessInfo.processInfo.environment) -> UserDefaults {
        guard environment["XCTestConfigurationFilePath"] != nil else { return .standard }
        let name = "PocketRadio.alignment.testHost"
        guard let suite = UserDefaults(suiteName: name) else { return .standard }
        suite.removePersistentDomain(forName: name)
        return suite
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    var mode: AlignmentMode {
        get {
            #if DEBUG
            return defaults.string(forKey: Self.key).flatMap(AlignmentMode.init(rawValue:)) ?? .off
            #else
            return .off
            #endif
        }
        set {
            #if DEBUG
            defaults.set(newValue.rawValue, forKey: Self.key)
            #endif
        }
    }

    var isOn: Bool { mode == .on }
}
#endif
