#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation

/// Fork-owned, explicitly armed startup barrier. Never stores or manufactures display data.
/// The lock serializes capture/release/reset, including execution, so a cancelled generation
/// cannot run a retained continuation in the next scenario. Release is synchronous on main.
final class RadioOutputTestHooks {
    static let shared = RadioOutputTestHooks()

    enum HookError: Error { case alreadyArmed, notPending, identityChanged, notOnMainThread }
    struct Ticket: Equatable {
        fileprivate let generation: UUID
        let stationID: String
    }

    private let lock = NSRecursiveLock()
    private var ticket: Ticket?
    private var continuation: (() -> Void)?

    var isIdle: Bool { locked { ticket == nil && continuation == nil } }
    func isPending(_ expected: Ticket) -> Bool {
        locked { ticket == expected && continuation != nil }
    }

    func arm(stationID: String) throws -> Ticket {
        try locked {
            guard ticket == nil else { throw HookError.alreadyArmed }
            let next = Ticket(generation: UUID(), stationID: stationID)
            ticket = next
            return next
        }
    }

    /// Returns true only for the explicitly armed station. The actual PM callback supplies
    /// the continuation. Repeated callbacks while held cannot bypass the pending rebuild.
    func capture(stationID: String, continuation: @escaping () -> Void) -> Bool {
        locked {
            guard ticket?.stationID == stationID else { return false }
            if self.continuation == nil { self.continuation = continuation }
            return true
        }
    }

    /// Checks identity immediately before invoking the original continuation, not at arm time.
    func release(_ expected: Ticket, currentStationID: () -> String?) throws {
        guard Thread.isMainThread else { throw HookError.notOnMainThread }
        try locked {
            guard ticket == expected, let run = continuation else { throw HookError.notPending }
            ticket = nil
            continuation = nil
            guard currentStationID() == expected.stationID else { throw HookError.identityChanged }
            run()
        }
    }

    /// Cancels, never releases. Tickets from an earlier reset cannot release a new arm.
    func cancel() {
        locked {
            ticket = nil
            continuation = nil
        }
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
#endif
