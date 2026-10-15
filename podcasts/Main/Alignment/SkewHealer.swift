#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils

/// The words shown while the timing recalibrates. Short, because they go in one header line.
enum HealMessage {
    static let anchorsNeeded = 3

    static func listening(_ n: Int) -> String { "Listening to the speaker… (\(n)/\(anchorsNeeded))" }

    /// What one anchor found. `change` is how far the skew in use is from the one the anchor implies.
    static func heard(change: Double, _ n: Int) -> String {
        let how: String
        if abs(change) < 0.5 {
            how = "In sync"
        } else if change > 0 {
            how = String(format: "Screen is %@ ahead of the audio", seconds(change))
        } else {
            how = String(format: "Audio is %@ ahead of the screen", seconds(-change))
        }
        return "\(how) (\(n)/\(anchorsNeeded))"
    }

    private static func seconds(_ value: Double) -> String {
        value >= 100 ? String(format: "%.0f s", value) : String(format: "%.1f s", value)
    }

    static func notInFeed(_ title: String) -> String { "\"\(title)\" isn't in the tracklist yet. Trying again…" }
    static func differentVersion(_ title: String) -> String { "\"\(title)\" is an edit or remix, so it can't set the timing. Trying again…" }
    static let onlyEditedVersions = "The songs playing are edits or remixes, which can't set the timing. Try again when a regular song plays."
    static let cancelled = "Calibration was cancelled. Try again."
    static let notRunning = "Start a station with alignment On first"
    static let sessionChanged = "The station changed. Try again."
    static let gaveUp = "Couldn't calibrate. Check the speaker is audible and try again."
    static let outOfRange = "The result was out of range, so nothing changed. Try again."

    static func failed(_ status: String) -> String { "\(status). Trying again…" }
    static func inSync(_ skew: Double) -> String { String(format: "In sync. Skew %.1f s", skew) }
    static func corrected(by change: Double, to skew: Double) -> String {
        String(format: "Timing corrected by %+.1f s. Skew %.1f s", change, skew)
    }
}

/// The heal: listens to the speaker for a few anchors, and when three agree sets the station's skew to their median.
/// It replaces the skew, including any fine-tune. It works from any starting skew (see `SkewSolver`). Debug only.
@MainActor
final class SkewHealer: ObservableObject {
    static let shared = SkewHealer()
    static let maxAttempts = 8
    /// Anchors must agree within this many seconds to count toward the three.
    static let agreement = 1.0
    /// Seconds between one listen and the next. ShazamKit refuses a session opened right after another one closes
    /// (it answers "Missing entitlements" at once), so the heal waits, as the earlier self-healing loop did.
    static let gap: TimeInterval = 5

    @Published private(set) var lastResult = "Not run"
    @Published private(set) var isRunning = false

    private let probe: ShazamAnchorProbe
    private let store: AlignmentSkewStore
    private let session: @MainActor () -> (generation: UUID, stationId: String)?
    private let now: () -> TimeInterval
    private let emit: (String) -> Void
    private let sleep: (TimeInterval) async -> Void

    init(probe: ShazamAnchorProbe? = nil,
         store: AlignmentSkewStore = .shared,
         session: @escaping @MainActor () -> (generation: UUID, stationId: String)? = {
             RadioPlaybackSession.active.flatMap { $0.isStopped ? nil : ($0.generation, $0.stationId) }
         },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.probe = probe ?? ShazamAnchorProbe()
        self.store = store
        self.session = session
        self.now = now
        self.emit = emit
        self.sleep = sleep
    }

    /// The probe, so the Debug screen shows the same anchors.
    var anchorProbe: ShazamAnchorProbe { probe }

    /// Listens until three anchors agree, then saves their median as the station's skew. `report` receives the
    /// progress lines. Returns true when it set a skew or confirmed the one in use.
    @discardableResult
    func heal(report: @escaping @MainActor (String) -> Void) async -> Bool {
        guard !isRunning else { return false }
        guard let started = session() else {
            report(HealMessage.notRunning)
            lastResult = HealMessage.notRunning
            return false
        }
        isRunning = true
        defer { isRunning = false }
        emit("[heal] started")

        var learner = OffsetLearner(config: Self.learnerConfig)
        var attempts = 0
        var skippedVersions = 0
        var agreed: Double?
        while agreed == nil, attempts < Self.maxAttempts {
            // A cancelled task makes every sleep return at once, so the listens would run back to back and ShazamKit
            // would refuse each one. Stop instead of burning the attempts.
            guard !Task.isCancelled else {
                emit("[heal] cancelled after \(attempts) tries")
                finish(HealMessage.cancelled, report)
                return false
            }
            attempts += 1
            report(HealMessage.listening(min(learner.anchors.count + 1, HealMessage.anchorsNeeded)))
            let result = await probe.anchorNow()
            guard session()?.generation == started.generation else {
                finish(HealMessage.sessionChanged, report)
                return false
            }
            switch result {
            case .measured(let measurement):
                learner.add(OffsetAnchor(time: now(), delta: measurement.skew))
                report(HealMessage.heard(change: measurement.change, learner.anchors.count))
                agreed = Self.agreedSkew(learner.anchors.map(\.delta))
            case .notInFeed(let title, _):
                report(HealMessage.notInFeed(title))
            case .differentVersion(let heard, _):
                skippedVersions += 1
                report(HealMessage.differentVersion(heard))
            case .noMatch:
                report(HealMessage.failed("No match"))
            case .failed(let message):
                report(HealMessage.failed(message))
            case .sessionChanged:
                finish(HealMessage.sessionChanged, report)
                return false
            case .notRunning:
                finish(HealMessage.notRunning, report)
                return false
            }
            if agreed == nil, attempts < Self.maxAttempts { await sleep(Self.gap) }
        }
        guard let skew = agreed else {
            emit("[heal] gave up after \(attempts) tries (\(skippedVersions) different versions)")
            finish(skippedVersions > 0 && learner.anchors.count < HealMessage.anchorsNeeded
                   ? HealMessage.onlyEditedVersions : HealMessage.gaveUp, report)
            return false
        }
        let before = store.skew(for: started.stationId)
        guard store.set(skew, for: started.stationId) else {
            emit("[heal] result \(String(format: "%.1f", skew)) s is out of range; nothing changed")
            finish(HealMessage.outOfRange, report)
            return false
        }
        let after = store.skew(for: started.stationId)
        emit("[heal] skew \(String(format: "%.1f", before)) -> \(String(format: "%.1f", after)) s")
        let change = after - before
        finish(abs(change) < 0.5 ? HealMessage.inSync(after) : HealMessage.corrected(by: change, to: after), report)
        return true
    }

    private func finish(_ message: String, _ report: @MainActor (String) -> Void) {
        lastResult = message
        report(message)
    }

    /// The median of the anchors, when at least three of them sit within `agreement` of it. A wrong-section match
    /// that is far from the rest cannot move it.
    static func agreedSkew(_ values: [Double]) -> Double? {
        guard values.count >= HealMessage.anchorsNeeded else { return nil }
        let median = OffsetLearner.median(values)
        let close = values.filter { abs($0 - median) <= agreement }
        guard close.count >= HealMessage.anchorsNeeded else { return nil }
        return OffsetLearner.median(close)
    }

    /// The learner only rejects anchors that fall far from the window. Its clamp is the skew's sanity limit.
    static let learnerConfig = OffsetLearnerConfig(maxCorrection: AlignmentSkewStore.limit)
}
#endif
