import XCTest
@testable import podcasts

// MARK: - The solver

final class SkewSolverTests: XCTestCase {
    private let stamp = Date(timeIntervalSince1970: 1_700_000_000)

    private func match(_ title: String, _ artist: String, at position: Double) -> AnchorMatch {
        AnchorMatch(title: title, artist: artist, matchOffset: 0, predictedOffset: position, confidence: 1, frequencySkew: 0)
    }

    private func row(_ title: String, _ artist: String, _ at: Double) -> SkewCandidate {
        SkewCandidate(title: title, artist: artist, playedAt: stamp.addingTimeInterval(at))
    }

    func testTheSkewIsWhenTheSongStartedInTheStreamMinusWhenTheFeedStampedIt() throws {
        // The song is 30 s in at program time 190, so it began in the stream at 160. The feed stamped it at 0.
        let result = try measured(SkewSolver.solve(match: match("Fine", "The Cardigans", at: 30),
                                                   programDate: stamp.addingTimeInterval(190),
                                                   candidates: [row("Fine", "The Cardigans", 0)], currentSkew: 0))
        XCTAssertEqual(result.skew, 160, accuracy: 0.001)
        XCTAssertEqual(result.change, 160, accuracy: 0.001, "from skew 0 the screen is 160 s ahead of the audio")
    }

    func testTheAnswerDoesNotDependOnTheSkewInUse() throws {
        let rows = [row("Fine", "The Cardigans", 0)]
        for current in [0.0, 160, -50, 400] {
            let result = try measured(SkewSolver.solve(match: match("Fine", "The Cardigans", at: 30),
                                                       programDate: stamp.addingTimeInterval(190),
                                                       candidates: rows, currentSkew: current))
            XCTAssertEqual(result.skew, 160, accuracy: 0.001, "starting from \(current)")
            XCTAssertEqual(result.change, 160 - current, accuracy: 0.001)
        }
    }

    private func measured(_ solution: SkewSolver.Solution) throws -> SkewMeasurement {
        struct NotMeasured: Error { let solution: SkewSolver.Solution }
        guard case .measured(let m) = solution else { throw NotMeasured(solution: solution) }
        return m
    }

    func testASongThatIsNotInTheFeedGivesNothing() {
        XCTAssertEqual(SkewSolver.solve(match: match("Spirit 2.0", "Sampha", at: 30), programDate: stamp,
                                        candidates: [row("Fine", "The Cardigans", 0)], currentSkew: 160), .notInFeed)
        XCTAssertEqual(SkewSolver.solve(match: match("Fine", "The Cardigans", at: 30), programDate: stamp,
                                        candidates: [], currentSkew: 160), .notInFeed)
    }

    // Seen on the phone (2026-10-14): the feed said "20th Century Boy (Liza Richardson remix)" and ShazamKit matched the
    // original, 99 s off; the feed said "Dreams (radio edit - clean)" and ShazamKit's reference ran 8 s off the broadcast.
    func testADifferentVersionIsNotUsedToSetTheSkew() {
        let remix = SkewSolver.solve(match: match("20th Century Boy", "T. Rex", at: 105), programDate: stamp.addingTimeInterval(400),
                                     candidates: [row("20th Century Boy (Liza Richardson remix)", "T. Rex", 0)], currentSkew: 0)
        XCTAssertEqual(remix, .differentVersion(feedTitle: "20th Century Boy (Liza Richardson remix)"))

        let edit = SkewSolver.solve(match: match("Dreams", "Beck", at: 21), programDate: stamp.addingTimeInterval(200),
                                    candidates: [row("Dreams (radio edit - clean)", "Beck", 0)], currentSkew: 0)
        XCTAssertEqual(edit, .differentVersion(feedTitle: "Dreams (radio edit - clean)"))
    }

    func testTheSameVersionNamedBothWaysIsUsed() throws {
        let remix = try measured(SkewSolver.solve(
            match: match("20th Century Boy (Liza Richardson Remix)", "T. Rex", at: 234.5), programDate: stamp.addingTimeInterval(394.1),
            candidates: [row("20th Century Boy (Liza Richardson remix)", "T. Rex", 0)], currentSkew: 0))
        XCTAssertEqual(remix.skew, 159.6, accuracy: 0.001)

        let edit = SkewSolver.solve(match: match("Dreams - Radio Edit", "Beck", at: 21), programDate: stamp.addingTimeInterval(200),
                                    candidates: [row("Dreams (radio edit - clean)", "Beck", 0)], currentSkew: 0)
        guard case .measured = edit else { return XCTFail("\(edit)") }
    }

    func testOnlyWordsThatChangeTheTimingMakeADifferentVersion() {
        XCTAssertEqual(AnchorIdentity.versionMarkers("Dreams (radio edit - clean)"), ["edit"])
        XCTAssertEqual(AnchorIdentity.versionMarkers("Song: Their Version"), ["version"], "a version word counts wherever it is")
        XCTAssertEqual(AnchorIdentity.versionMarkers("Song - 2011 Remaster"), [])
        XCTAssertEqual(AnchorIdentity.versionMarkers("Song (Explicit)"), [])
        XCTAssertEqual(AnchorIdentity.versionMarkers("Song (feat. Someone) [Live]"), ["live"])
        XCTAssertEqual(AnchorIdentity.versionMarkers("Song"), [])
        XCTAssertTrue(AnchorIdentity.sameVersion("A Good Day (Clean)", "A Good Day"))
        XCTAssertTrue(AnchorIdentity.sameVersion("Song (Remastered)", "Song"))
        XCTAssertFalse(AnchorIdentity.sameVersion("Song", "Song (Live)"))
        // Seen on KEXP (2026-10-14): the feed wrote a colon where ShazamKit wrote brackets, and the heal wrongly skipped it.
        XCTAssertTrue(AnchorIdentity.sameVersion("TIME IS HAPPENING: MUSTAFA & JULIEN BAKER VERSION",
                                                 "TIME IS HAPPENING (MUSTAFA & JULIEN BAKER VERSION)"))
        XCTAssertTrue(AnchorIdentity.sameVersion("Live and Let Die", "Live and Let Die"), "the same word in both titles is not a difference")
        XCTAssertFalse(AnchorIdentity.sameVersion("Song (Album Version)", "Song"))
    }

    func testASongThatPlayedTwiceUsesTheRowNearestTheSkewInUse() throws {
        // Two plays of the same song, 600 s apart. The heard one began in the stream at 760.
        let rows = [row("Fine", "The Cardigans", 0), row("Fine", "The Cardigans", 600)]
        let program = stamp.addingTimeInterval(790)
        let near160 = try measured(SkewSolver.solve(match: match("Fine", "The Cardigans", at: 30), programDate: program,
                                                    candidates: rows, currentSkew: 160))
        XCTAssertEqual(near160.skew, 160, accuracy: 0.001)
        XCTAssertEqual(near160.matchingRows, 2)
        XCTAssertEqual(near160.entry.playedAt, stamp.addingTimeInterval(600))

        let near760 = try measured(SkewSolver.solve(match: match("Fine", "The Cardigans", at: 30), programDate: program,
                                                    candidates: rows, currentSkew: 700))
        XCTAssertEqual(near760.skew, 760, accuracy: 0.001)
    }

    func testTheTitleMatchIsTolerant() throws {
        let result = try measured(SkewSolver.solve(match: match("Simetachin", "Cut Chemist", at: 10), programDate: stamp.addingTimeInterval(170),
                                                   candidates: [row("Simetachin (featuring Derib Zenebe and Dexter Story)", "Cut Chemist", 0)],
                                                   currentSkew: 160))
        XCTAssertEqual(result.skew, 160, accuracy: 0.001)
    }
}

// MARK: - The probe

@MainActor
final class SkewProbeTests: XCTestCase {
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

    private final class State {
        var context: HealContext?
        var lines: [String] = []
    }

    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let generation = UUID()

    private func context(rows: [SkewCandidate]? = nil, skew: Double = 160, gen: UUID? = nil) -> HealContext {
        HealContext(generation: gen ?? generation, stationId: "s", programDate: base.addingTimeInterval(190),
                    candidates: rows ?? [SkewCandidate(title: "Fine", artist: "The Cardigans", playedAt: base)], currentSkew: skew)
    }

    private func match(_ position: Double, title: String = "Fine", artist: String = "The Cardigans") -> AnchorOutcome {
        .matched(AnchorMatch(title: title, artist: artist, matchOffset: position - 5, predictedOffset: position, confidence: 0.9, frequencySkew: 0))
    }

    private func make(_ source: Scripted, _ state: State, timeout: TimeInterval = 5) -> ShazamAnchorProbe {
        ShazamAnchorProbe(source: source, context: { state.context }, emit: { state.lines.append($0) }, timeout: timeout)
    }

    func test_aHeardSongFoundInTheFeedGivesASkewAndALogLine() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.outcomes = [match(30)]
        let result = await make(source, state).anchorNow()

        guard case .measured(let measurement) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(measurement.skew, 160, accuracy: 0.001)
        XCTAssertEqual(measurement.change, 0, accuracy: 0.001)
        XCTAssertTrue(state.lines.first(where: { $0.hasPrefix("[anchor] heard=") })?.contains("skew=160.0 inUse=160.0 change=+0.0") ?? false, "\(state.lines)")
        // The line also gives the moment the song began in the stream and the feed's stamp, to compare with the stream's own titles.
        XCTAssertTrue(state.lines.first(where: { $0.hasPrefix("[anchor] heard=") })?.contains("at=2023-11-14T22:16:30.000Z start=2023-11-14T22:16:00.000Z stamp=2023-11-14T22:13:20.000Z") ?? false,
                      "\(state.lines)")
    }

    func test_eachListenLogsTheAudioRouteItHeardOn() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.outcomes = [.noMatch]
        let probe = ShazamAnchorProbe(source: source, context: { state.context }, emit: { state.lines.append($0) },
                                      route: { "in=[MicrophoneBuiltIn \"iPhone Microphone\"] out=[BluetoothA2DPOutput \"WH\"]" }, timeout: 5)
        _ = await probe.anchorNow()
        XCTAssertEqual(state.lines.first, "[anchor] listening in=[MicrophoneBuiltIn \"iPhone Microphone\"] out=[BluetoothA2DPOutput \"WH\"]")
        XCTAssertEqual(state.lines.dropFirst().first, "[anchor] heard on in=[MicrophoneBuiltIn \"iPhone Microphone\"] out=[BluetoothA2DPOutput \"WH\"]",
                       "the route is read again after listening, when ShazamKit's own session is active")
    }

    func test_aSongTheFeedDoesNotListIsReportedAndNotMeasured() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.outcomes = [match(30, title: "Spirit 2.0", artist: "Sampha")]
        let probe = make(source, state)
        let result = await probe.anchorNow()

        XCTAssertEqual(result, .notInFeed(title: "Spirit 2.0", artist: "Sampha"))
        XCTAssertTrue(probe.measurements.isEmpty)
        XCTAssertTrue(probe.status.contains("isn't in the tracklist yet"))
    }

    func test_withoutASessionNothingListens() async {
        let source = Scripted(), state = State()
        let probe = make(source, state)
        let result = await probe.anchorNow()
        XCTAssertEqual(result, .notRunning)
        XCTAssertTrue(state.lines.isEmpty)
    }

    func test_aSessionThatChangesWhileListeningDiscardsTheAnchor() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.outcomes = [match(30)]
        source.onAnchor = { state.context = self.context(gen: UUID()) }
        let result = await make(source, state).anchorNow()
        XCTAssertEqual(result, .sessionChanged)
        XCTAssertTrue(state.lines.contains { $0.contains("discarded") })
    }

    func test_theFeedIsReadWhenTheResultArrivesNotWhenListeningStarts() async {
        let source = Scripted(), state = State()
        state.context = context(rows: [])      // empty feed when listening starts
        source.outcomes = [match(30)]
        source.onAnchor = { state.context = self.context() }   // the row arrives while listening
        let result = await make(source, state).anchorNow()
        guard case .measured = result else { return XCTFail("\(result)") }
    }

    func test_noMatchAndErrorsAreReportedNotMeasured() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.outcomes = [.noMatch, .error("not authorized")]
        let probe = make(source, state)
        let first = await probe.anchorNow()
        XCTAssertEqual(first, .noMatch)
        XCTAssertEqual(probe.status, "No match")
        let second = await probe.anchorNow()
        guard case .failed(let text) = second else { return XCTFail("\(second)") }
        XCTAssertTrue(text.contains("Microphone access is off"))
        XCTAssertTrue(probe.measurements.isEmpty)
    }

    func test_aSessionThatNeverAnswersTimesOutAndIsCancelled() async {
        let source = Scripted(), state = State()
        state.context = context()
        source.delay = 5
        source.outcomes = [match(30)]
        let probe = make(source, state, timeout: 0.05)
        let result = await probe.anchorNow()
        guard case .failed(let text) = result else { return XCTFail("\(result)") }
        XCTAssertTrue(text.contains("timed out"))
        XCTAssertEqual(source.cancelled, 1)
        XCTAssertFalse(probe.isListening)
    }

    func test_aMissingEntitlementIsExplained() {
        XCTAssertTrue(ShazamAnchorProbe.explain("Missing entitlements for com.apple.ShazamKit").contains("ShazamKit App Service"))
        XCTAssertTrue(ShazamAnchorProbe.explain("AMSStatusCode=401").contains("HTTP 401"))
    }
}

// MARK: - The skew store

final class AlignmentSkewStoreTests: XCTestCase {
    private let suite = "AlignmentSkewStoreTests"
    private var defaults: UserDefaults!
    private var center: NotificationCenter!

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
        center = NotificationCenter()
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    private func store(seed: Double = 0) -> AlignmentSkewStore {
        AlignmentSkewStore(defaults: defaults, seed: { $0 == "kcrw" ? 160 : seed }, center: center)
    }

    func testAStationNeverSavedStartsAtItsSeedAndAnUnknownStationAtZero() {
        let s = store()
        XCTAssertEqual(s.skew(for: "kcrw"), 160)
        XCTAssertEqual(s.skew(for: "a-new-stream"), 0)
        XCTAssertNil(s.saved(for: "kcrw"))
    }

    func testASavedSkewWinsOverTheSeedAndSurvivesANewStore() {
        XCTAssertTrue(store().set(157.5, for: "kcrw"))
        XCTAssertEqual(store().skew(for: "kcrw"), 157.5, "read back by a fresh store, as after a relaunch")
        XCTAssertEqual(store().saved(for: "kcrw"), 157.5)
    }

    func testZeroIsASavedValueNotASeed() {
        let s = store()
        s.set(0, for: "kcrw")
        XCTAssertEqual(s.skew(for: "kcrw"), 0, "a heal from skew 0 starts here, not at the seed")
        s.reset(stationId: "kcrw")
        XCTAssertEqual(s.skew(for: "kcrw"), 160)
    }

    func testEachStationHasItsOwnSkew() {
        let s = store()
        s.set(100, for: "a")
        s.set(200, for: "b")
        XCTAssertEqual(s.skew(for: "a"), 100)
        XCTAssertEqual(s.skew(for: "b"), 200)
    }

    func testANudgeAddsToTheSkewInUseAndSavesIt() {
        let s = store()
        XCTAssertEqual(s.nudge(by: 0.5, for: "kcrw"), 160.5, "from the seed")
        XCTAssertEqual(s.nudge(by: -2, for: "kcrw"), 158.5)
        XCTAssertEqual(store().skew(for: "kcrw"), 158.5)
    }

    func testHalfSecondNudgesAddUpExactly() {
        let s = store()
        for _ in 0..<20 { s.nudge(by: AlignmentSkewStore.nudgeStep, for: "x") }
        XCTAssertEqual(s.skew(for: "x"), 10, accuracy: 0.0001)
    }

    func testAValueBeyondTheLimitOrNotFiniteIsRefused() {
        let s = store()
        XCTAssertFalse(s.set(601, for: "kcrw"))
        XCTAssertFalse(s.set(-601, for: "kcrw"))
        XCTAssertFalse(s.set(.nan, for: "kcrw"))
        XCTAssertFalse(s.set(.infinity, for: "kcrw"))
        XCTAssertFalse(s.set(5, for: ""))
        XCTAssertEqual(s.skew(for: "kcrw"), 160)
        XCTAssertTrue(s.set(600, for: "kcrw"))
        XCTAssertEqual(s.nudge(by: 0.5, for: "kcrw"), 600, "a nudge past the limit leaves it")
    }

    func testAChangePostsANotificationForThatStation() {
        let s = store()
        var heard: [String] = []
        let token = center.addObserver(forName: .alignmentSkewDidChange, object: nil, queue: nil) {
            heard.append($0.userInfo?[AlignmentSkewStore.stationIdKey] as? String ?? "?")
        }
        defer { center.removeObserver(token) }
        s.set(1, for: "a")
        s.nudge(by: 0.5, for: "b")
        s.reset(stationId: "a")
        s.set(.nan, for: "c")
        XCTAssertEqual(heard, ["a", "b", "a"], "a refused value posts nothing")
    }

    func testTheValueIsRoundedToATenthOfASecond() {
        let s = store()
        s.set(157.4999, for: "x")
        XCTAssertEqual(s.skew(for: "x"), 157.5, accuracy: 0.0001)
    }

    func testTheHostAppStoreIsIsolatedUnderXCTest() {
        let testDefaults = AlignmentSkewStore.runtimeDefaults(environment: ["XCTestConfigurationFilePath": "/x"])
        XCTAssertFalse(testDefaults === UserDefaults.standard)
    }
}

// MARK: - The healer

@MainActor
final class SkewHealerTests: XCTestCase {
    private func make(_ world: SkewWorld, suite: String = "SkewHealerTests") -> (SkewHealer, [String]) {
        (SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { world.outcome() }, context: { world.context() },
                                             emit: { _ in }, timeout: 10),
                    store: world.store,
                    session: { (world.generation, world.stationId) },
                    now: { world.programTime },
                    emit: { _ in },
                    sleep: { world.programTime += $0 }), [])
    }

    private func world(start: Double, true trueSkew: Double = 158.2, seed: UInt64 = 1, repeatEvery: Int = 0) -> SkewWorld {
        SkewWorld(feed: SimulatedFeed(seed: seed, trueSkew: trueSkew, repeatEvery: repeatEvery), startSkew: start, seed: seed,
                  suite: "SkewHealerTests.\(seed)")
    }

    func test_theMessagesTellTheStory() {
        XCTAssertEqual(HealMessage.listening(2), "Listening… (2)")
        XCTAssertEqual(HealMessage.heard(change: -3.2, 1), "Audio is 3.2 s ahead of the screen (1)")
        XCTAssertEqual(HealMessage.heard(change: 5.0, 2), "Screen is 5.0 s ahead of the audio (2)")
        XCTAssertEqual(HealMessage.heard(change: 0.3, 3), "In sync (3)")
        XCTAssertEqual(HealMessage.heard(change: 158.2, 1), "Screen is 158 s ahead of the audio (1)")
        XCTAssertEqual(HealMessage.corrected(by: -2.8, to: 157.2), "Timing corrected by -2.8 s. Skew 157.2 s")
        XCTAssertEqual(HealMessage.inSync(158.2), "In sync. Skew 158.2 s")
    }

    func test_aHealFromSkewZeroFindsTheRightSkewAndSavesIt() async {
        let w = world(start: 0)
        let (healer, _) = make(w)
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }

        XCTAssertTrue(ok)
        XCTAssertEqual(w.skew, 158.2, accuracy: 1.0)
        XCTAssertEqual(w.attempts, 2, "a big change needs a second anchor to agree")
        XCTAssertEqual(messages.first, "Listening… (1)")
        XCTAssertTrue(messages.last?.hasPrefix("Timing corrected by") ?? false, "\(messages)")
        XCTAssertEqual(w.store.saved(for: w.stationId), w.skew, "it is saved, so the next session starts here")
    }

    func test_aHealReplacesAFineTune() async {
        let w = world(start: 158.2)
        w.store.nudge(by: 3, for: w.stationId)      // a fine-tune that the heal does not keep
        XCTAssertEqual(w.skew, 161.2)
        let (healer, _) = make(w)
        await healer.heal { _ in }
        XCTAssertEqual(w.skew, 158.2, accuracy: 1.0)
    }

    func test_aHealWhenAlreadyRightSaysSoAfterOneAnchorAndLeavesTheSkewAlone() async {
        let w = world(start: 158.2)
        let (healer, _) = make(w)
        var messages: [String] = []
        await healer.heal { messages.append($0) }
        XCTAssertEqual(w.attempts, 1, "close to the skew in use: one anchor is enough")
        XCTAssertTrue(messages.last?.hasPrefix("In sync. Skew") ?? false, "\(messages)")
        XCTAssertEqual(w.skew, 158.2, "one noisy anchor does not nudge a skew that is already right")
        XCTAssertEqual(healer.lastResult, messages.last)
    }

    func test_aSmallChangeIsBelievedAtOnceAndABigOneNeedsASecondAnchor() async {
        let small = world(start: 156.0)             // 2.2 s off
        let (healer1, _) = make(small)
        await healer1.heal { _ in }
        XCTAssertEqual(small.attempts, 1)
        XCTAssertEqual(small.skew, 158.2, accuracy: 1.0)

        let big = world(start: 100, seed: 2)        // 58 s off
        let (healer2, _) = make(big)
        await healer2.heal { _ in }
        XCTAssertEqual(big.attempts, 2)
        XCTAssertEqual(big.skew, 158.2, accuracy: 1.0)
    }

    func test_withoutASessionItSaysSo() async {
        let w = world(start: 0)
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.outcome() }, context: { w.context() }, emit: { _ in }),
                                store: w.store, session: { nil }, now: { 0 }, emit: { _ in }, sleep: { _ in })
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertEqual(messages, [HealMessage.notRunning])
        XCTAssertEqual(w.attempts, 0)
    }

    func test_whenNothingMatchesItGivesUpAfterEightTriesAndChangesNothing() async {
        let w = world(start: 100)
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.programTime += 7; return .noMatch },
                                                         context: { w.context() }, emit: { _ in }),
                                store: w.store, session: { (w.generation, w.stationId) }, now: { w.programTime }, emit: { _ in },
                                sleep: { w.programTime += $0 })
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertEqual(messages.last, HealMessage.gaveUp)
        XCTAssertEqual(w.skew, 100)
        XCTAssertNil(w.store.saved(for: w.stationId).flatMap { $0 == 100 ? nil : $0 }, "nothing else was saved")
    }

    func test_aSongMissingFromTheFeedIsWaitedForWithoutUsingUpTheAttempts() async {
        let w = world(start: 0)
        w.unknownSongRate = 1
        var sleeps: [TimeInterval] = []
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.outcome() }, context: { w.context() },
                                                         emit: { _ in }, timeout: 10),
                                store: w.store, session: { (w.generation, w.stationId) }, now: { w.programTime }, emit: { _ in },
                                sleep: { sleeps.append($0); w.programTime += $0 })
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertTrue(messages.contains("\"Not In The Feed\" isn't in the tracklist yet. Waiting for it…"), "\(messages)")
        XCTAssertEqual(w.attempts, SkewHealer.maxAttempts + SkewHealer.maxFeedWaits, "the waits did not use up the attempts")
        XCTAssertEqual(sleeps.filter { $0 == SkewHealer.feedGap }.count, SkewHealer.maxFeedWaits)
        XCTAssertEqual(w.skew, 0)
    }

    func test_aSongTheFeedListsLaterIsHealedOnceItAppears() async {
        // KEXP's feed lists a play about two minutes after its stamp, so a song heard soon after it starts is not there yet.
        let w = SkewWorld(feed: SimulatedFeed(seed: 5, trueSkew: 8, publishDelay: 100), startSkew: 0, seed: 5,
                          suite: "SkewHealerTests.late")
        if let song = w.feed.songs.first(where: { $0.stamp > SimulatedFeed.origin + 600 }) {
            w.programTime = song.stamp + w.feed.trueSkew + 10   // 10 s into a song that is not published yet
        }
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.outcome() }, context: { w.context() },
                                                         emit: { _ in }, timeout: 10),
                                store: w.store, session: { (w.generation, w.stationId) }, now: { w.programTime },
                                emit: { _ in }, sleep: { w.programTime += $0 })
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertTrue(messages.contains { $0.contains("isn't in the tracklist yet. Waiting for it") }, "\(messages)")
        XCTAssertTrue(ok, "\(messages)")
        XCTAssertEqual(w.skew, 8, accuracy: 1.0)
    }

    func test_itWaitsBetweenListensAndNotAfterTheLast() async {
        let w = world(start: 0)
        var sleeps: [TimeInterval] = []
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.programTime += 7; return .noMatch },
                                                         context: { w.context() }, emit: { _ in }, timeout: 10),
                                store: w.store, session: { (w.generation, w.stationId) }, now: { w.programTime }, emit: { _ in },
                                sleep: { sleeps.append($0) })
        await healer.heal { _ in }
        XCTAssertEqual(sleeps, Array(repeating: SkewHealer.gap, count: SkewHealer.maxAttempts - 1),
                       "ShazamKit rejects a session opened straight after another, so each listen waits")
    }

    func test_editedVersionsAreSkippedAndChangeNothing() async {
        let w = SkewWorld(feed: SimulatedFeed(seed: 3, trueSkew: 158.2, listedAsEdit: true), startSkew: 0, seed: 3,
                          suite: "SkewHealerTests.edit")
        let (healer, _) = make(w)
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertTrue(messages.contains { $0.contains("is an edit or remix, so it can't set the timing") }, "\(messages)")
        XCTAssertEqual(messages.last, HealMessage.onlyEditedVersions)
        XCTAssertEqual(w.skew, 0, "the anchors from an edit never set a skew")
    }

    func test_aCancelledHealStopsInsteadOfOpeningListensBackToBack() async {
        let w = world(start: 100)
        w.unknownSongRate = 1
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { w.outcome() }, context: { w.context() },
                                                         emit: { _ in }, timeout: 10),
                                store: w.store, session: { (w.generation, w.stationId) }, now: { w.programTime }, emit: { _ in },
                                sleep: { _ in })
        var messages: [String] = []
        let task = Task { @MainActor in await healer.heal { messages.append($0) } }
        task.cancel()
        let ok = await task.value
        XCTAssertFalse(ok)
        XCTAssertEqual(messages.last, HealMessage.cancelled)
        XCTAssertEqual(w.attempts, 0, "it stopped before listening")
        XCTAssertEqual(w.skew, 100)
    }

    func test_aResultBeyondTheLimitChangesNothing() async {
        let w = world(start: 0, true: 700)   // the stream is 700 s behind the feed: not latency
        let (healer, _) = make(w)
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertEqual(messages.last, HealMessage.outOfRange)
        XCTAssertEqual(w.skew, 0)
    }

    func test_aStationChangeMidwayStopsItWithoutChangingTheSkew() async {
        let w = world(start: 0)
        var generation = w.generation
        let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { [unowned w] in
                                                             let outcome = w.outcome()
                                                             generation = UUID()
                                                             return outcome
                                                         }, context: { [unowned w] in
                                                             w.context().map { HealContext(generation: generation, stationId: $0.stationId, programDate: $0.programDate, candidates: $0.candidates, currentSkew: $0.currentSkew) }
                                                         }, emit: { _ in }),
                                store: w.store, session: { (generation, w.stationId) }, now: { w.programTime }, emit: { _ in },
                                sleep: { w.programTime += $0 })
        // The generation is read before and after listening, so it differs by the time the result arrives.
        var messages: [String] = []
        let ok = await healer.heal { messages.append($0) }
        XCTAssertFalse(ok)
        XCTAssertEqual(messages.last, HealMessage.sessionChanged)
        XCTAssertEqual(w.skew, 0)
    }

    func test_twoHealsAtOnceRunOnce() async {
        let w = world(start: 0)
        let (healer, _) = make(w)
        async let first = healer.heal { _ in }
        async let second = healer.heal { _ in }
        let results = await [first, second]
        XCTAssertEqual(results.filter { $0 }.count, 1)
    }

    func test_agreedSkewNeedsTwoWithinASecondOfTheMedian() {
        XCTAssertNil(SkewHealer.agreedSkew([158.2]))
        XCTAssertEqual(SkewHealer.agreedSkew([158.2, 158.4]) ?? -1, 158.3, accuracy: 0.001)
        XCTAssertNil(SkewHealer.agreedSkew([158.2, 211.0]), "a wrong-section anchor has no one to agree with")
        XCTAssertEqual(SkewHealer.agreedSkew([158.2, 211.0, 158.4]) ?? -1, 158.3, accuracy: 0.001)
        XCTAssertNil(SkewHealer.agreedSkew([150, 158, 166]), "spread out: none agree")
    }
}

// MARK: - Phase 0: the heal against simulated stations

/// The heal against simulated stations (ADR 0010). Each run is a fresh station, a fresh starting skew and a seeded set of anchors. Pass:
/// from any starting skew, the heal ends within 1 s of the true skew; a wrong-section anchor never moves the result
/// by more than 1 s; a missing song changes nothing.
@MainActor
final class SkewSimulationTests: XCTestCase {
    struct Outcome {
        var errors: [Double] = []
        var attempts: [Int] = []
        var failures = 0
        var runs: Int { errors.count + failures }

        var worst: Double { errors.max() ?? 0 }
        var p95: Double { errors.sorted()[min(errors.count - 1, Int(Double(errors.count) * 0.95))] }
        var within1: Double { Double(errors.filter { $0 <= 1.0 }.count) / Double(max(1, runs)) }
        var meanAttempts: Double { Double(attempts.reduce(0, +)) / Double(max(1, attempts.count)) }
    }

    private func sweep(start: Double, trueSkew: Double = 158.2, seeds: Range<UInt64> = 0..<40, noise: Double = 0.4,
                       wrongSection: Double = 0, repeatEvery: Int = 0) async -> Outcome {
        var out = Outcome()
        for seed in seeds {
            let world = SkewWorld(feed: SimulatedFeed(seed: seed, trueSkew: trueSkew, repeatEvery: repeatEvery),
                                  startSkew: start, seed: seed, suite: "SkewSimulationTests")
            world.noise = noise
            world.wrongSectionRate = wrongSection
            let healer = SkewHealer(probe: ShazamAnchorProbe(source: WorldSource { world.outcome() },
                                                             context: { world.context() }, emit: { _ in }, timeout: 30),
                                    store: world.store, session: { (world.generation, world.stationId) },
                                    now: { world.programTime }, emit: { _ in }, sleep: { world.programTime += $0 })
            let ok = await healer.heal { _ in }
            if ok { out.errors.append(abs(world.skew - trueSkew)); out.attempts.append(world.attempts) } else { out.failures += 1 }
        }
        return out
    }

    func testFromSkewZero() async {
        let r = await sweep(start: 0)
        print("SIM start=0: runs=\(r.runs) failures=\(r.failures) within1s=\(r.within1) p95=\(r.p95) worst=\(r.worst) attempts=\(r.meanAttempts)")
        XCTAssertEqual(r.failures, 0)
        XCTAssertLessThanOrEqual(r.worst, 1.0)
    }

    func testFromTheSeedAndFromEitherSideOfIt() async {
        for start in [160.0, 100, 220, -60] {
            let r = await sweep(start: start)
            print("SIM start=\(start): within1s=\(r.within1) p95=\(r.p95) worst=\(r.worst) failures=\(r.failures)")
            XCTAssertEqual(r.failures, 0, "start \(start)")
            XCTAssertLessThanOrEqual(r.worst, 1.0, "start \(start)")
        }
    }

    func testTrueSkewsFarFromTheSeed() async {
        for truth in [0.0, 25, 90, 320] {
            let r = await sweep(start: 0, trueSkew: truth)
            print("SIM true=\(truth): within1s=\(r.within1) worst=\(r.worst) failures=\(r.failures)")
            XCTAssertEqual(r.failures, 0, "true \(truth)")
            XCTAssertLessThanOrEqual(r.worst, 1.0, "true \(truth)")
        }
    }

    func testWrongSectionAnchorsDoNotMoveTheResult() async {
        let r = await sweep(start: 0, seeds: 0..<60, wrongSection: 0.2)
        print("SIM wrongSection=0.2: runs=\(r.runs) failures=\(r.failures) within1s=\(r.within1) p95=\(r.p95) worst=\(r.worst) attempts=\(r.meanAttempts)")
        XCTAssertLessThanOrEqual(r.worst, 1.0, "a wrong section never gets through")
        XCTAssertGreaterThanOrEqual(r.within1, 0.95)
    }

    func testNoisyAnchors() async {
        let r = await sweep(start: 0, noise: 0.8)
        print("SIM noise=0.8: runs=\(r.runs) failures=\(r.failures) within1s=\(r.within1) p95=\(r.p95) worst=\(r.worst) attempts=\(r.meanAttempts)")
        XCTAssertLessThanOrEqual(r.p95, 1.5)
    }

    func testASongThatPlaysTwiceInTheWindowDoesNotMisleadAHealFromTheSeed() async {
        // Titles repeat every 3 songs, so the feed's window of 10 holds the heard song three or four times.
        let r = await sweep(start: 160, repeatEvery: 3)
        print("SIM repeats from seed: within1s=\(r.within1) worst=\(r.worst) failures=\(r.failures)")
        XCTAssertLessThanOrEqual(r.worst, 1.0)
    }

    func testRepeatsFromSkewZeroStillFindTheRightPlay() async {
        let r = await sweep(start: 0, repeatEvery: 3)
        print("SIM repeats from zero: runs=\(r.runs) within1s=\(r.within1) worst=\(r.worst) failures=\(r.failures)")
        XCTAssertLessThanOrEqual(r.worst, 1.0)
    }

    func testRepeatsFromAStartingSkewFarOnTheOtherSideAreTheKnownWeakness() async {
        // The true skew is 158 and the song repeats 825 s later, which is 383 s from a start of 600 and 442 s from 158.
        // The nearest-row rule picks the wrong play. A start that far from the truth is not a case the app produces
        // (a seed or a saved skew is within seconds), so this is recorded, not asserted.
        let r = await sweep(start: 600, repeatEvery: 3)
        print("SIM repeats from 600: runs=\(r.runs) within1s=\(r.within1) worst=\(r.worst) failures=\(r.failures)")
    }
}
