import XCTest
@testable import podcasts

final class AnchorIdentityTests: XCTestCase {
    private func same(_ at: String, _ aa: String, _ st: String, _ sa: String) -> Bool {
        AnchorIdentity.matches(alignedTitle: at, alignedArtist: aa, shazamTitle: st, shazamArtist: sa)
    }

    func test_sameSongDifferentCaseAndPunctuation() {
        XCTAssertTrue(same("Let’s Keep Dancing", "Emilíana Torrini", "Lets Keep Dancing", "Emiliana Torrini"))
    }

    func test_aFeaturingTailOrBracketedVersionDoesNotBreakTheMatch() {
        XCTAssertTrue(same("Simetachin (featuring Derib Zenebe and Dexter Story)", "Cut Chemist", "Simetachin", "Cut Chemist"))
        XCTAssertTrue(same("A Good Day (Clean)", "Anderson Paak", "A Good Day", "Anderson .Paak"))
        XCTAssertTrue(same("Ritmo Babilonia feat. Beck", "Meridian Brothers", "Ritmo Babilonia", "Meridian Brothers"))
    }

    func test_aDifferentSongIsRejected() {
        XCTAssertFalse(same("Spirit 2.0", "Sampha", "Fine", "The Cardigans"))
        XCTAssertFalse(same("Fine", "The Cardigans", "Fine Line", "Harry Styles"), "same words in the title, different artist")
    }

    func test_aMissingArtistCannotContradictTheTitle() {
        XCTAssertTrue(same("Comes Back to You", "", "Comes Back to You", "Bob Moses"))
        XCTAssertFalse(same("", "Bob Moses", "Comes Back to You", "Bob Moses"), "an empty title never matches")
    }

    func test_theArtistsShareAName() {
        XCTAssertTrue(same("Song", "Bob Moses", "Song", "Bob Moses & Friends"))
    }

    func test_normalizeStripsTheNoise() {
        XCTAssertEqual(AnchorIdentity.normalize("Héllo,  WORLD!! (Live) [Remastered]"), "hello world")
    }
}

@MainActor
final class ShazamAnchorProbeTests: XCTestCase {
    private final class Scripted: OffsetAnchorSource {
        var outcomes: [AnchorOutcome] = []
        var delay: TimeInterval = 0
        var cancelled = 0
        var onAnchor: (() -> Void)?
        func anchor() async -> AnchorOutcome {
            if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            onAnchor?()
            return outcomes.isEmpty ? .noMatch : outcomes.removeFirst()
        }
        func cancel() { cancelled += 1 }
    }

    private final class World {
        var moment: AlignedMoment? = AlignedMoment(title: "Fine", artist: "The Cardigans", occurrenceID: "occ-1", songSeconds: 100)
        var skew = 0.0
        var route = "Speaker"
        var now: TimeInterval = 0
        var lines: [String] = []
    }

    private func match(_ predicted: Double, title: String = "Fine", artist: String = "The Cardigans") -> AnchorOutcome {
        .matched(AnchorMatch(title: title, artist: artist, matchOffset: predicted - 10, predictedOffset: predicted,
                             confidence: 0.9, frequencySkew: 0))
    }

    private func make(_ source: Scripted, _ world: World, timeout: TimeInterval = 5) -> ShazamAnchorProbe {
        ShazamAnchorProbe(source: source, moment: { world.moment }, feedSkew: { world.skew }, route: { world.route },
                          uptime: { world.now }, emit: { world.lines.append($0) }, timeout: timeout)
    }

    func test_aMatchIsLoggedWithDeltaAndTheOffsetThatWouldHaveFixedIt() async throws {
        let source = Scripted(), world = World()
        source.outcomes = [match(103)]
        let probe = make(source, world)

        let anchored = await probe.anchorNow()
        let measurement = try XCTUnwrap(anchored)

        XCTAssertEqual(measurement.delta, 3, accuracy: 0.001, "the audio is 3 s ahead of the app")
        XCTAssertEqual(measurement.trueOffset, 157, accuracy: 0.001)
        XCTAssertTrue(world.lines.contains { $0.hasPrefix("[anchor] aligned=\"Fine — The Cardigans\"") && $0.contains("delta=+3.0") && $0.contains("trueOffset=157.0") && $0.contains("identity=match") })
        XCTAssertEqual(probe.measurements.count, 1)
    }

    func test_theFeedSkewDoesNotChangeTheTrueOffset() async throws {
        // With skew -3 the app is already 3 s further in, so the same audio gives delta 0, and the true offset is still 157.
        let source = Scripted(), world = World()
        world.skew = -3
        world.moment = AlignedMoment(title: "Fine", artist: "The Cardigans", occurrenceID: "occ-1", songSeconds: 103)
        source.outcomes = [match(103)]
        let anchored = await make(source, world).anchorNow()
        let measurement = try XCTUnwrap(anchored)

        XCTAssertEqual(measurement.delta, 0, accuracy: 0.001)
        XCTAssertEqual(measurement.trueOffset, 157, accuracy: 0.001)
        XCTAssertEqual(measurement.correctionNeeded, 0, accuracy: 0.001, "the skewed app is already right, so nothing is needed")
    }

    func test_theLearnerReportsACorrectionAfterThreeIdentityCheckedAnchors() async {
        let source = Scripted(), world = World()
        source.outcomes = [match(103), match(103.2), match(102.9)]
        let probe = make(source, world)
        for step in 0..<3 {
            world.now = Double(step) * 120
            await probe.anchorNow()
            if step < 2 { XCTAssertNil(probe.learnedCorrection) }
        }
        XCTAssertEqual(probe.learnedCorrection ?? -1, 3.0, accuracy: 0.001)
    }

    func test_aWrongSongIsLoggedButNeverTeachesTheLearner() async {
        let source = Scripted(), world = World()
        source.outcomes = [match(150, title: "Spirit 2.0", artist: "Sampha"), match(150, title: "Spirit 2.0", artist: "Sampha"), match(150, title: "Spirit 2.0", artist: "Sampha")]
        let probe = make(source, world)
        for _ in 0..<3 { await probe.anchorNow() }

        XCTAssertNil(probe.learnedCorrection)
        XCTAssertEqual(probe.measurements.count, 3)
        XCTAssertTrue(world.lines.allSatisfy { $0.contains("identity=MISMATCH") })
    }

    func test_nothingAnchorsWhenNoSongIsShowing() async {
        let source = Scripted(), world = World()
        world.moment = nil
        let probe = make(source, world)
        let result = await probe.anchorNow()
        XCTAssertNil(result)
        XCTAssertTrue(probe.status.contains("Apply"))
        XCTAssertTrue(world.lines.isEmpty)
    }

    func test_aSongChangeWhileListeningDiscardsTheAnchor() async {
        let source = Scripted(), world = World()
        source.outcomes = [match(103)]
        source.onAnchor = { world.moment = AlignedMoment(title: "Spirit 2.0", artist: "Sampha", occurrenceID: "occ-2", songSeconds: 5) }
        let result = await make(source, world).anchorNow()
        XCTAssertNil(result)
        XCTAssertTrue(world.lines.contains { $0.contains("discarded") })
    }

    func test_noMatchAndErrorsAreReportedNotLearned() async {
        let source = Scripted(), world = World()
        source.outcomes = [.noMatch, .error("not authorized")]
        let probe = make(source, world)
        await probe.anchorNow()
        XCTAssertEqual(probe.status, "No match")
        await probe.anchorNow()
        XCTAssertTrue(probe.status.contains("Microphone access is off"))
        XCTAssertTrue(probe.measurements.isEmpty)
    }

    func test_aSessionThatNeverAnswersTimesOutAndIsCancelled() async {
        let source = Scripted(), world = World()
        source.delay = 5
        source.outcomes = [match(103)]
        let probe = make(source, world, timeout: 0.05)
        let result = await probe.anchorNow()
        XCTAssertNil(result)
        XCTAssertTrue(probe.status.contains("timed out"))
        XCTAssertEqual(source.cancelled, 1)
        XCTAssertFalse(probe.isListening)
    }

    func test_anAppliedCorrectionIsInTheOffsetInUseAndTheTotalAsked() {
        let match = AnchorMatch(title: "Fine", artist: "The Cardigans", matchOffset: 0, predictedOffset: 100,
                                confidence: 1, frequencySkew: 0)
        // 3 s needed in all. 2 s are already applied, so the app (offset 158) is 1 s behind the audio.
        let measurement = AnchorMeasurement(
            aligned: AlignedMoment(title: "Fine", artist: "The Cardigans", occurrenceID: "o", songSeconds: 99),
            shazam: match, effectiveOffset: 158, feedSkew: 0, correction: 2)
        XCTAssertEqual(measurement.delta, 1, accuracy: 0.001)
        XCTAssertEqual(measurement.correctionNeeded, 3, accuracy: 0.001)
        XCTAssertEqual(measurement.trueOffset, 157, accuracy: 0.001, "the same answer whatever is applied")
        XCTAssertTrue(measurement.logLine().contains("correction=+2.0"))
    }

    func test_aMissingEntitlementIsExplained() {
        let raw = "Error Domain=com.apple.ShazamKit Code=202 \"Missing entitlements\" UserInfo={AMSStatusCode=401}"
        XCTAssertTrue(ShazamAnchorProbe.explain(raw).contains("developer portal"))
        XCTAssertTrue(ShazamAnchorProbe.explain("The microphone is unavailable").contains("Microphone"))
        XCTAssertEqual(ShazamAnchorProbe.explain("boom"), "Error: boom")
    }

    func test_learnersAreKeptPerRoute() async {
        let source = Scripted(), world = World()
        source.outcomes = [match(103), match(103), match(103)]
        let probe = make(source, world)
        for _ in 0..<3 { await probe.anchorNow() }
        XCTAssertNotNil(probe.learnedCorrection)
        world.route = "BluetoothA2DPOutput"
        XCTAssertNil(probe.learnedCorrection, "a different route starts again")
    }
}
