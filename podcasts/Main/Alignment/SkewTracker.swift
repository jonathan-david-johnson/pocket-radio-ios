#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import Foundation
import PocketCastsUtils

/// A measure-only loop: anchors the playing song every 30 s or so and logs what ShazamKit says, and changes nothing. It is
/// for finding out how the stream's timing moves inside a song (an edit with a cut, a different recording matched), before
/// deciding whether the skew should be re-measured continuously. Debug only. Each anchor is logged by the probe as
/// `[anchor] heard=…`; this adds `[track]` lines for the loop and for any jump between two anchors of one song.
@MainActor
final class SkewTracker: ObservableObject {
    static let shared = SkewTracker()

    /// Seconds between the end of one listen and the start of the next.
    static let gap: TimeInterval = 25
    /// A change between two anchors of one song, in seconds, that is worth a `[track] jump` line.
    static let jumpThreshold = 1.0

    @Published private(set) var isOn = false
    @Published private(set) var lastLine = "Off"

    private let probe: @MainActor () -> ShazamAnchorProbe
    private let healerBusy: @MainActor () -> Bool
    private let sessionActive: @MainActor () -> Bool
    private let emit: (String) -> Void
    private let sleep: (TimeInterval) async -> Void
    private var task: Task<Void, Never>?
    private var last: (song: String, measurement: SkewMeasurement)?

    init(probe: @escaping @MainActor () -> ShazamAnchorProbe = { SkewHealer.shared.anchorProbe },
         healerBusy: @escaping @MainActor () -> Bool = { SkewHealer.shared.isRunning },
         sessionActive: @escaping @MainActor () -> Bool = { RadioPlaybackSession.active.map { !$0.isStopped } ?? false },
         emit: @escaping (String) -> Void = { FileLog.shared.addMessage($0) },
         sleep: @escaping (TimeInterval) async -> Void = { try? await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }) {
        self.probe = probe
        self.healerBusy = healerBusy
        self.sessionActive = sessionActive
        self.emit = emit
        self.sleep = sleep
    }

    func start() {
        guard !isOn else { return }
        isOn = true
        lastLine = "Tracking"
        last = nil
        emit("[track] on")
        task = Task { [weak self] in
            while let self, self.isOn, !Task.isCancelled {
                await self.step()
                await self.sleep(Self.gap)
            }
        }
    }

    func stop() {
        guard isOn else { return }
        isOn = false
        task?.cancel()
        task = nil
        lastLine = "Off"
        emit("[track] off")
    }

    /// One listen, unless a heal is running or no station is playing. Logs a jump when this anchor and the last one,
    /// both for the same song, differ by more than `jumpThreshold`.
    func step() async {
        guard sessionActive() else { lastLine = "Waiting for a station"; return }
        guard !healerBusy() else { lastLine = "Heal running"; return }
        let result = await probe().anchorNow()
        guard case .measured(let measurement) = result else {
            lastLine = "No anchor"
            return
        }
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
    }
}
#endif
