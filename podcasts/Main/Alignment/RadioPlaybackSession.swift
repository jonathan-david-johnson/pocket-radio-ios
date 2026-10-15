#if !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils
import StreamSession

/// Owner of one `AVPlayerItem` for an aligned station (KCRW or KEXP; see `AlignmentProfile`). It samples the player once a second, keeps the
/// StreamSession core, runs one feed poller, records the monitor data, and writes `[align]` log
/// lines. It registers the station with `AlignedNowPlayingState` and hands every snapshot to
/// `AlignedNowPlayingPublisher`, the only path to the lock screen and players. It never writes Now
/// Playing fields, artwork or lyrics itself. The station's skew (`AlignmentSkewStore`) is the feed-to-program
/// offset it selects with, and a change to it takes effect at once.
///
/// Main-actor isolated. `DefaultPlayer` is not, so it goes through `startOnMain` and
/// `stopOnMain`.
@MainActor
final class RadioPlaybackSession {
    typealias Install = (AVPlayer, @escaping (CMTime) -> Void) -> Any
    typealias Remove = (AVPlayer, Any) -> Void
    typealias ObserveStatus = (AVPlayer, @escaping (AVPlayer.TimeControlStatus) -> Void) -> Any?
    typealias Fetch = @MainActor () async -> AlignmentFeedResult

    static let maxStoredSamples = 21_600
    static let pollInterval: TimeInterval = 30
    static let summaryInterval: TimeInterval = 300

    /// The live session, for the Debug readout. Weak, main thread only.
    private(set) static weak var active: RadioPlaybackSession?

    let generation: UUID
    let item: AVPlayerItem
    let endpoint: URL
    let stationId: String
    /// How this station is aligned: its clock, its feed and where its skew starts.
    let profile: AlignmentProfile
    /// Readout callback. Cleared on stop.
    var onSnapshot: ((RadioAlignmentSnapshot) -> Void)?

    private(set) var snapshot: RadioAlignmentSnapshot
    private(set) var isStopped = false
    /// True once a `.paused` status followed the first playing sample.
    private(set) var audioStopped = false
    /// Closed periods not playing after the first playing sample. An open one closes at stop.
    private(set) var stallIntervals: [ClosedRange<TimeInterval>] = []
    private(set) var monitorSamples: [AlignmentMonitorSample] = []
    /// One per attempt, recorded at attempt start. `succeeded` is filled when the result arrives,
    /// so a failed or still-in-flight attempt still counts as an attempt.
    private(set) var monitorPolls: [AlignmentMonitorPoll] = []

    private weak var player: AVPlayer?
    private let now: () -> TimeInterval
    private let emit: (String) -> Void
    private let flush: () -> Void
    private let fetch: Fetch
    private let feedClient: AlignmentFeed?
    private let remove: Remove
    private let alignedState: AlignedNowPlayingState
    private let publisher: AlignedNowPlayingPublisher?
    private let startedAt: TimeInterval
    private let wallNow: () -> Date
    /// For a `mediaTime` clock: the wall time at which media position 0 would have been, fixed when playback first
    /// advances. A new play is a new item and takes a new anchor.
    private var mediaAnchor: Date?
    private var state: SessionState
    private let skew: (String) -> Double
    /// The skew the selection policy currently reflects. Nil until the first sample reads it.
    private(set) var appliedSkew: Double?
    private var skewObserver: NSObjectProtocol?
    private var token: Any?
    private var statusToken: Any?
    private var pollTask: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?
    private var pollInFlight = false
    private var pollCount = 0
    private var tickCount = 0
    private var requestID = 0
    private var latestFeedTop: String?
    private var lastPollElapsed: TimeInterval?
    private var lastStatus: AVPlayer.TimeControlStatus?
    private var hasPlayed = false
    private var stallStart: TimeInterval?
    private var lastClockValid: Bool?
    private var lastDecisionID: OccurrenceID?
    private var lastDecisionReason = RadioAlignmentSnapshot.initialReason
    private var nextSummaryAt = RadioPlaybackSession.summaryInterval

    init(player: AVPlayer,
         item: AVPlayerItem,
         generation: UUID = UUID(),
         endpoint: URL,
         stationId: String = "",
         profile: AlignmentProfile = AlignmentProfiles.kcrw,
         alignedState: AlignedNowPlayingState = .shared,
         post: AlignedNowPlayingPublisher.Post? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         wallNow: @escaping () -> Date = Date.init,
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         flush: @escaping () -> Void = { FileLog.shared.forceFlush() },
         fetch: Fetch? = nil,
         install: Install? = nil,
         remove: @escaping Remove = { $0.removeTimeObserver($1) },
         observeStatus: ObserveStatus? = nil,
         skew: ((String) -> Double)? = nil,
         startsPoller: Bool = true) {
        self.player = player
        self.item = item
        self.generation = generation
        self.endpoint = endpoint
        self.stationId = stationId
        self.profile = profile
        self.wallNow = wallNow
        state = SessionState(historyPolicy: profile.historyPolicy,
                             selectionPolicy: profile.selectionPolicy,
                             clockPolicy: profile.clockPolicy)
        self.alignedState = alignedState
        if let post {
            publisher = AlignedNowPlayingPublisher(stationId: stationId, generation: generation,
                                                   state: alignedState, post: post, emit: emit)
        } else {
            publisher = AlignedNowPlayingPublisher(stationId: stationId, generation: generation,
                                                   state: alignedState, emit: emit)
        }
        self.now = now
        self.emit = emit
        self.flush = flush
        if let fetch {
            self.fetch = fetch
            feedClient = nil
        } else {
            let client = profile.makeFeed()
            self.fetch = { await client.fetch() }
            feedClient = client
        }
        self.remove = remove
        self.skew = skew ?? { AlignmentSkewStore.shared.skew(for: $0) }
        startedAt = now()
        snapshot = RadioAlignmentSnapshot(generation: generation,
                                          endpoint: AlignmentProbeLog.safeEndpoint(endpoint),
                                          feedTop: nil, candidate: nil, candidateID: nil, selectedOccurrence: nil,
                                          songSeconds: nil,
                                          mediaSeconds: nil, programDate: nil,
                                          reason: RadioAlignmentSnapshot.initialReason,
                                          feedStatus: "not requested", cacheAgeSeconds: nil, historyCount: 0,
                                          lastPollElapsed: nil, clockValid: false, trigger: nil)

        let installer: Install = install ?? { player, callback in
            player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                           queue: .main,
                                           using: callback)
        }
        let observer: ObserveStatus = observeStatus ?? { player, handler in
            player.observe(\.timeControlStatus, options: [.initial, .new]) { player, _ in
                handler(player.timeControlStatus)
            }
        }

        Self.active = self
        publisher?.isPlayerPlaying = { [weak self] in self?.lastStatus == .playing }
        alignedState.beginApplying(stationId: stationId, generation: generation)
        emit("[align] session start gen=\(AlignmentProbeLog.shortID(generation)) "
            + "endpoint=\(AlignmentProbeLog.safeEndpoint(endpoint))")
        refreshOffsetPolicy()
        token = installer(player, Self.tickHandler(for: self))
        statusToken = observer(player, Self.statusHandler(for: self))
        skewObserver = NotificationCenter.default.addObserver(forName: .alignmentSkewDidChange, object: nil, queue: .main) { [weak self] note in
            guard let id = note.userInfo?[AlignmentSkewStore.stationIdKey] as? String else { return }
            MainActor.assumeIsolated { self?.skewChanged(stationId: id) }
        }
        if startsPoller { startTimerPoller() }
    }

    // MARK: - DefaultPlayer seam

    /// `DefaultPlayer` is not main-actor isolated. Creation happens on the main thread in
    /// practice; off main it logs and does nothing rather than crash.
    nonisolated static func startOnMain(player: AVPlayer, item: AVPlayerItem, endpoint: URL,
                                        stationId: String, profile: AlignmentProfile) -> RadioPlaybackSession? {
        guard Thread.isMainThread else {
            FileLog.shared.addMessage("[align] session not started: not on the main thread")
            return nil
        }
        return MainActor.assumeIsolated {
            RadioPlaybackSession(player: player, item: item, endpoint: endpoint, stationId: stationId, profile: profile)
        }
    }

    /// Stops now on the main thread, or asynchronously on main from any other thread.
    nonisolated static func stopOnMain(_ session: RadioPlaybackSession?) {
        guard let session else { return }
        onMain { session.stop() }
    }

    nonisolated private static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated(work)
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated(work) }
        }
    }

    // Built outside the main-actor initializer so the closures are not main-actor isolated:
    // AVFoundation and KVO may call them from any thread.
    nonisolated private static func tickHandler(for session: RadioPlaybackSession) -> (CMTime) -> Void {
        { [weak session] _ in onMain { session?.tick() } }
    }

    nonisolated private static func statusHandler(for session: RadioPlaybackSession) -> (AVPlayer.TimeControlStatus) -> Void {
        { [weak session] status in onMain { session?.statusChanged(status) } }
    }

    // MARK: - Lifecycle

    /// Safe to call more than once. Removes the observer exactly once.
    func stop(reason: String = "teardown") {
        guard !isStopped else { return }
        let end = elapsedNow
        if let start = stallStart {
            stallIntervals.append(start ... max(start, end))
            stallStart = nil
        }
        // Reported while the session is still alive: this is the teardown, not a failure.
        emitSummary(endElapsed: end, kind: "stop")
        isStopped = true
        feedClient?.invalidate()
        pollTask?.cancel()
        pollTask = nil
        fetchTask?.cancel()
        fetchTask = nil
        if let player, let token { remove(player, token) }
        token = nil
        (statusToken as? NSKeyValueObservation)?.invalidate()
        statusToken = nil
        if let skewObserver { NotificationCenter.default.removeObserver(skewObserver) }
        skewObserver = nil
        onSnapshot = nil
        alignedState.endApplying(stationId: stationId, generation: generation)
        if Self.active === self { Self.active = nil }
        emit("[align] session stop gen=\(AlignmentProbeLog.shortID(generation)) reason=\(reason) "
            + "samples=\(monitorSamples.count) polls=\(monitorPolls.count)")
        flush()
    }

    private var elapsedNow: TimeInterval { now() - startedAt }

    /// Seconds since this session started, on the session's own clock.
    var currentElapsed: TimeInterval { elapsedNow }

    // MARK: - Sampling

    private func tick() {
        guard !isStopped, let player, player.currentItem === item else { return }
        tickCount += 1
        let media = item.currentTime().seconds
        sample(currentItem: player.currentItem,
               rate: player.rate,
               status: player.timeControlStatus,
               mediaSeconds: media,
               programDate: programDate(media: media, advancing: player.rate > 0 && player.timeControlStatus == .playing))
    }

    /// One paired player observation. Only this path can change the candidate.
    func sample(currentItem: AVPlayerItem?, rate: Float, status: AVPlayer.TimeControlStatus,
                mediaSeconds: Double?, programDate: Date?) {
        guard !isStopped, currentItem === item else { return }
        refreshOffsetPolicy()
        let elapsed = elapsedNow
        statusChanged(status)
        let media = mediaSeconds.flatMap { $0.isFinite ? $0 : nil }
        let advancing = rate > 0 && status == .playing
        let buffer = currentItem.flatMap {
            AlignmentProbeLog.forwardBuffer(loadedRanges: $0.loadedTimeRanges.map(\.timeRangeValue), current: $0.currentTime())
        }
        emit(AlignmentProbeLog.line(generation: generation, elapsed: elapsed, media: media,
                                    date: programDate, rate: rate, status: status,
                                    buffer: buffer, likelyToKeepUp: currentItem?.isPlaybackLikelyToKeepUp))
        monitorSamples.append(AlignmentMonitorSample(elapsed: elapsed, mediaSeconds: media,
                                                     programDate: programDate, rate: rate, isPlaying: advancing))
        if monitorSamples.count > Self.maxStoredSamples {
            monitorSamples.removeFirst(monitorSamples.count - Self.maxStoredSamples)
        }
        let decision = state.observePlayer(MediaClockSample(generation: generation.uuidString,
                                                            elapsedSeconds: elapsed,
                                                            mediaSeconds: media,
                                                            programDate: programDate,
                                                            isAdvancing: advancing))
        publish(decision, elapsed: elapsed)
        if elapsed >= nextSummaryAt {
            emitSummary(endElapsed: elapsed, kind: "checkpoint")
            nextSummaryAt = (floor(elapsed / Self.summaryInterval) + 1) * Self.summaryInterval
        }
    }

    /// Moves the selection policy to the station's skew when it differs from the one in use. The song selection, and
    /// through it the title, the artwork and the song position behind the lyrics, all follow this one number.
    private func refreshOffsetPolicy() {
        let skew = skew(stationId)
        guard skew != appliedSkew else { return }
        let first = appliedSkew == nil
        appliedSkew = skew
        let frozen = profile.selectionPolicy
        state.updateSelectionPolicy(OccurrenceSelectionPolicy(feedToProgramOffset: skew,
                                                              maxSelectedAge: frozen.maxSelectedAge,
                                                              maxFeedSilence: frozen.maxFeedSilence))
        emit("[align] skew \(String(format: "%.1f", skew)) s\(first ? " (session start)" : "")")
    }

    /// A nudge or a heal changed this station's skew. Reads it and takes a sample now, so the title and the lyric
    /// line move at once and not at the next one-second tick.
    private func skewChanged(stationId changed: String) {
        guard !isStopped, changed == stationId else { return }
        tick()
    }

    /// The program date for a media position, on this profile's clock.
    ///
    /// `programDate`: the player's own date for the item, as HLS carries it.
    ///
    /// `mediaTime`: a stream with no program date. The date is the wall time at which media position 0 would have
    /// been, fixed when playback first advances, plus the media position. Media time stops during a stall, so the
    /// clock follows the audio and a stall does not move the skew. Nil until playback first advances.
    func programDate(media: Double?, advancing: Bool) -> Date? {
        switch profile.clock {
        case .programDate:
            return item.currentDate()
        case .mediaTime:
            guard let media, media.isFinite else { return nil }
            if mediaAnchor == nil {
                guard advancing else { return nil }
                mediaAnchor = wallNow().addingTimeInterval(-media)
            }
            return mediaAnchor?.addingTimeInterval(media)
        }
    }

    /// The stream's program date now, on this profile's clock. Nil while it has none.
    func currentProgramDate() -> Date? {
        guard !isStopped, player?.currentItem === item else { return nil }
        switch profile.clock {
        case .programDate: return item.currentDate()
        case .mediaTime:
            let media = item.currentTime().seconds
            guard mediaAnchor != nil, media.isFinite else { return nil }
            return programDate(media: media, advancing: true)
        }
    }

    /// The rows the feed returned, for the heal to match a heard song against.
    var feedRows: [Occurrence] { state.history.occurrences }

    /// Status changes, from KVO or from a sample. Drives the stall record and `audioStopped`.
    func statusChanged(_ status: AVPlayer.TimeControlStatus) {
        guard !isStopped, status != lastStatus else { return }
        lastStatus = status
        let elapsed = elapsedNow
        emit("[align] status \(AlignmentProbeLog.statusText(status)) t=\(Self.f1(elapsed))")
        publisher?.playerStatusChanged(playing: status == .playing)
        if status == .playing {
            hasPlayed = true
            if let start = stallStart {
                stallIntervals.append(start ... max(start, elapsed))
                stallStart = nil
            }
        } else if hasPlayed {
            if stallStart == nil { stallStart = elapsed }
            if status == .paused, !audioStopped {
                // Judge the run up to this pause before the pause itself counts against it.
                emitSummary(endElapsed: elapsed, kind: "at-pause")
                audioStopped = true
            }
        }
    }

    private func publish(_ decision: SessionDecision, elapsed: TimeInterval) {
        let clock: ValidMediaClock?
        if case .valid(let valid)? = decision.clock { clock = valid } else { clock = nil }
        let selection: OccurrenceSelection?
        let reason: String
        switch decision.selection {
        case .selected(let current):
            selection = current
            reason = "estimated from the skew; not verified audible"
        case .unavailable(let why):
            selection = nil
            if case .invalid(let clockReason)? = decision.clock {
                reason = "player clock: \(clockReason.rawValue)"
            } else {
                reason = "alignment unavailable: \(why.rawValue)"
            }
        }

        let clockValid = clock != nil
        if clockValid != lastClockValid {
            lastClockValid = clockValid
            if case .invalid(let clockReason)? = decision.clock {
                emit("[align] clock invalid reason=\(clockReason.rawValue) t=\(Self.f1(elapsed))")
            } else {
                emit("[align] clock valid t=\(Self.f1(elapsed))")
            }
        }

        let candidate = selection.map { Self.describe($0.occurrence) }
        if selection?.occurrence.id != lastDecisionID || reason != lastDecisionReason {
            lastDecisionID = selection?.occurrence.id
            lastDecisionReason = reason
            let songText = selection.map { Self.f1($0.songSeconds) } ?? "nil"
            emit("[align] decision t=\(Self.f1(elapsed)) candidate=\(candidate.map { "\"\($0)\"" } ?? "none") "
                + "songSec=\(songText) reason=\(reason)")
        }

        snapshot = RadioAlignmentSnapshot(generation: generation, endpoint: snapshot.endpoint,
                                          feedTop: latestFeedTop, candidate: candidate,
                                          candidateID: selection?.occurrence.id,
                                          selectedOccurrence: selection?.occurrence,
                                          songSeconds: selection?.songSeconds,
                                          mediaSeconds: clock?.mediaSeconds, programDate: clock?.programDate,
                                          reason: reason, feedStatus: snapshot.feedStatus,
                                          cacheAgeSeconds: snapshot.cacheAgeSeconds,
                                          historyCount: state.history.occurrences.count,
                                          lastPollElapsed: lastPollElapsed, clockValid: clockValid,
                                          trigger: decision.trigger)
        onSnapshot?(snapshot)
        publisher?.receive(snapshot)
    }

    // MARK: - Feed

    /// Testable feed-injection boundary. A result after `stop()` is discarded before it can
    /// reach the core or the readout.
    ///
    /// Receiving rows changes the available evidence, not the player's position. Only the next
    /// paired player sample may change the candidate, so the candidate, reason and player
    /// fields are carried over unchanged.
    func accept(_ result: AlignmentFeedResult, requestedElapsed: TimeInterval, receivedElapsed: TimeInterval) {
        guard !isStopped else { return }
        requestID += 1
        lastPollElapsed = requestedElapsed
        var status: String
        do {
            let update: FeedMutation
            if let failure = result.failure {
                update = try state.failFeed(requestID: requestID,
                                            requestedElapsedSeconds: requestedElapsed,
                                            receivedElapsedSeconds: receivedElapsed,
                                            reason: failure)
            } else {
                update = try state.receiveFeed(requestID: requestID,
                                               requestedElapsedSeconds: requestedElapsed,
                                               receivedElapsedSeconds: receivedElapsed,
                                               entries: result.entries)
                latestFeedTop = result.entries.first.map { Self.describe($0) }
            }
            switch update.update {
            case .accepted: status = "received \(result.entries.count) entries"
            case .empty: status = "empty response"
            case .failed(let reason): status = reason
            case .ignoredOutOfOrder: status = "out-of-order response ignored"
            case .ambiguousCorrection: status = "ambiguous correction"
            }
        } catch {
            status = "rejected: invalid feed timing or policy"
            emit("[align] feed rejected reason=invalid feed timing or policy")
        }
        snapshot = RadioAlignmentSnapshot(generation: generation, endpoint: snapshot.endpoint,
                                          feedTop: latestFeedTop, candidate: snapshot.candidate,
                                          candidateID: snapshot.candidateID,
                                          selectedOccurrence: snapshot.selectedOccurrence,
                                          songSeconds: snapshot.songSeconds,
                                          mediaSeconds: snapshot.mediaSeconds, programDate: snapshot.programDate,
                                          reason: snapshot.reason, feedStatus: status,
                                          cacheAgeSeconds: result.cacheAgeSeconds,
                                          historyCount: state.history.occurrences.count,
                                          lastPollElapsed: requestedElapsed, clockValid: snapshot.clockValid,
                                          trigger: .feedUpdate)
        onSnapshot?(snapshot)
        publisher?.receive(snapshot)
    }

    // MARK: - Poller

    private func startTimerPoller() {
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard self?.beginTimerPoll() == true else { return }
                do { try await Task.sleep(nanoseconds: UInt64(Self.pollInterval * 1_000_000_000)) } catch { return }
            }
        }
    }

    private func beginTimerPoll() -> Bool {
        guard !isStopped else { return false }
        startPoll()
        return true
    }

    /// Starts one attempt unless one is already in flight. The attempt is recorded now, so a
    /// failed or hung request still counts.
    private func startPoll() {
        guard !isStopped, !pollInFlight else { return }
        pollInFlight = true
        pollCount += 1
        let number = pollCount
        let requested = elapsedNow
        monitorPolls.append(AlignmentMonitorPoll(elapsed: requested, succeeded: false))
        let index = monitorPolls.count - 1
        fetchTask = Task { [weak self] in
            guard let fetch = self?.fetch else { return }
            let result = await fetch()
            self?.pollFinished(result, number: number, index: index, requested: requested)
        }
    }

    private func pollFinished(_ result: AlignmentFeedResult, number: Int, index: Int, requested: TimeInterval) {
        pollInFlight = false
        guard !isStopped, !Task.isCancelled else { return }
        monitorPolls[index] = AlignmentMonitorPoll(elapsed: requested, succeeded: result.failure == nil)
        let start = "[align] poll n=\(number) t=\(Self.f1(requested))"
        if let failure = result.failure {
            emit("\(start) fail reason=\(failure)")
        } else {
            let age = result.cacheAgeSeconds.map(Self.f1) ?? "nil"
            emit("\(start) ok entries=\(result.entries.count) age=\(age)")
        }
        accept(result, requestedElapsed: requested, receivedElapsed: max(requested, elapsedNow))
    }

    // MARK: - Monitor

    func summary(endElapsed: TimeInterval) -> AlignmentMonitorSummary {
        AlignmentMonitorSummary.compute(samples: monitorSamples, polls: monitorPolls, endElapsed: endElapsed)
    }

    func lockedRunVerdict(endElapsed: TimeInterval) -> LockedRunVerdict {
        let open = stallStart.map { [$0 ... max($0, endElapsed)] } ?? []
        return summary(endElapsed: endElapsed)
            .evaluateLockedRun(sessionAliveAtEnd: !isStopped, audioNeverStopped: !audioStopped,
                               loggedStallIntervals: stallIntervals + open)
    }

    /// `kind` is `checkpoint` (every 300 s), `at-pause` (first pause after playback), or `stop`.
    private func emitSummary(endElapsed: TimeInterval, kind: String) {
        summary(endElapsed: endElapsed).formattedLines().forEach(emit)
        let verdict = lockedRunVerdict(endElapsed: endElapsed)
        emit("[align] verdict passed=\(verdict.passed) failures=\(verdict.failures.count) kind=\(kind)")
        verdict.failures.forEach { emit("[align] verdict - \($0)") }
    }

    // MARK: - Formatting

    private static func f1(_ value: Double) -> String { String(format: "%.1f", value) }

    private static func describe(_ occurrence: Occurrence) -> String {
        describe(title: occurrence.title, artist: occurrence.artist, kind: occurrence.kind)
    }

    private static func describe(_ input: OccurrenceInput) -> String {
        describe(title: input.title, artist: input.artist, kind: input.kind)
    }

    private static func describe(title: String?, artist: String?, kind: String) -> String {
        guard let title else { return kind }
        return "\(title) — \(artist ?? "")"
    }
}
#endif
