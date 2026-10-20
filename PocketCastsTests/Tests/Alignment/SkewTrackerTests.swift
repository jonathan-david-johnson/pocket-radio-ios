import XCTest
@testable import podcasts

@MainActor
final class SkewTrackerTests: XCTestCase {
    private final class Scripted: OffsetAnchorSource {
        var outcomes: [AnchorOutcome] = []
        var calls = 0
        func anchor() async -> AnchorOutcome {
            calls += 1
            return outcomes.isEmpty ? .noMatch : outcomes.removeFirst()
        }
        func cancel() {}
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let generation = UUID()

    private func match(_ title: String, position: Double, id: String) -> AnchorOutcome {
        .matched(AnchorMatch(title: title, artist: "Artist", matchOffset: position - 5, predictedOffset: position, confidence: 1,
                             frequencySkew: 0, shazamID: id, isrc: "ISRC", candidates: [id]))
    }

    /// A feed row stamped at `base`, and a program date `at` seconds after it.
    private func context(at: Double) -> HealContext {
        HealContext(generation: generation, stationId: "s", programDate: base.addingTimeInterval(at),
                    candidates: [SkewCandidate(title: "Song", artist: "Artist", playedAt: base)], currentSkew: 20)
    }

    func testItLogsAJumpBetweenTwoAnchorsOfOneSongAndNotASteadyOne() async {
        var lines: [String] = []
        let source = Scripted()
        var clock = 200.0
        let probe = ShazamAnchorProbe(source: source, context: { self.context(at: clock) }, emit: { lines.append($0) }, route: { "r" }, timeout: 5)
        let tracker = SkewTracker(probe: { probe }, healerBusy: { false }, sessionActive: { true }, emit: { lines.append($0) }, sleep: { _ in })

        // Skew = program date - position - stamp. 200 - 30 - 0 = 170, then 210 - 40 = 170 (steady), then 220 - 41 = 179 (a jump of 9).
        source.outcomes = [match("Song", position: 30, id: "A"), match("Song", position: 40, id: "A"), match("Song", position: 41, id: "B")]
        for (time, _) in [(200.0, 0), (210.0, 1), (220.0, 2)] {
            clock = time
            await tracker.step()
        }

        let jumps = lines.filter { $0.hasPrefix("[track] jump") }
        XCTAssertEqual(jumps.count, 1, "\(lines)")
        guard let jump = jumps.first else { return }
        XCTAssertTrue(jump.contains("+9.0 s (skew 170.0 -> 179.0)"), jump)
        XCTAssertTrue(jump.contains("sid A -> B"), "it names the recordings, so a changed reference shows: \(jump)")
    }

    func testItDoesNotListenWhileAHealRunsOrWithoutAStation() async {
        let source = Scripted()
        source.outcomes = [match("Song", position: 30, id: "A")]
        let probe = ShazamAnchorProbe(source: source, context: { self.context(at: 200) }, emit: { _ in }, route: { "r" }, timeout: 5)
        var busy = true, active = true
        let tracker = SkewTracker(probe: { probe }, healerBusy: { busy }, sessionActive: { active }, emit: { _ in }, sleep: { _ in })

        await tracker.step()
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(tracker.lastLine, "Heal running")
        busy = false
        active = false
        await tracker.step()
        XCTAssertEqual(source.calls, 0)
        XCTAssertEqual(tracker.lastLine, "Waiting for a station")
        active = true
        await tracker.step()
        XCTAssertEqual(source.calls, 1)
    }

    func testStartAndStopLogAndNeverChangeTheSkew() async {
        var lines: [String] = []
        let tracker = SkewTracker(probe: { ShazamAnchorProbe(source: Scripted(), context: { nil }, emit: { _ in }, route: { "r" }, timeout: 1) },
                                  healerBusy: { false }, sessionActive: { false }, emit: { lines.append($0) }, sleep: { _ in })
        tracker.start()
        XCTAssertTrue(tracker.isOn)
        tracker.stop()
        XCTAssertFalse(tracker.isOn)
        XCTAssertEqual(lines, ["[track] on", "[track] off"])
    }

    func testTheAnchorLineNamesTheRecording() {
        let measurement = SkewMeasurement(
            shazam: AnchorMatch(title: "Song", artist: "Artist", matchOffset: 0, predictedOffset: 30, confidence: 1, frequencySkew: 0,
                                shazamID: "123", isrc: "USX", candidates: ["123", "456"]),
            entry: SkewCandidate(title: "Song", artist: "Artist", playedAt: base), programDate: base.addingTimeInterval(200),
            skew: 170, currentSkew: 170, matchingRows: 1)
        XCTAssertTrue(measurement.logLine().hasSuffix("sid=123 isrc=USX cands=2"), measurement.logLine())
    }
}
