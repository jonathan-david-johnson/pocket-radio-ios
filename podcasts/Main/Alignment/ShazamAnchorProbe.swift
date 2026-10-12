#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils

/// Runs ShazamKit anchors against the aligned song and learns the offset from them. Debug only, and measure-only:
/// it never changes what the app shows. See the ShazamKit experiment.
@MainActor
final class ShazamAnchorProbe: ObservableObject {
    static let maxKept = 30

    @Published private(set) var status = "Idle"
    @Published private(set) var measurements: [AnchorMeasurement] = []
    @Published private(set) var isListening = false
    @Published private(set) var isAuto = false

    private(set) var learners: OffsetLearnerStore
    private let source: OffsetAnchorSource
    private let moment: () -> AlignedMoment?
    private let feedSkew: () -> Double
    private let correction: @MainActor () -> Double
    private let route: () -> String
    private let uptime: () -> TimeInterval
    private let emit: (String) -> Void
    private let timeout: TimeInterval
    private var autoTask: Task<Void, Never>?

    init(source: OffsetAnchorSource = ShazamManagedAnchorSource(),
         moment: @escaping () -> AlignedMoment? = ShazamAnchorProbe.currentMoment,
         feedSkew: @escaping () -> Double = { ObserveSwitchStore.shared.feedSkew },
         correction: @escaping @MainActor () -> Double = { AlignmentCorrection.shared.current },
         route: @escaping () -> String = ShazamAnchorProbe.currentRoute,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         timeout: TimeInterval = 25,
         learnerConfig: OffsetLearnerConfig = OffsetLearnerConfig()) {
        self.source = source
        self.moment = moment
        self.feedSkew = feedSkew
        self.correction = correction
        self.route = route
        self.uptime = uptime
        self.emit = emit
        self.timeout = timeout
        learners = OffsetLearnerStore(config: learnerConfig)
    }

    /// Reads one anchor now. Returns the measurement when ShazamKit named a song while the app was still showing
    /// the same song, else nil with the reason in `status`.
    @discardableResult
    func anchorNow() async -> AnchorMeasurement? {
        guard !isListening else { return nil }
        guard let before = moment() else {
            status = "Needs Apply on and a song playing on the speaker"
            return nil
        }
        isListening = true
        status = "Listening to the speaker…"
        defer { isListening = false }

        let outcome = await race()
        switch outcome {
        case .noMatch:
            status = "No match"
            emit("[anchor] no match aligned=\"\(before.title) — \(before.artist)\"")
            return nil
        case .error(let message):
            status = Self.explain(message)
            emit("[anchor] error \(message)")
            return nil
        case .matched(let match):
            // Read the app's position at the moment the result arrives, the same instant the predicted offset is read.
            guard let after = moment(), after.occurrenceID == before.occurrenceID else {
                status = "The song changed while listening; discarded"
                emit("[anchor] discarded: the aligned song changed while listening")
                return nil
            }
            let skew = feedSkew()
            let applied = correction()
            let measurement = AnchorMeasurement(
                aligned: after, shazam: match,
                effectiveOffset: AlignmentOffset.effective(base: KCRWAlignmentConfiguration.selectionPolicy.feedToProgramOffset,
                                                           skew: skew, correction: applied),
                feedSkew: skew, correction: applied)
            emit(measurement.logLine())
            measurements.insert(measurement, at: 0)
            if measurements.count > Self.maxKept { measurements.removeLast(measurements.count - Self.maxKept) }
            if measurement.identityMatches {
                learners.add(OffsetAnchor(time: uptime(), delta: measurement.correctionNeeded), route: route())
                status = String(format: "Anchored: audio is %+.1f s from the app", measurement.delta)
            } else {
                status = "Heard a different song than the app shows; not used"
            }
            return measurement
        }
    }

    /// The learner's correction for the current route. Positive: the audio is ahead of the app.
    var learnedCorrection: Double? { learners.correction(route: route()) }
    var learnerAnchorCount: Int { learners.anchorCount(route: route()) }
    var learnerRejectedCount: Int { learners.rejectedCount(route: route()) }

    /// Forgets what was learned, for a new session or a changed skew.
    func resetLearning() { learners.reset() }

    func startAuto(every interval: TimeInterval) {
        stopAuto()
        isAuto = true
        autoTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let waiting = self.moment() == nil
                if !waiting { _ = await self.anchorNow() }
                try? await Task.sleep(nanoseconds: UInt64((waiting ? 10 : interval) * 1_000_000_000))
            }
        }
    }

    func stopAuto() {
        autoTask?.cancel()
        autoTask = nil
        isAuto = false
    }

    // MARK: - Private

    /// The source against a timeout, so a session that never answers can't hold the button down.
    private func race() async -> AnchorOutcome {
        await withCheckedContinuation { continuation in
            var finished = false
            let source = self.source
            Task { @MainActor in
                let outcome = await source.anchor()
                if !finished { finished = true; continuation.resume(returning: outcome) }
            }
            let limit = timeout
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                if !finished {
                    finished = true
                    source.cancel()
                    continuation.resume(returning: .error("timed out after \(Int(limit)) s"))
                }
            }
        }
    }

    /// A readable status for the errors worth explaining. The log line keeps the full text.
    static func explain(_ message: String) -> String {
        if message.contains("Missing entitlements") || message.contains("AMSStatusCode=401") {
            return "ShazamKit refused this app (HTTP 401, missing entitlements). Enable the ShazamKit App Service for the app's ID in the developer portal."
        }
        if message.localizedCaseInsensitiveContains("microphone") || message.contains("not authorized") {
            return "Microphone access is off. Allow it in Settings > Pocket Casts."
        }
        return "Error: \(String(message.prefix(120)))"
    }

    // MARK: - Defaults

    static func currentMoment() -> AlignedMoment? {
        guard case .song(let song)? = AlignedNowPlayingState.shared.current,
              let position = AlignedConsumers.lyricPosition(stationId: song.stationId),
              position.occurrenceID == song.occurrenceID else { return nil }
        return AlignedMoment(title: song.title, artist: song.artist, occurrenceID: song.occurrenceID, songSeconds: position.seconds)
    }

    static func currentRoute() -> String {
        AVAudioSession.sharedInstance().currentRoute.outputs.first?.portType.rawValue ?? "unknown"
    }
}
#endif
