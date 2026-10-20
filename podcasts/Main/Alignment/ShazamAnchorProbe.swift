#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils

/// Listens once and turns what it hears into a skew. It asks ShazamKit which song is playing and where in it, reads
/// the stream's program date at that instant, and finds the song in the feed's rows (`SkewSolver`). It changes
/// nothing by itself: `SkewHealer` decides what to do with the measurements. Debug only.
@MainActor
final class ShazamAnchorProbe: ObservableObject {
    static let maxKept = 30

    @Published private(set) var status = "Idle"
    @Published private(set) var measurements: [SkewMeasurement] = []
    @Published private(set) var isListening = false

    private let source: OffsetAnchorSource
    private let context: () -> HealContext?
    private let emit: (String) -> Void
    private let route: () -> String
    private let timeout: TimeInterval

    init(source: OffsetAnchorSource = ShazamManagedAnchorSource(),
         context: @escaping () -> HealContext? = ShazamAnchorProbe.currentContext,
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         route: @escaping () -> String = ShazamAnchorProbe.routeDescription,
         timeout: TimeInterval = 25) {
        self.source = source
        self.context = context
        self.emit = emit
        self.route = route
        self.timeout = timeout
    }

    enum Result: Equatable {
        /// The anchor names a row in the feed. `skew` is what it implies.
        case measured(SkewMeasurement)
        /// ShazamKit named a song the feed does not list. The feed may lag.
        case notInFeed(title: String, artist: String)
        /// The feed lists this song as another version (a remix or an edit), so the anchor is not used.
        case differentVersion(heard: String, feed: String)
        case noMatch
        case failed(String)
        /// The session ended or changed while listening.
        case sessionChanged
        case notRunning
    }

    /// Reads one anchor now.
    func anchorNow() async -> Result {
        guard !isListening else { return .failed("Already listening") }
        guard let before = context() else {
            status = "Needs alignment On, a station playing, and the speaker audible"
            return .notRunning
        }
        isListening = true
        status = "Listening to the speaker…"
        defer { isListening = false }
        // Which input hears the audio, and which output plays it, so a heal that worked on headphones can be explained.
        emit("[anchor] listening \(route())")

        let outcome = await race()
        switch outcome {
        case .noMatch:
            status = "No match"
            emit("[anchor] no match")
            return .noMatch
        case .error(let message):
            status = Self.explain(message)
            emit("[anchor] error \(message)")
            return .failed(status)
        case .matched(let match):
            // The program date and the feed rows are read as the result arrives, the instant the predicted position is.
            guard let after = context(), after.generation == before.generation else {
                status = "The station changed while listening; discarded"
                emit("[anchor] discarded: the session changed while listening")
                return .sessionChanged
            }
            let solution = SkewSolver.solve(match: match, programDate: after.programDate,
                                            candidates: after.candidates, currentSkew: after.currentSkew)
            let measurement: SkewMeasurement
            switch solution {
            case .measured(let found):
                measurement = found
            case .differentVersion(let feedTitle):
                status = "\"\(match.title)\" is a different version from the feed's \"\(feedTitle)\""
                emit("[anchor] heard=\"\(match.title) — \(match.artist)\" predicted=\(String(format: "%.1f", match.predictedOffset)) "
                    + "is a different version from the feed's \"\(feedTitle)\"; not used")
                return .differentVersion(heard: match.title, feed: feedTitle)
            case .notInFeed:
                status = "Heard \"\(match.title)\", which isn't in the tracklist yet"
                emit("[anchor] heard=\"\(match.title) — \(match.artist)\" not in the feed's \(after.candidates.count) rows")
                return .notInFeed(title: match.title, artist: match.artist)
            }
            emit(measurement.logLine())
            measurements.insert(measurement, at: 0)
            if measurements.count > Self.maxKept { measurements.removeLast(measurements.count - Self.maxKept) }
            status = String(format: "Anchored: skew %.1f s", measurement.skew)
            return .measured(measurement)
        }
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

    /// The audio route the microphone listens on, for the log: `in=[type name] out=[type name]`.
    static func routeDescription() -> String {
        let route = AVAudioSession.sharedInstance().currentRoute
        func describe(_ ports: [AVAudioSessionPortDescription]) -> String {
            ports.map { "\($0.portType.rawValue) \"\($0.portName)\"" }.joined(separator: ", ")
        }
        return "in=[\(describe(route.inputs))] out=[\(describe(route.outputs))]"
    }

    /// The live session's program date, feed rows and skew. Nil without a session or a valid player clock.
    static func currentContext() -> HealContext? {
        guard let session = RadioPlaybackSession.active, !session.isStopped,
              let programDate = session.currentProgramDate() else { return nil }
        let rows = session.feedRows.compactMap { occurrence -> SkewCandidate? in
            guard let title = occurrence.title, let playedAt = occurrence.playedAt else { return nil }
            return SkewCandidate(title: title, artist: occurrence.artist ?? "", playedAt: playedAt)
        }
        return HealContext(generation: session.generation, stationId: session.stationId, programDate: programDate,
                           candidates: rows, currentSkew: session.appliedSkew ?? AlignmentSkewStore.shared.skew(for: session.stationId))
    }
}
#endif
