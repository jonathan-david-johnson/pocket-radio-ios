import XCTest
@testable import podcasts

final class RadioOutputTestHooksTests: HarnessScenarioCase {
    func testDefaultInertAndWrongIdentityDoesNotCapture() throws {
        let hooks = RadioOutputTestHooks()
        XCTAssertTrue(hooks.isIdle)
        XCTAssertFalse(hooks.capture(stationID: "A") { XCTFail("unarmed hook ran") })
        let ticket = try hooks.arm(stationID: "A")
        XCTAssertFalse(hooks.capture(stationID: "B") { XCTFail("wrong identity ran") })
        XCTAssertFalse(hooks.isPending(ticket))
        XCTAssertThrowsError(try hooks.release(ticket, currentStationID: { "A" }))
        hooks.cancel()
        XCTAssertTrue(hooks.isIdle)
    }

    func testArmCaptureAndReleaseExactlyOnce() throws {
        let hooks = RadioOutputTestHooks()
        let ticket = try hooks.arm(stationID: "A")
        XCTAssertThrowsError(try hooks.arm(stationID: "B"))
        var calls = 0
        XCTAssertTrue(hooks.capture(stationID: "A") { calls += 1 })
        XCTAssertTrue(hooks.capture(stationID: "A") { XCTFail("replaced pending continuation") })
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(hooks.isPending(ticket))
        try hooks.release(ticket, currentStationID: { "A" })
        XCTAssertEqual(calls, 1)
        XCTAssertTrue(hooks.isIdle)
        XCTAssertThrowsError(try hooks.release(ticket, currentStationID: { "A" }))
        XCTAssertEqual(calls, 1)
    }

    func testCancellationDropsRetainedClosureAndOldGeneration() throws {
        let hooks = RadioOutputTestHooks()
        let old = try hooks.arm(stationID: "A")
        var retained: NSObject? = NSObject()
        weak var weakObject = retained
        XCTAssertTrue(hooks.capture(stationID: "A") { [object = retained!] in _ = object })
        retained = nil
        XCTAssertNotNil(weakObject)
        hooks.cancel()
        XCTAssertNil(weakObject, "cancel must release the actual pending closure")
        let next = try hooks.arm(stationID: "A")
        var calls = 0
        XCTAssertTrue(hooks.capture(stationID: "A") { calls += 1 })
        XCTAssertThrowsError(try hooks.release(old, currentStationID: { "A" }))
        XCTAssertTrue(hooks.isPending(next))
        try hooks.release(next, currentStationID: { "A" })
        XCTAssertEqual(calls, 1)
    }

    func testReleaseIdentityChangeDropsContinuation() throws {
        let hooks = RadioOutputTestHooks()
        let ticket = try hooks.arm(stationID: "A")
        XCTAssertTrue(hooks.capture(stationID: "A") { XCTFail("stale station rebuild ran") })
        XCTAssertThrowsError(try hooks.release(ticket, currentStationID: { "B" }))
        XCTAssertTrue(hooks.isIdle)
    }

    func testFullResetCancelsPendingAndIsClean() throws {
        let hooks = RadioOutputTestHooks.shared
        let ticket = try hooks.arm(stationID: "A")
        XCTAssertTrue(hooks.capture(stationID: "A") { XCTFail("reset released instead of cancelling") })
        XCTAssertFalse(HarnessReset.isClean)
        HarnessReset.fullReset()
        XCTAssertTrue(hooks.isIdle)
        XCTAssertThrowsError(try hooks.release(ticket, currentStationID: { "A" }))
        XCTAssertTrue(HarnessReset.isClean, HarnessReset.stateSummary())
    }
}
