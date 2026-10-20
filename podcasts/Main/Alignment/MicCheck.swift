#if DEBUG && !os(watchOS) && !APPCLIP && !os(tvOS)
import AVFoundation
import Foundation
import PocketCastsUtils

/// A diagnostic, not part of the heal: records a few seconds from the phone's microphone and logs how loud it is and
/// which input and output the audio session had. Run it while a station plays, on headphones, on the speaker, and with
/// nothing playing. If the level with headphones on is the same as the level with nothing playing, the microphone is not
/// hearing the headphones, so a heal that still matches heard something else (ADR 0010).
@MainActor
final class MicCheck: ObservableObject {
    static let shared = MicCheck()

    struct Summary: Equatable {
        let samples: Int
        let min: Double
        let average: Double
        let max: Double
    }

    @Published private(set) var status = "Not run"
    @Published private(set) var isRunning = false

    /// Levels are in dBFS: 0 is full scale, about −160 is silence. `AVAudioRecorder` meters return −160 for silence.
    static func summarize(_ levels: [Double]) -> Summary? {
        let usable = levels.filter { $0.isFinite }
        guard !usable.isEmpty else { return nil }
        // The average is of power, not of dB, so a loud moment counts as it sounds.
        let power = usable.map { pow(10, $0 / 10) }.reduce(0, +) / Double(usable.count)
        return Summary(samples: usable.count, min: usable.min() ?? 0, average: 10 * log10(power), max: usable.max() ?? 0)
    }

    static func logLine(label: String, route: String, summary: Summary?) -> String {
        guard let summary else { return "[miccheck] \(label) \(route) level=unavailable" }
        return String(format: "[miccheck] %@ %@ level avg=%.1f min=%.1f max=%.1f dBFS samples=%d",
                      label, route, summary.average, summary.min, summary.max, summary.samples)
    }

    /// Records for `seconds` and logs the result. `label` says the condition ("headphones", "speaker", "silence").
    func run(label: String, seconds: Double = 6) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }
        status = "Listening for \(Int(seconds)) s…"

        let session = AVAudioSession.sharedInstance()
        let previous = (session.category, session.mode, session.categoryOptions)
        defer { try? session.setCategory(previous.0, mode: previous.1, options: previous.2) }
        do {
            // The speaker option keeps a phone that is playing on its speaker from moving to the earpiece.
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .allowBluetoothA2DP, .defaultToSpeaker])
            try session.setActive(true)
        } catch {
            status = "Could not set up the microphone"
            FileLog.shared.addMessage(Self.logLine(label: label, route: ShazamAnchorProbe.routeDescription(), summary: nil))
            return
        }

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("miccheck-\(UUID().uuidString).m4a")
        defer { try? FileManager.default.removeItem(at: url) }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1]
        guard let recorder = try? AVAudioRecorder(url: url, settings: settings) else {
            status = "Could not start recording"
            FileLog.shared.addMessage(Self.logLine(label: label, route: ShazamAnchorProbe.routeDescription(), summary: nil))
            return
        }
        recorder.isMeteringEnabled = true
        guard recorder.record() else {
            status = "Could not start recording (microphone busy or not allowed)"
            FileLog.shared.addMessage(Self.logLine(label: label, route: ShazamAnchorProbe.routeDescription(), summary: nil))
            return
        }

        var levels: [Double] = []
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            try? await Task.sleep(nanoseconds: 250_000_000)
            recorder.updateMeters()
            levels.append(Double(recorder.averagePower(forChannel: 0)))
        }
        recorder.stop()

        // The route is read while recording, so it is the input the microphone actually used.
        let route = ShazamAnchorProbe.routeDescription()
        let summary = Self.summarize(levels)
        let line = Self.logLine(label: label, route: route, summary: summary)
        FileLog.shared.addMessage(line)
        FileLog.shared.forceFlush()
        status = summary.map { String(format: "%@: average %.1f dBFS (min %.1f, max %.1f)", label, $0.average, $0.min, $0.max) }
            ?? "No level"
    }
}
#endif
