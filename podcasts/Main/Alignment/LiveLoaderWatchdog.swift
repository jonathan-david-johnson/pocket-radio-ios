#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils

/// Detects a live HLS item that has stopped loading segments while it keeps playing from its buffer.
///
/// A healthy live window gains a segment every target duration, so the end of the loaded range keeps moving.
/// When it stops moving while the player is playing, the loader has stopped. On KCRW this comes about two minutes
/// before the buffer runs out and AVPlayer stalls (ADR 0011).
struct LiveLoaderWatchdog {
    enum Verdict: Equatable {
        case healthy
        /// The loaded end has not grown for this long while playing.
        case stopped(for: TimeInterval)
    }

    /// How long the loaded end may stay still while playing. A hypothesis to test on the phone (ADR 0011).
    static let stallThreshold: TimeInterval = 20
    /// Smaller growth than this, measured from where the count started, is no growth.
    static let minimumGrowth: Double = 0.5
    /// A longer gap between samples restarts the count. A periodic time observer is silent while paused.
    static let maximumSampleGap: TimeInterval = 3

    private var lastSampleAt: TimeInterval?
    private var referenceEnd: Double?
    private var stillSince: TimeInterval?

    /// Takes one sample and reports whether loading has stopped.
    /// - Parameters:
    ///   - now: A monotonic time in seconds.
    ///   - playing: True if the player is playing; false otherwise. Only playing time counts.
    ///   - loadedEnd: The end of the loaded range that contains the playhead, in media seconds, or nil if none.
    mutating func sample(now: TimeInterval, playing: Bool, loadedEnd: Double?) -> Verdict {
        defer { lastSampleAt = now }
        let gap = lastSampleAt.map { now - $0 } ?? .infinity
        guard playing, let loadedEnd, loadedEnd.isFinite, now.isFinite, gap <= Self.maximumSampleGap,
              let referenceEnd, let stillSince else {
            restart(at: now, end: playing ? loadedEnd : nil)
            return .healthy
        }
        // Growth restarts the count. So does a loaded end that moved back: the item or its timeline changed.
        if loadedEnd > referenceEnd + Self.minimumGrowth || loadedEnd < referenceEnd - Self.minimumGrowth {
            restart(at: now, end: loadedEnd)
            return .healthy
        }
        let still = now - stillSince
        return still >= Self.stallThreshold ? .stopped(for: still) : .healthy
    }

    mutating func reset() {
        lastSampleAt = nil
        referenceEnd = nil
        stillSince = nil
    }

    private mutating func restart(at now: TimeInterval, end: Double?) {
        referenceEnd = end.flatMap { $0.isFinite ? $0 : nil }
        stillSince = referenceEnd == nil ? nil : now
    }
}

/// Limits how often a play may replace its item.
struct KCRWReconnectBudget {
    /// Both values are hypotheses (ADR 0011). One Bluetooth session lost its loader three times in about 8 minutes.
    static let minimumInterval: TimeInterval = 60
    static let maximumPerPlay = 3

    private(set) var used = 0
    private var lastAt: TimeInterval?

    func allows(now: TimeInterval) -> Bool {
        guard used < Self.maximumPerPlay else { return false }
        guard let lastAt else { return true }
        return now - lastAt >= Self.minimumInterval
    }

    var isExhausted: Bool { used >= Self.maximumPerPlay }

    mutating func record(now: TimeInterval) {
        used += 1
        lastAt = now
    }
}

/// Watches one play of KCRW's aligned HLS stream and asks its owner to replace the item when loading stops.
///
/// Use it from the main thread. `attach(to:)` samples the player once a second. The `replace` closure does the
/// replacement and returns false if the player should no longer be playing. A refusal spends no budget; the count
/// starts again, so it is retried only after another full threshold. Call `invalidate()` when the play ends.
final class KCRWLoaderRecovery {
    private(set) var budget = KCRWReconnectBudget()
    private var watchdog = LiveLoaderWatchdog()
    private let emit: (String) -> Void
    private let replace: () -> Bool
    /// True once this stop's reason for not replacing has been logged, so it is logged once, not every second.
    private var reportedThisStop = false
    private var isInvalid = false
    private weak var player: AVPlayer?
    private var token: Any?

    init(emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) }, replace: @escaping () -> Bool) {
        self.emit = emit
        self.replace = replace
    }

    deinit {
        if let player, let token { player.removeTimeObserver(token) }
    }

    func attach(to player: AVPlayer) {
        guard self.player == nil, !isInvalid else { return }
        self.player = player
        token = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 1, preferredTimescale: 600),
                                               queue: .main) { [weak self, weak player] _ in
            guard let self, let player else { return }
            let ahead = player.currentItem.flatMap {
                AlignmentProbeLog.forwardBuffer(loadedRanges: $0.loadedTimeRanges.map(\.timeRangeValue),
                                                current: $0.currentTime())
            }
            let current = player.currentItem?.currentTime().seconds
            self.sample(now: ProcessInfo.processInfo.systemUptime, playing: player.timeControlStatus == .playing,
                        loadedEnd: ahead.flatMap { a in current.map { $0 + a } }, bufferAhead: ahead)
        }
    }

    func invalidate() {
        isInvalid = true
        if let player, let token { player.removeTimeObserver(token) }
        token = nil
        player = nil
    }

    func sample(now: TimeInterval, playing: Bool, loadedEnd: Double?, bufferAhead: Double?) {
        guard !isInvalid else { return }
        guard case let .stopped(still) = watchdog.sample(now: now, playing: playing, loadedEnd: loadedEnd) else {
            reportedThisStop = false
            return
        }
        let detail = String(format: "loader stopped for %.0f s, buffer %.1f s", still, bufferAhead ?? -1)
        guard budget.allows(now: now) else {
            if !reportedThisStop {
                reportedThisStop = true
                let reason = budget.isExhausted
                    ? "budget used (\(budget.used)/\(KCRWReconnectBudget.maximumPerPlay))" : "waiting for the interval"
                emit("[recovery] \(detail); \(reason)")
            }
            return
        }
        emit("[recovery] \(detail); replace n=\(budget.used + 1)/\(KCRWReconnectBudget.maximumPerPlay)")
        if replace() {
            budget.record(now: now)
        } else {
            emit("[recovery] replace refused: the player is not meant to be playing")
        }
        watchdog.reset()
        reportedThisStop = false
    }
}
#endif
