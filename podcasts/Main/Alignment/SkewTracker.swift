#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils

/// Anchors the playing song every 25 s or so, for as long as it is on.
///
/// `measure`: logs only. It finds out how the stream's timing moves inside a song (an edit with a cut, a different recording
/// matched). Each anchor is logged by the probe as `[anchor] heard=…`; this adds `[track]` lines for the loop and for any
/// jump between two anchors of one song.
///
/// `apply`: also keeps the timing right. For a station whose stamps differ song to song (KEXP), each new song gets its own
/// offset from the first anchor, and a song's offset is corrected when later anchors move it (a speed difference drifts a
/// song's position). One anchor that is close to the song's offset is believed; a big change waits for a second that agrees.
/// Nothing changes for a station with a single stream skew. Debug only (ADR 0010).
@MainActor
final class SkewTracker: ObservableObject {
    static let shared = SkewTracker()

    enum Mode: String, CaseIterable { case off, measure, apply }

    /// Seconds between the end of one listen and the start of the next.
    static let gap: TimeInterval = 25
    /// After two anchors in a row that found nothing to change, listen less often.
    static let steadyGap: TimeInterval = 60
    /// A song the feed has not listed yet is tried again sooner.
    static let feedGap: TimeInterval = 15
    /// A big change that has one anchor so far is confirmed sooner.
    static let confirmGap: TimeInterval = 8
    /// A change between two anchors of one song, in seconds, that is worth a `[track] jump` line.
    static let jumpThreshold = 1.0

    @Published private(set) var mode: Mode = .off
    @Published private(set) var lastLine = "Off"

    private let probe: @MainActor () -> ShazamAnchorProbe
    private let healerBusy: @MainActor () -> Bool
    private let activeStation: @MainActor () -> String?
    private let perSong: @MainActor () -> PerSongControl?
    private let store: AlignmentSkewStore
    private let emit: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    private let runsLoop: Bool
    private var task: Task<Void, Never>?
    private var last: (song: String, measurement: SkewMeasurement)?
    private var pending: [String: Double] = [:]
    private var steady = 0

    init(probe: @escaping @MainActor () -> ShazamAnchorProbe = { SkewHealer.shared.anchorProbe },
         healerBusy: @escaping @MainActor () -> Bool = { SkewHealer.shared.isRunning },
         activeStation: @escaping @MainActor () -> String? = {
             RadioPlaybackSession.active.flatMap { $0.isStopped ? nil : $0.stationId }
         },
         perSong: @escaping @MainActor () -> PerSongControl? = { PerSongControl.live() },
         store: AlignmentSkewStore = .shared,
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) },
         runsLoop: Bool = true) {
        self.runsLoop = runsLoop
        self.probe = probe
        self.healerBusy = healerBusy
        self.activeStation = activeStation
        self.perSong = perSong
        self.store = store
        self.emit = emit
        self.sleep = sleep
    }

    func set(mode newMode: Mode) {
        guard newMode != mode else { return }
        task?.cancel()
        task = nil
        mode = newMode
        last = nil
        pending = [:]
        steady = 0
        guard newMode != .off else {
            lastLine = "Off"
            emit("[track] off")
            return
        }
        lastLine = newMode == .apply ? "Auto-heal" : "Tracking"
        emit("[track] on mode=\(newMode.rawValue)")
        guard runsLoop else { return }
        task = Task { [weak self] in
            while let self, self.mode != .off, !Task.isCancelled {
                let wait = await self.step()
                await self.sleep(wait)
            }
        }
    }

    /// One listen, unless a heal is running or no station is playing. Returns how long to wait before the next.
    @discardableResult
    func step() async -> TimeInterval {
        guard let stationId = activeStation() else { lastLine = "Waiting for a station"; return Self.gap }
        guard !healerBusy() else { lastLine = "Heal running"; return Self.gap }
        let result = await probe().anchorNow()
        switch result {
        case .measured(let measurement):
            return handle(measurement, stationId: stationId)
        case .notInFeed(let title, _):
            lastLine = "\"\(title)\" is not in the tracklist yet"
            return Self.feedGap
        case .differentVersion(let heard, _):
            lastLine = "\"\(heard)\" is an edit"
            return Self.gap
        default:
            lastLine = "No anchor"
            return Self.gap
        }
    }

    private func handle(_ measurement: SkewMeasurement, stationId: String) -> TimeInterval {
        let song = "\(measurement.entry.title)|\(measurement.entry.playedAt.timeIntervalSince1970)"
        if let previous = last, previous.song == song {
            let change = measurement.skew - previous.measurement.skew
            if abs(change) > Self.jumpThreshold {
                emit(String(format: "[track] jump %@ %+.1f s (skew %.1f -> %.1f) between references %.1f s and %.1f s sid %@ -> %@",
                            measurement.entry.title, change, previous.measurement.skew, measurement.skew,
                            previous.measurement.shazam.predictedOffset, measurement.shazam.predictedOffset,
                            previous.measurement.shazam.shazamID ?? "-", measurement.shazam.shazamID ?? "-"))
            }
        }
        last = (song, measurement)
        lastLine = String(format: "%@: skew %.1f", measurement.entry.title, measurement.skew)
        guard mode == .apply, let control = perSong(), let key = measurement.entry.rowKey else { return Self.gap }

        let current = control.effective(key)
        let diff = measurement.skew - current
        if abs(diff) < SkewHealer.deadband {
            pending[key] = nil
            steady += 1
            return steady >= 2 ? Self.steadyGap : Self.gap
        }
        steady = 0
        if abs(diff) <= SkewHealer.quickChange || pending[key].map({ abs($0 - measurement.skew) <= SkewHealer.agreement }) == true {
            let value = pending[key].map { ($0 + measurement.skew) / 2 } ?? measurement.skew
            pending[key] = nil
            if control.set(value, key) {
                // The stream skew follows as the default for the next song, which nobody has measured yet.
                store.set(value, for: stationId)
                emit(String(format: "[auto] %@ skew %.1f -> %.1f s (%+.1f)", measurement.entry.title, current, value, value - current))
                lastLine = String(format: "%@: corrected to %.1f", measurement.entry.title, value)
            }
            return Self.gap
        }
        pending[key] = measurement.skew
        emit(String(format: "[auto] %@ wants %.1f s, %+.1f from %.1f; waiting for a second anchor", measurement.entry.title,
                    measurement.skew, diff, current))
        return Self.confirmGap
    }
}
#endif
