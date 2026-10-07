import MediaPlayer
import UIKit
import XCTest

/// M13.1 harness. Reads what the system now-playing display would show, straight from
/// `MPNowPlayingInfoCenter`, and samples the artwork image (E1: tolerance 2/255).
enum NowPlayingProbe {
    struct Snapshot: Equatable, CustomStringConvertible {
        var isEmpty: Bool
        var title: String?
        var artist: String?
        var album: String?
        var isLiveStream: Bool?
        var mediaType: UInt?
        var nowPlayingMediaType: UInt?
        /// Named colour or `rgb(r,g,b)`; nil when there is no artwork object or no image.
        var artwork: String?

        var description: String {
            if isEmpty { return "Snapshot(empty)" }
            func q(_ s: String?) -> String { s.map { "'\($0)'" } ?? "nil" }
            func v<T>(_ x: T?) -> String { x.map { "\($0)" } ?? "nil" }
            return "Snapshot(title=\(q(title)) artist=\(q(artist)) album=\(q(album)) live=\(v(isLiveStream)) mediaType=\(v(mediaType)) npMediaType=\(v(nowPlayingMediaType)) artwork=\(v(artwork)))"
        }
    }

    static func snapshot() -> Snapshot {
        guard let info = MPNowPlayingInfoCenter.default().nowPlayingInfo else {
            return Snapshot(isEmpty: true)
        }
        var artworkName: String?
        if let art = info[MPMediaItemPropertyArtwork] as? MPMediaItemArtwork,
           let image = art.image(at: CGSize(width: 300, height: 300)) {
            artworkName = ImageProbe.name(of: image)
        }
        return Snapshot(
            isEmpty: false,
            title: info[MPMediaItemPropertyTitle] as? String,
            artist: info[MPMediaItemPropertyArtist] as? String,
            album: info[MPMediaItemPropertyAlbumTitle] as? String,
            isLiveStream: (info[MPNowPlayingInfoPropertyIsLiveStream] as? NSNumber)?.boolValue,
            mediaType: (info[MPMediaItemPropertyMediaType] as? NSNumber)?.uintValue,
            nowPlayingMediaType: (info[MPNowPlayingInfoPropertyMediaType] as? NSNumber)?.uintValue,
            artwork: artworkName
        )
    }

    /// Every field optional; only set fields are compared. Use `.some(nil)` is not needed:
    /// `expectNoArtwork` and `expectEmpty` cover the "absent" cases.
    struct Expectation {
        var title: String?
        var artist: String?
        var album: String?
        var isLiveStream: Bool?
        var mediaType: UInt?
        var nowPlayingMediaType: UInt?
        var artwork: String?
        var expectNoArtwork = false
        var expectEmpty = false

        init(title: String? = nil, artist: String? = nil, album: String? = nil, isLiveStream: Bool? = nil,
             mediaType: UInt? = nil, nowPlayingMediaType: UInt? = nil, artwork: String? = nil,
             expectNoArtwork: Bool = false, expectEmpty: Bool = false) {
            self.title = title; self.artist = artist; self.album = album; self.isLiveStream = isLiveStream
            self.mediaType = mediaType; self.nowPlayingMediaType = nowPlayingMediaType; self.artwork = artwork
            self.expectNoArtwork = expectNoArtwork; self.expectEmpty = expectEmpty
        }

        func diff(against s: Snapshot) -> [String] {
            var out: [String] = []
            func check<T: Equatable>(_ name: String, _ want: T?, _ got: T?) {
                guard let want, want != got else { return }
                out.append("\(name): expected \(want), got \(got.map { "\($0)" } ?? "nil")")
            }
            if expectEmpty, !s.isEmpty { out.append("display: expected empty, got \(s)") }
            check("title", title, s.title)
            check("artist", artist, s.artist)
            check("album", album, s.album)
            check("isLiveStream", isLiveStream, s.isLiveStream)
            check("mediaType", mediaType, s.mediaType)
            check("nowPlayingMediaType", nowPlayingMediaType, s.nowPlayingMediaType)
            check("artwork", artwork, s.artwork)
            if expectNoArtwork, let got = s.artwork { out.append("artwork: expected none, got \(got)") }
            return out
        }

        func matches(_ s: Snapshot) -> Bool { diff(against: s).isEmpty }
    }

    enum Outcome {
        case matched(Snapshot)
        case timedOut(last: Snapshot, diff: [String], waited: TimeInterval)

        var isMatched: Bool { if case .matched = self { return true }; return false }

        var failureMessage: String? {
            guard case let .timedOut(last, diff, waited) = self else { return nil }
            return String(format: "now-playing probe gave up after %.2f s. Last snapshot: %@. Diff: %@",
                          waited, last.description, diff.joined(separator: "; "))
        }
    }

    private static func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    private static func spin() { RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02)) }

    static func waitUntil(_ expectation: Expectation, timeout: TimeInterval = 10) -> Outcome {
        let start = now()
        var last = snapshot()
        while true {
            last = snapshot()
            if expectation.matches(last) { return .matched(last) }
            if now() - start >= timeout { break }
            spin()
        }
        return .timedOut(last: last, diff: expectation.diff(against: last), waited: now() - start)
    }

    static func waitUntil(_ label: String, timeout: TimeInterval = 10, _ predicate: (Snapshot) -> Bool) -> Outcome {
        let start = now()
        var last = snapshot()
        while true {
            last = snapshot()
            if predicate(last) { return .matched(last) }
            if now() - start >= timeout { break }
            spin()
        }
        return .timedOut(last: last, diff: ["predicate '\(label)' not satisfied"], waited: now() - start)
    }

    /// Passes only if the expectation matched on every poll for the whole window.
    /// On failure, `last` is the first snapshot that violated it.
    static func holds(_ expectation: Expectation, for seconds: TimeInterval) -> Outcome {
        let start = now()
        var s = snapshot()
        while true {
            s = snapshot()
            if !expectation.matches(s) {
                return .timedOut(last: s, diff: expectation.diff(against: s), waited: now() - start)
            }
            if now() - start >= seconds { return .matched(s) }
            spin()
        }
    }

    @discardableResult
    static func requireWaitUntil(_ expectation: Expectation, timeout: TimeInterval = 10,
                                 file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let outcome = waitUntil(expectation, timeout: timeout)
        if let m = outcome.failureMessage { XCTFail(m, file: file, line: line) }
        return outcome.isMatched
    }

    @discardableResult
    static func requireHolds(_ expectation: Expectation, for seconds: TimeInterval,
                             file: StaticString = #filePath, line: UInt = #line) -> Bool {
        let outcome = holds(expectation, for: seconds)
        if let m = outcome.failureMessage { XCTFail("display stopped matching. " + m, file: file, line: line) }
        return outcome.isMatched
    }

    /// Samples every 100 ms on the main run loop and records changes with seconds since start.
    final class Timeline {
        private(set) var lines: [String] = []
        private var timer: Timer?
        private var t0 = ProcessInfo.processInfo.systemUptime
        private var lastText: String?

        func start() {
            stop()
            lines = []
            lastText = nil
            t0 = ProcessInfo.processInfo.systemUptime
            let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in self?.sample() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
            sample()
        }

        func stop() {
            timer?.invalidate()
            timer = nil
        }

        private func sample() {
            let text = NowPlayingProbe.snapshot().description
            guard text != lastText else { return }
            lastText = text
            lines.append(String(format: "+%6.2f s  %@", ProcessInfo.processInfo.systemUptime - t0, text))
        }

        deinit { timer?.invalidate() }
    }
}
