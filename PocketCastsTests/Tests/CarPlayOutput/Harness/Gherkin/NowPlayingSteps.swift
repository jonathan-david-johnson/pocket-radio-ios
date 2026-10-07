import MediaPlayer
import XCTest
@testable import podcasts

/// M13.1 harness. Reusable iOS step definitions for now-playing scenarios. They map the platform-neutral
/// phrases in `contracts/features/now_playing/*.feature` ("the system now-playing display") to
/// `MPNowPlayingInfoCenter`, and script the `FakeWorld`. A failing step reports the last display snapshot,
/// the diff against what was expected, and any fault configured on the fake world.
final class NowPlayingSteps {
    private let world: FakeWorld
    private var stationName = "KCRW Eclectic 24"
    private var rows: [FakeWorld.FakeSong] = []
    private var announced: [String] = []
    private var observer: NSObjectProtocol?

    /// How long to wait for the app to receive an announced title.
    var titleTimeout: TimeInterval = 45
    /// How long to wait for the display to match.
    var displayTimeout: TimeInterval = 10

    init(world: FakeWorld) {
        self.world = world
        observer = NotificationCenter.default.addObserver(forName: .radioStationNowPlayingDidChange, object: nil, queue: .main) { [weak self] n in
            self?.announced.append(n.userInfo?[RadioMetadataNotificationKey.title] as? String ?? "")
        }
    }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    private func spin(_ timeout: TimeInterval, until condition: () -> Bool) -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + timeout
        while ProcessInfo.processInfo.systemUptime < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.02))
        }
        return condition()
    }

    private func failure(_ outcome: NowPlayingProbe.Outcome) -> StepFailure {
        let detail = outcome.failureMessage ?? "display did not match"
        return StepFailure(message: [detail, world.faultSummary].joined(separator: "\n  "))
    }

    private func expect(_ configure: (inout NowPlayingProbe.Expectation) -> Void) throws {
        var e = NowPlayingProbe.Expectation()
        configure(&e)
        let outcome = NowPlayingProbe.waitUntil(e, timeout: displayTimeout)
        if !outcome.isMatched { throw failure(outcome) }
    }

    func register(in steps: StepLibrary) {
        steps.add("the system now-playing display is empty") { _ in
            let snapshot = NowPlayingProbe.snapshot()
            if !snapshot.isEmpty { throw StepFailure(message: "display is not empty: \(snapshot)") }
        }
        steps.add("a station \"([^\"]*)\" that streams from the local test server") { a in self.stationName = a[0] }
        steps.add("the station's tracklist lists only \"([^\"]*)\" by \"([^\"]*)\" with (\\w+) artwork") { a in
            self.rows = [FakeWorld.FakeSong(title: a[0], artist: a[1], art: a[2])]
            self.world.setTracklist(self.rows)
        }
        steps.add("the station's tracklist takes (\\d+) seconds to arrive") { a in
            self.world.setLatency(.tracklist, seconds: TimeInterval(a[0])!)
        }
        steps.add("the station's tracklist fails with status (\\d+)") { a in
            self.world.fail(.tracklist, status: Int(a[0])!)
        }
        steps.add("the listener starts the station") { _ in
            let station = try self.world.makeStation(name: self.stationName)
            RadioPlaybackStarter.shared.play(station: station, source: .unknown, prefetchTracklist: true, republishWidgetState: false)
            let pm = PlaybackManager.shared
            if !self.spin(30, until: { pm.isPlaying && !pm.isBuffering && pm.currentTime() > 1 }) {
                throw StepFailure(message: "playback never reached the playing state; display: \(NowPlayingProbe.snapshot())")
            }
        }
        steps.add("the stream announces \"([^\"]*)\" by \"([^\"]*)\"") { a in
            self.world.play(FakeWorld.FakeSong(title: a[0], artist: a[1]))
            if !self.spin(self.titleTimeout, until: { self.announced.contains(a[0]) }) {
                throw StepFailure(message: "the app never received the announcement for '\(a[0])'; display: \(NowPlayingProbe.snapshot())")
            }
        }
        steps.add("the display shows the title \"([^\"]*)\", the artist \"([^\"]*)\" and the album \"([^\"]*)\"") { a in
            try self.expect { $0.title = a[0]; $0.artist = a[1]; $0.album = a[2] }
        }
        steps.add("the display shows the title \"([^\"]*)\"") { a in
            try self.expect { $0.title = a[0] }
        }
        steps.add("the display shows (\\w+) artwork") { a in
            try self.expect { $0.artwork = a[0] }
        }
        steps.add("the display is marked as a live music stream") { _ in
            try self.expect { $0.isLiveStream = true; $0.mediaType = MPMediaType.music.rawValue }
        }
    }
}
