import XCTest
@testable import podcasts

/// M13.1 harness. Small base class: resets process-wide state around each test and owns one lazily
/// started `FakeWorld`. A test that never touches `world` never starts servers.
class HarnessScenarioCase: XCTestCase {
    private var _world: FakeWorld?

    /// Created and started on first use; stopped in `tearDown`.
    var world: FakeWorld {
        if let _world { return _world }
        let w: FakeWorld
        do {
            w = try FakeWorld()
            try w.start()
        } catch {
            fatalError("FakeWorld failed to start: \(error)")
        }
        _world = w
        return w
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try XCTSkipUnless(HarnessReset.isEnabled, HarnessReset.skipMessage)
        HarnessReset.fullReset()
    }

    override func tearDown() {
        if HarnessReset.isEnabled {
            // Reset first, while the guard is still installed, so late requests from the ending playback are caught.
            HarnessReset.fullReset()
            let report = _world?.unexpectedRequestReport()
            _world?.stop()
            _world = nil
            if let report { XCTFail(report) }
        }
        super.tearDown()
    }

    func spin(timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }
}
