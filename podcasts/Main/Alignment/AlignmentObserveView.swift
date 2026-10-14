#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import SwiftUI
import PocketCastsUtils

/// Reads the active alignment session and the published state for the Debug screen. It never
/// assigns `onSnapshot` (the session's owner does) and publishes nothing to the listener.
@MainActor
final class AlignmentObserveViewModel: ObservableObject {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    private let store: AlignmentSwitchStore
    private let skewStore: AlignmentSkewStore
    private let sessionProvider: @MainActor () -> RadioPlaybackSession?
    private let alignedState: AlignedNowPlayingState
    private let timeZone: TimeZone

    @Published private(set) var statusText: String? = "No active session"
    @Published private(set) var sessionRows: [Row] = []
    @Published private(set) var monitorRows: [Row] = []
    @Published private(set) var verdictLines: [String] = []

    init(store: AlignmentSwitchStore = .shared,
         skewStore: AlignmentSkewStore = .shared,
         sessionProvider: @escaping @MainActor () -> RadioPlaybackSession? = { RadioPlaybackSession.active },
         alignedState: AlignedNowPlayingState = .shared,
         timeZone: TimeZone = .current) {
        self.store = store
        self.skewStore = skewStore
        self.sessionProvider = sessionProvider
        self.alignedState = alignedState
        self.timeZone = timeZone
    }

    var mode: AlignmentMode {
        get { store.mode }
        set { objectWillChange.send(); store.mode = newValue }
    }

    /// What the adapter last published for the listener: a song, the unavailable state, or none.
    var publishedText: String {
        switch alignedState.current {
        case .song(let song)?: return "song: \(song.title) — \(song.artist)"
        case .unavailable(_, let reason)?: return "unavailable: \(reason)"
        case nil: return "none"
        }
    }

    /// The skew in use for the live session's station, or nil without one.
    var skew: Double? {
        sessionProvider().map { skewStore.skew(for: $0.stationId) }
    }

    /// Debug: sets the live station's skew, to start a heal from a known wrong value. Takes effect at once.
    func setSkew(_ value: Double) {
        guard let id = sessionProvider()?.stationId else { return }
        objectWillChange.send()
        skewStore.set(value, for: id)
    }

    func addToSkew(_ delta: Double) {
        guard let id = sessionProvider()?.stationId else { return }
        objectWillChange.send()
        skewStore.nudge(by: delta, for: id)
    }

    /// Forgets the saved skew, so the station is back at its seed.
    func resetSkewToSeed() {
        guard let id = sessionProvider()?.stationId else { return }
        objectWillChange.send()
        skewStore.reset(stationId: id)
    }

    func refresh() {
        guard let session = sessionProvider() else {
            statusText = "No active session"
            sessionRows = []
            monitorRows = []
            verdictLines = []
            return
        }
        statusText = nil
        let s = session.snapshot
        sessionRows = [
            Row(label: "Generation", value: AlignmentProbeLog.shortID(s.generation)),
            Row(label: "Endpoint", value: s.endpoint),
            Row(label: "Clock", value: s.clockValid ? "valid" : "invalid"),
            Row(label: "Program date", value: formatProgramDate(s.programDate)),
            Row(label: "Media seconds", value: Self.seconds(s.mediaSeconds)),
            Row(label: "Candidate", value: s.candidate ?? "none"),
            Row(label: "Song seconds", value: Self.seconds(s.songSeconds)),
            Row(label: "Reason", value: s.reason),
            Row(label: "Published", value: publishedText),
            Row(label: "Feed status", value: s.feedStatus),
            Row(label: "Cache age", value: Self.seconds(s.cacheAgeSeconds, suffix: " s")),
            Row(label: "History count", value: "\(s.historyCount)"),
            Row(label: "Last poll", value: Self.seconds(s.lastPollElapsed, suffix: " s")),
            Row(label: "Feed top (evidence only)", value: s.feedTop ?? "none")
        ]

        // Judge as of now on the session's clock, so a sampler or poller that stopped shows as a tail gap.
        let end = session.currentElapsed
        let summary = session.summary(endElapsed: end)
        let verdict = session.lockedRunVerdict(endElapsed: end)
        func f1(_ v: Double) -> String { String(format: "%.1f s", v) }
        func rate(_ v: Float?) -> String { v.map { String(format: "%.2f", $0) } ?? "none" }
        var rows = [
            Row(label: "Samples", value: "\(summary.sampleCount)"),
            Row(label: "Poll attempts / failures", value: "\(summary.pollAttempts) / \(summary.pollFailures)"),
            Row(label: "Longest sample gap", value: f1(summary.longestSampleGap)),
            Row(label: "Longest poll gap", value: f1(summary.longestPollAttemptGap)),
            Row(label: "Rate range", value: "\(rate(summary.minRate))-\(rate(summary.maxRate))")
        ]
        for window in summary.speedWindows {
            let ratio = window.ratio.map { String(format: "%.3f", $0) } ?? "none"
            rows.append(Row(label: "Speed window @\(Int(window.start)) s", value: ratio))
        }
        rows.append(Row(label: "Verdict", value: verdict.passed ? "PASS" : "FAIL"))
        monitorRows = rows
        verdictLines = verdict.failures
    }

    func formatProgramDate(_ date: Date?) -> String {
        guard let date else { return "none" }
        func format(_ zone: TimeZone) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = zone
            f.dateFormat = "HH:mm:ss"
            return f.string(from: date)
        }
        let utc = format(TimeZone(identifier: "UTC")!)
        if timeZone.secondsFromGMT(for: date) == 0 { return "\(utc) UTC" }
        return "\(format(timeZone)) local / \(utc) UTC"
    }

    private static func seconds(_ value: Double?, suffix: String = "") -> String {
        value.map { String(format: "%.1f", $0) + suffix } ?? "none"
    }
}

struct AlignmentObserveView: View {
    @StateObject private var model = AlignmentObserveViewModel()
    @ObservedObject private var healer = SkewHealer.shared
    @ObservedObject private var anchors = SkewHealer.shared.anchorProbe
    @State private var timer: Timer?

    var body: some View {
        List {
            Section {
                Picker("Alignment", selection: Binding(get: { model.mode }, set: { model.mode = $0 })) {
                    Text("Off").tag(AlignmentMode.off)
                    Text("On").tag(AlignmentMode.on)
                }
                .pickerStyle(.segmented)
            } footer: {
                Text("Takes effect the next time a station starts. On plays KCRW's HLS stream and drives the lock screen and players from the aligned song. Off is the old behavior, with no skew and no heal.")
            }

            Section {
                if let skew = model.skew {
                    Text(String(format: "Skew: %.1f s", skew)).font(.subheadline.weight(.semibold))
                    HStack {
                        Button("Set 0") { model.setSkew(0) }
                        Button("−60") { model.addToSkew(-60) }
                        Button("+60") { model.addToSkew(60) }
                        Button("Seed") { model.resetSkewToSeed() }
                    }
                    .buttonStyle(.bordered)
                } else {
                    Text("Start KCRW with alignment On to see its skew.").font(.footnote)
                }
                Text(healer.lastResult).font(.footnote)
                Button(anchors.isListening ? "Listening…" : "Heal now") { Task { await healer.heal { _ in } } }
                    .disabled(healer.isRunning)
                Text(anchors.status).font(.footnote)
                ForEach(Array(anchors.measurements.prefix(8).enumerated()), id: \.offset) { _, m in
                    Text(String(format: "%+.1f s | skew %.1f | %@", m.change, m.skew, m.shazam.title))
                        .font(.footnote)
                }
            } header: {
                Text("Skew")
            } footer: {
                Text("The skew is the difference between the stream's timeline and the tracklist's. Heal listens to the speaker with ShazamKit, finds the heard song in the tracklist, and sets it from any starting value. The buttons set a wrong skew to test the heal. The lyrics page's + and − fine-tune it by 0.5 s.")
            }

            Section("Active session") {
                if let status = model.statusText {
                    Text(status)
                } else {
                    ForEach(model.sessionRows, id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                }
            }

            if !model.monitorRows.isEmpty {
                Section("Monitor") {
                    ForEach(model.monitorRows, id: \.label) { row in
                        LabeledContent(row.label, value: row.value)
                    }
                    ForEach(model.verdictLines, id: \.self) { Text($0).font(.footnote) }
                }
            }

            Section {
                Button("Flush log to file") { FileLog.shared.forceFlush() }
            }
        }
        .navigationTitle("KCRW alignment")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            model.refresh()
            timer?.invalidate()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in model.refresh() }
        }
        .onDisappear {
            timer?.invalidate()
            timer = nil
        }
    }
}
#endif
