import Foundation
import OSLog

private let lyricLog = Logger(subsystem: "com.jdj.pocketradio", category: "Lyrics")

protocol LyricSyncControllerDelegate: AnyObject {
    func lyricSyncController(_ c: LyricSyncController, didUpdateHeaderText text: String)
    func lyricSyncController(_ c: LyricSyncController, didChangeStatus status: LyricSyncController.LyricStatus)
    func lyricSyncController(_ c: LyricSyncController, didUpdateNowPlayingAlbum text: String)
}

extension LyricSyncControllerDelegate {
    func lyricSyncController(_ c: LyricSyncController, didUpdateNowPlayingAlbum text: String) {}
}

/// Where saved per-station lyric offsets live. The production store is Supabase through
/// `RadioFavoritesManager`; tests inject a fake so nothing touches the real `lyric_offsets` table.
protocol LyricOffsetStore {
    func fetchOffsets() async -> [String: Int]
    func savedOffset(stationId: String) -> Int?
    func saveOffset(stationId: String, seconds: Int) async
}

struct RadioFavoritesLyricOffsetStore: LyricOffsetStore {
    func fetchOffsets() async -> [String: Int] {
        await RadioFavoritesManager.shared.fetchLyricOffsets()
    }

    func savedOffset(stationId: String) -> Int? {
        RadioFavoritesManager.shared.lyricOffsets[stationId]
    }

    func saveOffset(stationId: String, seconds: Int) async {
        await RadioFavoritesManager.shared.upsertLyricOffset(stationId: stationId, seconds: seconds)
    }
}

/// Owns the full lyrics state machine for a radio station:
/// fetch, LRC parse, and the synced-line timer. For an aligned station the timing is its skew
/// (`AlignmentSkewStore`), which the aligned session already applies to the song position, so the controller keeps
/// no offset of its own. For any other station (the wall-clock path) it keeps the saved per-station lyric offset
/// the listener nudges, saved to Supabase after a short debounce.
/// Callers (StationDetailViewController) become thin delegates that update UI only.
final class LyricSyncController {

    enum LyricStatus: Equatable {
        case none, fetching, found, notFound, betweenTracks
    }

    typealias LyricLoader = (_ artist: String, _ title: String, _ album: String?) async -> LyricsResult?
    /// Starts a repeating tick and returns the function that stops it.
    typealias TickScheduler = (@escaping () -> Void) -> () -> Void
    /// The media-clock lyric position for a station: nil unless applying and the clock is valid.
    typealias PositionSource = (_ stationId: String) -> (occurrenceID: String, seconds: Double)?

    weak var delegate: LyricSyncControllerDelegate?

    private(set) var status: LyricStatus = .none
    private(set) var currentSongKey: String?
    /// The aligned occurrence these lyrics were loaded for. Non-nil means Apply (ADR 0005); nil is
    /// the wall-clock path for Off.
    /// The listener's nudge on the wall-clock path (a station that is not aligned), in whole seconds. Zero for an
    /// aligned station, whose nudge is its skew.
    private(set) var lyricOffset: TimeInterval = 0
    private(set) var currentOccurrenceID: String?
    private(set) var lyricStartDate: Date?
    private(set) var currentEntryAlbum: String?

    var hasLyrics: Bool { status != .none }

    private let stationId: String
    private let stationDisplayTitle: String
    /// The lyric fetch both screens use, so station detail and full-screen lyrics get the same lines.
    let loader: LyricLoader
    private let offsetStore: LyricOffsetStore
    private let clock: () -> Date
    private let scheduleTicks: TickScheduler
    private let positionSource: PositionSource
    private let isApplying: (String) -> Bool
    private let skew: SkewAdjuster

    private var lyricLines: [LyricLine] = []
    private var lyricDuration: TimeInterval?
    private var cancelTicks: (() -> Void)?
    private var lyricFetchTask: Task<Void, Never>?
    private var lyricOffsetSaveTask: Task<Void, Never>?
    private var generation = 0
    private var tickObservers: [UUID: () -> Void] = [:]

    private static let introGrace = AlignedLyricsPolicy.introGrace
    private static let endGrace = AlignedLyricsPolicy.endGrace

    static let oneSecondTicks: TickScheduler = { handler in
        let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in handler() }
        return { timer.invalidate() }
    }

    init(stationId: String,
         stationDisplayTitle: String,
         loader: @escaping LyricLoader = { artist, title, album in
             await LyricsService.shared.fetch(artist: artist, title: title, album: album)
         },
         offsetStore: LyricOffsetStore = RadioFavoritesLyricOffsetStore(),
         clock: @escaping () -> Date = Date.init,
         scheduleTicks: @escaping TickScheduler = LyricSyncController.oneSecondTicks,
         positionSource: @escaping PositionSource = { AlignedConsumers.lyricPosition(stationId: $0) },
         isApplying: @escaping (String) -> Bool = { AlignedConsumers.isApplying(stationId: $0) },
         skew: SkewAdjuster = .production) {
        self.stationId = stationId
        self.stationDisplayTitle = stationDisplayTitle
        self.loader = loader
        self.offsetStore = offsetStore
        self.clock = clock
        self.scheduleTicks = scheduleTicks
        self.positionSource = positionSource
        self.isApplying = isApplying
        self.skew = skew
    }

    // MARK: - Public interface

    func load(entry: TracklistEntry?, occurrenceID: String? = nil) {
        guard let entry, !entry.title.isEmpty else { return }
        let key = songKey(for: entry)
        // A repeat play of the same song is a new occurrence and reloads.
        if currentSongKey == key && currentOccurrenceID == occurrenceID { return }

        lyricFetchTask?.cancel()
        resetState()
        let generation = self.generation
        currentSongKey = key
        currentOccurrenceID = occurrenceID
        currentEntryAlbum = entry.album
        setStatus(.fetching)
        delegate?.lyricSyncController(self, didUpdateHeaderText: "Fetching…")

        lyricFetchTask = Task { [weak self] in
            guard let self else { return }
            lyricLog.debug("fetch start: artist='\(entry.artist, privacy: .public)' title='\(entry.title, privacy: .public)'")
            // An aligned station never reads the saved offsets (ADR 0005); its nudge is its skew.
            async let offsetsTask: [String: Int] = occurrenceID == nil ? self.offsetStore.fetchOffsets() : [:]
            let result = await self.loader(entry.artist, entry.title, entry.album)
            lyricLog.debug("fetch done: result=\(result == nil ? "nil" : result!.hasSynced ? "synced(\(result!.lines.count)lines)" : result!.plain != nil ? "plain" : "empty", privacy: .public) cancelled=\(Task.isCancelled)")
            _ = await offsetsTask
            guard !Task.isCancelled else {
                lyricLog.debug("task cancelled after fetch — discarding result")
                return
            }
            await MainActor.run {
                guard self.currentSongKey == key, self.generation == generation else {
                    lyricLog.debug("song key mismatch: expected '\(key, privacy: .public)' got '\(self.currentSongKey ?? "nil", privacy: .public)'")
                    return
                }
                if let occurrenceID {
                    guard self.currentOccurrenceID == occurrenceID, self.isApplying(self.stationId) else { return }
                }
                guard let result else {
                    self.delegate?.lyricSyncController(self, didUpdateHeaderText: "No lyrics found")
                    self.setStatus(.notFound)
                    return
                }
                if result.hasSynced {
                    self.lyricLines = result.lines
                    self.lyricDuration = result.duration
                    if occurrenceID != nil {
                        self.setStatus(.found)
                        self.startApplyTimer()
                        return
                    }
                    self.lyricOffset = TimeInterval(self.offsetStore.savedOffset(stationId: self.stationId) ?? 0)
                    lyricLog.info("restored offset \(self.lyricOffset, format: .fixed(precision: 1))s station=\(self.stationId, privacy: .public)")
                    let elapsed = entry.playedAt.map { self.clock().timeIntervalSince($0) } ?? 0
                    self.lyricStartDate = entry.playedAt ?? self.clock().addingTimeInterval(-elapsed)
                    self.setStatus(.found)
                    self.startTimer(initialElapsed: max(0, elapsed))
                } else if let plain = result.plain, let firstLine = self.firstNonEmptyLine(plain) {
                    self.delegate?.lyricSyncController(self, didUpdateHeaderText: "♪ " + firstLine)
                    self.setStatus(.found)
                } else {
                    self.delegate?.lyricSyncController(self, didUpdateHeaderText: "No lyrics found")
                    self.setStatus(.notFound)
                }
            }
        }
    }

    /// The station's skew, for the full-screen lyrics label.
    var currentSkew: TimeInterval { skew.current(stationId) }

    /// Moves the song position by `delta` seconds and returns the new offset.
    ///
    /// Aligned: the station's skew moves the other way (a larger skew means the song started later in the stream, so an
    /// earlier position), and the return value is the new skew. The session takes it at once, so the title, the artwork
    /// and the lyric line move together.
    ///
    /// Not aligned (the wall-clock path): the saved per-station lyric offset moves by `delta` (callers use whole
    /// seconds) and the return value is that offset. It is saved after a short debounce.
    @discardableResult
    func adjustOffset(by delta: TimeInterval) -> TimeInterval {
        if currentOccurrenceID != nil {
            guard isApplying(stationId) else { return skew.current(stationId) }
            let value = skew.nudge(stationId, -delta)
            lyricLog.info("skew = \(value, format: .fixed(precision: 1))s  station=\(self.stationId, privacy: .public)")
            applyTick()
            return value
        }
        lyricOffset += delta
        if let startDate = lyricStartDate {
            tick(at: clock().timeIntervalSince(startDate) + lyricOffset)
        }
        lyricLog.info("lyric offset = \(self.lyricOffset, format: .fixed(precision: 1))s  song=\(self.currentSongKey ?? "—", privacy: .public)")

        guard !stationId.isEmpty else { return lyricOffset }
        lyricOffsetSaveTask?.cancel()
        let seconds = Int(lyricOffset)
        lyricOffsetSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 800_000_000)
            if Task.isCancelled { return }
            guard let self else { return }
            await self.offsetStore.saveOffset(stationId: self.stationId, seconds: seconds)
            lyricLog.info("saved offset \(seconds)s station=\(self.stationId, privacy: .public)")
        }
        return lyricOffset
    }

    /// Waits for the in-flight fetch to finish. For tests.
    func waitForFetch() async {
        await lyricFetchTask?.value
    }

    /// Apply: the media-clock song position, the position every lyric view should highlight. Nil when not
    /// applying, when the clock gives no valid position, or when the position belongs to an occurrence other
    /// than the one the lyrics were loaded for.
    func alignedPosition() -> TimeInterval? {
        guard let occurrenceID = currentOccurrenceID, isApplying(stationId),
              let position = positionSource(stationId), position.occurrenceID == occurrenceID else { return nil }
        return position.seconds
    }

    /// Apply: calls `handler` after every tick of this controller's clock, so full-screen lyrics
    /// reads the same position without a timer of its own (ADR 0005). Returns the function that
    /// unsubscribes. Observers outlive `load` and `stop`; their owner unsubscribes.
    func observeTicks(_ handler: @escaping () -> Void) -> () -> Void {
        let id = UUID()
        tickObservers[id] = handler
        return { [weak self] in self?.tickObservers[id] = nil }
    }

    func stop() {
        resetState()
    }

    func songKey(for entry: TracklistEntry) -> String {
        "\(entry.artist.lowercased())|\(entry.title.lowercased())"
    }

    // MARK: - Private

    private func setStatus(_ newStatus: LyricStatus) {
        guard newStatus != status else { return }
        status = newStatus
        delegate?.lyricSyncController(self, didChangeStatus: newStatus)
    }

    private func startTimer(initialElapsed: TimeInterval) {
        tick(at: initialElapsed + lyricOffset)
        cancelTicks = scheduleTicks { [weak self] in
            guard let self, let startDate = self.lyricStartDate else { return }
            self.tick(at: self.clock().timeIntervalSince(startDate) + self.lyricOffset)
        }
    }

    private func startApplyTimer() {
        applyTick()
        cancelTicks = scheduleTicks { [weak self] in
            self?.applyTick()
            self?.tickObservers.values.forEach { $0() }
        }
    }

    /// Apply: the line comes from the media clock, never the wall clock.
    private func applyTick() {
        // The position source is nil once the session stops applying, so a stopped session falls through to
        // the no-highlight state, like the full-screen view on the same clock.
        guard let occurrenceID = currentOccurrenceID else { return }
        guard let position = positionSource(stationId), position.occurrenceID == occurrenceID else {
            // No valid clock, or a position for another occurrence: no timed highlight and no
            // wall-clock fallback (ADR 0005).
            showBetweenTracks(writesAlbum: false)
            return
        }
        tick(at: position.seconds, writesAlbum: false)
    }

    private func showBetweenTracks(writesAlbum: Bool) {
        guard status != .betweenTracks else { return }
        delegate?.lyricSyncController(self, didUpdateHeaderText: "♪ " + stationDisplayTitle)
        if writesAlbum {
            delegate?.lyricSyncController(self, didUpdateNowPlayingAlbum: currentEntryAlbum ?? stationDisplayTitle)
        }
        setStatus(.betweenTracks)
    }

    private func tick(at offset: TimeInterval, writesAlbum: Bool = true) {
        guard let first = lyricLines.first, let last = lyricLines.last else { return }
        let songEnd = lyricDuration ?? (last.timestamp + Self.endGrace)
        if offset < first.timestamp - Self.introGrace || offset > songEnd + Self.endGrace {
            showBetweenTracks(writesAlbum: writesAlbum)
            return
        }
        let result = LyricsResult(lines: lyricLines, plain: nil)
        if let line = LyricsService.shared.currentLine(in: result, at: offset) {
            delegate?.lyricSyncController(self, didUpdateHeaderText: "♪ " + line.text)
            if writesAlbum {
                delegate?.lyricSyncController(self, didUpdateNowPlayingAlbum: line.text)
            }
            if status != .found { setStatus(.found) }
        }
    }

    private func resetState() {
        generation += 1
        currentOccurrenceID = nil
        cancelTicks?()
        cancelTicks = nil
        lyricFetchTask?.cancel()
        lyricFetchTask = nil
        lyricOffsetSaveTask?.cancel()
        lyricOffsetSaveTask = nil
        lyricLines = []
        lyricStartDate = nil
        currentSongKey = nil
        lyricDuration = nil
        lyricOffset = 0
        status = .none
    }

    private func firstNonEmptyLine(_ text: String) -> String? {
        text.components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }
}

/// How lyric screens read and move a station's skew. Tests replace it so nothing touches the saved skews.
struct SkewAdjuster {
    let current: (String) -> TimeInterval
    /// Adds the delta and returns the new skew.
    let nudge: (String, TimeInterval) -> TimeInterval

    static let production = SkewAdjuster(
        current: { AlignmentSkewStore.shared.skew(for: $0) },
        nudge: { AlignmentSkewStore.shared.nudge(by: $1, for: $0) })
}
