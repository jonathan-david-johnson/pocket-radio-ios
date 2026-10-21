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

    /// A stand-in for the live session's per-song offsets.
    private final class Offsets {
        var values: [String: Double] = [:]
        var stream = 20.0
        var refuse = false
        var control: PerSongControl {
            PerSongControl(effective: { [self] in $0.flatMap { values[$0] } ?? stream },
                           set: { [self] value, key in
                               if refuse { return false }
                               values[key] = value
                               return true
                           })
        }
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let generation = UUID()
    private var defaults: UserDefaults!
    private var store: AlignmentSkewStore!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: "SkewTrackerTests")
        defaults.removePersistentDomain(forName: "SkewTrackerTests")
        store = AlignmentSkewStore(defaults: defaults, seed: { _ in 20 }, center: NotificationCenter())
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: "SkewTrackerTests")
        super.tearDown()
    }

    private func match(_ title: String, position: Double, id: String = "A") -> AnchorOutcome {
        .matched(AnchorMatch(title: title, artist: "Artist", matchOffset: position - 5, predictedOffset: position, confidence: 1,
                             frequencySkew: 0, shazamID: id, isrc: "ISRC", candidates: [id]))
    }

    /// The feed's row "Song" stamped at `base` with id `row-1`, and a program date `at` seconds after it.
    private func context(at: Double) -> HealContext {
        HealContext(generation: generation, stationId: "s", programDate: base.addingTimeInterval(at),
                    candidates: [SkewCandidate(title: "Song", artist: "Artist", playedAt: base, rowKey: "row-1")], currentSkew: 20)
    }

    private struct Rig {
        let tracker: SkewTracker
        let source: Scripted
        let offsets: Offsets
        let clock: Clock
        var lines: Lines
    }
    private final class Clock { var at = 200.0 }
    private final class Lines { var all: [String] = [] }

    private func makeRig(station: String? = "s", busy: Bool = false) -> Rig {
        let source = Scripted(), offsets = Offsets(), clock = Clock(), lines = Lines()
        let probe = ShazamAnchorProbe(source: source, context: { self.context(at: clock.at) }, emit: { lines.all.append($0) },
                                      route: { "r" }, timeout: 5)
        let tracker = SkewTracker(probe: { probe }, healerBusy: { busy }, activeStation: { station }, perSong: { offsets.control },
                                  store: store, emit: { lines.all.append($0) }, sleep: { _ in }, runsLoop: false)
        return Rig(tracker: tracker, source: source, offsets: offsets, clock: clock, lines: lines)
    }

    /// One anchor whose skew is `skew`: program date 200 minus the position minus the stamp (0).
    private func anchor(_ rig: Rig, skew: Double) async -> TimeInterval {
        rig.clock.at = 200
        rig.source.outcomes = [match("Song", position: 200 - skew)]
        return await rig.tracker.step()
    }

    // MARK: Measure

    func testMeasureLogsAJumpBetweenTwoAnchorsOfOneSongAndNeverChangesAnything() async {
        let rig = makeRig()
        rig.tracker.set(mode: .measure)
        rig.tracker.set(mode: .measure)
        _ = await anchor(rig, skew: 170)
        _ = await anchor(rig, skew: 170)
        rig.source.outcomes = [match("Song", position: 41, id: "B")]
        rig.clock.at = 220
        _ = await rig.tracker.step()

        let jumps = rig.lines.all.filter { $0.hasPrefix("[track] jump") }
        XCTAssertEqual(jumps.count, 1, "\(rig.lines.all)")
        XCTAssertTrue(jumps.first?.contains("+9.0 s (skew 170.0 -> 179.0)") ?? false, "\(jumps)")
        XCTAssertTrue(jumps.first?.contains("sid A -> B") ?? false, "it names the recordings: \(jumps)")
        XCTAssertTrue(rig.offsets.values.isEmpty, "measure mode changes nothing")
        rig.tracker.set(mode: .off)
    }

    // MARK: Apply

    func testANewSongsFirstBigChangeWaitsForASecondAnchorThatAgrees() async {
        let rig = makeRig()
        rig.tracker.set(mode: .apply)
        let first = await anchor(rig, skew: -31)           // the stream default is 20: 51 s away
        XCTAssertTrue(rig.offsets.values.isEmpty, "one anchor of a big change is not believed")
        XCTAssertEqual(first, SkewTracker.confirmGap, "the second anchor is asked for soon")
        XCTAssertTrue(rig.lines.all.contains { $0.contains("waiting for a second anchor") })

        let second = await anchor(rig, skew: -30.8)
        XCTAssertEqual(rig.offsets.values["row-1"] ?? 0, -30.9, accuracy: 0.11, "the two anchors' mean")
        XCTAssertEqual(store.skew(for: "s"), -30.9, accuracy: 0.11, "the stream default follows, for the next song")
        XCTAssertEqual(second, SkewTracker.gap)
        XCTAssertTrue(rig.lines.all.contains { $0.hasPrefix("[auto] Song skew 20.0 ->") }, "\(rig.lines.all)")
        rig.tracker.set(mode: .off)
    }

    func testAWrongSectionAnchorNeverSetsAnOffsetAlone() async {
        let rig = makeRig()
        rig.tracker.set(mode: .apply)
        let wrong = await anchor(rig, skew: 140)       // a wrong section, 120 s from the default
        XCTAssertEqual(wrong, SkewTracker.confirmGap)
        _ = await anchor(rig, skew: 19.8)              // the next anchor is back at the default: nothing to change
        XCTAssertTrue(rig.offsets.values.isEmpty, "the wrong anchor never became an offset, and the default needed none")
        XCTAssertEqual(store.skew(for: "s"), 20)
        rig.tracker.set(mode: .off)
    }

    func testASmallChangeIsBelievedAtOnceAndASteadySongIsListenedToLess() async {
        let rig = makeRig()
        rig.tracker.set(mode: .apply)
        rig.offsets.values["row-1"] = 16.4
        let drift = await anchor(rig, skew: 15.8)                   // 0.6 s: a drifting song, above the 0.5 s deadband
        XCTAssertEqual(rig.offsets.values["row-1"] ?? 0, 15.8, accuracy: 0.001)
        XCTAssertEqual(drift, SkewTracker.gap)

        _ = await anchor(rig, skew: 15.9)                           // 0.1 s: steady
        let steady = await anchor(rig, skew: 15.8)                  // steady twice in a row
        XCTAssertEqual(steady, SkewTracker.steadyGap)
        XCTAssertEqual(rig.offsets.values["row-1"] ?? 0, 15.8, accuracy: 0.001, "a steady song is left alone")
        rig.tracker.set(mode: .off)
    }

    func testMeasureModeNeverApplies() async {
        let rig = makeRig()
        rig.tracker.set(mode: .measure)
        _ = await anchor(rig, skew: 19)
        _ = await anchor(rig, skew: 19)
        XCTAssertTrue(rig.offsets.values.isEmpty)
        rig.tracker.set(mode: .off)
    }

    func testAnOffsetTheSessionRefusesIsNotAppliedToTheStreamDefault() async {
        let rig = makeRig()
        rig.offsets.refuse = true
        rig.tracker.set(mode: .apply)
        _ = await anchor(rig, skew: 22)
        XCTAssertEqual(store.skew(for: "s"), 20, "the default moves only when the song's offset was accepted")
        rig.tracker.set(mode: .off)
    }

    // MARK: Waiting

    func testItWaitsForAStationAndForAHealAndRetriesAMissingSongSoon() async {
        var rig = makeRig(station: nil)
        let none = await rig.tracker.step()
        XCTAssertEqual(none, SkewTracker.gap)
        XCTAssertEqual(rig.tracker.lastLine, "Waiting for a station")
        XCTAssertEqual(rig.source.calls, 0)

        rig = makeRig(busy: true)
        _ = await rig.tracker.step()
        XCTAssertEqual(rig.tracker.lastLine, "Heal running")
        XCTAssertEqual(rig.source.calls, 0)

        rig = makeRig()
        rig.source.outcomes = [match("Not Listed", position: 30)]
        let missing = await rig.tracker.step()
        XCTAssertEqual(missing, SkewTracker.feedGap, "a song the feed has not listed yet is tried again sooner")
    }

    func testTheModeLogsWhenItStartsAndStops() {
        let rig = makeRig()
        rig.tracker.set(mode: .apply)
        XCTAssertEqual(rig.tracker.mode, .apply)
        rig.tracker.set(mode: .off)
        XCTAssertEqual(rig.lines.all, ["[track] on mode=apply", "[track] off"])
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
