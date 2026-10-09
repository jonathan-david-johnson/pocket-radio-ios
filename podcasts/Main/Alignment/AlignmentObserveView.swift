#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import SwiftUI
import PocketCastsUtils

/// Reads the active alignment session for the Debug screen. It never assigns `onSnapshot`
/// (the session's owner does) and publishes nothing to the listener.
@MainActor
final class AlignmentObserveViewModel: ObservableObject {
    struct Row: Equatable {
        let label: String
        let value: String
    }

    private let store: ObserveSwitchStore
    private let sessionProvider: @MainActor () -> RadioPlaybackSession?
    private let timeZone: TimeZone

    @Published private(set) var statusText: String? = "No active session"
    @Published private(set) var sessionRows: [Row] = []
    @Published private(set) var monitorRows: [Row] = []
    @Published private(set) var verdictLines: [String] = []

    init(store: ObserveSwitchStore = .shared,
         sessionProvider: @escaping @MainActor () -> RadioPlaybackSession? = { RadioPlaybackSession.active },
         timeZone: TimeZone = .current) {
        self.store = store
        self.sessionProvider = sessionProvider
        self.timeZone = timeZone
    }

    var isObserveOn: Bool {
        get { store.isObserveOn }
        set { objectWillChange.send(); store.isObserveOn = newValue }
    }

    var pollDriver: AlignmentPollDriver {
        get { store.pollDriver }
        set { objectWillChange.send(); store.pollDriver = newValue }
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
    @State private var timer: Timer?

    var body: some View {
        List {
            Section {
                Toggle("Observe", isOn: Binding(get: { model.isObserveOn }, set: { model.isObserveOn = $0 }))
                Picker("Poll driver", selection: Binding(get: { model.pollDriver }, set: { model.pollDriver = $0 })) {
                    Text("Timer").tag(AlignmentPollDriver.timer)
                    Text("Playback ticks").tag(AlignmentPollDriver.playbackTicks)
                }
            } footer: {
                Text("Takes effect the next time a station starts. Observe plays KCRW's HLS stream, which has no song titles in the player. Nothing is published.")
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
