import XCTest
@testable import podcasts

@MainActor
final class MicCheckTests: XCTestCase {
    func testTheSummaryAveragesPowerNotDecibels() throws {
        // A loud moment dominates a power average: one −10 dB reading among nine at −60 averages near −20, not −55.
        let summary = try XCTUnwrap(MicCheck.summarize([-10] + Array(repeating: -60, count: 9)))
        XCTAssertEqual(summary.samples, 10)
        XCTAssertEqual(summary.min, -60)
        XCTAssertEqual(summary.max, -10)
        XCTAssertEqual(summary.average, -20, accuracy: 0.1)
    }

    func testSilenceAndNonFiniteReadingsAreHandled() throws {
        XCTAssertNil(MicCheck.summarize([]))
        XCTAssertNil(MicCheck.summarize([.nan, .infinity]))
        let silent = try XCTUnwrap(MicCheck.summarize([-160, -160]))
        XCTAssertEqual(silent.average, -160, accuracy: 0.001)
    }

    func testTheLogLineNamesTheConditionTheRouteAndTheLevel() {
        let line = MicCheck.logLine(label: "headphones", route: "in=[MicrophoneBuiltIn \"iPhone Microphone\"] out=[BluetoothA2DPOutput \"WH\"]",
                                    summary: MicCheck.Summary(samples: 24, min: -61.2, average: -52.4, max: -40.0))
        XCTAssertEqual(line, "[miccheck] headphones in=[MicrophoneBuiltIn \"iPhone Microphone\"] out=[BluetoothA2DPOutput \"WH\"] level avg=-52.4 min=-61.2 max=-40.0 dBFS samples=24")
        XCTAssertEqual(MicCheck.logLine(label: "silence", route: "in=[] out=[]", summary: nil), "[miccheck] silence in=[] out=[] level=unavailable")
    }
}
