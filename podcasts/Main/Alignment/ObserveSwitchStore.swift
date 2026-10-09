#if !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Who drives the 30 s KCRW feed poll. `.timer` is a sleeping `Task`; `.playbackTicks` starts
/// a poll from the 1 s player observer instead (the fallback if the timer is suspended when locked).
enum AlignmentPollDriver: Equatable {
    case timer
    case playbackTicks
}

/// Debug-only Observe switch for the KCRW alignment probe. Off by default. In Release builds
/// it is always off and cannot be set. Tests must inject `UserDefaults(suiteName:)`.
final class ObserveSwitchStore {
    static let key = "PocketRadio.alignment.observe"
    static let pollDriverKey = "PocketRadio.alignment.pollDriver"

    /// The app's runtime store. Under XCTest it is an emptied private suite, because the test host
    /// is the app: a switch left on in the simulator must not change host-app tests.
    static let shared = ObserveSwitchStore(defaults: runtimeDefaults())

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

    var isObserveOn: Bool {
        get {
            #if DEBUG
            return defaults.bool(forKey: Self.key)
            #else
            return false
            #endif
        }
        set {
            #if DEBUG
            defaults.set(newValue, forKey: Self.key)
            #endif
        }
    }

    /// Debug-only. Release always uses `.timer`.
    var pollDriver: AlignmentPollDriver {
        get {
            #if DEBUG
            return defaults.string(forKey: Self.pollDriverKey) == "ticks" ? .playbackTicks : .timer
            #else
            return .timer
            #endif
        }
        set {
            #if DEBUG
            defaults.set(newValue == .playbackTicks ? "ticks" : "timer", forKey: Self.pollDriverKey)
            #endif
        }
    }
}
#endif
